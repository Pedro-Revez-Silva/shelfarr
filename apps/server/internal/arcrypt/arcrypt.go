package arcrypt

import (
	"bytes"
	"compress/zlib"
	"crypto/aes"
	"crypto/cipher"
	"crypto/pbkdf2"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"hash"
	"io"
	"strings"
)

const (
	derivationIterations = 1 << 16
	keyLength            = 32
	nonceLength          = 12
	tagLength            = 16
	MaxEnvelopeBytes     = 1 << 20
	MaxPlaintextBytes    = 1 << 20
)

type Kind string

const (
	KindDecryption    Kind = "decryption"
	KindDecompression Kind = "decompression"
	KindLimit         Kind = "limit"
	KindUnsupported   Kind = "unsupported"
	KindConfiguration Kind = "configuration"
)

type Error struct {
	Kind Kind
}

func (e *Error) Error() string {
	return "active record encryption: " + string(e.Kind)
}

func KindOf(err error) Kind {
	var typed *Error
	if errors.As(err, &typed) {
		return typed.Kind
	}
	return ""
}

func fail(kind Kind) error {
	return &Error{Kind: kind}
}

var byteIdenticalEncodings = map[string]bool{"UTF-8": true, "US-ASCII": true, "ASCII-8BIT": true, "BINARY": true}

type Scheme string

const (
	SchemeSHA256 Scheme = "sha256"
	SchemeSHA1   Scheme = "sha1"
)

type Options struct {
	LegacySHA1 bool
}

type derivedKey struct {
	scheme Scheme
	id     string
	secret []byte
}

type Decryptor struct {
	keys []derivedKey
}

func NewDecryptor(primaryKey, salt string, options Options) (*Decryptor, error) {
	if primaryKey == "" || salt == "" {
		return nil, fail(KindConfiguration)
	}
	schemes := []struct {
		scheme Scheme
		digest func() hash.Hash
	}{{SchemeSHA256, sha256.New}}
	if options.LegacySHA1 {
		schemes = append(schemes, struct {
			scheme Scheme
			digest func() hash.Hash
		}{SchemeSHA1, sha1.New})
	}
	decryptor := &Decryptor{}
	for _, entry := range schemes {
		secret, err := pbkdf2.Key(entry.digest, primaryKey, []byte(salt), derivationIterations, keyLength)
		if err != nil {
			return nil, fail(KindConfiguration)
		}
		decryptor.keys = append(decryptor.keys, derivedKey{scheme: entry.scheme, id: keyID(secret), secret: secret})
	}
	return decryptor, nil
}

func keyID(secret []byte) string {
	sum := sha1.Sum(secret)
	return hex.EncodeToString(sum[:])[:4]
}

type envelope struct {
	Payload *string                    `json:"p"`
	Headers map[string]json.RawMessage `json:"h"`
}

type message struct {
	payload    []byte
	nonce      []byte
	tag        []byte
	keyID      string
	hasKeyID   bool
	compressed bool
}

func decodeBase64(value string) ([]byte, error) {
	if strings.ContainsAny(value, "\r\n") {
		return nil, fail(KindDecryption)
	}
	decoded, err := base64.StdEncoding.Strict().DecodeString(value)
	if err != nil {
		return nil, fail(KindDecryption)
	}
	return decoded, nil
}

func headerString(headers map[string]json.RawMessage, name string) (string, bool, error) {
	raw, present := headers[name]
	if !present {
		return "", false, nil
	}
	var value string
	if err := json.Unmarshal(raw, &value); err != nil {
		return "", true, fail(KindDecryption)
	}
	return value, true, nil
}

func headerBytes(headers map[string]json.RawMessage, name string) ([]byte, error) {
	value, present, err := headerString(headers, name)
	if err != nil || !present {
		return nil, err
	}
	return decodeBase64(value)
}

func truthy(raw json.RawMessage) bool {
	trimmed := bytes.TrimSpace(raw)
	return len(trimmed) > 0 && !bytes.Equal(trimmed, []byte("null")) && !bytes.Equal(trimmed, []byte("false"))
}

func parse(data []byte) (message, error) {
	if len(data) > MaxEnvelopeBytes {
		return message{}, fail(KindLimit)
	}
	var parsed envelope
	if err := json.Unmarshal(data, &parsed); err != nil || parsed.Payload == nil {
		return message{}, fail(KindDecryption)
	}
	payload, err := decodeBase64(*parsed.Payload)
	if err != nil {
		return message{}, err
	}
	if len(payload) > MaxPlaintextBytes {
		return message{}, fail(KindLimit)
	}
	result := message{payload: payload}
	if result.nonce, err = headerBytes(parsed.Headers, "iv"); err != nil {
		return message{}, err
	}
	if result.tag, err = headerBytes(parsed.Headers, "at"); err != nil {
		return message{}, err
	}
	if _, declared := parsed.Headers["e"]; declared {
		label, err := headerBytes(parsed.Headers, "e")
		if err != nil {
			return message{}, err
		}
		if !byteIdenticalEncodings[strings.ToUpper(string(label))] {
			return message{}, fail(KindUnsupported)
		}
	}
	if _, declared := parsed.Headers["k"]; declared {
		return message{}, fail(KindUnsupported)
	}
	if _, declared := parsed.Headers["i"]; declared {
		identifier, err := headerBytes(parsed.Headers, "i")
		if err != nil {
			return message{}, err
		}
		result.keyID, result.hasKeyID = string(identifier), true
	}
	result.compressed = truthy(parsed.Headers["c"])
	return result, nil
}

func (d *Decryptor) Decrypt(data []byte) ([]byte, error) {
	parsed, err := parse(data)
	if err != nil {
		return nil, err
	}
	if len(parsed.nonce) != nonceLength || len(parsed.tag) != tagLength {
		return nil, fail(KindDecryption)
	}
	sealed := append(append(make([]byte, 0, len(parsed.payload)+tagLength), parsed.payload...), parsed.tag...)
	for _, key := range d.keys {
		if parsed.hasKeyID && key.id != parsed.keyID {
			continue
		}
		if plaintext, ok := open(key.secret, parsed.nonce, sealed); ok {
			return finish(plaintext, parsed.compressed)
		}
	}
	return nil, fail(KindDecryption)
}

func open(secret, nonce, sealed []byte) ([]byte, bool) {
	block, err := aes.NewCipher(secret)
	if err != nil {
		return nil, false
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, false
	}
	plaintext, err := aead.Open(nil, nonce, sealed, nil)
	if err != nil {
		return nil, false
	}
	return plaintext, true
}

func finish(plaintext []byte, compressed bool) ([]byte, error) {
	if !compressed {
		return plaintext, nil
	}
	reader, err := zlib.NewReader(bytes.NewReader(plaintext))
	if err != nil {
		return nil, fail(KindDecompression)
	}
	defer reader.Close()
	inflated, err := io.ReadAll(io.LimitReader(reader, MaxPlaintextBytes+1))
	if err != nil {
		return nil, fail(KindDecompression)
	}
	if len(inflated) > MaxPlaintextBytes {
		return nil, fail(KindLimit)
	}
	return inflated, nil
}

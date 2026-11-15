package railsmsg

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"time"
)

const (
	encryptionKeyLength = 32
	nonceLength         = 12
	tagLength           = 16
	maxEncrypted        = 4096
)

var urlSafe = base64.RawURLEncoding.Strict()

type Encryptor struct {
	aead cipher.AEAD
}

func NewEncryptor(secretKeyBase, salt string) (Encryptor, error) {
	if secretKeyBase == "" {
		return Encryptor{}, ErrSecret
	}
	key, err := pbkdf2.Key(sha256.New, secretKeyBase, []byte(salt), keyIterations, encryptionKeyLength)
	if err != nil {
		return Encryptor{}, ErrSecret
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return Encryptor{}, ErrSecret
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return Encryptor{}, ErrSecret
	}
	return Encryptor{aead: aead}, nil
}

func (e Encryptor) Encrypt(plaintext []byte) (string, error) {
	nonce := make([]byte, nonceLength)
	if _, err := rand.Read(nonce); err != nil {
		return "", ErrSecret
	}
	sealed := e.aead.Seal(nil, nonce, plaintext, nil)
	body, tag := sealed[:len(sealed)-tagLength], sealed[len(sealed)-tagLength:]
	return urlSafe.EncodeToString(body) + separator + urlSafe.EncodeToString(nonce) + separator + urlSafe.EncodeToString(tag), nil
}

func (e Encryptor) Decrypt(message string) ([]byte, bool) {
	if len(message) > maxEncrypted {
		return nil, false
	}
	encodedTag, rest, ok := lastPart(message, urlSafe.EncodedLen(tagLength))
	if !ok {
		return nil, false
	}
	encodedNonce, encodedBody, ok := lastPart(rest, urlSafe.EncodedLen(nonceLength))
	if !ok || encodedBody == "" {
		return nil, false
	}
	body, err := urlSafe.DecodeString(encodedBody)
	if err != nil {
		return nil, false
	}
	nonce, err := urlSafe.DecodeString(encodedNonce)
	if err != nil || len(nonce) != nonceLength {
		return nil, false
	}
	tag, err := urlSafe.DecodeString(encodedTag)
	if err != nil || len(tag) != tagLength {
		return nil, false
	}
	plaintext, err := e.aead.Open(nil, nonce, append(body, tag...), nil)
	if err != nil {
		return nil, false
	}
	return plaintext, true
}

func lastPart(message string, length int) (part, rest string, ok bool) {
	cut := len(message) - length
	if cut < len(separator) || message[cut-len(separator):cut] != separator {
		return "", "", false
	}
	return message[cut:], message[:cut-len(separator)], true
}

const encryptedExpiryLayout = "2006-01-02T15:04:05.000Z"

type sealedEnvelope struct {
	Rails struct {
		Data json.RawMessage `json:"data"`
		Exp  string          `json:"exp"`
		Pur  string          `json:"pur"`
	} `json:"_rails"`
}

func (e Encryptor) Seal(data json.RawMessage, purpose string, expires time.Time) (string, error) {
	if !json.Valid(data) {
		return "", ErrSecret
	}
	payload := `{"_rails":{"data":` + string(data) + `,"exp":"` + expires.UTC().Format(encryptedExpiryLayout) + `","pur":` + Quote(purpose) + `}}`
	return e.Encrypt([]byte(payload))
}

func (e Encryptor) Open(message, purpose string, now time.Time) (json.RawMessage, bool) {
	plaintext, ok := e.Decrypt(message)
	if !ok {
		return nil, false
	}
	var envelope sealedEnvelope
	decoder := json.NewDecoder(bytes.NewReader(plaintext))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&envelope); err != nil || decoder.More() {
		return nil, false
	}
	expires, err := time.Parse(time.RFC3339Nano, envelope.Rails.Exp)
	if err != nil || !now.Before(expires) || envelope.Rails.Pur != purpose || len(envelope.Rails.Data) == 0 {
		return nil, false
	}
	return envelope.Rails.Data, true
}

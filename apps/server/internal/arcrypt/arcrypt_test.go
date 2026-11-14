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
	"encoding/json"
	"hash"
	"strings"
	"testing"
)

const (
	testPrimary = "primary-key-for-unit-tests-only"
	testSalt    = "salt-for-unit-tests-only"
)

func derive(t *testing.T, digest func() hash.Hash) []byte {
	t.Helper()
	key, err := pbkdf2.Key(digest, testPrimary, []byte(testSalt), derivationIterations, keyLength)
	if err != nil {
		t.Fatal(err)
	}
	return key
}

type headers map[string]any

func seal(t *testing.T, key, plaintext []byte, extra headers) []byte {
	t.Helper()
	block, err := aes.NewCipher(key)
	if err != nil {
		t.Fatal(err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatal(err)
	}
	nonce := bytes.Repeat([]byte{7}, nonceLength)
	sealed := aead.Seal(nil, nonce, plaintext, nil)
	body := sealed[:len(sealed)-tagLength]
	tag := sealed[len(sealed)-tagLength:]
	envelope := map[string]any{"p": base64.StdEncoding.EncodeToString(body), "h": headers{
		"iv": base64.StdEncoding.EncodeToString(nonce), "at": base64.StdEncoding.EncodeToString(tag),
	}}
	for name, value := range extra {
		envelope["h"].(headers)[name] = value
	}
	encoded, err := json.Marshal(envelope)
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}

func deflate(t *testing.T, data []byte) []byte {
	t.Helper()
	var buffer bytes.Buffer
	writer := zlib.NewWriter(&buffer)
	if _, err := writer.Write(data); err != nil {
		t.Fatal(err)
	}
	writer.Close()
	return buffer.Bytes()
}

func decryptor(t *testing.T, legacy bool) *Decryptor {
	t.Helper()
	result, err := NewDecryptor(testPrimary, testSalt, Options{LegacySHA1: legacy})
	if err != nil {
		t.Fatal(err)
	}
	return result
}

func TestDecryptRoundTrip(t *testing.T) {
	key := derive(t, sha256.New)
	plain, err := decryptor(t, false).Decrypt(seal(t, key, []byte("synthetic plaintext"), nil))
	if err != nil || string(plain) != "synthetic plaintext" {
		t.Fatalf("plain = %q, %v", plain, err)
	}
	compressed, err := decryptor(t, false).Decrypt(seal(t, key, deflate(t, []byte(strings.Repeat("x", 500))), headers{"c": true}))
	if err != nil || len(compressed) != 500 {
		t.Fatalf("compressed length = %d, %v", len(compressed), err)
	}
	empty, err := decryptor(t, false).Decrypt(seal(t, key, nil, nil))
	if err != nil || len(empty) != 0 {
		t.Fatalf("empty = %q, %v", empty, err)
	}
}

func TestLegacySHA1RequiresOptIn(t *testing.T) {
	envelope := seal(t, derive(t, sha1.New), []byte("legacy"), nil)
	if _, err := decryptor(t, false).Decrypt(envelope); KindOf(err) != KindDecryption {
		t.Fatalf("sha1 envelope without opt-in: %v", err)
	}
	plain, err := decryptor(t, true).Decrypt(envelope)
	if err != nil || string(plain) != "legacy" {
		t.Fatalf("sha1 envelope with opt-in = %q, %v", plain, err)
	}
}

func TestDecryptRejects(t *testing.T) {
	key := derive(t, sha256.New)
	valid := seal(t, key, []byte("secret value"), nil)
	bomb := deflate(t, make([]byte, MaxPlaintextBytes+1))
	cases := map[string]struct {
		input []byte
		kind  Kind
	}{
		"oversized envelope":      {bytes.Repeat([]byte(" "), MaxEnvelopeBytes+1), KindLimit},
		"decompression bomb":      {seal(t, key, bomb, headers{"c": true}), KindLimit},
		"truncated zlib stream":   {seal(t, key, deflate(t, []byte(strings.Repeat("y", 400)))[:10], headers{"c": true}), KindDecompression},
		"flag on plain payload":   {seal(t, key, []byte("not zlib"), headers{"c": true}), KindDecompression},
		"wrong key":               {seal(t, bytes.Repeat([]byte{1}, keyLength), []byte("x"), nil), KindDecryption},
		"missing nonce":           {seal(t, key, []byte("x"), headers{"iv": nil}), KindDecryption},
		"short nonce":             {seal(t, key, []byte("x"), headers{"iv": base64.StdEncoding.EncodeToString([]byte("short"))}), KindDecryption},
		"short tag":               {seal(t, key, []byte("x"), headers{"at": base64.StdEncoding.EncodeToString([]byte("short"))}), KindDecryption},
		"foreign encoding label":  {seal(t, key, []byte("x"), headers{"e": base64.StdEncoding.EncodeToString([]byte("ISO-8859-1"))}), KindUnsupported},
		"envelope data key":       {seal(t, key, []byte("x"), headers{"k": "AAAA"}), KindUnsupported},
		"not json":                {[]byte("plain text"), KindDecryption},
		"no payload":              {[]byte(`{"h":{}}`), KindDecryption},
		"newline in base64":       {bytes.Replace(valid, []byte(`"p":"`), []byte(`"p":"\n`), 1), KindDecryption},
		"non-string payload":      {[]byte(`{"p":5,"h":{}}`), KindDecryption},
		"mismatched key id":       {seal(t, key, []byte("x"), headers{"i": base64.StdEncoding.EncodeToString([]byte("zzzz"))}), KindDecryption},
		"truncated envelope text": {valid[:len(valid)/2], KindDecryption},
	}
	for name, testCase := range cases {
		t.Run(name, func(t *testing.T) {
			plain, err := decryptor(t, false).Decrypt(testCase.input)
			if err == nil {
				t.Fatalf("accepted, plaintext length %d", len(plain))
			}
			if KindOf(err) != testCase.kind {
				t.Fatalf("kind = %q, want %q", KindOf(err), testCase.kind)
			}
		})
	}
}

func TestAcceptedEncodingLabels(t *testing.T) {
	key := derive(t, sha256.New)
	for _, label := range []string{"US-ASCII", "UTF-8", "ASCII-8BIT"} {
		envelope := seal(t, key, []byte("ok"), headers{"e": base64.StdEncoding.EncodeToString([]byte(label))})
		if plain, err := decryptor(t, false).Decrypt(envelope); err != nil || string(plain) != "ok" {
			t.Fatalf("%s: %q, %v", label, plain, err)
		}
	}
}

func TestMatchingKeyIDIsAccepted(t *testing.T) {
	key := derive(t, sha256.New)
	envelope := seal(t, key, []byte("ok"), headers{"i": base64.StdEncoding.EncodeToString([]byte(keyID(key)))})
	if plain, err := decryptor(t, false).Decrypt(envelope); err != nil || string(plain) != "ok" {
		t.Fatalf("%q, %v", plain, err)
	}
}

func TestErrorsNeverCarrySecrets(t *testing.T) {
	key := derive(t, sha256.New)
	secret := "very-secret-plaintext"
	tampered := seal(t, key, []byte(secret), headers{"at": base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{9}, tagLength))})
	_, err := decryptor(t, false).Decrypt(tampered)
	if err == nil {
		t.Fatal("tampered tag accepted")
	}
	for _, forbidden := range []string{secret, testPrimary, testSalt, string(tampered)} {
		if strings.Contains(err.Error(), forbidden) {
			t.Fatalf("error leaks %q", forbidden)
		}
	}
}

func TestNewDecryptorRequiresConfiguration(t *testing.T) {
	for _, arguments := range [][2]string{{"", testSalt}, {testPrimary, ""}} {
		if _, err := NewDecryptor(arguments[0], arguments[1], Options{}); KindOf(err) != KindConfiguration {
			t.Fatalf("%v: %v", arguments, err)
		}
	}
}

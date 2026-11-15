package railsmsg

import (
	"bytes"
	"crypto/hmac"
	"crypto/pbkdf2"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

const (
	keyIterations = 1000
	keyLength     = 64
	separator     = "--"
	maxToken      = 4096
)

var ErrSecret = errors.New("secret key base is unusable")

type Verifier struct {
	key []byte
}

func NewVerifier(secretKeyBase, salt string) (Verifier, error) {
	if secretKeyBase == "" {
		return Verifier{}, ErrSecret
	}
	key, err := pbkdf2.Key(sha256.New, secretKeyBase, []byte(salt), keyIterations, keyLength)
	if err != nil {
		return Verifier{}, ErrSecret
	}
	return Verifier{key: key}, nil
}

type envelope struct {
	Rails struct {
		Data    json.RawMessage `json:"data"`
		Expires *string         `json:"exp"`
		Purpose string          `json:"pur"`
	} `json:"_rails"`
}

func (v Verifier) Generate(data json.RawMessage, purpose string) (string, error) {
	if !json.Valid(data) {
		return "", ErrSecret
	}
	payload := `{"_rails":{"data":` + string(data) + `,"pur":` + Quote(purpose) + `}}`
	text := base64.StdEncoding.EncodeToString([]byte(payload))
	return text + separator + v.sign(text), nil
}

func (v Verifier) sign(text string) string {
	mac := hmac.New(sha1.New, v.key)
	mac.Write([]byte(text))
	return hex.EncodeToString(mac.Sum(nil))
}

func (v Verifier) verifiedPayload(token string) ([]byte, bool) {
	if len(token) > maxToken {
		return nil, false
	}
	index := strings.LastIndex(token, separator)
	if index <= 0 {
		return nil, false
	}
	text, digest := token[:index], token[index+len(separator):]
	if !hmac.Equal([]byte(digest), []byte(v.sign(text))) {
		return nil, false
	}
	payload, err := base64.StdEncoding.Strict().DecodeString(text)
	if err != nil {
		return nil, false
	}
	return payload, true
}

func (v Verifier) Verified(token, purpose string) (json.RawMessage, bool) {
	payload, ok := v.verifiedPayload(token)
	if !ok {
		return nil, false
	}
	var message envelope
	decoder := json.NewDecoder(bytes.NewReader(payload))
	if err := decoder.Decode(&message); err != nil || decoder.More() {
		return nil, false
	}
	if message.Rails.Purpose != purpose || message.Rails.Expires != nil || len(message.Rails.Data) == 0 {
		return nil, false
	}
	return message.Rails.Data, true
}

type messageEnvelope struct {
	Rails struct {
		Message *string `json:"message"`
		Expires *string `json:"exp"`
		Purpose string  `json:"pur"`
	} `json:"_rails"`
}

const expiryLayout = "2006-01-02T15:04:05.000Z"

func (v Verifier) VerifiedMessage(token, purpose string, now time.Time) (json.RawMessage, bool) {
	payload, ok := v.verifiedPayload(token)
	if !ok {
		return nil, false
	}
	var message messageEnvelope
	decoder := json.NewDecoder(bytes.NewReader(payload))
	if err := decoder.Decode(&message); err != nil || decoder.More() {
		return nil, false
	}
	if message.Rails.Message == nil || message.Rails.Purpose != purpose {
		return nil, false
	}
	if message.Rails.Expires != nil {
		expires, err := time.Parse(time.RFC3339Nano, *message.Rails.Expires)
		if err != nil || !now.Before(expires) {
			return nil, false
		}
	}
	value, err := base64.StdEncoding.Strict().DecodeString(*message.Rails.Message)
	if err != nil || !json.Valid(value) {
		return nil, false
	}
	return value, true
}

func (v Verifier) GenerateMessage(value json.RawMessage, purpose string, expires time.Time) (string, error) {
	if !json.Valid(value) {
		return "", ErrSecret
	}
	payload := `{"_rails":{"message":"` + base64.StdEncoding.EncodeToString(value) + `","exp":"` + expires.UTC().Format(expiryLayout) + `","pur":` + Quote(purpose) + `}}`
	text := base64.StdEncoding.EncodeToString([]byte(payload))
	return text + separator + v.sign(text), nil
}

func Quote(text string) string {
	var builder strings.Builder
	builder.WriteByte('"')
	for _, character := range text {
		switch character {
		case '"':
			builder.WriteString(`\"`)
		case '\\':
			builder.WriteString(`\\`)
		case '\b':
			builder.WriteString(`\b`)
		case '\f':
			builder.WriteString(`\f`)
		case '\n':
			builder.WriteString(`\n`)
		case '\r':
			builder.WriteString(`\r`)
		case '\t':
			builder.WriteString(`\t`)
		case '<', '>', '&':
			fmt.Fprintf(&builder, `\u%04x`, character)
		default:
			if character < 0x20 {
				fmt.Fprintf(&builder, `\u%04x`, character)
			} else {
				builder.WriteRune(character)
			}
		}
	}
	builder.WriteByte('"')
	return builder.String()
}

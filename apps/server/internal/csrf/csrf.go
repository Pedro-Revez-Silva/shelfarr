package csrf

import (
	"crypto/hmac"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"strconv"
	"strings"
	"time"
)

const (
	salt           = "shelfarr go browser csrf v1"
	keyIterations  = 1000
	keyLength      = 32
	maxToken       = 128
	NonceBytes     = 32
	nonceTextBytes = 43
	SessionTTL     = 2 * time.Hour
	LoginTTL       = 10 * time.Minute
	kindSession    = "s"
	kindLogin      = "l"
	version        = "v1"
)

var ErrKey = errors.New("csrf key is unusable")

type Tokens struct {
	key []byte
}

func New(secretKeyBase string) (Tokens, error) {
	if secretKeyBase == "" {
		return Tokens{}, ErrKey
	}
	key, err := pbkdf2.Key(sha256.New, secretKeyBase, []byte(salt), keyIterations, keyLength)
	if err != nil {
		return Tokens{}, ErrKey
	}
	return Tokens{key: key}, nil
}

func (t Tokens) mac(kind string, expires int64, binding string) string {
	mac := hmac.New(sha256.New, t.key)
	mac.Write([]byte(version + "|" + kind + "|" + strconv.FormatInt(expires, 10) + "|" + binding))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func (t Tokens) issue(kind, binding string, now time.Time, ttl time.Duration) (string, time.Time) {
	expires := now.Add(ttl).Unix()
	return version + "." + kind + "." + strconv.FormatInt(expires, 10) + "." + t.mac(kind, expires, binding), time.Unix(expires, 0)
}

func (t Tokens) verify(token, kind, binding string, now time.Time) bool {
	if len(token) == 0 || len(token) > maxToken {
		return false
	}
	parts := strings.Split(token, ".")
	if len(parts) != 4 || parts[0] != version || parts[1] != kind {
		return false
	}
	expires, err := strconv.ParseInt(parts[2], 10, 64)
	if err != nil || expires <= now.Unix() {
		return false
	}
	return hmac.Equal([]byte(parts[3]), []byte(t.mac(kind, expires, binding)))
}

func sessionBinding(sessionID, userID int64, created time.Time) string {
	return strconv.FormatInt(sessionID, 10) + "|" + strconv.FormatInt(userID, 10) + "|" + strconv.FormatInt(created.UnixMicro(), 10)
}

func (t Tokens) ForSession(sessionID, userID int64, created, now time.Time) (string, time.Time) {
	return t.issue(kindSession, sessionBinding(sessionID, userID, created), now, SessionTTL)
}

func (t Tokens) VerifySession(token string, sessionID, userID int64, created, now time.Time) bool {
	return t.verify(token, kindSession, sessionBinding(sessionID, userID, created), now)
}

func (t Tokens) ForLogin(nonce string, now time.Time) (string, time.Time) {
	return t.issue(kindLogin, nonce, now, LoginTTL)
}

func (t Tokens) VerifyLogin(token, nonce string, now time.Time) bool {
	return ValidNonce(nonce) && t.verify(token, kindLogin, nonce, now)
}

func ValidNonce(nonce string) bool {
	if len(nonce) != nonceTextBytes {
		return false
	}
	for index := 0; index < len(nonce); index++ {
		character := nonce[index]
		if !(character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' || character >= '0' && character <= '9' || character == '-' || character == '_') {
			return false
		}
	}
	return true
}

func NewNonce() (string, error) {
	raw := make([]byte, NonceBytes)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(raw), nil
}

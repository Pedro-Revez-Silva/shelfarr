package devicegrant

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"slices"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/strictjson"
)

const (
	LifetimeSeconds    = 600
	TokenLifetimeDays  = 30
	TokenLifetimeSecs  = TokenLifetimeDays * 24 * 60 * 60
	InitialInterval    = 5
	IntervalStep       = 5
	MaxInterval        = 60
	MaxClientNameBytes = 80
	MaxScopeBytes      = 200
	MaxUserCodeChars   = 32
	CodeAlphabet       = "BCDFGHJKLMNPQRSTVWXYZ23456789"
	TokenPrefix        = "shf_"
	tokenRandomLength  = 40
	base58Alphabet     = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
	userCodeLength     = 8
	deviceCodeBytes    = 32
	Consumer           = "consumer_device"
)

var (
	BaseScopes    = []string{"library:read", "progress:write"}
	RequestScopes = []string{"search:read", "requests:read", "requests:write"}

	ErrInvalidScope = errors.New("scope is not offered to native apps")
	ErrRandom       = errors.New("secure random source failed")
)

func Digest(code string) string {
	sum := sha256.Sum256([]byte(code))
	return hex.EncodeToString(sum[:])
}

type Codes struct {
	Device string
	User   string
}

func (c Codes) DeviceDigest() string { return Digest(c.Device) }
func (c Codes) UserDigest() string   { return Digest(c.User) }

func (c Codes) Display() string { return c.User[:4] + "-" + c.User[4:] }

func NewCodes(source io.Reader) (Codes, error) {
	raw := make([]byte, deviceCodeBytes)
	if _, err := io.ReadFull(source, raw); err != nil {
		return Codes{}, ErrRandom
	}
	user, err := choose(source, CodeAlphabet, userCodeLength)
	if err != nil {
		return Codes{}, err
	}
	return Codes{Device: hex.EncodeToString(raw), User: user}, nil
}

func RandomSource() io.Reader { return rand.Reader }

func NewAccessToken(source io.Reader) (string, error) {
	body, err := choose(source, base58Alphabet, tokenRandomLength)
	if err != nil {
		return "", err
	}
	return TokenPrefix + body, nil
}

func TokenPrefixOf(raw string) string {
	if len(raw) < 12 {
		return raw
	}
	return raw[:12]
}

func NewConnectionKey(source io.Reader) (string, error) {
	raw := make([]byte, 16)
	if _, err := io.ReadFull(source, raw); err != nil {
		return "", ErrRandom
	}
	raw[6] = raw[6]&0x0f | 0x40
	raw[8] = raw[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", raw[0:4], raw[4:6], raw[6:8], raw[8:10], raw[10:16]), nil
}

func choose(source io.Reader, alphabet string, length int) (string, error) {
	limit := byte(256 - 256%len(alphabet))
	out := make([]byte, 0, length)
	buffer := make([]byte, length*2)
	for len(out) < length {
		if _, err := io.ReadFull(source, buffer); err != nil {
			return "", ErrRandom
		}
		for _, value := range buffer {
			if value >= limit {
				continue
			}
			out = append(out, alphabet[int(value)%len(alphabet)])
			if len(out) == length {
				break
			}
		}
	}
	return string(out), nil
}

const rubyStripSet = " \t\n\v\f\r\x00"

func ClientName(raw string) (string, bool) {
	if len(raw) > MaxClientNameBytes || !utf8.ValidString(raw) {
		return "", false
	}
	name := strings.Trim(raw, rubyStripSet)
	if strings.IndexFunc(name, func(r rune) bool { return !unicode.IsSpace(r) }) < 0 {
		return "", false
	}
	return name, true
}

func rubyFields(text string) []string {
	return strings.FieldsFunc(text, func(r rune) bool {
		return r == ' ' || r >= '\t' && r <= '\r'
	})
}

func RequestedScopes(present bool, scope strictjson.Value) ([]string, error) {
	if !present || scope.Kind == strictjson.Null {
		return slices.Clone(BaseScopes), nil
	}
	if scope.Kind != strictjson.String || len(scope.Text) > MaxScopeBytes {
		return nil, ErrInvalidScope
	}
	return ParseScopeText(scope.Text)
}

func ParseScopeText(text string) ([]string, error) {
	var names []string
	for _, name := range rubyFields(text) {
		if !slices.Contains(names, name) {
			names = append(names, name)
		}
	}
	var extra []string
	for _, name := range names {
		switch {
		case slices.Contains(BaseScopes, name):
		case slices.Contains(RequestScopes, name):
			extra = append(extra, name)
		default:
			return nil, ErrInvalidScope
		}
	}
	switch len(extra) {
	case 0:
		return slices.Clone(BaseScopes), nil
	case len(RequestScopes):
		return append(slices.Clone(BaseScopes), RequestScopes...), nil
	}
	return nil, ErrInvalidScope
}

func EncodeScopes(scopes []string) (string, bool) {
	if slices.Equal(scopes, BaseScopes) {
		return "", false
	}
	quoted := make([]string, len(scopes))
	for index, scope := range scopes {
		quoted[index] = `"` + scope + `"`
	}
	return "[" + strings.Join(quoted, ",") + "]", true
}

func Requesting(scopes []string) bool {
	for _, scope := range RequestScopes {
		if !slices.Contains(scopes, scope) {
			return false
		}
	}
	return true
}

func StoredScopes(stored string, present bool) []string {
	if !present || strings.TrimFunc(stored, unicode.IsSpace) == "" {
		return slices.Clone(BaseScopes)
	}
	parsed, err := strictjson.Parse([]byte(stored))
	if err != nil || parsed.Kind != strictjson.Array {
		return slices.Clone(BaseScopes)
	}
	var joined []string
	if !flatten(parsed, &joined) {
		return slices.Clone(BaseScopes)
	}
	text := strings.Join(joined, " ")
	if len(text) > MaxScopeBytes {
		return slices.Clone(BaseScopes)
	}
	scopes, err := ParseScopeText(text)
	if err != nil {
		return slices.Clone(BaseScopes)
	}
	return scopes
}

func flatten(value strictjson.Value, into *[]string) bool {
	switch value.Kind {
	case strictjson.Array:
		for _, item := range value.Items {
			if !flatten(item, into) {
				return false
			}
		}
		return true
	case strictjson.String:
		*into = append(*into, value.Text)
		return true
	case strictjson.Null:
		*into = append(*into, "")
		return true
	}
	return false
}

func NormalizeUserCode(input string) (string, bool) {
	if !utf8.ValidString(input) {
		return "", false
	}
	var builder strings.Builder
	for _, character := range input {
		switch character {
		case '-', ' ':
			continue
		}
		builder.WriteString(rubyUpcase(character))
	}
	normalized := builder.String()
	if len(normalized) != userCodeLength {
		return "", false
	}
	for index := 0; index < len(normalized); index++ {
		if !strings.ContainsRune(CodeAlphabet, rune(normalized[index])) {
			return "", false
		}
	}
	return normalized, true
}

func rubyUpcase(character rune) string {
	switch character {
	case 'ß':
		return "SS"
	case 'ﬀ':
		return "FF"
	case 'ﬅ', 'ﬆ':
		return "ST"
	}
	return string(unicode.ToUpper(character))
}

func FirstCharacters(text string, limit int) string {
	count := 0
	for index := range text {
		if count == limit {
			return text[:index]
		}
		count++
	}
	return text
}

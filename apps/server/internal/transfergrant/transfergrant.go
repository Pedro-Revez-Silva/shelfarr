package transfergrant

import (
	"bytes"
	"encoding/json"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/railsmsg"
)

const (
	minGrantLength = 32
	maxGrantLength = 2048
	Purpose        = "consumer_transfer_grant"
	Salt           = "shelfarr consumer transfer grant v1"
	Scope          = "library:read"
	Lifetime       = 24 * time.Hour
	queryKey       = "grant="
)

var number = regexp.MustCompile(`^[1-9][0-9]{0,18}$`)

type Claims struct {
	TokenID int64
	UserID  int64
	BookID  string
	AssetID string
}

type Grants struct {
	encryptor railsmsg.Encryptor
}

func New(secretKeyBase string) (Grants, error) {
	encryptor, err := railsmsg.NewEncryptor(secretKeyBase, Salt)
	if err != nil {
		return Grants{}, err
	}
	return Grants{encryptor: encryptor}, nil
}

func GrantFromQuery(rawQuery string) (string, bool) {
	value, found := strings.CutPrefix(rawQuery, queryKey)
	if !found || len(value) < minGrantLength || len(value) > maxGrantLength {
		return "", false
	}
	for index := 0; index < len(value); index++ {
		character := value[index]
		if !(character >= 'A' && character <= 'Z' || character >= 'a' && character <= 'z' || character >= '0' && character <= '9' || character == '_' || character == '-') {
			return "", false
		}
	}
	return value, true
}

func ExpiresAt(now time.Time, tokenExpiry *time.Time) time.Time {
	expires := now.Add(Lifetime)
	if tokenExpiry != nil && tokenExpiry.Before(expires) {
		return *tokenExpiry
	}
	return expires
}

func (g Grants) Issue(claims Claims, expires time.Time) (string, error) {
	data := `{"t":` + strconv.FormatInt(claims.TokenID, 10) + `,"u":` + strconv.FormatInt(claims.UserID, 10) + `,"b":` + railsmsg.Quote(claims.BookID) + `,"a":` + railsmsg.Quote(claims.AssetID) + `}`
	return g.encryptor.Seal(json.RawMessage(data), Purpose, expires)
}

type claimsDocument struct {
	Token json.RawMessage `json:"t"`
	User  json.RawMessage `json:"u"`
	Book  *string         `json:"b"`
	Asset *string         `json:"a"`
}

func (g Grants) Open(value string, now time.Time) (Claims, bool) {
	data, ok := g.encryptor.Open(value, Purpose, now)
	if !ok {
		return Claims{}, false
	}
	var document claimsDocument
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&document); err != nil || decoder.More() || document.Book == nil || document.Asset == nil {
		return Claims{}, false
	}
	if !number.MatchString(string(document.Token)) || !number.MatchString(string(document.User)) {
		return Claims{}, false
	}
	token, tokenErr := strconv.ParseInt(string(document.Token), 10, 64)
	user, userErr := strconv.ParseInt(string(document.User), 10, 64)
	if tokenErr != nil || userErr != nil {
		return Claims{}, false
	}
	return Claims{TokenID: token, UserID: user, BookID: *document.Book, AssetID: *document.Asset}, true
}

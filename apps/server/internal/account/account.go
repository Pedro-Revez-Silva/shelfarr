package account

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/strictjson"
)

const MaxBcryptCost = 14

var (
	ErrUnsupportedCost     = errors.New("bcrypt cost is above the supported ceiling")
	ErrUnsupportedScopes   = errors.New("unsupported scope encoding")
	ErrUnsupportedAdoption = errors.New("token adoption is not supported")
)

type Directory interface {
	TokenByDigest(ctx context.Context, digest string) (*store.Token, error)
	UserByID(ctx context.Context, id int64) (*store.User, error)
}

func PasswordMatches(digest, candidate string) (bool, error) {
	cost, err := bcrypt.Cost([]byte(digest))
	if err != nil {
		return false, nil
	}
	if cost > MaxBcryptCost {
		return false, ErrUnsupportedCost
	}
	return bcrypt.CompareHashAndPassword([]byte(digest), []byte(candidate)) == nil, nil
}

func TokenDigest(raw string) string {
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:])
}

func BearerToken(header string) (string, bool) {
	scheme, rest, found := splitAuthorization(header)
	if !found || !strings.EqualFold(scheme, "bearer") || strings.TrimSpace(rest) == "" {
		return "", false
	}
	return rest, true
}

func splitAuthorization(header string) (string, string, bool) {
	trimmed := strings.TrimLeft(header, " \t\n\v\f\r")
	end := strings.IndexAny(trimmed, " \t\n\v\f\r")
	if end < 0 {
		return trimmed, "", false
	}
	return trimmed[:end], strings.TrimLeft(trimmed[end:], " \t\n\v\f\r"), true
}

type Principal struct {
	TokenID        int64
	TokenExpiresAt sql.NullString
	UserID         int64
	Username       string
	Name           string
	Admin          bool
	Scopes         []string
}

var privilegedScopes = map[string]bool{"requests:admin": true, "users:write": true}

func (p Principal) HasScope(scope string) bool {
	if !contains(p.Scopes, scope) {
		return false
	}
	return !privilegedScopes[scope] || p.Admin
}

func (p Principal) VisibleScopes() []string {
	visible := []string{}
	for _, scope := range p.Scopes {
		if p.HasScope(scope) {
			visible = append(visible, scope)
		}
	}
	return visible
}

func contains(values []string, wanted string) bool {
	for _, value := range values {
		if value == wanted {
			return true
		}
	}
	return false
}

func ScopeList(encoded string) ([]string, error) {
	parsed, err := strictjson.Parse([]byte(encoded))
	if err != nil {
		return []string{}, nil
	}
	var items []string
	switch parsed.Kind {
	case strictjson.String:
		items = []string{parsed.Text}
	case strictjson.Array:
		for _, element := range parsed.Items {
			if element.Kind != strictjson.String {
				return nil, ErrUnsupportedScopes
			}
			items = append(items, element.Text)
		}
	default:
		return nil, ErrUnsupportedScopes
	}
	return splitScopes(items), nil
}

func splitScopes(items []string) []string {
	seen := map[string]bool{}
	scopes := []string{}
	for _, item := range items {
		for _, scope := range strings.FieldsFunc(item, func(r rune) bool {
			return r == ',' || r == ' ' || r == '\t' || r == '\n' || r == '\r' || r == '\v' || r == '\f'
		}) {
			if !seen[scope] {
				seen[scope] = true
				scopes = append(scopes, scope)
			}
		}
	}
	return scopes
}

func Authenticate(ctx context.Context, directory Directory, authorization string, now time.Time) (*Principal, error) {
	raw, ok := BearerToken(authorization)
	if !ok {
		return nil, nil
	}
	token, err := directory.TokenByDigest(ctx, TokenDigest(raw))
	if err != nil || token == nil {
		return nil, err
	}
	if token.RevokedAt.Valid {
		return nil, nil
	}
	if token.ExpiresAt.Valid {
		expiry, err := store.ParseTimestamp(token.ExpiresAt.String)
		if err != nil {
			return nil, err
		}
		if !expiry.After(now) {
			return nil, nil
		}
	}
	if token.ReplacesID.Valid {
		return nil, ErrUnsupportedAdoption
	}
	if !token.UserID.Valid {
		return nil, nil
	}
	user, err := directory.UserByID(ctx, token.UserID.Int64)
	if err != nil || user == nil || user.Deleted {
		return nil, err
	}
	scopes, err := ScopeList(token.Scopes)
	if err != nil {
		return nil, err
	}
	return &Principal{UserID: user.ID, Username: user.Username, Name: user.Name, Admin: user.Role == 1, Scopes: scopes}, nil
}

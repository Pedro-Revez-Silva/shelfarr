package account

import (
	"context"
	"database/sql"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
)

func TestBearerToken(t *testing.T) {
	cases := []struct {
		header string
		token  string
		ok     bool
	}{
		{"Bearer abc", "abc", true},
		{"bearer abc", "abc", true},
		{"  BEARER   abc def ", "abc def ", true},
		{"Bearer", "", false},
		{"Bearer    ", "", false},
		{"Basic abc", "", false},
		{"", "", false},
		{"abc", "", false},
	}
	for _, testCase := range cases {
		token, ok := BearerToken(testCase.header)
		if token != testCase.token || ok != testCase.ok {
			t.Errorf("%q = (%q, %v), want (%q, %v)", testCase.header, token, ok, testCase.token, testCase.ok)
		}
	}
}

func TestScopeList(t *testing.T) {
	cases := []struct {
		encoded string
		want    []string
		err     bool
	}{
		{`["library:read","progress:write"]`, []string{"library:read", "progress:write"}, false},
		{`["a b","a,c"," d "]`, []string{"a", "b", "c", "d"}, false},
		{`"x y"`, []string{"x", "y"}, false},
		{`[]`, []string{}, false},
		{`not json`, []string{}, false},
		{``, []string{}, false},
		{`[1]`, nil, true},
		{`{"a":1}`, nil, true},
		{`5`, nil, true},
	}
	for _, testCase := range cases {
		got, err := ScopeList(testCase.encoded)
		if (err != nil) != testCase.err || !reflect.DeepEqual(got, testCase.want) {
			t.Errorf("%q = %v, %v", testCase.encoded, got, err)
		}
	}
}

func TestPrivilegedScopesNeedAnAdministrator(t *testing.T) {
	scopes := []string{"library:read", "requests:admin", "users:write", "progress:write"}
	member := Principal{Scopes: scopes}
	admin := Principal{Scopes: scopes, Admin: true}
	if got := member.VisibleScopes(); !reflect.DeepEqual(got, []string{"library:read", "progress:write"}) {
		t.Errorf("member scopes = %v", got)
	}
	if got := admin.VisibleScopes(); !reflect.DeepEqual(got, scopes) {
		t.Errorf("admin scopes = %v", got)
	}
	if (Principal{}).HasScope("library:read") {
		t.Error("an empty principal has a scope")
	}
}

type directory struct {
	tokens map[string]*store.Token
	users  map[int64]*store.User
}

func (d directory) TokenByDigest(_ context.Context, digest string) (*store.Token, error) {
	return d.tokens[digest], nil
}

func (d directory) UserByID(_ context.Context, id int64) (*store.User, error) {
	return d.users[id], nil
}

func TestAuthenticateDecisions(t *testing.T) {
	now := time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC)
	owner := sql.NullInt64{Int64: 1, Valid: true}
	scopes := `["library:read"]`
	users := map[int64]*store.User{1: {ID: 1, Username: "a", Name: "A"}, 2: {ID: 2, Deleted: true}}
	tokens := map[string]*store.Token{
		TokenDigest("good"):     {UserID: owner, Scopes: scopes},
		TokenDigest("revoked"):  {UserID: owner, Scopes: scopes, RevokedAt: sql.NullString{String: "2026-01-01 00:00:00", Valid: true}},
		TokenDigest("expired"):  {UserID: owner, Scopes: scopes, ExpiresAt: sql.NullString{String: "2026-11-14 12:00:00", Valid: true}},
		TokenDigest("future"):   {UserID: owner, Scopes: scopes, ExpiresAt: sql.NullString{String: "2026-11-14 12:00:00.000001", Valid: true}},
		TokenDigest("deleted"):  {UserID: sql.NullInt64{Int64: 2, Valid: true}, Scopes: scopes},
		TokenDigest("orphan"):   {Scopes: scopes},
		TokenDigest("adopting"): {UserID: owner, Scopes: scopes, ReplacesID: sql.NullInt64{Int64: 9, Valid: true}},
		TokenDigest("badscope"): {UserID: owner, Scopes: `[1]`},
	}
	source := directory{tokens, users}
	cases := []struct {
		header    string
		principal bool
		err       error
	}{
		{"Bearer good", true, nil},
		{"Bearer unknown", false, nil},
		{"Bearer revoked", false, nil},
		{"Bearer expired", false, nil},
		{"Bearer future", true, nil},
		{"Bearer deleted", false, nil},
		{"Bearer orphan", false, nil},
		{"Bearer adopting", false, ErrUnsupportedAdoption},
		{"Bearer badscope", false, ErrUnsupportedScopes},
		{"", false, nil},
	}
	for _, testCase := range cases {
		principal, err := Authenticate(context.Background(), source, testCase.header, now)
		if (principal != nil) != testCase.principal || !errors.Is(err, testCase.err) {
			t.Errorf("%q = (%v, %v)", testCase.header, principal, err)
		}
	}
}

func TestPasswordMatches(t *testing.T) {
	digest, err := bcrypt.GenerateFromPassword([]byte("Correct-Horse-1"), bcrypt.MinCost)
	if err != nil {
		t.Fatal(err)
	}
	if matches, err := PasswordMatches(string(digest), "Correct-Horse-1"); !matches || err != nil {
		t.Errorf("correct password: %v, %v", matches, err)
	}
	for _, candidate := range []string{"", "correct-horse-1", "Correct-Horse-1 "} {
		if matches, err := PasswordMatches(string(digest), candidate); matches || err != nil {
			t.Errorf("%q: %v, %v", candidate, matches, err)
		}
	}
	if matches, err := PasswordMatches("not a digest", "Correct-Horse-1"); matches || err != nil {
		t.Errorf("malformed digest: %v, %v", matches, err)
	}
}

func TestPasswordMatchesRefusesCostsAboveTheCeilingWithoutDoingTheWork(t *testing.T) {
	started := time.Now()
	for _, cost := range []string{"15", "20", "31"} {
		digest := "$2a$" + cost + "$" + strings.Repeat("a", 53)
		if matches, err := PasswordMatches(digest, "x"); matches || !errors.Is(err, ErrUnsupportedCost) {
			t.Errorf("cost %s: %v, %v", cost, matches, err)
		}
	}
	if time.Since(started) > time.Second {
		t.Fatal("refusal took bcrypt time")
	}
}

func TestAStoredScopeIsFoundOnlyAmongTheTextsRailsNormalises(t *testing.T) {
	for encoded, want := range map[string]bool{
		`["library:read"]`: true, `"library:read"`: true, `"search:read library:read"`: true, `["search:read,library:read"]`: true,
		`[null, "library:read"]`: true, `[5, true, "library:read"]`: true, `[{"a": 1}, "library:read"]`: true,
		`null`: false, `[]`: false, `{"library:read": true}`: false, `[["library:read"]]`: false, `5`: false, `not json`: false,
		`["progress:write"]`: false, `["library:readx"]`: false, `["LIBRARY:READ"]`: false,
	} {
		if got := StoredScopeIncludes(encoded, "library:read"); got != want {
			t.Errorf("%s: %v", encoded, got)
		}
	}
}

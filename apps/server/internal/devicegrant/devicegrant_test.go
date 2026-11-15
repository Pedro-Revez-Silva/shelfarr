package devicegrant

import (
	"bytes"
	"errors"
	"reflect"
	"regexp"
	"strings"
	"testing"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/strictjson"
)

func scopeValue(t *testing.T, document string) (strictjson.Value, bool) {
	t.Helper()
	parsed, err := strictjson.Parse([]byte(document))
	if err != nil {
		t.Fatal(err)
	}
	return parsed.Member("scope")
}

func TestRequestedScopesFollowTheRailsRule(t *testing.T) {
	bundle := "search:read requests:read requests:write"
	base := []string{"library:read", "progress:write"}
	full := append(append([]string{}, base...), "search:read", "requests:read", "requests:write")
	cases := []struct {
		document string
		want     []string
		invalid  bool
	}{
		{`{}`, base, false},
		{`{"scope":null}`, base, false},
		{`{"scope":""}`, base, false},
		{`{"scope":"   "}`, base, false},
		{`{"scope":"library:read"}`, base, false},
		{`{"scope":"library:read library:read progress:write"}`, base, false},
		{`{"scope":"progress:write\tlibrary:read\n"}`, base, false},
		{`{"scope":"library:read progress:write ` + bundle + `"}`, full, false},
		{`{"scope":"requests:write requests:read search:read"}`, full, false},
		{`{"scope":"` + bundle + ` search:read"}`, full, false},
		{`{"scope":"search:read"}`, nil, true},
		{`{"scope":"search:read requests:read"}`, nil, true},
		{`{"scope":"requests:admin"}`, nil, true},
		{`{"scope":"users:write library:read"}`, nil, true},
		{`{"scope":"unknown"}`, nil, true},
		{`{"scope":"library:read progress:write"}`, nil, true},
		{`{"scope":"library:read\u0000progress:write"}`, nil, true},
		{`{"scope":["library:read"]}`, nil, true},
		{`{"scope":5}`, nil, true},
		{`{"scope":true}`, nil, true},
		{`{"scope":{}}`, nil, true},
		{`{"scope":"` + strings.Repeat("a", 201) + `"}`, nil, true},
		{`{"scope":"library:read ` + strings.Repeat(" ", 200) + `"}`, nil, true},
	}
	for _, c := range cases {
		value, present := scopeValue(t, c.document)
		got, err := RequestedScopes(present, value)
		if c.invalid != errors.Is(err, ErrInvalidScope) || !reflect.DeepEqual(got, c.want) {
			t.Errorf("%.60s: got %v %v want %v invalid=%t", c.document, got, err, c.want, c.invalid)
		}
	}
}

func TestStoredScopesFallBackToTheBasePairExactlyWhereRailsDoes(t *testing.T) {
	base := []string{"library:read", "progress:write"}
	full := append(append([]string{}, base...), "search:read", "requests:read", "requests:write")
	for stored, want := range map[string][]string{
		`["library:read","progress:write","search:read","requests:read","requests:write"]`: full,
		`["requests:write","requests:read","search:read"]`:                                 full,
		`["library:read","progress:write"]`:                                                base,
		`["search:read"]`:                                                                  base,
		`["requests:admin"]`:                                                               base,
		`"search:read requests:read requests:write"`:                                       base,
		`{"a":1}`: base,
		`[1]`:     base,
		`[null]`:  base,
		`[["search:read","requests:read"],"requests:write"]`: full,
		`not json`: base,
		`  `:       base,
		``:         base,
	} {
		if got := StoredScopes(stored, true); !reflect.DeepEqual(got, want) {
			t.Errorf("%q: %v want %v", stored, got, want)
		}
	}
	if got := StoredScopes("", false); !reflect.DeepEqual(got, base) {
		t.Errorf("null scopes: %v", got)
	}
}

func TestScopesAreEncodedAsRailsToJSONWritesThem(t *testing.T) {
	if _, stored := EncodeScopes(BaseScopes); stored {
		t.Fatal("the base pair is stored as NULL")
	}
	encoded, stored := EncodeScopes(append(append([]string{}, BaseScopes...), RequestScopes...))
	if !stored || encoded != `["library:read","progress:write","search:read","requests:read","requests:write"]` {
		t.Fatalf("%q %t", encoded, stored)
	}
}

func TestClientNameFollowsRubyStripPresentAndByteSize(t *testing.T) {
	for raw, want := range map[string]string{"App": "App", "  App  ": "App", "\t\x00App\n": "App", "A": "A", "Ünïcode": "Ünïcode", " App": " App", "App ": "App ", strings.Repeat("a", 80): strings.Repeat("a", 80)} {
		if got, ok := ClientName(raw); !ok || got != want {
			t.Errorf("%q: %q %t want %q", raw, got, ok, want)
		}
	}
	for _, raw := range []string{"", " ", "\t\n", "\x00", " ", "   ", "　", strings.Repeat("a", 81), "  " + strings.Repeat("a", 79), strings.Repeat("é", 41), "bad\xff"} {
		if got, ok := ClientName(raw); ok {
			t.Errorf("%q accepted as %q", raw, got)
		}
	}
}

func TestUserCodeNormalisationFollowsRubyUpcaseAndDelete(t *testing.T) {
	for input, want := range map[string]string{"bcdf-ghjk": "BCDFGHJK", "BCDF GHJK": "BCDFGHJK", "bcdfghjk": "BCDFGHJK", "bc-df-gh-jk": "BCDFGHJK", "2345-6789": "23456789", "ßßßß": "SSSSSSSS", "ſſſſſſſſ": "SSSSSSSS"} {
		got, ok := NormalizeUserCode(input)
		if !ok || got != want {
			t.Errorf("%q: %q %t want %q", input, got, ok, want)
		}
	}
	for _, input := range []string{"", "BCDFGHJ", "BCDFGHJKL", "BCDFGHJA", "BCDFGHJ0", "BCDFGHJ1", "BCDF\tGHJK", "BCDF_GHJK", "BCDFGHJK\n", "ＢＣＤＦＧＨＪＫ", "\xff"} {
		if got, ok := NormalizeUserCode(input); ok {
			t.Errorf("%q accepted as %q", input, got)
		}
	}
}

func TestGeneratedMaterialHasTheRailsShape(t *testing.T) {
	source := RandomSource()
	devicePattern := regexp.MustCompile(`^[0-9a-f]{64}$`)
	userPattern := regexp.MustCompile(`^[BCDFGHJKLMNPQRSTVWXYZ23456789]{8}$`)
	tokenPattern := regexp.MustCompile(`^shf_[1-9A-HJ-NP-Za-km-z]{40}$`)
	uuidPattern := regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
	seen := map[string]bool{}
	for index := 0; index < 200; index++ {
		codes, err := NewCodes(source)
		if err != nil || !devicePattern.MatchString(codes.Device) || !userPattern.MatchString(codes.User) || len(codes.Display()) != 9 || codes.Display()[4] != '-' {
			t.Fatalf("codes %v %v", codes, err)
		}
		token, err := NewAccessToken(source)
		if err != nil || !tokenPattern.MatchString(token) || TokenPrefixOf(token) != token[:12] {
			t.Fatalf("token %q %v", token, err)
		}
		key, err := NewConnectionKey(source)
		if err != nil || !uuidPattern.MatchString(key) {
			t.Fatalf("key %q %v", key, err)
		}
		for _, value := range []string{codes.Device, token, key} {
			if seen[value] {
				t.Fatalf("repeated %q", value)
			}
			seen[value] = true
		}
	}
	if Digest("abc") != "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" {
		t.Fatal("digest is not SHA-256 hex")
	}
}

func TestRandomFailureIsReportedNotSwallowed(t *testing.T) {
	short := bytes.NewReader(make([]byte, 5))
	if _, err := NewCodes(short); !errors.Is(err, ErrRandom) {
		t.Fatalf("codes: %v", err)
	}
	if _, err := NewAccessToken(bytes.NewReader(nil)); !errors.Is(err, ErrRandom) {
		t.Fatalf("token: %v", err)
	}
	if _, err := NewConnectionKey(bytes.NewReader(make([]byte, 3))); !errors.Is(err, ErrRandom) {
		t.Fatalf("key: %v", err)
	}
}

func TestFirstCharactersCountsCharactersNotBytes(t *testing.T) {
	if got := FirstCharacters("ééééé", 3); got != "ééé" {
		t.Fatal(got)
	}
	if got := FirstCharacters("ab", 32); got != "ab" {
		t.Fatal(got)
	}
}

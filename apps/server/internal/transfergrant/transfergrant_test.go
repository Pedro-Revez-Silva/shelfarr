package transfergrant

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/railsmsg"
)

var (
	assetHex = strings.Repeat("a", 64)
	railsNow = time.Date(2026, 11, 15, 10, 0, 0, 0, time.UTC)
	want     = Claims{TokenID: 5, UserID: 3, BookID: "77", AssetID: assetHex}
)

func grants(t *testing.T, secret string) Grants {
	t.Helper()
	grants, err := New(secret)
	if err != nil {
		t.Fatal(err)
	}
	return grants
}

func TestARailsGrantIsOpenedAndEveryOtherRailsEnvelopeIsRefused(t *testing.T) {
	opener := grants(t, railsSecret)
	claims, ok := opener.Open(railsVectors["valid"], railsNow)
	if !ok || claims != want {
		t.Fatalf("a grant minted by Rails was refused: %v %+v", ok, claims)
	}
	if claims, ok := opener.Open(railsVectors["offset_expiry"], railsNow); !ok || claims != want {
		t.Fatalf("an expiry written with an offset was refused: %v", ok)
	}
	for name, vector := range railsVectors {
		if name == "valid" || name == "offset_expiry" {
			continue
		}
		if claims, ok := opener.Open(vector, railsNow); ok {
			t.Errorf("%s was opened as %+v", name, claims)
		}
	}
}

func TestAGrantIsRefusedFromTheSecondItExpires(t *testing.T) {
	opener := grants(t, railsSecret)
	expires := time.Date(2099, 1, 1, 0, 0, 0, 0, time.UTC)
	for offset, accepted := range map[time.Duration]bool{-time.Millisecond: true, 0: false, time.Millisecond: false, -24 * time.Hour: true} {
		if _, ok := opener.Open(railsVectors["valid"], expires.Add(offset)); ok != accepted {
			t.Errorf("at expiry %+v the grant was accepted=%v", offset, ok)
		}
	}
}

func TestGoGrantsCarryTheRailsPlaintextAndAreOpenedByTheSameKey(t *testing.T) {
	issuer := grants(t, railsSecret)
	expires := time.Date(2026, 11, 16, 10, 0, 0, 987_654_000, time.UTC)
	first, err := issuer.Issue(want, expires)
	if err != nil {
		t.Fatal(err)
	}
	second, _ := issuer.Issue(want, expires)
	if first == second {
		t.Fatal("two grants for the same claims are identical: the nonce is not random")
	}
	encryptor, _ := railsmsg.NewEncryptor(railsSecret, Salt)
	plaintext, ok := encryptor.Decrypt(first)
	wantText := `{"_rails":{"data":{"t":5,"u":3,"b":"77","a":"` + assetHex + `"},"exp":"2026-11-16T10:00:00.987Z","pur":"consumer_transfer_grant"}}`
	if !ok || string(plaintext) != wantText {
		t.Fatalf("the plaintext differs from the Rails envelope: %q", plaintext)
	}
	if claims, ok := issuer.Open(first, railsNow); !ok || claims != want {
		t.Fatal("a grant is not opened by the key that issued it")
	}
	if _, ok := grants(t, "another-synthetic-secret-key-base-0123456789abcdef").Open(first, railsNow); ok {
		t.Fatal("a grant was opened by another secret")
	}
	if len(first) != len(railsVectors["valid"]) {
		t.Fatalf("the grant has %d characters, Rails produces %d for the same claims", len(first), len(railsVectors["valid"]))
	}
}

func TestEveryTamperedOrTruncatedGrantIsRefusedWithoutPanicking(t *testing.T) {
	opener := grants(t, railsSecret)
	valid := railsVectors["valid"]
	alphabet := []byte("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
	for index := 0; index < len(valid); index++ {
		for _, replacement := range alphabet[:2] {
			if valid[index] == replacement {
				continue
			}
			tampered := valid[:index] + string(replacement) + valid[index+1:]
			if _, ok := opener.Open(tampered, railsNow); ok {
				t.Fatalf("a grant altered at %d was opened", index)
			}
		}
	}
	for length := 0; length < len(valid); length++ {
		if _, ok := opener.Open(valid[:length], railsNow); ok {
			t.Fatalf("a grant cut to %d characters was opened", length)
		}
	}
	for _, hostile := range []string{"", "--", strings.Repeat("-", 6000), strings.Repeat("A", 70000), valid + valid, valid + "=", "+" + valid[1:], valid[:10] + "/" + valid[11:]} {
		if _, ok := opener.Open(hostile, railsNow); ok {
			t.Fatalf("a hostile value of %d bytes was opened", len(hostile))
		}
	}
}

func TestOnlyOneLiteralGrantQueryIsAccepted(t *testing.T) {
	grant := railsVectors["valid"]
	for query, accepted := range map[string]bool{
		"grant=" + grant: true, "": false, "grant": false, "grant=": false, "grant=" + grant + "&": false, "&grant=" + grant: false,
		"grant=" + grant + "&grant=" + grant: false, "grant=" + grant + "&x=1": false, "x=1&grant=" + grant: false, "grant=" + grant + ";x=1": false,
		"gr%61nt=" + grant: false, "GRANT=" + grant: false, "grant[]=" + grant: false, "x[grant]=" + grant: false, "grant==" + grant: false,
		"grant=" + grant + "=": false, "grant=+" + grant: false, "grant=" + grant + "%20": false, "grant=" + grant + "%": false, "grant=%" + grant: false,
		"grant=" + strings.Repeat("A", 31): false, "grant=" + strings.Repeat("A", 32): true, "grant=" + strings.Repeat("A", 2048): true, "grant=" + strings.Repeat("A", 2049): false,
		"grant=" + grant[:40] + "+/" + grant[42:]: false, "grant=" + grant + "\n": false, "grant=" + grant + " ": false, "Grant=" + grant: false, "token=" + grant: false,
	} {
		if _, ok := GrantFromQuery(query); ok != accepted {
			t.Errorf("%q: accepted=%v", query, ok)
		}
	}
}

func TestTheLifetimeIsADayOrTheTokensOwnExpiryWhicheverIsSooner(t *testing.T) {
	now := time.Date(2026, 11, 7, 12, 0, 0, 500, time.UTC)
	soon, later := now.Add(3*time.Hour), now.Add(30*24*time.Hour)
	for name, test := range map[string]struct {
		expiry *time.Time
		want   time.Time
	}{"none": {nil, now.Add(24 * time.Hour)}, "soon": {&soon, soon}, "later": {&later, now.Add(24 * time.Hour)}, "exactly a day": {ptr(now.Add(24 * time.Hour)), now.Add(24 * time.Hour)}} {
		if got := ExpiresAt(now, test.expiry); !got.Equal(test.want) {
			t.Errorf("%s: %v want %v", name, got, test.want)
		}
	}
}

func ptr(moment time.Time) *time.Time { return &moment }

func TestClaimsAreOpenedOnlyWithTheExactTypesRailsWrites(t *testing.T) {
	encryptor, _ := railsmsg.NewEncryptor(railsSecret, Salt)
	opener := grants(t, railsSecret)
	expires := time.Date(2099, 1, 1, 0, 0, 0, 0, time.UTC)
	for name, claims := range map[string]string{
		"exact": `{"t":5,"u":3,"b":"77","a":"x"}`, "reordered": `{"a":"x","b":"77","u":3,"t":5}`,
		"string id": `{"t":"5","u":3,"b":"77","a":"x"}`, "float id": `{"t":5.0,"u":3,"b":"77","a":"x"}`, "exponent id": `{"t":5e0,"u":3,"b":"77","a":"x"}`,
		"zero id": `{"t":0,"u":3,"b":"77","a":"x"}`, "negative id": `{"t":-5,"u":3,"b":"77","a":"x"}`, "leading zero id": `{"t":05,"u":3,"b":"77","a":"x"}`,
		"huge id": `{"t":99999999999999999999,"u":3,"b":"77","a":"x"}`, "null id": `{"t":null,"u":3,"b":"77","a":"x"}`,
		"numeric book": `{"t":5,"u":3,"b":77,"a":"x"}`, "null asset": `{"t":5,"u":3,"b":"77","a":null}`, "missing asset": `{"t":5,"u":3,"b":"77"}`,
		"extra": `{"t":5,"u":3,"b":"77","a":"x","z":1}`, "array": `[{"t":5,"u":3,"b":"77","a":"x"}]`, "string": `"x"`, "null": `null`,
	} {
		grant, _ := encryptor.Seal(json.RawMessage(claims), Purpose, expires)
		_, ok := opener.Open(grant, railsNow)
		if wanted := name == "exact" || name == "reordered"; ok != wanted {
			t.Errorf("%s: accepted=%v", name, ok)
		}
	}
}

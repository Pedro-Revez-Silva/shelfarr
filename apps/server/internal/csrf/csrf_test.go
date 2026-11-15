package csrf

import (
	"strings"
	"testing"
	"time"
)

var base = time.Date(2026, 11, 15, 12, 0, 0, 0, time.UTC)

func tokens(t *testing.T, secret string) Tokens {
	t.Helper()
	found, err := New(secret)
	if err != nil {
		t.Fatal(err)
	}
	return found
}

func TestSessionTokensAreBoundToTheSessionTheUserAndTheirExpiry(t *testing.T) {
	issuer := tokens(t, "first-secret-key-base")
	token, expires := issuer.ForSession(7, 3, base, base)
	if !expires.Equal(base.Add(SessionTTL)) {
		t.Fatalf("expiry %v", expires)
	}
	for name, ok := range map[string]bool{
		"same":              issuer.VerifySession(token, 7, 3, base, base.Add(time.Hour)),
		"other session":     issuer.VerifySession(token, 8, 3, base, base),
		"other user":        issuer.VerifySession(token, 7, 4, base, base),
		"other creation":    issuer.VerifySession(token, 7, 3, base.Add(time.Microsecond), base),
		"expired":           issuer.VerifySession(token, 7, 3, base, base.Add(SessionTTL)),
		"other key":         tokens(t, "second-secret-key-base").VerifySession(token, 7, 3, base, base),
		"login kind":        issuer.VerifyLogin(token, "x", base),
		"empty":             issuer.VerifySession("", 7, 3, base, base),
		"oversized":         issuer.VerifySession(strings.Repeat("a", 500), 7, 3, base, base),
		"tampered":          issuer.VerifySession(token[:len(token)-1]+"A", 7, 3, base, base),
		"extended expiry":   issuer.VerifySession(strings.Replace(token, "."+itoa(expires.Unix())+".", "."+itoa(expires.Unix()+9999)+".", 1), 7, 3, base, base),
		"missing separator": issuer.VerifySession(strings.ReplaceAll(token, ".", ""), 7, 3, base, base),
	} {
		if want := name == "same"; ok != want {
			t.Errorf("%s verified=%t", name, ok)
		}
	}
}

func itoa(value int64) string {
	digits := []byte{}
	if value == 0 {
		return "0"
	}
	for value > 0 {
		digits = append([]byte{byte('0' + value%10)}, digits...)
		value /= 10
	}
	return string(digits)
}

func TestLoginTokensNeedTheNonceThatMintedThem(t *testing.T) {
	issuer := tokens(t, "first-secret-key-base")
	nonce, err := NewNonce()
	if err != nil || !ValidNonce(nonce) {
		t.Fatalf("nonce %q %v", nonce, err)
	}
	other, _ := NewNonce()
	if nonce == other {
		t.Fatal("two nonces are equal")
	}
	token, _ := issuer.ForLogin(nonce, base)
	if !issuer.VerifyLogin(token, nonce, base.Add(LoginTTL-time.Second)) || issuer.VerifyLogin(token, other, base) || issuer.VerifyLogin(token, nonce, base.Add(LoginTTL)) || issuer.VerifyLogin(token, "", base) || issuer.VerifySession(token, 1, 1, base, base) {
		t.Fatal("a login token verified outside its binding")
	}
	for _, bad := range []string{"", "short", strings.Repeat("a", 44), strings.Repeat("!", 43)} {
		if ValidNonce(bad) {
			t.Errorf("%q accepted as a nonce", bad)
		}
	}
}

func TestAnEmptySecretIsRefused(t *testing.T) {
	if _, err := New(""); err == nil {
		t.Fatal("an empty secret produced a key")
	}
}

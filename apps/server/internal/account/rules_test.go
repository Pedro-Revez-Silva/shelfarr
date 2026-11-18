package account

import (
	"reflect"
	"strings"
	"testing"

	"golang.org/x/crypto/bcrypt"
)

func TestNewPasswordRulesFollowRails(t *testing.T) {
	weak := []string{MessageWeak}
	cases := []struct {
		name         string
		password     string
		confirmation string
		oidc         bool
		want         FieldErrors
	}{
		{"valid", "Abcdefghijk1", "Abcdefghijk1", false, FieldErrors{}},
		{"twelve characters, more bytes", "Aa1ééééééééé", "Aa1ééééééééé", false, FieldErrors{}},
		{"thirteen bytes, eight characters", "Aa1ééééé", "Aa1ééééé", false, FieldErrors{"password": {MessageTooShort}}},
		{"exactly 72 bytes", "Aa1" + strings.Repeat("x", 69), "Aa1" + strings.Repeat("x", 69), false, FieldErrors{}},
		{"73 bytes", "Aa1" + strings.Repeat("x", 70), "Aa1" + strings.Repeat("x", 70), false, FieldErrors{"password": {MessageTooLong}}},
		{"too long and weak", strings.Repeat("x", 80), strings.Repeat("x", 80), false, FieldErrors{"password": {MessageTooLong, MessageWeak}}},
		{"short and weak", "abc", "abc", false, FieldErrors{"password": {MessageTooShort, MessageWeak}}},
		{"short and mismatched", "Ab1", "zz", false, FieldErrors{"password": {MessageTooShort}, "password_confirmation": {MessageMismatch}}},
		{"no uppercase", "abcdefghijk1", "abcdefghijk1", false, FieldErrors{"password": weak}},
		{"a line feed", "Abcdefghijk1\nzz", "Abcdefghijk1\nzz", false, FieldErrors{"password": weak}},
		{"carriage return and tab are allowed", "Abcd\tefghijk1\r", "Abcd\tefghijk1\r", false, FieldErrors{}},
		{"line separator is allowed", "Abcdefghijk1\u2028", "Abcdefghijk1\u2028", false, FieldErrors{}},
		{"Arabic-Indic digit is not a digit", "Abcdefghijk١", "Abcdefghijk١", false, FieldErrors{"password": weak}},
		{"accented letters are not ASCII letters", "ÀÉÎÕÜÇàéîõü1", "ÀÉÎÕÜÇàéîõü1", false, FieldErrors{"password": weak}},
		{"mismatch", "Abcdefghijk1", "Abcdefghijk2", false, FieldErrors{"password_confirmation": {MessageMismatch}}},
		{"empty confirmation", "Abcdefghijk1", "", false, FieldErrors{"password_confirmation": {MessageMismatch}}},
		{"blank is refused", "", "", false, FieldErrors{"password": {MessageBlank}}},
		{"whitespace only is weak", strings.Repeat(" ", 12), strings.Repeat(" ", 12), false, FieldErrors{"password": weak}},
		{"NUL is refused", "Abcdefghijk1\x00", "Abcdefghijk1\x00", false, FieldErrors{"password": {MessageInvalid}}},
		{"OIDC accounts skip the strength rules", "short", "short", true, FieldErrors{}},
		{"OIDC accounts keep the byte limit", strings.Repeat("x", 73), strings.Repeat("x", 73), true, FieldErrors{"password": {MessageTooLong}}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := NewPasswordErrors(c.password, c.confirmation, c.oidc)
			if !reflect.DeepEqual(got, c.want) {
				t.Fatalf("got %v want %v", got, c.want)
			}
		})
	}
}

func TestNamesAreBlankOnlyWhenEveryCharacterIsUnicodeWhitespace(t *testing.T) {
	for _, blank := range []string{"", "   ", "\t\n", "\u00a0\u3000", "\u0085", "\u2028"} {
		if got := NameErrors(blank); !reflect.DeepEqual(got, FieldErrors{"name": {MessageBlank}}) {
			t.Fatalf("%q: %v", blank, got)
		}
	}
	for _, kept := range []string{"\u200b", "Zoë 📚 ✨", "  Zoë  ", "a\x00b", "\ufeff"} {
		if got := NameErrors(kept); len(got) != 0 {
			t.Fatalf("%q: %v", kept, got)
		}
	}
}

func TestUsernamesMustBeLowercaseASCII(t *testing.T) {
	if got := UsernameErrors("reader_2"); len(got) != 0 {
		t.Fatalf("%v", got)
	}
	if got := UsernameErrors("Bad Name"); !reflect.DeepEqual(got, FieldErrors{"username": {MessageUsernameShape}}) {
		t.Fatalf("%v", got)
	}
	if got := UsernameErrors(""); !reflect.DeepEqual(got, FieldErrors{"username": {MessageBlank, MessageUsernameShape}}) {
		t.Fatalf("%v", got)
	}
}

func TestNewPasswordsAreHashedLikeRailsProduction(t *testing.T) {
	digest, err := HashPassword("Abcdefghijk1")
	if err != nil {
		t.Fatal(err)
	}
	cost, err := bcrypt.Cost([]byte(digest))
	if err != nil || cost != 12 || !strings.HasPrefix(digest, "$2a$12$") {
		t.Fatalf("digest %.7s cost %d", digest, cost)
	}
	if matches, err := PasswordMatches(digest, "Abcdefghijk1"); err != nil || !matches {
		t.Fatal("the new digest does not verify")
	}
}

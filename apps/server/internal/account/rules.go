package account

import (
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"

	"golang.org/x/crypto/bcrypt"
)

const (
	MinPasswordCharacters = 12
	MaxPasswordBytes      = 72
	PasswordCost          = 12

	MessageBlank         = "can't be blank"
	MessageInvalid       = "is invalid"
	MessageTooLong       = "is too long"
	MessageTooShort      = "is too short (minimum is 12 characters)"
	MessageWeak          = "must include at least one lowercase letter, one uppercase letter, and one number"
	MessageMismatch      = "doesn't match Password"
	MessageIncorrect     = "is incorrect"
	MessageTaken         = "has already been taken"
	MessageUsernameShape = "only allows lowercase letters, numbers, and underscores"
)

var usernameShape = regexp.MustCompile(`^[a-z0-9_]+$`)

type FieldErrors map[string][]string

func (e FieldErrors) Add(field, message string) {
	e[field] = append(e[field], message)
}

func (e FieldErrors) Merge(other FieldErrors) {
	for field, messages := range other {
		e[field] = append(e[field], messages...)
	}
}

func Blank(text string) bool {
	return strings.TrimFunc(text, unicode.IsSpace) == ""
}

func NameErrors(name string) FieldErrors {
	found := FieldErrors{}
	if Blank(name) {
		found.Add("name", MessageBlank)
	}
	return found
}

func UsernameErrors(username string) FieldErrors {
	found := FieldErrors{}
	if Blank(username) {
		found.Add("username", MessageBlank)
	}
	if !usernameShape.MatchString(username) {
		found.Add("username", MessageUsernameShape)
	}
	return found
}

func NewPasswordErrors(password, confirmation string, oidcLinked bool) FieldErrors {
	found := FieldErrors{}
	if password != confirmation {
		found.Add("password_confirmation", MessageMismatch)
	}
	switch {
	case password == "":
		found.Add("password", MessageBlank)
		return found
	case strings.ContainsRune(password, 0):
		found.Add("password", MessageInvalid)
		return found
	}
	if len(password) > MaxPasswordBytes {
		found.Add("password", MessageTooLong)
	}
	if oidcLinked {
		return found
	}
	if utf8.RuneCountInString(password) < MinPasswordCharacters {
		found.Add("password", MessageTooShort)
	}
	if !strongPassword(password) {
		found.Add("password", MessageWeak)
	}
	return found
}

func strongPassword(password string) bool {
	if strings.ContainsRune(password, '\n') {
		return false
	}
	return strings.ContainsFunc(password, isASCIILower) && strings.ContainsFunc(password, isASCIIUpper) && strings.ContainsFunc(password, isASCIIDigit)
}

func isASCIILower(r rune) bool { return r >= 'a' && r <= 'z' }
func isASCIIUpper(r rune) bool { return r >= 'A' && r <= 'Z' }
func isASCIIDigit(r rune) bool { return r >= '0' && r <= '9' }

func HashPassword(password string) (string, error) {
	digest, err := bcrypt.GenerateFromPassword([]byte(password), PasswordCost)
	return string(digest), err
}

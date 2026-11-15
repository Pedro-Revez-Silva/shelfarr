package gohttp

import (
	"errors"
	"io"
	"strings"
	"unicode/utf8"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/safeopen"
)

const maxSecretBytes = 4096

var (
	ErrSecretMissing    = errors.New("secret key base is not configured")
	ErrSecretAmbiguous  = errors.New("secret key base is configured twice")
	ErrSecretUnreadable = errors.New("secret key base file is unusable")
	ErrMasterKeyMode    = errors.New("credentials master key mode is not supported")
)

type Environment func(string) string

func readSecretFile(path string) (string, error) {
	file, err := safeopen.Regular(path)
	if err != nil {
		return "", ErrSecretUnreadable
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maxSecretBytes+1))
	if err != nil || len(data) > maxSecretBytes || !utf8.Valid(data) {
		return "", ErrSecretUnreadable
	}
	return string(data), nil
}

func ResolveSecretKeyBase(environment Environment, persistedFile string) (string, error) {
	inline, file := environment("SECRET_KEY_BASE"), environment("SECRET_KEY_BASE_FILE")
	sources := 0
	for _, present := range []bool{inline != "", file != "", persistedFile != ""} {
		if present {
			sources++
		}
	}
	switch {
	case sources > 1:
		return "", ErrSecretAmbiguous
	case inline != "":
		return inline, nil
	case file != "":
		text, err := readSecretFile(file)
		if err != nil {
			return "", err
		}
		return strings.TrimSuffix(strings.TrimSuffix(text, "\n"), "\r"), nil
	case persistedFile != "":
		text, err := readSecretFile(persistedFile)
		if err != nil {
			return "", err
		}
		return strings.TrimRight(text, "\n"), nil
	case environment("RAILS_MASTER_KEY") != "" || environment("RAILS_MASTER_KEY_FILE") != "":
		return "", ErrMasterKeyMode
	}
	return "", ErrSecretMissing
}

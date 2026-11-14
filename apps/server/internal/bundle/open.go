package bundle

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
)

const (
	MaxManifestBytes    = 1 << 20
	MaxExpectedBytes    = 16 << 20
	MaxCredentialsBytes = 64 << 10
	MaxDatabaseBytes    = 256 << 20
	MaxFileBytes        = 512 << 20
	MaxEntries          = 4096
)

type Error struct {
	Code    string
	Subject string
}

func (e *Error) Error() string {
	if e.Subject == "" {
		return "bundle: " + e.Code
	}
	return "bundle: " + e.Code + ": " + e.Subject
}

func fail(code, subject string) error {
	return &Error{Code: code, Subject: subject}
}

func IsCode(err error, code string) bool {
	var typed *Error
	return errors.As(err, &typed) && typed.Code == code
}

type Bundle struct {
	Dir         string
	Manifest    Manifest
	Identity    IdentityVectors
	Assets      LibraryAssets
	Accounts    Accounts
	Encryption  Encryption
	Responses   Responses
	Credentials Credentials
}

func (b *Bundle) DatabasePath() string {
	return filepath.Join(b.Dir, filepath.FromSlash(b.Manifest.Database.Path))
}

func Open(ctx context.Context, dir string) (*Bundle, error) {
	absolute, err := filepath.Abs(dir)
	if err != nil {
		return nil, fail("path", "")
	}
	info, err := os.Lstat(absolute)
	if err != nil || !info.IsDir() {
		return nil, fail("not-a-directory", "")
	}
	opened := &Bundle{Dir: absolute}
	if err := readJSON(filepath.Join(absolute, "manifest.json"), MaxManifestBytes, &opened.Manifest); err != nil {
		return nil, relabel(err, "manifest.json")
	}
	if err := opened.validateManifest(); err != nil {
		return nil, err
	}
	if err := opened.requirePrivateSecrets(); err != nil {
		return nil, err
	}
	if err := opened.Verify(ctx); err != nil {
		return nil, err
	}
	return opened, opened.loadDocuments()
}

func relabel(err error, label string) error {
	var typed *Error
	if errors.As(err, &typed) && typed.Subject == "" {
		return fail(typed.Code, label)
	}
	return err
}

func readJSON(path string, limit int64, target any) error {
	file, err := os.Open(path)
	if err != nil {
		return fail("unreadable", "")
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return fail("unreadable", "")
	}
	if int64(len(data)) > limit {
		return fail("too-large", "")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return fail("malformed", "")
	}
	if decoder.More() {
		return fail("malformed", "")
	}
	return nil
}

var internalPrefixes = []string{"db/", "expected/", "secrets/"}

func (b *Bundle) validateManifest() error {
	manifest := b.Manifest
	if manifest.FixtureFormat != SupportedFormat {
		return fail("unsupported-format", "manifest.json")
	}
	if manifest.Origin == "" || manifest.Schema.Revision == "" || manifest.Coverage.Digest == "" || len(manifest.Files) == 0 {
		return fail("incomplete-manifest", "manifest.json")
	}
	if len(manifest.Files) > MaxEntries {
		return fail("too-many-entries", "manifest.json")
	}
	for name := range manifest.Files {
		if !cleanRelative(name) || !hasAnyPrefix(name, internalPrefixes) {
			return fail("unsafe-path", "manifest.json")
		}
	}
	if !cleanRelative(manifest.Database.Path) || manifest.Files[manifest.Database.Path].SHA256 == "" {
		return fail("unsafe-path", "manifest.json")
	}
	if !filepath.IsAbs(manifest.MediaRoot) || filepath.Clean(manifest.MediaRoot) != manifest.MediaRoot {
		return fail("unsafe-path", "manifest.json")
	}
	entries := 0
	for _, tree := range manifest.ExternalTrees {
		if !filepath.IsAbs(tree.Root) || filepath.Clean(tree.Root) != tree.Root {
			return fail("unsafe-path", "manifest.json")
		}
		entries += len(tree.Files) + len(tree.Symlinks)
		for name := range tree.Files {
			if !cleanRelative(name) {
				return fail("unsafe-path", "manifest.json")
			}
		}
		for name := range tree.Symlinks {
			if !cleanRelative(name) {
				return fail("unsafe-path", "manifest.json")
			}
		}
	}
	if entries > MaxEntries {
		return fail("too-many-entries", "manifest.json")
	}
	return nil
}

func cleanRelative(name string) bool {
	if name == "" || strings.HasPrefix(name, "/") || strings.ContainsRune(name, 0) {
		return false
	}
	cleaned := filepath.ToSlash(filepath.Clean(name))
	return cleaned == name && cleaned != "." && !strings.HasPrefix(cleaned, "../") && cleaned != ".."
}

func hasAnyPrefix(name string, prefixes []string) bool {
	for _, prefix := range prefixes {
		if strings.HasPrefix(name, prefix) {
			return true
		}
	}
	return false
}

func (b *Bundle) requirePrivateSecrets() error {
	for _, path := range []string{filepath.Join(b.Dir, "secrets"), filepath.Join(b.Dir, "secrets", "credentials.json")} {
		info, err := os.Lstat(path)
		if err != nil {
			return fail("missing", "secrets")
		}
		if info.Mode().Perm()&0o077 != 0 {
			return fail("secrets-not-private", "secrets")
		}
	}
	return nil
}

func (b *Bundle) loadDocuments() error {
	documents := []struct {
		name   string
		limit  int64
		target any
	}{
		{"expected/identity-vectors.json", MaxExpectedBytes, &b.Identity},
		{"expected/library-assets.json", MaxExpectedBytes, &b.Assets},
		{"expected/accounts.json", MaxExpectedBytes, &b.Accounts},
		{"expected/encryption.json", MaxExpectedBytes, &b.Encryption},
		{"expected/responses.json", MaxExpectedBytes, &b.Responses},
		{"secrets/credentials.json", MaxCredentialsBytes, &b.Credentials},
	}
	for _, document := range documents {
		if _, listed := b.Manifest.Files[document.name]; !listed {
			return fail("missing", document.name)
		}
		if err := readJSON(filepath.Join(b.Dir, filepath.FromSlash(document.name)), document.limit, document.target); err != nil {
			return relabel(err, document.name)
		}
	}
	return nil
}

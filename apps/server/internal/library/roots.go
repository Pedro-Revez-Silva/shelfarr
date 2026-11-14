package library

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

var (
	ErrUnsupportedPath = errors.New("unsupported library path form")
	ErrUnsupportedRoot = errors.New("output root setting is not available as an explicit string")
	ErrReference       = errors.New("reference imports are not supported")
)

type Settings interface {
	StringSetting(ctx context.Context, key string) (string, bool, error)
}

var outputRootKeys = []string{"audiobook_output_path", "ebook_output_path", "comicbook_output_path"}

func OutputRoots(ctx context.Context, settings Settings) ([]string, error) {
	var roots []string
	seen := map[string]bool{}
	for _, key := range outputRootKeys {
		value, present, err := settings.StringSetting(ctx, key)
		if err != nil {
			return nil, err
		}
		if !present {
			return nil, ErrUnsupportedRoot
		}
		if strings.TrimSpace(value) == "" {
			continue
		}
		root, ok, err := canonicalRoot(value)
		if err != nil {
			return nil, err
		}
		if ok && !seen[root] {
			seen[root] = true
			roots = append(roots, root)
		}
	}
	return roots, nil
}

func expand(path string) (string, error) {
	if strings.HasPrefix(path, "~") || !strings.HasPrefix(path, "/") || strings.HasPrefix(path, "//") || strings.ContainsRune(path, 0) {
		return "", ErrUnsupportedPath
	}
	return filepath.Clean(path), nil
}

func canonicalRoot(configured string) (string, bool, error) {
	expanded, err := expand(configured)
	if err != nil {
		return "", false, err
	}
	resolved, err := filepath.EvalSymlinks(expanded)
	if err != nil || resolved == "/" {
		return "", false, nil
	}
	info, err := os.Lstat(resolved)
	if err != nil || !info.IsDir() {
		return "", false, nil
	}
	return resolved, true, nil
}

func contained(path, root string) bool {
	if path == root {
		return true
	}
	prefix := root
	if !strings.HasSuffix(prefix, "/") {
		prefix += "/"
	}
	return strings.HasPrefix(path, prefix)
}

func containingRoot(path string, roots []string) (string, bool) {
	best := ""
	found := false
	for _, root := range roots {
		if contained(path, root) && (!found || len(root) > len(best)) {
			best, found = root, true
		}
	}
	return best, found
}

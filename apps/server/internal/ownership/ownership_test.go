//go:build unix

package ownership

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestOnlyOneOwnerAtATimeAndTheLockIsReleasable(t *testing.T) {
	path := filepath.Join(t.TempDir(), "auth.lock")
	first, err := Acquire(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Acquire(path); !errors.Is(err, ErrHeld) {
		t.Fatalf("second owner: %v", err)
	}
	if err := first.Release(); err != nil {
		t.Fatal(err)
	}
	second, err := Acquire(path)
	if err != nil {
		t.Fatalf("lock was not released: %v", err)
	}
	second.Release()
}

func TestRelativeAndSymbolicLinkPathsAreRefused(t *testing.T) {
	if _, err := Acquire("relative.lock"); !errors.Is(err, ErrPath) {
		t.Fatalf("relative path: %v", err)
	}
	directory := t.TempDir()
	target := filepath.Join(directory, "target")
	if err := os.WriteFile(target, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(directory, "link.lock")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if _, err := Acquire(link); !errors.Is(err, ErrPath) {
		t.Fatalf("symbolic link: %v", err)
	}
}

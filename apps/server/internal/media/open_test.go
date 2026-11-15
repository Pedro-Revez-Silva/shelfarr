//go:build linux

package media

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func library(t *testing.T) (root, outside string) {
	t.Helper()
	base, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	root, outside = filepath.Join(base, "library"), filepath.Join(base, "outside")
	for _, directory := range []string{filepath.Join(root, "nested"), outside} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	return root, outside
}

func write(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestOpenPinnedReadsRegularFilesBeneathTheRoot(t *testing.T) {
	root, _ := library(t)
	write(t, filepath.Join(root, "nested", "book.epub"), "content")
	file, err := OpenPinned(root, filepath.Join(root, "nested", "book.epub"))
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	data, _ := io.ReadAll(file)
	if string(data) != "content" {
		t.Fatalf("%q", data)
	}
}

func TestOpenPinnedRefusesEverythingThatIsNotAPlainFileBeneathTheRoot(t *testing.T) {
	root, outside := library(t)
	write(t, filepath.Join(outside, "secret.txt"), "secret")
	write(t, filepath.Join(root, "real.epub"), "real")
	if err := os.Symlink(filepath.Join(outside, "secret.txt"), filepath.Join(root, "link-out.epub")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(root, "real.epub"), filepath.Join(root, "link-in.epub")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "dir-link")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("real.epub", filepath.Join(root, "link-relative.epub")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("nested", filepath.Join(root, "nested-link")); err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(root, "nested", "inner.epub"), "inner")
	if err := syscall.Mkfifo(filepath.Join(root, "pipe.epub"), 0o600); err != nil {
		t.Fatal(err)
	}
	cases := map[string]struct {
		path string
		want error
	}{
		"link to a file outside":     {filepath.Join(root, "link-out.epub"), ErrUnavailable},
		"link to a file inside":      {filepath.Join(root, "link-in.epub"), ErrUnavailable},
		"link in a directory chain":  {filepath.Join(root, "dir-link", "secret.txt"), ErrUnavailable},
		"relative link to a file":    {filepath.Join(root, "link-relative.epub"), ErrUnavailable},
		"relative link directory":    {filepath.Join(root, "nested-link", "inner.epub"), ErrUnavailable},
		"fifo":                       {filepath.Join(root, "pipe.epub"), ErrNotRegularFile},
		"directory":                  {filepath.Join(root, "nested"), ErrNotRegularFile},
		"missing":                    {filepath.Join(root, "absent.epub"), ErrUnavailable},
		"traversal":                  {filepath.Join(root, "..", "outside", "secret.txt"), ErrOutsideRoot},
		"sibling sharing the prefix": {root + "-sibling/real.epub", ErrOutsideRoot},
		"the root itself":            {root, ErrOutsideRoot},
		"absolute path outside":      {filepath.Join(outside, "secret.txt"), ErrOutsideRoot},
		"dotdot escaping mid-path":   {root + "/nested/../../outside/secret.txt", ErrUnavailable},
	}
	for name, attempt := range cases {
		file, err := OpenPinned(root, attempt.path)
		if file != nil {
			file.Close()
			t.Errorf("%s: a file was opened", name)
			continue
		}
		if !errors.Is(err, attempt.want) {
			t.Errorf("%s: got %v want %v", name, err, attempt.want)
		}
	}
}

func TestAReplacementIsOpenedAsTheReplacementNeverAsTheOldFile(t *testing.T) {
	root, outside := library(t)
	path := filepath.Join(root, "book.epub")
	write(t, path, "old")
	write(t, filepath.Join(outside, "evil"), "evil")
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(outside, "evil"), path); err != nil {
		t.Fatal(err)
	}
	if file, err := OpenPinned(root, path); err == nil {
		file.Close()
		t.Fatal("a symbolic link that replaced the file was followed")
	}
}

func TestConfinedOpensAreAvailableOnThisKernel(t *testing.T) {
	if !ConfinedOpenSupported() {
		t.Fatal("openat2 is required")
	}
}

//go:build linux

package bookfile

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/ziptest"
)

func epubEntries() []ziptest.Entry {
	return []ziptest.Entry{
		ziptest.Raw("mimetype", []byte(epubMediaType), ziptest.Stored),
		ziptest.Raw("META-INF/container.xml", []byte(`<container/>`), ziptest.Deflated),
		ziptest.Raw("OEBPS/chapter.xhtml", []byte(`<html/>`), ziptest.Deflated),
	}
}

func TestCheckEPUBAcceptsOnlyAnOCFContainer(t *testing.T) {
	valid := epubEntries()
	compressed := epubEntries()
	compressed[0].Method = ziptest.Deflated
	late := []ziptest.Entry{valid[1], valid[0], valid[2]}
	wrongType := epubEntries()
	wrongType[0] = ziptest.Raw("mimetype", []byte("application/epub+zap"), ziptest.Stored)
	noContainer := []ziptest.Entry{valid[0], valid[2]}
	containerFolder := []ziptest.Entry{valid[0], ziptest.Raw("META-INF/container.xml/", nil, ziptest.Stored)}
	badCRC := epubEntries()
	badCRC[0].Central.CRC = ziptest.U32(1)
	badCRC[0].Local.CRC = ziptest.U32(1)
	built := ziptest.Build(valid, ziptest.End{})
	cases := []struct {
		name  string
		body  []byte
		valid bool
	}{
		{"valid", built, true},
		{"compressed mimetype", ziptest.Build(compressed, ziptest.End{}), false},
		{"mimetype not first", ziptest.Build(late, ziptest.End{}), false},
		{"another media type", ziptest.Build(wrongType, ziptest.End{}), false},
		{"no container", ziptest.Build(noContainer, ziptest.End{}), false},
		{"container is a folder", ziptest.Build(containerFolder, ziptest.End{}), false},
		{"mimetype checksum disagrees", ziptest.Build(badCRC, ziptest.End{}), false},
		{"truncated", built[:len(built)-10], false},
		{"html", []byte("<!doctype html><html></html>"), false},
		{"empty", nil, false},
	}
	for _, entry := range cases {
		err := CheckEPUB(context.Background(), bytes.NewReader(entry.body), int64(len(entry.body)))
		if (err == nil) != entry.valid || (err != nil && !errors.Is(err, ErrNotEPUB)) {
			t.Errorf("%s: %v", entry.name, err)
		}
	}
}

func privateWorkdir(t *testing.T) (string, string) {
	t.Helper()
	workdir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	os.Chmod(workdir, 0o700)
	library := filepath.Join(workdir, "library")
	if err := os.Mkdir(library, 0o755); err != nil {
		t.Fatal(err)
	}
	return workdir, library
}

func TestOpenRootAcceptsOnlyAPrivateDirectoryInsideTheWorkdir(t *testing.T) {
	workdir, library := privateWorkdir(t)
	outside := t.TempDir()
	os.Symlink(library, filepath.Join(workdir, "linked"))
	os.WriteFile(filepath.Join(workdir, "file"), nil, 0o600)
	os.Mkdir(filepath.Join(workdir, "open"), 0o777)
	os.Chmod(filepath.Join(workdir, "open"), 0o777)
	for _, path := range []string{outside, workdir, library + "/", filepath.Join(workdir, "linked"), filepath.Join(workdir, "file"),
		filepath.Join(workdir, "open"), filepath.Join(workdir, "absent"), "library", workdir + "/../" + filepath.Base(workdir) + "/library"} {
		if root, err := OpenRoot(workdir, path); !errors.Is(err, ErrRootRefused) {
			if root != nil {
				root.Close()
			}
			t.Errorf("%s: %v", path, err)
		}
	}
	root, err := OpenRoot(workdir, library)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	if err := root.Unchanged(); err != nil {
		t.Fatal(err)
	}
	os.Rename(library, library+".old")
	os.Mkdir(library, 0o755)
	if err := root.Unchanged(); !errors.Is(err, ErrRootChanged) {
		t.Errorf("a replaced root: %v", err)
	}
}

func TestPublishNeverReplacesAndRemovesOnlyItsOwnFile(t *testing.T) {
	workdir, library := privateWorkdir(t)
	root, err := OpenRoot(workdir, library)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	staged, err := root.Stage()
	if err != nil {
		t.Fatal(err)
	}
	defer staged.Close()
	staged.File.Write([]byte("book"))
	if err := staged.Seal(); err != nil || staged.Size != 4 {
		t.Fatalf("seal: %v %d", err, staged.Size)
	}
	if entries, _ := os.ReadDir(library); len(entries) != 0 {
		t.Fatalf("staging is visible: %v", entries)
	}
	placement := Placement{Folders: []string{"shelfarr-gutenberg", "book-1"}, Name: "gutenberg-1.epub"}
	if identity, present, err := root.Identify(placement); present || err != nil || identity != (Identity{}) {
		t.Fatalf("identify before publication: %v %v", present, err)
	}
	if err := root.Publish(staged, placement); err != nil {
		t.Fatal(err)
	}
	final := filepath.Join(library, placement.Relative())
	if data, _ := os.ReadFile(final); string(data) != "book" {
		t.Fatalf("published %q", data)
	}
	if identity, present, err := root.Identify(placement); !present || err != nil || identity != staged.Identity {
		t.Fatalf("identify after publication: %v %v %v", identity, present, err)
	}
	if err := root.Publish(staged, placement); !errors.Is(err, ErrExists) {
		t.Errorf("a second publication: %v", err)
	}
	os.Remove(final)
	os.WriteFile(final, []byte("foreign"), 0o644)
	if removed, err := root.Remove(placement, staged.Identity); removed || err != nil {
		t.Errorf("removed a foreign file: %v %v", removed, err)
	}
	if data, _ := os.ReadFile(final); string(data) != "foreign" {
		t.Errorf("the foreign file changed")
	}
	os.Remove(final)
	other, _ := root.Stage()
	defer other.Close()
	other.Seal()
	if err := root.Publish(other, placement); err != nil {
		t.Fatal(err)
	}
	if removed, err := root.Remove(placement, other.Identity); !removed || err != nil {
		t.Errorf("own file: %v %v", removed, err)
	}
	if _, err := os.Lstat(filepath.Dir(final)); !os.IsNotExist(err) {
		t.Errorf("the emptied book folder remains: %v", err)
	}
}

func TestPublishRefusesALinkedFolder(t *testing.T) {
	workdir, library := privateWorkdir(t)
	outside := t.TempDir()
	os.Symlink(outside, filepath.Join(library, "shelfarr-gutenberg"))
	root, err := OpenRoot(workdir, library)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	staged, _ := root.Stage()
	defer staged.Close()
	staged.Seal()
	if err := root.Publish(staged, Placement{Folders: []string{"shelfarr-gutenberg", "book-1"}, Name: "b.epub"}); !errors.Is(err, ErrUnsafe) {
		t.Errorf("publication through a link: %v", err)
	}
	if entries, _ := os.ReadDir(outside); len(entries) != 0 {
		t.Errorf("wrote outside the library: %v", entries)
	}
}

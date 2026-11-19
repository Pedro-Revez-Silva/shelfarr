//go:build linux

package bookfile

import (
	"bytes"
	"context"
	"crypto/sha256"
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
		if _, err := OpenRoot(workdir, path); !errors.Is(err, ErrRootRefused) {
			t.Errorf("%s: %v", path, err)
		}
	}
}

func sealed(t *testing.T, root *Root, body string) (*Staged, Owned) {
	t.Helper()
	staged, err := root.Stage()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(staged.Close)
	staged.File.Write([]byte(body))
	if err := staged.Seal(); err != nil || staged.Size != int64(len(body)) {
		t.Fatalf("seal: %v %d", err, staged.Size)
	}
	digest := sha256.Sum256([]byte(body))
	return staged, Owned{Identity: staged.Identity, Size: staged.Size, SHA256: digest[:]}
}

func TestEveryOperationRefusesAReplacedRoot(t *testing.T) {
	workdir, library := privateWorkdir(t)
	root, err := OpenRoot(workdir, library)
	if err != nil {
		t.Fatal(err)
	}
	staged, owned := sealed(t, root, "book")
	placement := Placement{Folders: []string{"shelfarr-gutenberg", "book-1"}, Name: "gutenberg-1.epub"}
	if linked, err := root.Publish(staged, placement); !linked || err != nil {
		t.Fatal(err)
	}
	os.Rename(library, library+".old")
	os.Mkdir(library, 0o755)
	if _, err := root.Stage(); !errors.Is(err, ErrRootChanged) {
		t.Errorf("staging in a replaced root: %v", err)
	}
	if linked, err := root.Publish(staged, Placement{Folders: []string{"other"}, Name: "b.epub"}); linked || !errors.Is(err, ErrRootChanged) {
		t.Errorf("publication in a replaced root: %v %v", linked, err)
	}
	if _, _, err := root.Identify(placement); !errors.Is(err, ErrRootChanged) {
		t.Errorf("identification in a replaced root: %v", err)
	}
	if removed, err := root.Remove(placement, owned); removed || !errors.Is(err, ErrRootChanged) {
		t.Errorf("removal in a replaced root: %v %v", removed, err)
	}
	if entries, _ := os.ReadDir(library); len(entries) != 0 {
		t.Errorf("wrote into the replacement: %v", entries)
	}
}

func TestPublishNeverReplacesAndRemovesOnlyItsOwnFile(t *testing.T) {
	workdir, library := privateWorkdir(t)
	root, err := OpenRoot(workdir, library)
	if err != nil {
		t.Fatal(err)
	}
	staged, owned := sealed(t, root, "book")
	if entries, _ := os.ReadDir(library); len(entries) != 0 {
		t.Fatalf("staging is visible: %v", entries)
	}
	placement := Placement{Folders: []string{"shelfarr-gutenberg", "book-1"}, Name: "gutenberg-1.epub"}
	if identity, present, err := root.Identify(placement); present || err != nil || identity != (Identity{}) {
		t.Fatalf("identify before publication: %v %v", present, err)
	}
	if linked, err := root.Publish(staged, placement); !linked || err != nil {
		t.Fatal(err)
	}
	final := filepath.Join(library, placement.Relative())
	if data, _ := os.ReadFile(final); string(data) != "book" {
		t.Fatalf("published %q", data)
	}
	if identity, present, err := root.Identify(placement); !present || err != nil || identity != staged.Identity {
		t.Fatalf("identify after publication: %v %v %v", identity, present, err)
	}
	if linked, err := root.Publish(staged, placement); linked || !errors.Is(err, ErrExists) {
		t.Errorf("a second publication: %v %v", linked, err)
	}
	for name, claim := range map[string]Owned{
		"another size":   {Identity: owned.Identity, Size: owned.Size + 1, SHA256: owned.SHA256},
		"another digest": {Identity: owned.Identity, Size: owned.Size, SHA256: make([]byte, 32)},
		"another inode":  {Identity: Identity{Device: owned.Identity.Device, Inode: owned.Identity.Inode + 1}, Size: owned.Size, SHA256: owned.SHA256},
	} {
		if removed, err := root.Remove(placement, claim); removed || err != nil {
			t.Errorf("%s: removed %v %v", name, removed, err)
		}
	}
	os.Remove(final)
	os.WriteFile(final, []byte("book"), 0o644)
	if removed, err := root.Remove(placement, owned); removed || err != nil {
		t.Errorf("removed a foreign file with the same bytes: %v %v", removed, err)
	}
	os.Remove(final)
	if removed, err := root.Remove(placement, owned); removed || err != nil {
		t.Errorf("a missing name: %v %v", removed, err)
	}
	other, otherOwned := sealed(t, root, "other book")
	if linked, err := root.Publish(other, placement); !linked || err != nil {
		t.Fatal(err)
	}
	if removed, err := root.Remove(placement, otherOwned); !removed || err != nil {
		t.Errorf("own file: %v %v", removed, err)
	}
	if info, err := os.Lstat(filepath.Dir(final)); err != nil || !info.IsDir() {
		t.Errorf("removing the file removed its folder: %v", err)
	}
}

func TestALinkedOrOpenFolderIsNeverUsed(t *testing.T) {
	workdir, library := privateWorkdir(t)
	outside := t.TempDir()
	os.Symlink(outside, filepath.Join(library, "shelfarr-gutenberg"))
	os.Mkdir(filepath.Join(library, "open"), 0o755)
	os.Chmod(filepath.Join(library, "open"), 0o775)
	root, err := OpenRoot(workdir, library)
	if err != nil {
		t.Fatal(err)
	}
	staged, owned := sealed(t, root, "book")
	for _, folder := range []string{"shelfarr-gutenberg", "open"} {
		placement := Placement{Folders: []string{folder, "book-1"}, Name: "b.epub"}
		if linked, err := root.Publish(staged, placement); linked || !errors.Is(err, ErrUnsafe) {
			t.Errorf("%s: publication %v %v", folder, linked, err)
		}
		if removed, err := root.Remove(placement, owned); removed || !errors.Is(err, ErrUnsafe) {
			t.Errorf("%s: removal %v %v", folder, removed, err)
		}
	}
	if entries, _ := os.ReadDir(outside); len(entries) != 0 {
		t.Errorf("wrote outside the library: %v", entries)
	}
}

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

func sealed(t *testing.T, root *Root, body string) (*Staged, []byte) {
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
	return staged, digest[:]
}

func TestEveryOperationRefusesAReplacedRoot(t *testing.T) {
	workdir, library := privateWorkdir(t)
	root, err := OpenRoot(workdir, library)
	if err != nil {
		t.Fatal(err)
	}
	staged, digest := sealed(t, root, "book")
	placement := Placement{Folders: []string{"shelfarr-gutenberg", "book-1"}, Name: "gutenberg-1.epub"}
	published, err := root.Publish(staged, placement, digest)
	if !published.Linked || err != nil {
		t.Fatal(err)
	}
	os.Rename(library, library+".old")
	os.Mkdir(library, 0o755)
	if _, err := root.Stage(); !errors.Is(err, ErrRootChanged) {
		t.Errorf("staging in a replaced root: %v", err)
	}
	if again, err := root.Publish(staged, Placement{Folders: []string{"other"}, Name: "b.epub"}, digest); again.Linked || !errors.Is(err, ErrRootChanged) {
		t.Errorf("publication in a replaced root: %v %v", again, err)
	}
	if _, _, err := root.Identify(placement); !errors.Is(err, ErrRootChanged) {
		t.Errorf("identification in a replaced root: %v", err)
	}
	if err := root.Remove(placement, published.Identity); !errors.Is(err, ErrRootChanged) {
		t.Errorf("removal in a replaced root: %v", err)
	}
	if entries, _ := os.ReadDir(library); len(entries) != 0 {
		t.Errorf("wrote into the replacement: %v", entries)
	}
}

func TestPublishNeverReplacesAndAdoptsOnlyTheSameBytes(t *testing.T) {
	workdir, library := privateWorkdir(t)
	root, err := OpenRoot(workdir, library)
	if err != nil {
		t.Fatal(err)
	}
	staged, digest := sealed(t, root, "book")
	if entries, _ := os.ReadDir(library); len(entries) != 0 {
		t.Fatalf("staging is visible: %v", entries)
	}
	placement := Placement{Folders: []string{"shelfarr-gutenberg", "book-1"}, Name: "gutenberg-1.epub"}
	if identity, present, err := root.Identify(placement); present || err != nil || identity != (Identity{}) {
		t.Fatalf("identify before publication: %v %v", present, err)
	}
	published, err := root.Publish(staged, placement, digest)
	if !published.Linked || published.Identity != staged.Identity || err != nil {
		t.Fatal(err)
	}
	final := filepath.Join(library, placement.Relative())
	if data, _ := os.ReadFile(final); string(data) != "book" {
		t.Fatalf("published %q", data)
	}
	if identity, present, err := root.Identify(placement); !present || err != nil || identity != staged.Identity {
		t.Fatalf("identify after publication: %v %v %v", identity, present, err)
	}
	again, againDigest := sealed(t, root, "book")
	adopted, err := root.Publish(again, placement, againDigest)
	if adopted.Linked || adopted.Identity != staged.Identity || err != nil {
		t.Errorf("the same bytes at the name are not adopted: %+v %v", adopted, err)
	}
	other, otherDigest := sealed(t, root, "another book")
	if refused, err := root.Publish(other, placement, otherDigest); refused != (Published{}) || !errors.Is(err, ErrExists) {
		t.Errorf("different bytes at the name: %+v %v", refused, err)
	}
	if refused, err := root.Publish(again, placement, otherDigest); refused != (Published{}) || !errors.Is(err, ErrExists) {
		t.Errorf("the same size with another digest: %+v %v", refused, err)
	}
	os.Link(final, filepath.Join(library, "second-name"))
	if refused, err := root.Publish(again, placement, againDigest); refused != (Published{}) || !errors.Is(err, ErrExists) {
		t.Errorf("a file with another name is adopted: %+v %v", refused, err)
	}
	os.Remove(filepath.Join(library, "second-name"))
	if err := root.Remove(placement, other.Identity); !errors.Is(err, ErrExists) {
		t.Errorf("removed a file this process did not link: %v", err)
	}
	if data, _ := os.ReadFile(final); string(data) != "book" {
		t.Errorf("the file changed")
	}
	if err := root.Remove(placement, published.Identity); err != nil {
		t.Errorf("own file: %v", err)
	}
	if _, err := os.Lstat(final); !os.IsNotExist(err) {
		t.Errorf("own file remains: %v", err)
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
	staged, digest := sealed(t, root, "book")
	for _, folder := range []string{"shelfarr-gutenberg", "open"} {
		placement := Placement{Folders: []string{folder, "book-1"}, Name: "b.epub"}
		if published, err := root.Publish(staged, placement, digest); published.Linked || !errors.Is(err, ErrUnsafe) {
			t.Errorf("%s: publication %+v %v", folder, published, err)
		}
		if err := root.Remove(placement, staged.Identity); !errors.Is(err, ErrUnsafe) {
			t.Errorf("%s: removal %v", folder, err)
		}
	}
	if entries, _ := os.ReadDir(outside); len(entries) != 0 {
		t.Errorf("wrote outside the library: %v", entries)
	}
}

package library

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"testing"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
)

func TestRubyExtensionRules(t *testing.T) {
	cases := map[string]string{
		"a.mp3": ".mp3", "a.b.EPUB": ".EPUB", "foo.": ".", ".epub": "", "..a": "", "noext": "", "dir.d/file": "", ".a.b": ".b",
	}
	for path, want := range cases {
		if got := rubyExt(path); got != want {
			t.Errorf("rubyExt(%q) = %q, want %q", path, got, want)
		}
	}
}

func TestNaturalOrdering(t *testing.T) {
	paths := []string{"/x/Chapter10.mp3", "/x/chapter2.mp3", "/x/Chapter1.mp3", "/x/1a.mp3", "/x/a1.mp3", "/x/a.mp3", "/x/a100.mp3", "/x/a99999999999999999999.mp3"}
	sortNatural(paths)
	want := []string{"/x/1a.mp3", "/x/a1.mp3", "/x/a100.mp3", "/x/a99999999999999999999.mp3", "/x/a.mp3", "/x/Chapter1.mp3", "/x/chapter2.mp3", "/x/Chapter10.mp3"}
	if !reflect.DeepEqual(paths, want) {
		t.Fatalf("order = %v", paths)
	}
}

func TestContainmentDoesNotMatchSiblingPrefixes(t *testing.T) {
	roots := []string{"/lib", "/lib/deeper"}
	cases := map[string]string{"/lib/a": "/lib", "/lib/deeper/a": "/lib/deeper", "/lib": "/lib", "/lib/deeper": "/lib/deeper"}
	for path, want := range cases {
		if got, ok := containingRoot(path, roots); !ok || got != want {
			t.Errorf("%s -> %q, %v", path, got, ok)
		}
	}
	for _, path := range []string{"/lib2/a", "/library", "/", "/other"} {
		if _, ok := containingRoot(path, roots); ok {
			t.Errorf("%s contained", path)
		}
	}
}

func TestExpandRefusesUnmodelledForms(t *testing.T) {
	for _, path := range []string{"~/x", "relative/x", "//double/x", "", "/a\x00b"} {
		if _, err := expand(path); !errors.Is(err, ErrUnsupportedPath) {
			t.Errorf("%q: %v", path, err)
		}
	}
	if got, err := expand("/a//b/./c/../d/"); err != nil || got != "/a/b/d" {
		t.Errorf("expand = %q, %v", got, err)
	}
}

type fixedSettings map[string]string

func (s fixedSettings) StringSetting(_ context.Context, key string) (string, bool, error) {
	value, present := s[key]
	return value, present, nil
}

func TestOutputRoots(t *testing.T) {
	directory := t.TempDir()
	real := filepath.Join(directory, "real")
	file := filepath.Join(directory, "file")
	if err := os.Mkdir(real, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(directory, "link")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	roots, err := OutputRoots(context.Background(), fixedSettings{"audiobook_output_path": link, "ebook_output_path": real, "comicbook_output_path": file})
	if err != nil || !reflect.DeepEqual(roots, []string{real}) {
		t.Fatalf("roots = %v, %v", roots, err)
	}
	roots, err = OutputRoots(context.Background(), fixedSettings{"audiobook_output_path": "/", "ebook_output_path": "  ", "comicbook_output_path": filepath.Join(directory, "absent")})
	if err != nil || len(roots) != 0 {
		t.Fatalf("degenerate roots = %v, %v", roots, err)
	}
	if _, err := OutputRoots(context.Background(), fixedSettings{"audiobook_output_path": real}); !errors.Is(err, ErrUnsupportedRoot) {
		t.Fatalf("missing setting: %v", err)
	}
	if _, err := OutputRoots(context.Background(), fixedSettings{"audiobook_output_path": "relative", "ebook_output_path": real, "comicbook_output_path": real}); !errors.Is(err, ErrUnsupportedPath) {
		t.Fatalf("relative root: %v", err)
	}
}

type workspace struct {
	root string
	t    *testing.T
}

func newWorkspace(t *testing.T) workspace {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return workspace{root: root, t: t}
}

func (w workspace) write(relative string) string {
	w.t.Helper()
	path := filepath.Join(w.root, relative)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		w.t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(relative), 0o644); err != nil {
		w.t.Fatal(err)
	}
	return path
}

func audiobook(path string) store.Book {
	return store.Book{ID: 7, Title: "t", BookType: store.BookTypeAudiobook, FilePath: sql.NullString{String: path, Valid: true}}
}

func ebook(path string) store.Book {
	book := audiobook(path)
	book.BookType = store.BookTypeEbook
	return book
}

func filenames(listing Listing) []string {
	names := []string{}
	for _, asset := range listing.Assets {
		names = append(names, asset.Filename+"@"+strconv.Itoa(asset.Position))
	}
	return names
}

func TestListDirectoryIsNaturalSortedAndSkipsNonMedia(t *testing.T) {
	space := newWorkspace(t)
	for _, name := range []string{"B/Part10.mp3", "B/Part2.MP3", "B/Part1.mp3", "B/cover.jpg", "B/.hidden.mp3", "B/sub/Part3.mp3", "B/sub/readme.txt"} {
		space.write(name)
	}
	listing, err := Lister{Roots: []string{space.root}}.List(audiobook(filepath.Join(space.root, "B")), filepath.Join(space.root, "B"))
	if err != nil || listing.Unavailable {
		t.Fatalf("%v %v", listing, err)
	}
	want := []string{"Part1.mp3@0", "Part2.MP3@1", "Part10.mp3@2", "Part3.mp3@3"}
	if got := filenames(listing); !reflect.DeepEqual(got, want) {
		t.Fatalf("assets = %v", got)
	}
	if listing.Assets[1].MediaType != "audio/mpeg" || listing.Assets[1].Format != "mp3" {
		t.Fatalf("asset = %+v", listing.Assets[1])
	}
}

func TestListEbookOnlyOffersEpubForms(t *testing.T) {
	space := newWorkspace(t)
	for _, name := range []string{"E/book.kepub", "E/book.pdf", "E/book.cbz", "E/audio.mp3"} {
		space.write(name)
	}
	path := filepath.Join(space.root, "E")
	listing, err := Lister{Roots: []string{space.root}}.List(ebook(path), path)
	if err != nil {
		t.Fatal(err)
	}
	if got := filenames(listing); !reflect.DeepEqual(got, []string{"book.kepub@0"}) || listing.Assets[0].Format != "epub" || listing.Assets[0].MediaType != "application/epub+zip" {
		t.Fatalf("assets = %v %+v", got, listing.Assets)
	}
}

func TestListUnavailableOutcomes(t *testing.T) {
	space := newWorkspace(t)
	outside := newWorkspace(t)
	inside := space.write("in.epub")
	elsewhere := outside.write("out.epub")
	lister := Lister{Roots: []string{space.root}}
	for name, path := range map[string]string{
		"missing": filepath.Join(space.root, "missing.epub"), "outside": elsewhere, "library root": space.root, "blank": " ",
	} {
		listing, err := lister.List(ebook(path), path)
		if err != nil || !listing.Unavailable || len(listing.Assets) != 0 {
			t.Errorf("%s: %+v %v", name, listing, err)
		}
	}
	if listing, err := lister.List(ebook(inside), inside); err != nil || listing.Unavailable || len(listing.Assets) != 1 {
		t.Errorf("control: %+v %v", listing, err)
	}
}

func TestListDirectoryLimits(t *testing.T) {
	space := newWorkspace(t)
	deep := "D"
	for level := 0; level <= maxDepth+1; level++ {
		deep = filepath.Join(deep, "d")
	}
	space.write(filepath.Join(deep, "x.mp3"))
	path := filepath.Join(space.root, "D")
	if listing, err := (Lister{Roots: []string{space.root}}).List(audiobook(path), path); err != nil || !listing.Unavailable {
		t.Errorf("deep tree: %+v %v", listing, err)
	}
	crowded := filepath.Join(space.root, "C")
	if err := os.Mkdir(crowded, 0o755); err != nil {
		t.Fatal(err)
	}
	for index := 0; index <= maxEntries; index++ {
		if err := os.WriteFile(filepath.Join(crowded, strconv.Itoa(index)+".txt"), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if listing, err := (Lister{Roots: []string{space.root}}).List(audiobook(crowded), crowded); err != nil || !listing.Unavailable {
		t.Errorf("crowded tree: %+v %v", listing, err)
	}
}

func TestListRefusesReferenceSymlinks(t *testing.T) {
	space := newWorkspace(t)
	target := space.write("target.epub")
	link := filepath.Join(space.root, "link.epub")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if _, err := (Lister{Roots: []string{space.root}}).List(ebook(link), link); !errors.Is(err, ErrReference) {
		t.Fatalf("direct reference: %v", err)
	}
	folder := filepath.Join(space.root, "F")
	if err := os.Mkdir(folder, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(folder, "track.mp3")); err != nil {
		t.Fatal(err)
	}
	if _, err := (Lister{Roots: []string{space.root}}).List(audiobook(folder), folder); !errors.Is(err, ErrReference) {
		t.Fatalf("nested reference: %v", err)
	}
}

func TestIdentityUsesStoredAndCanonicalPath(t *testing.T) {
	space := newWorkspace(t)
	real := space.write("real/Plain.epub")
	if err := os.Symlink(filepath.Dir(real), filepath.Join(space.root, "alias")); err != nil {
		t.Fatal(err)
	}
	lister := Lister{Roots: []string{space.root}}
	direct, err := lister.List(ebook(real), real)
	if err != nil {
		t.Fatal(err)
	}
	stored := filepath.Join(space.root, "alias", ".", "x", "..", "Plain.epub")
	indirect, err := lister.List(ebook(stored), stored)
	if err != nil {
		t.Fatal(err)
	}
	if len(direct.Assets) != 1 || len(indirect.Assets) != 1 {
		t.Fatalf("%+v %+v", direct, indirect)
	}
	if direct.Assets[0].Path != indirect.Assets[0].Path || direct.Assets[0].ID == indirect.Assets[0].ID {
		t.Fatalf("same canonical path must keep distinct ids per stored path: %s %s", direct.Assets[0].ID, indirect.Assets[0].ID)
	}
}

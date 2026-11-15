package library

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/assetid"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/ziptest"
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
	listing, err := Lister{Roots: []string{space.root}}.List(context.Background(), audiobook(filepath.Join(space.root, "B")), filepath.Join(space.root, "B"))
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
	listing, err := Lister{Roots: []string{space.root}}.List(context.Background(), ebook(path), path)
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
		listing, err := lister.List(context.Background(), ebook(path), path)
		if err != nil || !listing.Unavailable || len(listing.Assets) != 0 {
			t.Errorf("%s: %+v %v", name, listing, err)
		}
	}
	if listing, err := lister.List(context.Background(), ebook(inside), inside); err != nil || listing.Unavailable || len(listing.Assets) != 1 {
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
	if listing, err := (Lister{Roots: []string{space.root}}).List(context.Background(), audiobook(path), path); err != nil || !listing.Unavailable {
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
	if listing, err := (Lister{Roots: []string{space.root}}).List(context.Background(), audiobook(crowded), crowded); err != nil || !listing.Unavailable {
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
	if _, err := (Lister{Roots: []string{space.root}}).List(context.Background(), ebook(link), link); !errors.Is(err, ErrReference) {
		t.Fatalf("direct reference: %v", err)
	}
	folder := filepath.Join(space.root, "F")
	if err := os.Mkdir(folder, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(folder, "track.mp3")); err != nil {
		t.Fatal(err)
	}
	if _, err := (Lister{Roots: []string{space.root}}).List(context.Background(), audiobook(folder), folder); !errors.Is(err, ErrReference) {
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
	direct, err := lister.List(context.Background(), ebook(real), real)
	if err != nil {
		t.Fatal(err)
	}
	stored := filepath.Join(space.root, "alias", ".", "x", "..", "Plain.epub")
	indirect, err := lister.List(context.Background(), ebook(stored), stored)
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

func (w workspace) bytes(relative string, content []byte) string {
	w.t.Helper()
	path := filepath.Join(w.root, relative)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		w.t.Fatal(err)
	}
	if err := os.WriteFile(path, content, 0o644); err != nil {
		w.t.Fatal(err)
	}
	return path
}

func comicbook(path string) store.Book {
	book := audiobook(path)
	book.BookType = store.BookTypeComicbook
	return book
}

func padded(offset int, header string) []byte {
	content := make([]byte, offset+len(header)+10)
	copy(content[offset:], header)
	return content
}

func TestAPdfIsOfferedOnlyWithItsHeaderInsideTheFirstKibibyte(t *testing.T) {
	space := newWorkspace(t)
	cases := map[string][]byte{
		"a-start.pdf": padded(0, "%PDF-1.7\n"), "b-late.pdf": padded(1016, "%PDF-1.4"), "c-too-late.pdf": padded(1017, "%PDF-1.4"), "d-empty.pdf": nil,
		"e-no-header.pdf": []byte("hello"), "f-lowercase.pdf": padded(0, "%pdf-1.7"), "g-no-minor.pdf": padded(0, "%PDF-1"), "h-short.PDF": []byte("%PDF-1.7"),
	}
	for name, content := range cases {
		space.bytes("P/"+name, content)
	}
	path := filepath.Join(space.root, "P")
	listing, err := Lister{Roots: []string{space.root}, Formats: []string{"pdf"}}.List(context.Background(), ebook(path), path)
	if err != nil || listing.Unavailable {
		t.Fatalf("%+v %v", listing, err)
	}
	if got, want := filenames(listing), []string{"a-start.pdf@0", "b-late.pdf@1", "h-short.PDF@2"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("%v", got)
	}
	for _, asset := range listing.Assets {
		if asset.Format != "pdf" || asset.MediaType != "application/pdf" || asset.PageCount != 0 {
			t.Fatalf("%+v", asset)
		}
	}
}

func TestACbzIsOfferedOnlyWithAValidPageListAndCarriesItsPageCount(t *testing.T) {
	space := newWorkspace(t)
	space.bytes("C/a valid.cbz", ziptest.Simple(4))
	space.bytes("C/b text.cbz", []byte("not an archive"))
	space.bytes("C/c no pages.cbz", ziptest.Build([]ziptest.Entry{ziptest.Page("notes.txt")}, ziptest.End{}))
	space.bytes("C/d traversal.cbz", ziptest.Build([]ziptest.Entry{ziptest.Page("../a.png")}, ziptest.End{}))
	space.bytes("C/e one.CBZ", ziptest.Simple(1))
	space.bytes("C/.hidden.cbz", ziptest.Simple(1))
	path := filepath.Join(space.root, "C")
	listing, err := Lister{Roots: []string{space.root}, Formats: []string{"cbz"}}.List(context.Background(), comicbook(path), path)
	if err != nil || listing.Unavailable {
		t.Fatalf("%+v %v", listing, err)
	}
	if got, want := filenames(listing), []string{"a valid.cbz@0", "e one.CBZ@1"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("%v", got)
	}
	if listing.Assets[0].PageCount != 4 || listing.Assets[1].PageCount != 1 || listing.Assets[0].MediaType != "application/vnd.comicbook+zip" || listing.Assets[0].Format != "cbz" {
		t.Fatalf("%+v", listing.Assets)
	}
}

func TestOnlyDeclaredFormatsAreListedAndAudioAlwaysListsItsTracks(t *testing.T) {
	space := newWorkspace(t)
	space.bytes("M/book.epub", []byte("epub"))
	space.bytes("M/book.pdf", padded(0, "%PDF-1.7"))
	space.bytes("M/book.cbz", ziptest.Simple(2))
	path := filepath.Join(space.root, "M")
	for formats, want := range map[string][]string{
		"epub": {"book.epub@0"}, "pdf": {"book.pdf@0"}, "cbz": {"book.cbz@0"}, "epub,pdf": {"book.epub@0", "book.pdf@1"}, "epub,pdf,cbz": {"book.cbz@0", "book.epub@1", "book.pdf@2"},
	} {
		listing, err := Lister{Roots: []string{space.root}, Formats: strings.Split(formats, ",")}.List(context.Background(), ebook(path), path)
		if err != nil || !reflect.DeepEqual(filenames(listing), want) {
			t.Errorf("%s: %v %v", formats, filenames(listing), err)
		}
	}
	space.bytes("M/track.mp3", []byte("audio"))
	listing, err := Lister{Roots: []string{space.root}, Formats: []string{"pdf"}}.List(context.Background(), audiobook(path), path)
	if err != nil || !reflect.DeepEqual(filenames(listing), []string{"track.mp3@0"}) {
		t.Fatalf("%v %v", filenames(listing), err)
	}
}

func TestACbzInAComicRecordAndAnEpubInAComicRecordAreBothListed(t *testing.T) {
	space := newWorkspace(t)
	epub := space.bytes("comic.epub", []byte("an epub"))
	listing, err := Lister{Roots: []string{space.root}, Formats: []string{"epub", "cbz"}}.List(context.Background(), comicbook(epub), epub)
	if err != nil || len(listing.Assets) != 1 || listing.Assets[0].Format != "epub" {
		t.Fatalf("%+v %v", listing, err)
	}
	cbz := space.bytes("comic.cbz", ziptest.Simple(2))
	listing, err = Lister{Roots: []string{space.root}, Formats: []string{"epub", "cbz"}}.List(context.Background(), comicbook(cbz), cbz)
	if err != nil || len(listing.Assets) != 1 || listing.Assets[0].PageCount != 2 {
		t.Fatalf("%+v %v", listing, err)
	}
}

func TestFindInspectsOnlyTheRequestedFileAndAnswersEveryOutcomeDistinctly(t *testing.T) {
	space := newWorkspace(t)
	space.bytes("F/a.cbz", ziptest.Simple(3))
	space.bytes("F/b.cbz", []byte("broken"))
	space.bytes("F/c.pdf", padded(0, "%PDF-1.7"))
	path := filepath.Join(space.root, "F")
	lister := Lister{Roots: []string{space.root}, Formats: []string{"epub", "pdf", "cbz"}}
	book := comicbook(path)
	listing, err := lister.List(context.Background(), book, path)
	if err != nil || len(listing.Assets) != 2 {
		t.Fatalf("%+v %v", listing, err)
	}
	for _, expected := range listing.Assets {
		found, err := lister.Find(context.Background(), book, path, expected.ID)
		if err != nil || found.Unavailable || found.Asset == nil {
			t.Errorf("%s: %+v %v", expected.Filename, found, err)
			continue
		}
		found.Asset.Position = expected.Position
		if !reflect.DeepEqual(*found.Asset, expected) {
			t.Errorf("%s: %+v want %+v", expected.Filename, *found.Asset, expected)
		}
	}
	broken := assetIDOf(t, book, path, filepath.Join(path, "b.cbz"))
	if found, err := lister.Find(context.Background(), book, path, broken); err != nil || found.Unavailable || found.Asset != nil {
		t.Fatalf("a file that fails its check is offered: %+v %v", found, err)
	}
	if found, err := lister.Find(context.Background(), book, path, strings.Repeat("0", 64)); err != nil || found.Unavailable || found.Asset != nil {
		t.Fatalf("%+v %v", found, err)
	}
	outside := filepath.Join(space.root, "missing")
	if found, err := lister.Find(context.Background(), book, outside, broken); err != nil || !found.Unavailable {
		t.Fatalf("%+v %v", found, err)
	}
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := lister.Find(cancelled, book, path, listing.Assets[0].ID); !errors.Is(err, context.Canceled) {
		t.Fatalf("%v", err)
	}
	if _, err := lister.List(cancelled, book, path); !errors.Is(err, context.Canceled) {
		t.Fatalf("%v", err)
	}
}

func assetIDOf(t *testing.T, book store.Book, stored, path string) string {
	t.Helper()
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	stat, err := assetid.StatOf(info)
	if err != nil {
		t.Fatal(err)
	}
	return assetid.ID(assetid.Input{BookID: book.ID, StoredPath: stored, CanonicalPath: path, Stat: stat})
}

func sparseComic(t *testing.T, path string, total int64) {
	t.Helper()
	pages := []ziptest.Entry{ziptest.Page("a.png")}
	plain := ziptest.Build(pages, ziptest.End{})
	directorySize := int64(46 + len("a.png"))
	body := plain[:int64(len(plain))-22-directorySize]
	at := total - directorySize - 22
	final := ziptest.Build(pages, ziptest.End{DirectoryOffset: ziptest.U32(uint32(at))})
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	file.WriteAt(body, 0)
	file.WriteAt(final[len(body):], at)
	if info, _ := file.Stat(); info.Size() != total {
		t.Fatalf("built %d bytes, want %d", info.Size(), total)
	}
}

func TestFixedLayoutSizeLimitsAreExactAtTheirBoundaries(t *testing.T) {
	space := newWorkspace(t)
	path := filepath.Join(space.root, "L")
	if err := os.Mkdir(path, 0o755); err != nil {
		t.Fatal(err)
	}
	const pdfLimit, cbzLimit = 500 << 20, 2 << 30
	for name, size := range map[string]int64{"at.pdf": pdfLimit, "over.pdf": pdfLimit + 1} {
		file, err := os.Create(filepath.Join(path, name))
		if err != nil {
			t.Fatal(err)
		}
		file.WriteString("%PDF-1.7\n")
		file.Truncate(size)
		file.Close()
	}
	sparseComic(t, filepath.Join(path, "at.cbz"), cbzLimit)
	sparseComic(t, filepath.Join(path, "over.cbz"), cbzLimit+1)
	listing, err := Lister{Roots: []string{space.root}, Formats: []string{"pdf", "cbz"}}.List(context.Background(), comicbook(path), path)
	if err != nil {
		t.Fatal(err)
	}
	got := filenames(listing)
	if want := []string{"at.cbz@0", "at.pdf@1"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("%v", got)
	}
}

func TestAnEpubOverTheLimitMakesThePublicationUnavailableButAFixedLayoutFileIsSkipped(t *testing.T) {
	space := newWorkspace(t)
	path := filepath.Join(space.root, "E")
	if err := os.Mkdir(path, 0o755); err != nil {
		t.Fatal(err)
	}
	big, _ := os.Create(filepath.Join(path, "big.epub"))
	big.Truncate(maxEpubBytes + 1)
	big.Close()
	space.bytes("E/ok.pdf", padded(0, "%PDF-1.7"))
	listing, err := Lister{Roots: []string{space.root}, Formats: []string{"epub", "pdf"}}.List(context.Background(), ebook(path), path)
	if err != nil || !listing.Unavailable || len(listing.Assets) != 0 {
		t.Fatalf("%+v %v", listing, err)
	}
}

func TestNaturalOrderOfFixedLayoutFilesFollowsRubyForUnicodeAndNumbers(t *testing.T) {
	paths := []string{"/x/Vol 10.cbz", "/x/ΑΣ.cbz", "/x/vol 2.cbz", "/x/ας.cbz", "/x/Vol 1.cbz", "/x/\U00010d702.cbz", "/x/\U00010d502.cbz", "/x/p99999999999999999999.cbz", "/x/p100000000000000000000.cbz"}
	sortNatural(paths)
	want := []string{"/x/p99999999999999999999.cbz", "/x/p100000000000000000000.cbz", "/x/Vol 1.cbz", "/x/vol 2.cbz", "/x/Vol 10.cbz", "/x/ας.cbz", "/x/ΑΣ.cbz", "/x/\U00010d502.cbz", "/x/\U00010d702.cbz"}
	if !reflect.DeepEqual(paths, want) {
		t.Fatalf("%q", paths)
	}
}

type swappingContext struct {
	context.Context
	calls  int
	onCall int
	swap   func()
}

func (c *swappingContext) Err() error {
	c.calls++
	if c.calls == c.onCall {
		c.swap()
	}
	return c.Context.Err()
}

func TestAFileRewrittenBetweenMatchingAndInspectionIsNotReturnedUnderTheOldIdentity(t *testing.T) {
	space := newWorkspace(t)
	path := space.bytes("S/doc.pdf", padded(0, "%PDF-1.7"))
	book := ebook(path)
	lister := Lister{Roots: []string{space.root}, Formats: []string{"pdf"}}
	listing, err := lister.List(context.Background(), book, path)
	if err != nil || len(listing.Assets) != 1 {
		t.Fatalf("%+v %v", listing, err)
	}
	original := listing.Assets[0].ID
	swapping := &swappingContext{Context: context.Background(), onCall: 2, swap: func() {
		if err := os.WriteFile(path, padded(0, "%PDF-1.7 rewritten"), 0o644); err != nil {
			t.Error(err)
		}
	}}
	found, err := lister.Find(swapping, book, path, original)
	if err != nil || found.Unavailable || found.Asset != nil || swapping.calls < 2 {
		t.Fatalf("%+v %v after %d checks", found, err, swapping.calls)
	}
	again, err := lister.Find(context.Background(), book, path, original)
	if err != nil || again.Asset != nil {
		t.Fatalf("the old identity survived: %+v %v", again, err)
	}
}

func TestAFileSwappedAfterItsBoundaryWasResolvedIsNotOpened(t *testing.T) {
	space := newWorkspace(t)
	current := space.bytes("W/current.pdf", padded(0, "%PDF-1.7"))
	other := space.bytes("W/other.pdf", padded(0, "%PDF-1.7"))
	currentInfo, err := os.Lstat(current)
	if err != nil {
		t.Fatal(err)
	}
	otherInfo, err := os.Lstat(other)
	if err != nil {
		t.Fatal(err)
	}
	located := boundary{target: current, root: space.root}
	file, err := openFixedLayout(located, currentInfo)
	if err != nil {
		t.Fatalf("the file the boundary named: %v", err)
	}
	file.Close()
	var skip errSkip
	if file, err := openFixedLayout(located, otherInfo); !errors.As(err, &skip) || file != nil {
		t.Fatalf("a different file than the one the boundary resolved was opened: %v", err)
	}
}

func TestAFolderScanStopsWhenTheRequestIsCancelledEvenWhenItFindsNothing(t *testing.T) {
	space := newWorkspace(t)
	space.bytes("D/notes.txt", []byte("x"))
	path := filepath.Join(space.root, "D")
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := (Lister{Roots: []string{space.root}, Formats: []string{"pdf", "cbz", "epub"}}).List(cancelled, comicbook(path), path); !errors.Is(err, context.Canceled) {
		t.Fatalf("%v", err)
	}
	if _, err := (Lister{Roots: []string{space.root}, Formats: []string{"pdf"}}).Find(cancelled, comicbook(path), path, strings.Repeat("0", 64)); !errors.Is(err, context.Canceled) {
		t.Fatalf("%v", err)
	}
}

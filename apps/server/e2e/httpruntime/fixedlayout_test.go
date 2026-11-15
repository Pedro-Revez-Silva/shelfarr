//go:build e2e

package httpruntime

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"fmt"
	"hash/crc32"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

const (
	pdfBook   = 9101
	comicBook = 9102
	pdfBytes  = 3 << 20
	cbzPages  = 40
)

type fixedLibrary struct {
	shelf
	pdfPath, cbzPath string
	pdf              []byte
	pageNames        []string
}

func buildComic(t *testing.T, names []string, method uint16) []byte {
	t.Helper()
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	for index, name := range names {
		entry, err := writer.CreateHeader(&zip.FileHeader{Name: name, Method: method})
		if err != nil {
			t.Fatal(err)
		}
		entry.Write(pseudoRandom(int64(100+index), 2000+index))
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

func newFixedLibrary(t *testing.T) fixedLibrary {
	t.Helper()
	s := newShelf(t)
	pdf := append([]byte("%PDF-1.7\n"), pseudoRandom(77, pdfBytes)...)
	var names []string
	for page := cbzPages; page >= 1; page-- {
		names = append(names, fmt.Sprintf("pages/page %d.png", page))
	}
	library := fixedLibrary{shelf: s, pdf: pdf, pageNames: names, pdfPath: filepath.Join(s.library.root, "Fixed Doc.pdf"), cbzPath: filepath.Join(s.library.root, "Fixed Comic.cbz")}
	if err := os.WriteFile(library.pdfPath, pdf, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(library.cbzPath, buildComic(t, names, zip.Store), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, book := range []struct {
		id       int
		title    string
		bookType int
		path     string
	}{{pdfBook, "Fixed Doc", 1, library.pdfPath}, {comicBook, "Fixed Comic", 2, library.cbzPath}} {
		execSQL(t, s.copied.database, `INSERT INTO books (id, title, author, book_type, file_path, created_at, updated_at) VALUES (?, ?, 'Synthetic', ?, ?, '2026-11-01 00:00:00', '2026-11-01 00:00:00')`, book.id, book.title, book.bookType, book.path)
	}
	return library
}

func graphicHeaders(f fixture) map[string]string {
	headers := bearer(f, "alice-full")
	headers["X-Shelfarr-Reader-Formats"] = "epub,pdf,cbz"
	return headers
}

type fixedAsset struct {
	ID              string `json:"id"`
	Format          string `json:"format"`
	MediaType       string `json:"media_type"`
	Size            int64  `json:"size_bytes"`
	URL             string `json:"content_url"`
	PageCount       *int   `json:"page_count"`
	ReadingOrderURL string `json:"reading_order_url"`
}

func (s *server) fixedAssets(t *testing.T, f fixture, book int) []fixedAsset {
	t.Helper()
	response := s.do("GET", fmt.Sprintf("/api/consumer/v1/library/%d", book), graphicHeaders(f))
	var publication struct {
		Assets []fixedAsset `json:"assets"`
	}
	if err := json.Unmarshal(response.body, &publication); err != nil || response.status != 200 {
		t.Fatalf("%d %s", response.status, response.body)
	}
	return publication.Assets
}

func TestPdfAndCbzBytesAreDeliveredIntactAsAttachmentsUnderTheDocumentPolicy(t *testing.T) {
	library := newFixedLibrary(t)
	instance := library.start(t, serverOptions{})
	f := library.f
	pdf := instance.fixedAssets(t, f, pdfBook)[0]
	comic := instance.fixedAssets(t, f, comicBook)[0]
	cbz, _ := os.ReadFile(library.cbzPath)
	for _, test := range []struct {
		name    string
		asset   fixedAsset
		content []byte
		media   string
	}{{"pdf", pdf, library.pdf, "application/pdf"}, {"cbz", comic, cbz, "application/vnd.comicbook+zip"}} {
		whole := instance.do("GET", test.asset.URL, bearer(f, "alice-full"))
		if whole.status != 200 || !bytes.Equal(whole.body, test.content) {
			t.Fatalf("%s: %d, %d bytes of %d", test.name, whole.status, len(whole.body), len(test.content))
		}
		for name, want := range map[string]string{
			"Content-Type": test.media, "Cache-Control": "private, no-store", "Accept-Ranges": "bytes", "X-Content-Type-Options": "nosniff", "Etag": `"` + test.asset.ID + `"`,
			"Content-Security-Policy": "default-src 'none'; sandbox; frame-ancestors 'none'; form-action 'none'; base-uri 'none'", "Content-Length": fmt.Sprint(len(test.content)),
		} {
			if got := whole.headers.Get(name); got != want {
				t.Errorf("%s %s: %q want %q", test.name, name, got, want)
			}
		}
		if disposition := whole.headers.Get("Content-Disposition"); !strings.HasPrefix(disposition, "attachment; filename=") {
			t.Errorf("%s: %q", test.name, disposition)
		}
		head := instance.do("HEAD", test.asset.URL, bearer(f, "alice-full"))
		if head.status != 200 || len(head.body) != 0 || head.headers.Get("Content-Length") != fmt.Sprint(len(test.content)) || head.headers.Get("Content-Security-Policy") == "" {
			t.Errorf("%s HEAD: %d %v", test.name, head.status, head.headers)
		}
		for _, seek := range []struct {
			header      string
			first, last int
		}{{"bytes=0-0", 0, 0}, {"bytes=1048000-1049999", 1048000, 1049999}, {"bytes=-1000", len(test.content) - 1000, len(test.content) - 1}, {fmt.Sprintf("bytes=%d-", len(test.content)-10), len(test.content) - 10, len(test.content) - 1}} {
			headers := bearer(f, "alice-full")
			headers["Range"] = seek.header
			part := instance.do("GET", test.asset.URL, headers)
			if part.status != 206 || !bytes.Equal(part.body, test.content[seek.first:seek.last+1]) || part.headers.Get("Content-Range") != fmt.Sprintf("bytes %d-%d/%d", seek.first, seek.last, len(test.content)) {
				t.Errorf("%s %s: %d %q", test.name, seek.header, part.status, part.headers.Get("Content-Range"))
			}
		}
		conditional := bearer(f, "alice-full")
		conditional["If-None-Match"] = `"` + test.asset.ID + `"`
		if got := instance.do("GET", test.asset.URL, conditional); got.status != 304 || len(got.body) != 0 {
			t.Errorf("%s conditional: %d", test.name, got.status)
		}
	}
	instance.assertNoSensitive(t, f, library.library.root, library.copied.database, pdf.ID, comic.ID)
}

func TestTheReadingOrderIsTheArchiveDirectoryInNaturalPageOrder(t *testing.T) {
	library := newFixedLibrary(t)
	instance := library.start(t, serverOptions{})
	f := library.f
	comic := instance.fixedAssets(t, f, comicBook)[0]
	if comic.PageCount == nil || *comic.PageCount != cbzPages || comic.ReadingOrderURL != comic.URL+"/reading_order" || comic.Format != "cbz" {
		t.Fatalf("%+v", comic)
	}
	response := instance.do("GET", comic.ReadingOrderURL, bearer(f, "alice-full"))
	var order struct {
		AssetID string `json:"asset_id"`
		Format  string `json:"format"`
		Items   []struct {
			Position          int    `json:"position"`
			Href              string `json:"href"`
			MediaType         string `json:"media_type"`
			SizeBytes         int64  `json:"size_bytes"`
			CompressedSize    int64  `json:"compressed_size"`
			CompressionMethod int    `json:"compression_method"`
			LocalHeaderOffset int64  `json:"local_header_offset"`
			CRC32             string `json:"crc32"`
		} `json:"items"`
	}
	if err := json.Unmarshal(response.body, &order); err != nil || response.status != 200 || order.AssetID != comic.ID || order.Format != "cbz" || len(order.Items) != cbzPages {
		t.Fatalf("%d %s", response.status, response.body)
	}
	archive, _ := os.ReadFile(library.cbzPath)
	reader, err := zip.NewReader(bytes.NewReader(archive), int64(len(archive)))
	if err != nil {
		t.Fatal(err)
	}
	byName := map[string]*zip.File{}
	for _, file := range reader.File {
		byName[file.Name] = file
	}
	for index, item := range order.Items {
		name := fmt.Sprintf("pages/page %d.png", index+1)
		file := byName[name]
		offset, _ := file.DataOffset()
		want := fmt.Sprintf("pages/page%%20%d.png|image/png|%d|%d|%d|%d|%08x", index+1, file.UncompressedSize64, file.CompressedSize64, file.Method, offset-int64(30+len(name)), crc32.ChecksumIEEE(archive[offset:offset+int64(file.CompressedSize64)]))
		got := fmt.Sprintf("%s|%s|%d|%d|%d|%d|%s", item.Href, item.MediaType, item.SizeBytes, item.CompressedSize, item.CompressionMethod, item.LocalHeaderOffset, item.CRC32)
		if item.Position != index+1 || got != want {
			t.Fatalf("item %d: %s want %s", index, got, want)
		}
	}
	for _, request := range []struct{ method, label string }{{"HEAD", "head"}, {"GET", "get"}} {
		got := instance.do(request.method, comic.ReadingOrderURL, bearer(f, "alice-full"))
		if got.status != 200 || got.headers.Get("Cache-Control") != "private, no-store" || got.headers.Get("X-Content-Type-Options") != "nosniff" || !strings.HasPrefix(got.headers.Get("Content-Type"), "application/json") {
			t.Errorf("%s: %d %v", request.label, got.status, got.headers)
		}
	}
}

func TestAReplacedTruncatedOrDeletedFixedLayoutFileIsGoneAndNeverServedUnderTheOldIdentity(t *testing.T) {
	library := newFixedLibrary(t)
	instance := library.start(t, serverOptions{})
	f := library.f
	pdf := instance.fixedAssets(t, f, pdfBook)[0]
	comic := instance.fixedAssets(t, f, comicBook)[0]
	get := func(url string) result { return instance.do("GET", url, bearer(f, "alice-full")) }
	if get(pdf.URL).status != 200 || get(comic.URL).status != 200 || get(comic.ReadingOrderURL).status != 200 {
		t.Fatal("baseline")
	}
	original, _ := os.ReadFile(library.cbzPath)
	if err := os.WriteFile(library.cbzPath, original[:len(original)/2], 0o600); err != nil {
		t.Fatal(err)
	}
	for name, url := range map[string]string{"asset": comic.URL, "reading order": comic.ReadingOrderURL} {
		if got := get(url); got.status != 410 || !bytes.Contains(got.body, []byte("asset_unavailable")) {
			t.Errorf("a truncated comic %s: %d %s", name, got.status, got.body)
		}
	}
	if assets := instance.fixedAssets(t, f, comicBook); len(assets) != 0 {
		t.Fatalf("a truncated comic is still offered: %+v", assets)
	}
	replacement := library.cbzPath + ".new"
	os.WriteFile(replacement, original, 0o600)
	os.Rename(replacement, library.cbzPath)
	if got := get(comic.ReadingOrderURL); got.status != 410 {
		t.Fatalf("a replaced comic kept its identity: %d", got.status)
	}
	again := instance.fixedAssets(t, f, comicBook)[0]
	if again.ID == comic.ID || get(again.ReadingOrderURL).status != 200 || get(again.URL).status != 200 {
		t.Fatal("the replacement was not offered under a new identity")
	}
	body := fmt.Sprintf(`{"asset_id":"%s","expected_version":0,"client_mutation_id":"%s","locator":{"href":"pages/page%%201.png","type":"image/png","locations":{"position":1}}}`, comic.ID, uuidA)
	if got := put(instance, library.pathOf(comicBook), library.token("alice-full"), body); got.status != 422 || !bytes.Contains(got.body, []byte("This asset is no longer available; refresh the publication")) {
		t.Fatalf("a write against the old identity: %d %s", got.status, got.body)
	}
	os.WriteFile(library.pdfPath, append([]byte("%PDF-1.7\n"), pseudoRandom(5, 1000)...), 0o600)
	if got := get(pdf.URL); got.status != 410 {
		t.Fatalf("a rewritten PDF kept its identity: %d", got.status)
	}
	os.WriteFile(library.pdfPath, []byte("not a pdf any more"), 0o600)
	if assets := instance.fixedAssets(t, f, pdfBook); len(assets) != 0 {
		t.Fatalf("a file without a PDF header is offered: %+v", assets)
	}
	if rows := library.rows(t, `SELECT COUNT(*) AS n FROM consumer_progresses`); rows[0]["n"] != int64(0) {
		t.Fatalf("a refused write stored a row: %v", rows)
	}
}

func (l fixedLibrary) pathOf(book int) string {
	return fmt.Sprintf("/api/consumer/v1/library/%d/progress", book)
}

func (l fixedLibrary) pagePlace(index int) string {
	return fmt.Sprintf(`{"href":"pages/page%%20%d.png","type":"image/png","locations":{"position":%d,"totalProgression":0.5}}`, index, index)
}

func TestConcurrentPageWritesStoreOneCheckpointAndKeepEveryRetryIdempotent(t *testing.T) {
	library := newFixedLibrary(t)
	instance := library.start(t, serverOptions{})
	comic := instance.fixedAssets(t, library.f, comicBook)[0]
	pdf := instance.fixedAssets(t, library.f, pdfBook)[0]
	cbzBody := func(mutation string, version, page int) string {
		return fmt.Sprintf(`{"asset_id":"%s","expected_version":%d,"client_mutation_id":"%s","locator":%s}`, comic.ID, version, mutation, library.pagePlace(page))
	}
	var created, conflicts, other atomic.Int32
	var wait sync.WaitGroup
	for index := 0; index < 24; index++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			switch put(instance, library.pathOf(comicBook), library.token("alice-full"), cbzBody(fmt.Sprintf("00000000-0000-4000-8000-%012d", index), 0, 1+index%cbzPages)).status {
			case 200:
				created.Add(1)
			case 409:
				conflicts.Add(1)
			default:
				other.Add(1)
			}
		}()
	}
	wait.Wait()
	if created.Load() != 1 || conflicts.Load() != 23 || other.Load() != 0 {
		t.Fatalf("created=%d conflicts=%d other=%d", created.Load(), conflicts.Load(), other.Load())
	}
	first := put(instance, library.pathOf(pdfBook), library.token("alice-full"), fmt.Sprintf(`{"asset_id":"%s","expected_version":0,"client_mutation_id":"%s","observed_at":"2026-11-07T10:15:30.123456+01:00","locator":{"href":"document.pdf","type":"application/pdf","locations":{"position":7,"fragments":["page=7"]}}}`, pdf.ID, uuidB))
	retry := put(instance, library.pathOf(pdfBook), library.token("alice-full"), fmt.Sprintf(`{"asset_id":"%s","expected_version":0,"client_mutation_id":"%s","observed_at":"2026-11-07T09:15:30.123Z","locator":{"fragments":["page=7"],"locations":{"position":7},"type":"application/pdf","href":"document.pdf"}}`, pdf.ID, uuidB))
	if first.status != 200 || retry.status != 200 || !bytes.Equal(first.body, retry.body) {
		t.Fatalf("an identical retry with a re-encoded locator: %d %d\n%s\n%s", first.status, retry.status, first.body, retry.body)
	}
	rows := library.rows(t, `SELECT book_id, version, locator, observed_at FROM consumer_progresses ORDER BY book_id`)
	if len(rows) != 2 || rows[0]["version"] != int64(1) || rows[1]["version"] != int64(1) || !strings.Contains(fmt.Sprint(rows[1]["observed_at"]), "2026-11-07 09:15:30.123") {
		t.Fatalf("%v", rows)
	}
}

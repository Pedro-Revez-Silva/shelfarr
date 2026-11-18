//go:build linux

package gohttp

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/webassets/webassetstest"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/ziptest"
)

type pageFixture struct {
	h       *browserHarness
	alice   *browserClient
	token   string
	engine  webassetstest.PageEngine
	assets  webassetstest.Manifest
	epub    string
	pdf     string
	cbz     string
	pdfSize int64
}

type pageAsset struct {
	ID              string `json:"id"`
	Format          string `json:"format"`
	MediaType       string `json:"media_type"`
	SizeBytes       int64  `json:"size_bytes"`
	URL             string `json:"url"`
	PageCount       *int   `json:"page_count"`
	ReadingOrderURL string `json:"reading_order_url"`
}

type pageReaderEnvelope struct {
	Account     string `json:"account"`
	Publication struct {
		ContentKind  string      `json:"content_kind"`
		OtherFormats []string    `json:"other_formats"`
		Assets       []pageAsset `json:"assets"`
	} `json:"publication"`
}

var comicPageNames = []string{"página 10.png", "página 2.png", "página 1.jpg", "日本/二.webp", "notes.txt", ".hidden.png"}

func comicBytes() string {
	entries := make([]ziptest.Entry, len(comicPageNames))
	for index, name := range comicPageNames {
		entries[index] = ziptest.Page(name)
	}
	return string(ziptest.Build(entries, ziptest.End{}))
}

func newPageFixture(t *testing.T) *pageFixture {
	t.Helper()
	directory := t.TempDir()
	listed, engine := webassetstest.WriteWithPageEngine(t, directory)
	h := newBrowserHarness(t, func(config *Config) { config.WebAssetsDir = directory })
	pdf := "%PDF-1.4\n" + strings.Repeat("x", 600)
	h.file("Mixed Book/Mixed Book.epub", readerEpubBytes)
	h.file("Mixed Book/Mixed Book.pdf", pdf)
	h.addBook(7, "Mixed Book", store.BookTypeEbook, filepath.Join(h.root, "Mixed Book"))
	h.addBook(9, "Harbor Panels", store.BookTypeComicbook, h.file("Harbor Panels.cbz", comicBytes()))
	alice := h.client()
	f := &pageFixture{h: h, alice: alice, token: alice.signIn("alice", alicePassword), engine: engine, assets: listed, pdfSize: int64(len(pdf))}
	for _, asset := range f.reader(t, "7").Publication.Assets {
		switch asset.Format {
		case "epub":
			f.epub = asset.ID
		case "pdf":
			f.pdf = asset.ID
		}
	}
	comic := f.reader(t, "9").Publication.Assets
	if len(comic) != 1 || f.epub == "" || f.pdf == "" {
		t.Fatalf("fixture assets missing: %+v %+v", f, comic)
	}
	f.cbz = comic[0].ID
	return f
}

func (f *pageFixture) reader(t *testing.T, id string) pageReaderEnvelope {
	t.Helper()
	recorder := f.alice.get("/preview/api/v1/library/" + id + "/reader")
	if recorder.Code != http.StatusOK {
		t.Fatalf("reader %s: %d %s", id, recorder.Code, recorder.Body.String())
	}
	var envelope pageReaderEnvelope
	if err := json.Unmarshal(recorder.Body.Bytes(), &envelope); err != nil {
		t.Fatal(err)
	}
	return envelope
}

func (f *pageFixture) orderPath(book, asset string) string {
	return "/preview/api/v1/library/" + book + "/assets/" + asset + "/reading_order"
}

func TestWithAPageEngineTheReaderDescribesPdfAndCbzFilesWithTheirBrowserAddresses(t *testing.T) {
	f := newPageFixture(t)
	mixed := f.reader(t, "7")
	if len(mixed.Publication.Assets) != 2 || len(mixed.Publication.OtherFormats) != 0 {
		t.Fatalf("mixed: %+v", mixed.Publication)
	}
	for _, asset := range mixed.Publication.Assets {
		if asset.URL != "/preview/api/v1/accounts/1/library/7/assets/"+asset.ID || asset.PageCount != nil || asset.ReadingOrderURL != "" {
			t.Errorf("%s asset: %+v", asset.Format, asset)
		}
	}
	comic := f.reader(t, "9")
	asset := comic.Publication.Assets[0]
	if comic.Publication.ContentKind != "graphic" || asset.Format != "cbz" || asset.PageCount == nil || *asset.PageCount != 4 || asset.ReadingOrderURL != f.orderPath("9", f.cbz) ||
		asset.URL != "/preview/api/v1/accounts/1/library/9/assets/"+f.cbz {
		t.Errorf("comic asset: %+v", asset)
	}
	if rows := progressRows(t, f.h); len(rows) != 0 {
		t.Errorf("opening the reader wrote %v", rows)
	}
}

func TestTheBrowserReadingOrderIsTheNativeOrderBoundToTheSignedInAccount(t *testing.T) {
	f := newPageFixture(t)
	recorder := f.alice.get(f.orderPath("9", f.cbz))
	if recorder.Code != http.StatusOK || recorder.Header().Get("Cache-Control") != "private, no-store" || recorder.Header().Get("Cross-Origin-Resource-Policy") != "same-origin" {
		t.Fatalf("order: %d %v %s", recorder.Code, recorder.Header(), recorder.Body.String())
	}
	var browser map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &browser); err != nil {
		t.Fatal(err)
	}
	native := f.h.do(http.MethodGet, "/api/consumer/v1/library/9/assets/"+f.cbz+"/reading_order", map[string]string{"Authorization": "Bearer " + rawToken})
	var order map[string]any
	if err := json.Unmarshal(native.Body.Bytes(), &order); err != nil || native.Code != http.StatusOK {
		t.Fatalf("native: %d %s", native.Code, native.Body.String())
	}
	if browser["account"] != "1" || browser["asset_id"] != f.cbz || browser["format"] != "cbz" || !reflect.DeepEqual(browser["items"], order["items"]) || len(browser) != 4 {
		t.Errorf("the browser order must be the native order with its account: %v", browser)
	}
	var hrefs []string
	for _, item := range browser["items"].([]any) {
		hrefs = append(hrefs, item.(map[string]any)["href"].(string))
	}
	if strings.Join(hrefs, " ") != "p%C3%A1gina%201.jpg p%C3%A1gina%202.png p%C3%A1gina%2010.png %E6%97%A5%E6%9C%AC/%E4%BA%8C.webp" {
		t.Errorf("natural Unicode order: %v", hrefs)
	}
	refusals := []struct {
		name    string
		client  *browserClient
		path    string
		headers map[string]string
		status  int
		code    string
	}{
		{"no account", f.alice, f.orderPath("9", f.cbz), map[string]string{"X-Shelfarr-Account": ""}, http.StatusUnauthorized, "account_changed"},
		{"another account", f.alice, f.orderPath("9", f.cbz), map[string]string{"X-Shelfarr-Account": "2"}, http.StatusUnauthorized, "account_changed"},
		{"signed out", f.h.client(), f.orderPath("9", f.cbz), map[string]string{"X-Shelfarr-Account": "1"}, http.StatusUnauthorized, "signed_out"},
		{"a bearer credential", f.h.client(), f.orderPath("9", f.cbz), map[string]string{"X-Shelfarr-Account": "1", "Authorization": "Bearer " + rawToken}, http.StatusUnauthorized, "signed_out"},
		{"a PDF", f.alice, f.orderPath("7", f.pdf), nil, http.StatusGone, "asset_unavailable"},
		{"an EPUB", f.alice, f.orderPath("7", f.epub), nil, http.StatusGone, "asset_unavailable"},
		{"another book's archive", f.alice, f.orderPath("7", f.cbz), nil, http.StatusGone, "asset_unavailable"},
		{"an unknown book", f.alice, f.orderPath("999", f.cbz), nil, http.StatusNotFound, "not_found"},
	}
	for _, refusal := range refusals {
		headers := map[string]string{"X-Shelfarr-Account": "1"}
		for name, value := range refusal.headers {
			headers[name] = value
		}
		if headers["X-Shelfarr-Account"] == "" {
			delete(headers, "X-Shelfarr-Account")
		}
		got := refusal.client.send(http.MethodGet, refusal.path, "", headers)
		if got.Code != refusal.status || decoded(t, got)["error"] != refusal.code || got.Header().Get("Cache-Control") != "private, no-store" || got.Header().Get("Location") != "" {
			t.Errorf("%s: %d %v %s", refusal.name, got.Code, got.Header(), got.Body.String())
		}
	}
	if got := f.alice.send(http.MethodPost, f.orderPath("9", f.cbz), "", nil); got.Code != http.StatusMethodNotAllowed || got.Header().Get("Allow") != "GET, HEAD" || got.Header().Get("Cross-Origin-Resource-Policy") != "same-origin" {
		t.Errorf("post: %d %v", got.Code, got.Header())
	}
	f.h.file("Harbor Panels.cbz", comicBytes()+"trailing bytes")
	if got := f.alice.get(f.orderPath("9", f.cbz)); got.Code != http.StatusGone || decoded(t, got)["error"] != "asset_unavailable" {
		t.Errorf("an archive replaced after the reader opened must be a new edition: %d %s", got.Code, got.Body.String())
	}
}

func TestACancelledReadingOrderRequestIsTheClientsAndWritesNoOrder(t *testing.T) {
	f := newPageFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	request := httptest.NewRequest(http.MethodGet, f.orderPath("9", f.cbz), nil).WithContext(ctx)
	request.RemoteAddr = "127.0.0.1:50000"
	request.Header.Set("Cookie", "session_id="+f.alice.cookies["session_id"])
	request.Header.Set("X-Shelfarr-Account", "1")
	recorder := httptest.NewRecorder()
	f.h.app.ServeHTTP(recorder, request)
	if recorder.Body.Len() != 0 {
		t.Errorf("a cancelled request must not answer an order: %d %s", recorder.Code, recorder.Body.String())
	}
}

func TestPdfAndCbzBytesAreAccountBoundRangedAttachmentsThatAreRecheckedPerRequest(t *testing.T) {
	f := newPageFixture(t)
	for name, test := range map[string]struct {
		path, mediaType string
		size            int64
	}{
		"pdf": {"/preview/api/v1/accounts/1/library/7/assets/" + f.pdf, "application/pdf", f.pdfSize},
		"cbz": {"/preview/api/v1/accounts/1/library/9/assets/" + f.cbz, "application/vnd.comicbook+zip", int64(len(comicBytes()))},
	} {
		ranged := f.alice.send(http.MethodGet, test.path, "", map[string]string{"Range": "bytes=0-3", "Sec-Fetch-Site": "same-origin", "If-Range": `"` + strings.TrimPrefix(test.path[strings.LastIndex(test.path, "/"):], "/") + `"`})
		header := ranged.Header()
		want := map[string]string{
			"Content-Type": test.mediaType, "Cache-Control": "private, no-store", "Cross-Origin-Resource-Policy": "same-origin", "X-Content-Type-Options": "nosniff",
			"Content-Security-Policy": expectedMediaPolicy, "Referrer-Policy": "no-referrer", "Content-Range": fmt.Sprintf("bytes 0-3/%d", test.size), "Accept-Ranges": "bytes",
		}
		if ranged.Code != http.StatusPartialContent || ranged.Body.Len() != 4 || !strings.HasPrefix(header.Get("Content-Disposition"), "attachment") {
			t.Errorf("%s range: %d %v", name, ranged.Code, header)
		}
		for key, value := range want {
			if header.Get(key) != value {
				t.Errorf("%s: %s = %q, want %q", name, key, header.Get(key), value)
			}
		}
		for refusal, client := range map[string]*browserClient{"signed out": f.h.client()} {
			if got := client.send(http.MethodGet, test.path, "", map[string]string{"Range": "bytes=0-3"}); got.Code != http.StatusUnauthorized || got.Body.Len() == 4 {
				t.Errorf("%s %s: %d", name, refusal, got.Code)
			}
		}
		if got := f.h.client().send(http.MethodGet, test.path, "", map[string]string{"Range": "bytes=0-3", "Sec-Fetch-Site": "cross-site"}); got.Code != http.StatusForbidden || decoded(t, got)["error"] != "cross_site_refused" {
			t.Errorf("%s cross site: %d %s", name, got.Code, got.Body.String())
		}
		other := strings.Replace(test.path, "/accounts/1/", "/accounts/2/", 1)
		if got := f.alice.send(http.MethodGet, other, "", map[string]string{"Range": "bytes=0-3"}); got.Code != http.StatusUnauthorized || decoded(t, got)["error"] != "account_changed" {
			t.Errorf("%s another account: %d", name, got.Code)
		}
	}
	bob := f.h.client()
	bob.signIn("bob", bobPassword)
	if got := bob.send(http.MethodGet, "/preview/api/v1/accounts/1/library/9/assets/"+f.cbz, "", map[string]string{"Range": "bytes=0-3"}); got.Code != http.StatusUnauthorized || decoded(t, got)["error"] != "account_changed" {
		t.Errorf("a range read after the account changed must be refused: %d %s", got.Code, got.Body.String())
	}
	if got := f.alice.send(http.MethodPost, "/preview/api/v1/auth/logout", "", map[string]string{"X-Shelfarr-Account": "1", "Origin": browserOrigin, "X-CSRF-Token": f.token}); got.Code != http.StatusOK {
		t.Fatalf("logout: %d %s", got.Code, got.Body.String())
	}
	if got := f.alice.send(http.MethodGet, "/preview/api/v1/accounts/1/library/9/assets/"+f.cbz, "", map[string]string{"Range": "bytes=0-3"}); got.Code != http.StatusUnauthorized {
		t.Errorf("a range read after signing out must be refused: %d %s", got.Code, got.Body.String())
	}
}

func TestBrowserPagePlacesAreTheNativePagePlaces(t *testing.T) {
	f := newPageFixture(t)
	pdf := `{"asset_id":"` + f.pdf + `","locator":{"href":"document.pdf","type":"application/pdf","locations":{"position":3,"totalProgression":0.2,"fragments":["page=3"]}},"expected_version":0,"client_mutation_id":"` + readerMutation + `","observed_at":"2026-11-15T11:59:00.250Z"}`
	saved := f.alice.send(http.MethodPut, "/preview/api/v1/library/7/progress", pdf, map[string]string{"X-Shelfarr-Account": "1", "Origin": browserOrigin, "X-CSRF-Token": f.token})
	if saved.Code != http.StatusOK || !strings.Contains(saved.Body.String(), `"fragments":["page=3"]`) {
		t.Fatalf("pdf place: %d %s", saved.Code, saved.Body.String())
	}
	place := func(href, mediaType string, position int) string {
		return `{"asset_id":"` + f.cbz + `","locator":{"href":"` + href + `","type":"` + mediaType + `","locations":{"position":` + jsonInt(position) + `,"totalProgression":0.25}},"expected_version":0,"client_mutation_id":"` + readerMutation2 + `","observed_at":"2026-11-15T11:59:01.000Z"}`
	}
	wrong := f.alice.send(http.MethodPut, "/preview/api/v1/library/9/progress", place("p%C3%A1gina%202.png", "image/png", 1), map[string]string{"X-Shelfarr-Account": "1", "Origin": browserOrigin, "X-CSRF-Token": f.token})
	if wrong.Code != http.StatusUnprocessableEntity || decoded(t, wrong)["error"] != "invalid_progress" {
		t.Errorf("a page that is not the Nth of the order must be refused: %d %s", wrong.Code, wrong.Body.String())
	}
	right := f.alice.send(http.MethodPut, "/preview/api/v1/library/9/progress", place("p%C3%A1gina%202.png", "image/png", 2), map[string]string{"X-Shelfarr-Account": "1", "Origin": browserOrigin, "X-CSRF-Token": f.token})
	if right.Code != http.StatusOK {
		t.Errorf("the second page: %d %s", right.Code, right.Body.String())
	}
	if rows := progressRows(t, f.h); len(rows) != 2 {
		t.Errorf("rows: %v", rows)
	}
}

func TestWithoutAPageEngineTheBrowserKeepsRefusingPdfAndCbz(t *testing.T) {
	f := newReaderFixture(t)
	f.h.addBook(9, "Harbor Panels", store.BookTypeComicbook, f.h.file("Harbor Panels.cbz", comicBytes()))
	comic := f.reader(t, f.alice, "9")
	if len(comic.Publication.Assets) != 0 || strings.Join(comic.Publication.OtherFormats, ",") != "cbz" {
		t.Errorf("a comic must stay unreadable without the page engine: %+v", comic.Publication)
	}
	if got := f.alice.get("/preview/api/v1/library/9/assets/" + strings.Repeat("a", 64) + "/reading_order"); got.Code != http.StatusNotFound || got.Header().Get("Cache-Control") != "private, no-store" {
		t.Errorf("the reading order must not exist without the page engine: %d", got.Code)
	}
	for _, shell := range []string{"/preview/library/7/read", "/preview/library"} {
		boot := bootOf(t, f.alice.send(http.MethodGet, shell, "", nil))
		if fmt.Sprint(boot["reader_formats"]) != "[epub]" || boot["page_engine"] != nil {
			t.Errorf("%s boot: %v", shell, boot)
		}
	}
}

func bootOf(t *testing.T, recorder *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	found := regexp.MustCompile(`<script type="application/json" id="shelfarr-boot">(.*)</script>`).FindStringSubmatch(recorder.Body.String())
	var boot map[string]any
	if found == nil || json.Unmarshal([]byte(found[1]), &boot) != nil {
		t.Fatalf("no boot: %d", recorder.Code)
	}
	return boot
}

func TestThePageEngineIsAnnouncedOnlyToTheReaderAndTheLibraryPolicyIsUnchanged(t *testing.T) {
	f := newPageFixture(t)
	reader := f.alice.send(http.MethodGet, "/preview/library/9/read", "", nil)
	if reader.Header().Get("Content-Security-Policy") != expectedReaderPolicy {
		t.Errorf("reader policy: %v", reader.Header())
	}
	boot := bootOf(t, reader)
	engine, _ := boot["page_engine"].(map[string]any)
	files, _ := engine["files"].(map[string]any)
	wasm, _ := files["wasmUrl"].(map[string]any)
	if fmt.Sprint(boot["reader_formats"]) != "[cbz epub pdf]" || engine["engine"] != "/preview/assets/"+f.engine.Engine || engine["worker"] != "/preview/assets/"+f.engine.Worker ||
		wasm["openjpeg.wasm"] != "/preview/assets/"+f.engine.Resources["wasmUrl"]["openjpeg.wasm"] || len(files) != 3 {
		t.Errorf("reader boot: %v", boot)
	}
	for _, path := range []string{"/preview/assets/" + f.engine.Engine, "/preview/assets/" + f.engine.Worker, "/preview/assets/" + f.engine.Resources["cMapUrl"]["UniJIS-UTF16-H.bcmap"]} {
		if got := f.alice.send(http.MethodGet, path, "", nil); got.Code != http.StatusOK || got.Header().Get("Cross-Origin-Resource-Policy") != "same-origin" || got.Header().Get("X-Content-Type-Options") != "nosniff" {
			t.Errorf("%s: %d %v", path, got.Code, got.Header())
		}
	}
	library := f.alice.send(http.MethodGet, "/preview/library", "", nil)
	libraryBoot := bootOf(t, library)
	if library.Header().Get("Content-Security-Policy") != webContentPolicy || libraryBoot["page_engine"] != nil || libraryBoot["reader_engine"] != nil || fmt.Sprint(libraryBoot["reader_formats"]) != "[cbz epub pdf]" {
		t.Errorf("library: %v %v", library.Header(), libraryBoot)
	}
}

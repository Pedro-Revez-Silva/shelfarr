package gohttp

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/livetest"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/ziptest"
)

type fixedShelf struct {
	shelf
	pdfBook, comicBook, epubComic, ebookComic int
	pdfID, cbzID, ebookCbzID                  string
}

func pdfBytes(extra int) string { return "%PDF-1.7\n" + strings.Repeat("p", extra) }

func comicArchive(names ...string) string {
	entries := make([]ziptest.Entry, len(names))
	for index, name := range names {
		entries[index] = ziptest.Page(name)
	}
	return string(ziptest.Build(entries, ziptest.End{}))
}

func (h *harness) fixedShelf() fixedShelf {
	h.t.Helper()
	lib := fixedShelf{shelf: h.shelf(), pdfBook: 11, comicBook: 12, epubComic: 13, ebookComic: 14}
	h.addBook(11, "A PDF", store.BookTypeEbook, h.file("Doc.pdf", pdfBytes(600)))
	h.addBook(12, "A Comic", store.BookTypeComicbook, h.file("Comic.cbz", comicArchive("p10.png", "p2.png", "p1.jpg", "notes.txt", ".hidden.png")))
	h.addBook(13, "Epub In Comic", store.BookTypeComicbook, h.file("Comic Epub.epub", "an epub"))
	h.addBook(14, "Graphic Ebook", store.BookTypeEbook, h.file("Graphic.cbz", comicArchive("a.png")))
	livetest.Exec(h.t, h.path, `UPDATE books SET content_kind = 1 WHERE id = 14`)
	all := map[string]string{"X-Shelfarr-Reader-Formats": "epub,pdf,cbz"}
	lib.pdfID = h.firstAsset(11, all)
	lib.cbzID = h.firstAsset(12, all)
	lib.ebookCbzID = h.firstAsset(14, all)
	return lib
}

func (h *harness) firstAsset(book int, extra map[string]string) string {
	h.t.Helper()
	headers := jsonHeaders(progressToken)
	for name, value := range extra {
		headers[name] = value
	}
	recorder := h.do(http.MethodGet, fmt.Sprintf("/api/consumer/v1/library/%d", book), headers)
	var publication struct {
		Assets []struct {
			ID string `json:"id"`
		} `json:"assets"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &publication); err != nil || len(publication.Assets) == 0 {
		h.t.Fatalf("%d %s", recorder.Code, recorder.Body.String())
	}
	return publication.Assets[0].ID
}

func (h *harness) library(selection *string, query string) (*httptest.ResponseRecorder, []map[string]any) {
	h.t.Helper()
	headers := jsonHeaders(progressToken)
	if selection != nil {
		headers["X-Shelfarr-Reader-Formats"] = *selection
	}
	recorder := h.do(http.MethodGet, "/api/consumer/v1/library?limit=50"+query, headers)
	var body struct {
		Items []map[string]any `json:"items"`
	}
	if recorder.Code == http.StatusOK && json.Unmarshal(recorder.Body.Bytes(), &body) != nil {
		h.t.Fatalf("%s", recorder.Body.String())
	}
	return recorder, body.Items
}

func listed(items []map[string]any) string {
	var parts []string
	for _, item := range items {
		formats := []string{}
		for _, asset := range item["assets"].([]any) {
			formats = append(formats, asset.(map[string]any)["format"].(string))
		}
		kind, _ := item["content_kind"].(string)
		parts = append(parts, fmt.Sprintf("%s:%s:%s:%s", item["id"], item["book_type"], kind, strings.Join(formats, "+")))
	}
	return strings.Join(parts, " ")
}

func TestDeclaredFormatsDecideWhichRecordsAndAssetsAreListed(t *testing.T) {
	lib := newHarness(t, nil).fixedShelf()
	text := func(value string) *string { return &value }
	cases := []struct {
		name      string
		selection *string
		want      string
	}{
		{"absent", nil, "14:ebook:: 11:ebook:: 2:audiobook::mp3 1:ebook::epub"},
		{"epub", text("epub"), "14:ebook:graphic: 11:ebook:book: 2:audiobook:book:mp3 1:ebook:book:epub"},
		{"epub twice", text("epub,epub"), "14:ebook:graphic: 11:ebook:book: 2:audiobook:book:mp3 1:ebook:book:epub"},
		{"pdf", text("pdf"), "14:ebook:graphic: 13:ebook:graphic: 12:ebook:graphic: 11:ebook:book:pdf 2:audiobook:book:mp3 1:ebook:book:"},
		{"cbz", text("cbz"), "14:ebook:graphic:cbz 13:ebook:graphic: 12:ebook:graphic:cbz 11:ebook:book: 2:audiobook:book:mp3 1:ebook:book:"},
		{"epub and pdf", text("epub,pdf"), "14:ebook:graphic: 13:ebook:graphic:epub 12:ebook:graphic: 11:ebook:book:pdf 2:audiobook:book:mp3 1:ebook:book:epub"},
		{"all, unordered and padded", text(" pdf, cbz,epub,pdf"), "14:ebook:graphic:cbz 13:ebook:graphic:epub 12:ebook:graphic:cbz 11:ebook:book:pdf 2:audiobook:book:mp3 1:ebook:book:epub"},
	}
	for _, test := range cases {
		recorder, items := lib.h.library(test.selection, "")
		if recorder.Code != http.StatusOK || !strings.Contains(recorder.Header().Get("Vary"), "X-Shelfarr-Reader-Formats") {
			t.Errorf("%s: %d %q", test.name, recorder.Code, recorder.Header().Get("Vary"))
		}
		if got := listed(items); got != test.want {
			t.Errorf("%s:\n got %s\nwant %s", test.name, got, test.want)
		}
	}
}

func TestEveryCapabilitySelectionFiltersByTypeAndStatusWithoutLosingAMixedLibrary(t *testing.T) {
	lib := newHarness(t, nil).fixedShelf()
	all := "epub,pdf,cbz"
	_, ebooks := lib.h.library(&all, "&type=ebook")
	if got := listed(ebooks); got != "14:ebook:graphic:cbz 13:ebook:graphic:epub 12:ebook:graphic:cbz 11:ebook:book:pdf 1:ebook:book:epub" {
		t.Fatalf("%s", got)
	}
	_, audio := lib.h.library(&all, "&type=audiobook")
	if got := listed(audio); got != "2:audiobook:book:mp3" {
		t.Fatalf("%s", got)
	}
	livetest.Exec(t, lib.h.path, `INSERT INTO consumer_reading_states (user_id, book_id, status, created_at, updated_at) VALUES (1, 12, 2, '2026-11-01 00:00:00', '2026-11-01 00:00:00')`)
	_, finished := lib.h.library(&all, "&status=finished")
	if got := listed(finished); got != "12:ebook:graphic:cbz" {
		t.Fatalf("%s", got)
	}
	epub := "epub"
	if _, hidden := lib.h.library(&epub, "&status=finished"); len(hidden) != 0 {
		t.Fatalf("a client that cannot open comics was shown one: %s", listed(hidden))
	}
	_, titled := lib.h.library(&all, "&sort=title&limit=2&q=comic")
	if got := listed(titled); got != "12:ebook:graphic:cbz 13:ebook:graphic:epub" {
		t.Fatalf("%s", got)
	}
}

func TestCursorsBindToTheNormalisedFormatSelectionAndLegacyCursorsKeepTheirIdentity(t *testing.T) {
	lib := newHarness(t, nil).fixedShelf()
	next := func(selection *string) string {
		recorder, _ := lib.h.library(selection, "")
		_ = recorder
		headers := jsonHeaders(progressToken)
		if selection != nil {
			headers["X-Shelfarr-Reader-Formats"] = *selection
		}
		var body struct {
			Next *string `json:"next_cursor"`
		}
		json.Unmarshal(lib.h.do(http.MethodGet, "/api/consumer/v1/library?limit=2", headers).Body.Bytes(), &body)
		if body.Next == nil {
			t.Fatal("no cursor")
		}
		return *body.Next
	}
	replay := func(cursor string, selection *string) int {
		headers := jsonHeaders(progressToken)
		if selection != nil {
			headers["X-Shelfarr-Reader-Formats"] = *selection
		}
		return lib.h.do(http.MethodGet, "/api/consumer/v1/library?limit=2&cursor="+cursor, headers).Code
	}
	text := func(value string) *string { return &value }
	graphic := next(text("epub,pdf"))
	if replay(graphic, text("pdf,epub")) != http.StatusOK || replay(graphic, text(" epub , pdf,pdf")) != http.StatusOK {
		t.Fatal("an equal selection must share its cursors")
	}
	for _, other := range []*string{text("epub"), text("epub,pdf,cbz"), text("pdf"), nil} {
		if replay(graphic, other) != http.StatusBadRequest {
			t.Errorf("a cursor crossed selections: %v", other)
		}
	}
	legacy := next(nil)
	explicit := next(text("epub"))
	if replay(legacy, nil) != http.StatusOK || replay(legacy, text("epub")) != http.StatusOK || replay(explicit, nil) != http.StatusOK {
		t.Fatal("the default selection keeps the identity cursors had before formats were negotiable")
	}
}

func TestInvalidSelectionsAreRealBadRequestsOnEveryRoute(t *testing.T) {
	lib := newHarness(t, nil).fixedShelf()
	for _, value := range []string{"", "PDF", "pdf,", ",pdf", "pdf,,cbz", "mobi", "pdf;cbz", strings.Repeat("pdf,", 20)} {
		for _, target := range []string{"/api/consumer/v1/library", "/api/consumer/v1/continue", "/api/consumer/v1/library/11"} {
			headers := jsonHeaders(progressToken)
			headers["X-Shelfarr-Reader-Formats"] = value
			recorder := lib.h.do(http.MethodGet, target, headers)
			parsed := decodeObject(t, recorder, http.StatusBadRequest)
			if parsed["error"] != "invalid_request" || parsed["message"] == "" {
				t.Errorf("%q %s: %v", value, target, parsed)
			}
		}
	}
}

func TestACbzAssetCarriesItsPageCountAndReadingOrderLinkAndOtherFormatsDoNot(t *testing.T) {
	lib := newHarness(t, nil).fixedShelf()
	headers := jsonHeaders(progressToken)
	headers["X-Shelfarr-Reader-Formats"] = "epub,pdf,cbz"
	comic := decodeObject(t, lib.h.do(http.MethodGet, "/api/consumer/v1/library/12", headers), http.StatusOK)
	asset := comic["assets"].([]any)[0].(map[string]any)
	want := map[string]any{
		"id": lib.cbzID, "filename": "Comic.cbz", "format": "cbz", "media_type": "application/vnd.comicbook+zip", "size_bytes": asset["size_bytes"], "position": 0.0,
		"content_url": "/api/consumer/v1/library/12/assets/" + lib.cbzID, "page_count": 3.0, "reading_order_url": "/api/consumer/v1/library/12/assets/" + lib.cbzID + "/reading_order",
	}
	if !reflect.DeepEqual(asset, want) || comic["book_type"] != "ebook" || comic["content_kind"] != "graphic" {
		t.Fatalf("%v", comic)
	}
	pdf := decodeObject(t, lib.h.do(http.MethodGet, "/api/consumer/v1/library/11", headers), http.StatusOK)["assets"].([]any)[0].(map[string]any)
	if _, present := pdf["page_count"]; present || pdf["format"] != "pdf" || pdf["media_type"] != "application/pdf" {
		t.Fatalf("%v", pdf)
	}
	if got := lib.h.do(http.MethodGet, "/api/consumer/v1/library/12", jsonHeaders(progressToken)); got.Code != http.StatusNotFound {
		t.Fatalf("a comic record was shown to a client that never declared a fixed-layout format: %d", got.Code)
	}
}

func (l fixedShelf) get(path string, headers map[string]string) *httptest.ResponseRecorder {
	h := jsonHeaders(progressToken)
	for name, value := range headers {
		h[name] = value
	}
	return l.h.do(http.MethodGet, path, h)
}

func TestFixedLayoutAssetsAreAttachmentsUnderTheDocumentPolicyAndDirectFetchNeedsNoCapabilityHeader(t *testing.T) {
	lib := newHarness(t, nil).fixedShelf()
	for _, test := range []struct{ path, media, name string }{
		{"/api/consumer/v1/library/11/assets/" + lib.pdfID, "application/pdf", `attachment; filename="Doc.pdf"; filename*=UTF-8''Doc.pdf`},
		{"/api/consumer/v1/library/12/assets/" + lib.cbzID, "application/vnd.comicbook+zip", `attachment; filename="Comic.cbz"; filename*=UTF-8''Comic.cbz`},
	} {
		for _, method := range []string{http.MethodGet, http.MethodHead} {
			recorder := lib.h.do(method, test.path, jsonHeaders(progressToken))
			want := map[string]string{
				"Content-Type": test.media, "Content-Disposition": test.name, "Cache-Control": "private, no-store", "Accept-Ranges": "bytes", "X-Content-Type-Options": "nosniff",
				"Content-Security-Policy": documentPolicy, "Content-Length": recorder.Header().Get("Content-Length"),
			}
			for name, value := range want {
				if got := recorder.Header().Get(name); got != value {
					t.Errorf("%s %s %s: %q want %q", method, test.path, name, got, value)
				}
			}
			if recorder.Code != http.StatusOK || (method == http.MethodHead) != (recorder.Body.Len() == 0) {
				t.Errorf("%s %s: %d %d", method, test.path, recorder.Code, recorder.Body.Len())
			}
		}
	}
	epub := lib.h.do(http.MethodGet, "/api/consumer/v1/library/1/assets/"+lib.epubID, jsonHeaders(progressToken))
	if !strings.HasPrefix(epub.Header().Get("Content-Disposition"), "inline;") || epub.Header().Get("Content-Security-Policy") != "" {
		t.Fatalf("an EPUB changed: %v", epub.Header())
	}
	content, _ := os.ReadFile(lib.h.root + "/Comic.cbz")
	body := lib.h.do(http.MethodGet, "/api/consumer/v1/library/12/assets/"+lib.cbzID, jsonHeaders(progressToken)).Body.Bytes()
	if string(body) != string(content) {
		t.Fatal("the archive was not delivered byte for byte")
	}
}

func TestReadingOrderAnswersOnlyForTheExactCbzGeneration(t *testing.T) {
	lib := newHarness(t, nil).fixedShelf()
	path := func(book int, id string) string {
		return fmt.Sprintf("/api/consumer/v1/library/%d/assets/%s/reading_order", book, id)
	}
	order := decodeObject(t, lib.get(path(12, lib.cbzID), nil), http.StatusOK)
	items := order["items"].([]any)
	if order["asset_id"] != lib.cbzID || order["format"] != "cbz" || len(items) != 3 {
		t.Fatalf("%v", order)
	}
	var hrefs []string
	for index, item := range items {
		page := item.(map[string]any)
		hrefs = append(hrefs, page["href"].(string))
		if page["position"] != float64(index+1) || len(page) != 8 {
			t.Fatalf("%v", page)
		}
	}
	if !reflect.DeepEqual(hrefs, []string{"p1.jpg", "p2.png", "p10.png"}) || items[0].(map[string]any)["media_type"] != "image/jpeg" {
		t.Fatalf("%v", hrefs)
	}
	for name, recorder := range map[string]*httptest.ResponseRecorder{
		"an EPUB asset":      lib.get(path(1, lib.epubID), nil),
		"a PDF asset":        lib.get(path(11, lib.pdfID), nil),
		"an audio asset":     lib.get(path(2, lib.audioID), nil),
		"another book's id":  lib.get(path(14, lib.cbzID), nil),
		"an unknown id":      lib.get(path(12, strings.Repeat("0", 64)), nil),
		"an uppercase id":    lib.get(path(12, strings.ToUpper(lib.cbzID)), nil),
		"a short id":         lib.get(path(12, lib.cbzID[:63]), nil),
		"an epub in a comic": lib.get(path(13, lib.h.firstAsset(13, map[string]string{"X-Shelfarr-Reader-Formats": "epub,cbz"})), nil),
	} {
		if recorder.Code != http.StatusGone || recorder.Body.String() != `{"error":"asset_unavailable"}` {
			t.Errorf("%s: %d %s", name, recorder.Code, recorder.Body.String())
		}
	}
	if got := lib.get(path(999, lib.cbzID), nil); got.Code != http.StatusNotFound {
		t.Fatalf("%d", got.Code)
	}
	readOnly := lib.h.do(http.MethodGet, path(12, lib.cbzID), jsonHeaders(writeOnlyToken))
	if readOnly.Code != http.StatusForbidden || !strings.Contains(readOnly.Body.String(), "insufficient_scope") {
		t.Fatalf("%d %s", readOnly.Code, readOnly.Body.String())
	}
	head := lib.h.do(http.MethodHead, path(12, lib.cbzID), jsonHeaders(progressToken))
	whole := lib.h.do(http.MethodGet, path(12, lib.cbzID), jsonHeaders(progressToken))
	if head.Code != http.StatusOK || head.Header().Get("Content-Length") != whole.Header().Get("Content-Length") || head.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatalf("%d %v", head.Code, head.Header())
	}
}

func TestACbzPlaceMustBeTheNthItemOfTheReadingOrderOfThatGeneration(t *testing.T) {
	lib := newHarness(t, nil).fixedShelf()
	place := func(mutation string, version int, locator string) string {
		return fmt.Sprintf(`{"asset_id":"%s","expected_version":%d,"client_mutation_id":"%s","locator":%s}`, lib.cbzID, version, mutation, locator)
	}
	refused := map[string]string{
		`{"href":"p2.png","type":"image/png","locations":{"position":1}}`:                                    "This page is not page 1 of the comic's reading order; refresh the publication",
		`{"href":"p1.jpg","type":"image/png","locations":{"position":1}}`:                                    "This page is not page 1 of the comic's reading order; refresh the publication",
		`{"href":"p1.jpg","locations":{"position":1}}`:                                                       "This page is not page 1 of the comic's reading order; refresh the publication",
		`{"href":"p1.jpg","type":"image/jpeg","locations":{"position":4}}`:                                   "This page is not page 4 of the comic's reading order; refresh the publication",
		`{"href":"p1.jpg","type":"image/jpeg","locations":{"position":1,"fragments":null}}`:                  "A comic place has no fragments",
		`{"href":"p1.jpg","type":"image/jpeg","locations":{"position":1,"fragments":["page=1"]}}`:            "A comic place has no fragments",
		`{"href":"p1.jpg","type":"image/jpeg","locations":{"position":0}}`:                                   "A bounded relative ebook locator is required",
		`{"href":"p1.jpg","type":"image/jpeg","locations":{"position":1,"cfi":"/2/4"}}`:                      "A page place needs a one-based locations.position and no text position",
		`{"href":"p1.jpg","type":"image/jpeg","locations":{"position":1},"vendor":1}`:                        "A page place needs a one-based locations.position and no text position",
		`{"href":"p1.jpg","type":"image/jpeg","text":"x","locations":{"position":1}}`:                        "A page place needs a one-based locations.position and no text position",
		`{"href":"p1.jpg","type":"image/jpeg","locations":{"position":1.0}}`:                                 "A bounded relative ebook locator is required",
		`{"href":"document.pdf","type":"application/pdf","locations":{"position":1}}`:                        "This page is not page 1 of the comic's reading order; refresh the publication",
		`{"href":"OEBPS/chapter.xhtml","locations":{"position":1,"progression":0.1,"totalProgression":0.2}}`: "This page is not page 1 of the comic's reading order; refresh the publication",
	}
	for locator, message := range refused {
		recorder := lib.put(12, progressToken, place(mutationOne, 0, locator))
		if parsed := decodeObject(t, recorder, http.StatusUnprocessableEntity); parsed["error"] != "invalid_progress" || parsed["message"] != message {
			t.Errorf("%s: %v", locator, parsed)
		}
	}
	if rows := livetest.Query(t, lib.h.path, `SELECT (SELECT COUNT(*) FROM consumer_progresses), (SELECT COUNT(*) FROM consumer_reading_states)`); fmt.Sprint(rows) != "[[0 0]]" {
		t.Fatalf("a refused place changed rows: %v", rows)
	}
	for index, locator := range []string{
		`{"href":"p1.jpg","type":"image/jpeg","locations":{"position":1}}`,
		`{"href":"p2.png","type":"image/png","title":"Two","text":{"a":1},"locations":{"position":2,"progression":0.5,"totalProgression":0.6}}`,
		`{"href":"p10.png","type":"image/png","locations":{"position":3}}`,
	} {
		position := index + 1
		recorder := lib.put(12, progressToken, place(fmt.Sprintf("00000000-0000-4000-8000-%012d", position), position-1, locator))
		stored := decodeObject(t, recorder, http.StatusOK)["progress"].(map[string]any)
		if stored["version"] != float64(position) || stored["asset_id"] != lib.cbzID {
			t.Fatalf("%d: %v", position, stored)
		}
	}
}

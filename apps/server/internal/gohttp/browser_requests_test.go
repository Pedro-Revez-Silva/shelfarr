//go:build linux

package gohttp

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strconv"
	"strings"
	"testing"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/livetest"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/webpreview"
)

type seededRequest struct {
	id, book, user, status int
	attention              any
	issue                  any
	created                string
	completed, retry       any
}

func (h *browserHarness) request(r seededRequest) {
	h.t.Helper()
	livetest.Exec(h.t, h.path, `INSERT INTO requests (id, book_id, user_id, status, attention_needed, issue_description, created_at, updated_at, completed_at, next_retry_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		r.id, r.book, r.user, r.status, r.attention, r.issue, r.created, r.created, r.completed, r.retry)
}

func (h *browserHarness) download(request, status int, progress any) {
	h.t.Helper()
	livetest.Exec(h.t, h.path, `INSERT INTO downloads (request_id, name, status, progress, download_path, external_id, download_client_id) VALUES (?, 'Release.Name.Tracker-GROUP', ?, ?, '/downloads/secret/path', 'hash-secret', 'client-secret')`, request, status, progress)
}

func newRequestsHarness(t *testing.T) *browserHarness {
	t.Helper()
	h := newBrowserHarness(t, nil)
	livetest.Exec(t, h.path, `INSERT INTO users (id, username, name) VALUES (3, 'carol', 'Carol')`)
	h.addBook(10, "Opened Book", store.BookTypeEbook, h.file("Opened Book.epub", "PK epub"))
	livetest.Exec(t, h.path, `UPDATE books SET author = 'O. Author', cover_url = 'https://covers.example.test/opened.jpg' WHERE id = 10`)
	h.addBook(11, "Missing Book", store.BookTypeAudiobook, "/library/absent/Missing Book")
	livetest.Exec(t, h.path, `INSERT INTO books (id, title, author, cover_url, book_type) VALUES (12, 'Pending Book', '  ', 'http://insecure.example.test/c.jpg', 1), (13, 'Alice Book', 'A. Writer', NULL, 2), (14, 'Carol Book', NULL, NULL, 0)`)
	h.request(seededRequest{id: 1, book: 10, user: 2, status: 5, attention: 0, created: "2026-11-10 08:00:00.5", completed: "2026-11-11 09:30:00"})
	h.request(seededRequest{id: 2, book: 11, user: 2, status: 5, attention: 0, created: "2026-11-12 08:00:00", completed: "2026-11-12 10:00:00"})
	h.request(seededRequest{id: 3, book: 12, user: 2, status: 3, attention: 0, created: "2026-11-13 08:00:00"})
	h.request(seededRequest{id: 4, book: 13, user: 1, status: 2, attention: 1, issue: "Failed to connect to download client: http://admin:hunter2@10.0.0.5:8080", created: "2026-11-14 08:00:00", retry: "2026-11-16 08:00:00"})
	h.request(seededRequest{id: 5, book: 14, user: 3, status: 1, attention: 1, issue: "Search results found. Please review and select a result to download.", created: "2026-11-14 08:00:00"})
	h.download(3, 1, 42)
	h.download(3, 2, 150)
	h.download(3, 4, 99)
	h.download(1, 3, 100)
	return h
}

func requestsBody(t *testing.T, recorder *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	if recorder.Code != http.StatusOK || recorder.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatalf("requests %d %v %s", recorder.Code, recorder.Header(), recorder.Body.String())
	}
	return decoded(t, recorder)
}

func itemIDs(body map[string]any) []string {
	ids := []string{}
	for _, item := range body["items"].([]any) {
		ids = append(ids, item.(map[string]any)["id"].(string))
	}
	return ids
}

func style(id string) string { return webpreview.CoverStyle(id) }

func TestAMemberSeesOnlyTheirOwnRequestsProjectedWithoutAnyoneElsesData(t *testing.T) {
	h := newRequestsHarness(t)
	client := h.client()
	client.signIn("bob", bobPassword)
	body := requestsBody(t, client.get("/preview/api/v1/requests"))
	want := map[string]any{
		"account": "2", "scope": "own", "filter": map[string]any{"status": nil, "attention": false, "q": nil},
		"counts": map[string]any{"attention": 0.0, "active": 1.0}, "page": 1.0, "per_page": 25.0, "total": 3.0, "total_pages": 1.0,
		"items": []any{
			map[string]any{"id": "3", "status": "downloading", "attention_needed": false, "title": "Pending Book", "author": nil, "book_type": "ebook",
				"cover": map[string]any{"url": nil, "style": style("12")}, "download_percent": 100.0, "created_at": "2026-11-13T08:00:00.000Z", "updated_at": "2026-11-13T08:00:00.000Z",
				"completed_at": nil, "next_retry_at": nil, "library": nil},
			map[string]any{"id": "2", "status": "completed", "attention_needed": false, "title": "Missing Book", "author": nil, "book_type": "audiobook",
				"cover": map[string]any{"url": nil, "style": style("11")}, "download_percent": nil, "created_at": "2026-11-12T08:00:00.000Z", "updated_at": "2026-11-12T08:00:00.000Z",
				"completed_at": "2026-11-12T10:00:00.000Z", "next_retry_at": nil, "library": map[string]any{"state": "unavailable"}},
			map[string]any{"id": "1", "status": "completed", "attention_needed": false, "title": "Opened Book", "author": "O. Author", "book_type": "ebook",
				"cover": map[string]any{"url": "https://covers.example.test/opened.jpg", "style": style("10")}, "download_percent": nil, "created_at": "2026-11-10T08:00:00.500Z",
				"updated_at": "2026-11-10T08:00:00.500Z", "completed_at": "2026-11-11T09:30:00.000Z", "next_retry_at": nil, "library": map[string]any{"state": "available", "publication_id": "10"}},
		},
	}
	if !reflect.DeepEqual(body, want) {
		t.Fatalf("got %#v", body)
	}
	for _, id := range []string{"4", "5", "999", "0", "01", "abc"} {
		recorder := client.get("/preview/api/v1/requests/" + id)
		if recorder.Code != http.StatusNotFound || errorCode(t, recorder) != "not_found" || recorder.Header().Get("Cache-Control") != "private, no-store" || recorder.Body.String() != `{"error":"not_found"}` {
			t.Fatalf("%s: %d %s", id, recorder.Code, recorder.Body.String())
		}
	}
	detail := requestsBody(t, client.get("/preview/api/v1/requests/3"))
	request := detail["request"].(map[string]any)
	if detail["account"] != "2" || request["id"] != "3" || request["attention_reason"] != nil || request["requested_by"] != nil ||
		!reflect.DeepEqual(request["downloads"], []any{map[string]any{"status": "failed", "progress": nil}, map[string]any{"status": "paused", "progress": nil}, map[string]any{"status": "downloading", "progress": 42.0}}) {
		t.Fatalf("detail %v", detail)
	}
}

func TestAnAdminSeesEveryRequestWithOnlyTheRequestersDisplayName(t *testing.T) {
	h := newRequestsHarness(t)
	client := h.client()
	client.signIn("alice", alicePassword)
	body := requestsBody(t, client.get("/preview/api/v1/requests"))
	if body["scope"] != "all" || body["total"] != 5.0 || !reflect.DeepEqual(itemIDs(body), []string{"5", "4", "3", "2", "1"}) ||
		!reflect.DeepEqual(body["counts"], map[string]any{"attention": 2.0, "active": 1.0}) {
		t.Fatalf("admin list %v", body)
	}
	names := map[string]any{}
	for _, item := range body["items"].([]any) {
		entry := item.(map[string]any)
		names[entry["id"].(string)] = entry["requested_by"]
	}
	wantNames := map[string]any{"5": map[string]any{"name": "Carol", "self": false}, "4": map[string]any{"name": "Alice", "self": true}, "3": map[string]any{"name": "Bob", "self": false},
		"2": map[string]any{"name": "Bob", "self": false}, "1": map[string]any{"name": "Bob", "self": false}}
	if !reflect.DeepEqual(names, wantNames) {
		t.Fatalf("names %v", names)
	}
	own := requestsBody(t, client.get("/preview/api/v1/requests/4"))["request"].(map[string]any)
	if own["attention_reason"] != nil || own["next_retry_at"] != "2026-11-16T08:00:00.000Z" || own["status"] != "not_found" || own["attention_needed"] != true {
		t.Fatalf("free-text reason or retry %v", own)
	}
	other := requestsBody(t, client.get("/preview/api/v1/requests/5"))["request"].(map[string]any)
	if other["attention_reason"] != "Search results found. Please review and select a result to download." || !reflect.DeepEqual(other["requested_by"], map[string]any{"name": "Carol", "self": false}) {
		t.Fatalf("allowlisted reason %v", other)
	}
	for _, path := range []string{"/preview/api/v1/requests", "/preview/api/v1/requests/3", "/preview/api/v1/requests/4"} {
		text := client.get(path).Body.String()
		for _, secret := range []string{"hunter2", "10.0.0.5", "Release.Name", "secret", "/library", "/downloads", h.root, "carol\"", "bob\"", "insecure.example.test", "password"} {
			if strings.Contains(text, secret) {
				t.Fatalf("%s leaks %q: %s", path, secret, text)
			}
		}
	}
}

func TestRequestFiltersSearchAndPagesFollowRails(t *testing.T) {
	h := newRequestsHarness(t)
	livetest.Exec(t, h.path, `INSERT INTO books (id, title, author, book_type) VALUES (20, 'Crème Brûlée', 'ÉMILE ZOLA', 1), (21, 'Plain 100%_x', NULL, 1)`)
	h.request(seededRequest{id: 20, book: 20, user: 1, status: 0, attention: nil, created: "2026-11-14 09:00:00"})
	h.request(seededRequest{id: 21, book: 21, user: 1, status: 4, attention: 0, created: "2026-11-14 09:00:00"})
	client := h.client()
	client.signIn("alice", alicePassword)
	cases := map[string][]string{
		"":                                {"21", "20", "5", "4", "3", "2", "1"},
		"status=active":                   {"21", "3"},
		"attention=true":                  {"5", "4"},
		"attention=yes":                   {"21", "20", "5", "4", "3", "2", "1"},
		"status=completed":                {"2", "1"},
		"status=not_found":                {"4"},
		"status=pending":                  {"20"},
		"status=awaiting_purchase":        {},
		"status=failed":                   {},
		"status=":                         {"21", "20", "5", "4", "3", "2", "1"},
		"status=active&attention=true":    {},
		"status=searching&attention=true": {"5"},
		"q=cr%C3%A8me":                    {"20"},
		"q=CRE%CC%80ME":                   {"20"},
		"q=%C3%A9mile":                    {"20"},
		"q=++%C3%89MILE+%0A":              {"20"},
		"q=100%25_":                       {"21"},
		"q=%25":                           {"21"},
		"q=_":                             {"21"},
		"q=book&status=completed":         {"2", "1"},
		"q=nothing":                       {},
		"page=abc":                        {"21", "20", "5", "4", "3", "2", "1"},
		"page=-3":                         {"21", "20", "5", "4", "3", "2", "1"},
		"page=99":                         {"21", "20", "5", "4", "3", "2", "1"},
	}
	for query, want := range cases {
		body := requestsBody(t, client.get("/preview/api/v1/requests?"+query))
		if got := itemIDs(body); !reflect.DeepEqual(got, want) {
			t.Errorf("%q: got %v want %v", query, got, want)
		}
		if !reflect.DeepEqual(body["counts"], map[string]any{"attention": 2.0, "active": 2.0}) {
			t.Errorf("%q counts %v", query, body["counts"])
		}
	}
	echoed := requestsBody(t, client.get("/preview/api/v1/requests?status=active&attention=true&q=+"+strings.Repeat("é", 205)))["filter"]
	if !reflect.DeepEqual(echoed, map[string]any{"status": "active", "attention": true, "q": strings.Repeat("é", 200)}) {
		t.Fatalf("filter echo %v", echoed)
	}
	for _, query := range []string{"status=bogus", "status=Active", "status=a&status=b", "q=a&q=b", "page=1&page=2", "attention=true&attention=true", "q=%ff", "q=%zz"} {
		recorder := client.get("/preview/api/v1/requests?" + query)
		if recorder.Code != http.StatusUnprocessableEntity || errorCode(t, recorder) != "invalid_query" || recorder.Header().Get("Cache-Control") != "private, no-store" {
			t.Errorf("%q: %d %s", query, recorder.Code, recorder.Body.String())
		}
	}
}

func TestRequestPagesHoldTwentyFiveInAStableNewestFirstOrderAndClampLikeRails(t *testing.T) {
	h := newBrowserHarness(t, nil)
	livetest.Exec(t, h.path, `INSERT INTO books (id, title, book_type) VALUES (1, 'Shared', 1)`)
	for id := 1; id <= 60; id++ {
		h.request(seededRequest{id: id, book: 1, user: 2, status: 0, attention: 0, created: fmt.Sprintf("2026-11-%02d 08:00:00", 1+id/3)})
	}
	client := h.client()
	client.signIn("bob", bobPassword)
	var seen []string
	for page := 1; page <= 3; page++ {
		body := requestsBody(t, client.get("/preview/api/v1/requests?page="+strconv.Itoa(page)))
		if body["page"] != float64(page) || body["total"] != 60.0 || body["total_pages"] != 3.0 {
			t.Fatalf("page %d: %v", page, body)
		}
		seen = append(seen, itemIDs(body)...)
	}
	var want []string
	for id := 60; id >= 1; id-- {
		want = append(want, strconv.Itoa(id))
	}
	if !reflect.DeepEqual(seen, want) {
		t.Fatalf("order %v", seen)
	}
	last := requestsBody(t, client.get("/preview/api/v1/requests?page=+0_0_7x"))
	if last["page"] != 3.0 || len(last["items"].([]any)) != 10 {
		t.Fatalf("clamp %v", last["page"])
	}
	if first := requestsBody(t, client.get("/preview/api/v1/requests?page=0")); first["page"] != 1.0 {
		t.Fatalf("zero %v", first["page"])
	}
}

func TestOlderAndUnknownRequestValuesAreShownHonestly(t *testing.T) {
	h := newBrowserHarness(t, nil)
	livetest.Exec(t, h.path, `INSERT INTO books (id, title, book_type, file_path) VALUES (1, 'Future', 7, '/elsewhere/Future.epub'), (2, 'Odd cover', 1, NULL)`)
	livetest.Exec(t, h.path, `UPDATE books SET cover_url = 'https://covers.example.test/a b.jpg' WHERE id = 2`)
	h.request(seededRequest{id: 1, book: 1, user: 2, status: 9, attention: nil, created: "2026-11-01 08:00:00", completed: "2026-11-02 08:00:00"})
	h.request(seededRequest{id: 2, book: 2, user: 2, status: 3, attention: 0, created: "2026-11-01 07:00:00"})
	h.download(2, 7, 50)
	h.download(2, 1, nil)
	client := h.client()
	client.signIn("bob", bobPassword)
	body := requestsBody(t, client.get("/preview/api/v1/requests"))
	items := body["items"].([]any)
	future, odd := items[0].(map[string]any), items[1].(map[string]any)
	if future["status"] != "unknown" || future["book_type"] != "unknown" || future["attention_needed"] != false || !reflect.DeepEqual(future["library"], map[string]any{"state": "unavailable"}) {
		t.Fatalf("future %v", future)
	}
	if odd["download_percent"] != nil || odd["cover"].(map[string]any)["url"] != nil {
		t.Fatalf("odd %v", odd)
	}
	detail := requestsBody(t, client.get("/preview/api/v1/requests/2"))["request"].(map[string]any)
	if !reflect.DeepEqual(detail["downloads"], []any{map[string]any{"status": "downloading", "progress": nil}, map[string]any{"status": "unknown", "progress": nil}}) {
		t.Fatalf("downloads %v", detail["downloads"])
	}
	livetest.Exec(t, h.path, `UPDATE requests SET created_at = 'yesterday' WHERE id = 2`)
	if recorder := client.get("/preview/api/v1/requests"); recorder.Code != http.StatusNotImplemented || errorCode(t, recorder) != "unsupported_stored_value" {
		t.Fatalf("unreadable timestamp %d %s", recorder.Code, recorder.Body.String())
	}
}

func TestRequestRoutesKeepTheBrowserGuardsAnswerOnlyGetAndWriteNothing(t *testing.T) {
	h := newRequestsHarness(t)
	client := h.client()
	for _, path := range []string{"/preview/api/v1/requests", "/preview/api/v1/requests/1"} {
		if recorder := client.send(http.MethodGet, path, "", map[string]string{"X-Shelfarr-Account": "2"}); recorder.Code != http.StatusUnauthorized || errorCode(t, recorder) != "signed_out" {
			t.Fatalf("signed out %s %d", path, recorder.Code)
		}
	}
	client.signIn("bob", bobPassword)
	before := livetest.Query(t, h.path, `SELECT * FROM requests ORDER BY id`)
	downloads := livetest.Query(t, h.path, `SELECT * FROM downloads ORDER BY id`)
	for _, path := range []string{"/preview/api/v1/requests", "/preview/api/v1/requests/1"} {
		if recorder := client.send(http.MethodGet, path, "", map[string]string{"X-Shelfarr-Account": "1"}); recorder.Code != http.StatusUnauthorized || errorCode(t, recorder) != "account_changed" {
			t.Fatalf("other account %s %d", path, recorder.Code)
		}
		if recorder := client.send(http.MethodGet, path, "", nil); recorder.Code != http.StatusUnauthorized || errorCode(t, recorder) != "account_changed" {
			t.Fatalf("no account %s %d", path, recorder.Code)
		}
		for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodHead} {
			recorder := client.send(method, path, "", map[string]string{"X-Shelfarr-Account": "2"})
			if recorder.Code != http.StatusMethodNotAllowed || recorder.Header().Get("Allow") != "GET" || recorder.Header().Get("Cache-Control") != "private, no-store" {
				t.Fatalf("%s %s: %d %v", method, path, recorder.Code, recorder.Header())
			}
		}
	}
	if !reflect.DeepEqual(before, livetest.Query(t, h.path, `SELECT * FROM requests ORDER BY id`)) || !reflect.DeepEqual(downloads, livetest.Query(t, h.path, `SELECT * FROM downloads ORDER BY id`)) {
		t.Fatal("a read changed request or download rows")
	}
	for _, path := range []string{"/api/consumer/v1/requests", "/api/consumer/v1/requests/1"} {
		if recorder := h.harness.do(http.MethodGet, path, authorised()); recorder.Code != http.StatusNotImplemented || errorCode(t, recorder) != "not_implemented_in_go_runtime" {
			t.Fatalf("native %s %d", path, recorder.Code)
		}
	}
}

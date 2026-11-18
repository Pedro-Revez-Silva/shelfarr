//go:build linux

package gohttp

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"runtime"
	"strings"
	"sync"
	"testing"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/livetest"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/openlibrary"
)

const searchAnswer = `{"numFound":4,"docs":[
{"key":"/works/OL27448W","title":"The Lord of the Rings","author_name":["J.R.R. Tolkien"],"first_publish_year":1954,"cover_i":14625765,"edition_count":256},
{"key":"/works/OL82563W","title":"Harbor Panels","author_name":["H. Panel"],"edition_count":2},
{"key":"/works/OL10W","title":"Pending Only"},
{"key":"/works/OL11W","title":"Near Miss","cover_i":-1}
]}`

type upstream struct {
	mutex    sync.Mutex
	requests []*http.Request
	respond  func(*http.Request) (*http.Response, error)
}

func (u *upstream) RoundTrip(request *http.Request) (*http.Response, error) {
	u.mutex.Lock()
	u.requests = append(u.requests, request)
	respond := u.respond
	u.mutex.Unlock()
	return respond(request)
}

func (u *upstream) count() int {
	u.mutex.Lock()
	defer u.mutex.Unlock()
	return len(u.requests)
}

func jsonAnswer(status int, body string, headers ...string) func(*http.Request) (*http.Response, error) {
	return func(*http.Request) (*http.Response, error) {
		header := http.Header{"Content-Type": {"application/json"}}
		for index := 0; index+1 < len(headers); index += 2 {
			header.Set(headers[index], headers[index+1])
		}
		return &http.Response{StatusCode: status, Header: header, Body: io.NopCloser(strings.NewReader(body))}, nil
	}
}

func newDiscoverHarness(t *testing.T, enabled bool) (*browserHarness, *upstream) {
	t.Helper()
	h := newBrowserHarness(t, func(config *Config) { config.OpenLibrarySearch = enabled })
	fake := &upstream{respond: jsonAnswer(http.StatusOK, searchAnswer)}
	if enabled {
		if h.app.openLibrary == nil {
			t.Fatal("the switch did not create a client")
		}
		h.app.openLibrary = openlibrary.New("Shelfarr/test", fake, h.clock.Now)
	} else if h.app.openLibrary != nil {
		t.Fatal("a client exists without the switch")
	}
	return h, fake
}

func (c *browserClient) discover(rawQuery string) *httptest.ResponseRecorder {
	path := "/preview/api/v1/discover"
	if rawQuery != "" {
		path += "?" + rawQuery
	}
	return c.get(path)
}

func discoverBody(t *testing.T, recorder *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	if recorder.Code != http.StatusOK || recorder.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatalf("discover %d %v %s", recorder.Code, recorder.Header(), recorder.Body.String())
	}
	return decoded(t, recorder)
}

func provider() map[string]any {
	return map[string]any{"name": "Open Library", "url": "https://openlibrary.org"}
}

func TestDiscoverIsOffUntilTheOperatorSwitchesItOnAndNeverContactsOpenLibraryThen(t *testing.T) {
	h, _ := newDiscoverHarness(t, false)
	client := h.client()
	client.signIn("alice", alicePassword)
	for _, query := range []string{"", "q=dune"} {
		got := discoverBody(t, client.discover(query))
		want := map[string]any{"account": "1", "provider": provider(), "search": "server_off", "query": nil, "items": []any{}}
		if query != "" {
			want["query"] = "dune"
		}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("%q: %v", query, got)
		}
	}
	if strings.Contains(h.logs.String(), "open_library") {
		t.Fatalf("logged an outbound search: %s", h.logs.String())
	}
}

func TestDiscoverKeepsTheBrowserGuardsAndAnswersOnlyGet(t *testing.T) {
	h, fake := newDiscoverHarness(t, true)
	client := h.client()
	if recorder := client.send(http.MethodGet, "/preview/api/v1/discover?q=dune", "", map[string]string{"X-Shelfarr-Account": "1"}); recorder.Code != http.StatusUnauthorized || errorCode(t, recorder) != "signed_out" {
		t.Fatalf("signed out %d", recorder.Code)
	}
	client.signIn("alice", alicePassword)
	for _, header := range []map[string]string{nil, {"X-Shelfarr-Account": "2"}} {
		if recorder := client.send(http.MethodGet, "/preview/api/v1/discover?q=dune", "", header); recorder.Code != http.StatusUnauthorized || errorCode(t, recorder) != "account_changed" {
			t.Fatalf("header %v answered %d", header, recorder.Code)
		}
	}
	for _, method := range []string{http.MethodHead, http.MethodPost, http.MethodPut, http.MethodDelete} {
		recorder := client.send(method, "/preview/api/v1/discover?q=dune", "", map[string]string{"X-Shelfarr-Account": "1"})
		if recorder.Code != http.StatusMethodNotAllowed || recorder.Header().Get("Allow") != "GET" {
			t.Fatalf("%s answered %d %v", method, recorder.Code, recorder.Header())
		}
	}
	if fake.count() != 0 {
		t.Fatalf("a refused request reached Open Library %d times", fake.count())
	}
	outsider := newDiscoverOutsider(t)
	if recorder := outsider.discover("q=dune"); recorder.Code != http.StatusNotFound {
		t.Fatalf("outsider %d", recorder.Code)
	}
	if native := h.do(http.MethodGet, "/api/consumer/v1/discover?q=dune", authorised()); native.Code != http.StatusNotImplemented || errorCode(t, native) != "not_implemented_in_go_runtime" {
		t.Fatalf("native discover %d", native.Code)
	}
}

func newDiscoverOutsider(t *testing.T) *browserClient {
	t.Helper()
	h, _ := newDiscoverHarness(t, true)
	h.app.previewIDs = map[string]bool{"2": true}
	client := h.client()
	token, _ := client.bootstrap()
	client.login("bob", bobPassword, token)
	h.app.previewIDs = map[string]bool{"1": true}
	client.account = "2"
	return client
}

func TestDiscoverFollowsTheShelfarrOpenLibrarySettingsWithoutWritingProviderHealth(t *testing.T) {
	cases := []struct {
		name   string
		setup  []string
		search string
		retry  any
		limit  string
	}{
		{"defaults", nil, "available", nil, "20"},
		{"disabled", []string{`INSERT INTO settings (key, value, value_type) VALUES ('open_library_enabled', 'false', 'boolean')`}, "provider_disabled", nil, ""},
		{"disabled as zero", []string{`INSERT INTO settings (key, value, value_type) VALUES ('open_library_enabled', '0', 'boolean')`}, "provider_disabled", nil, ""},
		{"enabled", []string{`INSERT INTO settings (key, value, value_type) VALUES ('open_library_enabled', 'true', 'boolean')`}, "available", nil, "20"},
		{"blank means default", []string{`INSERT INTO settings (key, value, value_type) VALUES ('open_library_enabled', '', 'boolean')`}, "available", nil, "20"},
		{"another provider selected", []string{`INSERT INTO settings (key, value, value_type) VALUES ('metadata_source', ' hardcover' || char(10), 'string')`}, "provider_not_selected", nil, ""},
		{"google selected", []string{`INSERT INTO settings (key, value, value_type) VALUES ('metadata_source', 'google_books', 'string')`}, "provider_not_selected", nil, ""},
		{"open library selected", []string{`INSERT INTO settings (key, value, value_type) VALUES ('metadata_source', 'openlibrary', 'string')`}, "available", nil, "20"},
		{"auto", []string{`INSERT INTO settings (key, value, value_type) VALUES ('metadata_source', 'auto', 'string')`}, "available", nil, "20"},
		{"unknown source", []string{`INSERT INTO settings (key, value, value_type) VALUES ('metadata_source', 'Hardcover', 'string')`}, "available", nil, "20"},
		{"configured limit", []string{`INSERT INTO settings (key, value, value_type) VALUES ('open_library_search_limit', '7', 'integer')`}, "available", nil, "7"},
		{"large limit", []string{`INSERT INTO settings (key, value, value_type) VALUES ('open_library_search_limit', '100', 'integer')`}, "available", nil, "20"},
		{"zero limit", []string{`INSERT INTO settings (key, value, value_type) VALUES ('open_library_search_limit', '0', 'integer')`}, "available", nil, "1"},
		{"rails backoff", []string{`INSERT INTO metadata_provider_statuses (provider, status, rate_limited_until) VALUES ('openlibrary', 'rate_limited', '2026-11-15 12:01:30.623456')`}, "provider_paused", float64(91), ""},
		{"rails backoff over", []string{`INSERT INTO metadata_provider_statuses (provider, status, rate_limited_until) VALUES ('openlibrary', 'down', '2026-11-15 12:00:00.123456')`}, "available", nil, "20"},
		{"another provider's backoff", []string{`INSERT INTO metadata_provider_statuses (provider, status, rate_limited_until) VALUES ('hardcover', 'rate_limited', '2026-11-16 12:00:00')`}, "available", nil, "20"},
		{"auth failure", []string{`INSERT INTO metadata_provider_statuses (provider, status) VALUES ('openlibrary', 'auth_failed')`}, "provider_paused", nil, ""},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			h, fake := newDiscoverHarness(t, true)
			for _, statement := range test.setup {
				livetest.Exec(t, h.path, statement)
			}
			before := livetest.Query(t, h.path, `SELECT provider, status, CAST(rate_limited_until AS TEXT), failure_count, CAST(updated_at AS TEXT) FROM metadata_provider_statuses ORDER BY provider`)
			client := h.client()
			client.signIn("alice", alicePassword)
			status := discoverBody(t, client.discover(""))
			if status["search"] != test.search || status["retry_after"] != test.retry || fake.count() != 0 {
				t.Fatalf("status %v after %d searches", status, fake.count())
			}
			got := discoverBody(t, client.discover("q=dune"))
			if got["search"] != test.search {
				t.Fatalf("search %v", got)
			}
			if test.limit == "" {
				if fake.count() != 0 || len(got["items"].([]any)) != 0 {
					t.Fatalf("searched while %s: %v", test.search, got)
				}
			} else if fake.count() != 1 || fake.requests[0].URL.Query().Get("limit") != test.limit {
				t.Fatalf("limit %v", fake.requests)
			}
			after := livetest.Query(t, h.path, `SELECT provider, status, CAST(rate_limited_until AS TEXT), failure_count, CAST(updated_at AS TEXT) FROM metadata_provider_statuses ORDER BY provider`)
			if !reflect.DeepEqual(before, after) {
				t.Fatalf("provider health changed: %v -> %v", before, after)
			}
		})
	}
}

func TestDiscoverRefusesSettingsItCannotReadInsteadOfGuessing(t *testing.T) {
	for _, statement := range []string{
		`INSERT INTO settings (key, value, value_type) VALUES ('open_library_enabled', 'yes', 'string')`,
		`INSERT INTO settings (key, value, value_type) VALUES ('open_library_search_limit', '20 results', 'integer')`,
		`INSERT INTO settings (key, value, value_type) VALUES ('metadata_source', '["openlibrary"]', 'json')`,
		`INSERT INTO metadata_provider_statuses (provider, status, rate_limited_until) VALUES ('openlibrary', 'rate_limited', 'soon')`,
	} {
		h, fake := newDiscoverHarness(t, true)
		livetest.Exec(t, h.path, statement)
		client := h.client()
		client.signIn("alice", alicePassword)
		if recorder := client.discover("q=dune"); recorder.Code != http.StatusNotImplemented || errorCode(t, recorder) != "unsupported_stored_value" || fake.count() != 0 {
			t.Fatalf("%s: %d %s", statement, recorder.Code, recorder.Body.String())
		}
	}
}

func TestDiscoverRefusesQueriesItWouldNotSend(t *testing.T) {
	h, fake := newDiscoverHarness(t, true)
	client := h.client()
	client.signIn("alice", alicePassword)
	for _, query := range []string{"q=", "q=%20%09", "q=" + strings.Repeat("a", 201), "q=a&q=b", "q=%zz", "q=a;b", "q=line%0Abreak", "q=%FF"} {
		if recorder := client.discover(query); recorder.Code != http.StatusUnprocessableEntity || errorCode(t, recorder) != "invalid_query" {
			t.Fatalf("%q answered %d %s", query, recorder.Code, recorder.Body.String())
		}
	}
	if fake.count() != 0 {
		t.Fatalf("an invalid query reached Open Library")
	}
	got := discoverBody(t, client.discover("q=%20%20"+strings.Repeat("%C3%A9", 200)+"%20&other=ignored"))
	if got["query"] != strings.Repeat("é", 200) || fake.count() != 1 || fake.requests[0].URL.Query().Get("q") != strings.Repeat("é", 200) {
		t.Fatalf("bounded query %v", got["query"])
	}
}

func TestDiscoverLinksOnlyAcquiredCopiesOfTheSameOpenLibraryWork(t *testing.T) {
	h, fake := newDiscoverHarness(t, true)
	for _, statement := range []string{
		`INSERT INTO books (id, title, file_path, book_type, open_library_work_id) VALUES (10, 'Rings ebook', '/library/rings.epub', 1, 'OL27448W')`,
		`INSERT INTO books (id, title, file_path, book_type, open_library_work_id) VALUES (11, 'Rings audio', '/library/rings', 0, 'OL27448W')`,
		`INSERT INTO books (id, title, file_path, book_type, open_library_work_id) VALUES (12, 'Rings ebook again', '/library/rings-2.epub', 1, 'OL27448W')`,
		`INSERT INTO books (id, title, file_path, book_type, open_library_work_id) VALUES (13, 'Rings ebook requested', NULL, 1, 'OL27448W')`,
		`INSERT INTO books (id, title, file_path, book_type, open_library_work_id) VALUES (14, 'Harbor comic', '/library/harbor.cbz', 2, 'OL82563W')`,
		`INSERT INTO books (id, title, file_path, book_type, open_library_work_id) VALUES (15, 'Pending only', '   ', 1, 'OL10W')`,
		`INSERT INTO books (id, title, file_path, book_type, open_library_work_id) VALUES (16, 'Near Miss', '/library/near.epub', 1, 'ol11w')`,
		`INSERT INTO books (id, title, file_path, book_type, open_library_work_id) VALUES (17, 'Near Miss', '/library/near2.epub', 1, ' OL11W')`,
		`INSERT INTO books (id, title, file_path, book_type, open_library_work_id) VALUES (18, 'Near Miss', '/library/near3.epub', 1, '/works/OL11W')`,
		`INSERT INTO books (id, title, file_path, book_type, open_library_work_id) VALUES (19, 'Near Miss', '/library/near4.epub', 1, NULL)`,
		`INSERT INTO books (id, title, file_path, book_type, open_library_work_id) VALUES (20, 'Odd type', '/library/odd', 7, 'OL11W')`,
	} {
		livetest.Exec(t, h.path, statement)
	}
	client := h.client()
	client.signIn("alice", alicePassword)
	got := discoverBody(t, client.discover("q=the+lord+%26+rings"))
	want := map[string]any{
		"account": "1", "provider": provider(), "search": "available", "query": "the lord & rings",
		"items": []any{
			map[string]any{"id": "OL27448W", "title": "The Lord of the Rings", "author": "J.R.R. Tolkien", "first_publish_year": float64(1954), "edition_count": float64(256),
				"cover_url": "https://covers.openlibrary.org/b/id/14625765-M.jpg", "source_url": "https://openlibrary.org/works/OL27448W",
				"library": []any{map[string]any{"book_type": "ebook", "publication_id": "12"}, map[string]any{"book_type": "audiobook", "publication_id": "11"}}},
			map[string]any{"id": "OL82563W", "title": "Harbor Panels", "author": "H. Panel", "first_publish_year": nil, "edition_count": float64(2), "cover_url": nil,
				"source_url": "https://openlibrary.org/works/OL82563W", "library": []any{map[string]any{"book_type": "comicbook", "publication_id": "14"}}},
			map[string]any{"id": "OL10W", "title": "Pending Only", "author": nil, "first_publish_year": nil, "edition_count": nil, "cover_url": nil,
				"source_url": "https://openlibrary.org/works/OL10W", "library": []any{}},
			map[string]any{"id": "OL11W", "title": "Near Miss", "author": nil, "first_publish_year": nil, "edition_count": nil, "cover_url": nil,
				"source_url": "https://openlibrary.org/works/OL11W", "library": []any{}},
		},
	}
	if !reflect.DeepEqual(got, want) {
		encoded, _ := json.MarshalIndent(got, "", " ")
		t.Fatalf("answer %s", encoded)
	}
	if fake.count() != 1 || fake.requests[0].URL.Query().Get("q") != "the lord & rings" || fake.requests[0].Header.Get("Cookie") != "" || fake.requests[0].Header.Get("X-Shelfarr-Account") != "" {
		t.Fatalf("upstream request %v", fake.requests[0])
	}
	if logs := h.logs.String(); strings.Contains(logs, "rings") || strings.Contains(logs, "Tolkien") || !strings.Contains(logs, `"msg":"open_library","outcome":"ok","results":4`) {
		t.Fatalf("logs %s", logs)
	}
}

func TestOpenLibraryFailuresAreNamedAndNothingIsRetried(t *testing.T) {
	cases := []struct {
		name    string
		respond func(*http.Request) (*http.Response, error)
		status  int
		code    string
		retry   string
	}{
		{"server error", jsonAnswer(http.StatusServiceUnavailable, `{"error":"x"}`), http.StatusBadGateway, "search_failed", ""},
		{"redirect", jsonAnswer(http.StatusFound, ``, "Location", "http://127.0.0.1:9/"), http.StatusBadGateway, "search_failed", ""},
		{"garbage", jsonAnswer(http.StatusOK, `<html>`), http.StatusBadGateway, "search_failed", ""},
		{"unreachable", func(*http.Request) (*http.Response, error) { return nil, errors.New("dial: refused") }, http.StatusServiceUnavailable, "search_unavailable", ""},
		{"rate limited", jsonAnswer(http.StatusTooManyRequests, `{}`, "Retry-After", "30"), http.StatusTooManyRequests, "search_rate_limited", "30"},
	}
	for _, test := range cases {
		h, fake := newDiscoverHarness(t, true)
		fake.respond = test.respond
		client := h.client()
		client.signIn("alice", alicePassword)
		recorder := client.discover("q=dune")
		if recorder.Code != test.status || errorCode(t, recorder) != test.code || recorder.Header().Get("Retry-After") != test.retry || fake.count() != 1 {
			t.Fatalf("%s: %d %s %v after %d", test.name, recorder.Code, recorder.Body.String(), recorder.Header(), fake.count())
		}
		if strings.Contains(recorder.Body.String(), "127.0.0.1") || strings.Contains(h.logs.String(), "dune") || strings.Contains(h.logs.String(), "refused") {
			t.Fatalf("%s leaked %s %s", test.name, recorder.Body.String(), h.logs.String())
		}
	}
}

func TestDiscoverSpendsAtMostOneOpenLibrarySearchASecondAcrossAccounts(t *testing.T) {
	h, fake := newDiscoverHarness(t, true)
	alice := h.client()
	alice.signIn("alice", alicePassword)
	bob := h.client()
	bob.signIn("bob", bobPassword)
	if recorder := alice.discover("q=dune"); recorder.Code != http.StatusOK {
		t.Fatalf("first %d", recorder.Code)
	}
	recorder := bob.discover("q=emma")
	if recorder.Code != http.StatusTooManyRequests || errorCode(t, recorder) != "search_rate_limited" || recorder.Header().Get("Retry-After") != "1" || fake.count() != 1 {
		t.Fatalf("second %d %v", recorder.Code, recorder.Header())
	}
	if status := discoverBody(t, bob.discover("")); status["search"] != "available" {
		t.Fatalf("status while throttled %v", status)
	}
	h.clock.Advance(openlibrary.MinimumInterval)
	if recorder := bob.discover("q=emma"); recorder.Code != http.StatusOK || fake.count() != 2 {
		t.Fatalf("after a second %d", recorder.Code)
	}
}

func TestADisconnectedBrowserCancelsTheOpenLibraryRequest(t *testing.T) {
	h, fake := newDiscoverHarness(t, true)
	cancelled := make(chan struct{})
	fake.respond = func(request *http.Request) (*http.Response, error) {
		<-request.Context().Done()
		close(cancelled)
		return nil, request.Context().Err()
	}
	client := h.client()
	client.signIn("alice", alicePassword)
	request := httptest.NewRequest(http.MethodGet, "/preview/api/v1/discover?q=dune", nil)
	for name, value := range client.cookies {
		request.AddCookie(&http.Cookie{Name: name, Value: value})
	}
	request.Header.Set("X-Shelfarr-Account", "1")
	ctx, cancel := context.WithCancel(request.Context())
	request = request.WithContext(ctx)
	go func() {
		for fake.count() == 0 {
			runtime.Gosched()
		}
		cancel()
	}()
	recorder := httptest.NewRecorder()
	h.app.ServeHTTP(recorder, request)
	<-cancelled
	if !strings.Contains(h.logs.String(), `"outcome":"cancelled"`) || !strings.Contains(h.logs.String(), `"status":499`) {
		t.Fatalf("logs %s", h.logs.String())
	}
}

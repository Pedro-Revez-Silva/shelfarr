//go:build linux

package gohttp

import (
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/livetest"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
)

const (
	overviewPath   = "/preview/api/v1/admin/overview"
	healthSecret   = "Failed to connect to http://admin:hunter2@10.0.0.5:9696/api?apikey=s3cr3t"
	overviewTables = `SELECT (SELECT group_concat(id || ':' || service || ':' || status || ':' || IFNULL(last_check_at, '-'), ',') FROM system_healths), (SELECT group_concat(id || ':' || user_id, ',') FROM sessions), (SELECT group_concat(id || ':' || role || ':' || IFNULL(deleted_at, '-'), ',') FROM users)`
)

func newOverviewHarness(t *testing.T) *browserHarness {
	t.Helper()
	h := newBrowserHarness(t, nil)
	livetest.Exec(t, h.path, `INSERT INTO users (id, username, name, deleted_at) VALUES (3, 'carol', 'Carol', '2026-11-01 10:00:00'), (4, 'dave', 'Dave', NULL)`)
	h.addBook(10, "Opened Book", store.BookTypeEbook, h.file("Opened Book.epub", "PK epub"))
	livetest.Exec(t, h.path, `INSERT INTO books (id, title, book_type) VALUES (11, 'Wanted', 0), (12, 'Heard', 1), (13, 'Drawn', 2)`)
	for _, r := range []seededRequest{
		{id: 1, book: 11, user: 2, status: 0, attention: 0, created: "2026-11-10 08:00:00"},
		{id: 2, book: 11, user: 2, status: 1, attention: 1, created: "2026-11-10 08:00:00"},
		{id: 3, book: 12, user: 1, status: 3, attention: 0, created: "2026-11-10 08:00:00"},
		{id: 4, book: 12, user: 4, status: 4, attention: nil, created: "2026-11-10 08:00:00"},
		{id: 5, book: 13, user: 3, status: 2, attention: 1, created: "2026-11-10 08:00:00"},
		{id: 6, book: 13, user: 2, status: 5, attention: 0, created: "2026-11-10 08:00:00"},
		{id: 7, book: 10, user: 2, status: 6, attention: 1, created: "2026-11-10 08:00:00"},
		{id: 8, book: 10, user: 1, status: 7, attention: 0, created: "2026-11-10 08:00:00"},
	} {
		h.request(r)
	}
	livetest.Exec(t, h.path, `INSERT INTO system_healths (id, service, status, message, last_check_at, last_success_at) VALUES
		(1, 'prowlarr', 0, 'legacy alias', '2026-11-15 11:59:00', '2026-11-15 11:59:00'),
		(2, 'indexer', 2, ?, '2026-11-15 11:55:00.123456', '2026-11-01 09:00:00'),
		(3, 'download_client', 1, 'qBittorrent refused the login', '2026-11-12 08:00:00', NULL),
		(4, 'output_paths', 0, 'All paths writable', '2026-10-01 07:30:00', '2026-10-01 07:30:00'),
		(5, 'audiobookshelf', 3, 'Not configured', NULL, NULL),
		(6, 'hardcover', 9, 'from a newer release', '2026-11-15 11:00:00', NULL),
		(7, 'unrelated_service', 2, 'not one of the six', '2026-11-15 11:00:00', NULL)`, healthSecret)
	return h
}

func overviewOf(t *testing.T, recorder *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	if recorder.Code != http.StatusOK || recorder.Header().Get("Cache-Control") != "private, no-store" || recorder.Header().Get("Content-Type") != "application/json; charset=utf-8" {
		t.Fatalf("overview %d %v %s", recorder.Code, recorder.Header(), recorder.Body.String())
	}
	return decoded(t, recorder)
}

func TestAnAdminSeesTheRailsCountsAndTheSixSavedHealthResultsWithoutMessages(t *testing.T) {
	h := newOverviewHarness(t)
	client := h.client()
	client.signIn("alice", alicePassword)
	before := livetest.Query(t, h.path, overviewTables)
	recorder := client.get(overviewPath)
	body := overviewOf(t, recorder)
	text := func(value string) any { return value }
	want := map[string]any{
		"account": "1",
		"counts":  map[string]any{"users": 3.0, "books": 4.0, "active_requests": 4.0, "attention_requests": 3.0},
		"services": []any{
			map[string]any{"service": "indexer", "status": text("down"), "checked_at": text("2026-11-15T11:55:00.123Z")},
			map[string]any{"service": "download_client", "status": text("degraded"), "checked_at": text("2026-11-12T08:00:00.000Z")},
			map[string]any{"service": "download_paths", "status": nil, "checked_at": nil},
			map[string]any{"service": "output_paths", "status": text("healthy"), "checked_at": text("2026-10-01T07:30:00.000Z")},
			map[string]any{"service": "audiobookshelf", "status": text("not_configured"), "checked_at": nil},
			map[string]any{"service": "hardcover", "status": text("unknown"), "checked_at": text("2026-11-15T11:00:00.000Z")},
		},
	}
	if !reflect.DeepEqual(body, want) {
		t.Fatalf("got %#v", body)
	}
	for _, leaked := range []string{"hunter2", "s3cr3t", "9696", "qBittorrent", "legacy alias", "writable", "newer release", "unrelated", "prowlarr", "last_success", "message"} {
		if strings.Contains(recorder.Body.String(), leaked) {
			t.Errorf("the overview leaked %q", leaked)
		}
	}
	if after := livetest.Query(t, h.path, overviewTables); !reflect.DeepEqual(before, after) {
		t.Fatalf("reading the overview changed rows: %v -> %v", before, after)
	}
}

func TestStoredHealthValuesTheRailsEnumCannotNameAreReportedAsUnknown(t *testing.T) {
	h := newBrowserHarness(t, nil)
	livetest.Exec(t, h.path, `INSERT INTO system_healths (service, status, last_check_at) VALUES ('indexer', 'down', '2026-11-15 11:00:00'), ('download_client', 0, 'yesterday'), ('download_paths', -1, NULL), ('output_paths', 3, '2026-11-15 11:00:00')`)
	client := h.client()
	client.signIn("alice", alicePassword)
	services := overviewOf(t, client.get(overviewPath))["services"].([]any)
	got := []string{}
	for _, service := range services[:4] {
		entry := service.(map[string]any)
		checked, _ := entry["checked_at"].(string)
		got = append(got, entry["service"].(string)+"="+entry["status"].(string)+"@"+checked)
	}
	if want := []string{"indexer=unknown@2026-11-15T11:00:00.000Z", "download_client=unknown@", "download_paths=unknown@", "output_paths=not_configured@2026-11-15T11:00:00.000Z"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v", got)
	}
}

func TestOnlyAnAdminOfTheBoundAccountReceivesTheOverview(t *testing.T) {
	h := newOverviewHarness(t)
	anonymous := h.client().send(http.MethodGet, overviewPath, "", map[string]string{"X-Shelfarr-Account": "1"})
	if anonymous.Code != http.StatusUnauthorized || anonymous.Body.String() != `{"error":"signed_out"}` || anonymous.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatalf("anonymous %d %s", anonymous.Code, anonymous.Body.String())
	}
	member := h.client()
	member.signIn("bob", bobPassword)
	refused := member.get(overviewPath)
	if refused.Code != http.StatusNotFound || refused.Body.String() != `{"error":"not_found"}` || refused.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatalf("member %d %s", refused.Code, refused.Body.String())
	}
	admin := h.client()
	admin.signIn("alice", alicePassword)
	for _, header := range []map[string]string{nil, {"X-Shelfarr-Account": "2"}, {"X-Shelfarr-Account": "01"}} {
		recorder := admin.send(http.MethodGet, overviewPath, "", header)
		if recorder.Code != http.StatusUnauthorized || recorder.Body.String() != `{"error":"account_changed"}` {
			t.Fatalf("%v: %d %s", header, recorder.Code, recorder.Body.String())
		}
	}
	for _, method := range []string{http.MethodHead, http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		recorder := admin.send(method, overviewPath, "", map[string]string{"X-Shelfarr-Account": "1", "Origin": browserOrigin})
		if recorder.Code != http.StatusMethodNotAllowed || recorder.Header().Get("Allow") != http.MethodGet || recorder.Header().Get("Cache-Control") != "private, no-store" {
			t.Fatalf("%s: %d %v", method, recorder.Code, recorder.Header())
		}
	}
	livetest.Exec(t, h.path, `UPDATE users SET role = 0 WHERE id = 1`)
	demoted := admin.get(overviewPath)
	if demoted.Code != http.StatusNotFound || demoted.Body.String() != `{"error":"not_found"}` {
		t.Fatalf("demoted %d %s", demoted.Code, demoted.Body.String())
	}
}

func TestTheOverviewIsHiddenWhenThePreviewIsOffOrTheAdminIsNotListed(t *testing.T) {
	off := newBrowserHarness(t, func(config *Config) { config.PreviewUserIDs = nil })
	recorder := off.client().send(http.MethodGet, overviewPath, "", map[string]string{"X-Shelfarr-Account": "1"})
	if recorder.Code != http.StatusNotFound || recorder.Body.String() != `{"error":"not_found"}` || recorder.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatalf("preview off: %d %s", recorder.Code, recorder.Body.String())
	}
	h := newOverviewHarness(t)
	admin := h.client()
	admin.signIn("alice", alicePassword)
	delete(h.app.previewIDs, "1")
	recorder = admin.get(overviewPath)
	if recorder.Code != http.StatusNotFound || recorder.Body.String() != `{"error":"not_found"}` || recorder.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatalf("unlisted admin: %d %s", recorder.Code, recorder.Body.String())
	}
}

func TestTheOverviewRechecksTheRoleAndSessionInsideItsReadSnapshot(t *testing.T) {
	for _, change := range []struct {
		name, statement, status, body string
	}{
		{"demoted", `UPDATE users SET role = 0 WHERE id = 1`, "404", `{"error":"not_found"}`},
		{"deleted", `UPDATE users SET deleted_at = '2026-11-15 11:00:00' WHERE id = 1`, "401", `{"error":"signed_out"}`},
		{"signed out elsewhere", `DELETE FROM sessions WHERE user_id = 1`, "401", `{"error":"signed_out"}`},
	} {
		t.Run(change.name, func(t *testing.T) {
			h := newOverviewHarness(t)
			client := h.client()
			client.signIn("alice", alicePassword)
			request := httptest.NewRequest(http.MethodGet, overviewPath, nil)
			request.Header.Set("Cookie", sessionCookieName+"="+client.cookies[sessionCookieName])
			session, err := h.app.resume(request.Context(), httptest.NewRecorder(), request)
			if err != nil || session == nil || !session.user.Admin {
				t.Fatalf("resume %v %v", session, err)
			}
			livetest.Exec(t, h.path, change.statement)
			recorder := httptest.NewRecorder()
			h.app.webAdminOverview(recorder, request, *session, &outcome{})
			if got := recorder.Result().Status[:3]; got != change.status || recorder.Body.String() != change.body {
				t.Fatalf("%s %s", got, recorder.Body.String())
			}
		})
	}
}

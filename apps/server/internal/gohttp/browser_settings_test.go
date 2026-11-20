//go:build linux

package gohttp

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/livetest"
)

const (
	metadataSettingsPath = "/preview/api/v1/admin/settings/metadata"
	settingsTable        = `SELECT id, key, IFNULL(value, '<null>'), value_type, IFNULL(category, '<null>'), IFNULL(description, '<null>'), CAST(created_at AS TEXT), CAST(updated_at AS TEXT) FROM settings ORDER BY id`
	unrelatedRows        = `SELECT key, value, value_type, category, description, CAST(created_at AS TEXT), CAST(updated_at AS TEXT) FROM settings WHERE key NOT IN ('open_library_enabled', 'open_library_search_limit') ORDER BY key`
	providerStatusRows   = `SELECT provider, status, IFNULL(CAST(rate_limited_until AS TEXT), '-'), failure_count, CAST(updated_at AS TEXT) FROM metadata_provider_statuses ORDER BY id`
)

type settingsAnswer struct {
	Account     string `json:"account"`
	Error       string `json:"error"`
	Revision    string `json:"revision"`
	OpenLibrary struct {
		Enabled     *bool  `json:"enabled"`
		SearchLimit *int64 `json:"search_limit"`
	} `json:"open_library"`
	Discover struct {
		Search      string `json:"search"`
		ResultLimit *int   `json:"result_limit"`
		MaxResults  int    `json:"max_results"`
		RetryAfter  *int   `json:"retry_after"`
	} `json:"discover"`
}

func seedUnrelatedSettings(t *testing.T, h *browserHarness) {
	t.Helper()
	livetest.Exec(t, h.path, `INSERT INTO settings (key, value, value_type, category, description, created_at, updated_at) VALUES
		('google_books_enabled', 'true', 'boolean', 'google_books', 'Enable Google Books as a metadata provider', '2026-10-01 08:00:00.123456', '2026-10-02 09:00:00.654321'),
		('hardcover_api_token', 'hc-secret-token', 'string', 'hardcover', 'Hardcover token', '2026-10-01 08:00:00', '2026-10-01 08:00:00'),
		('metadata_source', 'auto', 'string', 'hardcover', 'Legacy selector', '2026-10-01 08:00:00', '2026-10-01 08:00:00'),
		('queue_batch_size', '5', 'integer', 'queue', 'Requests per run', '2026-10-01 08:00:00', '2026-10-03 10:00:00')`)
}

func (c *browserClient) saveSettings(token, body string) *httptest.ResponseRecorder {
	return c.send(http.MethodPut, metadataSettingsPath, body, map[string]string{"X-Shelfarr-Account": c.account, "Origin": browserOrigin, "X-CSRF-Token": token})
}

func answerOf(t *testing.T, recorder *httptest.ResponseRecorder, status int) settingsAnswer {
	t.Helper()
	if recorder.Code != status || recorder.Header().Get("Cache-Control") != "private, no-store" || recorder.Header().Get("Content-Type") != "application/json; charset=utf-8" {
		t.Fatalf("settings %d %v %s", recorder.Code, recorder.Header(), recorder.Body.String())
	}
	var answer settingsAnswer
	if err := json.Unmarshal(recorder.Body.Bytes(), &answer); err != nil {
		t.Fatalf("not json: %s", recorder.Body.String())
	}
	return answer
}

func changeBody(revision string, values string) string {
	return `{"revision":"` + revision + `","open_library":` + values + `}`
}

func TestAnAdminReadsTheDefaultsWithoutAnyRowBeingWritten(t *testing.T) {
	h, fake := newDiscoverHarness(t, true)
	seedUnrelatedSettings(t, h)
	client := h.client()
	client.signIn("alice", alicePassword)
	before := livetest.Query(t, h.path, settingsTable)
	recorder := client.get(metadataSettingsPath)
	answerOf(t, recorder, http.StatusOK)
	var body map[string]any
	json.Unmarshal(recorder.Body.Bytes(), &body)
	revision, _ := body["revision"].(string)
	if !settingsRevision.MatchString(revision) {
		t.Fatalf("revision %q", revision)
	}
	want := map[string]any{
		"account":            "1",
		"revision":           revision,
		"open_library":       map[string]any{"enabled": true, "search_limit": 20.0},
		"defaults":           map[string]any{"enabled": true, "search_limit": 20.0},
		"search_limit_range": map[string]any{"min": 1.0, "max": 1000.0},
		"discover":           map[string]any{"search": "available", "result_limit": 20.0, "max_results": 20.0},
	}
	if !reflect.DeepEqual(body, want) {
		t.Fatalf("got %#v", body)
	}
	if strings.Contains(recorder.Body.String(), "hc-secret-token") || strings.Contains(recorder.Body.String(), "google") {
		t.Fatalf("the answer carries other settings: %s", recorder.Body.String())
	}
	if after := livetest.Query(t, h.path, settingsTable); !reflect.DeepEqual(before, after) {
		t.Fatalf("reading changed settings: %v -> %v", before, after)
	}
	if fake.count() != 0 {
		t.Fatalf("reading the settings contacted Open Library %d times", fake.count())
	}
}

func TestStoredRailsFormsAreShownAsRailsReadsThemAndDiscoverKeepsItsOwnCap(t *testing.T) {
	for _, stored := range []struct {
		name      string
		rows      string
		enabled   any
		limit     any
		search    string
		resultCap any
	}{
		{"rails false", `('open_library_enabled', 'false', 'boolean'), ('open_library_search_limit', '15', 'integer')`, false, 15.0, "provider_disabled", nil},
		{"rails f and padded underscored limit", `('open_library_enabled', 'f', 'boolean'), ('open_library_search_limit', ' 0d1_5 ', 'integer')`, false, 15.0, "provider_disabled", nil},
		{"rails one and a larger limit", `('open_library_enabled', '1', 'boolean'), ('open_library_search_limit', '50', 'integer')`, true, 50.0, "available", 20.0},
		{"blank boolean is the default", `('open_library_enabled', '', 'boolean'), ('open_library_search_limit', NULL, 'integer')`, true, 20.0, "available", 20.0},
		{"negative limit", `('open_library_search_limit', '-3', 'integer')`, true, -3.0, "available", 0.0},
		{"huge legacy limit", `('open_library_search_limit', '12345678901234567890', 'integer')`, true, nil, "available", 20.0},
		{"sixteen digits Rails reads exactly", `('open_library_search_limit', '1_000_000_000_000_000', 'integer')`, true, 1e15, "available", 20.0},
		{"blank switch saved as text", `('open_library_enabled', '', 'string')`, nil, 20.0, "available", 20.0},
		{"enabled saved as text", `('open_library_enabled', 'false', 'string')`, nil, 20.0, "settings_unreadable", nil},
		{"limit not a number", `('open_library_search_limit', '12abc', 'integer')`, true, nil, "settings_unreadable", nil},
		{"limit saved as text", `('open_library_search_limit', '12', 'string')`, true, nil, "settings_unreadable", nil},
		{"off with an unreadable limit", `('open_library_enabled', 'off', 'boolean'), ('open_library_search_limit', 'many', 'integer')`, false, nil, "provider_disabled", nil},
	} {
		t.Run(stored.name, func(t *testing.T) {
			h, fake := newDiscoverHarness(t, true)
			livetest.Exec(t, h.path, `INSERT INTO settings (key, value, value_type) VALUES `+stored.rows)
			client := h.client()
			client.signIn("alice", alicePassword)
			recorder := client.get(metadataSettingsPath)
			answerOf(t, recorder, http.StatusOK)
			var body map[string]any
			json.Unmarshal(recorder.Body.Bytes(), &body)
			values := body["open_library"].(map[string]any)
			discover := body["discover"].(map[string]any)
			got := []any{values["enabled"], values["search_limit"], discover["search"], discover["result_limit"]}
			if want := []any{stored.enabled, stored.limit, stored.search, stored.resultCap}; !reflect.DeepEqual(got, want) {
				t.Fatalf("got %v want %v", got, want)
			}
			if fake.count() != 0 {
				t.Fatal("reading the settings contacted Open Library")
			}
		})
	}
}

func TestDiscoverAvailabilityFollowsTheServerSwitchTheSourceAndTheBackoff(t *testing.T) {
	off := newBrowserHarness(t, nil)
	client := off.client()
	client.signIn("alice", alicePassword)
	if answer := answerOf(t, client.get(metadataSettingsPath), http.StatusOK); answer.Discover.Search != "server_off" || answer.Discover.ResultLimit != nil || *answer.OpenLibrary.Enabled != true {
		t.Fatalf("server off %+v", answer)
	}
	h, fake := newDiscoverHarness(t, true)
	admin := h.client()
	token := admin.signIn("alice", alicePassword)
	livetest.Exec(t, h.path, `INSERT INTO settings (key, value, value_type) VALUES ('metadata_source', ' hardcover ', 'string')`)
	if answer := answerOf(t, admin.get(metadataSettingsPath), http.StatusOK); answer.Discover.Search != "provider_not_selected" {
		t.Fatalf("source %+v", answer)
	}
	livetest.Exec(t, h.path, `UPDATE settings SET value = 'auto' WHERE key = 'metadata_source'`)
	livetest.Exec(t, h.path, `INSERT INTO metadata_provider_statuses (provider, status, rate_limited_until) VALUES ('openlibrary', 'rate_limited', '2026-11-15 12:01:30.123456')`)
	answer := answerOf(t, admin.get(metadataSettingsPath), http.StatusOK)
	if answer.Discover.Search != "provider_paused" || answer.Discover.RetryAfter == nil || *answer.Discover.RetryAfter != 90 || *answer.Discover.ResultLimit != 20 {
		t.Fatalf("paused %+v", answer.Discover)
	}
	statuses := livetest.Query(t, h.path, providerStatusRows)
	saved := answerOf(t, admin.saveSettings(token, changeBody(answer.Revision, `{"search_limit":12}`)), http.StatusOK)
	if saved.Discover.Search != "provider_paused" || *saved.Discover.ResultLimit != 12 {
		t.Fatalf("a save lifted the pause %+v", saved.Discover)
	}
	if after := livetest.Query(t, h.path, providerStatusRows); !reflect.DeepEqual(statuses, after) {
		t.Fatalf("saving changed the provider status: %v -> %v", statuses, after)
	}
	if fake.count() != 0 {
		t.Fatal("saving contacted Open Library")
	}
}

func TestOpenLibrarysOwnRateLimitInThisProcessIsReportedAsAPause(t *testing.T) {
	h, fake := newDiscoverHarness(t, true)
	fake.respond = jsonAnswer(http.StatusTooManyRequests, `{}`, "Retry-After", "30")
	client := h.client()
	client.signIn("alice", alicePassword)
	if recorder := client.discover("q=dune"); recorder.Code != http.StatusTooManyRequests {
		t.Fatalf("discover %d %s", recorder.Code, recorder.Body.String())
	}
	answer := answerOf(t, client.get(metadataSettingsPath), http.StatusOK)
	if answer.Discover.Search != "provider_paused" || answer.Discover.RetryAfter == nil || *answer.Discover.RetryAfter != 30 || *answer.Discover.ResultLimit != 20 {
		t.Fatalf("upstream pause %+v", answer.Discover)
	}
	h.clock.Advance(31 * time.Second)
	if answer := answerOf(t, client.get(metadataSettingsPath), http.StatusOK); answer.Discover.Search != "available" || answer.Discover.RetryAfter != nil {
		t.Fatalf("after the pause %+v", answer.Discover)
	}
	if fake.count() != 1 {
		t.Fatalf("Open Library was asked %d times", fake.count())
	}
	if recorder := client.discover("q=dune"); recorder.Code != http.StatusTooManyRequests {
		t.Fatalf("second 429 %d", recorder.Code)
	}
	livetest.Exec(t, h.path, `INSERT INTO metadata_provider_statuses (provider, status, rate_limited_until) VALUES ('openlibrary', 'rate_limited', '2026-11-15 12:00:36.123456')`)
	if answer := answerOf(t, client.get(metadataSettingsPath), http.StatusOK); answer.Discover.Search != "provider_paused" || *answer.Discover.RetryAfter != 30 {
		t.Fatalf("the later of both pauses %+v", answer.Discover)
	}
	livetest.Exec(t, h.path, `DELETE FROM metadata_provider_statuses`)
	livetest.Exec(t, h.path, `INSERT INTO settings (key, value, value_type) VALUES ('open_library_search_limit', '0', 'integer')`)
	if answer := answerOf(t, client.get(metadataSettingsPath), http.StatusOK); answer.Discover.Search != "available" || *answer.Discover.ResultLimit != 0 || answer.Discover.RetryAfter != nil {
		t.Fatalf("a zero limit never reaches Open Library %+v", answer.Discover)
	}
}

func TestSavingWritesOnlyTheChangedKeyInTheRailsFormAndDiscoverHonoursIt(t *testing.T) {
	h, fake := newDiscoverHarness(t, true)
	seedUnrelatedSettings(t, h)
	livetest.Exec(t, h.path, `INSERT INTO settings (key, value, value_type, category, description, created_at, updated_at) VALUES ('open_library_search_limit', '50', 'integer', 'open_library', 'Maximum number of search results to return', '2026-09-01 07:00:00.111111', '2026-09-02 07:00:00.222222')`)
	client := h.client()
	token := client.signIn("alice", alicePassword)
	unrelated := livetest.Query(t, h.path, unrelatedRows)
	limitRow := livetest.Query(t, h.path, `SELECT * FROM settings WHERE key = 'open_library_search_limit'`)
	read := answerOf(t, client.get(metadataSettingsPath), http.StatusOK)
	saved := answerOf(t, client.saveSettings(token, changeBody(read.Revision, `{"enabled":false}`)), http.StatusOK)
	if *saved.OpenLibrary.Enabled || *saved.OpenLibrary.SearchLimit != 50 || saved.Discover.Search != "provider_disabled" || saved.Revision == read.Revision {
		t.Fatalf("saved %+v", saved)
	}
	inserted := livetest.Query(t, h.path, `SELECT value, value_type, category, description, CAST(created_at AS TEXT), CAST(updated_at AS TEXT) FROM settings WHERE key = 'open_library_enabled'`)
	want := [][]any{{"false", "boolean", "open_library", "Enable Open Library as a metadata provider", "2026-11-15 12:00:00.123456", "2026-11-15 12:00:00.123456"}}
	if !reflect.DeepEqual(inserted, want) {
		t.Fatalf("inserted %v", inserted)
	}
	if after := livetest.Query(t, h.path, `SELECT * FROM settings WHERE key = 'open_library_search_limit'`); !reflect.DeepEqual(limitRow, after) {
		t.Fatalf("an unrelated save rewrote the larger limit: %v -> %v", limitRow, after)
	}
	if after := livetest.Query(t, h.path, unrelatedRows); !reflect.DeepEqual(unrelated, after) {
		t.Fatalf("other settings changed: %v -> %v", unrelated, after)
	}
	reloaded := answerOf(t, client.get(metadataSettingsPath), http.StatusOK)
	if reloaded.Revision != saved.Revision || !reflect.DeepEqual(reloaded.OpenLibrary, saved.OpenLibrary) {
		t.Fatalf("reload %+v saved %+v", reloaded, saved)
	}
	discover := discoverBody(t, client.discover("q=dune"))
	if discover["search"] != "provider_disabled" || len(discover["items"].([]any)) != 0 || fake.count() != 0 {
		t.Fatalf("discover after disabling %v, %d searches", discover, fake.count())
	}
	h.clock.Advance(time.Second)
	turnedOn := answerOf(t, client.saveSettings(token, changeBody(reloaded.Revision, `{"enabled":true,"search_limit":7}`)), http.StatusOK)
	if !*turnedOn.OpenLibrary.Enabled || *turnedOn.OpenLibrary.SearchLimit != 7 || turnedOn.Discover.Search != "available" || *turnedOn.Discover.ResultLimit != 7 {
		t.Fatalf("turned on %+v", turnedOn)
	}
	updated := livetest.Query(t, h.path, `SELECT key, value, value_type, CAST(created_at AS TEXT), CAST(updated_at AS TEXT) FROM settings WHERE key LIKE 'open_library_%' ORDER BY key`)
	if want := [][]any{{"open_library_enabled", "true", "boolean", "2026-11-15 12:00:00.123456", "2026-11-15 12:00:01.123456"}, {"open_library_search_limit", "7", "integer", "2026-09-01 07:00:00.111111", "2026-11-15 12:00:01.123456"}}; !reflect.DeepEqual(updated, want) {
		t.Fatalf("updated %v", updated)
	}
	discoverBody(t, client.discover("q=dune"))
	if fake.count() != 1 || !strings.Contains(fake.requests[0].URL.RawQuery, "limit=7") {
		t.Fatalf("discover searched %d times: %v", fake.count(), fake.requests)
	}
}

func TestAValueEqualToWhatIsSavedIsNotWrittenAndAnUnreadableValueCanBeReplaced(t *testing.T) {
	h, _ := newDiscoverHarness(t, true)
	livetest.Exec(t, h.path, `INSERT INTO settings (key, value, value_type, updated_at) VALUES ('open_library_enabled', '1', 'boolean', '2026-09-01 07:00:00'), ('open_library_search_limit', 'lots', 'string', '2026-09-01 07:00:00')`)
	client := h.client()
	token := client.signIn("alice", alicePassword)
	before := livetest.Query(t, h.path, settingsTable)
	read := answerOf(t, client.get(metadataSettingsPath), http.StatusOK)
	if read.OpenLibrary.SearchLimit != nil || read.Discover.Search != "settings_unreadable" {
		t.Fatalf("read %+v", read)
	}
	same := answerOf(t, client.saveSettings(token, changeBody(read.Revision, `{"enabled":true}`)), http.StatusOK)
	if same.Revision != read.Revision {
		t.Fatal("an unchanged value changed the revision")
	}
	if after := livetest.Query(t, h.path, settingsTable); !reflect.DeepEqual(before, after) {
		t.Fatalf("an unchanged value was written: %v -> %v", before, after)
	}
	repaired := answerOf(t, client.saveSettings(token, changeBody(read.Revision, `{"search_limit":20}`)), http.StatusOK)
	if *repaired.OpenLibrary.SearchLimit != 20 || repaired.Discover.Search != "available" {
		t.Fatalf("repaired %+v", repaired)
	}
	if row := livetest.Query(t, h.path, `SELECT value, value_type, category, description, CAST(created_at AS TEXT), CAST(updated_at AS TEXT) FROM settings WHERE key = 'open_library_search_limit'`); !reflect.DeepEqual(row, [][]any{{"20", "integer", "open_library", "Maximum number of search results to return", "2026-01-01 00:00:00", "2026-11-15 12:00:00.123456"}}) {
		t.Fatalf("repair wrote %v", row)
	}
	fresh, _ := newDiscoverHarness(t, true)
	other := fresh.client()
	otherToken := other.signIn("alice", alicePassword)
	untouched := livetest.Query(t, fresh.path, settingsTable)
	defaults := answerOf(t, other.get(metadataSettingsPath), http.StatusOK)
	answerOf(t, other.saveSettings(otherToken, changeBody(defaults.Revision, `{"enabled":true,"search_limit":20}`)), http.StatusOK)
	if after := livetest.Query(t, fresh.path, settingsTable); !reflect.DeepEqual(untouched, after) {
		t.Fatalf("saving the defaults wrote: %v -> %v", untouched, after)
	}
}

func TestAStaleRevisionIsAConflictThatShowsTheSavedValuesAndWritesNothing(t *testing.T) {
	h, _ := newDiscoverHarness(t, true)
	first, second := h.client(), h.client()
	firstToken := first.signIn("alice", alicePassword)
	secondToken := second.signIn("alice", alicePassword)
	stale := answerOf(t, second.get(metadataSettingsPath), http.StatusOK)
	answerOf(t, first.saveSettings(firstToken, changeBody(stale.Revision, `{"search_limit":5}`)), http.StatusOK)
	before := livetest.Query(t, h.path, settingsTable)
	conflict := answerOf(t, second.saveSettings(secondToken, changeBody(stale.Revision, `{"enabled":false}`)), http.StatusConflict)
	if conflict.Error != "settings_conflict" || *conflict.OpenLibrary.SearchLimit != 5 || !*conflict.OpenLibrary.Enabled || conflict.Revision == stale.Revision {
		t.Fatalf("conflict %+v", conflict)
	}
	if after := livetest.Query(t, h.path, settingsTable); !reflect.DeepEqual(before, after) {
		t.Fatalf("a stale save wrote: %v -> %v", before, after)
	}
	answerOf(t, second.saveSettings(secondToken, changeBody(conflict.Revision, `{"enabled":false}`)), http.StatusOK)
}

func TestARevisionReadBeforeAChangeAndItsUndoIsStillStale(t *testing.T) {
	for _, clock := range []struct {
		name   string
		undoAt time.Duration
	}{{"clock forward", 2 * time.Second}, {"clock stepped back to the original row's time", 0}} {
		t.Run(clock.name, func(t *testing.T) { changeAndUndo(t, clock.undoAt) })
	}
}

func changeAndUndo(t *testing.T, undoAt time.Duration) {
	h, _ := newDiscoverHarness(t, true)
	livetest.Exec(t, h.path, `INSERT INTO settings (key, value, value_type, updated_at) VALUES ('open_library_search_limit', '20', 'integer', '2026-11-15 12:00:00.123456')`)
	stale, other := h.client(), h.client()
	staleToken := stale.signIn("alice", alicePassword)
	otherToken := other.signIn("alice", alicePassword)
	read := answerOf(t, stale.get(metadataSettingsPath), http.StatusOK)
	h.clock.Advance(time.Second)
	eight := answerOf(t, other.saveSettings(otherToken, changeBody(read.Revision, `{"search_limit":8}`)), http.StatusOK)
	h.clock.Advance(undoAt - time.Second)
	undone := answerOf(t, other.saveSettings(otherToken, changeBody(eight.Revision, `{"search_limit":20}`)), http.StatusOK)
	if undone.Revision == read.Revision {
		t.Fatal("an undone change gave back the earlier revision")
	}
	before := livetest.Query(t, h.path, settingsTable)
	conflict := answerOf(t, stale.saveSettings(staleToken, changeBody(read.Revision, `{"search_limit":7}`)), http.StatusConflict)
	if *conflict.OpenLibrary.SearchLimit != 20 {
		t.Fatalf("conflict %+v", conflict)
	}
	if after := livetest.Query(t, h.path, settingsTable); !reflect.DeepEqual(before, after) {
		t.Fatalf("a stale save wrote: %v -> %v", before, after)
	}
}

func TestConcurrentSavesFromOneRevisionLetExactlyOneWrite(t *testing.T) {
	h, _ := newDiscoverHarness(t, true)
	client := h.client()
	token := client.signIn("alice", alicePassword)
	read := answerOf(t, client.get(metadataSettingsPath), http.StatusOK)
	var group sync.WaitGroup
	codes := make([]int, 6)
	for index := range codes {
		group.Add(1)
		go func(index int) {
			defer group.Done()
			request := httptest.NewRequest(http.MethodPut, metadataSettingsPath, strings.NewReader(changeBody(read.Revision, `{"search_limit":`+string(rune('1'+index))+`}`)))
			request.RemoteAddr = "127.0.0.1:50000"
			for name, value := range map[string]string{"Content-Type": "application/json", "Cookie": sessionCookieName + "=" + client.cookies[sessionCookieName], "X-Shelfarr-Account": "1", "Origin": browserOrigin, "X-CSRF-Token": token} {
				request.Header.Set(name, value)
			}
			recorder := httptest.NewRecorder()
			h.app.ServeHTTP(recorder, request)
			codes[index] = recorder.Code
		}(index)
	}
	group.Wait()
	saved := 0
	for _, code := range codes {
		switch code {
		case http.StatusOK:
			saved++
		case http.StatusConflict:
		default:
			t.Fatalf("codes %v", codes)
		}
	}
	if saved != 1 {
		t.Fatalf("codes %v", codes)
	}
	if rows := livetest.Query(t, h.path, `SELECT COUNT(*) FROM settings WHERE key = 'open_library_search_limit'`); rows[0][0] != int64(1) {
		t.Fatalf("rows %v", rows)
	}
}

func TestInvalidChangesAreRefusedFieldByFieldAndMalformedBodiesWriteNothing(t *testing.T) {
	h, _ := newDiscoverHarness(t, true)
	client := h.client()
	token := client.signIn("alice", alicePassword)
	read := answerOf(t, client.get(metadataSettingsPath), http.StatusOK)
	before := livetest.Query(t, h.path, settingsTable)
	for _, values := range []struct{ body, errors string }{
		{`{"search_limit":0}`, `{"search_limit":["must be a whole number from 1 to 1000"]}`},
		{`{"search_limit":1001}`, `{"search_limit":["must be a whole number from 1 to 1000"]}`},
		{`{"search_limit":-1}`, `{"search_limit":["must be a whole number from 1 to 1000"]}`},
		{`{"search_limit":1.5}`, `{"search_limit":["must be a whole number from 1 to 1000"]}`},
		{`{"search_limit":1e1}`, `{"search_limit":["must be a whole number from 1 to 1000"]}`},
		{`{"search_limit":"15"}`, `{"search_limit":["must be a whole number from 1 to 1000"]}`},
		{`{"search_limit":99999999999999999999}`, `{"search_limit":["must be a whole number from 1 to 1000"]}`},
		{`{"enabled":"false","search_limit":null}`, `{"enabled":["must be true or false"],"search_limit":["must be a whole number from 1 to 1000"]}`},
		{`{"enabled":0,"search_limit":10}`, `{"enabled":["must be true or false"]}`},
	} {
		recorder := client.saveSettings(token, changeBody(read.Revision, values.body))
		want := `{"account":"1","error":"invalid_settings","errors":` + values.errors + `}`
		if recorder.Code != http.StatusUnprocessableEntity || recorder.Body.String() != want {
			t.Errorf("%s: %d %s", values.body, recorder.Code, recorder.Body.String())
		}
	}
	for _, body := range []string{
		``, `[]`, `{}`, changeBody(read.Revision, `{}`), changeBody(read.Revision, `[]`), changeBody(read.Revision, `{"enabled":true,"url":"https://example.com"}`),
		`{"open_library":{"enabled":false}}`, changeBody("abc", `{"enabled":false}`), changeBody(strings.ToUpper(read.Revision), `{"enabled":false}`),
		`{"revision":"` + read.Revision + `","open_library":{"enabled":false},"metadata_source":"hardcover"}`, `{"revision":1,"open_library":{"enabled":false}}`,
	} {
		recorder := client.saveSettings(token, body)
		if recorder.Code != http.StatusBadRequest || recorder.Body.String() != `{"error":"invalid_request"}` {
			t.Errorf("%q: %d %s", body, recorder.Code, recorder.Body.String())
		}
	}
	oversized := client.saveSettings(token, changeBody(read.Revision, `{"enabled":false}`+strings.Repeat(" ", 1100)))
	if oversized.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("oversized %d %s", oversized.Code, oversized.Body.String())
	}
	if after := livetest.Query(t, h.path, settingsTable); !reflect.DeepEqual(before, after) {
		t.Fatalf("a refused change wrote: %v -> %v", before, after)
	}
}

func TestOnlyACurrentAdminOfTheBoundAccountWithOriginAndTokenCanSave(t *testing.T) {
	h, _ := newDiscoverHarness(t, true)
	admin := h.client()
	token := admin.signIn("alice", alicePassword)
	revision := answerOf(t, admin.get(metadataSettingsPath), http.StatusOK).Revision
	body := changeBody(revision, `{"enabled":false}`)
	before := livetest.Query(t, h.path, settingsTable)
	anonymous := h.client().send(http.MethodGet, metadataSettingsPath, "", map[string]string{"X-Shelfarr-Account": "1"})
	if anonymous.Code != http.StatusUnauthorized || anonymous.Body.String() != `{"error":"signed_out"}` {
		t.Fatalf("anonymous %d %s", anonymous.Code, anonymous.Body.String())
	}
	member := h.client()
	memberToken := member.signIn("bob", bobPassword)
	for _, recorder := range []*httptest.ResponseRecorder{member.get(metadataSettingsPath), member.saveSettings(memberToken, body)} {
		if recorder.Code != http.StatusNotFound || recorder.Body.String() != `{"error":"not_found"}` || recorder.Header().Get("Cache-Control") != "private, no-store" {
			t.Fatalf("member %d %s", recorder.Code, recorder.Body.String())
		}
	}
	for _, headers := range []map[string]string{
		{"X-Shelfarr-Account": "2", "Origin": browserOrigin, "X-CSRF-Token": token},
		{"Origin": browserOrigin, "X-CSRF-Token": token},
	} {
		if recorder := admin.send(http.MethodPut, metadataSettingsPath, body, headers); recorder.Code != http.StatusUnauthorized || recorder.Body.String() != `{"error":"account_changed"}` {
			t.Fatalf("%v: %d %s", headers, recorder.Code, recorder.Body.String())
		}
	}
	for _, headers := range []map[string]string{
		{"X-Shelfarr-Account": "1", "X-CSRF-Token": token},
		{"X-Shelfarr-Account": "1", "Origin": "http://evil.test", "X-CSRF-Token": token},
		{"X-Shelfarr-Account": "1", "Origin": browserOrigin, "X-CSRF-Token": token, "Sec-Fetch-Site": "cross-site"},
		{"X-Shelfarr-Account": "1", "Origin": browserOrigin},
		{"X-Shelfarr-Account": "1", "Origin": browserOrigin, "X-CSRF-Token": memberToken},
	} {
		if recorder := admin.send(http.MethodPut, metadataSettingsPath, body, headers); recorder.Code != http.StatusUnprocessableEntity || recorder.Body.String() != `{"error":"invalid_csrf"}` {
			t.Fatalf("%v: %d %s", headers, recorder.Code, recorder.Body.String())
		}
	}
	for _, method := range []string{http.MethodHead, http.MethodPost, http.MethodDelete, http.MethodPatch} {
		recorder := admin.send(method, metadataSettingsPath, "", map[string]string{"X-Shelfarr-Account": "1", "Origin": browserOrigin, "X-CSRF-Token": token})
		if recorder.Code != http.StatusMethodNotAllowed || recorder.Header().Get("Allow") != "GET, PUT" || recorder.Header().Get("Cache-Control") != "private, no-store" {
			t.Fatalf("%s: %d %v", method, recorder.Code, recorder.Header())
		}
	}
	delete(h.app.previewIDs, "1")
	if recorder := admin.saveSettings(token, body); recorder.Code != http.StatusNotFound {
		t.Fatalf("unlisted admin %d %s", recorder.Code, recorder.Body.String())
	}
	if after := livetest.Query(t, h.path, settingsTable); !reflect.DeepEqual(before, after) {
		t.Fatalf("a refused save wrote: %v -> %v", before, after)
	}
	off := newBrowserHarness(t, func(config *Config) { config.PreviewUserIDs = nil })
	if recorder := off.client().send(http.MethodGet, metadataSettingsPath, "", map[string]string{"X-Shelfarr-Account": "1"}); recorder.Code != http.StatusNotFound {
		t.Fatalf("preview off %d %s", recorder.Code, recorder.Body.String())
	}
}

func TestASaveRechecksTheRoleAndSessionInsideTheWriteTransaction(t *testing.T) {
	for _, change := range []struct {
		name, statement, status, body string
	}{
		{"demoted", `UPDATE users SET role = 0 WHERE id = 1`, "404", `{"error":"not_found"}`},
		{"deleted", `UPDATE users SET deleted_at = '2026-11-15 11:00:00' WHERE id = 1`, "401", `{"error":"signed_out"}`},
		{"signed out elsewhere", `DELETE FROM sessions WHERE user_id = 1`, "401", `{"error":"signed_out"}`},
	} {
		for _, method := range []string{http.MethodGet, http.MethodPut} {
			t.Run(change.name+" "+method, func(t *testing.T) {
				h, _ := newDiscoverHarness(t, true)
				client := h.client()
				client.signIn("alice", alicePassword)
				revision := answerOf(t, client.get(metadataSettingsPath), http.StatusOK).Revision
				before := livetest.Query(t, h.path, settingsTable)
				request := httptest.NewRequest(method, metadataSettingsPath, strings.NewReader(changeBody(revision, `{"enabled":false}`)))
				request.Header.Set("Content-Type", "application/json")
				request.Header.Set("Cookie", sessionCookieName+"="+client.cookies[sessionCookieName])
				session, err := h.app.resume(request.Context(), httptest.NewRecorder(), request)
				if err != nil || session == nil || !session.user.Admin {
					t.Fatalf("resume %v %v", session, err)
				}
				livetest.Exec(t, h.path, change.statement)
				recorder := httptest.NewRecorder()
				h.app.webMetadataSettings(recorder, request, *session, &outcome{})
				if got := recorder.Result().Status[:3]; got != change.status || recorder.Body.String() != change.body {
					t.Fatalf("%s %s", got, recorder.Body.String())
				}
				if after := livetest.Query(t, h.path, settingsTable); !reflect.DeepEqual(before, after) {
					t.Fatalf("wrote: %v -> %v", before, after)
				}
			})
		}
	}
}

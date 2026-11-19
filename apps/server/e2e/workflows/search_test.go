//go:build e2e

package workflows

import (
	"database/sql"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"
)

const (
	searchEvidenceEnvironment = "SHELFARR_SEARCH_EVIDENCE"
	searchPath                = "/ebooks/search.opds/"
	prideQuery                = "Pride and Prejudice Jane Austen"
	selectionMessage          = "Search results found. Please review and select a result to download."
	failureMessage            = "Search failed before any source returned results."
)

var searchTables = []string{"requests", "search_results", "downloads", "store_offers", "request_events", "notifications"}

type reply struct {
	Path   string `json:"path"`
	Query  string `json:"query,omitempty"`
	Status int    `json:"status"`
	Body   string `json:"body"`
	delay  time.Duration
	before func()
}

type catalogue struct {
	t      *testing.T
	server *httptest.Server
	mutex  sync.Mutex
	routes map[string]reply
	seen   []string
	served []reply
}

func newCatalogue(t *testing.T) *catalogue {
	t.Helper()
	fake := &catalogue{t: t, routes: map[string]reply{}}
	fake.server = httptest.NewServer(fake)
	t.Cleanup(fake.server.Close)
	fake.defaults()
	return fake
}

func (c *catalogue) defaults() {
	c.answer(searchPath, prideQuery, 200, opds(c.t, "search-pride.xml"))
	for _, id := range []string{"1342", "42671", "37431"} {
		c.answer("/ebooks/"+id+".opds", "", 200, opds(c.t, "detail-"+id+".xml"))
	}
	c.answer("/ebooks/90001.opds", "", 404, "Not Found")
}

func opds(t *testing.T, name string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata", "gutenberg", name))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func routeKey(path, query string) string { return path + "\x00" + query }

func (c *catalogue) answer(path, query string, status int, body string) {
	c.set(reply{Path: path, Query: query, Status: status, Body: body})
}

func (c *catalogue) set(answer reply) {
	c.mutex.Lock()
	defer c.mutex.Unlock()
	c.routes[routeKey(answer.Path, answer.Query)] = answer
}

func (c *catalogue) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	query := ""
	if request.URL.Path == searchPath {
		query = request.URL.Query().Get("query")
	}
	c.mutex.Lock()
	c.seen = append(c.seen, request.URL.Path+"?"+query)
	answer, known := c.routes[routeKey(request.URL.Path, query)]
	if known {
		c.served = append(c.served, answer)
	}
	c.mutex.Unlock()
	if !known || request.Header.Get("User-Agent") != "Shelfarr/1.0 (+https://github.com/Pedro-Revez-Silva/shelfarr)" {
		http.Error(writer, "unexpected", http.StatusTeapot)
		return
	}
	if answer.before != nil {
		answer.before()
	}
	if answer.delay > 0 {
		select {
		case <-request.Context().Done():
			return
		case <-time.After(answer.delay):
		}
	}
	if answer.Status >= 300 && answer.Status < 400 {
		writer.Header().Set("Location", answer.Body)
	}
	writer.WriteHeader(answer.Status)
	writer.Write([]byte(answer.Body))
}

func (c *catalogue) requests() []string {
	c.mutex.Lock()
	defer c.mutex.Unlock()
	return append([]string(nil), c.seen...)
}

func (c *catalogue) replies() []reply {
	c.mutex.Lock()
	defer c.mutex.Unlock()
	return append([]reply(nil), c.served...)
}

func (c *catalogue) table() []reply {
	c.mutex.Lock()
	defer c.mutex.Unlock()
	var all []reply
	for _, answer := range c.routes {
		all = append(all, answer)
	}
	sort.Slice(all, func(i, j int) bool { return routeKey(all[i].Path, all[i].Query) < routeKey(all[j].Path, all[j].Query) })
	return all
}

func (c *catalogue) reset() {
	c.mutex.Lock()
	defer c.mutex.Unlock()
	c.seen, c.served = nil, nil
}

func putSetting(t *testing.T, db *sql.DB, key, valueType, value string) {
	t.Helper()
	exec1(t, db, `INSERT INTO settings (key, value, value_type, category, created_at, updated_at) VALUES (?, ?, ?, 'general', ?, ?)
		ON CONFLICT (key) DO UPDATE SET value = excluded.value, value_type = excluded.value_type`, key, value, valueType, seededStamp, seededStamp)
}

type searchSetup struct {
	w        *workdir
	db       *sql.DB
	fake     *catalogue
	users    map[string]int64
	nextWork int
}

func newSearchSetup(t *testing.T, bundle string) *searchSetup {
	t.Helper()
	setup := &searchSetup{w: prepare(t, bundle), fake: newCatalogue(t), users: map[string]int64{}, nextWork: 7001}
	setup.db = setup.w.open()
	for _, username := range []string{"alice", "bob", "carol"} {
		setup.users[username] = scalar[int64](t, setup.db, `SELECT id FROM users WHERE username = ?`, username)
	}
	putSetting(t, setup.db, "gutenberg_enabled", "boolean", "true")
	putSetting(t, setup.db, "gutenberg_url", "string", setup.fake.server.URL)
	return setup
}

func (s *searchSetup) disableCustomProviders(t *testing.T) {
	t.Helper()
	exec1(t, s.db, `UPDATE acquisition_providers SET enabled = 0`)
}

func (s *searchSetup) admit(t *testing.T, title, author string) int64 {
	t.Helper()
	work := "OL" + itoa(int64(s.nextWork)) + "W"
	s.nextWork++
	body := `{"work_id":"openlibrary:` + work + `","book_type":"ebook","title":` + quote(title) + `,"language":"en"`
	if author != "" {
		body += `,"author":` + quote(author)
	}
	answer := s.w.admit(plainBinary, faults{}, itoa(s.users["alice"]), body+"}")
	if answer.outcome != "created" {
		t.Fatalf("admission answered %v exit %d", answer.fields, answer.code)
	}
	return scalar[int64](t, s.db, `SELECT id FROM requests WHERE id = ?`, answer.fields.text("request_id"))
}

func quote(text string) string {
	return `"` + strings.ReplaceAll(strings.ReplaceAll(text, `\`, `\\`), `"`, `\"`) + `"`
}

func (s *searchSetup) search(t *testing.T, binary string, injected faults, request int64, options ...string) result {
	t.Helper()
	run := s.w.binary(binary, injected, append([]string{"search", "--workdir", s.w.dir, "--request", itoa(request), "--request-timeout", "2s"}, options...)...)
	code := run.wait()
	return result{code: code, events: run.snapshot(), output: run.output()}
}

func (s *searchSetup) start(t *testing.T, binary string, injected faults, request int64, options ...string) *process {
	t.Helper()
	return s.w.binary(binary, injected, append([]string{"search", "--workdir", s.w.dir, "--request", itoa(request), "--request-timeout", "2s"}, options...)...)
}

func last(t *testing.T, outcome result, name string) event {
	t.Helper()
	for index := len(outcome.events) - 1; index >= 0; index-- {
		if outcome.events[index].name() == name {
			return outcome.events[index]
		}
	}
	t.Fatalf("no %s event: %s", name, outcome.output)
	return nil
}

type requestState struct {
	Status     int64
	Generation int64
	Claimed    bool
	Attention  int64
	Issue      string
	Retries    int64
	NextRetry  string
	UpdatedAt  string
}

func stateOf(t *testing.T, db *sql.DB, request int64) requestState {
	t.Helper()
	var state requestState
	var claimed, issue, next sql.NullString
	err := db.QueryRow(`SELECT status, search_generation, search_claimed_at, attention_needed, issue_description, retry_count, next_retry_at, updated_at FROM requests WHERE id = ?`, request).
		Scan(&state.Status, &state.Generation, &claimed, &state.Attention, &issue, &state.Retries, &next, &state.UpdatedAt)
	if err != nil {
		t.Fatal(err)
	}
	state.Claimed, state.Issue, state.NextRetry = claimed.Valid, issue.String, next.String
	return state
}

func requestRows(t *testing.T, db *sql.DB, request int64) map[string][][]string {
	t.Helper()
	return map[string][][]string{
		"search_results": rows(t, db, `SELECT * FROM search_results WHERE request_id = ? ORDER BY id`, request),
		"downloads":      rows(t, db, `SELECT * FROM downloads WHERE request_id = ? ORDER BY id`, request),
		"store_offers":   rows(t, db, `SELECT * FROM store_offers WHERE request_id = ? ORDER BY id`, request),
		"request_events": rows(t, db, `SELECT * FROM request_events WHERE request_id = ? ORDER BY id`, request),
		"notifications":  rows(t, db, `SELECT * FROM notifications WHERE notifiable_type = 'Request' AND notifiable_id = ? ORDER BY id`, request),
	}
}

func otherRows(t *testing.T, db *sql.DB, request int64) map[string][][]string {
	t.Helper()
	return map[string][][]string{
		"requests":       rows(t, db, `SELECT * FROM requests WHERE id <> ? ORDER BY id`, request),
		"search_results": rows(t, db, `SELECT * FROM search_results WHERE request_id <> ? ORDER BY id`, request),
		"downloads":      rows(t, db, `SELECT * FROM downloads WHERE request_id <> ? AND (search_result_id IS NULL OR search_result_id NOT IN (SELECT id FROM search_results WHERE request_id = ?)) ORDER BY id`, request, request),
		"store_offers":   rows(t, db, `SELECT * FROM store_offers WHERE request_id <> ? ORDER BY id`, request),
		"request_events": rows(t, db, `SELECT * FROM request_events WHERE request_id <> ? ORDER BY id`, request),
		"notifications":  rows(t, db, `SELECT * FROM notifications WHERE NOT (notifiable_type = 'Request' AND notifiable_id = ?) ORDER BY id`, request),
	}
}

type untouched struct {
	tables map[string]string
	others map[string][][]string
	own    map[string][][]string
	state  requestState
}

func observe(t *testing.T, db *sql.DB, request int64) untouched {
	t.Helper()
	return untouched{tables: digests(t, db, searchTables...), others: otherRows(t, db, request), own: requestRows(t, db, request), state: stateOf(t, db, request)}
}

func (u untouched) requireOthers(t *testing.T, db *sql.DB, request int64) {
	t.Helper()
	requireSame(t, u.tables, digests(t, db, searchTables...))
	if after := otherRows(t, db, request); !reflect.DeepEqual(u.others, after) {
		for table := range after {
			if !reflect.DeepEqual(u.others[table], after[table]) {
				t.Errorf("rows of other requests in %s changed", table)
			}
		}
	}
}

func (u untouched) requireAll(t *testing.T, db *sql.DB, request int64) {
	t.Helper()
	u.requireOthers(t, db, request)
	if after := requestRows(t, db, request); !reflect.DeepEqual(u.own, after) {
		t.Errorf("the request's rows changed: %v", after)
	}
	if state := stateOf(t, db, request); state != u.state {
		t.Errorf("request changed from %+v to %+v", u.state, state)
	}
}

type searchCase struct {
	Name       string   `json:"name"`
	Bundle     string   `json:"bundle"`
	RequestID  int64    `json:"request_id"`
	Origin     string   `json:"origin"`
	Outcome    string   `json:"outcome"`
	Code       string   `json:"code,omitempty"`
	Replies    []reply  `json:"replies"`
	Routes     []reply  `json:"routes"`
	Requests   []string `json:"requests"`
	Candidates []string `json:"candidates,omitempty"`
}

func searchEvidence(t *testing.T, name string) string {
	t.Helper()
	root := os.Getenv(searchEvidenceEnvironment)
	if root == "" {
		root = t.TempDir()
	}
	dir := filepath.Join(root, name)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	return dir
}

func (s *searchSetup) record(t *testing.T, dir string, entry searchCase) {
	t.Helper()
	entry.Origin = s.fake.server.URL
	entry.Replies = s.fake.replies()
	entry.Routes = s.fake.table()
	entry.Requests = s.fake.requests()
	writeJSON(t, filepath.Join(dir, "case.json"), entry)
}

func seedSearchHistory(t *testing.T, db *sql.DB, request int64, other int64) map[string]int64 {
	t.Helper()
	insert := func(requestID int64, guid, source, title string, status int, blocklisted bool) int64 {
		var blocked any
		if blocklisted {
			blocked = seededStamp
		}
		return exec1(t, db, `INSERT INTO search_results (request_id, guid, title, source, status, blocklisted_at, blocklist_reason, provider_payload, created_at, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, '{}', ?, ?)`, requestID, guid, title, source, status, blocked, map[bool]any{true: "seeded failure", false: nil}[blocklisted], seededStamp, seededStamp)
	}
	download := func(requestID, result int64, status int) int64 {
		return exec1(t, db, `INSERT INTO downloads (request_id, search_result_id, status, external_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)`, requestID, result, status, "seeded-client-"+itoa(result), seededStamp, seededStamp)
	}
	ids := map[string]int64{
		"manual":      insert(request, "manual_magnet:seeded", "manual_magnet", "Manual magnet for Pride and Prejudice", 0, false),
		"stale":       insert(request, "seeded-stale-indexer-guid", "prowlarr", "Pride and Prejudice 1813 EPUB", 0, false),
		"blocklisted": insert(request, "gutenberg:1342", "gutenberg", "Pride and Prejudice - Austen, Jane [EPUB] [English]", 0, true),
		"active":      insert(request, "seeded-active-indexer-guid", "prowlarr", "Pride and Prejudice Annotated", 1, false),
		"unrelated":   insert(other, "gutenberg:84", "gutenberg", "Frankenstein [EPUB]", 0, false),
	}
	ids["failed-download"] = download(request, ids["stale"], 4)
	ids["active-download"] = download(request, ids["active"], 1)
	ids["unrelated-download"] = download(other, ids["unrelated"], 0)
	exec1(t, db, `INSERT INTO store_offers (request_id, provider, external_id, title, market, storefront_url, drm_free, quoted_at, created_at, updated_at) VALUES (?, 'ebooks_com', 'seeded-offer', 'Pride and Prejudice', 'GB', 'https://www.ebooks.com/en-gb/book/1/', 1, ?, ?, ?)`, request, seededStamp, seededStamp, seededStamp)
	exec1(t, db, `INSERT INTO request_events (request_id, event_type, source, message, level, details, user_visible, created_at, updated_at) VALUES (?, 'store_offers_found', 'store_provider', '1 DRM-free store offer found', 0, '{"offer_count":1}', 0, ?, ?)`, request, seededStamp, seededStamp)
	exec1(t, db, `INSERT INTO request_events (request_id, event_type, source, message, level, details, user_visible, created_at, updated_at) VALUES (?, 'search_started', 'request', 'kept', 0, '{}', 0, ?, ?)`, request, seededStamp, seededStamp)
	return ids
}

func TestGutenbergSearchPublishesCandidatesForManualSelection(t *testing.T) {
	for _, bundle := range []struct{ name, path string }{{"current", currentBundle}, {"upgrade", upgradeBundle}} {
		t.Run(bundle.name, func(t *testing.T) {
			setup := newSearchSetup(t, bundle.path)
			db := setup.db
			setup.disableCustomProviders(t)
			other := setup.admit(t, "Frankenstein", "Mary Shelley")
			request := setup.admit(t, "Pride and Prejudice", "Jane Austen")
			seeded := seedSearchHistory(t, db, request, other)
			before := observe(t, db, request)
			evidence := searchEvidence(t, "candidates-"+bundle.name)
			snapshot(t, db, filepath.Join(evidence, "before.sqlite3"))

			outcome := setup.search(t, plainBinary, faults{}, request)
			answer := last(t, outcome, "search")
			if outcome.code != 0 || answer.text("outcome") != "candidates" || answer.number("written") != 1 || answer.number("preserved") != 1 || answer.number("removed") != 1 || answer.number("candidates") != 2 || answer.number("withheld") != 0 || answer.number("requests") != 5 {
				t.Fatalf("exit %d: %s", outcome.code, outcome.output)
			}
			wantRequests := []string{searchPath + "?" + prideQuery, "/ebooks/1342.opds?", "/ebooks/42671.opds?", "/ebooks/37431.opds?", "/ebooks/90001.opds?"}
			if got := setup.fake.requests(); !reflect.DeepEqual(got, wantRequests) {
				t.Errorf("catalogue requests %q", got)
			}
			if strings.Contains(outcome.output, "Pride") || strings.Contains(outcome.output, "127.0.0.1") || strings.Contains(outcome.output, "Austen") {
				t.Errorf("the decision log carries provider data: %s", outcome.output)
			}

			state := stateOf(t, db, request)
			if state.Status != 1 || state.Generation != 1 || state.Claimed || state.Attention != 1 || state.Issue != selectionMessage || state.Retries != 0 || state.NextRetry != "" || state.UpdatedAt == before.state.UpdatedAt {
				t.Errorf("request state %+v", state)
			}
			origin := setup.fake.server.URL
			written := rows(t, db, `SELECT guid, title, indexer, size_bytes, seeders, leechers, download_url, magnet_url, info_url, published_at, source, detected_language, status,
				provider_payload, confidence_score, score_breakdown, blocklisted_at, acquisition_provider_id, provider_result_id, created_at = updated_at
				FROM search_results WHERE request_id = ? AND id > ?`, request, seeded["unrelated"])
			want := [][]string{{"string:gutenberg:37431", "string:Pride and Prejudice, a play founded on Jane Austen's novel - Mackaye, Mary Keith Medbery [EPUB] [English]",
				"string:Project Gutenberg", "NULL", "NULL", "NULL", "string:" + origin + "/ebooks/37431.epub.noimages", "NULL", "string:" + origin + "/ebooks/37431",
				"NULL", "string:gutenberg", "string:en", "int64:0", "string:{}", "NULL", "NULL", "NULL", "NULL", "NULL", "int64:1"}}
			if !reflect.DeepEqual(written, want) {
				t.Errorf("written candidate\n%v\nwant\n%v", written, want)
			}
			kept := func(key string) []string {
				found := rows(t, db, `SELECT guid, status, blocklisted_at IS NOT NULL, updated_at <> ? FROM search_results WHERE id = ?`, seededStamp, seeded[key])
				if len(found) == 0 {
					return nil
				}
				return found[0]
			}
			if got := kept("manual"); !reflect.DeepEqual(got, []string{"string:manual_magnet:seeded", "int64:0", "int64:0", "int64:0"}) {
				t.Errorf("manual result %v", got)
			}
			if got := kept("blocklisted"); !reflect.DeepEqual(got, []string{"string:gutenberg:1342", "int64:2", "int64:1", "int64:1"}) {
				t.Errorf("blocklisted result %v", got)
			}
			if got := kept("active"); !reflect.DeepEqual(got, []string{"string:seeded-active-indexer-guid", "int64:1", "int64:0", "int64:0"}) {
				t.Errorf("result of the active download %v", got)
			}
			if got := kept("stale"); got != nil {
				t.Errorf("the previous provider result survived: %v", got)
			}
			if got := rows(t, db, `SELECT search_result_id, updated_at FROM downloads WHERE id = ?`, seeded["failed-download"]); !reflect.DeepEqual(got, [][]string{{"NULL", "string:" + seededStamp}}) {
				t.Errorf("the failed download keeps %v", got)
			}
			if got := scalar[int64](t, db, `SELECT COUNT(*) FROM store_offers WHERE request_id = ?`, request); got != 0 {
				t.Errorf("%d store offers left", got)
			}
			events := rows(t, db, `SELECT event_type, source, message, level, details, user_visible, download_id, created_at = updated_at FROM request_events WHERE request_id = ? ORDER BY id`, request)
			wantEvents := [][]string{{"string:search_started", "string:request", "string:kept", "int64:0", "string:{}", "int64:0", "NULL", "int64:1"},
				{"string:attention_flagged", "string:request", "string:" + selectionMessage, "int64:1", "string:{}", "int64:0", "NULL", "int64:1"}}
			if !reflect.DeepEqual(events, wantEvents) {
				t.Errorf("events %v", events)
			}
			notifications := rows(t, db, `SELECT user_id, notification_type, title, message, read_at FROM notifications WHERE notifiable_type = 'Request' AND notifiable_id = ?`, request)
			if want := [][]string{{"int64:" + itoa(setup.users["alice"]), "string:request_attention", "string:Attention Needed", `string:"Pride and Prejudice" needs your attention.`, "NULL"}}; !reflect.DeepEqual(notifications, want) {
				t.Errorf("notifications %v", notifications)
			}
			before.requireOthers(t, db, request)
			if verdict := scalar[string](t, db, `PRAGMA integrity_check`); verdict != "ok" {
				t.Errorf("integrity_check: %s", verdict)
			}
			snapshot(t, db, filepath.Join(evidence, "after.sqlite3"))
			setup.record(t, evidence, searchCase{Name: "candidates", Bundle: bundle.name, RequestID: request, Outcome: "candidates", Candidates: []string{"gutenberg:1342", "gutenberg:37431"}})

			again := observe(t, db, request)
			setup.fake.reset()
			repeat := setup.search(t, plainBinary, faults{}, request)
			if repeat.code != 7 || last(t, repeat, "rejected").text("code") != "request_not_pending" || len(setup.fake.requests()) != 0 {
				t.Errorf("a repeated search of a published request: exit %d %s", repeat.code, repeat.output)
			}
			again.requireAll(t, db, request)
		})
	}
}

func TestGutenbergSearchWithoutResultsSchedulesARetry(t *testing.T) {
	setup := newSearchSetup(t, currentBundle)
	db := setup.db
	empty := opds(t, "search-empty.xml")

	t.Run("no results", func(t *testing.T) {
		request := setup.admit(t, "An Unwritten Book", "Nobody")
		setup.fake.answer(searchPath, "An Unwritten Book Nobody", 200, empty)
		exec1(t, db, `INSERT INTO store_offers (request_id, provider, external_id, title, market, storefront_url, drm_free, quoted_at, created_at, updated_at) VALUES (?, 'ebooks_com', 'stale-offer', 'Stale', 'GB', 'https://www.ebooks.com/en-gb/book/2/', 1, ?, ?, ?)`, request, seededStamp, seededStamp, seededStamp)
		before := observe(t, db, request)
		evidence := searchEvidence(t, "no-results")
		snapshot(t, db, filepath.Join(evidence, "before.sqlite3"))
		setup.fake.reset()
		started := time.Now().UTC()
		outcome := setup.search(t, plainBinary, faults{}, request)
		if outcome.code != 0 || last(t, outcome, "search").text("outcome") != "no_results" {
			t.Fatalf("exit %d: %s", outcome.code, outcome.output)
		}
		state := stateOf(t, db, request)
		next, err := time.Parse("2006-01-02 15:04:05.000000", state.NextRetry)
		if err != nil || next.Before(started.Add(24*time.Hour-time.Second)) || next.After(time.Now().UTC().Add(24*time.Hour+time.Second)) {
			t.Errorf("next retry %q", state.NextRetry)
		}
		if state.Status != 2 || state.Generation != 1 || state.Claimed || state.Attention != 0 || state.Issue != "" || state.Retries != 1 {
			t.Errorf("request state %+v", state)
		}
		if got := scalar[int64](t, db, `SELECT COUNT(*) FROM search_results WHERE request_id = ?`, request) + scalar[int64](t, db, `SELECT COUNT(*) FROM store_offers WHERE request_id = ?`, request) + scalar[int64](t, db, `SELECT COUNT(*) FROM request_events WHERE request_id = ?`, request); got != 0 {
			t.Errorf("%d rows left or written", got)
		}
		before.requireOthers(t, db, request)
		snapshot(t, db, filepath.Join(evidence, "after.sqlite3"))
		setup.record(t, evidence, searchCase{Name: "no_results", Bundle: "current", RequestID: request, Outcome: "no_results"})
	})

	t.Run("retries exhausted", func(t *testing.T) {
		putSetting(t, db, "max_retries", "integer", "2")
		defer exec1(t, db, `DELETE FROM settings WHERE key = 'max_retries'`)
		request := setup.admit(t, "Another Unwritten Book", "")
		setup.fake.answer(searchPath, "Another Unwritten Book", 200, empty)
		exec1(t, db, `UPDATE requests SET retry_count = 2 WHERE id = ?`, request)
		before := observe(t, db, request)
		evidence := searchEvidence(t, "retries-exhausted")
		snapshot(t, db, filepath.Join(evidence, "before.sqlite3"))
		setup.fake.reset()
		outcome := setup.search(t, plainBinary, faults{}, request)
		if outcome.code != 0 || last(t, outcome, "search").text("outcome") != "retries_exhausted" {
			t.Fatalf("exit %d: %s", outcome.code, outcome.output)
		}
		state := stateOf(t, db, request)
		if state.Status != 2 || state.Claimed || state.Attention != 1 || state.Issue != "Maximum retry attempts (2) exceeded. Manual intervention required." || state.Retries != 3 || state.NextRetry != "" {
			t.Errorf("request state %+v", state)
		}
		if got := scalar[int64](t, db, `SELECT COUNT(*) FROM request_events WHERE request_id = ? AND event_type = 'attention_flagged'`, request); got != 1 {
			t.Errorf("%d attention events", got)
		}
		before.requireOthers(t, db, request)
		snapshot(t, db, filepath.Join(evidence, "after.sqlite3"))
		setup.record(t, evidence, searchCase{Name: "retries_exhausted", Bundle: "current", RequestID: request, Outcome: "retries_exhausted"})
	})
}

func TestGutenbergSearchReadsAFeedWithAByteOrderMark(t *testing.T) {
	setup := newSearchSetup(t, currentBundle)
	request := setup.admit(t, "Pride and Prejudice", "Jane Austen")
	setup.fake.answer(searchPath, prideQuery, 200, "\ufeff"+opds(t, "search-pride.xml"))
	outcome := setup.search(t, plainBinary, faults{}, request)
	if answer := last(t, outcome, "search"); outcome.code != 0 || answer.text("outcome") != "candidates" || answer.number("written") != 2 {
		t.Fatalf("exit %d: %s", outcome.code, outcome.output)
	}
}

func TestGutenbergSearchTriesEachTitleVariant(t *testing.T) {
	setup := newSearchSetup(t, upgradeBundle)
	setup.disableCustomProviders(t)
	db := setup.db
	request := setup.admit(t, "Le Petit Prince / The Little Prince", "Antoine de Saint-Exupéry")
	setup.fake.answer(searchPath, "Le Petit Prince Antoine de Saint-Exupéry", 200, opds(t, "search-empty.xml"))
	setup.fake.answer(searchPath, "The Little Prince Antoine de Saint-Exupéry", 200, opds(t, "search-little-prince.xml"))
	setup.fake.answer("/ebooks/25344.opds", "", 200, opds(t, "detail-25344.xml"))
	evidence := searchEvidence(t, "title-variants")
	snapshot(t, db, filepath.Join(evidence, "before.sqlite3"))
	setup.fake.reset()
	outcome := setup.search(t, plainBinary, faults{}, request)
	if outcome.code != 0 || last(t, outcome, "search").text("outcome") != "candidates" {
		t.Fatalf("exit %d: %s", outcome.code, outcome.output)
	}
	want := []string{searchPath + "?Le Petit Prince Antoine de Saint-Exupéry", searchPath + "?The Little Prince Antoine de Saint-Exupéry", "/ebooks/25344.opds?"}
	if got := setup.fake.requests(); !reflect.DeepEqual(got, want) {
		t.Errorf("requests %q", got)
	}
	if got := rows(t, db, `SELECT guid, title FROM search_results WHERE request_id = ?`, request); !reflect.DeepEqual(got, [][]string{{"string:gutenberg:25344", "string:The Little Prince - Saint-Exupéry, Antoine de [EPUB] [English]"}}) {
		t.Errorf("results %v", got)
	}
	snapshot(t, db, filepath.Join(evidence, "after.sqlite3"))
	setup.record(t, evidence, searchCase{Name: "title_variants", Bundle: "upgrade", RequestID: request, Outcome: "candidates", Candidates: []string{"gutenberg:25344"}})
}

func TestGutenbergProviderFailuresAreNeverReadAsNoResults(t *testing.T) {
	setup := newSearchSetup(t, currentBundle)
	db := setup.db
	listing := opds(t, "search-pride.xml")
	for _, test := range []struct {
		name     string
		replies  []reply
		options  []string
		outcome  string
		code     string
		evidence string
	}{
		{name: "unavailable", replies: []reply{{Path: searchPath, Status: 503, Body: "Service Unavailable"}}, outcome: "released", code: "provider-busy"},
		{name: "rate limited", replies: []reply{{Path: searchPath, Status: 429, Body: "Too Many Requests"}}, outcome: "released", code: "provider-busy"},
		{name: "timeout", replies: []reply{{Path: searchPath, Status: 200, Body: listing, delay: 4 * time.Second}}, options: []string{"--request-timeout", "500ms"}, outcome: "released", code: "provider-timeout"},
		{name: "partial", replies: []reply{{Path: searchPath, Status: 200, Body: listing}, {Path: "/ebooks/42671.opds", Status: 500, Body: "Internal Server Error"}}, outcome: "released", code: "provider-busy"},
		{name: "deadline", replies: []reply{{Path: searchPath, Status: 200, Body: listing, delay: 700 * time.Millisecond}, {Path: "/ebooks/1342.opds", Status: 200, Body: opds(t, "detail-1342.xml"), delay: 700 * time.Millisecond}}, options: []string{"--deadline", "1s"}, outcome: "released", code: "search-deadline"},
		{name: "withheld", replies: []reply{{Path: searchPath, Status: 200, Body: opds(t, "search-withheld.xml")}, {Path: "/ebooks/30254.opds", Status: 200, Body: opds(t, "detail-30254.xml")}, {Path: "/ebooks/30255.opds", Status: 200, Body: opds(t, "detail-30255.xml")}}, outcome: "released", code: "unsupported-candidates", evidence: "withheld"},
		{name: "malformed", replies: []reply{{Path: searchPath, Status: 200, Body: opds(t, "search-truncated.xml")}}, outcome: "failed", code: "provider-malformed", evidence: "malformed"},
		{name: "too large", replies: []reply{{Path: searchPath, Status: 200, Body: strings.Repeat(" ", 1<<20+1)}}, outcome: "failed", code: "provider-too-large"},
		{name: "redirect", replies: []reply{{Path: searchPath, Status: 302, Body: "/elsewhere"}, {Path: "/elsewhere", Status: 200, Body: listing}}, outcome: "failed", code: "provider-refused"},
		{name: "maintenance page", replies: []reply{{Path: searchPath, Status: 200, Body: "<html><body><p>Down for maintenance</p></body></html>"}}, outcome: "failed", code: "provider-malformed"},
		{name: "text after the feed", replies: []reply{{Path: searchPath, Status: 200, Body: opds(t, "search-empty.xml") + "Service Unavailable"}}, outcome: "failed", code: "provider-malformed"},
		{name: "html detail after a candidate", replies: []reply{{Path: searchPath, Status: 200, Body: listing}, {Path: "/ebooks/42671.opds", Status: 200, Body: "<html><body><p>Down for maintenance</p></body></html>"}}, outcome: "failed", code: "provider-malformed"},
		{name: "only another language before an unread page", replies: []reply{{Path: searchPath, Status: 200, Body: strings.Replace(opds(t, "search-empty.xml"), "<opensearch:itemsPerPage>", `<link rel="next" href="/ebooks/search.opds/?start_index=26"/><entry><id>http://www.gutenberg.org/ebooks/42671.opds</id><link rel="subsection" href="/ebooks/42671.opds"/></entry><opensearch:itemsPerPage>`, 1)}}, outcome: "failed", code: "provider-pagination"},
		{name: "a feed in another namespace", replies: []reply{{Path: searchPath, Status: 200, Body: `<rss:feed xmlns:rss="urn:example:status"><rss:error>Maintenance</rss:error></rss:feed>`}}, outcome: "failed", code: "provider-malformed"},
		{name: "a paged book page with only another language", replies: []reply{{Path: searchPath, Status: 200, Body: strings.Replace(opds(t, "search-empty.xml"), "<opensearch:itemsPerPage>", `<entry><id>http://www.gutenberg.org/ebooks/42671.opds</id><link rel="subsection" href="/ebooks/42671.opds"/></entry><opensearch:itemsPerPage>`, 1)},
			{Path: "/ebooks/42671.opds", Status: 200, Body: strings.Replace(opds(t, "detail-42671.xml"), "<entry>", `<link rel="next" href="/ebooks/42671.opds?start_index=2"/><entry>`, 1)}}, outcome: "failed", code: "provider-pagination"},
		{name: "forbidden", replies: []reply{{Path: searchPath, Status: 403, Body: "Forbidden"}}, outcome: "failed", code: "provider-refused"},
		{name: "next page only", replies: []reply{{Path: searchPath, Status: 200, Body: strings.Replace(opds(t, "search-empty.xml"), "<opensearch:itemsPerPage>", `<link rel="next" href="/ebooks/search.opds/?start_index=26"/><opensearch:itemsPerPage>`, 1)}}, outcome: "failed", code: "provider-pagination"},
	} {
		t.Run(test.name, func(t *testing.T) {
			title := "Failure " + test.name
			request := setup.admit(t, title, "")
			setup.fake.defaults()
			for _, answer := range test.replies {
				if answer.Path == searchPath {
					answer.Query = title
				}
				setup.fake.set(answer)
			}
			before := observe(t, db, request)
			var evidence string
			if test.evidence != "" {
				evidence = searchEvidence(t, test.evidence)
				snapshot(t, db, filepath.Join(evidence, "before.sqlite3"))
			}
			setup.fake.reset()
			outcome := setup.search(t, plainBinary, faults{}, request, test.options...)
			answer := last(t, outcome, "search")
			if outcome.code != 1 || answer.text("outcome") != test.outcome || answer.text("code") != test.code {
				t.Fatalf("exit %d: %s", outcome.code, outcome.output)
			}
			state := stateOf(t, db, request)
			switch test.outcome {
			case "released":
				if state.Status != 0 || state.Generation != 2 || state.Claimed || state.Attention != 0 || state.Issue != "" || state.Retries != 0 {
					t.Errorf("released state %+v", state)
				}
				if own := requestRows(t, db, request); !reflect.DeepEqual(own, before.own) {
					t.Errorf("a released search wrote %v", own)
				}
			case "failed":
				if state.Status != 1 || state.Generation != 1 || state.Claimed || state.Attention != 1 || state.Issue != failureMessage || state.Retries != 0 || state.NextRetry != "" {
					t.Errorf("failed state %+v", state)
				}
				if got := scalar[int64](t, db, `SELECT COUNT(*) FROM search_results WHERE request_id = ?`, request); got != 0 {
					t.Errorf("%d results written by a failed search", got)
				}
				if got := scalar[int64](t, db, `SELECT COUNT(*) FROM notifications WHERE notifiable_type = 'Request' AND notifiable_id = ?`, request); got != 1 {
					t.Errorf("%d attention notifications", got)
				}
			}
			for _, seen := range setup.fake.requests() {
				if strings.HasPrefix(seen, "/elsewhere") {
					t.Error("a redirect was followed")
				}
			}
			before.requireOthers(t, db, request)
			if evidence != "" {
				snapshot(t, db, filepath.Join(evidence, "after.sqlite3"))
				setup.record(t, evidence, searchCase{Name: test.evidence, Bundle: "current", RequestID: request, Outcome: test.outcome, Code: test.code})
			}
			if test.outcome != "released" {
				return
			}
			setup.fake.defaults()
			setup.fake.answer(searchPath, title, 200, opds(t, "search-pride.xml"))
			resumed := setup.search(t, plainBinary, faults{}, request)
			if resumed.code != 0 || last(t, resumed, "search").text("outcome") != "candidates" || stateOf(t, db, request).Generation != 3 {
				t.Errorf("a released request did not resume: exit %d %s", resumed.code, resumed.output)
			}
		})
	}
}

func TestGutenbergSearchRefusesWorkItMustNotClaim(t *testing.T) {
	setup := newSearchSetup(t, upgradeBundle)
	db := setup.db
	request := setup.admit(t, "Pride and Prejudice", "Jane Austen")
	audiobookBook := exec1(t, db, `INSERT INTO books (title, book_type, content_kind, created_at, updated_at) VALUES ('Spoken Pride', 0, 0, ?, ?)`, seededStamp, seededStamp)
	audiobook := exec1(t, db, `INSERT INTO requests (book_id, user_id, status, created_via, request_scope, retry_count, search_generation, language, created_at, updated_at) VALUES (?, ?, 0, 'web', 'single', 0, 0, 'en', ?, ?)`, audiobookBook, setup.users["alice"], seededStamp, seededStamp)
	ebook := scalar[int64](t, db, `SELECT book_id FROM requests WHERE id = ?`, request)
	deleted := exec1(t, db, `INSERT INTO requests (book_id, user_id, status, created_via, request_scope, retry_count, search_generation, language, created_at, updated_at) VALUES (?, ?, 0, 'web', 'single', 0, 0, 'en', ?, ?)`, ebook, setup.users["carol"], seededStamp, seededStamp)
	downloading := exec1(t, db, `INSERT INTO requests (book_id, user_id, status, created_via, request_scope, retry_count, search_generation, language, created_at, updated_at) VALUES (?, ?, 3, 'web', 'single', 0, 0, 'en', ?, ?)`, ebook, setup.users["bob"], seededStamp, seededStamp)

	refuse := func(t *testing.T, target int64, code string) {
		t.Helper()
		before := observe(t, db, target)
		setup.fake.reset()
		outcome := setup.search(t, plainBinary, faults{}, target)
		event := "rejected"
		exit := 7
		if code == "request_claimed" {
			event, exit = "refused", 3
		}
		if outcome.code != exit || last(t, outcome, event).text("code") != code {
			t.Fatalf("exit %d: %s", outcome.code, outcome.output)
		}
		if seen := setup.fake.requests(); len(seen) != 0 {
			t.Errorf("the catalogue was contacted: %q", seen)
		}
		before.requireAll(t, db, target)
	}
	t.Run("an enabled custom provider", func(t *testing.T) { refuse(t, request, "other_sources_configured") })
	setup.disableCustomProviders(t)
	t.Run("an audiobook", func(t *testing.T) { refuse(t, audiobook, "not_an_ebook") })
	t.Run("a deleted account", func(t *testing.T) { refuse(t, deleted, "account_unavailable") })
	t.Run("a downloading request", func(t *testing.T) { refuse(t, downloading, "request_not_pending") })
	t.Run("a missing request", func(t *testing.T) {
		before := digests(t, db)
		outcome := setup.search(t, plainBinary, faults{}, 999999)
		if outcome.code != 7 || last(t, outcome, "rejected").text("code") != "request_not_found" {
			t.Fatalf("exit %d: %s", outcome.code, outcome.output)
		}
		requireSame(t, before, digests(t, db))
	})
	for _, test := range []struct {
		name     string
		settings [][3]string
		code     string
	}{
		{"gutenberg disabled", [][3]string{{"gutenberg_enabled", "boolean", "false"}}, "provider_disabled"},
		{"the public catalogue", [][3]string{{"gutenberg_url", "string", "https://www.gutenberg.org"}}, "provider_not_loopback"},
		{"a host name", [][3]string{{"gutenberg_url", "string", strings.Replace(setup.fake.server.URL, "127.0.0.1", "localhost", 1)}}, "provider_not_loopback"},
		{"a catalogue path", [][3]string{{"gutenberg_url", "string", setup.fake.server.URL + "/catalog"}}, "provider_invalid"},
		{"an indexer", [][3]string{{"prowlarr_url", "string", "http://127.0.0.1:9"}}, "other_sources_configured"},
		{"z-library on its default mirrors", [][3]string{{"zlibrary_enabled", "boolean", "true"}, {"zlibrary_email", "string", "reader@example.test"}, {"zlibrary_password", "string", "synthetic"}}, "other_sources_configured"},
		{"auto selection", [][3]string{{"auto_select_enabled", "boolean", "true"}}, "auto_select_enabled"},
		{"a webhook", [][3]string{{"webhook_enabled", "boolean", "true"}, {"webhook_url", "string", "http://127.0.0.1:9/hook"}}, "outbound_notifications_configured"},
		{"an unreadable limit", [][3]string{{"gutenberg_search_limit", "integer", "ten"}}, "unsupported_stored_value"},
	} {
		t.Run(test.name, func(t *testing.T) {
			exec1(t, db, `CREATE TABLE saved_settings AS SELECT * FROM settings`)
			defer func() {
				exec1(t, db, `DELETE FROM settings`)
				exec1(t, db, `INSERT INTO settings SELECT * FROM saved_settings`)
				exec1(t, db, `DROP TABLE saved_settings`)
			}()
			for _, entry := range test.settings {
				putSetting(t, db, entry[0], entry[1], entry[2])
			}
			refuse(t, request, test.code)
		})
	}
	t.Run("a newer schema", func(t *testing.T) {
		exec1(t, db, `INSERT INTO schema_migrations (version) VALUES ('20991231000000')`)
		defer exec1(t, db, `DELETE FROM schema_migrations WHERE version = '20991231000000'`)
		refuse(t, request, "unsupported_schema")
	})
	t.Run("a fresh claim of another worker", func(t *testing.T) {
		exec1(t, db, `UPDATE requests SET status = 1, search_generation = 5, search_claimed_at = ? WHERE id = ?`, formatStamp(time.Now().Add(-29*time.Minute)), downloading)
		refuse(t, downloading, "request_claimed")
	})
	t.Run("a published search awaiting selection", func(t *testing.T) {
		exec1(t, db, `UPDATE requests SET status = 1, search_generation = 5, search_claimed_at = NULL, attention_needed = 1 WHERE id = ?`, downloading)
		refuse(t, downloading, "request_not_pending")
	})
}

func formatStamp(moment time.Time) string { return moment.UTC().Format("2006-01-02 15:04:05.000000") }

func TestGutenbergSearchClaimsARequestOnce(t *testing.T) {
	setup := newSearchSetup(t, currentBundle)
	db := setup.db
	request := setup.admit(t, "Pride and Prejudice", "Jane Austen")
	slowed := setup.fake.routes[routeKey(searchPath, prideQuery)]
	slowed.delay = 400 * time.Millisecond
	setup.fake.set(slowed)
	var runs []*process
	for range 6 {
		runs = append(runs, setup.start(t, plainBinary, faults{}, request))
	}
	codes := map[int]int{}
	for _, run := range runs {
		code := run.wait()
		codes[code]++
		if code == 0 && run.count("claimed") != 1 {
			t.Error("the winner did not report its claim")
		}
		if code != 0 && run.count("claimed") != 0 {
			t.Errorf("a loser claimed: %s", run.output())
		}
	}
	if codes[0] != 1 || codes[0]+codes[3]+codes[7] != len(runs) {
		t.Errorf("exit codes %v", codes)
	}
	state := stateOf(t, db, request)
	if state.Generation != 1 || state.Status != 1 || state.Claimed || state.Attention != 1 {
		t.Errorf("state %+v", state)
	}
	if got := scalar[int64](t, db, `SELECT COUNT(*) FROM search_results WHERE request_id = ?`, request); got != 2 {
		t.Errorf("%d results", got)
	}
	if got := scalar[int64](t, db, `SELECT COUNT(*) FROM request_events WHERE request_id = ?`, request); got != 1 {
		t.Errorf("%d attention events", got)
	}
	if searches := setup.fake.requests(); len(searches) != 5 {
		t.Errorf("%d catalogue requests for one claim", len(searches))
	}
}

func TestGutenbergSearchSurvivesAKill(t *testing.T) {
	setup := newSearchSetup(t, currentBundle)
	db := setup.db

	t.Run("after the claim", func(t *testing.T) {
		request := setup.admit(t, "Pride and Prejudice", "Jane Austen")
		setup.fake.reset()
		killed := setup.search(t, faultBinary, newFaults(t, map[string]string{"search.claimed": "kill"}), request)
		state := stateOf(t, db, request)
		if killed.code != -1 || state.Status != 1 || state.Generation != 1 || !state.Claimed || len(setup.fake.requests()) != 0 {
			t.Fatalf("exit %d state %+v: %s", killed.code, state, killed.output)
		}
		evidence := searchEvidence(t, "killed")
		snapshot(t, db, filepath.Join(evidence, "before.sqlite3"))
		setup.record(t, evidence, searchCase{Name: "killed", Bundle: "current", RequestID: request, Outcome: "claimed"})

		again := setup.search(t, plainBinary, faults{}, request)
		if again.code != 3 || last(t, again, "refused").text("code") != "request_claimed" || stateOf(t, db, request) != state {
			t.Errorf("a live claim was taken over: exit %d %s", again.code, again.output)
		}
		exec1(t, db, `UPDATE requests SET search_claimed_at = ? WHERE id = ?`, formatStamp(time.Now().Add(-31*time.Minute)), request)
		recovered := setup.search(t, plainBinary, faults{}, request)
		if recovered.code != 0 || last(t, recovered, "claimed").number("generation") != 2 || last(t, recovered, "search").text("outcome") != "candidates" {
			t.Errorf("a stale claim was not recovered: exit %d %s", recovered.code, recovered.output)
		}
		if got := scalar[int64](t, db, `SELECT COUNT(*) FROM search_results WHERE request_id = ?`, request); got != 2 {
			t.Errorf("%d results after recovery", got)
		}
	})

	t.Run("inside the publication", func(t *testing.T) {
		request := setup.admit(t, "Pride and Prejudice", "Jane Austen")
		killed := setup.search(t, faultBinary, newFaults(t, map[string]string{"search.before-commit": "kill"}), request)
		state := stateOf(t, db, request)
		if killed.code != -1 || state.Status != 1 || state.Generation != 1 || !state.Claimed || state.Attention != 0 {
			t.Fatalf("exit %d state %+v", killed.code, state)
		}
		for table, found := range requestRows(t, db, request) {
			if len(found) != 0 {
				t.Errorf("an interrupted publication left %s rows", table)
			}
		}
		exec1(t, db, `UPDATE requests SET search_claimed_at = ? WHERE id = ?`, formatStamp(time.Now().Add(-31*time.Minute)), request)
		recovered := setup.search(t, plainBinary, faults{}, request)
		if recovered.code != 0 || last(t, recovered, "search").text("outcome") != "candidates" {
			t.Errorf("exit %d %s", recovered.code, recovered.output)
		}
	})
}

func TestGutenbergSearchDiscardsASupersededAnswer(t *testing.T) {
	setup := newSearchSetup(t, currentBundle)
	db := setup.db

	t.Run("claimed again while the answer was being read", func(t *testing.T) {
		request := setup.admit(t, "Pride and Prejudice", "Jane Austen")
		injected := newFaults(t, map[string]string{"search.fetched": "park"})
		run := setup.start(t, faultBinary, injected, request)
		injected.reached(t, "search.fetched")
		if renewed := scalar[int64](t, db, `SELECT search_claimed_at > updated_at FROM requests WHERE id = ?`, request); renewed != 1 {
			t.Error("the heartbeats did not renew the claim")
		}
		exec1(t, db, `UPDATE requests SET search_generation = search_generation + 1, search_claimed_at = ? WHERE id = ?`, formatStamp(time.Now()), request)
		before := observe(t, db, request)
		injected.release(t, "search.fetched")
		if code := run.wait(); code != 4 || run.snapshot()[len(run.snapshot())-1].text("outcome") != "superseded" {
			t.Fatalf("exit %d: %s", code, run.output())
		}
		before.requireAll(t, db, request)
	})

	t.Run("finished by its owner while the answer was being read", func(t *testing.T) {
		request := setup.admit(t, "Pride and Prejudice", "Jane Austen")
		injected := newFaults(t, map[string]string{"search.fetched": "park"})
		run := setup.start(t, faultBinary, injected, request)
		injected.reached(t, "search.fetched")
		exec1(t, db, `UPDATE requests SET search_claimed_at = NULL, attention_needed = 1, issue_description = 'Finished elsewhere' WHERE id = ?`, request)
		before := observe(t, db, request)
		injected.release(t, "search.fetched")
		if code := run.wait(); code != 4 || run.snapshot()[len(run.snapshot())-1].text("outcome") != "superseded" {
			t.Fatalf("exit %d: %s", code, run.output())
		}
		before.requireAll(t, db, request)
	})

	t.Run("its language changed while the answer was being read", func(t *testing.T) {
		request := setup.admit(t, "Pride and Prejudice", "Jane Austen")
		exec1(t, db, `UPDATE requests SET language = NULL WHERE id = ?`, request)
		putSetting(t, db, "default_language", "string", "en")
		defer exec1(t, db, `DELETE FROM settings WHERE key = 'default_language'`)
		injected := newFaults(t, map[string]string{"search.fetched": "park"})
		run := setup.start(t, faultBinary, injected, request)
		injected.reached(t, "search.fetched")
		putSetting(t, db, "default_language", "string", "fr")
		injected.release(t, "search.fetched")
		if code := run.wait(); code != 1 {
			t.Fatalf("exit %d: %s", code, run.output())
		}
		answer := run.snapshot()[len(run.snapshot())-1]
		state := stateOf(t, db, request)
		if answer.text("outcome") != "released" || answer.text("code") != "configuration-changed" || state.Status != 0 || state.Generation != 2 || state.Claimed {
			t.Errorf("%v %+v", answer, state)
		}
		if got := scalar[int64](t, db, `SELECT COUNT(*) FROM search_results WHERE request_id = ?`, request); got != 0 {
			t.Errorf("%d results filtered for the old language were published", got)
		}
	})

	t.Run("claimed by another worker between two answers", func(t *testing.T) {
		request := setup.admit(t, "Pride and Prejudice", "Jane Austen")
		detail := setup.fake.routes[routeKey("/ebooks/1342.opds", "")]
		detail.before = func() {
			if _, err := db.Exec(`UPDATE requests SET search_generation = search_generation + 1, search_claimed_at = ? WHERE id = ?`, formatStamp(time.Now()), request); err != nil {
				t.Error(err)
			}
		}
		setup.fake.set(detail)
		defer func() { detail.before = nil; setup.fake.set(detail) }()
		setup.fake.reset()
		outcome := setup.search(t, plainBinary, faults{}, request)
		if outcome.code != 4 || last(t, outcome, "search").text("outcome") != "superseded" {
			t.Fatalf("exit %d: %s", outcome.code, outcome.output)
		}
		if seen := setup.fake.requests(); len(seen) != 2 {
			t.Errorf("a superseded search kept asking the catalogue: %q", seen)
		}
		state := stateOf(t, db, request)
		if state.Generation != 2 || state.Status != 1 || !state.Claimed || state.Attention != 0 {
			t.Errorf("the new owner's claim was changed: %+v", state)
		}
		if got := scalar[int64](t, db, `SELECT COUNT(*) FROM search_results WHERE request_id = ?`, request); got != 0 {
			t.Errorf("%d results from a superseded search", got)
		}
	})

	t.Run("configuration changed while the answer was being read", func(t *testing.T) {
		request := setup.admit(t, "Pride and Prejudice", "Jane Austen")
		injected := newFaults(t, map[string]string{"search.fetched": "park"})
		run := setup.start(t, faultBinary, injected, request)
		injected.reached(t, "search.fetched")
		putSetting(t, db, "gutenberg_enabled", "boolean", "false")
		defer putSetting(t, db, "gutenberg_enabled", "boolean", "true")
		injected.release(t, "search.fetched")
		if code := run.wait(); code != 1 {
			t.Fatalf("exit %d: %s", code, run.output())
		}
		answer := run.snapshot()[len(run.snapshot())-1]
		state := stateOf(t, db, request)
		if answer.text("outcome") != "released" || answer.text("code") != "configuration-changed" || state.Status != 0 || state.Generation != 2 || state.Claimed {
			t.Errorf("%v %+v", answer, state)
		}
		if got := scalar[int64](t, db, `SELECT COUNT(*) FROM search_results WHERE request_id = ?`, request); got != 0 {
			t.Errorf("%d results published under a changed configuration", got)
		}
	})

	t.Run("stopped by a signal", func(t *testing.T) {
		request := setup.admit(t, "Pride and Prejudice", "Jane Austen")
		slowed := setup.fake.routes[routeKey(searchPath, prideQuery)]
		slowed.delay = 10 * time.Second
		setup.fake.set(slowed)
		defer func() { slowed.delay = 0; setup.fake.set(slowed) }()
		run := setup.start(t, plainBinary, faults{}, request)
		run.waitFor(named("claimed"))
		if code := run.terminate(); code != 1 {
			t.Fatalf("exit %d: %s", code, run.output())
		}
		answer := run.snapshot()[len(run.snapshot())-1]
		state := stateOf(t, db, request)
		if answer.text("outcome") != "released" || answer.text("code") != "cancelled" || state.Status != 0 || state.Generation != 2 || state.Claimed {
			t.Errorf("%v %+v", answer, state)
		}
	})
}

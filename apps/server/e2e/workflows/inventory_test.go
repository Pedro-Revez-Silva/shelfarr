//go:build e2e

package workflows

import (
	"database/sql"
	"net/http"
	"reflect"
	"strings"
	"testing"
)

func (w *workdir) configureABS(db *sql.DB, peer *absPeer, libraries ...string) {
	w.t.Helper()
	settings := map[string]string{
		"audiobookshelf_url":     peer.URL,
		"audiobookshelf_api_key": absKey,
	}
	if len(libraries) > 0 {
		settings["audiobookshelf_audiobook_library_id"] = libraries[0]
		settings["audiobookshelf_audiobook_scan_library_ids"] = strings.Join(libraries[1:], ", ")
	}
	setSettings(w.t, db, settings)
}

func inventoryOf(t *testing.T, db *sql.DB) [][]string {
	return rows(t, db, `SELECT library_platform, library_id, audiobookshelf_id, title, subtitle, author, narrator, series, series_position, publisher, language, description, isbn, asin, published_year, missing FROM library_items ORDER BY library_platform, library_id, audiobookshelf_id`)
}

func seedItem(t *testing.T, db *sql.DB, platform, library, id, title, syncedAt string) {
	t.Helper()
	exec1(t, db, `INSERT INTO library_items (library_platform, library_id, audiobookshelf_id, title, missing, synced_at, created_at, updated_at) VALUES (?, ?, ?, ?, 0, ?, '2025-01-01 00:00:00.000000', '2025-01-01 00:00:00.000000')`, platform, library, id, title, nullIfEmpty(syncedAt))
}

func nullIfEmpty(text string) any {
	if text == "" {
		return nil
	}
	return text
}

func TestInventoryPublishesTheSnapshotWithRailsSemantics(t *testing.T) {
	for name, bundle := range map[string]string{"current schema": currentBundle, "upgraded released schema": upgradeBundle} {
		t.Run(name, func(t *testing.T) {
			work := prepare(t, bundle)
			db := work.open()
			peer := newABS(t, libraryOf("lib-a", "Dune", "Emma", "Ulysses", "Hamlet", "Beloved"))
			work.configureABS(db, peer, "lib-a")
			db.Exec(`DELETE FROM library_items`)
			seedItem(t, db, "audiobookshelf", "lib-a", "lib-a-dune", "Stale title", "2025-06-01 00:00:00.000000")
			seedItem(t, db, "audiobookshelf", "lib-a", "gone-from-server", "Removed upstream", "2025-06-01 00:00:00.000000")
			seedItem(t, db, "audiobookshelf", "lib-a", "newer-than-snapshot", "Newer local", "2999-01-01 00:00:00.000000")
			seedItem(t, db, "audiobookshelf", "lib-old", "old-library-item", "Library no longer configured", "2025-06-01 00:00:00.000000")
			seedItem(t, db, "bookorbit", "lib-a", "other-platform", "Other platform", "2025-06-01 00:00:00.000000")
			before := digests(t, db, "library_items", "settings")
			createdBefore := scalar[string](t, db, `SELECT created_at FROM library_items WHERE audiobookshelf_id = 'lib-a-dune'`)

			outcome := work.runOnce(faults{}, "--page-size", "2")
			if outcome.code != 0 {
				t.Fatalf("exit %d: %s", outcome.code, outcome.output)
			}
			ids := rows(t, db, `SELECT library_platform, library_id, audiobookshelf_id FROM library_items ORDER BY 1, 2, 3`)
			want := [][]string{
				{"string:audiobookshelf", "string:lib-a", "string:lib-a-beloved"},
				{"string:audiobookshelf", "string:lib-a", "string:lib-a-dune"},
				{"string:audiobookshelf", "string:lib-a", "string:lib-a-emma"},
				{"string:audiobookshelf", "string:lib-a", "string:lib-a-hamlet"},
				{"string:audiobookshelf", "string:lib-a", "string:lib-a-ulysses"},
				{"string:audiobookshelf", "string:lib-a", "string:newer-than-snapshot"},
				{"string:bookorbit", "string:lib-a", "string:other-platform"},
			}
			if !reflect.DeepEqual(ids, want) {
				t.Fatalf("inventory %v", ids)
			}
			dune := rows(t, db, `SELECT title, subtitle, author, narrator, series, series_position, publisher, language, description, isbn, asin, published_year, missing, created_at, typeof(synced_at) FROM library_items WHERE audiobookshelf_id = 'lib-a-dune'`)[0]
			wantDune := []string{"string:Dune", "string:Sub lib-a-dune", "string:Author lib-a-dune", "string:Narrator lib-a-dune", "string:Series", "string:2", "string:Pub", "string:en", "string:About Dune", "string:978lib-a-dune", "string:Blib-a-dune", "int64:2001", "int64:0", "string:" + createdBefore, "string:text"}
			if !reflect.DeepEqual(dune, wantDune) {
				t.Fatalf("dune %v\nwant %v", dune, wantDune)
			}
			if title := scalar[string](t, db, `SELECT title FROM library_items WHERE audiobookshelf_id = 'newer-than-snapshot'`); title != "Newer local" {
				t.Fatalf("a newer row was overwritten: %s", title)
			}
			fresh := rows(t, db, `SELECT created_at = updated_at, synced_at = (SELECT snapshot_at FROM wf_inventory_runs) FROM library_items WHERE audiobookshelf_id = 'lib-a-emma'`)[0]
			if fresh[0] != "int64:1" || fresh[1] != "int64:1" {
				t.Fatalf("timestamps %v", fresh)
			}
			requireSame(t, before, digests(t, db, "library_items", "settings"))
			if state := scalar[string](t, db, `SELECT state FROM wf_inventory_runs`); state != "published" {
				t.Fatalf("run %s", state)
			}
			if stage := scalar[int64](t, db, `SELECT COUNT(*) FROM wf_inventory_stage`); stage != 0 {
				t.Fatalf("stage rows left: %d", stage)
			}
			if got := peer.itemRequests("lib-a"); got != 3 {
				t.Fatalf("expected 3 paginated requests, saw %d", got)
			}
			assertNoSecrets(t, outcome.output)
		})
	}
}

func assertNoSecrets(t *testing.T, output string) {
	t.Helper()
	for _, secret := range []string{absKey, qbitPassword, "Authorization", "Bearer"} {
		if strings.Contains(output, secret) {
			t.Fatalf("output leaked %q", secret)
		}
	}
}

func TestUnreliableInventoriesNeverChangeLiveInventory(t *testing.T) {
	cases := []struct {
		name    string
		library *fakeLibrary
		hook    func(library string, page int, w http.ResponseWriter, r *http.Request) bool
		args    []string
		code    string
	}{
		{name: "server error", hook: func(string, int, http.ResponseWriter, *http.Request) bool { return false }, code: "http-status-500"},
		{name: "truncated inventory", code: "truncated"},
		{name: "total shrinks between pages", code: "inconsistent"},
		{name: "garbage body", code: "malformed"},
		{name: "empty list without a total", code: "malformed"},
		{name: "connection dropped", code: "connection"},
		{name: "unauthorised", code: "auth-401"},
		{name: "hung response", args: []string{"--request-timeout", "300ms"}, code: "connection"},
	}
	for _, entry := range cases {
		t.Run(entry.name, func(t *testing.T) {
			work := prepare(t, currentBundle)
			db := work.open()
			library := libraryOf("lib-a", "One", "Two", "Three", "Four")
			peer := newABS(t, library)
			work.configureABS(db, peer, "lib-a")
			seedItem(t, db, "audiobookshelf", "lib-a", "keep-1", "Must survive", "2025-06-01 00:00:00.000000")
			seedItem(t, db, "audiobookshelf", "lib-b", "keep-2", "Must survive too", "2025-06-01 00:00:00.000000")
			before := digests(t, db, "wf_none")
			hold := make(chan struct{})
			defer close(hold)
			peer.hook = func(id string, page int, w http.ResponseWriter, r *http.Request) bool {
				switch entry.name {
				case "server error":
					w.WriteHeader(500)
				case "truncated inventory":
					if page == 0 {
						w.Write([]byte(`{"results":[{"id":"x"},{"id":"y"}],"total":4,"page":0}`))
					} else {
						w.Write([]byte(`{"results":[],"total":4,"page":1}`))
					}
				case "total shrinks between pages":
					if page == 0 {
						w.Write([]byte(`{"results":[{"id":"a"},{"id":"b"}],"total":4}`))
					} else {
						w.Write([]byte(`{"results":[{"id":"c"}],"total":3}`))
					}
				case "garbage body":
					w.Write([]byte("<html>Bad gateway</html>"))
				case "empty list without a total":
					w.Write([]byte(`{"results":[]}`))
				case "connection dropped":
					hijacker := w.(http.Hijacker)
					connection, _, _ := hijacker.Hijack()
					connection.Close()
				case "unauthorised":
					w.WriteHeader(401)
				case "hung response":
					select {
					case <-hold:
					case <-r.Context().Done():
					}
				}
				return true
			}
			outcome := work.runOnce(faults{}, append([]string{"--page-size", "2"}, entry.args...)...)
			if outcome.code != 1 {
				t.Fatalf("exit %d: %s", outcome.code, outcome.output)
			}
			if !contains(outcome.codes, "all-libraries-failed") {
				t.Fatalf("codes %v", outcome.codes)
			}
			failed := rows(t, db, `SELECT state, error_code FROM wf_inventory_libraries`)
			if len(failed) != 1 || failed[0][0] != "string:failed" || failed[0][1] != "string:"+entry.code {
				t.Fatalf("library state %v, want %s", failed, entry.code)
			}
			requireSame(t, before, digests(t, db, "wf_none"))
			if stage := scalar[int64](t, db, `SELECT COUNT(*) FROM wf_inventory_stage`); stage != 0 {
				t.Fatalf("staged rows for an unreliable inventory: %d", stage)
			}
			assertNoSecrets(t, outcome.output)
			if strings.Contains(outcome.output, "Bad gateway") || strings.Contains(outcome.output, "keep-1") {
				t.Fatalf("fixture-controlled text in output: %s", outcome.output)
			}
		})
	}
}

func contains(list []string, wanted string) bool {
	for _, entry := range list {
		if entry == wanted {
			return true
		}
	}
	return false
}

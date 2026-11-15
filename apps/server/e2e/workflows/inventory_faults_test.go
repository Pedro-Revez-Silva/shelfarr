//go:build e2e

package workflows

import (
	"database/sql"
	"net/http"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
)

var inventoryOnly = []string{"--workflows", "inventory", "--page-size", "2"}

type inventoryFixture struct {
	work *workdir
	db   *sql.DB
	peer *absPeer
}

func newInventoryFixture(t *testing.T, libraries ...*fakeLibrary) inventoryFixture {
	t.Helper()
	work := prepare(t, currentBundle)
	db := work.open()
	peer := newABS(t, libraries...)
	var ids []string
	for _, library := range libraries {
		ids = append(ids, library.ID)
	}
	work.configureABS(db, peer, ids...)
	return inventoryFixture{work: work, db: db, peer: peer}
}

func (f inventoryFixture) seedLive(t *testing.T) {
	t.Helper()
	seedItem(t, f.db, "audiobookshelf", "lib-a", "lib-a-one", "Old one", "2025-06-01 00:00:00.000000")
	seedItem(t, f.db, "audiobookshelf", "lib-a", "removed-upstream", "Gone", "2025-06-01 00:00:00.000000")
	seedItem(t, f.db, "audiobookshelf", "lib-b", "lib-b-uno", "Old uno", "2025-06-01 00:00:00.000000")
}

func (f inventoryFixture) runs(t *testing.T) [][]string {
	return rows(t, f.db, `SELECT id, state FROM wf_inventory_runs ORDER BY id`)
}

func TestExplicitEmptyInventoryRemovesOnlyItsOwnLibrary(t *testing.T) {
	fixture := newInventoryFixture(t, libraryOf("lib-a"), libraryOf("lib-b", "Uno", "Dos"))
	fixture.seedLive(t)
	seedItem(t, fixture.db, "audiobookshelf", "lib-a", "kept-newer", "Newer than the snapshot", "2999-01-01 00:00:00.000000")
	seedItem(t, fixture.db, "audiobookshelf", "lib-old", "out-of-scope-newer", "Not configured but newer", "2999-01-01 00:00:00.000000")
	seedItem(t, fixture.db, "bookorbit", "lib-a", "other-platform", "Other platform", "2025-06-01 00:00:00.000000")
	outcome := fixture.work.runOnce(faults{}, inventoryOnly...)
	if outcome.code != 0 {
		t.Fatalf("exit %d: %s", outcome.code, outcome.output)
	}
	got := rows(t, fixture.db, `SELECT library_platform, library_id, audiobookshelf_id FROM library_items ORDER BY 1, 2, 3`)
	want := [][]string{
		{"string:audiobookshelf", "string:lib-a", "string:kept-newer"},
		{"string:audiobookshelf", "string:lib-b", "string:lib-b-dos"},
		{"string:audiobookshelf", "string:lib-b", "string:lib-b-uno"},
		{"string:audiobookshelf", "string:lib-old", "string:out-of-scope-newer"},
		{"string:bookorbit", "string:lib-a", "string:other-platform"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("inventory %v", got)
	}
	libraries := rows(t, fixture.db, `SELECT library_id, state, item_count FROM wf_inventory_libraries ORDER BY library_id`)
	if !reflect.DeepEqual(libraries, [][]string{{"string:lib-a", "string:empty", "int64:0"}, {"string:lib-b", "string:staged", "int64:2"}}) {
		t.Fatalf("libraries %v", libraries)
	}
}

func TestEmptyWithoutAnExplicitTotalIsNotAuthoritative(t *testing.T) {
	fixture := newInventoryFixture(t, libraryOf("lib-a", "One"))
	fixture.seedLive(t)
	before := digests(t, fixture.db)
	fixture.peer.setHook(func(id string, page int, w http.ResponseWriter, r *http.Request) bool {
		w.Write([]byte(`{"results":[],"page":0}`))
		return true
	})
	outcome := fixture.work.runOnce(faults{}, inventoryOnly...)
	if outcome.code != 1 {
		t.Fatalf("exit %d", outcome.code)
	}
	requireSame(t, before, digests(t, fixture.db))
}

func TestPartialFailurePublishesOnlyCompleteLibrariesAndSkipsOutOfScopePruning(t *testing.T) {
	fixture := newInventoryFixture(t, libraryOf("lib-a", "One", "Two"), libraryOf("lib-b", "Uno"))
	fixture.seedLive(t)
	seedItem(t, fixture.db, "audiobookshelf", "lib-old", "old", "Out of scope", "2025-06-01 00:00:00.000000")
	fixture.peer.setHook(func(id string, page int, w http.ResponseWriter, r *http.Request) bool {
		if id == "lib-b" {
			w.WriteHeader(500)
			return true
		}
		return false
	})
	outcome := fixture.work.runOnce(faults{}, inventoryOnly...)
	if outcome.code != 1 || !contains(outcome.codes, "http-status-500") {
		t.Fatalf("exit %d codes %v", outcome.code, outcome.codes)
	}
	got := rows(t, fixture.db, `SELECT library_id, audiobookshelf_id FROM library_items ORDER BY 1, 2`)
	want := [][]string{
		{"string:lib-a", "string:lib-a-one"}, {"string:lib-a", "string:lib-a-two"},
		{"string:lib-b", "string:lib-b-uno"}, {"string:lib-old", "string:old"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("inventory %v", got)
	}
	if title := scalar[string](t, fixture.db, `SELECT title FROM library_items WHERE audiobookshelf_id = 'lib-b-uno'`); title != "Old uno" {
		t.Fatalf("a failed library was modified: %s", title)
	}
	if state := scalar[string](t, fixture.db, `SELECT state FROM wf_inventory_runs`); state != "published" {
		t.Fatalf("run %s", state)
	}
}

func TestConfigurationChangedDuringFetchPublishesNothing(t *testing.T) {
	for name, change := range map[string]map[string]string{
		"library set": {"audiobookshelf_audiobook_scan_library_ids": "lib-b, lib-c"},
		"platform":    {"library_platform": "grimmory"},
		"server url":  {"audiobookshelf_url": "http://127.0.0.1:1"},
	} {
		t.Run(name, func(t *testing.T) {
			fixture := newInventoryFixture(t, libraryOf("lib-a", "One", "Two", "Three"), libraryOf("lib-b", "Uno"))
			fixture.seedLive(t)
			before := digests(t, fixture.db, "settings")
			var changed atomic.Bool
			fixture.peer.setHook(func(id string, page int, w http.ResponseWriter, r *http.Request) bool {
				if page == 1 && changed.CompareAndSwap(false, true) {
					setSettings(t, fixture.db, change)
				}
				return false
			})
			outcome := fixture.work.runOnce(faults{}, inventoryOnly...)
			if !changed.Load() {
				t.Fatal("the change never happened during a fetch")
			}
			if outcome.code != 0 {
				t.Fatalf("exit %d: %s", outcome.code, outcome.output)
			}
			requireSame(t, before, digests(t, fixture.db, "settings"))
			if runs := fixture.runs(t); !reflect.DeepEqual(runs, [][]string{{"int64:1", "string:abandoned"}}) {
				t.Fatalf("runs %v", runs)
			}
			if stage := scalar[int64](t, fixture.db, `SELECT COUNT(*) FROM wf_inventory_stage`); stage != 0 {
				t.Fatalf("stage rows %d", stage)
			}
			if !strings.Contains(scalar[string](t, fixture.db, `SELECT outcome FROM wf_inventory_runs`), "configuration-changed") {
				t.Fatal("outcome not recorded")
			}
		})
	}
}

func TestConfigurationChangedBeforePublicationAbandonsStagedData(t *testing.T) {
	fixture := newInventoryFixture(t, libraryOf("lib-a", "One"))
	fixture.seedLive(t)
	before := digests(t, fixture.db, "settings")
	injected := newFaults(t, map[string]string{"inventory.before-publish": "park"})
	run := fixture.work.command(injected, append([]string{"run", "--once"}, inventoryOnly...)...)
	injected.reached(t, "inventory.before-publish")
	if staged := scalar[int64](t, fixture.db, `SELECT COUNT(*) FROM wf_inventory_stage`); staged != 1 {
		t.Fatalf("expected staged data, saw %d", staged)
	}
	setSettings(t, fixture.db, map[string]string{"audiobookshelf_audiobook_library_id": "lib-z"})
	injected.release(t, "inventory.before-publish")
	if code := run.wait(); code != 0 {
		t.Fatalf("exit %d: %s", code, run.output())
	}
	requireSame(t, before, digests(t, fixture.db, "settings"))
	if runs := fixture.runs(t); !reflect.DeepEqual(runs, [][]string{{"int64:1", "string:abandoned"}}) {
		t.Fatalf("runs %v", runs)
	}
}

func TestCancellationIsPersistedAbortsTheFetchAndIsNeverResurrected(t *testing.T) {
	fixture := newInventoryFixture(t, libraryOf("lib-a", "One", "Two"))
	fixture.seedLive(t)
	before := digests(t, fixture.db)
	reached := make(chan struct{}, 1)
	var blocking atomic.Bool
	blocking.Store(true)
	fixture.peer.setHook(func(id string, page int, w http.ResponseWriter, r *http.Request) bool {
		if !blocking.Load() {
			return false
		}
		reached <- struct{}{}
		<-r.Context().Done()
		return true
	})
	run := fixture.work.command(faults{}, append([]string{"run", "--once"}, inventoryOnly...)...)
	<-reached
	if code := fixture.work.control("cancel", "inventory"); code != 0 {
		t.Fatalf("cancel exited %d", code)
	}
	if code := run.wait(); code != 0 {
		t.Fatalf("exit %d: %s", code, run.output())
	}
	blocking.Store(false)
	requireSame(t, before, digests(t, fixture.db))
	if runs := fixture.runs(t); !reflect.DeepEqual(runs, [][]string{{"int64:1", "string:cancelled"}}) {
		t.Fatalf("runs %v", runs)
	}
	if status := fixture.work.status(); status["inventory"].(map[string]any)["state"] != "cancelled" {
		t.Fatalf("schedule %v", status)
	}
	if code := fixture.work.control("trigger", "inventory"); code != 0 {
		t.Fatalf("trigger exited %d", code)
	}
	again := fixture.work.runOnce(faults{}, inventoryOnly...)
	if again.code != 0 || fixture.runs(t)[0][1] != "string:cancelled" || len(fixture.runs(t)) != 1 {
		t.Fatalf("a cancelled workflow was resurrected: %v %v", again.code, fixture.runs(t))
	}
	fixture.work.control("resume", "inventory")
	resumed := fixture.work.runOnce(faults{}, inventoryOnly...)
	if resumed.code != 0 {
		t.Fatalf("exit %d: %s", resumed.code, resumed.output)
	}
	if runs := fixture.runs(t); !reflect.DeepEqual(runs, [][]string{{"int64:1", "string:cancelled"}, {"int64:2", "string:published"}}) {
		t.Fatalf("runs %v", runs)
	}
}

func TestSecondInstanceOfADomainIsRefusedAndOtherDomainsAreNot(t *testing.T) {
	fixture := newInventoryFixture(t, libraryOf("lib-a", "One"))
	first := fixture.work.command(faults{}, "run", "--workflows", "inventory", "--tick", "20ms")
	first.waitFor(named("owner"))
	duplicate := fixture.work.command(faults{}, "run", "--workflows", "inventory,downloads", "--once")
	if code := duplicate.wait(); code != 3 {
		t.Fatalf("duplicate exited %d: %s", code, duplicate.output())
	}
	refusal := duplicate.snapshot()
	if len(refusal) == 0 || refusal[len(refusal)-1].text("code") != "already-owned" {
		t.Fatalf("events %v", refusal)
	}
	if generation := scalar[int64](t, fixture.db, `SELECT generation FROM wf_owner WHERE domain = 'inventory'`); generation != 1 {
		t.Fatalf("the refused instance changed ownership: %d", generation)
	}
	other := fixture.work.command(faults{}, "run", "--workflows", "downloads", "--once")
	if code := other.wait(); code != 0 {
		t.Fatalf("a different domain was refused: %d %s", code, other.output())
	}
	if code := first.terminate(); code != 0 {
		t.Fatalf("shutdown exited %d: %s", code, first.output())
	}
	second := fixture.work.command(faults{}, "run", "--workflows", "inventory", "--once")
	if code := second.wait(); code != 0 {
		t.Fatalf("restart exited %d: %s", code, second.output())
	}
	if generation := scalar[int64](t, fixture.db, `SELECT generation FROM wf_owner WHERE domain = 'inventory'`); generation != 2 {
		t.Fatalf("generation %d", generation)
	}
}

func TestSupersededOwnerCannotPublish(t *testing.T) {
	fixture := newInventoryFixture(t, libraryOf("lib-a", "One", "Two"))
	fixture.seedLive(t)
	before := digests(t, fixture.db)
	injected := newFaults(t, map[string]string{"inventory.before-publish": "park"})
	run := fixture.work.command(injected, append([]string{"run", "--once"}, inventoryOnly...)...)
	injected.reached(t, "inventory.before-publish")
	exec1(t, fixture.db, `UPDATE wf_owner SET generation = generation + 1, owner_id = 'another-owner' WHERE domain = 'inventory'`)
	injected.release(t, "inventory.before-publish")
	if code := run.wait(); code != 4 {
		t.Fatalf("exit %d: %s", code, run.output())
	}
	requireSame(t, before, digests(t, fixture.db))
	if runs := fixture.runs(t); !reflect.DeepEqual(runs, [][]string{{"int64:1", "string:fetching"}}) {
		t.Fatalf("runs %v", runs)
	}
}

func TestCrashRecoveryAtEveryInventoryBoundary(t *testing.T) {
	type expectation struct {
		point           string
		stagedAtCrash   int64
		liveAtCrash     string
		refetchesLibA   bool
		finalRunsStates [][]string
	}
	cases := []expectation{
		{point: "inventory.admitted", stagedAtCrash: 0, liveAtCrash: "unchanged", refetchesLibA: true},
		{point: "inventory.library-fetched", stagedAtCrash: 0, liveAtCrash: "unchanged", refetchesLibA: true},
		{point: "inventory.library-staged", stagedAtCrash: 2, liveAtCrash: "unchanged", refetchesLibA: false},
		{point: "inventory.before-publish", stagedAtCrash: 3, liveAtCrash: "unchanged", refetchesLibA: false},
		{point: "inventory.publish-in-transaction", stagedAtCrash: 3, liveAtCrash: "unchanged", refetchesLibA: false},
		{point: "inventory.published", stagedAtCrash: 0, liveAtCrash: "published", refetchesLibA: false},
	}
	for _, entry := range cases {
		t.Run(entry.point, func(t *testing.T) {
			fixture := newInventoryFixture(t, libraryOf("lib-a", "One", "Two"), libraryOf("lib-b", "Uno"))
			fixture.seedLive(t)
			beforeLive := digests(t, fixture.db)
			injected := newFaults(t, map[string]string{entry.point: "park"})
			run := fixture.work.command(injected, append([]string{"run", "--once"}, inventoryOnly...)...)
			injected.reached(t, entry.point)
			if code := run.kill(); code == 0 {
				t.Fatal("the killed process reported success")
			}
			if integrity := scalar[string](t, fixture.db, `PRAGMA integrity_check`); integrity != "ok" {
				t.Fatalf("integrity %s", integrity)
			}
			if staged := scalar[int64](t, fixture.db, `SELECT COUNT(*) FROM wf_inventory_stage`); staged != entry.stagedAtCrash {
				t.Fatalf("staged rows at crash: %d, want %d", staged, entry.stagedAtCrash)
			}
			if entry.liveAtCrash == "unchanged" {
				requireSame(t, beforeLive, digests(t, fixture.db))
			}
			requestsAtCrash := fixture.peer.itemRequests("lib-a")
			recovery := fixture.work.runOnce(faults{}, inventoryOnly...)
			if recovery.code != 0 {
				t.Fatalf("recovery exited %d: %s", recovery.code, recovery.output)
			}
			if runs := fixture.runs(t); !reflect.DeepEqual(runs, [][]string{{"int64:1", "string:published"}}) {
				t.Fatalf("runs %v", runs)
			}
			refetched := fixture.peer.itemRequests("lib-a") > requestsAtCrash
			if refetched != entry.refetchesLibA {
				t.Fatalf("refetched=%v, want %v", refetched, entry.refetchesLibA)
			}
			got := rows(t, fixture.db, `SELECT library_id, audiobookshelf_id, title FROM library_items ORDER BY 1, 2`)
			want := [][]string{
				{"string:lib-a", "string:lib-a-one", "string:One"},
				{"string:lib-a", "string:lib-a-two", "string:Two"},
				{"string:lib-b", "string:lib-b-uno", "string:Uno"},
			}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("inventory %v", got)
			}
			if staged := scalar[int64](t, fixture.db, `SELECT COUNT(*) FROM wf_inventory_stage`); staged != 0 {
				t.Fatalf("stage rows left %d", staged)
			}
			digestAfter := digests(t, fixture.db)
			again := fixture.work.runOnce(faults{}, inventoryOnly...)
			if again.code != 0 || len(fixture.runs(t)) != 1 {
				t.Fatalf("a published run was repeated: %v", fixture.runs(t))
			}
			requireSame(t, digestAfter, digests(t, fixture.db))
		})
	}
}

func TestShutdownDuringAFetchLeavesTheRunToResume(t *testing.T) {
	fixture := newInventoryFixture(t, libraryOf("lib-a", "One", "Two"))
	fixture.seedLive(t)
	before := digests(t, fixture.db)
	reached := make(chan struct{}, 1)
	var blocking atomic.Bool
	blocking.Store(true)
	fixture.peer.setHook(func(id string, page int, w http.ResponseWriter, r *http.Request) bool {
		if !blocking.Load() {
			return false
		}
		reached <- struct{}{}
		<-r.Context().Done()
		return true
	})
	run := fixture.work.command(faults{}, append([]string{"run", "--tick", "20ms"}, inventoryOnly...)...)
	<-reached
	if code := run.terminate(); code != 0 {
		t.Fatalf("shutdown exited %d: %s", code, run.output())
	}
	requireSame(t, before, digests(t, fixture.db))
	if runs := fixture.runs(t); !reflect.DeepEqual(runs, [][]string{{"int64:1", "string:fetching"}}) {
		t.Fatalf("runs %v", runs)
	}
	blocking.Store(false)
	resumed := fixture.work.runOnce(faults{}, inventoryOnly...)
	if resumed.code != 0 {
		t.Fatalf("exit %d: %s", resumed.code, resumed.output)
	}
	if runs := fixture.runs(t); !reflect.DeepEqual(runs, [][]string{{"int64:1", "string:published"}}) {
		t.Fatalf("runs %v", runs)
	}
}

func TestSQLiteWriterContentionLeavesRecoverableState(t *testing.T) {
	fixture := newInventoryFixture(t, libraryOf("lib-a", "One", "Two"))
	fixture.seedLive(t)
	before := digests(t, fixture.db)
	injected := newFaults(t, map[string]string{"inventory.before-publish": "park"})
	run := fixture.work.command(injected, append([]string{"run", "--once", "--busy-timeout", "150ms"}, inventoryOnly...)...)
	injected.reached(t, "inventory.before-publish")
	holder := fixture.work.open()
	transaction, err := holder.Begin()
	if err != nil {
		t.Fatal(err)
	}
	injected.release(t, "inventory.before-publish")
	if code := run.wait(); code != 1 || !contains(run.errorCodes(), "db-busy") {
		t.Fatalf("exit %d codes %v: %s", run.wait(), run.errorCodes(), run.output())
	}
	transaction.Rollback()
	requireSame(t, before, digests(t, fixture.db))
	if runs := fixture.runs(t); !reflect.DeepEqual(runs, [][]string{{"int64:1", "string:fetching"}}) {
		t.Fatalf("runs %v", runs)
	}
	resumed := fixture.work.runOnce(faults{}, inventoryOnly...)
	if resumed.code != 0 {
		t.Fatalf("exit %d: %s", resumed.code, resumed.output)
	}
	if runs := fixture.runs(t); !reflect.DeepEqual(runs, [][]string{{"int64:1", "string:published"}}) {
		t.Fatalf("runs %v", runs)
	}
}

func TestSchedulingNeverCreatesASecondChain(t *testing.T) {
	fixture := newInventoryFixture(t, libraryOf("lib-a", "One"))
	first := fixture.work.runOnce(faults{}, inventoryOnly...)
	if first.code != 0 {
		t.Fatalf("exit %d", first.code)
	}
	for attempt := 0; attempt < 3; attempt++ {
		if again := fixture.work.runOnce(faults{}, inventoryOnly...); again.code != 0 {
			t.Fatalf("exit %d", again.code)
		}
	}
	if runs := fixture.runs(t); len(runs) != 1 {
		t.Fatalf("restarts admitted extra runs: %v", runs)
	}
	if _, err := fixture.db.Exec(`INSERT INTO wf_inventory_runs (generation, cancel_epoch, platform, scope_fingerprint, snapshot_at, state, admitted_at) VALUES (1, 0, 'audiobookshelf', 'x', 'x', 'fetching', 'x')`); err != nil {
		t.Fatalf("one active run is allowed: %v", err)
	}
	if _, err := fixture.db.Exec(`INSERT INTO wf_inventory_runs (generation, cancel_epoch, platform, scope_fingerprint, snapshot_at, state, admitted_at) VALUES (1, 0, 'audiobookshelf', 'y', 'y', 'fetching', 'y')`); err == nil {
		t.Fatal("two active runs were accepted")
	}
	exec1(t, fixture.db, `UPDATE wf_inventory_runs SET state = 'abandoned' WHERE scope_fingerprint = 'x'`)
	fixture.work.control("trigger", "inventory")
	fixture.work.control("trigger", "inventory")
	if again := fixture.work.runOnce(faults{}, inventoryOnly...); again.code != 0 {
		t.Fatalf("exit %d", again.code)
	}
	if runs := fixture.runs(t); len(runs) != 3 {
		t.Fatalf("two triggers must admit one run: %v", runs)
	}
}

func TestALibraryThatExceedsItsFetchDeadlineFailsWithoutPruning(t *testing.T) {
	fixture := newInventoryFixture(t, libraryOf("lib-a", "One", "Two", "Three"))
	fixture.seedLive(t)
	before := digests(t, fixture.db)
	fixture.peer.setHook(func(id string, page int, w http.ResponseWriter, r *http.Request) bool {
		if page == 1 {
			<-r.Context().Done()
			return true
		}
		return false
	})
	outcome := fixture.work.runOnce(faults{}, append(inventoryOnly, "--pass-deadline", "300ms", "--request-timeout", "30s")...)
	if outcome.code != 1 || !contains(outcome.codes, "deadline") {
		t.Fatalf("exit %d codes %v: %s", outcome.code, outcome.codes, outcome.output)
	}
	requireSame(t, before, digests(t, fixture.db))
	if state := rows(t, fixture.db, `SELECT state, error_code FROM wf_inventory_libraries`); !reflect.DeepEqual(state, [][]string{{"string:failed", "string:deadline"}}) {
		t.Fatalf("library %v", state)
	}
}

func TestCancellationSurvivesAResumeWhileTheOwnerIsDown(t *testing.T) {
	fixture := newInventoryFixture(t, libraryOf("lib-a", "One", "Two"))
	fixture.seedLive(t)
	before := digests(t, fixture.db)
	injected := newFaults(t, map[string]string{"inventory.before-publish": "park"})
	run := fixture.work.command(injected, append([]string{"run", "--once"}, inventoryOnly...)...)
	injected.reached(t, "inventory.before-publish")
	run.kill()
	if code := fixture.work.control("cancel", "inventory"); code != 0 {
		t.Fatalf("cancel exited %d", code)
	}
	if code := fixture.work.control("resume", "inventory"); code != 0 {
		t.Fatalf("resume exited %d", code)
	}
	restarted := fixture.work.runOnce(faults{}, inventoryOnly...)
	if restarted.code != 0 {
		t.Fatalf("exit %d: %s", restarted.code, restarted.output)
	}
	if runs := fixture.runs(t); !reflect.DeepEqual(runs, [][]string{{"int64:1", "string:cancelled"}}) {
		t.Fatalf("the cancelled run was revived: %v", runs)
	}
	requireSame(t, before, digests(t, fixture.db))
	next := fixture.work.runOnce(faults{}, inventoryOnly...)
	if next.code != 0 {
		t.Fatalf("exit %d: %s", next.code, next.output)
	}
	if runs := fixture.runs(t); !reflect.DeepEqual(runs, [][]string{{"int64:1", "string:cancelled"}, {"int64:2", "string:published"}}) {
		t.Fatalf("runs %v", runs)
	}
}

func TestCredentialChangesAbandonAStagedRun(t *testing.T) {
	for name, change := range map[string]map[string]string{
		"credential removed":  {"audiobookshelf_api_key": ""},
		"credential replaced": {"audiobookshelf_api_key": "another-synthetic-key"},
	} {
		t.Run(name, func(t *testing.T) {
			fixture := newInventoryFixture(t, libraryOf("lib-a", "One"))
			fixture.seedLive(t)
			before := digests(t, fixture.db, "settings")
			injected := newFaults(t, map[string]string{"inventory.before-publish": "park"})
			run := fixture.work.command(injected, append([]string{"run", "--once"}, inventoryOnly...)...)
			injected.reached(t, "inventory.before-publish")
			setSettings(t, fixture.db, change)
			injected.release(t, "inventory.before-publish")
			if code := run.wait(); code != 0 {
				t.Fatalf("exit %d: %s", code, run.output())
			}
			requireSame(t, before, digests(t, fixture.db, "settings"))
			if runs := fixture.runs(t); !reflect.DeepEqual(runs, [][]string{{"int64:1", "string:abandoned"}}) {
				t.Fatalf("runs %v", runs)
			}
		})
	}
}

func TestLibraryIdentifiersAreNeverEchoedInOutput(t *testing.T) {
	fixture := newInventoryFixture(t, libraryOf(absKey, "One"))
	outcome := fixture.work.runOnce(faults{}, inventoryOnly...)
	if outcome.code != 0 {
		t.Fatalf("exit %d: %s", outcome.code, outcome.output)
	}
	assertNoSecrets(t, outcome.output)
	if count := scalar[int64](t, fixture.db, `SELECT COUNT(*) FROM library_items WHERE library_id = ?`, absKey); count != 1 {
		t.Fatalf("inventory %d", count)
	}
}

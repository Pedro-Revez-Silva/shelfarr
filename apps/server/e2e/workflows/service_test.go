//go:build e2e

package workflows

import (
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestAFailingWorkflowNeverStopsTheOthersAndRecoversWithoutARestart(t *testing.T) {
	work := prepare(t, currentBundle)
	db := work.open()
	abs := newABS(t, libraryOf("lib-a", "One", "Two"))
	work.configureABS(db, abs, "lib-a")
	abs.setHook(func(id string, page int, w http.ResponseWriter, r *http.Request) bool {
		w.WriteHeader(500)
		w.Write([]byte("SECRET-CANARY-abs"))
		return true
	})
	peer := newQBit(t)
	client := work.seedClient(db, peer.URL, qbitPassword, true)
	seed := work.seedDownload(db, client, hashOf(40))
	peer.set(seed.Hash, torrentState{Name: "Book", Progress: 1, State: "uploading", Size: 1, Content: "/d/Book"})
	sink := newConsumer(t)

	run := work.command(faults{}, "run", "--tick", "20ms", "--page-size", "2", "--handoff-url", sink.URL, "--handoff-backoff", "0s", "--request-timeout", "1s")
	run.waitFor(func(e event) bool { return e.name() == "error" && e.text("code") == "all-libraries-failed" })
	run.waitFor(named("downloads.completed"))
	run.waitFor(func(e event) bool { return e.name() == "downloads.handoff" && e.text("outcome") == "delivered" })
	if effects := sink.localEffects(); len(effects) != 1 {
		t.Fatalf("effects %v", effects)
	}
	abs.setHook(nil)
	if code := work.control("trigger", "inventory"); code != 0 {
		t.Fatalf("trigger exited %d", code)
	}
	run.waitFor(func(e event) bool { return e.name() == "inventory.finished" && e.text("outcome") == "published" })
	if count := scalar[int64](t, db, `SELECT COUNT(*) FROM library_items WHERE library_id = 'lib-a'`); count != 2 {
		t.Fatalf("inventory %d", count)
	}
	if runs := rows(t, db, `SELECT state FROM wf_inventory_runs ORDER BY id`); !reflect.DeepEqual(runs, [][]string{{"string:abandoned"}, {"string:published"}}) {
		t.Fatalf("runs %v", runs)
	}
	if code := run.terminate(); code != 0 {
		t.Fatalf("shutdown exited %d: %s", code, run.output())
	}
	if last := run.snapshot(); last[len(last)-1].text("outcome") != "clean" {
		t.Fatalf("last event %v", last[len(last)-1])
	}
	if strings.Contains(run.output(), "SECRET-CANARY") {
		t.Fatal("fixture-controlled response text reached the output")
	}
}

func TestAPanicInOneObservationIsContainedAndReported(t *testing.T) {
	work := prepare(t, currentBundle)
	db := work.open()
	abs := newABS(t, libraryOf("lib-a", "One"))
	work.configureABS(db, abs, "lib-a")
	peer := newQBit(t)
	client := work.seedClient(db, peer.URL, qbitPassword, true)
	seed := work.seedDownload(db, client, hashOf(41))
	peer.set(seed.Hash, torrentState{Name: "Book", Progress: 0.5, State: "downloading", Size: 1})
	injected := newFaults(t, map[string]string{"monitor.observed": "panic"})
	run := work.command(injected, "run", "--tick", "20ms", "--page-size", "2")
	run.waitFor(named("downloads.panic"))
	run.waitFor(func(e event) bool { return e.name() == "inventory.finished" && e.text("outcome") == "published" })
	if code := run.terminate(); code != 0 {
		t.Fatalf("shutdown exited %d: %s", code, run.output())
	}
	if status := scalar[int64](t, db, `SELECT status FROM downloads WHERE id = ?`, seed.Download); status != 1 {
		t.Fatalf("download status %d", status)
	}
}

func TestShutdownIsBoundedWhileEveryPeerHangs(t *testing.T) {
	work := prepare(t, currentBundle)
	db := work.open()
	abs := newABS(t, libraryOf("lib-a", "One"))
	work.configureABS(db, abs, "lib-a")
	peer := newQBit(t)
	client := work.seedClient(db, peer.URL, qbitPassword, true)
	completed := work.seedDownload(db, client, hashOf(42))
	peer.set(completed.Hash, torrentState{Name: "Book", Progress: 1, State: "uploading", Size: 1})
	sink := newConsumer(t)
	hanging := make(chan string, 8)
	abs.setHook(func(id string, page int, w http.ResponseWriter, r *http.Request) bool {
		hanging <- "abs"
		<-r.Context().Done()
		return true
	})
	peer.setHook(func(hash string, w http.ResponseWriter, r *http.Request) bool {
		hanging <- "qbit"
		<-r.Context().Done()
		return true
	})
	run := work.command(faults{}, "run", "--tick", "20ms", "--shutdown-grace", "5s", "--handoff-url", sink.URL)
	seen := map[string]bool{}
	for len(seen) < 2 {
		seen[<-hanging] = true
	}
	started := time.Now()
	if code := run.terminate(); code != 0 {
		t.Fatalf("shutdown exited %d: %s", code, run.output())
	}
	if elapsed := time.Since(started); elapsed > 5*time.Second {
		t.Fatalf("shutdown took %s", elapsed)
	}
	if runs := rows(t, db, `SELECT state FROM wf_inventory_runs`); !reflect.DeepEqual(runs, [][]string{{"string:fetching"}}) {
		t.Fatalf("the interrupted run was lost: %v", runs)
	}
}

func TestShutdownWithPendingHandoffsRestartsAndDeliversThem(t *testing.T) {
	work := prepare(t, currentBundle)
	db := work.open()
	peer := newQBit(t)
	client := work.seedClient(db, peer.URL, qbitPassword, true)
	seed := work.seedDownload(db, client, hashOf(43))
	peer.set(seed.Hash, torrentState{Name: "Book", Progress: 1, State: "uploading", Size: 1, Content: "/d/Book"})
	sink := newConsumer(t)
	sink.setStatus(503)
	run := work.command(faults{}, "run", "--workflows", "downloads", "--tick", "20ms", "--handoff-url", sink.URL, "--handoff-backoff", "0s")
	run.waitFor(func(e event) bool { return e.name() == "downloads.handoff" && e.text("outcome") == "failed" })
	if code := run.terminate(); code != 0 {
		t.Fatalf("shutdown exited %d: %s", code, run.output())
	}
	if state := scalar[string](t, db, `SELECT state FROM wf_postprocess_handoffs`); state != "pending" {
		t.Fatalf("handoff %s", state)
	}
	sink.setStatus(200)
	restarted := work.runOnce(faults{}, "--workflows", "downloads", "--handoff-url", sink.URL, "--handoff-backoff", "0s")
	if restarted.code != 0 {
		t.Fatalf("exit %d: %s", restarted.code, restarted.output)
	}
	if got := sink.localEffects(); len(got) != 1 {
		t.Fatalf("effects %v", got)
	}
	if state := scalar[string](t, db, `SELECT state FROM wf_postprocess_handoffs`); state != "delivered" {
		t.Fatalf("handoff %s", state)
	}
}

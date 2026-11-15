//go:build e2e

package workflows

import (
	"database/sql"
	"fmt"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"
)

var downloadsOnly = []string{"--workflows", "downloads"}

type downloadFixture struct {
	work     *workdir
	db       *sql.DB
	peer     *qbitPeer
	consumer *consumer
	client   int64
}

func newDownloadFixture(t *testing.T, bundle string) downloadFixture {
	t.Helper()
	work := prepare(t, bundle)
	db := work.open()
	peer := newQBit(t)
	return downloadFixture{work: work, db: db, peer: peer, consumer: newConsumer(t), client: work.seedClient(db, peer.URL, qbitPassword, true)}
}

func (f downloadFixture) cycle(t *testing.T, options ...string) result {
	t.Helper()
	f.work.control("trigger", "downloads")
	return f.work.runOnce(faults{}, append(append([]string{}, downloadsOnly...), options...)...)
}

func (f downloadFixture) download(t *testing.T, id int64) map[string]string {
	t.Helper()
	cursor, err := f.db.Query(`SELECT * FROM downloads WHERE id = ?`, id)
	if err != nil {
		t.Fatal(err)
	}
	defer cursor.Close()
	columns, _ := cursor.Columns()
	if !cursor.Next() {
		t.Fatalf("download %d missing", id)
	}
	values := make([]any, len(columns))
	pointers := make([]any, len(columns))
	for index := range values {
		pointers[index] = &values[index]
	}
	if err := cursor.Scan(pointers...); err != nil {
		t.Fatal(err)
	}
	row := map[string]string{}
	for index, name := range columns {
		row[name] = "NULL"
		if values[index] != nil {
			row[name] = toText(values[index])
		}
	}
	return row
}

func toText(value any) string {
	switch typed := value.(type) {
	case []byte:
		return string(typed)
	case string:
		return typed
	}
	return fmt.Sprint(value)
}

func (f downloadFixture) counts(t *testing.T) (events, handoffs int64) {
	t.Helper()
	return scalar[int64](t, f.db, `SELECT COUNT(*) FROM request_events`), scalar[int64](t, f.db, `SELECT COUNT(*) FROM wf_postprocess_handoffs`)
}

func differences(before, after map[string]string) map[string]string {
	changed := map[string]string{}
	for key, value := range after {
		if before[key] != value {
			changed[key] = value
		}
	}
	return changed
}

func TestProgressIsPersistedTruthfullyAndOnlyWhenItChanges(t *testing.T) {
	for name, bundle := range map[string]string{"current schema": currentBundle, "upgraded released schema": upgradeBundle} {
		t.Run(name, func(t *testing.T) {
			fixture := newDownloadFixture(t, bundle)
			seed := fixture.work.seedDownload(fixture.db, fixture.client, hashOf(1))
			fixture.peer.set(seed.Hash, torrentState{Name: "Book", Progress: 0.4249, State: "downloading", Size: 1 << 20, Content: "/d/Book", Save: "/d"})
			untouched := digests(t, fixture.db, "downloads")
			released := rows(t, fixture.db, `SELECT * FROM downloads WHERE id <> ? ORDER BY id`, seed.Download)
			before := fixture.download(t, seed.Download)
			baseEvents, baseHandoffs := fixture.counts(t)
			outcome := fixture.cycle(t)
			if outcome.code != 0 {
				t.Fatalf("exit %d: %s", outcome.code, outcome.output)
			}
			after := fixture.download(t, seed.Download)
			changed := differences(before, after)
			if changed["progress"] != "42" || len(changed) != 2 || changed["updated_at"] == "" {
				t.Fatalf("changed columns %v", changed)
			}
			requireSame(t, untouched, digests(t, fixture.db, "downloads"))
			if !reflect.DeepEqual(released, rows(t, fixture.db, `SELECT * FROM downloads WHERE id <> ? ORDER BY id`, seed.Download)) {
				t.Fatal("rows of other downloads changed")
			}
			if events, handoffs := fixture.counts(t); events != baseEvents || handoffs != baseHandoffs {
				t.Fatalf("progress produced completion effects: %d %d", events, handoffs)
			}
			fixture.cycle(t)
			if same := fixture.download(t, seed.Download); !reflect.DeepEqual(after, same) {
				t.Fatalf("an unchanged observation was written: %v", differences(after, same))
			}
			fixture.peer.set(seed.Hash, torrentState{Name: "Book", Progress: 0.9, State: "downloading", Size: 1 << 20})
			fixture.cycle(t)
			if progress := fixture.download(t, seed.Download)["progress"]; progress != "90" {
				t.Fatalf("progress %s", progress)
			}
			assertNoSecrets(t, outcome.output)
		})
	}
}

func TestCompletionIsAtomicAndDoesNotAdvanceTheRequest(t *testing.T) {
	fixture := newDownloadFixture(t, currentBundle)
	seed := fixture.work.seedDownload(fixture.db, fixture.client, hashOf(2))
	fixture.peer.set(seed.Hash, torrentState{Name: "Book", Progress: 1, State: "stalledUP", Size: 1 << 20, Content: "/d/Book", Save: "/d"})
	untouched := digests(t, fixture.db, "downloads", "request_events")
	outcome := fixture.cycle(t)
	if outcome.code != 0 {
		t.Fatalf("exit %d: %s", outcome.code, outcome.output)
	}
	row := fixture.download(t, seed.Download)
	if row["status"] != "3" || row["progress"] != "100" || row["download_path"] != "/d/Book" || row["external_id"] != seed.Hash {
		t.Fatalf("download %v", row)
	}
	event := rows(t, fixture.db, `SELECT request_id, download_id, event_type, source, message, level, details, user_visible FROM request_events`)
	wantEvent := [][]string{{"int64:" + itoa(seed.Request), "int64:" + itoa(seed.Download), "string:completed", "string:GoDownloadMonitor", "string:Download completed in client", "int64:0", `string:{"download_path":"/d/Book"}`, "int64:0"}}
	if !reflect.DeepEqual(event, wantEvent) {
		t.Fatalf("events %v", event)
	}
	handoff := rows(t, fixture.db, `SELECT download_id, request_id, idempotency_key, download_path, state, attempts FROM wf_postprocess_handoffs`)
	wantHandoff := [][]string{{"int64:" + itoa(seed.Download), "int64:" + itoa(seed.Request), "string:shelfarr-download-completed-" + itoa(seed.Download), "string:/d/Book", "string:pending", "int64:0"}}
	if !reflect.DeepEqual(handoff, wantHandoff) {
		t.Fatalf("handoff %v", handoff)
	}
	if status := scalar[int64](t, fixture.db, `SELECT status FROM requests WHERE id = ?`, seed.Request); status != 3 {
		t.Fatalf("the request was advanced to %d", status)
	}
	requireSame(t, untouched, digests(t, fixture.db, "downloads", "request_events"))
	fixture.cycle(t)
	fixture.cycle(t)
	if events, handoffs := fixture.counts(t); events != 1 || handoffs != 1 {
		t.Fatalf("repeated cycles duplicated effects: %d %d", events, handoffs)
	}
}

func TestCrashAroundCompletionNeverLosesOrDuplicatesIt(t *testing.T) {
	for _, point := range []string{"monitor.completion-claimed", "monitor.completion-before-commit", "monitor.completion-committed"} {
		t.Run(point, func(t *testing.T) {
			fixture := newDownloadFixture(t, currentBundle)
			seed := fixture.work.seedDownload(fixture.db, fixture.client, hashOf(3))
			fixture.peer.set(seed.Hash, torrentState{Name: "Book", Progress: 1, State: "uploading", Size: 1 << 20, Content: "/d/Book"})
			beforeRow := fixture.download(t, seed.Download)
			injected := newFaults(t, map[string]string{point: "park"})
			fixture.work.control("trigger", "downloads")
			run := fixture.work.command(injected, append([]string{"run", "--once"}, downloadsOnly...)...)
			injected.reached(t, point)
			run.kill()
			events, handoffs := fixture.counts(t)
			committed := point == "monitor.completion-committed"
			if committed {
				if fixture.download(t, seed.Download)["status"] != "3" || events != 1 || handoffs != 1 {
					t.Fatalf("committed completion not durable: %d %d", events, handoffs)
				}
			} else if !reflect.DeepEqual(fixture.download(t, seed.Download), beforeRow) || events != 0 || handoffs != 0 {
				t.Fatalf("a partial completion survived the crash: %d %d %v", events, handoffs, differences(beforeRow, fixture.download(t, seed.Download)))
			}
			recovery := fixture.work.runOnce(faults{}, append([]string{"--handoff-url", fixture.consumer.URL}, downloadsOnly...)...)
			if recovery.code != 0 {
				t.Fatalf("recovery exited %d: %s", recovery.code, recovery.output)
			}
			if !committed {
				fixture.work.control("trigger", "downloads")
				fixture.work.runOnce(faults{}, append([]string{"--handoff-url", fixture.consumer.URL}, downloadsOnly...)...)
			}
			if events, handoffs := fixture.counts(t); events != 1 || handoffs != 1 {
				t.Fatalf("effects after recovery: %d %d", events, handoffs)
			}
			if status := fixture.download(t, seed.Download)["status"]; status != "3" {
				t.Fatalf("status %s", status)
			}
			if got := fixture.consumer.localEffects(); len(got) != 1 {
				t.Fatalf("consumer effects %v", got)
			}
			if state := scalar[string](t, fixture.db, `SELECT state FROM wf_postprocess_handoffs`); state != "delivered" {
				t.Fatalf("handoff %s", state)
			}
		})
	}
}

func TestHandoffRedeliveryIsAtLeastOnceWithAnIdempotentLocalEffect(t *testing.T) {
	fixture := newDownloadFixture(t, currentBundle)
	seed := fixture.work.seedDownload(fixture.db, fixture.client, hashOf(4))
	fixture.peer.set(seed.Hash, torrentState{Name: "Book", Progress: 1, State: "uploading", Size: 1, Content: "/d/Book"})
	if outcome := fixture.cycle(t); outcome.code != 0 {
		t.Fatalf("exit %d", outcome.code)
	}
	injected := newFaults(t, map[string]string{"handoff.consumer-replied": "park"})
	run := fixture.work.command(injected, append([]string{"run", "--once", "--handoff-url", fixture.consumer.URL}, downloadsOnly...)...)
	injected.reached(t, "handoff.consumer-replied")
	run.kill()
	if state := scalar[string](t, fixture.db, `SELECT state FROM wf_postprocess_handoffs`); state != "pending" {
		t.Fatalf("handoff %s after the kill", state)
	}
	key := "shelfarr-download-completed-" + itoa(seed.Download)
	if got := fixture.consumer.deliveries(); !reflect.DeepEqual(got, []string{key}) {
		t.Fatalf("deliveries %v", got)
	}
	retry := fixture.work.runOnce(faults{}, append([]string{"--handoff-url", fixture.consumer.URL}, downloadsOnly...)...)
	if retry.code != 0 {
		t.Fatalf("exit %d: %s", retry.code, retry.output)
	}
	if got := fixture.consumer.deliveries(); !reflect.DeepEqual(got, []string{key, key}) {
		t.Fatalf("deliveries %v", got)
	}
	if got := fixture.consumer.localEffects(); !reflect.DeepEqual(got, map[string]int{key: 1}) {
		t.Fatalf("local effects %v", got)
	}
	fixture.work.runOnce(faults{}, append([]string{"--handoff-url", fixture.consumer.URL}, downloadsOnly...)...)
	if got := fixture.consumer.deliveries(); len(got) != 2 {
		t.Fatalf("a delivered handoff was sent again: %v", got)
	}
	if events, handoffs := fixture.counts(t); events != 1 || handoffs != 1 {
		t.Fatalf("effects %d %d", events, handoffs)
	}
}

func TestFailedHandoffStaysPendingWithItsReasonAndRetries(t *testing.T) {
	fixture := newDownloadFixture(t, currentBundle)
	seed := fixture.work.seedDownload(fixture.db, fixture.client, hashOf(5))
	fixture.peer.set(seed.Hash, torrentState{Name: "Book", Progress: 1, State: "uploading", Size: 1, Content: "/d/Book"})
	fixture.cycle(t)
	fixture.consumer.setStatus(500)
	failed := fixture.work.runOnce(faults{}, append([]string{"--handoff-url", fixture.consumer.URL, "--handoff-backoff", "0s"}, downloadsOnly...)...)
	if failed.code != 1 || !contains(failed.codes, "delivery-failed") {
		t.Fatalf("exit %d codes %v", failed.code, failed.codes)
	}
	state := rows(t, fixture.db, `SELECT state, attempts, last_error_code FROM wf_postprocess_handoffs`)
	if !reflect.DeepEqual(state, [][]string{{"string:pending", "int64:1", "string:http-status"}}) {
		t.Fatalf("handoff %v", state)
	}
	fixture.consumer.setStatus(200)
	retried := fixture.work.runOnce(faults{}, append([]string{"--handoff-url", fixture.consumer.URL, "--handoff-backoff", "0s"}, downloadsOnly...)...)
	if retried.code != 0 {
		t.Fatalf("exit %d: %s", retried.code, retried.output)
	}
	state = rows(t, fixture.db, `SELECT state, attempts, last_error_code FROM wf_postprocess_handoffs`)
	if !reflect.DeepEqual(state, [][]string{{"string:delivered", "int64:2", "NULL"}}) {
		t.Fatalf("handoff %v", state)
	}
}

func TestHangingHandoffConsumerIsBoundedAndKeepsTheHandoffPending(t *testing.T) {
	fixture := newDownloadFixture(t, currentBundle)
	seed := fixture.work.seedDownload(fixture.db, fixture.client, hashOf(6))
	fixture.peer.set(seed.Hash, torrentState{Name: "Book", Progress: 1, State: "uploading", Size: 1})
	fixture.cycle(t)
	release := make(chan struct{})
	defer close(release)
	fixture.consumer.setHook(func(key string, w http.ResponseWriter, r *http.Request) bool {
		select {
		case <-release:
		case <-r.Context().Done():
		}
		return true
	})
	outcome := fixture.work.runOnce(faults{}, append([]string{"--handoff-url", fixture.consumer.URL, "--handoff-backoff", "0s", "--request-timeout", "200ms"}, downloadsOnly...)...)
	if outcome.code != 1 {
		t.Fatalf("exit %d: %s", outcome.code, outcome.output)
	}
	state := rows(t, fixture.db, `SELECT state, last_error_code FROM wf_postprocess_handoffs`)
	if !reflect.DeepEqual(state, [][]string{{"string:pending", "string:connection"}}) {
		t.Fatalf("handoff %v", state)
	}
}

func TestOldObservationsCannotActOnACancelledOrReplacedAttempt(t *testing.T) {
	cases := map[string]func(t *testing.T, f downloadFixture, seed seeded){
		"request cancelled": func(t *testing.T, f downloadFixture, seed seeded) {
			exec1(t, f.db, `UPDATE downloads SET status = 4 WHERE id = ?`, seed.Download)
			exec1(t, f.db, `UPDATE requests SET status = 6 WHERE id = ?`, seed.Request)
		},
		"release replaced": func(t *testing.T, f downloadFixture, seed seeded) {
			exec1(t, f.db, `UPDATE search_results SET status = 2 WHERE id = ?`, seed.Result)
		},
		"re-dispatched under a new torrent": func(t *testing.T, f downloadFixture, seed seeded) {
			exec1(t, f.db, `UPDATE downloads SET external_id = ? WHERE id = ?`, hashOf(99), seed.Download)
		},
		"moved to another client": func(t *testing.T, f downloadFixture, seed seeded) {
			other := f.work.seedClient(f.db, f.peer.URL, qbitPassword, true)
			exec1(t, f.db, `UPDATE downloads SET download_client_id = ? WHERE id = ?`, itoa(other), seed.Download)
		},
	}
	for name, change := range cases {
		t.Run(name, func(t *testing.T) {
			fixture := newDownloadFixture(t, currentBundle)
			seed := fixture.work.seedDownload(fixture.db, fixture.client, hashOf(7))
			fixture.peer.set(seed.Hash, torrentState{Name: "Book", Progress: 1, State: "uploading", Size: 1, Content: "/d/Book"})
			reached := make(chan struct{}, 1)
			release := make(chan struct{})
			fixture.peer.setHook(func(hash string, w http.ResponseWriter, r *http.Request) bool {
				if hash == seed.Hash {
					reached <- struct{}{}
					<-release
				}
				return false
			})
			fixture.work.control("trigger", "downloads")
			run := fixture.work.command(faults{}, append([]string{"run", "--once"}, downloadsOnly...)...)
			<-reached
			change(t, fixture, seed)
			afterChange := fixture.download(t, seed.Download)
			requestStatus := scalar[int64](t, fixture.db, `SELECT status FROM requests WHERE id = ?`, seed.Request)
			close(release)
			if code := run.wait(); code != 0 {
				t.Fatalf("exit %d: %s", code, run.output())
			}
			if !reflect.DeepEqual(afterChange, fixture.download(t, seed.Download)) {
				t.Fatalf("the old observation changed the newer attempt: %v", differences(afterChange, fixture.download(t, seed.Download)))
			}
			if events, handoffs := fixture.counts(t); events != 0 || handoffs != 0 {
				t.Fatalf("effects for a stale attempt: %d %d", events, handoffs)
			}
			if status := scalar[int64](t, fixture.db, `SELECT status FROM requests WHERE id = ?`, seed.Request); status != requestStatus {
				t.Fatalf("request status changed")
			}
			stale := false
			for _, e := range run.snapshot() {
				if e.name() == "downloads.cycle" && e.number("stale") == 1 {
					stale = true
				}
			}
			if !stale {
				t.Fatalf("the discarded observation was not reported: %s", run.output())
			}
		})
	}
}

func TestOnlyAnEmptyAnswerCountsAsNotFoundAndFailureHandlingIsNotPorted(t *testing.T) {
	fixture := newDownloadFixture(t, currentBundle)
	seed := fixture.work.seedDownload(fixture.db, fixture.client, hashOf(8))
	requestBefore := rows(t, fixture.db, `SELECT * FROM requests WHERE id = ?`, seed.Request)
	for expected := 1; expected <= 3; expected++ {
		if outcome := fixture.cycle(t); outcome.code != 0 {
			t.Fatalf("cycle %d exit %d: %s", expected, outcome.code, outcome.output)
		}
		if count := fixture.download(t, seed.Download)["not_found_count"]; count != itoa(int64(expected)) {
			t.Fatalf("cycle %d: count %s", expected, count)
		}
	}
	state := rows(t, fixture.db, `SELECT blocked_code FROM wf_download_state WHERE download_id = ?`, seed.Download)
	if !reflect.DeepEqual(state, [][]string{{"string:not-found-threshold"}}) {
		t.Fatalf("state %v", state)
	}
	fixture.cycle(t)
	row := fixture.download(t, seed.Download)
	if row["status"] != "1" || row["not_found_count"] != "3" {
		t.Fatalf("download %v", row)
	}
	if !reflect.DeepEqual(requestBefore, rows(t, fixture.db, `SELECT * FROM requests WHERE id = ?`, seed.Request)) {
		t.Fatal("the request was changed by a failure path that is not ported")
	}
	if events, handoffs := fixture.counts(t); events != 0 || handoffs != 0 {
		t.Fatalf("effects %d %d", events, handoffs)
	}
	fixture.peer.set(seed.Hash, torrentState{Name: "Book", Progress: 0.5, State: "downloading", Size: 1})
	fixture.cycle(t)
	if row := fixture.download(t, seed.Download); row["not_found_count"] != "0" || row["progress"] != "50" {
		t.Fatalf("the reappeared torrent was not recorded: %v", row)
	}
	if blocked := scalar[sql.NullString](t, fixture.db, `SELECT blocked_code FROM wf_download_state WHERE download_id = ?`, seed.Download); blocked.Valid {
		t.Fatalf("the block was not cleared: %v", blocked)
	}
}

func TestClientErrorsAreNeverTreatedAsNotFound(t *testing.T) {
	cases := map[string]struct {
		respond func(w http.ResponseWriter, hash string)
		code    string
	}{
		"not found status": {func(w http.ResponseWriter, hash string) { w.WriteHeader(404) }, "http-status-404"},
		"server error":     {func(w http.ResponseWriter, hash string) { w.WriteHeader(500) }, "http-status-500"},
		"garbage":          {func(w http.ResponseWriter, hash string) { w.Write([]byte("<html>")) }, "malformed"},
		"a different torrent": {func(w http.ResponseWriter, hash string) {
			w.Write([]byte(`[{"hash":"` + hashOf(500) + `","name":"x","progress":1,"state":"uploading","size":1}]`))
		}, "malformed"},
		"progress out of range": {func(w http.ResponseWriter, hash string) {
			w.Write([]byte(`[{"hash":"` + hash + `","name":"x","progress":7,"state":"downloading","size":1}]`))
		}, "malformed"},
	}
	for name, entry := range cases {
		t.Run(name, func(t *testing.T) {
			fixture := newDownloadFixture(t, currentBundle)
			seed := fixture.work.seedDownload(fixture.db, fixture.client, hashOf(9))
			fixture.peer.setHook(func(hash string, w http.ResponseWriter, r *http.Request) bool {
				entry.respond(w, hash)
				return true
			})
			before := fixture.download(t, seed.Download)
			outcome := fixture.cycle(t)
			if outcome.code != 1 || !contains(outcome.codes, "observation-errors") {
				t.Fatalf("exit %d codes %v", outcome.code, outcome.codes)
			}
			if !reflect.DeepEqual(before, fixture.download(t, seed.Download)) {
				t.Fatalf("a client error changed the download: %v", differences(before, fixture.download(t, seed.Download)))
			}
			state := rows(t, fixture.db, `SELECT error_code, blocked_code FROM wf_download_state WHERE download_id = ?`, seed.Download)
			if !reflect.DeepEqual(state, [][]string{{"string:" + entry.code, "NULL"}}) {
				t.Fatalf("state %v", state)
			}
		})
	}
}

func TestClientReportedFailureIsRecordedAsBlockedWithoutFailingTheRequest(t *testing.T) {
	fixture := newDownloadFixture(t, currentBundle)
	seed := fixture.work.seedDownload(fixture.db, fixture.client, hashOf(10))
	fixture.peer.set(seed.Hash, torrentState{Name: "Book", Progress: 0.3, State: "missingFiles", Size: 1})
	requestBefore := rows(t, fixture.db, `SELECT * FROM requests WHERE id = ?`, seed.Request)
	if outcome := fixture.cycle(t); outcome.code != 0 {
		t.Fatalf("exit %d: %s", outcome.code, outcome.output)
	}
	row := fixture.download(t, seed.Download)
	if row["status"] != "1" || row["progress"] != "30" {
		t.Fatalf("download %v", row)
	}
	state := rows(t, fixture.db, `SELECT blocked_code FROM wf_download_state`)
	if !reflect.DeepEqual(state, [][]string{{"string:client-reported-failure"}}) {
		t.Fatalf("state %v", state)
	}
	if !reflect.DeepEqual(requestBefore, rows(t, fixture.db, `SELECT * FROM requests WHERE id = ?`, seed.Request)) {
		t.Fatal("request changed")
	}
}

func TestUnsupportedDownloadsAreBlockedNotChanged(t *testing.T) {
	fixture := newDownloadFixture(t, currentBundle)
	usenet := scalar[int64](t, fixture.db, `SELECT id FROM download_clients WHERE client_type = 'sabnzbd'`)
	disabled := fixture.work.seedClient(fixture.db, fixture.peer.URL, qbitPassword, false)
	usenetDownload := fixture.work.seedDownload(fixture.db, usenet, hashOf(11))
	disabledDownload := fixture.work.seedDownload(fixture.db, disabled, hashOf(12))
	direct := fixture.work.seedDownload(fixture.db, fixture.client, hashOf(13))
	exec1(t, fixture.db, `UPDATE downloads SET download_type = 'direct' WHERE id = ?`, direct.Download)
	undispatched := fixture.work.seedDownload(fixture.db, fixture.client, hashOf(14))
	exec1(t, fixture.db, `UPDATE downloads SET external_id = NULL, status = 0 WHERE id = ?`, undispatched.Download)
	before := digests(t, fixture.db, "wf_none")
	outcome := fixture.cycle(t)
	if outcome.code != 0 {
		t.Fatalf("exit %d: %s", outcome.code, outcome.output)
	}
	requireSame(t, before, digests(t, fixture.db, "wf_none"))
	state := rows(t, fixture.db, `SELECT download_id, blocked_code FROM wf_download_state ORDER BY download_id`)
	want := [][]string{
		{"int64:" + itoa(usenetDownload.Download), "string:client-unsupported"},
		{"int64:" + itoa(direct.Download), "string:direct-download-unsupported"},
		{"int64:" + itoa(undispatched.Download), "string:not-dispatched"},
	}
	if !reflect.DeepEqual(state, want) {
		t.Fatalf("state %v (disabled client download %d must be ignored)", state, disabledDownload.Download)
	}
}

func TestStoredCredentialsAreDecryptedAndNeverPrinted(t *testing.T) {
	fixture := newDownloadFixture(t, currentBundle)
	seed := fixture.work.seedDownload(fixture.db, fixture.client, hashOf(15))
	fixture.peer.set(seed.Hash, torrentState{Name: "Book", Progress: 0.2, State: "downloading", Size: 1})
	wrongClient := fixture.work.seedClient(fixture.db, fixture.peer.URL, "a-different-secret-7731", true)
	wrong := fixture.work.seedDownload(fixture.db, wrongClient, hashOf(16))
	brokenClient := fixture.work.seedClient(fixture.db, fixture.peer.URL, qbitPassword, true)
	exec1(t, fixture.db, `UPDATE download_clients SET password = '{"p":"AAAA","h":{"iv":"AAAAAAAAAAAAAAAA","at":"AAAAAAAAAAAAAAAAAAAAAA=="}}' WHERE id = ?`, brokenClient)
	broken := fixture.work.seedDownload(fixture.db, brokenClient, hashOf(17))
	outcome := fixture.cycle(t)
	if outcome.code != 1 {
		t.Fatalf("exit %d", outcome.code)
	}
	if progress := fixture.download(t, seed.Download)["progress"]; progress != "20" {
		t.Fatalf("the correct client was not used: %s", progress)
	}
	state := rows(t, fixture.db, `SELECT download_id, error_code FROM wf_download_state WHERE error_code IS NOT NULL ORDER BY download_id`)
	want := [][]string{{"int64:" + itoa(wrong.Download), "string:auth"}, {"int64:" + itoa(broken.Download), "string:credential-decrypt"}}
	if !reflect.DeepEqual(state, want) {
		t.Fatalf("state %v", state)
	}
	assertNoSecrets(t, outcome.output)
	for _, secret := range []string{"a-different-secret-7731", "synthetic-session"} {
		if strings.Contains(outcome.output, secret) {
			t.Fatalf("output leaked a credential")
		}
	}
}

func TestOnlyTheConfiguredNumberOfObservationsRunAtOnce(t *testing.T) {
	fixture := newDownloadFixture(t, currentBundle)
	for index := 0; index < 6; index++ {
		seed := fixture.work.seedDownload(fixture.db, fixture.client, hashOf(20+index))
		fixture.peer.set(seed.Hash, torrentState{Name: "Book", Progress: 0.1, State: "downloading", Size: 1})
	}
	release := make(chan struct{})
	fixture.peer.setHook(func(hash string, w http.ResponseWriter, r *http.Request) bool {
		select {
		case <-release:
		case <-r.Context().Done():
		}
		return false
	})
	fixture.work.control("trigger", "downloads")
	run := fixture.work.command(faults{}, append([]string{"run", "--once", "--concurrency", "2"}, downloadsOnly...)...)
	deadline := time.Now().Add(waitLimit)
	for {
		if fixture.peer.running() == 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("two observations never ran together")
		}
		time.Sleep(time.Millisecond)
	}
	time.Sleep(400 * time.Millisecond)
	close(release)
	if code := run.wait(); code != 0 {
		t.Fatalf("exit %d: %s", code, run.output())
	}
	if fixture.peer.peak() != 2 {
		t.Fatalf("observed %d concurrent requests, want exactly the limit of 2", fixture.peer.peak())
	}
	if progressed := scalar[int64](t, fixture.db, `SELECT COUNT(*) FROM downloads WHERE progress = 10`); progressed != 6 {
		t.Fatalf("progressed %d", progressed)
	}
}

func TestAHungClientDelaysOnlyItsOwnObservation(t *testing.T) {
	fixture := newDownloadFixture(t, currentBundle)
	hung := fixture.work.seedDownload(fixture.db, fixture.client, hashOf(30))
	fine := fixture.work.seedDownload(fixture.db, fixture.client, hashOf(31))
	fixture.peer.set(fine.Hash, torrentState{Name: "Book", Progress: 1, State: "uploading", Size: 1, Content: "/d/Fine"})
	release := make(chan struct{})
	defer close(release)
	fixture.peer.setHook(func(hash string, w http.ResponseWriter, r *http.Request) bool {
		if hash == hung.Hash {
			select {
			case <-release:
			case <-r.Context().Done():
			}
			return true
		}
		return false
	})
	outcome := fixture.cycle(t, "--request-timeout", "300ms")
	if outcome.code != 1 {
		t.Fatalf("exit %d: %s", outcome.code, outcome.output)
	}
	if status := fixture.download(t, fine.Download)["status"]; status != "3" {
		t.Fatalf("the healthy download was blocked by the hung one: %s", status)
	}
	if code := scalar[string](t, fixture.db, `SELECT error_code FROM wf_download_state WHERE download_id = ?`, hung.Download); code != "connection" {
		t.Fatalf("hung observation code %s", code)
	}
	if status := fixture.download(t, hung.Download)["status"]; status != "1" {
		t.Fatalf("hung download status %s", status)
	}
}

func TestWriterContentionDuringCompletionRollsBackAndRecovers(t *testing.T) {
	fixture := newDownloadFixture(t, currentBundle)
	seed := fixture.work.seedDownload(fixture.db, fixture.client, hashOf(32))
	fixture.peer.set(seed.Hash, torrentState{Name: "Book", Progress: 1, State: "uploading", Size: 1, Content: "/d/Book"})
	before := fixture.download(t, seed.Download)
	injected := newFaults(t, map[string]string{"monitor.observed": "park"})
	fixture.work.control("trigger", "downloads")
	run := fixture.work.command(injected, append([]string{"run", "--once", "--busy-timeout", "150ms"}, downloadsOnly...)...)
	injected.reached(t, "monitor.observed")
	holder := fixture.work.open()
	transaction, err := holder.Begin()
	if err != nil {
		t.Fatal(err)
	}
	injected.release(t, "monitor.observed")
	code := run.wait()
	transaction.Rollback()
	if code != 1 || !contains(run.errorCodes(), "db-busy") {
		t.Fatalf("exit %d codes %v: %s", code, run.errorCodes(), run.output())
	}
	if !reflect.DeepEqual(before, fixture.download(t, seed.Download)) {
		t.Fatal("a busy database left a partial change")
	}
	if events, handoffs := fixture.counts(t); events != 0 || handoffs != 0 {
		t.Fatalf("effects %d %d", events, handoffs)
	}
	recovered := fixture.cycle(t)
	if recovered.code != 0 {
		t.Fatalf("exit %d: %s", recovered.code, recovered.output)
	}
	if events, handoffs := fixture.counts(t); events != 1 || handoffs != 1 {
		t.Fatalf("effects %d %d", events, handoffs)
	}
}

func TestAnUnreachableClientIsAConnectionErrorNotAMissingTorrent(t *testing.T) {
	fixture := newDownloadFixture(t, currentBundle)
	closed := newQBit(t)
	address := closed.URL
	closed.Close()
	client := fixture.work.seedClient(fixture.db, address, qbitPassword, true)
	seed := fixture.work.seedDownload(fixture.db, client, hashOf(60))
	before := fixture.download(t, seed.Download)
	outcome := fixture.cycle(t)
	if outcome.code != 1 {
		t.Fatalf("exit %d", outcome.code)
	}
	if !reflect.DeepEqual(before, fixture.download(t, seed.Download)) {
		t.Fatal("an unreachable client changed the download")
	}
	if code := scalar[string](t, fixture.db, `SELECT error_code FROM wf_download_state WHERE download_id = ?`, seed.Download); code != "connection" {
		t.Fatalf("code %s", code)
	}
}

func TestACycleThatExceedsItsDeadlineIsReportedAndRetried(t *testing.T) {
	fixture := newDownloadFixture(t, currentBundle)
	seed := fixture.work.seedDownload(fixture.db, fixture.client, hashOf(61))
	release := make(chan struct{})
	defer close(release)
	fixture.peer.setHook(func(hash string, w http.ResponseWriter, r *http.Request) bool {
		select {
		case <-release:
		case <-r.Context().Done():
		}
		return true
	})
	outcome := fixture.cycle(t, "--pass-deadline", "300ms", "--request-timeout", "30s")
	if outcome.code != 1 || !contains(outcome.codes, "pass-deadline") {
		t.Fatalf("exit %d codes %v", outcome.code, outcome.codes)
	}
	if next := scalar[string](t, fixture.db, `SELECT next_due_at FROM wf_schedule WHERE workflow = 'downloads'`); next > "2000-01-01" && next > time.Now().UTC().Format("2006-01-02 15:04:05.000000") {
		t.Fatalf("an incomplete cycle consumed its slot: %s", next)
	}
	if row := fixture.download(t, seed.Download); row["status"] != "1" {
		t.Fatalf("download %v", row)
	}
}

func TestControlChangesDuringACycleKeepTheScheduleDue(t *testing.T) {
	fixture := newDownloadFixture(t, currentBundle)
	seed := fixture.work.seedDownload(fixture.db, fixture.client, hashOf(62))
	fixture.peer.set(seed.Hash, torrentState{Name: "Book", Progress: 0.5, State: "downloading", Size: 1})
	injected := newFaults(t, map[string]string{"monitor.observed": "park"})
	fixture.work.control("trigger", "downloads")
	run := fixture.work.command(injected, append([]string{"run", "--once"}, downloadsOnly...)...)
	injected.reached(t, "monitor.observed")
	fixture.work.control("cancel", "downloads")
	fixture.work.control("resume", "downloads")
	injected.release(t, "monitor.observed")
	if code := run.wait(); code != 0 {
		t.Fatalf("exit %d: %s", code, run.output())
	}
	now := time.Now().UTC().Format("2006-01-02 15:04:05.000000")
	if next := scalar[string](t, fixture.db, `SELECT next_due_at FROM wf_schedule WHERE workflow = 'downloads'`); next > now {
		t.Fatalf("a cycle that raced a control change consumed the new slot: %s", next)
	}
}

func TestStaleObservationsWriteNeitherProgressNorState(t *testing.T) {
	cases := map[string]func(t *testing.T, f downloadFixture, seed seeded){
		"request cancelled": func(t *testing.T, f downloadFixture, seed seeded) {
			exec1(t, f.db, `UPDATE downloads SET status = 4 WHERE id = ?`, seed.Download)
		},
		"release replaced": func(t *testing.T, f downloadFixture, seed seeded) {
			exec1(t, f.db, `UPDATE search_results SET status = 2 WHERE id = ?`, seed.Result)
		},
		"re-dispatched under a new torrent": func(t *testing.T, f downloadFixture, seed seeded) {
			exec1(t, f.db, `UPDATE downloads SET external_id = ? WHERE id = ?`, hashOf(98), seed.Download)
		},
		"moved to another client": func(t *testing.T, f downloadFixture, seed seeded) {
			other := f.work.seedClient(f.db, f.peer.URL, qbitPassword, true)
			exec1(t, f.db, `UPDATE downloads SET download_client_id = ? WHERE id = ?`, itoa(other), seed.Download)
		},
	}
	for name, change := range cases {
		t.Run(name, func(t *testing.T) {
			fixture := newDownloadFixture(t, currentBundle)
			seed := fixture.work.seedDownload(fixture.db, fixture.client, hashOf(63))
			fixture.peer.set(seed.Hash, torrentState{Name: "Book", Progress: 0.75, State: "downloading", Size: 1})
			reached := make(chan struct{}, 1)
			release := make(chan struct{})
			fixture.peer.setHook(func(hash string, w http.ResponseWriter, r *http.Request) bool {
				if hash == seed.Hash {
					reached <- struct{}{}
					<-release
				}
				return false
			})
			fixture.work.control("trigger", "downloads")
			run := fixture.work.command(faults{}, append([]string{"run", "--once"}, downloadsOnly...)...)
			<-reached
			change(t, fixture, seed)
			afterChange := fixture.download(t, seed.Download)
			close(release)
			if code := run.wait(); code != 0 {
				t.Fatalf("exit %d: %s", code, run.output())
			}
			if !reflect.DeepEqual(afterChange, fixture.download(t, seed.Download)) {
				t.Fatalf("a stale observation wrote progress: %v", differences(afterChange, fixture.download(t, seed.Download)))
			}
			if states := scalar[int64](t, fixture.db, `SELECT COUNT(*) FROM wf_download_state WHERE download_id = ?`, seed.Download); states != 0 {
				t.Fatalf("a stale observation wrote state")
			}
		})
	}
}

func TestHandoffBackoffStaysCappedForLargeAttemptCounts(t *testing.T) {
	fixture := newDownloadFixture(t, currentBundle)
	seed := fixture.work.seedDownload(fixture.db, fixture.client, hashOf(64))
	fixture.peer.set(seed.Hash, torrentState{Name: "Book", Progress: 1, State: "uploading", Size: 1})
	fixture.cycle(t)
	exec1(t, fixture.db, `UPDATE wf_postprocess_handoffs SET attempts = 64`)
	fixture.consumer.setStatus(500)
	options := append([]string{"--handoff-url", fixture.consumer.URL, "--handoff-backoff", "30s"}, downloadsOnly...)
	if outcome := fixture.work.runOnce(faults{}, options...); outcome.code != 1 {
		t.Fatalf("exit %d", outcome.code)
	}
	fixture.work.runOnce(faults{}, options...)
	if got := len(fixture.consumer.deliveries()); got != 1 {
		t.Fatalf("a failing consumer was retried immediately: %d deliveries", got)
	}
	next := scalar[string](t, fixture.db, `SELECT next_attempt_at FROM wf_postprocess_handoffs`)
	if limit := time.Now().UTC().Add(5 * time.Minute).Format("2006-01-02 15:04:05.000000"); next > limit || next < time.Now().UTC().Format("2006-01-02 15:04:05.000000") {
		t.Fatalf("next attempt %s is not within the capped delay", next)
	}
}

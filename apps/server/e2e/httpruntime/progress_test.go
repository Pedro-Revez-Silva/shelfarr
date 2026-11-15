//go:build e2e

package httpruntime

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type shelf struct {
	f       fixture
	copied  runtimeCopy
	library privateLibrary
	roots   []string
}

func newShelf(t *testing.T) shelf {
	t.Helper()
	f := currentFixture(t)
	copied := newRuntimeCopy(t, f)
	library := newPrivateLibrary(t, copied, 20_000)
	return shelf{f: f, copied: copied, library: library, roots: []string{library.root}}
}

func (s shelf) start(t *testing.T, options serverOptions) *server {
	t.Helper()
	options.roots = s.roots
	return startServer(t, s.f, s.copied, options)
}

func (s shelf) token(label string) map[string]string {
	headers := bearer(s.f, label)
	headers["Content-Type"] = "application/json"
	return headers
}

func (s shelf) epubBody(t *testing.T, instance *server, mutation string, version int, extra string) string {
	t.Helper()
	asset := instance.assets(t, s.f, s.library.bookIDs["epub"])[0]
	return fmt.Sprintf(`{"asset_id":"%s","expected_version":%d,"client_mutation_id":"%s","locator":{"href":"OEBPS/chapter.xhtml","locations":{"progression":0.25,"position":3}}%s}`, asset.ID, version, mutation, extra)
}

func (s shelf) audioBody(t *testing.T, instance *server, mutation string, version int, seconds float64, extra string) string {
	t.Helper()
	asset := instance.assets(t, s.f, s.library.bookIDs["audio"])[0]
	return fmt.Sprintf(`{"asset_id":"%s","expected_version":%d,"client_mutation_id":"%s","position_seconds":%v%s}`, asset.ID, version, mutation, seconds, extra)
}

func (s shelf) progressPath(book string) string {
	return fmt.Sprintf("/api/consumer/v1/library/%d/progress", s.library.bookIDs[book])
}

func (s shelf) statusPath(book string) string {
	return fmt.Sprintf("/api/consumer/v1/library/%d/reading_status", s.library.bookIDs[book])
}

func put(instance *server, path string, headers map[string]string, body string) result {
	return instance.doBody(context.Background(), "PUT", path, headers, []byte(body))
}

func progressOf(t *testing.T, response result) map[string]any {
	t.Helper()
	var parsed struct {
		Progress map[string]any `json:"progress"`
	}
	if err := json.Unmarshal(response.body, &parsed); err != nil {
		t.Fatalf("%d %s", response.status, response.body)
	}
	return parsed.Progress
}

func (s shelf) rows(t *testing.T, query string, arguments ...any) []map[string]any {
	t.Helper()
	return openMirror(t, s.copied.database).rows(t, query, arguments...)
}

const (
	uuidA = "6f1c8d2e-3b4a-4c5d-8e9f-0a1b2c3d4e5f"
	uuidB = "7a2d9e3f-4c5b-4d6e-9fa0-1b2c3d4e5f60"
	uuidC = "8b3eaf40-5d6c-4e7f-a0b1-2c3d4e5f6071"
)

func TestGeneratedEpubAndAudioCheckpointsRoundTripAndSurviveARestart(t *testing.T) {
	s := newShelf(t)
	instance := s.start(t, serverOptions{})
	epub := put(instance, s.progressPath("epub"), s.token("alice-full"), s.epubBody(t, instance, uuidA, 0, `,"observed_at":"2026-11-07T10:15:30.123456+01:00"`))
	audio := put(instance, s.progressPath("audio"), s.token("alice-full"), s.audioBody(t, instance, uuidB, 0, 1234.5, ""))
	if epub.status != 200 || audio.status != 200 {
		t.Fatalf("%d %s | %d %s", epub.status, epub.body, audio.status, audio.body)
	}
	if status := put(instance, s.statusPath("audio"), s.token("alice-full"), `{"status":"finished"}`); status.status != 200 {
		t.Fatalf("%d %s", status.status, status.body)
	}
	before := map[string]string{}
	for _, name := range []string{"epub", "audio"} {
		page := instance.do("GET", fmt.Sprintf("/api/consumer/v1/library/%d", s.library.bookIDs[name]), bearer(s.f, "alice-full"))
		before[name] = string(page.body)
	}
	if !strings.Contains(before["epub"], `"observed_at":"2026-11-07T09:15:30.123Z"`) || !strings.Contains(before["audio"], `"reading_status":"finished"`) || !strings.Contains(before["audio"], `"position_seconds":1234.5`) {
		t.Fatalf("%v", before)
	}
	if code := instance.stop(); code != 0 {
		t.Fatalf("exit %d", code)
	}
	restarted := s.start(t, serverOptions{})
	for _, name := range []string{"epub", "audio"} {
		page := restarted.do("GET", fmt.Sprintf("/api/consumer/v1/library/%d", s.library.bookIDs[name]), bearer(s.f, "alice-full"))
		if string(page.body) != before[name] {
			t.Errorf("%s changed over a restart:\n%s\n%s", name, page.body, before[name])
		}
	}
	for _, target := range []string{"/api/consumer/v1/library?status=finished", "/api/consumer/v1/continue"} {
		if got := restarted.do("GET", target, bearer(s.f, "alice-full")); got.status != 200 {
			t.Errorf("%s: %d", target, got.status)
		}
	}
	continued := restarted.do("GET", "/api/consumer/v1/continue", bearer(s.f, "alice-full"))
	if !bytes.Contains(continued.body, []byte(fmt.Sprintf(`"id":"%d"`, s.library.bookIDs["epub"]))) || bytes.Contains(continued.body, []byte(fmt.Sprintf(`"id":"%d"`, s.library.bookIDs["audio"]))) {
		t.Fatalf("continue after restart: %s", continued.body)
	}
	if other := restarted.do("GET", s.progressPath("epub"), bearer(s.f, "bob-full")); !bytes.Contains(other.body, []byte(`"progress":null`)) {
		t.Fatalf("another account read a place: %s", other.body)
	}
	instance.assertNoSensitive(t, s.f, s.library.root, s.copied.database)
}

func TestConcurrentFirstWritesAndUpdatesOverRealSocketsLoseNothing(t *testing.T) {
	s := newShelf(t)
	instance := s.start(t, serverOptions{})
	asset := instance.assets(t, s.f, s.library.bookIDs["audio"])[0]
	body := func(mutation string, version int, seconds int) string {
		return fmt.Sprintf(`{"asset_id":"%s","expected_version":%d,"client_mutation_id":"%s","position_seconds":%d}`, asset.ID, version, mutation, seconds)
	}
	var created, conflicts, other atomic.Int32
	var wait sync.WaitGroup
	for index := 0; index < 24; index++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			switch put(instance, s.progressPath("audio"), s.token("alice-full"), body(fmt.Sprintf("00000000-0000-4000-8000-%012d", index), 0, index)).status {
			case 200:
				created.Add(1)
			case 409:
				conflicts.Add(1)
			default:
				other.Add(1)
			}
		}()
	}
	wait.Wait()
	if created.Load() != 1 || conflicts.Load() != 23 || other.Load() != 0 {
		t.Fatalf("created=%d conflicts=%d other=%d", created.Load(), conflicts.Load(), other.Load())
	}
	const writers = 12
	var applied atomic.Int32
	for index := 0; index < writers; index++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			for attempt := 0; attempt < 200; attempt++ {
				current := progressOf(t, instance.do("GET", s.progressPath("audio"), bearer(s.f, "alice-full")))
				mutation := fmt.Sprintf("10000000-0000-4000-8000-%08d%04d", index, attempt)
				if put(instance, s.progressPath("audio"), s.token("alice-full"), body(mutation, int(current["version"].(float64)), 1000+index)).status == 200 {
					applied.Add(1)
					return
				}
			}
		}()
	}
	wait.Wait()
	rows := s.rows(t, `SELECT version FROM consumer_progresses`)
	if applied.Load() != writers || len(rows) != 1 || rows[0]["version"] != int64(writers+1) {
		t.Fatalf("applied=%d rows=%v", applied.Load(), rows)
	}
	instance.assertNoSensitive(t, s.f, s.library.root, s.copied.database, asset.ID)
}

func TestARetryAfterAnUncertainCommitIsIdempotentAndKeepsTheOriginalActivityTime(t *testing.T) {
	cases := []struct {
		name, fault string
		committed   bool
	}{{"killed after the commit", "progress.committed=kill", true}, {"killed before the commit", "progress.before-commit=kill", false}}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newShelf(t)
			plain := s.start(t, serverOptions{})
			body := s.audioBody(t, plain, uuidA, 0, 777, `,"observed_at":"2026-11-07T10:15:30.123Z"`)
			plain.stop()
			faultDir := t.TempDir()
			crashing := s.start(t, serverOptions{seam: true, faults: c.fault, faultDir: faultDir})
			request, _ := http.NewRequest("PUT", crashing.base+s.progressPath("audio"), strings.NewReader(body))
			for name, value := range s.token("alice-full") {
				request.Header.Set(name, value)
			}
			if response, err := crashing.client.Do(request); err == nil {
				response.Body.Close()
				t.Fatalf("the response survived a kill: %d", response.StatusCode)
			}
			select {
			case <-crashing.done:
			case <-time.After(10 * time.Second):
				t.Fatal("the server did not die")
			}
			rows := s.rows(t, `SELECT version, client_mutation_id, CAST(observed_at AS TEXT) AS observed_at FROM consumer_progresses`)
			if c.committed != (len(rows) == 1) {
				t.Fatalf("committed=%v rows=%v", c.committed, rows)
			}
			if c.committed && (rows[0]["observed_at"] != "2026-11-07 10:15:30.123000" || rows[0]["version"] != int64(1)) {
				t.Fatalf("%v", rows)
			}
			var mode string
			database, err := sql.Open("sqlite", "file:"+s.copied.database)
			if err != nil {
				t.Fatal(err)
			}
			database.QueryRow(`PRAGMA journal_mode`).Scan(&mode)
			database.Close()
			if mode != "wal" {
				t.Fatalf("the journal mode changed to %s", mode)
			}
			restarted := s.start(t, serverOptions{})
			first := put(restarted, s.progressPath("audio"), s.token("alice-full"), body)
			retry := put(restarted, s.progressPath("audio"), s.token("alice-full"), body)
			if first.status != 200 || retry.status != 200 || !bytes.Equal(first.body, retry.body) {
				t.Fatalf("%d %s | %d %s", first.status, first.body, retry.status, retry.body)
			}
			stored := progressOf(t, first)
			if stored["version"] != 1.0 || stored["observed_at"] != "2026-11-07T10:15:30.123Z" || stored["client_mutation_id"] != uuidA {
				t.Fatalf("%v", stored)
			}
			next := put(restarted, s.progressPath("audio"), s.token("alice-full"), strings.Replace(strings.Replace(body, uuidA, uuidB, 1), `"expected_version":0`, `"expected_version":1`, 1))
			if progressOf(t, next)["version"] != 2.0 {
				t.Fatalf("the next write did not follow the retried one: %s", next.body)
			}
			if count := s.rows(t, `SELECT COUNT(*) AS n FROM consumer_progresses`); count[0]["n"] != int64(1) {
				t.Fatalf("%v", count)
			}
		})
	}
}

func TestAReadingStatusSurvivesAKillAfterItsCommit(t *testing.T) {
	s := newShelf(t)
	crashing := s.start(t, serverOptions{seam: true, faults: "status.committed=kill", faultDir: t.TempDir()})
	request, _ := http.NewRequest("PUT", crashing.base+s.statusPath("epub"), strings.NewReader(`{"status":"finished"}`))
	for name, value := range s.token("alice-full") {
		request.Header.Set(name, value)
	}
	if response, err := crashing.client.Do(request); err == nil {
		response.Body.Close()
		t.Fatal("the response survived a kill")
	}
	<-crashing.done
	if rows := s.rows(t, `SELECT status FROM consumer_reading_states`); len(rows) != 1 || rows[0]["status"] != int64(2) {
		t.Fatalf("%v", rows)
	}
	restarted := s.start(t, serverOptions{})
	if retry := put(restarted, s.statusPath("epub"), s.token("alice-full"), `{"status":"finished"}`); retry.status != 200 || !bytes.Contains(retry.body, []byte(`"reading_status":"finished"`)) {
		t.Fatalf("%d %s", retry.status, retry.body)
	}
	if rows := s.rows(t, `SELECT COUNT(*) AS n FROM consumer_reading_states`); rows[0]["n"] != int64(1) {
		t.Fatalf("%v", rows)
	}
}

func TestAClientThatLeavesWhileItsWriteHoldsTheLockWritesNothing(t *testing.T) {
	s := newShelf(t)
	plain := s.start(t, serverOptions{})
	body := s.audioBody(t, plain, uuidA, 0, 5, "")
	plain.stop()
	faultDir := t.TempDir()
	instance := s.start(t, serverOptions{seam: true, faults: "progress.locked=park", faultDir: faultDir})
	ctx, leave := context.WithCancel(context.Background())
	finished := make(chan error, 1)
	go func() {
		request, _ := http.NewRequestWithContext(ctx, "PUT", instance.base+s.progressPath("audio"), strings.NewReader(body))
		for name, value := range s.token("alice-full") {
			request.Header.Set(name, value)
		}
		response, err := instance.client.Do(request)
		if err == nil {
			response.Body.Close()
		}
		finished <- err
	}()
	reached := filepath.Join(faultDir, "progress.locked.reached")
	for deadline := time.Now().Add(10 * time.Second); ; time.Sleep(5 * time.Millisecond) {
		if _, err := os.Stat(reached); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the write never reached the lock")
		}
	}
	leave()
	if err := <-finished; !errors.Is(err, context.Canceled) {
		t.Fatalf("%v", err)
	}
	time.Sleep(300 * time.Millisecond)
	os.WriteFile(filepath.Join(faultDir, "progress.locked.release"), nil, 0o600)
	time.Sleep(300 * time.Millisecond)
	if rows := s.rows(t, `SELECT COUNT(*) AS n FROM consumer_progresses`); rows[0]["n"] != int64(0) {
		t.Fatalf("a write of a client that left was committed: %v", rows)
	}
	logged := instance.logLines()
	var sawCancelled bool
	for _, line := range logged {
		if line["route"] == "progress" && line["status"] == 499.0 {
			sawCancelled = true
		}
	}
	if !sawCancelled {
		t.Fatalf("the cancelled write was not logged as such: %s", instance.log.String())
	}
	if retry := put(instance, s.progressPath("audio"), s.token("alice-full"), body); retry.status != 200 {
		t.Fatalf("%d %s", retry.status, retry.body)
	}
}

func holdWriteLock(t *testing.T, path string) func() {
	t.Helper()
	holder, err := sql.Open("sqlite", "file:"+path+"?_txlock=immediate&_pragma=busy_timeout(5000)")
	if err != nil {
		t.Fatal(err)
	}
	transaction, err := holder.Begin()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := transaction.Exec(`UPDATE settings SET description = description WHERE id = (SELECT MIN(id) FROM settings)`); err != nil {
		t.Fatal(err)
	}
	return func() { transaction.Rollback(); holder.Close() }
}

func TestAHeldWriteLockIsBusyForWritesAndNeverAnAnonymousOrAnEmptySuccess(t *testing.T) {
	s := newShelf(t)
	instance := s.start(t, serverOptions{arguments: []string{"-busy-timeout", "200ms"}})
	progressBody := s.audioBody(t, instance, uuidA, 0, 5, "")
	release := holdWriteLock(t, s.copied.database)
	started := time.Now()
	for _, request := range [][3]string{{s.progressPath("audio"), progressBody, "progress"}, {s.statusPath("audio"), `{"status":"finished"}`, "status"}} {
		got := put(instance, request[0], s.token("alice-full"), request[1])
		if got.status != 503 || got.headers.Get("Retry-After") == "" || !bytes.Contains(got.body, []byte("database_busy")) {
			t.Fatalf("%s: %d %s", request[2], got.status, got.body)
		}
	}
	if time.Since(started) > 5*time.Second {
		t.Fatal("busy writes were not bounded")
	}
	release()
	if rows := s.rows(t, `SELECT (SELECT COUNT(*) FROM consumer_progresses) AS progress, (SELECT COUNT(*) FROM consumer_reading_states) AS status`); rows[0]["progress"] != int64(0) || rows[0]["status"] != int64(0) {
		t.Fatalf("a busy write changed state: %v", rows)
	}
	if got := put(instance, s.progressPath("audio"), s.token("alice-full"), progressBody); got.status != 200 {
		t.Fatalf("the server did not recover: %d %s", got.status, got.body)
	}
}

func rawRequest(t *testing.T, instance *server, head string) net.Conn {
	t.Helper()
	connection, err := net.DialTimeout("tcp", instance.base[len("http://"):], 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { connection.Close() })
	if _, err := io.WriteString(connection, head); err != nil {
		t.Fatal(err)
	}
	return connection
}

func readStatus(t *testing.T, connection net.Conn, within time.Duration) (int, string) {
	t.Helper()
	connection.SetReadDeadline(time.Now().Add(within))
	response, err := http.ReadResponse(bufioReader(connection), nil)
	if err != nil {
		return 0, err.Error()
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(response.Body)
	return response.StatusCode, string(body)
}

func TestWriteBodiesAreBoundedTimedAndNeverReadBeforeAuthentication(t *testing.T) {
	s := newShelf(t)
	instance := s.start(t, serverOptions{arguments: []string{"-body-timeout", "400ms", "-max-metadata-requests", "2"}})
	path := s.progressPath("audio")
	auth := "Authorization: Bearer " + s.f.token["alice-full"] + "\r\n"
	head := func(extra string) string {
		return "PUT " + path + " HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n" + auth + extra + "\r\n"
	}

	declared := rawRequest(t, instance, head("Content-Length: 10485760\r\n"))
	if status, body := readStatus(t, declared, 3*time.Second); status != 413 || !strings.Contains(body, "request_too_large") {
		t.Fatalf("a declared oversized body: %d %s", status, body)
	}

	chunked := rawRequest(t, instance, head("Transfer-Encoding: chunked\r\n"))
	go func() {
		piece := strings.Repeat("a", 4096)
		for index := 0; index < 40; index++ {
			if _, err := fmt.Fprintf(chunked, "%x\r\n%s\r\n", len(piece), piece); err != nil {
				return
			}
		}
	}()
	if status, body := readStatus(t, chunked, 5*time.Second); status != 413 || !strings.Contains(body, "request_too_large") {
		t.Fatalf("a chunked oversized body: %d %s", status, body)
	}

	unauthenticated := rawRequest(t, instance, "PUT "+path+" HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nAuthorization: Bearer nope\r\nContent-Length: 10485760\r\n\r\n")
	if status, _ := readStatus(t, unauthenticated, 3*time.Second); status != 401 {
		t.Fatalf("an unauthenticated body was awaited: %d", status)
	}

	started := time.Now()
	stalled := rawRequest(t, instance, head("Content-Length: 300\r\n")+`{"asset_id":"`)
	second := rawRequest(t, instance, head("Content-Length: 300\r\n")+`{"asset_id":"`)
	time.Sleep(100 * time.Millisecond)
	if busy := instance.do("GET", "/api/consumer/v1/me", bearer(s.f, "alice-full")); busy.status != 503 || !bytes.Contains(busy.body, []byte("server_busy")) {
		t.Fatalf("stalled bodies did not hold their bounded slots: %d %s", busy.status, busy.body)
	}
	if status, body := readStatus(t, stalled, 3*time.Second); status != 408 || !strings.Contains(body, "request_body_timeout") {
		t.Fatalf("a stalled body: %d %s", status, body)
	}
	if status, _ := readStatus(t, second, 3*time.Second); status != 408 {
		t.Fatalf("a second stalled body: %d", status)
	}
	if time.Since(started) > 3*time.Second {
		t.Fatal("stalled bodies were not bounded")
	}
	if recovered := instance.do("GET", "/api/consumer/v1/me", bearer(s.f, "alice-full")); recovered.status != 200 {
		t.Fatalf("the slots were not returned: %d", recovered.status)
	}

	leaver := rawRequest(t, instance, head("Content-Length: 300\r\n")+`{"asset_id":"`)
	leaver.Close()
	time.Sleep(600 * time.Millisecond)
	if got := instance.do("GET", "/api/consumer/v1/me", bearer(s.f, "alice-full")); got.status != 200 {
		t.Fatalf("a client that left mid-body hurt the server: %d", got.status)
	}
	if rows := s.rows(t, `SELECT COUNT(*) AS n FROM consumer_progresses`); rows[0]["n"] != int64(0) {
		t.Fatalf("a rejected body wrote a place: %v", rows)
	}
	for _, kind := range []string{"text/plain", "application/x-www-form-urlencoded"} {
		headers := bearer(s.f, "alice-full")
		headers["Content-Type"] = kind
		if got := put(instance, path, headers, "asset_id=x"); got.status != 415 {
			t.Errorf("%s: %d", kind, got.status)
		}
	}
	instance.assertNoSensitive(t, s.f, s.library.root, s.copied.database)
}

func TestOnlyProgressAndStatusTablesAreWrittenAndTokensAreTouchedSeparately(t *testing.T) {
	s := newShelf(t)
	instance := s.start(t, serverOptions{})
	tables := func() map[string]string {
		result := map[string]string{}
		mirror := openMirror(t, s.copied.database)
		for _, table := range []string{"users", "books", "settings", "download_clients", "requests", "downloads"} {
			rows := mirror.rows(t, "SELECT COUNT(*) AS n, COALESCE(MAX(CAST(updated_at AS TEXT)), '') AS latest FROM "+table)
			result[table] = fmt.Sprint(rows[0]["n"], rows[0]["latest"])
		}
		return result
	}
	before := tables()
	put(instance, s.progressPath("audio"), s.token("alice-full"), s.audioBody(t, instance, uuidA, 0, 5, ""))
	put(instance, s.progressPath("audio"), s.token("alice-full"), "{")
	put(instance, s.statusPath("audio"), s.token("alice-full"), `{"status":"finished"}`)
	put(instance, s.progressPath("audio"), s.token("alice-read-only"), s.audioBody(t, instance, uuidB, 1, 5, ""))
	after := tables()
	for table, state := range before {
		if after[table] != state {
			t.Errorf("%s was written: %s -> %s", table, state, after[table])
		}
	}
	touched := s.rows(t, `SELECT id FROM api_tokens WHERE last_used_at IS NOT NULL AND CAST(last_used_at AS TEXT) >= ?`, time.Now().Add(-time.Minute).UTC().Format("2006-01-02 15:04:05"))
	if len(touched) < 1 {
		t.Fatal("no credential use was recorded")
	}
	instance.assertNoSensitive(t, s.f, s.library.root)
}

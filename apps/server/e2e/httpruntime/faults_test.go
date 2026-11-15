//go:build e2e

package httpruntime

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

func currentFixture(t *testing.T) fixture {
	t.Helper()
	return loadFixture(t, "current-schema", "SHELFARR_HTTP_CASES_CURRENT")
}

func (s *server) assertNoSensitive(t *testing.T, f fixture, extra ...string) {
	t.Helper()
	logged := s.log.String()
	secret, _ := os.ReadFile(f.secretFile())
	forbidden := append([]string{string(secret), f.doc.BundleMediaRoot, f.doc.ExtraMediaRoot, "Authorization", "Bearer "}, extra...)
	for _, raw := range f.token {
		forbidden = append(forbidden, raw)
	}
	for _, value := range forbidden {
		if value != "" && strings.Contains(logged, value) {
			t.Errorf("the output contains a sensitive value of %d bytes", len(value))
		}
	}
}

func TestGeneratedEpubIsFetchedIntactAndAudioIsSeekable(t *testing.T) {
	f := currentFixture(t)
	copied := newRuntimeCopy(t, f)
	library := newPrivateLibrary(t, copied, 700_000)
	instance := startServer(t, f, copied, serverOptions{roots: []string{library.root}})
	epub := instance.assets(t, f, library.bookIDs["epub"])
	if len(epub) != 1 || epub[0].MediaType != "application/epub+zip" {
		t.Fatalf("%+v", epub)
	}
	whole := instance.do("GET", epub[0].URL, bearer(f, "alice-full"))
	expected, _ := os.ReadFile(library.files["epub"])
	if whole.status != 200 || !bytes.Equal(whole.body, expected) || whole.headers.Get("Accept-Ranges") != "bytes" {
		t.Fatalf("the generated EPUB was not delivered intact: %d %d", whole.status, len(whole.body))
	}
	audio := instance.assets(t, f, library.bookIDs["audio"])[0]
	content, _ := os.ReadFile(library.files["audio"])
	seeks := []struct {
		header      string
		first, last int
	}{{"bytes=0-99", 0, 99}, {"bytes=350000-350999", 350000, 350999}, {"bytes=-500", len(content) - 500, len(content) - 1}, {"bytes=699900-", 699900, len(content) - 1}}
	for _, seek := range seeks {
		headers := bearer(f, "alice-full")
		headers["Range"] = seek.header
		part := instance.do("GET", audio.URL, headers)
		want := content[seek.first : seek.last+1]
		if part.status != 206 || !bytes.Equal(part.body, want) || part.headers.Get("Content-Range") != fmt.Sprintf("bytes %d-%d/%d", seek.first, seek.last, len(content)) {
			t.Errorf("%s: %d %s", seek.header, part.status, part.headers.Get("Content-Range"))
		}
	}
	headers := bearer(f, "alice-full")
	headers["Range"] = "bytes=999999999-"
	if refused := instance.do("GET", audio.URL, headers); refused.status != 416 || refused.headers.Get("Content-Range") != fmt.Sprintf("bytes */%d", len(content)) {
		t.Fatalf("%d", refused.status)
	}
	instance.assertNoSensitive(t, f, library.root, copied.database, audio.ID)
}

func TestMissingDeletedReplacedAndSwappedAssetsAreNeverServedUnderAnOldIdentity(t *testing.T) {
	f := currentFixture(t)
	copied := newRuntimeCopy(t, f)
	library := newPrivateLibrary(t, copied, 5000)
	instance := startServer(t, f, copied, serverOptions{roots: []string{library.root}})
	original := instance.assets(t, f, library.bookIDs["epub"])[0]
	fetch := func(asset assetInfo) result { return instance.do("GET", asset.URL, bearer(f, "alice-full")) }
	if fetch(original).status != 200 {
		t.Fatal("baseline fetch failed")
	}

	replacement := library.files["epub"] + ".new"
	os.WriteFile(replacement, pseudoRandom(1, 90_000), 0o600)
	os.Rename(replacement, library.files["epub"])
	if got := fetch(original); got.status != 410 || !bytes.Contains(got.body, []byte("asset_unavailable")) {
		t.Fatalf("a replaced file (new inode, identical bytes) kept its identity: %d", got.status)
	}
	replaced := instance.assets(t, f, library.bookIDs["epub"])[0]
	if replaced.ID == original.ID || fetch(replaced).status != 200 {
		t.Fatalf("the replacement was not offered under a new identity")
	}

	os.WriteFile(library.files["epub"], pseudoRandom(9, 90_001), 0o600)
	if got := fetch(replaced); got.status != 410 {
		t.Fatalf("a rewritten file kept its identity: %d", got.status)
	}

	os.Remove(library.files["epub"])
	if got := instance.assets(t, f, library.bookIDs["epub"]); len(got) != 0 {
		t.Fatalf("a deleted file is still offered: %+v", got)
	}
	if got := fetch(replaced); got.status != 410 {
		t.Fatalf("a deleted file was served: %d", got.status)
	}

	outside := filepath.Join(filepath.Dir(library.root), "outside.epub")
	os.WriteFile(outside, []byte("outside the library"), 0o600)
	os.Symlink(outside, library.files["epub"])
	if got := instance.do("GET", "/api/consumer/v1/library/"+fmt.Sprint(library.bookIDs["epub"]), bearer(f, "alice-full")); got.status != 501 || !bytes.Contains(got.body, []byte("unsupported_library_layout")) {
		t.Fatalf("a symbolic link entry was not refused explicitly: %d %s", got.status, got.body)
	}
	if got := fetch(replaced); got.status == 200 || bytes.Contains(got.body, []byte("outside")) {
		t.Fatalf("content outside the library was disclosed: %d", got.status)
	}

	serial := instance.assets(t, f, library.bookIDs["serial"])
	if len(serial) != 2 || serial[0].Filename != "Part 1.mp3" {
		t.Fatalf("%+v", serial)
	}
	os.Remove(library.files["track1"])
	os.Symlink(outside, library.files["track1"])
	if got := instance.do("GET", serial[1].URL, bearer(f, "alice-full")); got.status != 501 {
		t.Fatalf("a symbolic link swapped into a directory publication was not refused: %d", got.status)
	}
	for _, attempt := range []string{"/api/consumer/v1/library/9001/assets/..%2f..%2fetc%2fpasswd", "/api/consumer/v1/library/9001/assets/%2e%2e", "/api/consumer/v1/library/../me", "/api/consumer/v1/library/9001/assets/" + strings.Repeat("0", 64) + "/../x"} {
		if got := instance.do("GET", attempt, bearer(f, "alice-full")); got.status == 200 && bytes.Contains(got.body, []byte("root:")) {
			t.Fatalf("traversal %q reached the filesystem", attempt)
		}
	}
	instance.assertNoSensitive(t, f, library.root, copied.database, original.ID)
}

func TestAClientThatDisconnectsMidStreamReleasesItsSlot(t *testing.T) {
	f := currentFixture(t)
	copied := newRuntimeCopy(t, f)
	library := newPrivateLibrary(t, copied, 24<<20)
	instance := startServer(t, f, copied, serverOptions{roots: []string{library.root}, arguments: []string{"-max-media-streams", "1"}})
	audio := instance.assets(t, f, library.bookIDs["audio"])[0]
	connection := smallReceiveBuffer(t, instance.base[len("http://"):])
	fmt.Fprintf(connection, "GET %s HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer %s\r\n\r\n", audio.URL, f.token["alice-full"])
	buffer := make([]byte, 100_000)
	connection.SetReadDeadline(time.Now().Add(5 * time.Second))
	if count, _ := io.ReadAtLeast(connection, buffer, 50_000); count < 50_000 {
		t.Fatal("the stream never started")
	}
	if got := instance.do("GET", audio.URL, bearer(f, "alice-full")); got.status != 503 || got.headers.Get("Retry-After") == "" {
		t.Fatalf("the second stream should be refused while the slot is held: %d", got.status)
	}
	connection.Close()
	deadline := time.Now().Add(10 * time.Second)
	for {
		got := instance.do("GET", audio.URL, map[string]string{"Authorization": "Bearer " + f.token["alice-full"], "Range": "bytes=0-9"})
		if got.status == 206 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the slot of a disconnected client was never released (last status %d)", got.status)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func TestStalledMediaClientsNeverStarveTheCatalogue(t *testing.T) {
	f := currentFixture(t)
	copied := newRuntimeCopy(t, f)
	library := newPrivateLibrary(t, copied, 24<<20)
	instance := startServer(t, f, copied, serverOptions{roots: []string{library.root}, arguments: []string{"-max-media-streams", "2", "-stream-write-stall", "2s"}})
	audio := instance.assets(t, f, library.bookIDs["audio"])[0]
	var stalled []io.Closer
	for index := 0; index < 2; index++ {
		connection := smallReceiveBuffer(t, instance.base[len("http://"):])
		stalled = append(stalled, connection)
		fmt.Fprintf(connection, "GET %s HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer %s\r\n\r\n", audio.URL, f.token["alice-full"])
	}
	defer func() {
		for _, connection := range stalled {
			connection.Close()
		}
	}()
	time.Sleep(500 * time.Millisecond)
	started := time.Now()
	for _, target := range []string{"/api/consumer/v1/library", "/api/consumer/v1/me", "/api/consumer/v1/continue", "/api/consumer/v1/server.json"} {
		if got := instance.do("GET", target, bearer(f, "alice-full")); got.status != 200 {
			t.Fatalf("%s: %d while media streams are stalled", target, got.status)
		}
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("metadata took %s while two media clients were stalled", elapsed)
	}
	if got := instance.do("GET", audio.URL, bearer(f, "alice-full")); got.status != 503 {
		t.Fatalf("a third stream must be refused, got %d", got.status)
	}
	deadline := time.Now().Add(15 * time.Second)
	for {
		got := instance.do("GET", audio.URL, map[string]string{"Authorization": "Bearer " + f.token["alice-full"], "Range": "bytes=0-9"})
		if got.status == 206 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("stalled clients were never dropped (last status %d)", got.status)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func TestABusyDatabaseIsReportedAsBusyAndNeverAsAnAnonymousRequest(t *testing.T) {
	f := currentFixture(t)
	copied := newRuntimeCopy(t, f)
	instance := startServer(t, f, copied, serverOptions{arguments: []string{"-busy-timeout", "200ms"}})
	holder, err := sql.Open("sqlite", "file:"+copied.database+"?_txlock=immediate&_pragma=busy_timeout(5000)")
	if err != nil {
		t.Fatal(err)
	}
	defer holder.Close()
	transaction, err := holder.Begin()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := transaction.Exec(`UPDATE settings SET description = description WHERE id = (SELECT MIN(id) FROM settings)`); err != nil {
		t.Fatal(err)
	}
	lastUsed := tokenLastUsed(t, copied.database, f.token["alice-full"])
	started := time.Now()
	for _, target := range []string{"/api/consumer/v1/me", "/api/consumer/v1/library", "/api/consumer/v1/continue"} {
		got := instance.do("GET", target, bearer(f, "alice-full"))
		if got.status != 503 || got.headers.Get("Retry-After") == "" || !bytes.Contains(got.body, []byte("database_busy")) {
			t.Fatalf("%s: %d %s", target, got.status, got.body)
		}
	}
	if time.Since(started) > 5*time.Second {
		t.Fatal("busy requests were not bounded")
	}
	if tokenLastUsed(t, copied.database, f.token["alice-full"]) != lastUsed {
		t.Fatal("a refused request recorded use")
	}
	transaction.Rollback()
	if got := instance.do("GET", "/api/consumer/v1/me", bearer(f, "alice-full")); got.status != 200 {
		t.Fatalf("the server did not recover: %d", got.status)
	}
	if tokenLastUsed(t, copied.database, f.token["alice-full"]) == lastUsed {
		t.Fatal("the successful request after recovery recorded no use")
	}
	instance.assertNoSensitive(t, f, copied.database)
}

func tokenLastUsed(t *testing.T, path, raw string) string {
	t.Helper()
	database, err := sql.Open("sqlite", "file:"+path+"?mode=ro")
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	var stamp sql.NullString
	if err := database.QueryRow(`SELECT CAST(last_used_at AS TEXT) FROM api_tokens WHERE token_digest = ?`, digestOf(raw)).Scan(&stamp); err != nil {
		t.Fatal(err)
	}
	return stamp.String
}

func TestLiveWalCommitsAreVisibleImmediately(t *testing.T) {
	f := currentFixture(t)
	copied := newRuntimeCopy(t, f)
	library := newPrivateLibrary(t, copied, 3000)
	instance := startServer(t, f, copied, serverOptions{roots: []string{library.root}})
	writer, err := sql.Open("sqlite", "file:"+copied.database+"?_pragma=busy_timeout(5000)")
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Close()
	writer.SetMaxOpenConns(1)
	if _, err := writer.Exec(`PRAGMA wal_autocheckpoint=0`); err != nil {
		t.Fatal(err)
	}
	extra := filepath.Join(library.root, "Late Arrival.epub")
	os.WriteFile(extra, pseudoRandom(5, 2000), 0o600)
	if _, err := writer.Exec(`INSERT INTO books (id, title, book_type, file_path, created_at, updated_at) VALUES (9100, 'Late Arrival', 1, ?, '2026-11-02 00:00:00', '2026-11-02 00:00:00')`, extra); err != nil {
		t.Fatal(err)
	}
	if info, err := os.Stat(copied.database + "-wal"); err != nil || info.Size() == 0 {
		t.Fatal("the test needs an uncheckpointed WAL")
	}
	if got := instance.do("GET", "/api/consumer/v1/library/9100", bearer(f, "alice-full")); got.status != 200 || !bytes.Contains(got.body, []byte("Late Arrival")) {
		t.Fatalf("a committed WAL row is invisible: %d", got.status)
	}
	if _, err := writer.Exec(`UPDATE api_tokens SET revoked_at = '2026-11-02 00:00:00' WHERE token_digest = ?`, digestOf(f.token["alice-full"])); err != nil {
		t.Fatal(err)
	}
	if got := instance.do("GET", "/api/consumer/v1/me", bearer(f, "alice-full")); got.status != 401 {
		t.Fatalf("an external revocation did not take effect immediately: %d", got.status)
	}
}

func TestAMetadataReadFailureIsNeverAnEmptySuccess(t *testing.T) {
	f := currentFixture(t)
	copied := newRuntimeCopy(t, f)
	instance := startServer(t, f, copied, serverOptions{})
	execSQL(t, copied.database, `DROP TABLE consumer_progresses`)
	for _, target := range []string{"/api/consumer/v1/library", "/api/consumer/v1/continue"} {
		got := instance.do("GET", target, bearer(f, "alice-full"))
		if got.status < 500 || bytes.Contains(got.body, []byte(`"items":[]`)) {
			t.Fatalf("%s: %d %s", target, got.status, got.body)
		}
	}
}

func TestADatabaseRootOutsideTheConfiguredRootsIsRefusedLoudly(t *testing.T) {
	f := currentFixture(t)
	copied := newRuntimeCopy(t, f)
	elsewhere := t.TempDir()
	instance := startServer(t, f, copied, serverOptions{roots: []string{elsewhere}})
	for _, target := range []string{"/api/consumer/v1/library", "/api/consumer/v1/continue", "/api/consumer/v1/library/1"} {
		got := instance.do("GET", target, bearer(f, "alice-full"))
		if got.status != 503 || !bytes.Contains(got.body, []byte("library_root_not_allowed")) {
			t.Fatalf("%s: %d %s", target, got.status, got.body)
		}
	}
	if got := instance.do("GET", "/api/consumer/v1/me", bearer(f, "alice-full")); got.status != 200 {
		t.Fatalf("account routes do not depend on the library: %d", got.status)
	}
}

func TestOneAdoptionHappensEvenWhenManyRequestsRaceToUseTheNewCredential(t *testing.T) {
	f := currentFixture(t)
	copied := newRuntimeCopy(t, f)
	instance := startServer(t, f, copied, serverOptions{})
	var group sync.WaitGroup
	statuses := make([]int, 24)
	for index := range statuses {
		group.Add(1)
		go func() {
			defer group.Done()
			statuses[index] = instance.do("GET", "/api/consumer/v1/me", bearer(f, "alice-adopting")).status
		}()
	}
	group.Wait()
	for index, status := range statuses {
		if status != 200 {
			t.Fatalf("request %d: %d", index, status)
		}
	}
	if got := instance.do("GET", "/api/consumer/v1/me", bearer(f, "alice-previous")); got.status != 401 {
		t.Fatalf("the replaced credential still works: %d", got.status)
	}
	database, _ := sql.Open("sqlite", "file:"+copied.database+"?mode=ro")
	defer database.Close()
	var revoked, pointer sql.NullString
	database.QueryRow(`SELECT CAST(revoked_at AS TEXT) FROM api_tokens WHERE token_digest = ?`, digestOf(f.token["alice-previous"])).Scan(&revoked)
	database.QueryRow(`SELECT CAST(replaces_api_token_id AS TEXT) FROM api_tokens WHERE token_digest = ?`, digestOf(f.token["alice-adopting"])).Scan(&pointer)
	if !revoked.Valid || pointer.Valid {
		t.Fatalf("adoption incomplete: revoked=%v pointer=%v", revoked, pointer)
	}
	instance.do("GET", "/api/consumer/v1/me", bearer(f, "alice-adopting"))
	var again sql.NullString
	database.QueryRow(`SELECT CAST(revoked_at AS TEXT) FROM api_tokens WHERE token_digest = ?`, digestOf(f.token["alice-previous"])).Scan(&again)
	if again != revoked {
		t.Fatalf("the revocation was rewritten: %v -> %v", revoked, again)
	}
}

func TestBearerCredentialsAreSeparateFromBrowserSessionsAndTheLegacyApi(t *testing.T) {
	f := currentFixture(t)
	copied := newRuntimeCopy(t, f)
	instance := startServer(t, f, copied, serverOptions{})
	cookie := map[string]string{"Cookie": "session_id=" + f.token["alice-full"] + "; _shelfarr_session=x", "X-CSRF-Token": f.token["alice-full"]}
	for _, target := range []string{"/api/consumer/v1/me", "/api/consumer/v1/library", "/api/consumer/v1/library/1"} {
		if got := instance.do("GET", target, cookie); got.status != 401 {
			t.Fatalf("%s accepted a browser session: %d", target, got.status)
		}
	}
	for _, target := range []string{"/api/v1/requests", "/api/v1/search?q=x", "/preview/api/v1/session", "/read", "/up"} {
		got := instance.do("GET", target, bearer(f, "admin-full"))
		if target == "/up" {
			if got.status != 200 {
				t.Fatalf("%s: %d", target, got.status)
			}
			continue
		}
		if got.status != 404 {
			t.Fatalf("%s: %d (browser and legacy admin routes stay with Rails)", target, got.status)
		}
	}
	me := instance.do("GET", "/api/consumer/v1/me", bearer(f, "member-privileged-scopes"))
	var body struct {
		Scopes []string `json:"scopes"`
	}
	json.Unmarshal(me.body, &body)
	if len(body.Scopes) != 1 || body.Scopes[0] != "library:read" {
		t.Fatalf("a broad scope list granted administrator scopes: %v", body.Scopes)
	}
}

func TestExcludedRoutesAreRefusedWithoutAnySideEffect(t *testing.T) {
	f := currentFixture(t)
	copied := newRuntimeCopy(t, f)
	instance := startServer(t, f, copied, serverOptions{})
	before := shape(tokenState(t, copied.database), nil)
	for _, request := range [][2]string{
		{"POST", "/api/consumer/v1/auth/token"}, {"POST", "/api/consumer/v1/auth/device"}, {"POST", "/api/consumer/v1/auth/revoke"},
		{"GET", "/api/consumer/v1/discover"},
		{"POST", "/api/consumer/v1/requests"}, {"GET", "/api/consumer/v1/library/1/assets/" + strings.Repeat("a", 64) + "/reading_order"},
		{"POST", "/api/consumer/v1/library/1/assets/" + strings.Repeat("a", 64) + "/transfer_grant"},
	} {
		got := instance.do(request[0], request[1], bearer(f, "alice-full"))
		if got.status != 501 || !bytes.Contains(got.body, []byte("not_implemented_in_go_runtime")) {
			t.Errorf("%s %s: %d %s", request[0], request[1], got.status, got.body)
		}
	}
	if after := shape(tokenState(t, copied.database), nil); fmt.Sprint(before) != fmt.Sprint(after) {
		t.Fatal("an excluded route changed the database")
	}
}

func TestUnsupportedStoredFormsAreRefusedNotApproximated(t *testing.T) {
	f := currentFixture(t)
	copied := newRuntimeCopy(t, f)
	instance := startServer(t, f, copied, serverOptions{})
	execSQL(t, copied.database, `UPDATE api_tokens SET scopes = '{"library:read":true}' WHERE token_digest = ?`, digestOf(f.token["bob-full"]))
	got := instance.do("GET", "/api/consumer/v1/me", bearer(f, "bob-full"))
	if got.status != 501 || !bytes.Contains(got.body, []byte("unsupported_stored_value")) {
		t.Fatalf("%d %s", got.status, got.body)
	}
	execSQL(t, copied.database, `UPDATE consumer_progresses SET locator = 'not json' WHERE user_id = (SELECT id FROM users WHERE username = 'alice')`)
	if got := instance.do("GET", "/api/consumer/v1/library", bearer(f, "alice-full")); got.status < 500 {
		t.Fatalf("a locator that is not JSON was presented as ready: %d", got.status)
	}
}

func TestRequestLimitsAndDeadlines(t *testing.T) {
	f := currentFixture(t)
	copied := newRuntimeCopy(t, f)
	instance := startServer(t, f, copied, serverOptions{arguments: []string{"-read-header-timeout", "400ms"}})
	huge := map[string]string{"X-Padding": strings.Repeat("a", 64<<10)}
	if got := instance.do("GET", "/up", huge); got.status != 431 {
		t.Fatalf("oversized headers: %d", got.status)
	}
	if got := instance.do("GET", "/api/consumer/v1/library?q="+strings.Repeat("a", 40<<10), bearer(f, "alice-full")); got.status < 400 || got.status >= 500 {
		t.Fatalf("an oversized request line: %d", got.status)
	}
	request, _ := http.NewRequest("GET", instance.base+"/up", strings.NewReader(strings.Repeat("x", 1<<20)))
	response, err := instance.client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != 200 {
		t.Fatalf("a body on a GET: %d", response.StatusCode)
	}
	connection, err := net.DialTimeout("tcp", instance.base[len("http://"):], 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	fmt.Fprint(connection, "GET /up HTTP/1.1\r\nHost: x\r\nX-Slow:")
	connection.SetReadDeadline(time.Now().Add(5 * time.Second))
	started := time.Now()
	_, err = io.ReadAll(connection)
	if time.Since(started) > 3*time.Second {
		t.Fatalf("a client that never finishes its headers was kept for %s (%v)", time.Since(started), err)
	}
}

func TestShutdownWaitsForTransfersAndIsBoundedForStalledClients(t *testing.T) {
	f := currentFixture(t)
	copied := newRuntimeCopy(t, f)
	library := newPrivateLibrary(t, copied, 8<<20)
	instance := startServer(t, f, copied, serverOptions{roots: []string{library.root}, arguments: []string{"-shutdown-timeout", "3s", "-stream-write-stall", "30s"}})
	audio := instance.assets(t, f, library.bookIDs["audio"])[0]
	want, _ := os.ReadFile(library.files["audio"])
	request, _ := http.NewRequest("GET", instance.base+audio.URL, nil)
	request.Header.Set("Authorization", "Bearer "+f.token["alice-full"])
	response, err := instance.client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	first := make([]byte, 1<<20)
	if _, err := io.ReadFull(response.Body, first); err != nil {
		t.Fatal(err)
	}
	stalled := smallReceiveBuffer(t, instance.base[len("http://"):])
	fmt.Fprintf(stalled, "GET %s HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer %s\r\n\r\n", audio.URL, f.token["alice-full"])
	time.Sleep(300 * time.Millisecond)
	instance.cmd.Process.Signal(syscall.SIGTERM)
	rest, err := io.ReadAll(response.Body)
	if err != nil || !bytes.Equal(append(first, rest...), want) {
		t.Fatalf("an in-flight transfer was cut off by shutdown: %v", err)
	}
	defer stalled.Close()
	started := time.Now()
	select {
	case <-instance.done:
	case <-time.After(15 * time.Second):
		t.Fatal("shutdown never completed while a client stalled")
	}
	if elapsed := time.Since(started); elapsed > 8*time.Second {
		t.Fatalf("shutdown took %s with a 3s limit", elapsed)
	}
	if instance.exit != 0 {
		t.Fatalf("exit code %d", instance.exit)
	}
}

func TestStartupRefusesAnythingThatCouldTouchTheWrongDataWithFixedDiagnostics(t *testing.T) {
	f := currentFixture(t)
	copied := newRuntimeCopy(t, f)
	secretFile := f.secretFile()
	base := func(extra ...string) []string {
		return append([]string{"-experimental", "-database", copied.database, "-lock-file", copied.lock, "-library-root", f.doc.BundleMediaRoot, "-listen", "127.0.0.1:0"}, extra...)
	}
	good := []string{"SECRET_KEY_BASE_FILE=" + secretFile}
	typo := filepath.Join(copied.dir, "typo.sqlite3")
	notSQLite := filepath.Join(copied.dir, "text.sqlite3")
	os.WriteFile(notSQLite, []byte("plain text"), 0o600)
	unknown := filepath.Join(copied.dir, "unknown.sqlite3")
	source, _ := os.ReadFile(copied.database)
	os.WriteFile(unknown, source, 0o600)
	execSQL(t, unknown, `INSERT INTO schema_migrations (version) VALUES ('29991231235959')`)
	cases := []struct {
		name        string
		environment []string
		arguments   []string
		code        int
		diagnostic  string
	}{
		{"not acknowledged as experimental", good, []string{"-database", copied.database}, 2, "experimental"},
		{"a typo path must not become a fresh database", good, []string{"-experimental", "-database", typo, "-lock-file", copied.lock, "-library-root", f.doc.BundleMediaRoot, "-listen", "127.0.0.1:0"}, 2, "database-not-sqlite"},
		{"a file that is not sqlite", good, []string{"-experimental", "-database", notSQLite, "-lock-file", copied.lock, "-library-root", f.doc.BundleMediaRoot, "-listen", "127.0.0.1:0"}, 2, "database-not-sqlite"},
		{"an unknown schema revision", good, []string{"-experimental", "-database", unknown, "-lock-file", copied.lock, "-library-root", f.doc.BundleMediaRoot, "-listen", "127.0.0.1:0"}, 2, "database-schema"},
		{"no secret key", nil, base(), 2, "secret-key-base-missing"},
		{"credentials master key mode", []string{"RAILS_MASTER_KEY=synthetic"}, base(), 2, "master-key-mode-unsupported"},
		{"ambiguous secret key", []string{"SECRET_KEY_BASE=a", "SECRET_KEY_BASE_FILE=" + secretFile}, base(), 2, "secret-key-base-ambiguous"},
		{"unreadable secret file", []string{"SECRET_KEY_BASE_FILE=" + filepath.Join(copied.dir, "absent")}, base(), 2, "secret-key-base-unusable"},
		{"public listen address", good, base("-listen", "0.0.0.0:0"), 2, "config"},
		{"missing library root", good, append(base(), "-library-root", filepath.Join(copied.dir, "no-such-root")), 2, "library-roots"},
		{"no library root at all", good, []string{"-experimental", "-database", copied.database, "-lock-file", copied.lock, "-listen", "127.0.0.1:0"}, 2, "config"},
		{"relative lock path", good, []string{"-experimental", "-database", copied.database, "-lock-file", "domain.lock", "-library-root", f.doc.BundleMediaRoot, "-listen", "127.0.0.1:0"}, 2, "config"},
	}
	for _, c := range cases {
		output, code := runBinary(t, c.environment, c.arguments)
		if code != c.code || !strings.Contains(output, c.diagnostic) {
			t.Errorf("%s: exit %d output %q", c.name, code, output)
		}
		for _, sensitive := range []string{copied.database, secretFile, f.doc.BundleMediaRoot, typo} {
			if strings.Contains(output, sensitive) {
				t.Errorf("%s: the diagnostic leaks a path", c.name)
			}
		}
	}
	if _, err := os.Stat(typo); !os.IsNotExist(err) {
		t.Fatal("a typo path was turned into a database file")
	}
}

func TestOnlyOneProcessMayOwnTheWriteDomain(t *testing.T) {
	f := currentFixture(t)
	copied := newRuntimeCopy(t, f)
	first := startServer(t, f, copied, serverOptions{})
	_, code := runBinary(t, []string{"SECRET_KEY_BASE_FILE=" + f.secretFile()}, []string{"-experimental", "-database", copied.database, "-lock-file", copied.lock, "-library-root", f.doc.BundleMediaRoot, "-listen", "127.0.0.1:0"})
	if code != 3 {
		t.Fatalf("a second owner started (exit %d)", code)
	}
	first.kill()
	if _, code := runBinary(t, []string{"SECRET_KEY_BASE_FILE=" + f.secretFile()}, []string{"-experimental", "-database", copied.database, "-lock-file", copied.lock, "-library-root", f.doc.BundleMediaRoot, "-listen", "127.0.0.1:1"}); code == 3 {
		t.Fatal("the lock of a killed process was not released")
	}
}

func TestCursorsDoNotCrossASecretKeyBase(t *testing.T) {
	f := currentFixture(t)
	var railsCursor string
	for _, entry := range f.doc.Cases {
		if entry.Name == "library-page-recent-2" {
			railsCursor = entry.Path
		}
	}
	if railsCursor == "" {
		t.Fatal("the fixture has no Rails-issued cursor")
	}
	copied := newRuntimeCopy(t, f)
	own := startServer(t, f, copied, serverOptions{})
	if got := own.do("GET", railsCursor, bearer(f, "alice-full")); got.status != 200 {
		t.Fatalf("a cursor issued by Rails was refused with the same key: %d", got.status)
	}
	own.stop()
	other := startServer(t, f, copied, serverOptions{noSecret: true, env: []string{"SECRET_KEY_BASE=another-installation-secret-another-installation-secret"}})
	got := other.do("GET", railsCursor, bearer(f, "alice-full"))
	if got.status != 400 || !bytes.Contains(got.body, []byte("Invalid library cursor")) {
		t.Fatalf("a cursor of another installation was accepted: %d", got.status)
	}
}

func TestSensitiveValuesNeverReachTheOutputOfAnyRun(t *testing.T) {
	f := currentFixture(t)
	copied := newRuntimeCopy(t, f)
	instance := startServer(t, f, copied, serverOptions{})
	for _, entry := range f.doc.Cases[:120] {
		instance.do(entry.Method, entry.Path, requestHeaders(f, entry))
	}
	instance.do("GET", "/api/consumer/v1/me", map[string]string{"Authorization": "Bearer " + strings.Repeat("z", 64)})
	instance.assertNoSensitive(t, f, copied.database, copied.dir, copied.lock)
	for _, line := range instance.logLines() {
		if line["msg"] == "request" {
			for key := range line {
				switch key {
				case "time", "level", "msg", "method", "route", "status", "bytes", "duration_ms", "code":
				default:
					t.Fatalf("an unexpected field %q in the request log", key)
				}
			}
		}
	}
}

func digestOf(raw string) string {
	return accountDigest(raw)
}

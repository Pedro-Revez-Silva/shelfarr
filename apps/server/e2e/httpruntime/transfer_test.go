//go:build e2e

package httpruntime

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/railsmsg"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/transfergrant"
)

type mintedGrant struct {
	Name      string `json:"name"`
	Label     string `json:"label"`
	URL       string `json:"url"`
	Book      int64  `json:"book"`
	At        string `json:"at"`
	Plaintext string `json:"plaintext"`
}

type grantBody struct {
	URL       string `json:"url"`
	ExpiresAt string `json:"expires_at"`
}

const grantPlaceholder = "<grant>"

func productEncryptor(t *testing.T, f fixture) railsmsg.Encryptor {
	t.Helper()
	secret, err := os.ReadFile(f.secretFile())
	if err != nil {
		t.Fatal("cannot read the synthetic secret")
	}
	encryptor, err := railsmsg.NewEncryptor(strings.TrimRight(string(secret), "\n"), transfergrant.Salt)
	if err != nil {
		t.Fatal(err)
	}
	return encryptor
}

func grantURL(got result) string {
	var body grantBody
	json.Unmarshal(got.body, &body)
	return body.URL
}

func redactMintedGrant(t *testing.T, f fixture, entry caseEntry, got result) (result, []string) {
	t.Helper()
	var body map[string]string
	if err := json.Unmarshal(got.body, &body); err != nil || len(body) != 2 {
		return got, []string{"the minted grant body is not {url, expires_at}"}
	}
	grant, found := strings.CutPrefix(body["url"], entry.Grant.Prefix)
	if !found || len(grant) != entry.Grant.Length {
		return got, []string{fmt.Sprintf("the minted url has the wrong shape or length (%d want %d)", len(grant), entry.Grant.Length)}
	}
	if _, valid := transfergrant.GrantFromQuery("grant=" + grant); !valid {
		return got, []string{"the minted grant is outside the grant alphabet"}
	}
	plaintext, ok := productEncryptor(t, f).Decrypt(grant)
	if !ok || string(plaintext) != entry.Grant.Plaintext {
		return got, []string{fmt.Sprintf("the minted grant decrypts to %q, Rails minted %q", plaintext, entry.Grant.Plaintext)}
	}
	body["url"] = grantPlaceholder
	redacted, _ := json.Marshal(body)
	got.body = redacted
	return got, nil
}

func exportMintedGrants(t *testing.T, f fixture, minted []mintedGrant) {
	t.Helper()
	directory := os.Getenv("SHELFARR_HTTP_GO_ROWS_DIR")
	if directory == "" {
		return
	}
	if len(minted) == 0 {
		t.Fatal("Go minted no grant to hand to Rails")
	}
	encoded, err := json.MarshalIndent(minted, "", " ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, f.name+"-grants.json"), encoded, 0o600); err != nil {
		t.Fatal(err)
	}
}

func (s *server) mint(t *testing.T, f fixture, label string, book int64, asset string) string {
	t.Helper()
	headers := bearer(f, label)
	headers["Content-Type"] = "application/json"
	got := s.doBody(context.Background(), "POST", "/api/consumer/v1/library/"+strconv.FormatInt(book, 10)+"/assets/"+asset+"/transfer_grant", headers, []byte("{}"))
	var body grantBody
	if got.status != http.StatusCreated || json.Unmarshal(got.body, &body) != nil {
		t.Fatalf("mint: %d %s", got.status, got.body)
	}
	return body.URL
}

func (s *server) invalidGrant(t *testing.T, method, url string) {
	t.Helper()
	got := s.do(method, url, nil)
	if got.status != http.StatusUnauthorized || (method == "GET" && !bytes.Equal(got.body, []byte(`{"error":"invalid_grant"}`))) {
		t.Fatalf("%s: %d %s", method, got.status, got.body)
	}
	if got.headers.Get("Cache-Control") != "private, no-store" || got.headers.Get("Referrer-Policy") != "no-referrer" {
		t.Fatalf("an invalid grant answer is not private: %v", got.headers)
	}
}

func TestGoGrantsServeBytesAndRangesSurviveARestartAndDieWithAnotherSecret(t *testing.T) {
	f := currentFixture(t)
	copied := newRuntimeCopy(t, f)
	library := newPrivateLibrary(t, copied, 700_000)
	options := serverOptions{roots: []string{library.root}}
	instance := startServer(t, f, copied, options)
	epub := instance.assets(t, f, library.bookIDs["epub"])[0]
	audio := instance.assets(t, f, library.bookIDs["audio"])[0]
	epubURL := instance.mint(t, f, "alice-full", library.bookIDs["epub"], epub.ID)
	audioURL := instance.mint(t, f, "alice-full", library.bookIDs["audio"], audio.ID)
	if again := instance.mint(t, f, "alice-full", library.bookIDs["epub"], epub.ID); again == epubURL {
		t.Fatal("two mints produced the same grant")
	}
	expected, _ := os.ReadFile(library.files["epub"])
	content, _ := os.ReadFile(library.files["audio"])
	check := func(server *server) {
		t.Helper()
		whole := server.do("GET", epubURL, nil)
		if whole.status != 200 || !bytes.Equal(whole.body, expected) || whole.headers.Get("Location") != "" || whole.headers.Get("Content-Type") != "application/epub+zip" {
			t.Fatalf("the EPUB was not delivered intact through its grant: %d", whole.status)
		}
		head := server.do("HEAD", epubURL, nil)
		if head.status != 200 || head.headers.Get("Content-Length") != strconv.Itoa(len(expected)) || len(head.body) != 0 {
			t.Fatalf("HEAD: %d %v", head.status, head.headers)
		}
		part := server.do("GET", audioURL, map[string]string{"Range": "bytes=350000-350999", "If-Range": `"` + audio.ID + `"`})
		if part.status != 206 || !bytes.Equal(part.body, content[350000:351000]) || part.headers.Get("Content-Range") != fmt.Sprintf("bytes 350000-350999/%d", len(content)) {
			t.Fatalf("range: %d", part.status)
		}
		if got := server.do("GET", audioURL, map[string]string{"Range": "bytes=999999999-"}); got.status != 416 {
			t.Fatalf("an unsatisfiable range: %d", got.status)
		}
		if got := server.do("GET", audioURL, map[string]string{"If-None-Match": `"` + audio.ID + `"`}); got.status != 304 || len(got.body) != 0 {
			t.Fatalf("a matching validator: %d", got.status)
		}
		if got := server.do("GET", audioURL, map[string]string{"Authorization": "Bearer nonsense", "Cookie": "session_id=x"}); got.status != 200 || !bytes.Equal(got.body, content) {
			t.Fatalf("a stray credential spoiled a valid grant: %d", got.status)
		}
	}
	check(instance)
	if code := instance.stop(); code != 0 {
		t.Fatalf("exit %d", code)
	}
	restarted := startServer(t, f, copied, options)
	check(restarted)
	restarted.stop()
	rotated := startServer(t, f, copied, serverOptions{roots: options.roots, noSecret: true, env: []string{"SECRET_KEY_BASE=another-synthetic-secret-key-base-another-synthetic-secret"}})
	rotated.invalidGrant(t, "GET", epubURL)
	rotated.invalidGrant(t, "HEAD", audioURL)
	rotated.stop()
	original := startServer(t, f, copied, options)
	check(original)
	original.assertNoSensitive(t, f, library.root, copied.database, audio.ID, strings.Split(audioURL, "grant=")[1], strings.Split(epubURL, "grant=")[1])
}

func TestAGrantMintedByRailsIsServedByTheShippedBinaryAtRealTime(t *testing.T) {
	for _, f := range fixtures(t) {
		t.Run(f.name, func(t *testing.T) {
			var minted, fetched *caseEntry
			for index := range f.doc.Cases {
				switch f.doc.Cases[index].Name {
				case "transfer-boundary-mint":
					minted = &f.doc.Cases[index]
				case "transfer-boundary-issue-time":
					fetched = &f.doc.Cases[index]
				}
			}
			if minted == nil || fetched == nil || minted.MintedURL == "" {
				t.Fatal("the fixture has no Rails-minted grant")
			}
			issued, err := time.Parse(time.RFC3339Nano, *minted.At)
			if err != nil || time.Since(issued) > 22*time.Hour {
				t.Fatalf("the Rails-minted grant is too old to use at real time: %v", err)
			}
			copied := newRuntimeCopy(t, f)
			instance := startServer(t, f, copied, serverOptions{})
			got := instance.do("GET", minted.MintedURL, nil)
			if got.status != 200 || hexSum(got.body) != fetched.BodySHA256 || len(got.body) != fetched.BodyBytes {
				t.Fatalf("Go refused or altered a grant minted by Rails: %d", got.status)
			}
			for header, want := range map[string]string{"etag": got.headers.Get("ETag"), "cache-control": "private, no-store", "referrer-policy": "no-referrer"} {
				if got.headers.Get(header) != want || want != fetched.ResponseHeaders[header] {
					t.Errorf("%s: %q", header, got.headers.Get(header))
				}
			}
			instance.stop()
			restarted := startServer(t, f, copied, serverOptions{})
			if again := restarted.do("GET", minted.MintedURL, nil); again.status != 200 {
				t.Fatalf("a Rails grant did not survive a Go restart: %d", again.status)
			}
		})
	}
}

func TestEveryUseOfAGrantRechecksTheLiveCredentialAtRealTime(t *testing.T) {
	f := currentFixture(t)
	copied := newRuntimeCopy(t, f)
	library := newPrivateLibrary(t, copied, 5000)
	instance := startServer(t, f, copied, serverOptions{roots: []string{library.root}})
	epub := instance.assets(t, f, library.bookIDs["epub"])[0]
	url := instance.mint(t, f, "alice-full", library.bookIDs["epub"], epub.ID)
	digest := digestOf(f.token["alice-full"])
	steps := []struct{ name, change, restore string }{
		{"revoked", `UPDATE api_tokens SET revoked_at = '2026-01-01 00:00:00' WHERE token_digest = ?`, `UPDATE api_tokens SET revoked_at = NULL WHERE token_digest = ?`},
		{"scope", `UPDATE api_tokens SET scopes = '["progress:write"]' WHERE token_digest = ?`, `UPDATE api_tokens SET scopes = '["library:read"]' WHERE token_digest = ?`},
		{"owner", `UPDATE api_tokens SET user_id = (SELECT id FROM users WHERE username = 'bob') WHERE token_digest = ?`, `UPDATE api_tokens SET user_id = (SELECT id FROM users WHERE username = 'alice') WHERE token_digest = ?`},
		{"deleted owner", `UPDATE users SET deleted_at = '2026-01-01 00:00:00' WHERE id = (SELECT user_id FROM api_tokens WHERE token_digest = ?)`, `UPDATE users SET deleted_at = NULL WHERE id = (SELECT user_id FROM api_tokens WHERE token_digest = ?)`},
	}
	original := map[string]any{}
	database, _ := sql.Open("sqlite", "file:"+copied.database)
	defer database.Close()
	var scopes string
	database.QueryRow(`SELECT scopes FROM api_tokens WHERE token_digest = ?`, digest).Scan(&scopes)
	original["scopes"] = scopes
	for _, step := range steps {
		if got := instance.do("GET", url, nil); got.status != 200 {
			t.Fatalf("before %s: %d", step.name, got.status)
		}
		execSQL(t, copied.database, step.change, digest)
		instance.invalidGrant(t, "GET", url)
		instance.invalidGrant(t, "HEAD", url)
		execSQL(t, copied.database, step.restore, digest)
		if step.name == "scope" {
			execSQL(t, copied.database, `UPDATE api_tokens SET scopes = ? WHERE token_digest = ?`, original["scopes"], digest)
		}
		if got := instance.do("GET", url, nil); got.status != 200 {
			t.Fatalf("after restoring %s: %d", step.name, got.status)
		}
	}
	expires := time.Now().UTC().Add(1500 * time.Millisecond).Format("2006-01-02 15:04:05.000000")
	execSQL(t, copied.database, `UPDATE api_tokens SET expires_at = ? WHERE token_digest = ?`, expires, digest)
	if got := instance.do("GET", url, nil); got.status != 200 {
		t.Fatalf("a token about to expire: %d", got.status)
	}
	time.Sleep(1600 * time.Millisecond)
	instance.invalidGrant(t, "GET", url)
	execSQL(t, copied.database, `UPDATE api_tokens SET expires_at = NULL WHERE token_digest = ?`, digest)
	execSQL(t, copied.database, `DELETE FROM api_tokens WHERE token_digest = ?`, digest)
	instance.invalidGrant(t, "GET", url)
}

func TestGrantBoundariesFollowTheServerClockExactly(t *testing.T) {
	f := currentFixture(t)
	copied := newRuntimeCopy(t, f)
	library := newPrivateLibrary(t, copied, 5000)
	clock := filepath.Join(copied.dir, "clock")
	issued := time.Date(2026, 11, 15, 10, 0, 0, 987_654_000, time.UTC)
	os.WriteFile(clock, []byte(issued.Format(time.RFC3339Nano)), 0o600)
	instance := startServer(t, f, copied, serverOptions{roots: []string{library.root}, seam: true, clockFile: clock})
	epub := instance.assets(t, f, library.bookIDs["epub"])[0]
	url := instance.mint(t, f, "alice-full", library.bookIDs["epub"], epub.ID)
	expiry := time.Date(2026, 11, 16, 10, 0, 0, 987_000_000, time.UTC)
	for moment, alive := range map[time.Time]bool{issued.Add(-time.Hour): true, issued: true, expiry.Add(-time.Microsecond): true, expiry: false, expiry.Add(time.Microsecond): false, expiry.Add(48 * time.Hour): false} {
		os.WriteFile(clock, []byte(moment.Format(time.RFC3339Nano)), 0o600)
		if got := instance.do("GET", url, nil); (got.status == 200) != alive {
			t.Errorf("at %v: %d", moment, got.status)
		}
	}
	os.WriteFile(clock, []byte(issued.Format(time.RFC3339Nano)), 0o600)
	execSQL(t, copied.database, `UPDATE api_tokens SET expires_at = '2026-11-15 12:00:00.500700' WHERE token_digest = ?`, digestOf(f.token["alice-full"]))
	short := instance.mint(t, f, "alice-full", library.bookIDs["epub"], epub.ID)
	soon := time.Date(2026, 11, 15, 12, 0, 0, 500_000_000, time.UTC)
	for moment, alive := range map[time.Time]bool{soon.Add(-time.Microsecond): true, soon: false, soon.Add(300 * time.Microsecond): false} {
		os.WriteFile(clock, []byte(moment.Format(time.RFC3339Nano)), 0o600)
		if got := instance.do("GET", short, nil); (got.status == 200) != alive {
			t.Errorf("a short-lived token at %v: %d", moment, got.status)
		}
	}
}

func TestAnAbortedTransferReleasesItsSlotAndAnInFlightOneSurvivesRevocation(t *testing.T) {
	f := currentFixture(t)
	copied := newRuntimeCopy(t, f)
	library := newPrivateLibrary(t, copied, 24<<20)
	faultDir := t.TempDir()
	instance := startServer(t, f, copied, serverOptions{roots: []string{library.root}, seam: true, arguments: []string{"-max-media-streams", "2"}, faults: "transfer.authorized=park", faultDir: faultDir})
	audio := instance.assets(t, f, library.bookIDs["audio"])[0]
	url := instance.mint(t, f, "alice-full", library.bookIDs["audio"], audio.ID)
	content, _ := os.ReadFile(library.files["audio"])
	var inFlight result
	var group sync.WaitGroup
	group.Add(1)
	go func() {
		defer group.Done()
		inFlight = instance.do("GET", url, nil)
	}()
	reached := filepath.Join(faultDir, "transfer.authorized.reached")
	deadline := time.Now().Add(10 * time.Second)
	for {
		if _, err := os.Stat(reached); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the transfer never reached authorisation")
		}
		time.Sleep(5 * time.Millisecond)
	}
	execSQL(t, copied.database, `UPDATE api_tokens SET revoked_at = '2026-11-15 00:00:00' WHERE token_digest = ?`, digestOf(f.token["alice-full"]))
	os.WriteFile(filepath.Join(faultDir, "transfer.authorized.release"), nil, 0o600)
	group.Wait()
	if inFlight.status != 200 || !bytes.Equal(inFlight.body, content) {
		t.Fatalf("the transfer authorised before the revocation was cut: %d", inFlight.status)
	}
	instance.invalidGrant(t, "GET", url)
	execSQL(t, copied.database, `UPDATE api_tokens SET revoked_at = NULL WHERE token_digest = ?`, digestOf(f.token["alice-full"]))

	connection := smallReceiveBuffer(t, instance.base[len("http://"):])
	fmt.Fprintf(connection, "GET %s HTTP/1.1\r\nHost: x\r\n\r\n", url)
	buffer := make([]byte, 100_000)
	connection.SetReadDeadline(time.Now().Add(5 * time.Second))
	if count, _ := io.ReadAtLeast(connection, buffer, 50_000); count < 50_000 {
		t.Fatal("the stream never started")
	}
	connection.Close()
	deadline = time.Now().Add(10 * time.Second)
	for {
		got := instance.do("GET", url, map[string]string{"Range": "bytes=0-9"})
		if got.status == 206 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the slot of an aborted transfer was never released (last status %d)", got.status)
		}
		time.Sleep(50 * time.Millisecond)
	}
	aborted := false
	for _, line := range instance.logLines() {
		if bytesSent, _ := line["bytes"].(float64); line["route"] == "transfer" && line["status"] == float64(200) && bytesSent > 0 && int(bytesSent) < len(content) {
			aborted = true
		}
	}
	if !aborted {
		t.Fatal("the aborted transfer is not recorded as a partial delivery")
	}
}

func TestStalledTransfersAreBoundedAndNeverBlockMintingOrMetadata(t *testing.T) {
	f := currentFixture(t)
	copied := newRuntimeCopy(t, f)
	library := newPrivateLibrary(t, copied, 24<<20)
	instance := startServer(t, f, copied, serverOptions{roots: []string{library.root}, arguments: []string{"-max-media-streams", "2", "-stream-write-stall", "2s"}})
	audio := instance.assets(t, f, library.bookIDs["audio"])[0]
	url := instance.mint(t, f, "alice-full", library.bookIDs["audio"], audio.ID)
	var stalled []io.Closer
	for index := 0; index < 2; index++ {
		connection := smallReceiveBuffer(t, instance.base[len("http://"):])
		stalled = append(stalled, connection)
		fmt.Fprintf(connection, "GET %s HTTP/1.1\r\nHost: x\r\n\r\n", url)
	}
	defer func() {
		for _, connection := range stalled {
			connection.Close()
		}
	}()
	time.Sleep(500 * time.Millisecond)
	if got := instance.do("GET", url, nil); got.status != 503 || got.headers.Get("Retry-After") == "" {
		t.Fatalf("a third transfer must be refused while two are stalled: %d", got.status)
	}
	if got := instance.do("GET", url+"x", nil); got.status != 503 {
		t.Fatalf("an unauthenticated flood is not admitted ahead of the pool: %d", got.status)
	}
	instance.mint(t, f, "alice-full", library.bookIDs["audio"], audio.ID)
	if got := instance.do("GET", "/api/consumer/v1/me", bearer(f, "alice-full")); got.status != 200 {
		t.Fatalf("metadata was blocked: %d", got.status)
	}
	deadline := time.Now().Add(15 * time.Second)
	for {
		got := instance.do("GET", url, map[string]string{"Range": "bytes=0-9"})
		if got.status == 206 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("stalled transfers were never dropped (last status %d)", got.status)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func TestConcurrentTransfersAndARevocationNeverPanicOrServeAfterTheRevocation(t *testing.T) {
	f := currentFixture(t)
	copied := newRuntimeCopy(t, f)
	library := newPrivateLibrary(t, copied, 2<<20)
	instance := startServer(t, f, copied, serverOptions{roots: []string{library.root}, arguments: []string{"-max-media-streams", "16"}})
	audio := instance.assets(t, f, library.bookIDs["audio"])[0]
	url := instance.mint(t, f, "alice-full", library.bookIDs["audio"], audio.ID)
	var group sync.WaitGroup
	statuses := make(chan int, 64)
	for worker := 0; worker < 12; worker++ {
		group.Add(1)
		go func() {
			defer group.Done()
			for round := 0; round < 4; round++ {
				statuses <- instance.do("GET", url, map[string]string{"Range": "bytes=0-65535"}).status
			}
		}()
	}
	execSQL(t, copied.database, `UPDATE api_tokens SET revoked_at = '2026-11-15 00:00:00' WHERE token_digest = ?`, digestOf(f.token["alice-full"]))
	group.Wait()
	close(statuses)
	for status := range statuses {
		if status != 206 && status != 401 {
			t.Errorf("a concurrent transfer answered %d", status)
		}
	}
	instance.invalidGrant(t, "GET", url)
	if code := instance.stop(); code != 0 {
		t.Fatalf("exit %d", code)
	}
}

func TestGrantsAndCredentialsNeverReachTheLogEvenOnAPanic(t *testing.T) {
	f := currentFixture(t)
	copied := newRuntimeCopy(t, f)
	library := newPrivateLibrary(t, copied, 5000)
	faultDir := t.TempDir()
	instance := startServer(t, f, copied, serverOptions{roots: []string{library.root}, seam: true, faults: "transfer.authorized=panic", faultDir: faultDir})
	epub := instance.assets(t, f, library.bookIDs["epub"])[0]
	url := instance.mint(t, f, "alice-full", library.bookIDs["epub"], epub.ID)
	grant := strings.Split(url, "grant=")[1]
	if got := instance.do("GET", url, nil); got.status != 500 || !bytes.Contains(got.body, []byte("internal_error")) || bytes.Contains(got.body, []byte(grant)) || bytes.Contains(got.body, []byte("injected")) {
		t.Fatalf("a panic on a transfer: %d %s", got.status, got.body)
	}
	path := strings.Split(url, "?")[0]
	for _, target := range []string{
		url + "&grant=" + grant, path + "?gr%61nt=" + grant, path + "?grant=" + grant + "%", "/api/consumer/v1/nowhere?grant=" + grant, "/nowhere?x[grant]=" + grant + "&Grant=" + grant,
		strings.Replace(url, "/transfer?", "/elsewhere?", 1), path + "?grant=" + grant[:len(grant)-1], path + "?" + strings.Repeat("a", 5000),
	} {
		instance.do("GET", target, map[string]string{"Authorization": "Bearer " + grant, "Cookie": "session_id=" + grant})
		instance.do("HEAD", target, nil)
	}
	instance.assertNoSensitive(t, f, grant, "grant=", "gr%61nt", "Grant=", library.root, copied.database)
	lines := 0
	for _, line := range instance.logLines() {
		if line["msg"] == "request" {
			lines++
			for key := range line {
				switch key {
				case "time", "level", "msg", "method", "route", "status", "bytes", "duration_ms", "code":
				default:
					t.Fatalf("an unexpected field %q in the request log", key)
				}
			}
		}
	}
	if lines < 10 {
		t.Fatalf("only %d request lines were logged", lines)
	}
}

type privateGrant struct {
	Name   string `json:"name"`
	URL    string `json:"url"`
	Status int    `json:"status"`
	Code   string `json:"code"`
	SHA256 string `json:"sha256"`
}

func TestAReplacedOrRemovedAssetKillsItsGrantAndRailsAgreesAboutGoGrants(t *testing.T) {
	for _, f := range fixtures(t) {
		t.Run(f.name, func(t *testing.T) {
			copied := newRuntimeCopy(t, f)
			base, exported := t.TempDir(), os.Getenv("SHELFARR_HTTP_GO_ROWS_DIR")
			if exported != "" {
				base = filepath.Join(exported, f.name+"-private-library")
				if err := os.MkdirAll(base, 0o700); err != nil {
					t.Fatal(err)
				}
			}
			library := newPrivateLibraryIn(t, copied, base, 5000)
			instance := startServer(t, f, copied, serverOptions{roots: []string{library.root}})
			epub := instance.assets(t, f, library.bookIDs["epub"])[0]
			audio := instance.assets(t, f, library.bookIDs["audio"])[0]
			serial := instance.assets(t, f, library.bookIDs["serial"])[0]
			kept := instance.mint(t, f, "alice-full", library.bookIDs["epub"], epub.ID)
			replaced := instance.mint(t, f, "alice-full", library.bookIDs["audio"], audio.ID)
			removed := instance.mint(t, f, "alice-full", library.bookIDs["serial"], serial.ID)
			for _, url := range []string{kept, replaced, removed} {
				if got := instance.do("GET", url, nil); got.status != 200 {
					t.Fatalf("baseline %d", got.status)
				}
			}
			original, _ := os.ReadFile(library.files["epub"])
			successor := library.files["audio"] + ".successor"
			os.WriteFile(successor, pseudoRandom(77, 5000), 0o600)
			os.Rename(successor, library.files["audio"])
			execSQL(t, copied.database, `UPDATE books SET file_path = NULL WHERE id = ?`, library.bookIDs["serial"])
			expected := []privateGrant{
				{Name: "kept", URL: kept, Status: 200, SHA256: hexSum(original)},
				{Name: "replaced", URL: replaced, Status: 410, Code: "asset_unavailable"},
				{Name: "removed", URL: removed, Status: 404, Code: "not_found"},
			}
			for _, grant := range expected {
				for _, method := range []string{"GET", "HEAD"} {
					got := instance.do(method, grant.URL, nil)
					if got.status != grant.Status || method == "GET" && grant.Code != "" && !bytes.Contains(got.body, []byte(grant.Code)) || bytes.Contains(got.body, []byte(library.root)) {
						t.Errorf("%s %s: %d %s", method, grant.Name, got.status, got.body)
					}
				}
			}
			instance.stop()
			if exported == "" {
				return
			}
			database, err := sql.Open("sqlite", "file:"+copied.database)
			if err != nil {
				t.Fatal(err)
			}
			defer database.Close()
			if _, err := database.Exec(`PRAGMA wal_checkpoint(TRUNCATE)`); err != nil {
				t.Fatal(err)
			}
			data, _ := os.ReadFile(copied.database)
			encoded, _ := json.MarshalIndent(expected, "", " ")
			if os.WriteFile(filepath.Join(exported, f.name+"-private.sqlite3"), data, 0o600) != nil || os.WriteFile(filepath.Join(exported, f.name+"-private.json"), encoded, 0o600) != nil {
				t.Fatal("cannot export the private library")
			}
		})
	}
}

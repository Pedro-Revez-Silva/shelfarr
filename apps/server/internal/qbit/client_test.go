package qbit

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const wantedHash = "0123456789abcdef0123456789abcdef01234567"

type peer struct {
	*httptest.Server
	logins   atomic.Int32
	requests atomic.Int32
	session  atomic.Value
	issued   atomic.Value
	info     func(w http.ResponseWriter, r *http.Request)
}

func newPeer(t *testing.T, info func(w http.ResponseWriter, r *http.Request)) *peer {
	t.Helper()
	fake := &peer{info: info}
	fake.session.Store("SID=session-1")
	fake.issued.Store("session-1")
	mux := http.NewServeMux()
	mux.HandleFunc("/api/v2/auth/login", func(w http.ResponseWriter, r *http.Request) {
		fake.logins.Add(1)
		r.ParseForm()
		if r.Form.Get("username") != "operator" || r.Form.Get("password") != "synthetic-secret" {
			fmt.Fprint(w, "Fails.")
			return
		}
		http.SetCookie(w, &http.Cookie{Name: "SID", Value: fake.issued.Load().(string)})
		fmt.Fprint(w, "Ok.")
	})
	mux.HandleFunc("/api/v2/torrents/info", func(w http.ResponseWriter, r *http.Request) {
		fake.requests.Add(1)
		cookie, _ := r.Cookie("SID")
		if cookie == nil || "SID="+cookie.Value != fake.session.Load().(string) {
			w.WriteHeader(403)
			return
		}
		fake.info(w, r)
	})
	fake.Server = httptest.NewServer(mux)
	t.Cleanup(fake.Close)
	return fake
}

func connect(t *testing.T, fake *peer) *Client {
	t.Helper()
	built, err := NewClient(Config{BaseURL: fake.URL, Username: "operator", Password: "synthetic-secret", RequestTimeout: 2 * time.Second, MaxBytes: 1 << 16})
	if err != nil {
		t.Fatal(err)
	}
	return built
}

func torrentBody(extra string) string {
	return fmt.Sprintf(`[{"hash":"%s","name":"Book","progress":0.4249,"state":"downloading","size":1048576,"content_path":"/downloads/Book","save_path":"/downloads"%s}]`, strings.ToUpper(wantedHash), extra)
}

func TestTorrentParsesAProgressObservation(t *testing.T) {
	fake := newPeer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("hashes") != wantedHash {
			t.Errorf("query %s", r.URL.RawQuery)
		}
		fmt.Fprint(w, torrentBody(""))
	})
	torrent, err := connect(t, fake).Torrent(context.Background(), wantedHash)
	if err != nil {
		t.Fatal(err)
	}
	want := Torrent{Hash: wantedHash, Name: "Book", Progress: 42, State: Downloading, SizeBytes: 1048576, Path: "/downloads/Book"}
	if *torrent != want {
		t.Fatalf("got %+v", *torrent)
	}
}

func TestOnlyAnEmptyListIsNotFound(t *testing.T) {
	fake := newPeer(t, func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, "[]") })
	torrent, err := connect(t, fake).Torrent(context.Background(), wantedHash)
	if err != nil || torrent != nil {
		t.Fatalf("got %v %v", torrent, err)
	}
}

func TestEveryOtherAnswerIsAnErrorNeverNotFound(t *testing.T) {
	status := func(code int) func(http.ResponseWriter, *http.Request) {
		return func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(code) }
	}
	body := func(text string) func(http.ResponseWriter, *http.Request) {
		return func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, text) }
	}
	other := `"hash":"ffffffffffffffffffffffffffffffffffffffff"`
	cases := []struct {
		name    string
		handler func(http.ResponseWriter, *http.Request)
		code    string
	}{
		{"not found status", status(404), "http-status-404"},
		{"server error", status(500), "http-status-500"},
		{"bad gateway", status(502), "http-status-502"},
		{"redirect", func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, "http://127.0.0.1:1/", 302) }, "redirect-302"},
		{"garbage", body("<html>"), "malformed"},
		{"empty body", body(""), "malformed"},
		{"null", body("null"), "malformed"},
		{"object", body("{}"), "malformed"},
		{"trailing data", body("[] []"), "malformed"},
		{"two entries", body("[" + strings.Trim(torrentBody(""), "[]") + "," + strings.Trim(torrentBody(""), "[]") + "]"), "malformed"},
		{"different torrent", body(strings.Replace(torrentBody(""), `"hash":"`+strings.ToUpper(wantedHash)+`"`, other, 1)), "malformed"},
		{"progress above one", body(strings.Replace(torrentBody(""), "0.4249", "1.01", 1)), "malformed"},
		{"negative progress", body(strings.Replace(torrentBody(""), "0.4249", "-0.1", 1)), "malformed"},
		{"progress as text", body(strings.Replace(torrentBody(""), "0.4249", `"0.4"`, 1)), "malformed"},
		{"progress missing", body(strings.Replace(torrentBody(""), `"progress":0.4249,`, "", 1)), "malformed"},
		{"size negative", body(strings.Replace(torrentBody(""), "1048576", "-1", 1)), "malformed"},
		{"size fractional", body(strings.Replace(torrentBody(""), "1048576", "1.5", 1)), "malformed"},
		{"state missing", body(strings.Replace(torrentBody(""), `"state":"downloading",`, "", 1)), "malformed"},
		{"too large", body("[" + strings.Repeat(" ", 1<<17) + "]"), "too-large"},
	}
	for _, entry := range cases {
		t.Run(entry.name, func(t *testing.T) {
			fake := newPeer(t, entry.handler)
			torrent, err := connect(t, fake).Torrent(context.Background(), wantedHash)
			if err == nil || torrent != nil {
				t.Fatalf("accepted %v %v", torrent, err)
			}
			if got := CodeOf(err); got != entry.code {
				t.Fatalf("code %q want %q", got, entry.code)
			}
		})
	}
}

func TestStateClassificationFollowsTheRailsAdapter(t *testing.T) {
	want := map[string]Class{
		"downloading": Downloading, "forcedDL": Downloading, "metaDL": Downloading, "queuedDL": Downloading, "allocating": Downloading, "checkingDL": Downloading,
		"stalledDL": Paused, "pausedDL": Paused, "stoppedDL": Paused,
		"uploading": Completed, "forcedUP": Completed, "stalledUP": Completed, "queuedUP": Completed, "pausedUP": Completed, "stoppedUP": Completed, "checkingUP": Completed,
		"error": Failed, "missingFiles": Failed,
		"checkingResumeData": Queued, "moving": Queued, "unknown": Queued, "": Queued,
	}
	for state, class := range want {
		if got := classify(state); got != class {
			t.Errorf("%q: %q want %q", state, got, class)
		}
	}
}

func TestDownloadPathPrefersContentPath(t *testing.T) {
	cases := []struct{ extra, content, save, want string }{
		{"", "/d/Book", "/d", "/d/Book"},
		{"", "", "/d/", "/d/Book"},
		{"", "  ", "/d", "/d/Book"},
		{"", "", "", ""},
	}
	for _, entry := range cases {
		path := downloadPath(rawTorrent{Name: ptr("Book"), ContentPath: ptr(entry.content), SavePath: ptr(entry.save)})
		if path != entry.want {
			t.Errorf("%+v: %q", entry, path)
		}
	}
	if downloadPath(rawTorrent{Name: ptr("Book"), SavePath: ptr("/only")}) != "/only/Book" {
		t.Error("save path and name")
	}
	if downloadPath(rawTorrent{SavePath: ptr("/only")}) != "/only" {
		t.Error("save path alone")
	}
}

func ptr(text string) *string { return &text }

func TestSessionExpiryTriggersExactlyOneRelogin(t *testing.T) {
	fake := newPeer(t, func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, torrentBody("")) })
	client := connect(t, fake)
	if _, err := client.Torrent(context.Background(), wantedHash); err != nil {
		t.Fatal(err)
	}
	fake.session.Store("SID=session-2")
	fake.issued.Store("session-2")
	if _, err := client.Torrent(context.Background(), wantedHash); err != nil {
		t.Fatal(err)
	}
	if fake.logins.Load() != 2 || fake.requests.Load() != 3 {
		t.Fatalf("logins %d requests %d", fake.logins.Load(), fake.requests.Load())
	}
}

func TestPersistentAuthenticationFailureIsReportedAndRetriedOnlyOnce(t *testing.T) {
	fake := newPeer(t, func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, torrentBody("")) })
	fake.session.Store("SID=expected-by-the-server")
	client := connect(t, fake)
	_, err := client.Torrent(context.Background(), wantedHash)
	if CodeOf(err) != "auth-403" {
		t.Fatalf("got %v", err)
	}
	if fake.logins.Load() != 2 || fake.requests.Load() != 2 {
		t.Fatalf("logins %d requests %d", fake.logins.Load(), fake.requests.Load())
	}
}

func TestWrongCredentialsAreAnAuthenticationError(t *testing.T) {
	fake := newPeer(t, func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, torrentBody("")) })
	built, err := NewClient(Config{BaseURL: fake.URL, Username: "operator", Password: "wrong"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := built.Torrent(context.Background(), wantedHash); CodeOf(err) != "auth" {
		t.Fatalf("got %v", err)
	}
	if fake.requests.Load() != 0 {
		t.Fatal("queried without a session")
	}
}

func TestAPIKeyIsSentAsBearerWithoutLogin(t *testing.T) {
	key := apiKeyPrefix + strings.Repeat("k", apiKeyLength-len(apiKeyPrefix))
	var seen string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = r.Header.Get("Authorization")
		fmt.Fprint(w, torrentBody(""))
	}))
	defer server.Close()
	built, err := NewClient(Config{BaseURL: server.URL, APIKey: key})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := built.Torrent(context.Background(), wantedHash); err != nil || seen != "Bearer "+key {
		t.Fatalf("%v %q", err, seen)
	}
}

func TestInvalidHashIsRefusedBeforeAnyRequest(t *testing.T) {
	fake := newPeer(t, func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, "[]") })
	for _, hash := range []string{"", "abc", wantedHash + "0", "g" + wantedHash[1:], wantedHash + "|" + wantedHash} {
		if _, err := connect(t, fake).Torrent(context.Background(), hash); CodeOf(err) != CodeInvalidHash {
			t.Errorf("%q: %v", hash, err)
		}
	}
	if fake.logins.Load()+fake.requests.Load() != 0 {
		t.Fatal("network used")
	}
}

func TestHungClientIsCancelledAndBounded(t *testing.T) {
	released := make(chan struct{})
	reached := make(chan struct{}, 4)
	fake := newPeer(t, func(w http.ResponseWriter, r *http.Request) {
		reached <- struct{}{}
		select {
		case <-released:
		case <-r.Context().Done():
		}
	})
	defer close(released)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, err := connect(t, fake).Torrent(ctx, wantedHash)
		done <- err
	}()
	<-reached
	cancel()
	if err := <-done; CodeOf(err) != CodeCancelled {
		t.Fatalf("got %v", err)
	}
	built, err := NewClient(Config{BaseURL: fake.URL, Username: "operator", Password: "synthetic-secret", RequestTimeout: 100 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := built.Torrent(context.Background(), wantedHash); CodeOf(err) != CodeConnection {
		t.Fatalf("got %v", err)
	}
}

func TestClientOnlyTalksToLoopbackAndRefusesBadConfiguration(t *testing.T) {
	built, err := NewClient(Config{BaseURL: "http://192.0.2.1:9", Username: "u", Password: "p", RequestTimeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := built.Torrent(context.Background(), wantedHash); CodeOf(err) != CodeDestination {
		t.Fatalf("got %v", err)
	}
	for _, config := range []Config{{BaseURL: "", Username: "u"}, {BaseURL: "gopher://127.0.0.1", Username: "u"}, {BaseURL: "http://127.0.0.1"}, {BaseURL: "http://127.0.0.1", APIKey: "qbt_short"}} {
		if _, err := NewClient(config); CodeOf(err) != CodeConfig {
			t.Errorf("%+v: %v", config, err)
		}
	}
}

func TestBaseURLWithASubpathIsKept(t *testing.T) {
	var path string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path = r.URL.Path
		if strings.HasSuffix(path, "/auth/login") {
			http.SetCookie(w, &http.Cookie{Name: "SID", Value: "x"})
			fmt.Fprint(w, "Ok.")
			return
		}
		fmt.Fprint(w, "[]")
	}))
	defer server.Close()
	built, err := NewClient(Config{BaseURL: server.URL + "/qbt/", Username: "u", Password: "p"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := built.Torrent(context.Background(), wantedHash); err != nil || path != "/qbt/api/v2/torrents/info" {
		t.Fatalf("%v %q", err, path)
	}
}

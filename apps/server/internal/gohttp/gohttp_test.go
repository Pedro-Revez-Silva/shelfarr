//go:build linux

package gohttp

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/account"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/library"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/live"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/livetest"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
)

const (
	testSecret = "unit-test-secret-key-base-unit-test-secret-key-base"
	rawToken   = "unit-test-bearer-token-value"
)

type harness struct {
	t      *testing.T
	app    *App
	path   string
	root   string
	logs   *buffer
	config Config
}

type buffer struct {
	mutex sync.Mutex
	data  bytes.Buffer
}

func (b *buffer) Write(data []byte) (int, error) {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	return b.data.Write(data)
}

func (b *buffer) String() string {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	return b.data.String()
}

func newHarness(t *testing.T, adjust func(*Config)) *harness {
	t.Helper()
	path := livetest.Create(t)
	base, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(base, "library")
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"audiobook_output_path", "ebook_output_path", "comicbook_output_path"} {
		livetest.Exec(t, path, `INSERT INTO settings (key, value) VALUES (?, ?)`, key, root)
	}
	livetest.Exec(t, path, `INSERT INTO users (id, username, name) VALUES (1, 'alice', 'Alice')`)
	livetest.Exec(t, path, `INSERT INTO api_tokens (id, user_id, token_digest, scopes) VALUES (1, 1, ?, '["library:read"]')`, account.TokenDigest(rawToken))
	config := Config{DatabasePath: path, LockPath: filepath.Join(base, "domain.lock"), LibraryRoots: []string{root}, SecretKeyBase: testSecret, Listen: "127.0.0.1:0", RequestTimeout: 5 * time.Second}
	if adjust != nil {
		adjust(&config)
	}
	database, err := live.Open(context.Background(), path, live.Options{BusyTimeout: 200 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { database.Close() })
	logs := &buffer{}
	app, err := NewApp(config, database, []string{root}, slog.New(slog.NewJSONHandler(logs, nil)), time.Now)
	if err != nil {
		t.Fatal(err)
	}
	return &harness{t: t, app: app, path: path, root: root, logs: logs, config: config}
}

func (h *harness) do(method, target string, headers map[string]string) *httptest.ResponseRecorder {
	h.t.Helper()
	request := httptest.NewRequest(method, target, nil)
	for name, value := range headers {
		request.Header.Set(name, value)
	}
	recorder := httptest.NewRecorder()
	h.app.ServeHTTP(recorder, request)
	return recorder
}

func authorised() map[string]string { return map[string]string{"Authorization": "Bearer " + rawToken} }

func (h *harness) addBook(id int, title string, bookType int, path string) {
	h.t.Helper()
	livetest.Exec(h.t, h.path, `INSERT INTO books (id, title, book_type, file_path) VALUES (?, ?, ?, ?)`, id, title, bookType, path)
}

func (h *harness) file(name, content string) string {
	h.t.Helper()
	path := filepath.Join(h.root, name)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		h.t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		h.t.Fatal(err)
	}
	return path
}

func errorCode(t *testing.T, recorder *httptest.ResponseRecorder) string {
	t.Helper()
	var body struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatalf("not an error body: %q", recorder.Body.String())
	}
	return body.Error
}

func TestEveryDeclaredExcludedRouteIsRefusedBeforeAnyAuthenticationOrWrite(t *testing.T) {
	h := newHarness(t, nil)
	for _, excluded := range ExcludedRoutes {
		path := apiPrefix + strings.NewReplacer("{id}", "1", "{asset}", strings.Repeat("a", 64), "{audio}", strings.Repeat("b", 64), "{path...}", "OEBPS/chapter.xhtml").Replace(excluded.Pattern)
		recorder := h.do(excluded.Method, path, authorised())
		if recorder.Code != http.StatusNotImplemented || errorCode(t, recorder) != "not_implemented_in_go_runtime" {
			t.Errorf("%s %s: %d %s", excluded.Method, excluded.Pattern, recorder.Code, recorder.Body.String())
		}
	}
	if used := livetest.Query(t, h.path, `SELECT last_used_at FROM api_tokens WHERE id = 1`)[0][0]; used != nil {
		t.Fatalf("an excluded route touched the credential: %v", used)
	}
}

func TestUnknownPathsAndWrongVerbsAreNotServed(t *testing.T) {
	h := newHarness(t, nil)
	for _, target := range []string{"/", "/read", "/preview/api/v1/session", "/api/v1/requests", "/api/consumer/v2/me", "/api/consumer/v1/", "/api/consumer/v1/me/", "/api/consumer/v1/me.json", "/api/consumer/v1/library/1.json", "/api/consumer/v1/library/1/assets/x.mp3", "/api/consumer/v1/server", "/api/consumer/v1/library/1/assets", "/api/consumer/v1/kobo/x"} {
		if recorder := h.do(http.MethodGet, target, authorised()); recorder.Code != http.StatusNotFound {
			t.Errorf("GET %s: %d", target, recorder.Code)
		}
	}
	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		recorder := h.do(method, "/api/consumer/v1/me", authorised())
		if recorder.Code != http.StatusMethodNotAllowed || recorder.Header().Get("Allow") != "GET, HEAD" {
			t.Errorf("%s: %d %s", method, recorder.Code, recorder.Header().Get("Allow"))
		}
	}
	if used := livetest.Query(t, h.path, `SELECT last_used_at FROM api_tokens WHERE id = 1`)[0][0]; used != nil {
		t.Fatal("a refused request touched the credential")
	}
}

func TestCookiesNeverAuthenticateABearerOnlyRoute(t *testing.T) {
	h := newHarness(t, nil)
	headers := map[string]string{"Cookie": "session_id=abc; _shelfarr_session=" + rawToken, "X-CSRF-Token": rawToken}
	for _, target := range []string{"/api/consumer/v1/me", "/api/consumer/v1/library", "/api/consumer/v1/continue"} {
		if recorder := h.do(http.MethodGet, target, headers); recorder.Code != http.StatusUnauthorized {
			t.Errorf("%s: %d", target, recorder.Code)
		}
	}
	if recorder := h.do(http.MethodGet, "/api/consumer/v1/me", map[string]string{"Authorization": "Bearer " + rawToken, "Cookie": "x=y"}); recorder.Code != http.StatusOK {
		t.Fatalf("a bearer must work next to unrelated cookies: %d", recorder.Code)
	}
}

func TestPublicServerDocumentReadsNoCredentialAndAdmitsWhatThisRuntimeLacks(t *testing.T) {
	h := newHarness(t, func(c *Config) { c.AndroidChannels = []string{"release", "development"}; c.ServerVersion = "1.2.3" })
	recorder := h.do(http.MethodGet, "/api/consumer/v1/server.json", map[string]string{"Authorization": "Bearer wrong"})
	var body map[string]any
	if recorder.Code != 200 || json.Unmarshal(recorder.Body.Bytes(), &body) != nil {
		t.Fatalf("%d %s", recorder.Code, recorder.Body.String())
	}
	if body["server_version"] != "1.2.3" || len(body["consumer_features"].([]any)) != 0 || len(body["reader_features"].([]any)) != 0 || fmt.Sprint(body["reader_formats"]) != "[cbz epub pdf]" {
		t.Fatalf("capabilities overstated: %v", body)
	}
	android := body["android"].(map[string]any)
	if android["development"].(map[string]any)["download_page_url"] != "/apps/android?channel=development" || android["release"].(map[string]any)["feed_url"] != "/apps/android/release.json" {
		t.Fatalf("%v", android)
	}
	if recorder.Header().Get("Cache-Control") != "no-cache" {
		t.Fatal("server.json is revalidated, not stored")
	}
}

func TestSecretsAndTokensNeverAppearInLogsOrTheCapabilityPathsDoNot(t *testing.T) {
	h := newHarness(t, nil)
	path := h.file("Book.epub", "content")
	h.addBook(1, "Book", store.BookTypeEbook, path)
	var identifier string
	var listing struct {
		Items []struct {
			Assets []struct {
				ID string `json:"id"`
			} `json:"assets"`
		} `json:"items"`
	}
	recorder := h.do(http.MethodGet, "/api/consumer/v1/library", authorised())
	if err := json.Unmarshal(recorder.Body.Bytes(), &listing); err != nil || len(listing.Items) != 1 || len(listing.Items[0].Assets) != 1 {
		t.Fatalf("%d %s", recorder.Code, recorder.Body.String())
	}
	identifier = listing.Items[0].Assets[0].ID
	h.do(http.MethodGet, "/api/consumer/v1/library/1/assets/"+identifier, authorised())
	h.do(http.MethodGet, "/api/consumer/v1/library?q=secret-search-term&cursor=abc", authorised())
	h.do(http.MethodGet, "/api/consumer/v1/me", map[string]string{"Authorization": "Bearer " + rawToken + "-wrong"})
	logged := h.logs.String()
	for _, sensitive := range []string{rawToken, identifier, "secret-search-term", testSecret, h.root, h.path, "Authorization", "Bearer", "Book.epub", "cursor"} {
		if strings.Contains(logged, sensitive) {
			t.Errorf("the log leaks %q", sensitive)
		}
	}
	if !strings.Contains(logged, `"route":"asset"`) || !strings.Contains(logged, `"status":200`) {
		t.Fatalf("requests are not logged at all: %s", logged)
	}
}

func TestAReplacedFileIsNeverServedUnderTheOldIdentity(t *testing.T) {
	h := newHarness(t, nil)
	path := h.file("Book.epub", "original")
	h.addBook(1, "Book", store.BookTypeEbook, path)
	book := store.Book{ID: 1, FilePath: sql.NullString{String: path, Valid: true}, BookType: store.BookTypeEbook}
	listing, err := library.Lister{Roots: []string{h.root}}.List(context.Background(), book, path)
	if err != nil || len(listing.Assets) != 1 {
		t.Fatalf("%v %v", listing, err)
	}
	asset := listing.Assets[0]
	if file, err := openVerified(book, asset); err != nil {
		t.Fatalf("the unchanged file must open: %v", err)
	} else {
		file.Close()
	}
	replacement := filepath.Join(h.root, "replacement")
	if err := os.WriteFile(replacement, []byte("original"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(replacement, path); err != nil {
		t.Fatal(err)
	}
	if file, err := openVerified(book, asset); !errors.Is(err, errAssetChanged) {
		if file != nil {
			file.Close()
		}
		t.Fatalf("a replacement with identical bytes was served under the old identity: %v", err)
	}
}

func TestAnUnchangedPathWithRewrittenContentChangesTheIdentity(t *testing.T) {
	h := newHarness(t, nil)
	path := h.file("Book.epub", "original")
	book := store.Book{ID: 1, FilePath: sql.NullString{String: path, Valid: true}, BookType: store.BookTypeEbook}
	before, _ := library.Lister{Roots: []string{h.root}}.List(context.Background(), book, path)
	time.Sleep(10 * time.Millisecond)
	if err := os.WriteFile(path, []byte("rewritten content"), 0o600); err != nil {
		t.Fatal(err)
	}
	after, _ := library.Lister{Roots: []string{h.root}}.List(context.Background(), book, path)
	if before.Assets[0].ID == after.Assets[0].ID {
		t.Fatal("rewriting a file kept its asset identity")
	}
	if file, err := openVerified(book, before.Assets[0]); !errors.Is(err, errAssetChanged) {
		if file != nil {
			file.Close()
		}
		t.Fatalf("stale identity was served: %v", err)
	}
}

func TestMetadataAndMediaHaveSeparateBoundedCapacity(t *testing.T) {
	h := newHarness(t, func(c *Config) { c.MaxMetadataRequests = 1; c.MaxMediaStreams = 1 })
	h.app.metadata <- struct{}{}
	if recorder := h.do(http.MethodGet, "/api/consumer/v1/me", authorised()); recorder.Code != http.StatusServiceUnavailable || errorCode(t, recorder) != "server_busy" || recorder.Header().Get("Retry-After") == "" {
		t.Fatalf("%d %s", recorder.Code, recorder.Body.String())
	}
	if recorder := h.do(http.MethodGet, "/api/consumer/v1/library/1/assets/"+strings.Repeat("a", 64), authorised()); recorder.Code == http.StatusServiceUnavailable {
		t.Fatal("a saturated metadata pool must not block media")
	}
	<-h.app.metadata
	h.app.streams <- struct{}{}
	if recorder := h.do(http.MethodGet, "/api/consumer/v1/me", authorised()); recorder.Code != http.StatusOK {
		t.Fatalf("a saturated media pool blocked metadata: %d", recorder.Code)
	}
	if recorder := h.do(http.MethodGet, "/api/consumer/v1/library/1/assets/"+strings.Repeat("a", 64), authorised()); recorder.Code != http.StatusServiceUnavailable {
		t.Fatalf("media capacity is not bounded: %d", recorder.Code)
	}
}

func TestAPanicBecomesAGenericErrorWithoutLeakingItsCause(t *testing.T) {
	h := newHarness(t, nil)
	h.app.db = nil
	recorder := h.do(http.MethodGet, "/readyz", nil)
	if recorder.Code != http.StatusInternalServerError || errorCode(t, recorder) != "internal_error" || strings.Contains(recorder.Body.String(), "nil") {
		t.Fatalf("%d %s", recorder.Code, recorder.Body.String())
	}
}

func TestAStalledMediaClientIsDroppedAndItsSlotReturned(t *testing.T) {
	h := newHarness(t, func(c *Config) { c.MaxMediaStreams = 1; c.StreamWriteStall = 300 * time.Millisecond })
	path := h.file("Big.mp3", strings.Repeat("0123456789abcdef", 4<<20))
	h.addBook(1, "Big", store.BookTypeAudiobook, path)
	var listing struct {
		Items []struct {
			Assets []struct{ ID string } `json:"assets"`
		} `json:"items"`
	}
	json.Unmarshal(h.do(http.MethodGet, "/api/consumer/v1/library", authorised()).Body.Bytes(), &listing)
	target := "/api/consumer/v1/library/1/assets/" + listing.Items[0].Assets[0].ID
	server := httptest.NewUnstartedServer(h.app)
	server.Config.WriteTimeout = 0
	server.Start()
	defer server.Close()
	connection, err := net.Dial("tcp", server.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	if tcp, ok := connection.(*net.TCPConn); ok {
		tcp.SetReadBuffer(4096)
	}
	io.WriteString(connection, "GET "+target+" HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer "+rawToken+"\r\n\r\n")
	deadline := time.Now().Add(5 * time.Second)
	for len(h.app.streams) == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if len(h.app.streams) != 1 {
		t.Fatal("the stream never started")
	}
	if recorder := h.do(http.MethodGet, "/api/consumer/v1/me", authorised()); recorder.Code != http.StatusOK {
		t.Fatalf("metadata blocked by a stalled stream: %d", recorder.Code)
	}
	for len(h.app.streams) != 0 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if len(h.app.streams) != 0 {
		t.Fatal("a stalled client held its media slot forever")
	}
}

func TestAClientThatNeverReadsAMetadataResponseDoesNotHoldItsSlot(t *testing.T) {
	h := newHarness(t, func(c *Config) { c.MaxMetadataRequests = 1; c.RequestTimeout = 600 * time.Millisecond })
	description := strings.Repeat("日", 20_000)
	for id := 1; id <= 50; id++ {
		livetest.Exec(t, h.path, `INSERT INTO books (id, title, description, book_type, file_path) VALUES (?, 'Heavy', ?, 1, ?)`, id, description, filepath.Join(h.root, "absent.epub"))
	}
	server := httptest.NewUnstartedServer(nil)
	server.Config = newServer(h.app, h.config)
	server.Config.ConnState = func(connection net.Conn, state http.ConnState) {
		if tcp, ok := connection.(*net.TCPConn); ok && state == http.StateNew {
			tcp.SetWriteBuffer(4096)
		}
	}
	server.Start()
	defer server.Close()
	connection, err := net.Dial("tcp", server.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	connection.(*net.TCPConn).SetReadBuffer(2048)
	io.WriteString(connection, "GET /api/consumer/v1/library?limit=50 HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer "+rawToken+"\r\n\r\n")
	deadline := time.Now().Add(10 * time.Second)
	for len(h.app.metadata) == 0 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if len(h.app.metadata) == 0 {
		t.Fatal("the request never held a slot")
	}
	time.Sleep(200 * time.Millisecond)
	if len(h.app.metadata) == 0 {
		t.Fatal("the response was not blocked on the client, so the test proves nothing")
	}
	for len(h.app.metadata) != 0 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if len(h.app.metadata) != 0 {
		t.Fatal("a client that never reads kept its metadata slot")
	}
}

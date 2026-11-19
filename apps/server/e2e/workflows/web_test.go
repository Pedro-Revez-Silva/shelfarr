//go:build e2e

package workflows

import (
	"archive/zip"
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"hash/crc32"
	"io"
	"net"
	"net/http"
	"net/http/cookiejar"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"
)

const (
	webAssetsEnvironment = "SHELFARR_GO_WEB_ASSETS"
	prideWork            = "OL9001W"
	zombieWork           = "OL9002W"
	memberPassword       = "Member-Password-1x"
	adminPassword        = "Admin-Password-1x"
	openLibraryAnswer    = `{"numFound":2,"start":0,"docs":[` +
		`{"key":"/works/OL9001W","title":"Pride and Prejudice","author_name":["Jane Austen"],"first_publish_year":1813,"edition_count":3},` +
		`{"key":"/works/OL9002W","title":"Pride and Prejudice and Zombies","author_name":["Seth Grahame-Smith"],"first_publish_year":2009,"edition_count":2}]}`
)

var (
	clockBuild   sync.Once
	clockBinary  string
	clockError   error
	assetsBuild  sync.Once
	assetsDir    string
	assetsError  error
	fakeBuild    sync.Once
	fakeBinary   string
	fakeError    error
	readyAddress = `"address":"`
)

func buildOnce(t *testing.T, once *sync.Once, binary *string, failure *error, name string, arguments ...string) string {
	t.Helper()
	once.Do(func() {
		*binary = filepath.Join(buildScratch, name)
		command := exec.Command("go", append(append([]string{"build", "-trimpath", "-o", *binary}, arguments[:len(arguments)-1]...), arguments[len(arguments)-1])...)
		command.Dir = "../.."
		command.Env = append(os.Environ(), "CGO_ENABLED=0")
		if output, err := command.CombinedOutput(); err != nil {
			*failure = err
			*binary = string(output)
		}
	})
	if *failure != nil {
		t.Fatalf("building %s: %v %s", name, *failure, *binary)
	}
	return *binary
}

func httpClockBinary(t *testing.T) string {
	return buildOnce(t, &clockBuild, &clockBinary, &clockError, "shelfarr-http-clock", "-tags", "e2eclock", "./cmd/shelfarr-http")
}

func fakeOpenLibraryBinary(t *testing.T) string {
	return buildOnce(t, &fakeBuild, &fakeBinary, &fakeError, "fake-openlibrary", "-tags", "e2e", "./e2e/fakeopenlibrary")
}

func goWebAssets(t *testing.T) string {
	t.Helper()
	if prepared := os.Getenv(webAssetsEnvironment); prepared != "" {
		return prepared
	}
	assetsBuild.Do(func() {
		assetsDir = filepath.Join(buildScratch, "web-assets")
		command := exec.Command("bun", "run", "build-go.ts", "--out", assetsDir)
		command.Dir = "../../../web"
		if output, err := command.CombinedOutput(); err != nil {
			assetsError = err
			assetsDir = string(output)
		}
	})
	if assetsError != nil {
		t.Fatalf("building the Go web assets: %v %s", assetsError, assetsDir)
	}
	return assetsDir
}

type fakeOpenLibrary struct {
	proxy   string
	direct  string
	ca      string
	journal string
}

func startFakeOpenLibrary(t *testing.T) fakeOpenLibrary {
	t.Helper()
	dir := t.TempDir()
	answer := filepath.Join(dir, "search.json")
	if err := os.WriteFile(answer, []byte(openLibraryAnswer), 0o600); err != nil {
		t.Fatal(err)
	}
	command := exec.Command(fakeOpenLibraryBinary(t), "-dir", dir, "-response", answer)
	stdout, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		command.Process.Signal(syscall.SIGTERM)
		command.Wait()
	})
	line, err := bufio.NewReader(stdout).ReadString('\n')
	if err != nil {
		t.Fatalf("fake Open Library did not start: %v", err)
	}
	var ready fakeOpenLibrary
	var fields map[string]string
	if err := json.Unmarshal([]byte(line), &fields); err != nil {
		t.Fatal(err)
	}
	ready.proxy, ready.direct, ready.ca, ready.journal = fields["proxy"], fields["direct"], fields["ca"], fields["journal"]
	return ready
}

func (f fakeOpenLibrary) entries(t *testing.T) []map[string]any {
	t.Helper()
	data, err := os.ReadFile(f.journal)
	if err != nil {
		t.Fatal(err)
	}
	var found []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if line == "" {
			continue
		}
		var entry map[string]any
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Fatal(err)
		}
		found = append(found, entry)
	}
	return found
}

type webVolume struct {
	*searchSetup
	library  string
	roots    []string
	epub     []byte
	clock    string
	secret   string
	openLib  fakeOpenLibrary
	runtimes string
}

func freeLoopbackPort(t *testing.T) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	return listener.Addr().String()
}

func hashed(t *testing.T, password string) string {
	t.Helper()
	digest, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.MinCost)
	if err != nil {
		t.Fatal(err)
	}
	return string(digest)
}

func newWebVolume(t *testing.T, bundle string) *webVolume {
	t.Helper()
	volume := &webVolume{searchSetup: newSearchSetup(t, bundle), epub: syntheticEPUB(t, "It is a truth universally acknowledged.")}
	volume.disableCustomProviders(t)
	volume.library = filepath.Join(volume.w.dir, "library")
	if err := os.Mkdir(volume.library, 0o755); err != nil {
		t.Fatal(err)
	}
	putSetting(t, volume.db, "ebook_output_path", "string", volume.library)
	volume.roots = []string{volume.library}
	for _, key := range []string{"audiobook_output_path", "comicbook_output_path"} {
		var root sql.NullString
		volume.db.QueryRow(`SELECT value FROM settings WHERE key = ?`, key).Scan(&root)
		if root.Valid && root.String != "" && !strings.HasPrefix(root.String, volume.library) {
			volume.roots = append(volume.roots, root.String)
		}
	}
	exec1(t, volume.db, `UPDATE users SET otp_required = 0, otp_secret = NULL, password_digest = ?, failed_login_count = 0, locked_until = NULL WHERE username = 'alice'`, hashed(t, adminPassword))
	exec1(t, volume.db, `UPDATE users SET otp_required = 0, otp_secret = NULL, password_digest = ?, failed_login_count = 0, locked_until = NULL WHERE username = 'bob'`, hashed(t, memberPassword))
	if role := scalar[int64](t, volume.db, `SELECT role FROM users WHERE username = 'alice'`); role != 1 {
		t.Fatalf("alice is expected to be the fixture admin, role %d", role)
	}
	volume.serveBook(volume.epub)
	volume.runtimes = t.TempDir()
	volume.clock = filepath.Join(volume.runtimes, "clock")
	volume.setClock(t, time.Now().UTC())
	secret := make([]byte, 32)
	rand.Read(secret)
	volume.secret = filepath.Join(volume.runtimes, "secret")
	if err := os.WriteFile(volume.secret, []byte(hex.EncodeToString(secret)), 0o600); err != nil {
		t.Fatal(err)
	}
	volume.openLib = startFakeOpenLibrary(t)
	return volume
}

func (v *webVolume) serveBook(body []byte) {
	v.fake.set(reply{Path: bookLink, Status: 200, Body: string(body), ContentType: epubType})
}

func (v *webVolume) setClock(t *testing.T, moment time.Time) {
	t.Helper()
	if err := os.WriteFile(v.clock, []byte(moment.Format(time.RFC3339Nano)), 0o600); err != nil {
		t.Fatal(err)
	}
}

func (v *webVolume) advance(t *testing.T, by time.Duration) {
	t.Helper()
	data, err := os.ReadFile(v.clock)
	if err != nil {
		t.Fatal(err)
	}
	moment, err := time.Parse(time.RFC3339Nano, string(data))
	if err != nil {
		t.Fatal(err)
	}
	v.setClock(t, moment.Add(by))
}

type webServer struct {
	t       *testing.T
	volume  *webVolume
	base    string
	origin  string
	command *exec.Cmd
	mutex   sync.Mutex
	log     bytes.Buffer
	done    chan struct{}
	code    int
}

type serverChange func(arguments []string, environment []string) ([]string, []string)

func (v *webVolume) arguments(listen string) []string {
	arguments := []string{"-experimental", "-database", v.w.database(), "-lock-file", filepath.Join(v.w.dir, "locks", "http.lock"),
		"-listen", listen, "-browser-origin", "http://" + listen, "-preview-user-ids", itoa(v.users["alice"]) + "," + itoa(v.users["bob"]),
		"-open-library-search", "-acquisition-workdir", v.w.dir, "-acquisition-open-library-address", v.openLib.direct, "-server-version", "e2e"}
	for _, root := range v.roots {
		arguments = append(arguments, "-library-root", root)
	}
	return arguments
}

func (v *webVolume) environment() []string {
	return []string{"PATH=" + os.Getenv("PATH"), "SECRET_KEY_BASE_FILE=" + v.secret, "SHELFARR_E2E_CLOCK_FILE=" + v.clock,
		"HTTPS_PROXY=http://127.0.0.1:9", "SSL_CERT_FILE=" + v.openLib.ca}
}

func (v *webVolume) launch(t *testing.T, changes ...serverChange) *webServer {
	t.Helper()
	listen := freeLoopbackPort(t)
	arguments, environment := append(v.arguments(listen), "-web-assets-dir", goWebAssets(t)), v.environment()
	for _, change := range changes {
		arguments, environment = change(arguments, environment)
	}
	server := &webServer{t: t, volume: v, base: "http://" + listen, origin: "http://" + listen, done: make(chan struct{})}
	server.command = exec.Command(httpClockBinary(t), arguments...)
	server.command.Env = environment
	stderr, err := server.command.StderrPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := server.command.Start(); err != nil {
		t.Fatal(err)
	}
	ready := make(chan struct{}, 1)
	go func() {
		scanner := bufio.NewScanner(stderr)
		scanner.Buffer(make([]byte, 64<<10), 1<<20)
		for scanner.Scan() {
			server.mutex.Lock()
			server.log.WriteString(scanner.Text() + "\n")
			server.mutex.Unlock()
			if strings.Contains(scanner.Text(), readyAddress) {
				select {
				case ready <- struct{}{}:
				default:
				}
			}
		}
		server.code = exitCode(server.command.Wait())
		close(server.done)
	}()
	t.Cleanup(func() { server.stop() })
	select {
	case <-ready:
	case <-server.done:
	case <-time.After(30 * time.Second):
		t.Fatalf("shelfarr-http did not start: %s", server.output())
	}
	return server
}

func exitCode(err error) int {
	if err == nil {
		return 0
	}
	if exit, ok := err.(*exec.ExitError); ok {
		return exit.ExitCode()
	}
	return -1
}

func (s *webServer) output() string {
	s.mutex.Lock()
	defer s.mutex.Unlock()
	return s.log.String()
}

func (s *webServer) exited() (int, bool) {
	select {
	case <-s.done:
		return s.code, true
	case <-time.After(10 * time.Second):
		return 0, false
	}
}

func (s *webServer) stop() {
	select {
	case <-s.done:
		return
	default:
	}
	s.command.Process.Signal(syscall.SIGTERM)
	select {
	case <-s.done:
	case <-time.After(40 * time.Second):
		s.command.Process.Kill()
		<-s.done
	}
}

func (s *webServer) kill() {
	s.command.Process.Kill()
	<-s.done
}

type webClient struct {
	t       *testing.T
	server  *webServer
	client  *http.Client
	account string
	token   string
}

type answer struct {
	status  int
	headers http.Header
	body    []byte
}

func (a answer) json(t *testing.T) map[string]any {
	t.Helper()
	var decoded map[string]any
	if err := json.Unmarshal(a.body, &decoded); err != nil {
		t.Fatalf("not JSON (%d): %s", a.status, a.body)
	}
	return decoded
}

func (a answer) code(t *testing.T) string {
	t.Helper()
	value, _ := a.json(t)["error"].(string)
	return value
}

func (s *webServer) browser() *webClient {
	jar, _ := cookiejar.New(nil)
	return &webClient{t: s.t, server: s, client: &http.Client{Jar: jar, Timeout: 30 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}
}

func (c *webClient) send(ctx context.Context, method, path string, headers map[string]string, body string) (answer, error) {
	var reader io.Reader
	if body != "" {
		reader = strings.NewReader(body)
	}
	request, err := http.NewRequestWithContext(ctx, method, c.server.base+path, reader)
	if err != nil {
		return answer{}, err
	}
	request.Header.Set("Accept", "application/json")
	if body != "" {
		request.Header.Set("Content-Type", "application/json")
	}
	for name, value := range headers {
		request.Header.Set(name, value)
	}
	response, err := c.client.Do(request)
	if err != nil {
		return answer{}, err
	}
	defer response.Body.Close()
	received, err := io.ReadAll(response.Body)
	return answer{status: response.StatusCode, headers: response.Header, body: received}, err
}

func (c *webClient) do(method, path string, headers map[string]string, body string) answer {
	c.t.Helper()
	found, err := c.send(context.Background(), method, path, headers, body)
	if err != nil {
		c.t.Fatalf("%s %s: %v\n%s", method, path, err, c.server.output())
	}
	return found
}

func (c *webClient) signIn(username, password string) *webClient {
	c.t.Helper()
	pre := c.do("GET", "/preview/api/v1/auth/bootstrap", nil, "")
	token, _ := pre.json(c.t)["csrf_token"].(string)
	payload, _ := json.Marshal(map[string]string{"username": username, "password": password})
	signed := c.do("POST", "/preview/api/v1/auth/login", map[string]string{"Origin": c.server.origin, "X-CSRF-Token": token}, string(payload))
	if signed.status != http.StatusOK {
		c.t.Fatalf("sign-in of %s answered %d %s", username, signed.status, signed.body)
	}
	body := signed.json(c.t)
	c.account, c.token = body["account"].(string), body["csrf_token"].(string)
	return c
}

func (c *webClient) get(path string) answer {
	c.t.Helper()
	return c.do("GET", path, map[string]string{"X-Shelfarr-Account": c.account}, "")
}

func (c *webClient) writeHeaders() map[string]string {
	return map[string]string{"X-Shelfarr-Account": c.account, "Origin": c.server.origin, "X-CSRF-Token": c.token}
}

func (c *webClient) post(path, body string) answer {
	c.t.Helper()
	return c.do("POST", path, c.writeHeaders(), body)
}

func (c *webClient) discover(query string) answer {
	c.t.Helper()
	c.server.volume.advance(c.t, 2*time.Second)
	return c.get("/preview/api/v1/discover?q=" + query)
}

func requestBody(work string) string {
	return `{"work_id":"` + work + `","book_type":"ebook"}`
}

func (c *webClient) request(work string) answer {
	c.t.Helper()
	return c.post("/preview/api/v1/requests", requestBody(work))
}

func waitFor(t *testing.T, what string, limit time.Duration, check func() bool) {
	t.Helper()
	deadline := time.Now().Add(limit)
	for !check() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func (v *webVolume) requestState(t *testing.T, id int64) (int64, string) {
	t.Helper()
	var status int64
	var issue sql.NullString
	if err := v.db.QueryRow(`SELECT status, issue_description FROM requests WHERE id = ?`, id).Scan(&status, &issue); err != nil {
		t.Fatal(err)
	}
	return status, issue.String
}

func (v *webVolume) awaitCandidates(t *testing.T, id int64) {
	t.Helper()
	waitFor(t, "the worker to publish candidates", 30*time.Second, func() bool {
		status, issue := v.requestState(t, id)
		return status == 1 && issue == selectionMessage
	})
}

func idOf(t *testing.T, value any) int64 {
	t.Helper()
	text, _ := value.(string)
	id, err := strconv.ParseInt(text, 10, 64)
	if err != nil || id <= 0 {
		t.Fatalf("not an id: %v", value)
	}
	return id
}

func keysOf(value map[string]any) []string {
	var keys []string
	for key := range value {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func unprepared(t *testing.T, volume *webVolume) serverChange {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "copy")
	if err := os.MkdirAll(filepath.Join(dir, "locks"), 0o700); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(volume.w.database())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "workflows.sqlite3"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	return func(arguments, environment []string) ([]string, []string) {
		changed := append([]string{}, arguments...)
		for index := range changed {
			switch changed[index] {
			case "-database":
				changed[index+1] = filepath.Join(dir, "workflows.sqlite3")
			case "-lock-file":
				changed[index+1] = filepath.Join(dir, "locks", "http.lock")
			case "-acquisition-workdir":
				changed[index+1] = dir
			}
		}
		return changed, environment
	}
}

func TestWebAcquisitionRefusesToStartOutsideItsPreparedVolume(t *testing.T) {
	volume := newWebVolume(t, currentBundle)
	other := prepare(t, currentBundle)
	replace := func(flag, value string) serverChange {
		return func(arguments, environment []string) ([]string, []string) {
			changed := append([]string{}, arguments...)
			for index := range changed {
				if changed[index] == flag {
					changed[index+1] = value
				}
			}
			return changed, environment
		}
	}
	without := func(flag string) serverChange {
		return func(arguments, environment []string) ([]string, []string) {
			var kept []string
			for index := 0; index < len(arguments); index++ {
				if arguments[index] == flag {
					index++
					continue
				}
				kept = append(kept, arguments[index])
			}
			return kept, environment
		}
	}
	lockSibling := filepath.Join(volume.runtimes, "sibling-locks")
	if err := os.Mkdir(lockSibling, 0o700); err != nil {
		t.Fatal(err)
	}
	outsideLock := filepath.Join(volume.runtimes, "outside.lock")
	locks := filepath.Join(volume.w.dir, "locks")
	cases := []struct {
		name   string
		change serverChange
		setup  func()
		undo   func()
		code   string
	}{
		{name: "the database of another prepared volume", change: replace("-database", other.database()), code: "acquisition-volume"},
		{name: "a lock file outside the volume", change: replace("-lock-file", outsideLock), code: "acquisition-volume"},
		{
			name: "a lock directory replaced by a link out of the volume",
			setup: func() {
				os.Rename(locks, locks+".moved")
				os.Symlink(lockSibling, locks)
			},
			undo: func() {
				os.Remove(locks)
				os.Rename(locks+".moved", locks)
			},
			code: "acquisition-volume",
		},
		{name: "no preview account", change: replace("-preview-user-ids", ""), code: "acquisition-volume"},
		{
			name:  "a lock directory readable by others",
			setup: func() { os.Chmod(locks, 0o755) },
			undo:  func() { os.Chmod(locks, 0o700) },
			code:  "acquisition-volume",
		},
		{name: "a browser origin that is not loopback", change: replace("-browser-origin", "http://shelf.example"), code: "acquisition-volume"},
		{name: "a copied database outside any prepared volume", change: unprepared(t, volume), code: "acquisition-volume"},
		{name: "Open Library search without a test server address", change: without("-acquisition-open-library-address"), code: "acquisition-network"},
		{name: "Open Library search pinned to an address that is not loopback", change: replace("-acquisition-open-library-address", "93.184.215.14:443"), code: "acquisition-network"},
		{
			name:  "a public Gutenberg catalogue",
			setup: func() { putSetting(t, volume.db, "gutenberg_url", "string", "https://www.gutenberg.org") },
			undo:  func() { putSetting(t, volume.db, "gutenberg_url", "string", volume.fake.server.URL) },
			code:  "acquisition-settings",
		},
		{
			name:  "an ebook library outside the volume",
			setup: func() { putSetting(t, volume.db, "ebook_output_path", "string", volume.runtimes) },
			undo:  func() { putSetting(t, volume.db, "ebook_output_path", "string", volume.library) },
			code:  "acquisition-settings",
		},
		{
			name: "another ebook source configured",
			setup: func() {
				putSetting(t, volume.db, "anna_archive_enabled", "boolean", "true")
				putSetting(t, volume.db, "anna_archive_api_key", "string", "synthetic")
			},
			undo: func() { putSetting(t, volume.db, "anna_archive_enabled", "boolean", "false") },
			code: "acquisition-settings",
		},
	}
	before := digests(t, volume.db, "settings")
	for _, entry := range cases {
		t.Run(entry.name, func(t *testing.T) {
			if entry.setup != nil {
				entry.setup()
				t.Cleanup(entry.undo)
			}
			changes := []serverChange{}
			if entry.change != nil {
				changes = append(changes, entry.change)
			}
			server := volume.launch(t, changes...)
			code, exited := server.exited()
			if !exited || code != 2 || !strings.Contains(server.output(), "refused: "+entry.code) {
				t.Fatalf("expected exit 2 refused: %s, got %d (exited %v): %s", entry.code, code, exited, server.output())
			}
		})
	}
	requireSame(t, before, digests(t, volume.db, "settings"))
	for _, created := range []string{outsideLock, filepath.Join(lockSibling, "http.lock")} {
		if _, err := os.Lstat(created); err == nil {
			t.Errorf("a refused start created %s", created)
		}
	}
	if journal := volume.openLib.entries(t); len(journal) != 0 {
		t.Errorf("a refused start contacted Open Library: %v", journal)
	}
	if seen := volume.fake.requests(); len(seen) != 0 {
		t.Errorf("a refused start contacted the catalogue: %v", seen)
	}
}

func TestWebAcquisitionIsOffWithoutItsFlag(t *testing.T) {
	volume := newWebVolume(t, currentBundle)
	withoutFlag := func(arguments, environment []string) ([]string, []string) {
		var kept []string
		for index := 0; index < len(arguments); index++ {
			if arguments[index] == "-acquisition-workdir" || arguments[index] == "-acquisition-open-library-address" {
				index++
				continue
			}
			kept = append(kept, arguments[index])
		}
		var proxied []string
		for _, entry := range environment {
			if strings.HasPrefix(entry, "HTTPS_PROXY=") {
				entry = "HTTPS_PROXY=" + volume.openLib.proxy
			}
			proxied = append(proxied, entry)
		}
		return kept, proxied
	}
	server := volume.launch(t, withoutFlag)
	member := server.browser().signIn("bob", memberPassword)
	found := member.discover("pride")
	if found.status != 200 {
		t.Fatalf("discover %d %s", found.status, found.body)
	}
	if _, present := found.json(t)["requesting"]; present {
		t.Errorf("discover offers requesting without the flag: %s", found.body)
	}
	created := member.request(prideWork)
	if created.status != http.StatusMethodNotAllowed || created.headers.Get("Allow") != "GET" || created.code(t) != "method_not_allowed" {
		t.Errorf("POST requests without the flag answered %d %v %s", created.status, created.headers, created.body)
	}
	for _, path := range []string{"/preview/api/v1/requests/1/acquisition", "/preview/api/v1/requests/1/selection"} {
		for _, method := range []string{"GET", "POST"} {
			if found := member.do(method, path, member.writeHeaders(), `{}`); found.status != 404 {
				t.Errorf("%s %s without the flag answered %d", method, path, found.status)
			}
		}
	}
	time.Sleep(3 * time.Second)
	if count := scalar[int64](t, volume.db, `SELECT COUNT(*) FROM requests WHERE user_id = ? AND created_via = 'api'`, volume.users["bob"]); count != 0 {
		t.Errorf("%d requests written without the flag", count)
	}
	if seen := volume.fake.requests(); len(seen) != 0 {
		t.Errorf("the catalogue was contacted without the flag: %v", seen)
	}
}

func TestWebAcquisitionJourney(t *testing.T) {
	for _, bundle := range []struct{ name, path string }{{"current", currentBundle}, {"upgrade", upgradeBundle}} {
		t.Run(bundle.name, func(t *testing.T) {
			volume := newWebVolume(t, bundle.path)
			server := volume.launch(t)
			member := server.browser().signIn("bob", memberPassword)
			admin := server.browser().signIn("alice", adminPassword)
			legacy := rows(t, volume.db, `SELECT * FROM requests ORDER BY id`)
			untouched := digests(t, volume.db)

			found := member.discover("pride")
			body := found.json(t)
			if found.status != 200 || body["requesting"] != true {
				t.Fatalf("discover %d %s", found.status, found.body)
			}
			items, _ := body["items"].([]any)
			if len(items) != 2 || items[0].(map[string]any)["id"] != prideWork {
				t.Fatalf("discover items %s", found.body)
			}

			refusals := []struct {
				name    string
				headers map[string]string
				body    string
				status  int
				code    string
			}{
				{"no CSRF token", map[string]string{"X-Shelfarr-Account": member.account, "Origin": server.origin}, requestBody(prideWork), 422, "invalid_csrf"},
				{"another origin", map[string]string{"X-Shelfarr-Account": member.account, "Origin": "http://127.0.0.2:1", "X-CSRF-Token": member.token}, requestBody(prideWork), 422, "invalid_csrf"},
				{"a cross-site fetch", map[string]string{"X-Shelfarr-Account": member.account, "Origin": server.origin, "X-CSRF-Token": member.token, "Sec-Fetch-Site": "cross-site"}, requestBody(prideWork), 422, "invalid_csrf"},
				{"another account's token", map[string]string{"X-Shelfarr-Account": member.account, "Origin": server.origin, "X-CSRF-Token": admin.token}, requestBody(prideWork), 422, "invalid_csrf"},
				{"another account header", map[string]string{"X-Shelfarr-Account": admin.account, "Origin": server.origin, "X-CSRF-Token": member.token}, requestBody(prideWork), 401, "account_changed"},
				{"an audiobook", member.writeHeaders(), `{"work_id":"OL9001W","book_type":"audiobook"}`, 422, "invalid_request"},
				{"an extra field", member.writeHeaders(), `{"work_id":"OL9001W","book_type":"ebook","user_id":"1"}`, 422, "invalid_request"},
				{"a source prefix", member.writeHeaders(), `{"work_id":"openlibrary:OL9001W","book_type":"ebook"}`, 422, "invalid_request"},
				{"a work this account was not shown", member.writeHeaders(), requestBody("OL1W"), 422, "work_not_offered"},
			}
			for _, refusal := range refusals {
				got := member.do("POST", "/preview/api/v1/requests", refusal.headers, refusal.body)
				if got.status != refusal.status || got.code(t) != refusal.code {
					t.Errorf("%s: %d %s, want %d %s", refusal.name, got.status, got.body, refusal.status, refusal.code)
				}
			}
			if admin.request(prideWork).code(t) != "work_not_offered" {
				t.Errorf("an admin requested a work only another account was shown")
			}
			requireSame(t, untouched, digests(t, volume.db))

			for attempt := 0; attempt < 5; attempt++ {
				ctx, cancel := context.WithTimeout(context.Background(), time.Duration(attempt)*time.Millisecond)
				member.send(ctx, "POST", "/preview/api/v1/requests", member.writeHeaders(), requestBody(prideWork))
				cancel()
			}
			var group sync.WaitGroup
			answers := make([]answer, 8)
			for index := range answers {
				group.Add(1)
				go func() {
					defer group.Done()
					answers[index], _ = member.send(context.Background(), "POST", "/preview/api/v1/requests", member.writeHeaders(), requestBody(prideWork))
				}()
			}
			group.Wait()
			requests := rows(t, volume.db, `SELECT r.id FROM requests r JOIN books b ON b.id = r.book_id WHERE b.open_library_work_id = ?`, prideWork)
			if len(requests) != 1 {
				t.Fatalf("expected exactly one request for the work, found %v", requests)
			}
			requestID := idOf(t, strings.TrimPrefix(requests[0][0], "int64:"))
			for _, got := range answers {
				decoded := got.json(t)
				outcome := decoded["outcome"]
				if got.status == 201 && outcome == "created" || got.status == 200 && outcome == "existing" {
					if idOf(t, decoded["request"].(map[string]any)["id"]) != requestID {
						t.Errorf("answer names another request: %s", got.body)
					}
					continue
				}
				t.Errorf("concurrent request answered %d %s", got.status, got.body)
			}
			if row := rows(t, volume.db, `SELECT user_id, created_via, external_source, request_scope, language FROM requests WHERE id = ?`, requestID)[0]; !reflect.DeepEqual(row, []string{"int64:" + itoa(volume.users["bob"]), "string:api", "string:consumer_app", "string:single", "string:en"}) {
				t.Errorf("request row %v", row)
			}
			if book := rows(t, volume.db, `SELECT b.title, b.author, b.year, b.metadata_source, b.book_type FROM books b JOIN requests r ON r.book_id = b.id WHERE r.id = ?`, requestID)[0]; !reflect.DeepEqual(book, []string{"string:Pride and Prejudice", "string:Jane Austen", "int64:1813", "string:openlibrary", "int64:1"}) {
				t.Errorf("book row %v", book)
			}
			if logged := scalar[int64](t, volume.db, `SELECT COUNT(*) FROM activity_logs WHERE action = 'request.created' AND trackable_id = ?`, requestID); logged != 1 {
				t.Errorf("%d request.created rows", logged)
			}

			if searched := admin.discover("pride"); searched.status != 200 {
				t.Fatalf("admin discover %d %s", searched.status, searched.body)
			}
			shared := admin.request(prideWork)
			if shared.status != 200 || !reflect.DeepEqual(keysOf(shared.json(t)), []string{"account", "outcome"}) || shared.json(t)["outcome"] != "already_requested" {
				t.Errorf("another account's request answered %d %s", shared.status, shared.body)
			}

			volume.awaitCandidates(t, requestID)
			detail := member.get("/preview/api/v1/requests/" + itoa(requestID))
			if detail.status != 200 || !strings.Contains(string(detail.body), selectionMessage) || strings.Contains(string(detail.body), "requested_by") {
				t.Errorf("member detail %d %s", detail.status, detail.body)
			}
			for _, probe := range []answer{member.get("/preview/api/v1/requests/" + itoa(requestID) + "/acquisition"), member.post("/preview/api/v1/requests/"+itoa(requestID)+"/selection", `{"result_id":"1"}`)} {
				if probe.status != 404 || probe.code(t) != "not_found" {
					t.Errorf("a member reached the admin choice: %d %s", probe.status, probe.body)
				}
			}

			listed := admin.get("/preview/api/v1/requests/" + itoa(requestID) + "/acquisition")
			if listed.status != 200 {
				t.Fatalf("acquisition %d %s", listed.status, listed.body)
			}
			for _, forbidden := range []string{"http", "gutenberg:", volume.fake.server.URL, "/ebooks/", "download_url", "guid", "info_url"} {
				if strings.Contains(string(listed.body), forbidden) {
					t.Errorf("the admin answer carries %q: %s", forbidden, listed.body)
				}
			}
			chosen := scalar[int64](t, volume.db, `SELECT id FROM search_results WHERE request_id = ? AND guid = ?`, requestID, bookGUID)
			var listing struct {
				Candidates []struct{ ID, Title string } `json:"candidates"`
				Selection  any                          `json:"selection"`
			}
			json.Unmarshal(listed.body, &listing)
			ids := []string{}
			for _, candidate := range listing.Candidates {
				ids = append(ids, candidate.ID)
			}
			if !contains(ids, itoa(chosen)) || listing.Selection != nil {
				t.Errorf("candidates %s", listed.body)
			}

			otherRequest := exec1(t, volume.db, `INSERT INTO requests (book_id, user_id, status, created_at, updated_at) VALUES (?, ?, 5, ?, ?)`,
				scalar[int64](t, volume.db, `SELECT MIN(id) FROM books`), volume.users["alice"], seededStamp, seededStamp)
			foreign := exec1(t, volume.db, `INSERT INTO search_results (request_id, guid, title, source, status, download_url, created_at, updated_at) VALUES (?, 'gutenberg:158', 'Emma', 'gutenberg', 0, '/ebooks/158.epub3.images', ?, ?)`, otherRequest, seededStamp, seededStamp)
			for _, bad := range []struct{ body, code string }{
				{`{"result_id":` + itoa(chosen) + `}`, "invalid_request"},
				{`{"result_id":"` + itoa(chosen) + `","request_id":"1"}`, "invalid_request"},
				{`{"result_id":"` + itoa(foreign) + `"}`, "not_selectable"},
			} {
				if got := admin.post("/preview/api/v1/requests/"+itoa(requestID)+"/selection", bad.body); got.code(t) != bad.code {
					t.Errorf("selection %s answered %d %s", bad.body, got.status, got.body)
				}
			}
			volume.fake.reset()

			first := admin.post("/preview/api/v1/requests/"+itoa(requestID)+"/selection", `{"result_id":"`+itoa(chosen)+`"}`)
			second := admin.post("/preview/api/v1/requests/"+itoa(requestID)+"/selection", `{"result_id":"`+itoa(chosen)+`"}`)
			for _, got := range []answer{first, second} {
				if got.status != 202 && !(got.status == 200 && strings.Contains(string(got.body), `"completed"`)) {
					t.Errorf("selection answered %d %s", got.status, got.body)
				}
			}
			waitFor(t, "the download to complete", 30*time.Second, func() bool {
				status, _ := volume.requestState(t, requestID)
				return status == 5
			})
			waitFor(t, "the admin to see the completed download", 10*time.Second, func() bool {
				return strings.Contains(string(admin.get("/preview/api/v1/requests/"+itoa(requestID)+"/acquisition").body), `"state":"completed"`)
			})
			if downloads := rows(t, volume.db, `SELECT status, download_type, search_result_id FROM downloads WHERE request_id = ?`, requestID); !reflect.DeepEqual(downloads, [][]string{{"int64:3", "string:direct", "int64:" + itoa(chosen)}}) {
				t.Errorf("downloads %v", downloads)
			}
			bookID := scalar[int64](t, volume.db, `SELECT book_id FROM requests WHERE id = ?`, requestID)
			path := filepath.Join(volume.library, "shelfarr-gutenberg", "book-"+itoa(bookID), "gutenberg-1342.epub")
			stored, err := os.ReadFile(path)
			if err != nil || !bytes.Equal(stored, volume.epub) {
				t.Fatalf("library file %v", err)
			}
			if fetched := volume.fake.requests(); !reflect.DeepEqual(fetched, []string{bookLink + "?"}) {
				t.Errorf("catalogue requests for the download %v", fetched)
			}
			again := admin.post("/preview/api/v1/requests/"+itoa(requestID)+"/selection", `{"result_id":"`+itoa(chosen)+`"}`)
			if again.status != 200 || !strings.Contains(string(again.body), `"state":"completed"`) {
				t.Errorf("a repeated selection answered %d %s", again.status, again.body)
			}

			tracked := member.get("/preview/api/v1/requests/" + itoa(requestID)).json(t)["request"].(map[string]any)
			if tracked["status"] != "completed" || !reflect.DeepEqual(tracked["library"], map[string]any{"state": "available", "publication_id": itoa(bookID)}) {
				t.Errorf("member tracking %v", tracked)
			}
			library := member.get("/preview/api/v1/library?q=Pride")
			if !strings.Contains(string(library.body), `"id":"`+itoa(bookID)+`"`) {
				t.Errorf("library %d %s", library.status, library.body)
			}
			reader := member.get("/preview/api/v1/library/" + itoa(bookID) + "/reader")
			var opened struct {
				Publication struct {
					Assets []struct {
						Format string `json:"format"`
						URL    string `json:"url"`
					} `json:"assets"`
				} `json:"publication"`
			}
			if reader.status != 200 || json.Unmarshal(reader.body, &opened) != nil || len(opened.Publication.Assets) != 1 || opened.Publication.Assets[0].Format != "epub" {
				t.Fatalf("reader %d %s", reader.status, reader.body)
			}
			media := member.do("GET", opened.Publication.Assets[0].URL, map[string]string{"Sec-Fetch-Site": "same-origin"}, "")
			if media.status != 200 || !bytes.Equal(media.body, volume.epub) {
				t.Errorf("reader media %d, %d bytes", media.status, len(media.body))
			}

			if searched := member.discover("pride"); searched.status != 200 {
				t.Fatalf("member discover %d %s", searched.status, searched.body)
			}
			owned := member.request(prideWork)
			if owned.status != 200 || !reflect.DeepEqual(owned.json(t)["library"], map[string]any{"publication_id": itoa(bookID)}) || owned.json(t)["outcome"] != "already_in_library" {
				t.Errorf("a request for an acquired work answered %d %s", owned.status, owned.body)
			}
			if count := len(rows(t, volume.db, `SELECT r.id FROM requests r JOIN books b ON b.id = r.book_id WHERE b.open_library_work_id = ?`, prideWork)); count != 1 {
				t.Errorf("%d requests for the work after the journey", count)
			}

			for _, before := range legacy {
				if after := rows(t, volume.db, `SELECT * FROM requests WHERE id = ?`, strings.TrimPrefix(before[0], "int64:")); !reflect.DeepEqual(after, [][]string{before}) {
					t.Errorf("a request the website did not make was changed: %v to %v", before, after)
				}
			}
			kinds := map[string]int{}
			for _, entry := range volume.openLib.entries(t) {
				kinds[entry["kind"].(string)]++
			}
			if kinds["connect"] != 0 || kinds["refused"] != 0 || kinds["direct"] == 0 {
				t.Errorf("Open Library was reached other than through the pinned test address: %v", kinds)
			}
			logged := server.output()
			for _, secret := range []string{"Pride and Prejudice", "Jane Austen", volume.fake.server.URL, volume.library, bookLink, memberPassword, adminPassword} {
				if strings.Contains(logged, secret) {
					t.Errorf("the server log carries %q", secret)
				}
			}
			server.stop()
			if code, _ := server.exited(); code != 0 {
				t.Errorf("shutdown exit %d: %s", code, server.output())
			}
		})
	}
}

func TestWebAcquisitionSurvivesRestartsAndAnUnreachableCatalogue(t *testing.T) {
	volume := newWebVolume(t, currentBundle)
	stalled := make(chan struct{})
	volume.fake.set(reply{Path: searchPath, Query: prideQuery, Status: 200, Body: opds(t, "search-pride.xml"), before: func() {
		select {
		case <-stalled:
		case <-time.After(time.Minute):
		}
	}})
	server := volume.launch(t)
	member := server.browser().signIn("bob", memberPassword)
	member.discover("pride")
	created := member.request(prideWork)
	if created.status != 201 {
		t.Fatalf("request %d %s", created.status, created.body)
	}
	requestID := idOf(t, created.json(t)["request"].(map[string]any)["id"])
	waitFor(t, "the worker to claim the request", 15*time.Second, func() bool {
		status, _ := volume.requestState(t, requestID)
		return status == 1
	})
	claimed := scalar[int64](t, volume.db, `SELECT search_generation FROM requests WHERE id = ?`, requestID)
	server.kill()
	close(stalled)
	volume.fake.reset()
	volume.fake.set(reply{Path: searchPath, Query: prideQuery, Status: 503, Body: "busy"})

	restarted := volume.launch(t)
	admin := restarted.browser().signIn("alice", adminPassword)
	time.Sleep(4 * time.Second)
	if seen := volume.fake.requests(); len(seen) != 0 {
		t.Fatalf("a live claim was taken over before its lease: %v", seen)
	}
	if status, _ := volume.requestState(t, requestID); status != 1 {
		t.Fatalf("status %d after restart", status)
	}
	volume.advance(t, 31*time.Minute)
	waitFor(t, "the abandoned claim to be retried and released", 20*time.Second, func() bool {
		status, _ := volume.requestState(t, requestID)
		return status == 0 && len(volume.fake.requests()) > 0
	})
	if generation := scalar[int64](t, volume.db, `SELECT search_generation FROM requests WHERE id = ?`, requestID); generation != claimed+2 {
		t.Errorf("generation %d after one takeover and one release from %d", generation, claimed)
	}
	note := admin.get("/preview/api/v1/requests/" + itoa(requestID) + "/acquisition").json(t)["search"]
	if search, _ := note.(map[string]any); search["state"] != "retry_scheduled" || search["code"] != "provider-busy" {
		t.Errorf("admin search note %v", note)
	}
	attempts := len(volume.fake.requests())
	time.Sleep(5 * time.Second)
	if again := len(volume.fake.requests()); again != attempts {
		t.Errorf("a busy catalogue was asked %d more times before the retry was due", again-attempts)
	}
	if status, issue := volume.requestState(t, requestID); status != 0 || issue != "" {
		t.Errorf("a transport failure ended the request: %d %q", status, issue)
	}

	volume.fake.reset()
	volume.fake.defaults()
	volume.serveBook(volume.epub)
	volume.advance(t, 2*time.Minute)
	volume.awaitCandidates(t, requestID)
	chosen := scalar[int64](t, volume.db, `SELECT id FROM search_results WHERE request_id = ? AND guid = ?`, requestID, bookGUID)

	slow := make(chan struct{})
	volume.fake.set(reply{Path: bookLink, Status: 200, Body: string(volume.epub), ContentType: epubType, before: func() {
		select {
		case <-slow:
		case <-time.After(time.Minute):
		}
	}})
	if got := admin.post("/preview/api/v1/requests/"+itoa(requestID)+"/selection", `{"result_id":"`+itoa(chosen)+`"}`); got.status != 202 {
		t.Fatalf("selection %d %s", got.status, got.body)
	}
	waitFor(t, "the download to start", 10*time.Second, func() bool {
		return strings.Contains(string(admin.get("/preview/api/v1/requests/"+itoa(requestID)+"/acquisition").body), `"state":"downloading"`)
	})
	busy := admin.post("/preview/api/v1/requests/"+itoa(requestID)+"/selection", `{"result_id":"`+itoa(scalar[int64](t, volume.db, `SELECT id FROM search_results WHERE request_id = ? AND guid = ?`, requestID, otherGUID))+`"}`)
	if busy.status != 409 || busy.code(t) != "acquisition_busy" {
		t.Errorf("a second choice during a download answered %d %s", busy.status, busy.body)
	}
	restarted.kill()
	close(slow)
	if downloads := scalar[int64](t, volume.db, `SELECT COUNT(*) FROM downloads WHERE request_id = ?`, requestID); downloads != 0 {
		t.Errorf("a killed download left %d download rows", downloads)
	}
	if status, issue := volume.requestState(t, requestID); status != 1 || issue != selectionMessage {
		t.Errorf("a killed download changed the request: %d %q", status, issue)
	}

	volume.serveBook(volume.epub)
	third := volume.launch(t)
	admin = third.browser().signIn("alice", adminPassword)
	if selection := admin.get("/preview/api/v1/requests/" + itoa(requestID) + "/acquisition").json(t)["selection"]; selection != nil {
		t.Errorf("a restarted server claims a download it never ran: %v", selection)
	}
	if got := admin.post("/preview/api/v1/requests/"+itoa(requestID)+"/selection", `{"result_id":"`+itoa(chosen)+`"}`); got.status != 202 {
		t.Fatalf("selection after restart %d %s", got.status, got.body)
	}
	waitFor(t, "the download after restart", 30*time.Second, func() bool {
		status, _ := volume.requestState(t, requestID)
		return status == 5
	})
	third.stop()

	railsReadable(t, volume, requestID)
}

func railsReadable(t *testing.T, volume *webVolume, requestID int64) {
	t.Helper()
	var bookPath string
	var downloadPath string
	if err := volume.db.QueryRow(`SELECT b.file_path, d.download_path FROM requests r JOIN books b ON b.id = r.book_id JOIN downloads d ON d.request_id = r.id WHERE r.id = ? AND d.status = 3`, requestID).Scan(&bookPath, &downloadPath); err != nil {
		t.Fatal(err)
	}
	if bookPath != downloadPath || !strings.HasPrefix(bookPath, volume.library+"/shelfarr-gutenberg/") {
		t.Errorf("book path %q download path %q", bookPath, downloadPath)
	}
	stored, err := os.ReadFile(bookPath)
	if err != nil || !bytes.Equal(stored, volume.epub) {
		t.Errorf("the completed file is not the downloaded EPUB: %v", err)
	}
	var integrity string
	if err := volume.db.QueryRow(`PRAGMA integrity_check`).Scan(&integrity); err != nil || integrity != "ok" {
		t.Errorf("integrity %q %v", integrity, err)
	}
}

func (v *webVolume) acquisitionState(t *testing.T, admin *webClient, requestID int64) map[string]any {
	t.Helper()
	found := admin.get("/preview/api/v1/requests/" + itoa(requestID) + "/acquisition")
	if found.status != 200 {
		t.Fatalf("acquisition %d %s", found.status, found.body)
	}
	return found.json(t)
}

func selectionOf(state map[string]any) map[string]any {
	selection, _ := state["selection"].(map[string]any)
	return selection
}

func TestWebAcquisitionChecksAuthorityRetriesAndTheLibraryRoot(t *testing.T) {
	volume := newWebVolume(t, currentBundle)
	const zombieQuery = "Pride and Prejudice and Zombies Seth Grahame-Smith"
	zombies := make(chan struct{})
	volume.fake.set(reply{Path: searchPath, Query: zombieQuery, Status: 200, Body: opds(t, "search-empty.xml"), before: func() {
		select {
		case <-zombies:
		case <-time.After(time.Minute):
		}
	}})
	server := volume.launch(t)
	member := server.browser().signIn("bob", memberPassword)
	admin := server.browser().signIn("alice", adminPassword)
	member.discover("pride")
	pride := idOf(t, member.request(prideWork).json(t)["request"].(map[string]any)["id"])
	volume.awaitCandidates(t, pride)
	undead := idOf(t, member.request(zombieWork).json(t)["request"].(map[string]any)["id"])
	waitFor(t, "the worker to stall on the second search", 15*time.Second, func() bool {
		status, _ := volume.requestState(t, undead)
		return status == 1
	})
	chosen := scalar[int64](t, volume.db, `SELECT id FROM search_results WHERE request_id = ? AND guid = ?`, pride, bookGUID)
	choose := func(client *webClient) answer {
		return client.post("/preview/api/v1/requests/"+itoa(pride)+"/selection", `{"result_id":"`+itoa(chosen)+`"}`)
	}
	if queued := choose(admin); queued.status != 202 || selectionOf(queued.json(t))["state"] != "queued" {
		t.Fatalf("a choice behind a running search answered %d %s", queued.status, queued.body)
	}

	putSetting(t, volume.db, "session_max_age_days", "integer", "1")
	volume.advance(t, 25*time.Hour)
	close(zombies)
	waitFor(t, "the empty search to settle", 15*time.Second, func() bool {
		status, _ := volume.requestState(t, undead)
		return status == 2
	})
	time.Sleep(3 * time.Second)
	if count := scalar[int64](t, volume.db, `SELECT COUNT(*) FROM downloads WHERE request_id = ?`, pride); count != 0 {
		t.Fatalf("a choice whose session expired while it waited downloaded %d times", count)
	}
	if got := admin.get("/preview/api/v1/requests/" + itoa(pride) + "/acquisition"); got.status != 401 {
		t.Errorf("an expired session still reads the admin answer: %d", got.status)
	}
	member = server.browser().signIn("bob", memberPassword)
	admin = server.browser().signIn("alice", adminPassword)
	if selection := selectionOf(volume.acquisitionState(t, admin, pride)); selection["state"] != "failed" || selection["code"] != "authority_changed" {
		t.Errorf("an expired choice reads %v", selection)
	}

	member.discover("pride")
	if again := member.request(zombieWork).json(t); again["outcome"] != "existing" || idOf(t, again["request"].(map[string]any)["id"]) != undead {
		t.Errorf("asking again while a search is scheduled answered %v", again)
	}
	admin.discover("pride")
	if other := admin.request(zombieWork).json(t); !reflect.DeepEqual(keysOf(other), []string{"account", "outcome"}) || other["outcome"] != "already_requested" {
		t.Errorf("another account asking while a search is scheduled answered %v", other)
	}
	if count := scalar[int64](t, volume.db, `SELECT COUNT(*) FROM requests r JOIN books b ON b.id = r.book_id WHERE b.open_library_work_id = ?`, zombieWork); count != 1 {
		t.Errorf("%d requests for a work waiting for its next search", count)
	}

	held := make(chan struct{})
	volume.fake.set(reply{Path: bookLink, Status: 200, Body: string(volume.epub), ContentType: epubType, before: func() {
		select {
		case <-held:
		case <-time.After(time.Minute):
		}
	}})
	if got := choose(admin); got.status != 202 {
		t.Fatalf("choice %d %s", got.status, got.body)
	}
	waitFor(t, "the download to start", 10*time.Second, func() bool { return selectionOf(volume.acquisitionState(t, admin, pride))["state"] == "downloading" })
	exec1(t, volume.db, `UPDATE users SET role = 0 WHERE username = 'alice'`)
	close(held)
	waitFor(t, "the revoked download to settle", 15*time.Second, func() bool {
		return strings.Contains(server.output(), `"code":"authority_changed"`) && strings.Count(server.output(), `"step":"download"`) >= 2
	})
	if count := scalar[int64](t, volume.db, `SELECT COUNT(*) FROM downloads WHERE request_id = ?`, pride); count != 0 {
		t.Errorf("a download chosen by an account that lost the admin role completed")
	}
	bookID := scalar[int64](t, volume.db, `SELECT book_id FROM requests WHERE id = ?`, pride)
	if _, err := os.Lstat(filepath.Join(volume.library, "shelfarr-gutenberg", "book-"+itoa(bookID), "gutenberg-1342.epub")); !os.IsNotExist(err) {
		t.Errorf("the revoked download left its file: %v", err)
	}
	if got := admin.get("/preview/api/v1/requests/" + itoa(pride) + "/acquisition"); got.status != 404 {
		t.Errorf("a demoted account reads the admin answer: %d", got.status)
	}
	exec1(t, volume.db, `UPDATE users SET role = 1 WHERE username = 'alice'`)
	if selection := selectionOf(volume.acquisitionState(t, admin, pride)); selection["state"] != "failed" || selection["code"] != "authority_changed" {
		t.Errorf("a revoked download reads %v", selection)
	}

	unlisted := filepath.Join(volume.w.dir, "unlisted")
	if err := os.Mkdir(unlisted, 0o755); err != nil {
		t.Fatal(err)
	}
	putSetting(t, volume.db, "ebook_output_path", "string", unlisted)
	volume.serveBook(volume.epub)
	if got := choose(admin); got.status != 202 {
		t.Fatalf("choice %d %s", got.status, got.body)
	}
	waitFor(t, "the drifted root to be refused", 15*time.Second, func() bool { return selectionOf(volume.acquisitionState(t, admin, pride))["state"] == "failed" })
	if selection := selectionOf(volume.acquisitionState(t, admin, pride)); selection["code"] != "library_root_not_disposable" {
		t.Errorf("a library root outside the served roots reads %v", selection)
	}
	if entries, _ := os.ReadDir(unlisted); len(entries) != 0 {
		t.Errorf("a refused root received %d entries", len(entries))
	}
	putSetting(t, volume.db, "ebook_output_path", "string", volume.library)
	media := scalar[string](t, volume.db, `SELECT value FROM settings WHERE key = 'audiobook_output_path'`)
	putSetting(t, volume.db, "audiobook_output_path", "string", unlisted)
	if got := choose(admin); got.status != 202 {
		t.Fatalf("choice %d %s", got.status, got.body)
	}
	waitFor(t, "a drifted audiobook root to be refused", 15*time.Second, func() bool {
		selection := selectionOf(volume.acquisitionState(t, admin, pride))
		return selection["state"] == "failed" && strings.Contains(server.output(), `"code":"library_root_not_disposable"`) && strings.Count(server.output(), `"code":"library_root_not_disposable"`) >= 2
	})
	putSetting(t, volume.db, "audiobook_output_path", "string", media)

	hollow := hollowEPUB(t)
	volume.serveBook(hollow)
	if got := choose(admin); got.status != 202 {
		t.Fatalf("choice %d %s", got.status, got.body)
	}
	waitFor(t, "an EPUB without a readable book to be refused", 15*time.Second, func() bool {
		selection := selectionOf(volume.acquisitionState(t, admin, pride))
		return selection["state"] == "failed" && selection["code"] == "download-unreadable"
	})
	if status, issue := volume.requestState(t, pride); status != 1 || issue != selectionMessage {
		t.Errorf("an unreadable EPUB changed the request: %d %q", status, issue)
	}
	if entries, _ := os.ReadDir(filepath.Join(volume.library, "shelfarr-gutenberg", "book-"+itoa(bookID))); len(entries) != 0 {
		t.Errorf("an unreadable EPUB was published: %d entries", len(entries))
	}
	volume.serveBook(volume.epub)
	if got := choose(admin); got.status != 202 {
		t.Fatalf("choice %d %s", got.status, got.body)
	}
	waitFor(t, "the download to complete", 30*time.Second, func() bool {
		status, _ := volume.requestState(t, pride)
		return status == 5
	})

	generation := scalar[int64](t, volume.db, `SELECT search_generation FROM requests WHERE id = ?`, undead)
	searched := len(volume.fake.requests())
	putSetting(t, volume.db, "max_retries", "integer", "1")
	volume.advance(t, 25*time.Hour)
	waitFor(t, "the due retry to be searched again", 20*time.Second, func() bool {
		return scalar[int64](t, volume.db, `SELECT retry_count FROM requests WHERE id = ?`, undead) == 2
	})
	if after := scalar[int64](t, volume.db, `SELECT search_generation FROM requests WHERE id = ?`, undead); after != generation+2 {
		t.Errorf("generation %d after a requeue and a claim from %d", after, generation)
	}
	if again := volume.fake.requests()[searched:]; !reflect.DeepEqual(again, []string{searchPath + "?" + zombieQuery}) {
		t.Errorf("the due retry asked the catalogue %v", again)
	}
	if status, issue := volume.requestState(t, undead); status != 2 || !strings.HasPrefix(issue, "Maximum retry attempts") {
		t.Fatalf("retries were not exhausted: %d %q", status, issue)
	}
	member = server.browser().signIn("bob", memberPassword)
	member.discover("pride")
	if replay := member.request(zombieWork).json(t); replay["outcome"] != "existing" || idOf(t, replay["request"].(map[string]any)["id"]) != undead {
		t.Errorf("asking again after the retries ran out answered %v", replay)
	}
	if count := scalar[int64](t, volume.db, `SELECT COUNT(*) FROM requests r JOIN books b ON b.id = r.book_id WHERE b.open_library_work_id = ?`, zombieWork); count != 1 {
		t.Errorf("%d requests for a work whose retries ran out", count)
	}
}

func hollowEPUB(t *testing.T) []byte {
	t.Helper()
	var buffer bytes.Buffer
	archive := zip.NewWriter(&buffer)
	mimetype := []byte(epubType)
	writer, err := archive.CreateRaw(&zip.FileHeader{Name: "mimetype", Method: zip.Store, CRC32: crc32.ChecksumIEEE(mimetype), CompressedSize64: uint64(len(mimetype)), UncompressedSize64: uint64(len(mimetype))})
	if err != nil {
		t.Fatal(err)
	}
	writer.Write(mimetype)
	container, err := archive.Create("META-INF/container.xml")
	if err != nil {
		t.Fatal(err)
	}
	container.Write([]byte("<container/>"))
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

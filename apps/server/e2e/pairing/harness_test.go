//go:build e2e

package pairing

import (
	"bufio"
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

var binaryPath, seamBinaryPath string

func TestMain(m *testing.M) {
	directory, err := os.MkdirTemp("", "shelfarr-pairing-bin-")
	if err != nil {
		fmt.Fprintln(os.Stderr, "cannot create a build directory")
		os.Exit(1)
	}
	binaryPath = filepath.Join(directory, "shelfarr-http")
	seamBinaryPath = filepath.Join(directory, "shelfarr-http-seams")
	for target, tags := range map[string]string{binaryPath: "", seamBinaryPath: "e2eclock,faultinject"} {
		arguments := []string{"build", "-o", target}
		if tags != "" {
			arguments = append(arguments, "-tags", tags)
		}
		if os.Getenv("SHELFARR_HTTP_RACE") == "1" {
			arguments = append(arguments, "-race")
		}
		arguments = append(arguments, "../../cmd/shelfarr-http")
		build := exec.Command("go", arguments...)
		build.Stderr = os.Stderr
		if err := build.Run(); err != nil {
			fmt.Fprintln(os.Stderr, "build failed")
			os.Exit(1)
		}
	}
	code := m.Run()
	os.RemoveAll(directory)
	os.Exit(code)
}

type step struct {
	Kind            string            `json:"kind"`
	Name            string            `json:"name"`
	Flow            string            `json:"flow"`
	Method          string            `json:"method"`
	Path            string            `json:"path"`
	Authorization   *string           `json:"authorization"`
	Body            any               `json:"body"`
	Raw             *string           `json:"raw"`
	ContentType     *string           `json:"content_type"`
	Headers         map[string]string `json:"headers"`
	At              string            `json:"at"`
	Save            map[string]string `json:"save"`
	Status          int               `json:"status"`
	ResponseHeaders map[string]string `json:"response_headers"`
	BodyEmpty       bool              `json:"body_empty"`
	JSON            any               `json:"json"`
	Go              *struct {
		Status int    `json:"status"`
		Code   string `json:"code"`
	} `json:"go"`
	Actor     string         `json:"actor"`
	UserCode  string         `json:"user_code"`
	Decision  string         `json:"decision"`
	Statement string         `json:"statement"`
	Var       string         `json:"var"`
	Value     string         `json:"value"`
	Count     int            `json:"count"`
	Statuses  []int          `json:"statuses"`
	Limited   any            `json:"limited_json"`
	Rows      map[string]any `json:"rows"`
}

type casesDocument struct {
	BundleMediaRoot string           `json:"bundle_media_root"`
	ExtraMediaRoot  string           `json:"extra_media_root"`
	Database        string           `json:"database"`
	ServerVersion   string           `json:"server_version"`
	Users           map[string]int64 `json:"users"`
	Actors          []string         `json:"actors"`
	Final           map[string]any   `json:"final"`
	Handoff         handoffDocument  `json:"handoff"`
	Steps           []step           `json:"steps"`
}

type handoffDocument struct {
	Database string `json:"database"`
	At       string `json:"at"`
}

type secrets struct {
	Tokens    map[string]string `json:"tokens"`
	Passwords map[string]string `json:"passwords"`
	Handoff   map[string]string `json:"handoff"`
}

type fixture struct {
	name    string
	dir     string
	doc     casesDocument
	secrets secrets
}

func readJSON(t testing.TB, path string, into any) {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("cannot read %s", filepath.Base(path))
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := decoder.Decode(into); err != nil {
		t.Fatalf("cannot decode %s: %v", filepath.Base(path), err)
	}
}

func loadFixture(t testing.TB, name, variable string) fixture {
	t.Helper()
	dir := os.Getenv(variable)
	if dir == "" {
		t.Fatalf("%s is not set", variable)
	}
	found := fixture{name: name, dir: dir}
	readJSON(t, filepath.Join(dir, "cases.json"), &found.doc)
	readJSON(t, filepath.Join(dir, "secrets", "pairing.json"), &found.secrets)
	return found
}

func fixtures(t testing.TB) []fixture {
	t.Helper()
	return []fixture{loadFixture(t, "current-schema", "SHELFARR_PAIRING_CASES_CURRENT"), loadFixture(t, "stable-upgrade", "SHELFARR_PAIRING_CASES_UPGRADE")}
}

func (f fixture) allowedUsers() string {
	var ids []string
	for _, actor := range f.doc.Actors {
		ids = append(ids, fmt.Sprint(f.doc.Users[actor]))
	}
	return strings.Join(ids, ",")
}

func (f fixture) secretFile() string { return filepath.Join(f.dir, "secrets", "secret_key_base") }

type runtimeCopy struct {
	dir      string
	database string
	lock     string
}

func newRuntimeCopy(t testing.TB, f fixture) runtimeCopy {
	t.Helper()
	return newRuntimeCopyFrom(t, filepath.Join(f.dir, f.doc.Database))
}

func newRuntimeCopyFrom(t testing.TB, source string) runtimeCopy {
	t.Helper()
	dir := t.TempDir()
	if err := os.Chmod(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	copied := runtimeCopy{dir: dir, database: filepath.Join(dir, "primary.sqlite3"), lock: filepath.Join(dir, "domain.lock")}
	contents, err := os.ReadFile(source)
	if err != nil {
		t.Fatal("cannot read the source database")
	}
	if err := os.WriteFile(copied.database, contents, 0o600); err != nil {
		t.Fatal(err)
	}
	database, err := sql.Open("sqlite", "file:"+copied.database)
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	var mode string
	if err := database.QueryRow(`PRAGMA journal_mode=WAL`).Scan(&mode); err != nil || mode != "wal" {
		t.Fatalf("cannot enable WAL: %v %s", err, mode)
	}
	return copied
}

type lockedBuffer struct {
	mutex  sync.Mutex
	buffer bytes.Buffer
}

func (b *lockedBuffer) Write(data []byte) (int, error) {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	return b.buffer.Write(data)
}

func (b *lockedBuffer) String() string {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	return b.buffer.String()
}

type server struct {
	t      testing.TB
	cmd    *exec.Cmd
	base   string
	origin string
	log    *lockedBuffer
	done   chan struct{}
	exit   int
}

type serverOptions struct {
	arguments    []string
	env          []string
	database     string
	lock         string
	noSecret     bool
	seam         bool
	clockFile    string
	faults       string
	faultDir     string
	users        string
	noUsers      bool
	noOrigin     bool
	originScheme string
}

var listening = regexp.MustCompile(`"address":"([^"]+)"`)

func freePort(t testing.TB) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	_, port, _ := net.SplitHostPort(listener.Addr().String())
	return port
}

func startServer(t testing.TB, f fixture, copied runtimeCopy, options serverOptions) *server {
	t.Helper()
	database, lock := options.database, options.lock
	if database == "" {
		database = copied.database
	}
	if lock == "" {
		lock = copied.lock
	}
	port := freePort(t)
	origin := "http://127.0.0.1:" + port
	arguments := []string{"-experimental", "-database", database, "-lock-file", lock, "-listen", "127.0.0.1:" + port, "-server-version", f.doc.ServerVersion,
		"-library-root", f.doc.BundleMediaRoot, "-library-root", f.doc.ExtraMediaRoot}
	if !options.noOrigin {
		arguments = append(arguments, "-browser-origin", origin)
	}
	if !options.noUsers {
		users := options.users
		if users == "" {
			users = f.allowedUsers()
		}
		arguments = append(arguments, "-preview-user-ids", users)
	}
	arguments = append(arguments, options.arguments...)
	environment := []string{"PATH=" + os.Getenv("PATH")}
	if !options.noSecret {
		environment = append(environment, "SECRET_KEY_BASE_FILE="+f.secretFile())
	}
	environment = append(environment, options.env...)
	executable := binaryPath
	if options.seam {
		executable = seamBinaryPath
	}
	if options.clockFile != "" {
		environment = append(environment, "SHELFARR_E2E_CLOCK_FILE="+options.clockFile)
	}
	if options.faults != "" {
		environment = append(environment, "SHELFARR_FAULT_POINTS="+options.faults, "SHELFARR_FAULT_DIR="+options.faultDir)
	}
	command := exec.Command(executable, arguments...)
	command.Env = environment
	buffer := &lockedBuffer{}
	pipe, err := command.StderrPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	instance := &server{t: t, cmd: command, log: buffer, done: make(chan struct{}), origin: origin}
	address := make(chan string, 1)
	go func() {
		scanner := bufio.NewScanner(pipe)
		scanner.Buffer(make([]byte, 1<<20), 1<<20)
		for scanner.Scan() {
			line := scanner.Text()
			buffer.Write([]byte(line + "\n"))
			if match := listening.FindStringSubmatch(line); match != nil {
				select {
				case address <- match[1]:
				default:
				}
			}
		}
	}()
	go func() {
		err := command.Wait()
		if exitError, ok := err.(*exec.ExitError); ok {
			instance.exit = exitError.ExitCode()
		}
		close(instance.done)
	}()
	select {
	case value := <-address:
		instance.base = "http://" + value
	case <-instance.done:
		t.Fatalf("server exited before listening with code %d: %s", instance.exit, buffer.String())
	case <-time.After(20 * time.Second):
		command.Process.Kill()
		t.Fatalf("server did not start: %s", buffer.String())
	}
	t.Cleanup(func() { instance.stop() })
	instance.waitReady()
	return instance
}

func (s *server) waitReady() {
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		response, err := http.Get(s.base + "/readyz")
		if err == nil {
			io.Copy(io.Discard, response.Body)
			response.Body.Close()
			if response.StatusCode == http.StatusOK {
				return
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	s.t.Fatalf("server never became ready: %s", s.log.String())
}

func (s *server) stop() int {
	select {
	case <-s.done:
		return s.exit
	default:
	}
	s.cmd.Process.Signal(syscall.SIGTERM)
	select {
	case <-s.done:
	case <-time.After(30 * time.Second):
		s.cmd.Process.Kill()
		<-s.done
	}
	return s.exit
}

func (s *server) kill() {
	s.cmd.Process.Kill()
	<-s.done
}

type result struct {
	status  int
	headers http.Header
	body    []byte
}

func (r result) json(t testing.TB) map[string]any {
	t.Helper()
	var value map[string]any
	if err := json.Unmarshal(r.body, &value); err != nil {
		t.Fatalf("not a json object (%d): %q", r.status, r.body)
	}
	return value
}

func (r result) code(t testing.TB) string {
	t.Helper()
	value, _ := r.json(t)["error"].(string)
	return value
}

type browser struct {
	t      testing.TB
	server *server
	client *http.Client
	jar    *cookiejar.Jar
	plain  bool
}

func (s *server) browser() *browser {
	jar, _ := cookiejar.New(nil)
	return &browser{t: s.t, server: s, jar: jar, client: &http.Client{
		Jar: jar, Timeout: 60 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		Transport: &http.Transport{DisableCompression: true, MaxIdleConnsPerHost: 4},
	}}
}

func (s *server) bare() *browser {
	instance := s.browser()
	instance.client.Jar = nil
	return instance
}

func (b *browser) do(method, path string, headers map[string]string, body []byte) result {
	b.t.Helper()
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	request, err := http.NewRequestWithContext(context.Background(), method, b.server.base+path, reader)
	if err != nil {
		b.t.Fatalf("bad request %q: %v", path, err)
	}
	request.Header.Set("Accept-Encoding", "identity")
	request.Header.Set("User-Agent", "")
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	for name, value := range headers {
		if value == "" && name != "User-Agent" {
			continue
		}
		request.Header.Set(name, value)
	}
	response, err := b.client.Do(request)
	if err != nil {
		b.t.Fatalf("request failed: %v\n%s", err, b.server.log.String())
	}
	defer response.Body.Close()
	received, err := io.ReadAll(response.Body)
	if err != nil {
		b.t.Fatalf("body failed: %v", err)
	}
	return result{status: response.StatusCode, headers: response.Header, body: received}
}

func (b *browser) cookie(name string) string {
	for _, path := range []string{"/", "/preview/api/v1/auth/login"} {
		address, _ := url.Parse(b.server.base + path)
		for _, cookie := range b.jar.Cookies(address) {
			if cookie.Name == name {
				return cookie.Value
			}
		}
	}
	return ""
}

func (b *browser) bootstrap() (string, map[string]any) {
	b.t.Helper()
	response := b.do("GET", "/preview/api/v1/auth/bootstrap", nil, nil)
	if response.status != http.StatusOK {
		b.t.Fatalf("bootstrap answered %d %s", response.status, response.body)
	}
	body := response.json(b.t)
	token, _ := body["csrf_token"].(string)
	return token, body
}

func (b *browser) login(username, password, token string, extra map[string]string) result {
	payload, _ := json.Marshal(map[string]string{"username": username, "password": password})
	headers := map[string]string{"Origin": b.server.origin, "X-CSRF-Token": token}
	for name, value := range extra {
		headers[name] = value
	}
	return b.do("POST", "/preview/api/v1/auth/login", headers, payload)
}

func (b *browser) signIn(username, password string) (account, token string) {
	b.t.Helper()
	pre, _ := b.bootstrap()
	response := b.login(username, password, pre, nil)
	if response.status != http.StatusOK {
		b.t.Fatalf("login answered %d %s", response.status, response.body)
	}
	body := response.json(b.t)
	return body["account"].(string), body["csrf_token"].(string)
}

func (b *browser) get(path, account string) result {
	return b.do("GET", path, map[string]string{"X-Shelfarr-Account": account, "Accept": "application/json"}, nil)
}

func (b *browser) put(path, account, token, body string) result {
	return b.do("PUT", path, map[string]string{"X-Shelfarr-Account": account, "Accept": "application/json", "Origin": b.server.origin, "X-CSRF-Token": token}, []byte(body))
}

func (b *browser) logout(account, token string) result {
	return b.do("POST", "/preview/api/v1/auth/logout", map[string]string{"X-Shelfarr-Account": account, "Origin": b.server.origin, "X-CSRF-Token": token}, nil)
}

func openDatabase(t testing.TB, path string) *sql.DB {
	t.Helper()
	database, err := sql.Open("sqlite", "file:"+path+"?_pragma=busy_timeout(5000)")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { database.Close() })
	return database
}

func rows(t testing.TB, path, statement string, arguments ...any) []map[string]any {
	t.Helper()
	database := openDatabase(t, path)
	cursor, err := database.Query(statement, arguments...)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	defer cursor.Close()
	columns, _ := cursor.Columns()
	var found []map[string]any
	for cursor.Next() {
		values := make([]any, len(columns))
		pointers := make([]any, len(columns))
		for index := range values {
			pointers[index] = &values[index]
		}
		if err := cursor.Scan(pointers...); err != nil {
			t.Fatal(err)
		}
		row := map[string]any{}
		for index, column := range columns {
			if bytesValue, ok := values[index].([]byte); ok {
				values[index] = string(bytesValue)
			}
			row[column] = values[index]
		}
		found = append(found, row)
	}
	return found
}

func exec1(t testing.TB, path, statement string, arguments ...any) {
	t.Helper()
	database := openDatabase(t, path)
	if _, err := database.Exec(statement, arguments...); err != nil {
		t.Fatalf("exec: %v", err)
	}
}

func count(t testing.TB, path, statement string, arguments ...any) int64 {
	t.Helper()
	found := rows(t, path, statement, arguments...)
	for _, value := range found[0] {
		if number, ok := value.(int64); ok {
			return number
		}
	}
	t.Fatalf("no count in %v", found)
	return 0
}

func setClock(t testing.TB, path, at string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(at), 0o600); err != nil {
		t.Fatal(err)
	}
}

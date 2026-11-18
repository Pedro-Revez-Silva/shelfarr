//go:build e2e

package httpruntime

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
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
	directory, err := os.MkdirTemp("", "shelfarr-http-bin-")
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

type caseEntry struct {
	Name            string            `json:"name"`
	Method          string            `json:"method"`
	Path            string            `json:"path"`
	Bearer          *string           `json:"bearer"`
	Authorization   *string           `json:"authorization"`
	Headers         map[string]string `json:"headers"`
	Status          int               `json:"status"`
	ResponseHeaders map[string]string `json:"response_headers"`
	BodyBytes       int               `json:"body_bytes"`
	BodySHA256      string            `json:"body_sha256"`
	JSON            any               `json:"json"`
	Go              *struct {
		Status int    `json:"status"`
		Code   string `json:"code"`
	} `json:"go"`
	SQL           string                    `json:"sql"`
	MintedURL     string                    `json:"minted_url"`
	Grant         *grantShape               `json:"grant"`
	Body          *string                   `json:"body"`
	BodyBase64    *string                   `json:"body_base64"`
	At            *string                   `json:"at"`
	TrackedBook   *int64                    `json:"tracked_book"`
	StateBefore   *caseState                `json:"state_before"`
	State         *caseState                `json:"state"`
	TokensChanged map[string]map[string]any `json:"tokens_changed"`
}

type grantShape struct {
	Plaintext string `json:"plaintext"`
	Length    int    `json:"length"`
	Prefix    string `json:"prefix"`
}

type caseState struct {
	Progress []map[string]any `json:"progress"`
	Reading  []map[string]any `json:"reading"`
}

type tokenRow struct {
	ID        int64   `json:"id"`
	UserID    *int64  `json:"user_id"`
	Scopes    string  `json:"scopes"`
	ExpiresAt *string `json:"expires_at"`
	Replaces  *int64  `json:"replaces_api_token_id"`
	Key       *string `json:"connection_key"`
	Revoked   int     `json:"revoked"`
	Used      int     `json:"used"`
	UpdatedAt string  `json:"updated_at"`
}

type casesDocument struct {
	BundleMediaRoot string           `json:"bundle_media_root"`
	ExtraMediaRoot  string           `json:"extra_media_root"`
	Database        string           `json:"database"`
	ServerVersion   string           `json:"server_version"`
	Origin          string           `json:"origin"`
	Before          []tokenRow       `json:"token_state_before"`
	After           []tokenRow       `json:"token_state_after"`
	ProgressRows    []map[string]any `json:"progress_rows_after"`
	ReadingRows     []map[string]any `json:"reading_rows_after"`
	Cases           []caseEntry      `json:"cases"`
}

type fixture struct {
	name  string
	dir   string
	doc   casesDocument
	token map[string]string
}

func loadFixture(t *testing.T, name, variable string) fixture {
	t.Helper()
	dir := os.Getenv(variable)
	if dir == "" {
		t.Fatalf("%s is not set", variable)
	}
	var found fixture
	found.name, found.dir = name, dir
	readJSON(t, filepath.Join(dir, "cases.json"), &found.doc)
	readJSON(t, filepath.Join(dir, "secrets", "tokens.json"), &found.token)
	return found
}

func readJSON(t *testing.T, path string, into any) {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		setupFailed(t, "cannot read "+filepath.Base(path))
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := decoder.Decode(into); err != nil {
		t.Fatalf("cannot decode %s", filepath.Base(path))
	}
}

func fixtures(t *testing.T) []fixture {
	t.Helper()
	return []fixture{loadFixture(t, "current-schema", "SHELFARR_HTTP_CASES_CURRENT"), loadFixture(t, "stable-upgrade", "SHELFARR_HTTP_CASES_UPGRADE")}
}

type runtimeCopy struct {
	dir      string
	database string
	lock     string
}

func newRuntimeCopy(t *testing.T, f fixture) runtimeCopy {
	t.Helper()
	dir := t.TempDir()
	if err := os.Chmod(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	copied := runtimeCopy{dir: dir, database: filepath.Join(dir, "primary.sqlite3"), lock: filepath.Join(dir, "domain.lock")}
	source, err := os.ReadFile(filepath.Join(f.dir, f.doc.Database))
	if err != nil {
		setupFailed(t, "cannot read the pre-scenario database")
	}
	if err := os.WriteFile(copied.database, source, 0o600); err != nil {
		setupFailed(t, "cannot write the private database copy")
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
	t      *testing.T
	cmd    *exec.Cmd
	base   string
	log    *lockedBuffer
	done   chan struct{}
	exit   int
	client *http.Client
}

type serverOptions struct {
	arguments []string
	env       []string
	roots     []string
	database  string
	lock      string
	noSecret  bool
	seam      bool
	clockFile string
	faults    string
	faultDir  string
}

var listening = regexp.MustCompile(`"address":"([^"]+)"`)

func (f fixture) secretFile() string { return filepath.Join(f.dir, "secrets", "secret_key_base") }

func startServer(t *testing.T, f fixture, copied runtimeCopy, options serverOptions) *server {
	t.Helper()
	database, lock := options.database, options.lock
	if database == "" {
		database = copied.database
	}
	if lock == "" {
		lock = copied.lock
	}
	roots := options.roots
	if roots == nil {
		roots = []string{f.doc.BundleMediaRoot, f.doc.ExtraMediaRoot}
	}
	arguments := []string{"-experimental", "-database", database, "-lock-file", lock, "-listen", "127.0.0.1:0", "-server-version", f.doc.ServerVersion}
	for _, root := range roots {
		arguments = append(arguments, "-library-root", root)
	}
	arguments = append(arguments, options.arguments...)
	environment := []string{"PATH=" + os.Getenv("PATH")}
	if !options.noSecret {
		environment = append(environment, "SECRET_KEY_BASE_FILE="+f.secretFile())
	}
	environment = append(environment, options.env...)
	environment = append(environment, runnerEnvironment()...)
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
	instance := &server{t: t, cmd: command, log: buffer, done: make(chan struct{}), client: &http.Client{
		Transport:     &http.Transport{DisableCompression: true, MaxIdleConnsPerHost: 4},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		Timeout:       60 * time.Second,
	}}
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
		instance.exit = 0
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
		response, err := s.client.Get(s.base + "/readyz")
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

func (s *server) do(method, path string, headers map[string]string) result {
	return s.doWith(context.Background(), method, path, headers)
}

func (s *server) doWith(ctx context.Context, method, path string, headers map[string]string) result {
	return s.doBody(ctx, method, path, headers, nil)
}

func (s *server) doBody(ctx context.Context, method, path string, headers map[string]string, body []byte) result {
	s.t.Helper()
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	request, err := http.NewRequestWithContext(ctx, method, s.base+path, reader)
	if err != nil {
		s.t.Fatalf("bad request %q: %v", path, err)
	}
	request.Header.Set("Accept-Encoding", "identity")
	for name, value := range headers {
		request.Header.Set(name, value)
	}
	response, err := s.client.Do(request)
	if err != nil {
		s.t.Fatalf("request failed: %v\n%s", err, s.log.String())
	}
	defer response.Body.Close()
	received, err := io.ReadAll(response.Body)
	if err != nil {
		s.t.Fatalf("body failed: %v", err)
	}
	return result{status: response.StatusCode, headers: response.Header, body: received}
}

func bearer(f fixture, label string) map[string]string {
	return map[string]string{"Authorization": "Bearer " + f.token[label]}
}

func (s *server) logLines() []map[string]any {
	var lines []map[string]any
	for _, text := range strings.Split(s.log.String(), "\n") {
		var line map[string]any
		if json.Unmarshal([]byte(text), &line) == nil {
			lines = append(lines, line)
		}
	}
	return lines
}

func accountDigest(raw string) string {
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:])
}

func setupFailed(t *testing.T, reason string) {
	t.Helper()
	if os.Getenv(runMarkerName) != "" {
		t.Skip("the scenario could not be set up, which proves nothing about a mutant: " + reason)
	}
	t.Fatal(reason)
}

func runnerEnvironment() []string {
	var inherited []string
	for _, variable := range os.Environ() {
		if strings.HasPrefix(variable, "GOMAXPROCS=") || strings.HasPrefix(variable, runMarkerName+"=") {
			inherited = append(inherited, variable)
		}
	}
	return inherited
}

func runBinary(t *testing.T, environment []string, arguments []string) (string, int) {
	t.Helper()
	command := exec.Command(binaryPath, arguments...)
	command.Env = append(append([]string{"PATH=" + os.Getenv("PATH")}, environment...), runnerEnvironment()...)
	var output bytes.Buffer
	command.Stdout, command.Stderr = &output, &output
	err := command.Start()
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- command.Wait() }()
	select {
	case err = <-done:
	case <-time.After(20 * time.Second):
		command.Process.Kill()
		<-done
		t.Fatalf("the process did not exit: %s", output.String())
	}
	code := 0
	if exitError, ok := err.(*exec.ExitError); ok {
		code = exitError.ExitCode()
	}
	return output.String(), code
}

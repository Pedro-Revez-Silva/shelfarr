//go:build e2e

package workflows

import (
	"bufio"
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/pbkdf2"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

const (
	currentBundleEnvironment = "SHELFARR_WORKFLOW_BUNDLE"
	upgradeBundleEnvironment = "SHELFARR_WORKFLOW_UPGRADE_BUNDLE"
	waitLimit                = 45 * time.Second
	absKey                   = "synthetic-abs-key-4f1c"
	qbitPassword             = "synthetic-qbit-secret-9d2e"
)

var (
	faultBinary   string
	plainBinary   string
	currentBundle string
	upgradeBundle string
)

func TestMain(m *testing.M) {
	os.Exit(setupAndRun(m))
}

func setupAndRun(m *testing.M) int {
	currentBundle = os.Getenv(currentBundleEnvironment)
	upgradeBundle = os.Getenv(upgradeBundleEnvironment)
	if currentBundle == "" || upgradeBundle == "" {
		fmt.Fprintln(os.Stderr, currentBundleEnvironment+" and "+upgradeBundleEnvironment+" must name fixture bundles from tools/migration/produce_fixture.rb")
		return 2
	}
	scratch, err := os.MkdirTemp("", "shelfarr-workflows-e2e-")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	defer os.RemoveAll(scratch)
	module, err := filepath.Abs("../..")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	for _, build := range []struct {
		target *string
		name   string
		tags   string
	}{{&faultBinary, "workflows-fault", "faultinject"}, {&plainBinary, "workflows-plain", ""}} {
		*build.target = filepath.Join(scratch, build.name)
		arguments := []string{"build", "-trimpath", "-o", *build.target}
		if build.tags != "" {
			arguments = append(arguments, "-tags", build.tags)
		}
		command := exec.Command("go", append(arguments, "./cmd/shelfarr-workflows")...)
		command.Dir = module
		command.Env = append(os.Environ(), "CGO_ENABLED=0")
		if output, err := command.CombinedOutput(); err != nil {
			fmt.Fprintf(os.Stderr, "build failed: %v\n%s", err, output)
			return 2
		}
	}
	return m.Run()
}

type event map[string]any

func (e event) name() string { s, _ := e["event"].(string); return s }

func (e event) text(key string) string { s, _ := e[key].(string); return s }

func (e event) number(key string) int64 { f, _ := e[key].(float64); return int64(f) }

type process struct {
	t       *testing.T
	command *exec.Cmd
	mutex   sync.Mutex
	changed *sync.Cond
	events  []event
	raw     bytes.Buffer
	stderr  bytes.Buffer
	done    bool
	code    int
}

func spawn(t *testing.T, binary string, environment []string, arguments ...string) *process {
	t.Helper()
	command := exec.Command(binary, arguments...)
	command.Env = append([]string{"PATH=" + os.Getenv("PATH")}, environment...)
	command.Dir = t.TempDir()
	process := &process{t: t, command: command}
	process.changed = sync.NewCond(&process.mutex)
	stdout, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	command.Stderr = &lockedWriter{mutex: &process.mutex, buffer: &process.stderr}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	go func() {
		scanner := bufio.NewScanner(stdout)
		scanner.Buffer(make([]byte, 1<<16), 1<<20)
		for scanner.Scan() {
			line := scanner.Bytes()
			process.mutex.Lock()
			process.raw.Write(line)
			process.raw.WriteByte('\n')
			var parsed event
			if json.Unmarshal(line, &parsed) == nil {
				process.events = append(process.events, parsed)
			}
			process.changed.Broadcast()
			process.mutex.Unlock()
		}
		err := command.Wait()
		process.mutex.Lock()
		process.done = true
		process.code = command.ProcessState.ExitCode()
		if exit := command.ProcessState; exit != nil && !exit.Exited() {
			process.code = -1
		}
		_ = err
		process.changed.Broadcast()
		process.mutex.Unlock()
	}()
	t.Cleanup(func() {
		process.mutex.Lock()
		running := !process.done
		process.mutex.Unlock()
		if running {
			command.Process.Kill()
			process.wait()
		}
	})
	return process
}

type lockedWriter struct {
	mutex  *sync.Mutex
	buffer *bytes.Buffer
}

func (w *lockedWriter) Write(data []byte) (int, error) {
	w.mutex.Lock()
	defer w.mutex.Unlock()
	return w.buffer.Write(data)
}

func (p *process) waitFor(match func(event) bool) event {
	p.t.Helper()
	deadline := time.AfterFunc(waitLimit, func() {
		p.mutex.Lock()
		p.changed.Broadcast()
		p.mutex.Unlock()
	})
	defer deadline.Stop()
	started := time.Now()
	p.mutex.Lock()
	defer p.mutex.Unlock()
	checked := 0
	for {
		for ; checked < len(p.events); checked++ {
			if match(p.events[checked]) {
				return p.events[checked]
			}
		}
		if p.done {
			p.t.Fatalf("process ended (code %d) without the awaited event; events: %s", p.code, p.raw.String())
		}
		if time.Since(started) > waitLimit {
			p.t.Fatalf("timed out waiting for an event; events: %s", p.raw.String())
		}
		p.changed.Wait()
	}
}

func named(name string) func(event) bool {
	return func(e event) bool { return e.name() == name }
}

func (p *process) wait() int {
	p.t.Helper()
	deadline := time.AfterFunc(waitLimit, func() {
		p.mutex.Lock()
		p.changed.Broadcast()
		p.mutex.Unlock()
	})
	defer deadline.Stop()
	started := time.Now()
	p.mutex.Lock()
	defer p.mutex.Unlock()
	for !p.done {
		if time.Since(started) > waitLimit {
			p.t.Fatalf("process did not exit; events: %s", p.raw.String())
		}
		p.changed.Wait()
	}
	return p.code
}

func (p *process) kill() int {
	p.t.Helper()
	p.command.Process.Signal(syscall.SIGKILL)
	return p.wait()
}

func (p *process) terminate() int {
	p.t.Helper()
	p.command.Process.Signal(syscall.SIGTERM)
	return p.wait()
}

func (p *process) snapshot() []event {
	p.mutex.Lock()
	defer p.mutex.Unlock()
	return append([]event(nil), p.events...)
}

func (p *process) output() string {
	p.mutex.Lock()
	defer p.mutex.Unlock()
	return p.raw.String() + p.stderr.String()
}

func (p *process) count(name string) int {
	total := 0
	for _, e := range p.snapshot() {
		if e.name() == name {
			total++
		}
	}
	return total
}

func (p *process) errorCodes() []string {
	var codes []string
	for _, e := range p.snapshot() {
		if e.name() == "error" {
			codes = append(codes, e.text("code"))
		}
	}
	return codes
}

type result struct {
	code   int
	events []event
	output string
	codes  []string
}

type faults struct {
	dir    string
	points map[string]string
}

func (f faults) environment() []string {
	if f.dir == "" {
		return nil
	}
	var points []string
	for name, action := range f.points {
		points = append(points, name+"="+action)
	}
	sort.Strings(points)
	return []string{"SHELFARR_FAULT_DIR=" + f.dir, "SHELFARR_FAULT_POINTS=" + strings.Join(points, ",")}
}

func newFaults(t *testing.T, points map[string]string) faults {
	return faults{dir: t.TempDir(), points: points}
}

func (f faults) reached(t *testing.T, name string) {
	t.Helper()
	started := time.Now()
	for {
		if _, err := os.Stat(filepath.Join(f.dir, name+".reached")); err == nil {
			return
		}
		if time.Since(started) > waitLimit {
			t.Fatalf("failpoint %s never reached", name)
		}
		time.Sleep(time.Millisecond)
	}
}

func (f faults) release(t *testing.T, name string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(f.dir, name+".release"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
}

type workdir struct {
	t    *testing.T
	dir  string
	keys struct {
		PrimaryKey string `json:"primary_key"`
		Salt       string `json:"key_derivation_salt"`
	}
}

func prepare(t *testing.T, bundle string) *workdir {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "work")
	run := spawn(t, plainBinary, nil, "prepare", "--bundle", bundle, "--workdir", dir)
	if code := run.wait(); code != 0 {
		t.Fatalf("prepare exited %d: %s", code, run.output())
	}
	prepared := &workdir{t: t, dir: dir}
	data, err := os.ReadFile(filepath.Join(dir, "encryption.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &prepared.keys); err != nil {
		t.Fatal(err)
	}
	return prepared
}

func (w *workdir) database() string { return filepath.Join(w.dir, "workflows.sqlite3") }

func (w *workdir) open() *sql.DB {
	w.t.Helper()
	query := url.Values{}
	query.Add("_pragma", "busy_timeout(10000)")
	query.Add("_pragma", "foreign_keys(1)")
	query.Set("_txlock", "immediate")
	handle, err := sql.Open("sqlite", (&url.URL{Scheme: "file", Path: w.database(), RawQuery: query.Encode()}).String())
	if err != nil {
		w.t.Fatal(err)
	}
	handle.SetMaxOpenConns(1)
	w.t.Cleanup(func() { handle.Close() })
	return handle
}

func (w *workdir) binary(binary string, injected faults, arguments ...string) *process {
	w.t.Helper()
	return spawn(w.t, binary, injected.environment(), arguments...)
}

func (w *workdir) command(injected faults, arguments ...string) *process {
	w.t.Helper()
	return spawn(w.t, faultBinary, injected.environment(), append(arguments, "--workdir", w.dir)...)
}

func (w *workdir) runOnce(injected faults, options ...string) result {
	w.t.Helper()
	arguments := append([]string{"run", "--once", "--tick", "10ms"}, options...)
	run := w.command(injected, arguments...)
	code := run.wait()
	return result{code: code, events: run.snapshot(), output: run.output(), codes: run.errorCodes()}
}

func (w *workdir) control(action, workflow string) int {
	w.t.Helper()
	return w.command(faults{}, action, "--workflow", workflow).wait()
}

func (w *workdir) status() event {
	w.t.Helper()
	run := w.command(faults{}, "status")
	if code := run.wait(); code != 0 {
		w.t.Fatalf("status exited %d", code)
	}
	for _, e := range run.snapshot() {
		if e.name() == "status" {
			return e
		}
	}
	w.t.Fatal("no status event")
	return nil
}

func exec1(t *testing.T, db *sql.DB, query string, arguments ...any) int64 {
	t.Helper()
	result, err := db.Exec(query, arguments...)
	if err != nil {
		t.Fatalf("%s: %v", query, err)
	}
	id, _ := result.LastInsertId()
	return id
}

func scalar[T any](t *testing.T, db *sql.DB, query string, arguments ...any) T {
	t.Helper()
	var value T
	if err := db.QueryRow(query, arguments...).Scan(&value); err != nil {
		t.Fatalf("%s: %v", query, err)
	}
	return value
}

func rows(t *testing.T, db *sql.DB, query string, arguments ...any) [][]string {
	t.Helper()
	cursor, err := db.Query(query, arguments...)
	if err != nil {
		t.Fatalf("%s: %v", query, err)
	}
	defer cursor.Close()
	columns, _ := cursor.Columns()
	var all [][]string
	for cursor.Next() {
		values := make([]any, len(columns))
		pointers := make([]any, len(columns))
		for index := range values {
			pointers[index] = &values[index]
		}
		if err := cursor.Scan(pointers...); err != nil {
			t.Fatal(err)
		}
		line := make([]string, len(columns))
		for index, value := range values {
			switch typed := value.(type) {
			case nil:
				line[index] = "NULL"
			case []byte:
				line[index] = "blob:" + hex.EncodeToString(typed)
			default:
				line[index] = fmt.Sprintf("%T:%v", typed, typed)
			}
		}
		all = append(all, line)
	}
	return all
}

func tableDigest(t *testing.T, db *sql.DB, table string) string {
	t.Helper()
	hash := sha256.New()
	for _, line := range rows(t, db, `SELECT * FROM "`+table+`" ORDER BY rowid`) {
		fmt.Fprintln(hash, strings.Join(line, "\x1f"))
	}
	return hex.EncodeToString(hash.Sum(nil))
}

func digests(t *testing.T, db *sql.DB, skip ...string) map[string]string {
	t.Helper()
	skipped := map[string]bool{}
	for _, name := range skip {
		skipped[name] = true
	}
	result := map[string]string{}
	for _, line := range rows(t, db, `SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'wf_%'`) {
		name := line[0][len("string:"):]
		if !skipped[name] {
			result[name] = tableDigest(t, db, name)
		}
	}
	return result
}

func requireSame(t *testing.T, before, after map[string]string) {
	t.Helper()
	for table, digest := range before {
		if after[table] != digest {
			t.Errorf("table %s changed", table)
		}
	}
	if len(after) != len(before) {
		t.Errorf("table set changed")
	}
}

func setSettings(t *testing.T, db *sql.DB, values map[string]string) {
	t.Helper()
	for key, value := range values {
		exec1(t, db, `INSERT INTO settings (key, value, value_type, category, created_at, updated_at) VALUES (?, ?, 'string', 'audiobookshelf', datetime('now'), datetime('now')) ON CONFLICT (key) DO UPDATE SET value = excluded.value`, key, value)
	}
}

func (w *workdir) encrypt(plaintext string) string {
	block, _ := aes.NewCipher(deriveKey(w.keys.PrimaryKey, w.keys.Salt))
	aead, _ := cipher.NewGCM(block)
	nonce := bytes.Repeat([]byte{7}, 12)
	sealed := aead.Seal(nil, nonce, []byte(plaintext), nil)
	encoded, _ := json.Marshal(map[string]any{
		"p": base64.StdEncoding.EncodeToString(sealed[:len(sealed)-16]),
		"h": map[string]any{"iv": base64.StdEncoding.EncodeToString(nonce), "at": base64.StdEncoding.EncodeToString(sealed[len(sealed)-16:])},
	})
	return string(encoded)
}

func deriveKey(primary, salt string) []byte {
	key, err := pbkdf2.Key(sha256.New, primary, []byte(salt), 1<<16, 32)
	if err != nil {
		panic(err)
	}
	return key
}

func readAll(reader io.Reader) string {
	data, _ := io.ReadAll(reader)
	return string(data)
}

//go:build e2e

package e2e

import (
	"bytes"
	"compress/zlib"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/pbkdf2"
	"crypto/sha1"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"hash"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

const bundleEnvironment = "SHELFARR_COMPAT_BUNDLE"

var (
	binary    string
	pristine  string
	moduleDir string
)

func TestMain(m *testing.M) {
	os.Exit(setupAndRun(m))
}

func setupAndRun(m *testing.M) int {
	pristine = os.Getenv(bundleEnvironment)
	if pristine == "" {
		fmt.Fprintln(os.Stderr, bundleEnvironment+" must name a fixture bundle produced by tools/migration/produce_fixture.rb")
		return 2
	}
	var err error
	if moduleDir, err = filepath.Abs(".."); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	scratch, err := os.MkdirTemp("", "shelfarr-e2e-")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	defer os.RemoveAll(scratch)
	if binary, err = buildBinary(moduleDir, scratch, "pristine"); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	return m.Run()
}

func buildBinary(source, scratch, name string) (string, error) {
	output := filepath.Join(scratch, name)
	command := exec.Command("go", "build", "-trimpath", "-o", output, "./cmd/shelfarr-compat")
	command.Dir = source
	command.Env = append(os.Environ(), "CGO_ENABLED=0")
	if combined, err := command.CombinedOutput(); err != nil {
		return "", fmt.Errorf("build failed: %v\n%s", err, combined)
	}
	return output, nil
}

type checkReport struct {
	Name     string   `json:"name"`
	Status   string   `json:"status"`
	Cases    int      `json:"cases"`
	Failures []string `json:"failures"`
}

type report struct {
	Passed bool          `json:"passed"`
	Checks []checkReport `json:"checks"`
}

type outcome struct {
	code   int
	stdout string
	stderr string
	report report
}

func (o outcome) failed() []string {
	var names []string
	for _, check := range o.report.Checks {
		if check.Status != "pass" {
			names = append(names, check.Name)
		}
	}
	sort.Strings(names)
	return names
}

func (o outcome) check(name string) (checkReport, bool) {
	for _, check := range o.report.Checks {
		if check.Name == name {
			return check, true
		}
	}
	return checkReport{}, false
}

func execute(t *testing.T, executable, bundle string, arguments ...string) outcome {
	t.Helper()
	full := append([]string{"compat-check", "--bundle", bundle}, arguments...)
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, executable, full...)
	var stdout, stderr bytes.Buffer
	command.Stdout, command.Stderr = &stdout, &stderr
	err := command.Run()
	result := outcome{stdout: stdout.String(), stderr: stderr.String()}
	var exit *exec.ExitError
	switch {
	case err == nil:
	case errors.As(err, &exit):
		result.code = exit.ExitCode()
	default:
		t.Fatalf("could not run %s: %v", filepath.Base(executable), err)
	}
	if result.stdout != "" {
		if err := json.Unmarshal([]byte(result.stdout), &result.report); err != nil {
			t.Fatalf("report is not json: %v", err)
		}
	}
	return result
}

type variant struct {
	t        *testing.T
	dir      string
	manifest map[string]any
}

func readFile(t *testing.T, path string) []byte {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func writeFile(t *testing.T, path string, data []byte, mode os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
}

func newVariant(t *testing.T) *variant {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "variant")
	current := &variant{t: t, dir: dir}
	if err := json.Unmarshal(readFile(t, filepath.Join(pristine, "manifest.json")), &current.manifest); err != nil {
		t.Fatal(err)
	}
	for name := range current.files() {
		mode := os.FileMode(0o640)
		if strings.HasPrefix(name, "secrets/") {
			mode = 0o600
		}
		writeFile(t, filepath.Join(dir, name), readFile(t, filepath.Join(pristine, name)), mode)
	}
	if err := os.Chmod(filepath.Join(dir, "secrets"), 0o700); err != nil {
		t.Fatal(err)
	}
	current.seal()
	return current
}

func (v *variant) files() map[string]any {
	return v.manifest["files"].(map[string]any)
}

func (v *variant) path(name string) string {
	return filepath.Join(v.dir, filepath.FromSlash(name))
}

func (v *variant) seal() {
	v.t.Helper()
	for name := range v.files() {
		data := readFile(v.t, v.path(name))
		sum := sha256.Sum256(data)
		v.files()[name] = map[string]any{"sha256": hex.EncodeToString(sum[:]), "size": len(data)}
	}
	encoded, err := json.Marshal(v.manifest)
	if err != nil {
		v.t.Fatal(err)
	}
	writeFile(v.t, v.path("manifest.json"), encoded, 0o640)
}

func (v *variant) editJSON(name string, change func(map[string]any)) {
	v.t.Helper()
	var document map[string]any
	if err := json.Unmarshal(readFile(v.t, v.path(name)), &document); err != nil {
		v.t.Fatal(err)
	}
	change(document)
	encoded, err := json.Marshal(document)
	if err != nil {
		v.t.Fatal(err)
	}
	mode := os.FileMode(0o640)
	if strings.HasPrefix(name, "secrets/") {
		mode = 0o600
	}
	writeFile(v.t, v.path(name), encoded, mode)
}

func (v *variant) editDatabase(statements ...string) {
	v.t.Helper()
	handle, err := sql.Open("sqlite", v.path("db/primary.sqlite3"))
	if err != nil {
		v.t.Fatal(err)
	}
	for _, statement := range statements {
		result, err := handle.Exec(statement)
		if err != nil {
			v.t.Fatalf("%s: %v", statement, err)
		}
		if changed, _ := result.RowsAffected(); changed == 0 && strings.HasPrefix(strings.ToUpper(statement), "UPDATE") {
			v.t.Fatalf("statement changed nothing: %s", statement)
		}
	}
	if _, err := handle.Exec("PRAGMA wal_checkpoint(TRUNCATE)"); err != nil {
		v.t.Fatal(err)
	}
	if err := handle.Close(); err != nil {
		v.t.Fatal(err)
	}
	if leftovers, _ := filepath.Glob(v.path("db/primary.sqlite3-*")); len(leftovers) != 0 {
		v.t.Fatalf("edit left sidecars: %v", leftovers)
	}
}

func (v *variant) credentials() map[string]any {
	var document map[string]any
	if err := json.Unmarshal(readFile(v.t, v.path("secrets/credentials.json")), &document); err != nil {
		v.t.Fatal(err)
	}
	return document
}

func deriveKey(digest func() hash.Hash, primary, salt string) []byte {
	key, err := pbkdf2.Key(digest, primary, []byte(salt), 1<<16, 32)
	if err != nil {
		panic(err)
	}
	return key
}

func envelopeFor(primary, salt string, plaintext []byte, compress bool) string {
	payload := plaintext
	if compress {
		var buffer bytes.Buffer
		writer := zlib.NewWriter(&buffer)
		writer.Write(plaintext)
		writer.Close()
		payload = buffer.Bytes()
	}
	block, _ := aes.NewCipher(deriveKey(sha256.New, primary, salt))
	aead, _ := cipher.NewGCM(block)
	nonce := bytes.Repeat([]byte{3}, 12)
	sealed := aead.Seal(nil, nonce, payload, nil)
	headers := map[string]any{
		"iv": base64.StdEncoding.EncodeToString(nonce),
		"at": base64.StdEncoding.EncodeToString(sealed[len(sealed)-16:]),
	}
	if compress {
		headers["c"] = true
	}
	encoded, _ := json.Marshal(map[string]any{"p": base64.StdEncoding.EncodeToString(sealed[:len(sealed)-16]), "h": headers})
	return string(encoded)
}

func independentDecrypt(primary, salt, envelope string) ([]byte, error) {
	var parsed struct {
		P string         `json:"p"`
		H map[string]any `json:"h"`
	}
	if err := json.Unmarshal([]byte(envelope), &parsed); err != nil {
		return nil, err
	}
	payload, _ := base64.StdEncoding.DecodeString(parsed.P)
	nonce, _ := base64.StdEncoding.DecodeString(parsed.H["iv"].(string))
	tag, _ := base64.StdEncoding.DecodeString(parsed.H["at"].(string))
	for _, digest := range []func() hash.Hash{sha256.New, sha1.New} {
		block, _ := aes.NewCipher(deriveKey(digest, primary, salt))
		aead, _ := cipher.NewGCM(block)
		if plain, err := aead.Open(nil, nonce, append(payload, tag...), nil); err == nil {
			return plain, nil
		}
	}
	return nil, errors.New("not decryptable")
}

func jsonUnmarshal(data []byte, target any) error {
	return json.Unmarshal(data, target)
}

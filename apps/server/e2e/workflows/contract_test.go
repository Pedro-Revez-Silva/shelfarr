//go:build e2e

package workflows

import (
	"crypto/sha256"
	"encoding/hex"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func bundleFingerprint(t *testing.T, bundle string) map[string]string {
	t.Helper()
	found := map[string]string{}
	err := filepath.WalkDir(bundle, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		relative, _ := filepath.Rel(bundle, path)
		if entry.IsDir() {
			found[relative] = "dir " + info.ModTime().String()
			return nil
		}
		if entry.Type()&fs.ModeSymlink != 0 {
			target, _ := os.Readlink(path)
			found[relative] = "link " + target
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		sum := sha256.Sum256(data)
		found[relative] = hex.EncodeToString(sum[:]) + " " + info.ModTime().String() + " " + info.Mode().String()
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return found
}

func TestPrepareMakesAPrivateConsistentCopyAndNeverTouchesTheBundle(t *testing.T) {
	for name, bundle := range map[string]string{"current schema": currentBundle, "upgraded released schema": upgradeBundle} {
		t.Run(name, func(t *testing.T) {
			before := bundleFingerprint(t, bundle)
			work := prepare(t, bundle)
			db := work.open()
			source := openReadOnly(t, filepath.Join(bundle, "db", "primary.sqlite3"))
			for _, line := range rows(t, source, `SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'`) {
				table := strings.TrimPrefix(line[0], "string:")
				if tableDigest(t, db, table) != tableDigest(t, source, table) {
					t.Errorf("table %s differs from the bundle", table)
				}
			}
			for _, pragma := range []string{"user_version", "application_id"} {
				if scalar[int64](t, db, `PRAGMA `+pragma) != scalar[int64](t, source, `PRAGMA `+pragma) {
					t.Errorf("%s differs", pragma)
				}
			}
			if !reflect.DeepEqual(rows(t, db, `SELECT * FROM sqlite_sequence ORDER BY name`), rows(t, source, `SELECT * FROM sqlite_sequence ORDER BY name`)) {
				t.Error("autoincrement counters differ")
			}
			if mode := scalar[string](t, db, `PRAGMA journal_mode`); mode != "wal" {
				t.Errorf("journal mode %s", mode)
			}
			if verdict := scalar[string](t, db, `PRAGMA integrity_check`); verdict != "ok" {
				t.Errorf("integrity %s", verdict)
			}
			if violations := rows(t, db, `PRAGMA foreign_key_check`); len(violations) != len(rows(t, source, `PRAGMA foreign_key_check`)) {
				t.Errorf("foreign key violations %v", violations)
			}
			info, _ := os.Stat(work.dir)
			if info.Mode().Perm() != 0o700 {
				t.Errorf("workdir mode %v", info.Mode().Perm())
			}
			for _, file := range []string{"workflows.sqlite3", "WORKDIR.json", "encryption.json"} {
				info, err := os.Stat(filepath.Join(work.dir, file))
				if err != nil || info.Mode().Perm()&0o077 != 0 {
					t.Errorf("%s: %v %v", file, err, info)
				}
			}
			work.runOnce(faults{})
			if !reflect.DeepEqual(before, bundleFingerprint(t, bundle)) {
				t.Fatal("the fixture bundle was modified")
			}
		})
	}
}

func openReadOnly(t *testing.T, path string) *sqlDB {
	t.Helper()
	return openImmutable(t, path)
}

func TestPrepareRefusesWhatItCannotProveDisposable(t *testing.T) {
	existing := t.TempDir()
	marker := filepath.Join(existing, "keep")
	os.WriteFile(marker, []byte("x"), 0o600)
	cases := map[string][]string{
		"existing workdir":       {"prepare", "--bundle", currentBundle, "--workdir", existing},
		"missing bundle":         {"prepare", "--bundle", filepath.Join(t.TempDir(), "nothing"), "--workdir", filepath.Join(t.TempDir(), "w1")},
		"directory not a bundle": {"prepare", "--bundle", t.TempDir(), "--workdir", filepath.Join(t.TempDir(), "w2")},
	}
	for name, arguments := range cases {
		t.Run(name, func(t *testing.T) {
			run := spawn(t, plainBinary, nil, arguments...)
			if code := run.wait(); code != 6 {
				t.Fatalf("exit %d: %s", code, run.output())
			}
			if arguments[len(arguments)-1] != existing {
				if _, err := os.Stat(arguments[len(arguments)-1]); err == nil {
					t.Fatal("a refused prepare left a workdir")
				}
			}
		})
	}
	if _, err := os.Stat(marker); err != nil {
		t.Fatal("a refused prepare removed a directory it did not create")
	}
}

func TestPrepareRefusesATamperedBundle(t *testing.T) {
	copyDir := filepath.Join(t.TempDir(), "bundle")
	if err := copyTree(currentBundle, copyDir); err != nil {
		t.Fatal(err)
	}
	database := filepath.Join(copyDir, "db", "primary.sqlite3")
	file, err := os.OpenFile(database, os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		t.Fatal(err)
	}
	file.Write([]byte{0})
	file.Close()
	target := filepath.Join(t.TempDir(), "work")
	run := spawn(t, plainBinary, nil, "prepare", "--bundle", copyDir, "--workdir", target)
	if code := run.wait(); code != 6 {
		t.Fatalf("exit %d: %s", code, run.output())
	}
	if _, err := os.Stat(target); err == nil {
		t.Fatal("a workdir exists for a tampered bundle")
	}
}

func copyTree(source, destination string) error {
	return filepath.WalkDir(source, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		relative, _ := filepath.Rel(source, path)
		target := filepath.Join(destination, relative)
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return os.MkdirAll(target, info.Mode().Perm()|0o700)
		}
		if info.Mode()&os.ModeSymlink != 0 {
			link, _ := os.Readlink(path)
			return os.Symlink(link, target)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		return os.WriteFile(target, data, info.Mode().Perm())
	})
}

func TestRunOnlyAcceptsADirectoryPreparedFromABundle(t *testing.T) {
	prepared := prepare(t, currentBundle)
	cases := map[string]func(t *testing.T) string{
		"empty directory": func(t *testing.T) string { return privateDir(t) },
		"database without the marker table": func(t *testing.T) string {
			dir := privateDir(t)
			copyFile(t, filepath.Join(currentBundle, "db", "primary.sqlite3"), filepath.Join(dir, "workflows.sqlite3"))
			copyFile(t, filepath.Join(prepared.dir, "WORKDIR.json"), filepath.Join(dir, "WORKDIR.json"))
			copyFile(t, filepath.Join(prepared.dir, "encryption.json"), filepath.Join(dir, "encryption.json"))
			return dir
		},
		"marker token that does not match": func(t *testing.T) string {
			dir := privateDir(t)
			copyFile(t, prepared.database(), filepath.Join(dir, "workflows.sqlite3"))
			os.WriteFile(filepath.Join(dir, "WORKDIR.json"), []byte(`{"format":1,"token":"not-the-token"}`), 0o600)
			copyFile(t, filepath.Join(prepared.dir, "encryption.json"), filepath.Join(dir, "encryption.json"))
			return dir
		},
		"group readable directory": func(t *testing.T) string {
			dir := filepath.Join(t.TempDir(), "d")
			if err := copyTree(prepared.dir, dir); err != nil {
				t.Fatal(err)
			}
			os.Chmod(dir, 0o750)
			return dir
		},
		"symbolic link to a prepared directory": func(t *testing.T) string {
			link := filepath.Join(t.TempDir(), "link")
			os.Symlink(prepared.dir, link)
			return link
		},
	}
	for name, build := range cases {
		t.Run(name, func(t *testing.T) {
			dir := build(t)
			before := bundleFingerprint(t, dir)
			for _, action := range [][]string{{"run", "--once"}, {"trigger", "--workflow", "inventory"}, {"status"}} {
				run := spawn(t, plainBinary, nil, append(action, "--workdir", dir)...)
				if code := run.wait(); code != 5 {
					t.Fatalf("%v exited %d: %s", action, code, run.output())
				}
			}
			if !reflect.DeepEqual(before, bundleFingerprint(t, dir)) {
				t.Fatal("a refused command modified the directory")
			}
		})
	}
}

func privateDir(t *testing.T) string {
	dir := filepath.Join(t.TempDir(), "d")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	return dir
}

func copyFile(t *testing.T, from, to string) {
	t.Helper()
	data, err := os.ReadFile(from)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(to, data, 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestThereIsNoWayToPointTheExecutableAtADatabaseOrAnEnvironment(t *testing.T) {
	for _, arguments := range [][]string{
		{"run", "--database", "/does/not/matter.sqlite3"},
		{"run"},
		{"run", "--workdir", t.TempDir(), "--env-file", ".env"},
		{"status", "--database", "x"},
		{"prepare", "--bundle", currentBundle},
		{"unknown"},
		{},
	} {
		run := spawn(t, plainBinary, nil, arguments...)
		if code := run.wait(); code != 2 {
			t.Errorf("%v exited %d: %s", arguments, code, run.output())
		}
	}
	for _, directory := range []string{"../../cmd/shelfarr-workflows", "../../internal/wfstore", "../../internal/inventory", "../../internal/monitor", "../../internal/abs", "../../internal/qbit", "../../internal/netguard"} {
		entries, err := os.ReadDir(directory)
		if err != nil {
			t.Fatal(err)
		}
		for _, entry := range entries {
			if !strings.HasSuffix(entry.Name(), ".go") || strings.HasSuffix(entry.Name(), "_test.go") {
				continue
			}
			text, _ := os.ReadFile(filepath.Join(directory, entry.Name()))
			for _, forbidden := range []string{"os.Getenv", "os.LookupEnv", "os.Environ", "godotenv", ".env", "storage/production", "development.sqlite3"} {
				if strings.Contains(string(text), forbidden) {
					t.Errorf("%s/%s mentions %s", directory, entry.Name(), forbidden)
				}
			}
		}
	}
}

func TestTheShippedBinaryHasNoFailpoints(t *testing.T) {
	work := prepare(t, currentBundle)
	db := work.open()
	abs := newABS(t, libraryOf("lib-a", "One"))
	work.configureABS(db, abs, "lib-a")
	injected := newFaults(t, map[string]string{"inventory.before-publish": "kill", "inventory.admitted": "panic", "inventory.library-fetched": "error"})
	run := spawn(t, plainBinary, injected.environment(), "run", "--once", "--workflows", "inventory", "--workdir", work.dir)
	if code := run.wait(); code != 0 {
		t.Fatalf("exit %d: %s", code, run.output())
	}
	if count := scalar[int64](t, db, `SELECT COUNT(*) FROM library_items WHERE library_id = 'lib-a'`); count != 1 {
		t.Fatalf("inventory %d", count)
	}
}

func TestDestinationsOutsideLoopbackAreNeverContacted(t *testing.T) {
	work := prepare(t, currentBundle)
	db := work.open()
	setSettings(t, db, map[string]string{"audiobookshelf_url": "http://192.0.2.1:9", "audiobookshelf_api_key": absKey, "audiobookshelf_audiobook_library_id": "lib-a"})
	client := work.seedClient(db, "http://192.0.2.7:9", qbitPassword, true)
	seed := work.seedDownload(db, client, hashOf(50))
	exec1(t, db, `UPDATE downloads SET status = 1 WHERE id = ?`, seed.Download)
	work.control("trigger", "downloads")
	outcome := work.runOnce(faults{}, "--handoff-url", "http://192.0.2.9:9/hook", "--request-timeout", "1s")
	if outcome.code != 1 {
		t.Fatalf("exit %d: %s", outcome.code, outcome.output)
	}
	if got := rows(t, db, `SELECT error_code FROM wf_download_state`); !reflect.DeepEqual(got, [][]string{{"string:destination-refused"}}) {
		t.Fatalf("download state %v", got)
	}
	if got := rows(t, db, `SELECT error_code FROM wf_inventory_libraries`); !reflect.DeepEqual(got, [][]string{{"string:destination-refused"}}) {
		t.Fatalf("library state %v", got)
	}
}

func TestAutomaticDiscoveryScansOnlyBookLibrariesAndEmptyDiscoveryNeverPrunes(t *testing.T) {
	work := prepare(t, currentBundle)
	db := work.open()
	books := libraryOf("lib-a", "One")
	podcasts := &fakeLibrary{ID: "lib-pod", MediaType: "podcast", Items: libraryOf("lib-pod", "Episode").Items}
	abs := newABS(t, books, podcasts)
	work.configureABS(db, abs)
	seedItem(t, db, "audiobookshelf", "lib-a", "stale", "Stale", "2025-06-01 00:00:00.000000")
	seedItem(t, db, "audiobookshelf", "lib-pod", "pod", "Podcast data from before", "2025-06-01 00:00:00.000000")
	outcome := work.runOnce(faults{}, "--workflows", "inventory")
	if outcome.code != 0 {
		t.Fatalf("exit %d: %s", outcome.code, outcome.output)
	}
	got := rows(t, db, `SELECT library_id, audiobookshelf_id FROM library_items ORDER BY 1, 2`)
	if !reflect.DeepEqual(got, [][]string{{"string:lib-a", "string:lib-a-one"}}) {
		t.Fatalf("inventory %v", got)
	}
	abs.mutex.Lock()
	abs.libraries = nil
	abs.mutex.Unlock()
	before := digests(t, db, "wf_none")
	work.control("trigger", "inventory")
	empty := work.runOnce(faults{}, "--workflows", "inventory")
	if empty.code != 0 {
		t.Fatalf("exit %d", empty.code)
	}
	requireSame(t, before, digests(t, db, "wf_none"))
	if outcome := scalar[string](t, db, `SELECT outcome FROM wf_inventory_runs ORDER BY id DESC LIMIT 1`); !strings.Contains(outcome, "no-libraries") {
		t.Fatalf("outcome %s", outcome)
	}
	abs.setHook(func(id string, page int, w http.ResponseWriter, r *http.Request) bool { return false })
}

func TestUnconfiguredAndUnsupportedPlatformsAdmitNothing(t *testing.T) {
	work := prepare(t, currentBundle)
	db := work.open()
	before := digests(t, db, "wf_none")
	if outcome := work.runOnce(faults{}, "--workflows", "inventory"); outcome.code != 0 {
		t.Fatalf("exit %d", outcome.code)
	}
	if outcome := scalar[string](t, db, `SELECT last_outcome FROM wf_schedule WHERE workflow = 'inventory'`); outcome != "not-configured" {
		t.Fatalf("outcome %s", outcome)
	}
	abs := newABS(t, libraryOf("lib-a", "One"))
	work.configureABS(db, abs, "lib-a")
	setSettings(t, db, map[string]string{"library_platform": "grimmory"})
	work.control("trigger", "inventory")
	if outcome := work.runOnce(faults{}, "--workflows", "inventory"); outcome.code != 0 {
		t.Fatalf("exit %d", outcome.code)
	}
	if outcome := scalar[string](t, db, `SELECT last_outcome FROM wf_schedule WHERE workflow = 'inventory'`); outcome != "platform-unsupported" {
		t.Fatalf("outcome %s", outcome)
	}
	if runs := scalar[int64](t, db, `SELECT COUNT(*) FROM wf_inventory_runs`); runs != 0 {
		t.Fatalf("runs %d", runs)
	}
	after := digests(t, db, "wf_none")
	delete(before, "settings")
	delete(after, "settings")
	requireSame(t, before, after)
}

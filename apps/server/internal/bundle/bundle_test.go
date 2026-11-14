package bundle

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

type scenario struct {
	dir      string
	manifest Manifest
}

func digestOf(data []byte) FileEntry {
	sum := sha256.Sum256(data)
	return FileEntry{SHA256: hex.EncodeToString(sum[:]), Size: int64(len(data))}
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

func newScenario(t *testing.T) *scenario {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(root, "bundle")
	media := filepath.Join(root, "media")
	files := map[string][]byte{
		"db/primary.sqlite3":             []byte("SQLite format 3\x00"),
		"expected/identity-vectors.json": []byte(`{}`),
		"expected/library-assets.json":   []byte(`{}`),
		"expected/accounts.json":         []byte(`{}`),
		"expected/encryption.json":       []byte(`{}`),
		"expected/responses.json":        []byte(`{}`),
		"secrets/credentials.json":       []byte(`{}`),
	}
	manifest := Manifest{
		FixtureFormat: SupportedFormat, Origin: "test", Schema: Schema{Revision: "1"}, MediaRoot: media,
		Database: Database{Path: "db/primary.sqlite3"}, Coverage: Coverage{Digest: "d"}, Files: map[string]FileEntry{},
	}
	for name, data := range files {
		mode := os.FileMode(0o640)
		if strings.HasPrefix(name, "secrets/") {
			mode = 0o600
		}
		writeFile(t, filepath.Join(dir, name), data, mode)
		manifest.Files[name] = digestOf(data)
	}
	if err := os.Chmod(filepath.Join(dir, "secrets"), 0o700); err != nil {
		t.Fatal(err)
	}
	track := []byte("audio")
	writeFile(t, filepath.Join(media, "a.mp3"), track, 0o644)
	if err := os.Symlink(filepath.Join(media, "a.mp3"), filepath.Join(media, "link")); err != nil {
		t.Fatal(err)
	}
	manifest.ExternalTrees = []Tree{{Name: "media", Root: media, Files: map[string]FileEntry{"a.mp3": digestOf(track)}, Symlinks: map[string]string{"link": filepath.Join(media, "a.mp3")}}}
	result := &scenario{dir: dir, manifest: manifest}
	result.save(t)
	return result
}

func (s *scenario) save(t *testing.T) {
	t.Helper()
	encoded, err := json.Marshal(s.manifest)
	if err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(s.dir, "manifest.json"), encoded, 0o640)
}

func expectCode(t *testing.T, dir, code string) {
	t.Helper()
	opened, err := Open(context.Background(), dir)
	if err == nil {
		t.Fatalf("opened (%v), want %s", opened != nil, code)
	}
	if !IsCode(err, code) {
		t.Fatalf("error = %v, want code %s", err, code)
	}
	if strings.Contains(err.Error(), filepath.Dir(dir)) {
		t.Fatalf("error leaks an absolute path: %v", err)
	}
}

func TestOpenAcceptsConsistentBundle(t *testing.T) {
	scenario := newScenario(t)
	opened, err := Open(context.Background(), scenario.dir)
	if err != nil {
		t.Fatal(err)
	}
	before, err := opened.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	after, err := opened.Snapshot(context.Background())
	if err != nil || len(before.Differences(after)) != 0 {
		t.Fatalf("unchanged tree differs: %v %v", before.Differences(after), err)
	}
}

func TestOpenRejects(t *testing.T) {
	cases := map[string]struct {
		code   string
		mutate func(*testing.T, *scenario)
	}{
		"corrupted database": {"hash-mismatch", func(t *testing.T, s *scenario) {
			writeFile(t, filepath.Join(s.dir, "db/primary.sqlite3"), []byte("SQLite format 3\x01"), 0o640)
		}},
		"truncated database": {"size-mismatch", func(t *testing.T, s *scenario) {
			writeFile(t, filepath.Join(s.dir, "db/primary.sqlite3"), []byte("SQLite"), 0o640)
		}},
		"missing document": {"missing", func(t *testing.T, s *scenario) {
			os.Remove(filepath.Join(s.dir, "expected/accounts.json"))
		}},
		"unlisted file": {"unexpected-file", func(t *testing.T, s *scenario) {
			writeFile(t, filepath.Join(s.dir, "db/extra.bin"), []byte("x"), 0o640)
		}},
		"wal sidecar": {"unexpected-file", func(t *testing.T, s *scenario) {
			writeFile(t, filepath.Join(s.dir, "db/primary.sqlite3-wal"), nil, 0o640)
		}},
		"symlink inside bundle": {"unexpected-entry", func(t *testing.T, s *scenario) {
			os.Symlink("/etc/hostname", filepath.Join(s.dir, "db/link"))
		}},
		"unlisted media file": {"unexpected-file", func(t *testing.T, s *scenario) {
			writeFile(t, filepath.Join(s.manifest.ExternalTrees[0].Root, "extra.mp3"), []byte("x"), 0o644)
		}},
		"changed media file": {"hash-mismatch", func(t *testing.T, s *scenario) {
			writeFile(t, filepath.Join(s.manifest.ExternalTrees[0].Root, "a.mp3"), []byte("AUDIO"), 0o644)
		}},
		"redirected media symlink": {"symlink-mismatch", func(t *testing.T, s *scenario) {
			root := s.manifest.ExternalTrees[0].Root
			os.Remove(filepath.Join(root, "link"))
			os.Symlink("/etc/hostname", filepath.Join(root, "link"))
		}},
		"missing media tree": {"missing-tree", func(t *testing.T, s *scenario) {
			os.RemoveAll(s.manifest.ExternalTrees[0].Root)
		}},
		"group readable secrets": {"secrets-not-private", func(t *testing.T, s *scenario) {
			os.Chmod(filepath.Join(s.dir, "secrets/credentials.json"), 0o640)
		}},
		"world readable secrets directory": {"secrets-not-private", func(t *testing.T, s *scenario) {
			os.Chmod(filepath.Join(s.dir, "secrets"), 0o755)
		}},
		"unsafe manifest path": {"unsafe-path", func(t *testing.T, s *scenario) {
			s.manifest.Files["../escape"] = FileEntry{SHA256: "x"}
			s.save(t)
		}},
		"unsupported format": {"unsupported-format", func(t *testing.T, s *scenario) {
			s.manifest.FixtureFormat = 99
			s.save(t)
		}},
		"relative media root": {"unsafe-path", func(t *testing.T, s *scenario) {
			s.manifest.ExternalTrees[0].Root = "media"
			s.save(t)
		}},
		"unknown manifest field": {"malformed", func(t *testing.T, s *scenario) {
			writeFile(t, filepath.Join(s.dir, "manifest.json"), []byte(`{"fixture_format":1,"surprise":true}`), 0o640)
		}},
		"oversized manifest": {"too-large", func(t *testing.T, s *scenario) {
			writeFile(t, filepath.Join(s.dir, "manifest.json"), []byte(`{"origin":"`+strings.Repeat("a", MaxManifestBytes)+`"}`), 0o640)
		}},
		"closing bracket after manifest": {"malformed", func(t *testing.T, s *scenario) {
			encoded, _ := json.Marshal(s.manifest)
			writeFile(t, filepath.Join(s.dir, "manifest.json"), append(encoded, ']'), 0o640)
		}},
		"manifest is a fifo": {"unreadable", func(t *testing.T, s *scenario) {
			os.Remove(filepath.Join(s.dir, "manifest.json"))
			if err := syscall.Mkfifo(filepath.Join(s.dir, "manifest.json"), 0o600); err != nil {
				t.Fatal(err)
			}
		}},
		"manifest is a symlink": {"unreadable", func(t *testing.T, s *scenario) {
			target := filepath.Join(s.dir, "manifest.real")
			os.Rename(filepath.Join(s.dir, "manifest.json"), target)
			os.Symlink(target, filepath.Join(s.dir, "manifest.json"))
		}},
		"trailing data after manifest": {"malformed", func(t *testing.T, s *scenario) {
			encoded, _ := json.Marshal(s.manifest)
			writeFile(t, filepath.Join(s.dir, "manifest.json"), append(encoded, []byte(` {}`)...), 0o640)
		}},
	}
	for name, testCase := range cases {
		t.Run(name, func(t *testing.T) {
			scenario := newScenario(t)
			testCase.mutate(t, scenario)
			expectCode(t, scenario.dir, testCase.code)
		})
	}
}

func TestOpenRejectsNonDirectory(t *testing.T) {
	file := filepath.Join(t.TempDir(), "file")
	writeFile(t, file, nil, 0o600)
	expectCode(t, file, "not-a-directory")
	expectCode(t, filepath.Join(t.TempDir(), "absent"), "not-a-directory")
}

func TestOpenHonoursCancellation(t *testing.T) {
	scenario := newScenario(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := Open(ctx, scenario.dir); err == nil {
		t.Fatal("cancelled context accepted")
	}
}

func TestSnapshotReportsEveryKindOfChange(t *testing.T) {
	scenario := newScenario(t)
	opened, err := Open(context.Background(), scenario.dir)
	if err != nil {
		t.Fatal(err)
	}
	before, _ := opened.Snapshot(context.Background())
	writeFile(t, filepath.Join(scenario.dir, "db/primary.sqlite3-wal"), nil, 0o640)
	os.Remove(filepath.Join(scenario.manifest.ExternalTrees[0].Root, "link"))
	writeFile(t, filepath.Join(scenario.dir, "db/primary.sqlite3"), []byte("SQLite format 3\x00 x"), 0o640)
	after, _ := opened.Snapshot(context.Background())
	changes := strings.Join(before.Differences(after), ",")
	for _, expected := range []string{"added:bundle:db/primary.sqlite3-wal", "removed:tree:media:link", "changed:bundle:db/primary.sqlite3"} {
		if !strings.Contains(changes, expected) {
			t.Errorf("missing %s in %s", expected, changes)
		}
	}
	if !IsSidecar("primary.sqlite3-wal") || !IsSidecar("x-shm") || !IsSidecar("x-journal") || IsSidecar("primary.sqlite3") {
		t.Error("sidecar detection")
	}
}

func TestErrorsDoNotEchoBundleControlledText(t *testing.T) {
	hostile := "/private/synthetic-sensitive-library"
	scenario := newScenario(t)
	scenario.manifest.ExternalTrees[0].Name = hostile
	scenario.manifest.ExternalTrees[0].Root = filepath.Join(filepath.Dir(scenario.dir), "absent-tree")
	scenario.save(t)
	_, err := Open(context.Background(), scenario.dir)
	if err == nil || strings.Contains(err.Error(), "private") || strings.Contains(err.Error(), "absent-tree") {
		t.Fatalf("error = %v", err)
	}
	other := newScenario(t)
	writeFile(t, filepath.Join(other.dir, "db", "hostile-\x1b[31m-name.bin"), []byte("x"), 0o640)
	if _, err := Open(context.Background(), other.dir); err == nil || strings.Contains(err.Error(), "hostile") {
		t.Fatalf("error = %v", err)
	}
}

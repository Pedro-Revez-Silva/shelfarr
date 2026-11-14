//go:build e2e

package e2e

import (
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"syscall"
	"testing"
)

var allChecks = []string{"consumer-projection", "encrypted-columns", "identity-vectors", "library-assets", "passwords", "read-only", "schema-revision", "tampered-envelopes"}

func TestPristineBundlePassesEveryCheck(t *testing.T) {
	result := execute(t, binary, pristine, "--legacy-sha1")
	if result.code != 0 || !result.report.Passed {
		t.Fatalf("exit %d, failed checks %v, stderr %q", result.code, result.failed(), result.stderr)
	}
	var names []string
	for _, check := range result.report.Checks {
		names = append(names, check.Name)
		if check.Cases == 0 {
			t.Errorf("%s ran no cases", check.Name)
		}
	}
	sort.Strings(names)
	if !reflect.DeepEqual(names, allChecks) {
		t.Fatalf("checks = %v", names)
	}
	minimums := map[string]int{"identity-vectors": 10, "library-assets": 10, "passwords": 15, "encrypted-columns": 8, "tampered-envelopes": 12, "consumer-projection": 40}
	for name, minimum := range minimums {
		if check, _ := result.check(name); check.Cases < minimum {
			t.Errorf("%s ran %d cases, want at least %d", name, check.Cases, minimum)
		}
	}
}

func TestOutputNeverCarriesSecretsOrPaths(t *testing.T) {
	scrubbed := []string{pristine, filepath.Dir(pristine)}
	credentials := (&variant{t: t, dir: pristine}).credentials()
	scrubbed = append(scrubbed, stringsIn(credentials)...)
	var manifest map[string]any
	(&variant{t: t, dir: pristine}).editManifest(&manifest)
	scrubbed = append(scrubbed, manifest["media_root"].(string))
	runs := []outcome{execute(t, binary, pristine, "--legacy-sha1"), execute(t, binary, pristine)}
	broken := newVariant(t)
	broken.editJSON("secrets/credentials.json", func(document map[string]any) {
		document["encryption"].(map[string]any)["primary_key"] = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
	})
	broken.seal()
	runs = append(runs, execute(t, binary, broken.dir, "--legacy-sha1"), execute(t, binary, filepath.Join(pristine, "absent")))
	for _, result := range runs {
		combined := result.stdout + result.stderr
		for _, secret := range scrubbed {
			if len(secret) >= 8 && strings.Contains(combined, secret) {
				t.Fatalf("output contains protected text of length %d", len(secret))
			}
		}
	}
}

func stringsIn(value any) []string {
	switch typed := value.(type) {
	case string:
		return []string{typed}
	case map[string]any:
		var result []string
		for _, element := range typed {
			result = append(result, stringsIn(element)...)
		}
		return result
	case []any:
		var result []string
		for _, element := range typed {
			result = append(result, stringsIn(element)...)
		}
		return result
	}
	return nil
}

func (v *variant) editManifest(target *map[string]any) {
	v.t.Helper()
	*target = map[string]any{}
	if err := jsonUnmarshal(readFile(v.t, v.path("manifest.json")), target); err != nil {
		v.t.Fatal(err)
	}
}

type treeState struct {
	kind    fs.FileMode
	size    int64
	mtime   int64
	ctime   int64
	inode   uint64
	content string
}

func snapshotTree(t *testing.T, root string) map[string]treeState {
	t.Helper()
	state := map[string]treeState{}
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		info, err := os.Lstat(path)
		if err != nil {
			return err
		}
		raw := info.Sys().(*syscall.Stat_t)
		current := treeState{kind: info.Mode(), size: info.Size(), mtime: raw.Mtim.Nano(), ctime: raw.Ctim.Nano(), inode: raw.Ino}
		if info.Mode().IsRegular() {
			current.content = string(readFile(t, path))
		}
		state[path] = current
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return state
}

func TestCheckerNeverWritesToTheBundleOrMedia(t *testing.T) {
	var manifest map[string]any
	(&variant{t: t, dir: pristine}).editManifest(&manifest)
	roots := []string{pristine}
	for _, tree := range manifest["external_trees"].([]any) {
		roots = append(roots, tree.(map[string]any)["root"].(string))
	}
	before := map[string]map[string]treeState{}
	for _, root := range roots {
		before[root] = snapshotTree(t, root)
	}
	for _, arguments := range [][]string{{"--legacy-sha1"}, {}} {
		execute(t, binary, pristine, arguments...)
	}
	for _, root := range roots {
		after := snapshotTree(t, root)
		if !reflect.DeepEqual(before[root], after) {
			t.Fatalf("tree %s changed", filepath.Base(root))
		}
		for path := range after {
			if strings.HasSuffix(path, "-wal") || strings.HasSuffix(path, "-shm") || strings.HasSuffix(path, "-journal") {
				t.Fatalf("sidecar %s present", filepath.Base(path))
			}
		}
	}
}

func TestLegacySHA1IsOptIn(t *testing.T) {
	result := execute(t, binary, pristine)
	if result.code != 1 || !reflect.DeepEqual(result.failed(), []string{"encrypted-columns"}) {
		t.Fatalf("exit %d, failed %v", result.code, result.failed())
	}
	check, _ := result.check("encrypted-columns")
	want := []string{"users.otp_secret#2:decryption", "users.backup_codes#2:decryption"}
	if !reflect.DeepEqual(check.Failures, want) {
		t.Fatalf("failures = %v, want %v", check.Failures, want)
	}
}

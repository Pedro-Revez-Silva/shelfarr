//go:build e2e

package e2e

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"math"
	"net/url"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
)

const releasedSource = "db/released-source.sqlite3"

var intentionalPostUpgradeChanges = map[string]map[string]bool{"api_tokens": {"last_used_at": true, "updated_at": true}}

func openImmutable(t *testing.T, path string) *sql.DB {
	t.Helper()
	handle, err := sql.Open("sqlite", "file:"+url.PathEscape(path)+"?mode=ro&immutable=1")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { handle.Close() })
	return handle
}

func tableNames(t *testing.T, handle *sql.DB) []string {
	t.Helper()
	rows, err := handle.Query("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var names []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			t.Fatal(err)
		}
		names = append(names, name)
	}
	return names
}

func columnNames(t *testing.T, handle *sql.DB, table string) []string {
	t.Helper()
	rows, err := handle.Query(fmt.Sprintf(`PRAGMA table_info("%s")`, table))
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var names []string
	for rows.Next() {
		var cid, notnull, pk int
		var name, kind string
		var def sql.NullString
		if err := rows.Scan(&cid, &name, &kind, &notnull, &def, &pk); err != nil {
			t.Fatal(err)
		}
		names = append(names, name)
	}
	return names
}

func renderRows(t *testing.T, handle *sql.DB, table string, columns []string) []string {
	t.Helper()
	var projection []string
	for _, column := range columns {
		projection = append(projection, fmt.Sprintf(`typeof("%s")`, column), fmt.Sprintf(`"%s"`, column))
	}
	rows, err := handle.Query(fmt.Sprintf(`SELECT %s FROM "%s"`, strings.Join(projection, ", "), table))
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var rendered []string
	for rows.Next() {
		cells := make([]any, len(projection))
		pointers := make([]any, len(projection))
		for index := range cells {
			pointers[index] = &cells[index]
		}
		if err := rows.Scan(pointers...); err != nil {
			t.Fatal(err)
		}
		var parts []string
		for index := 0; index < len(cells); index += 2 {
			parts = append(parts, fmt.Sprintf("%v=%s", cells[index], renderCell(cells[index+1])))
		}
		rendered = append(rendered, strings.Join(parts, "\x1f"))
	}
	sort.Strings(rendered)
	return rendered
}

func renderCell(value any) string {
	switch typed := value.(type) {
	case nil:
		return "null"
	case float64:
		return fmt.Sprintf("%016x", math.Float64bits(typed))
	case []byte:
		return fmt.Sprintf("%x", typed)
	default:
		return fmt.Sprint(typed)
	}
}

func preservationDifferences(t *testing.T, source, current string) []string {
	t.Helper()
	before, after := openImmutable(t, source), openImmutable(t, current)
	var differences []string
	afterTables := map[string]bool{}
	for _, name := range tableNames(t, after) {
		afterTables[name] = true
	}
	for _, table := range tableNames(t, before) {
		if !afterTables[table] {
			differences = append(differences, "table-lost:"+table)
			continue
		}
		var columns []string
		for _, column := range columnNames(t, before, table) {
			if !intentionalPostUpgradeChanges[table][column] {
				columns = append(columns, column)
			}
		}
		old := renderRows(t, before, table, columns)
		now := map[string]int{}
		for _, row := range renderRows(t, after, table, columns) {
			now[row]++
		}
		for _, row := range old {
			if now[row] == 0 {
				differences = append(differences, "row-changed-or-lost:"+table)
				break
			}
			now[row]--
		}
	}
	return differences
}

func readDocument(t *testing.T, bundle, name string, target any) {
	t.Helper()
	if err := json.Unmarshal(readFile(t, filepath.Join(bundle, name)), target); err != nil {
		t.Fatal(err)
	}
}

func TestUpgradedBundlePassesEveryCheckAndRunsEveryRecordedCase(t *testing.T) {
	result := execute(t, binary, upgraded, "--legacy-sha1")
	if result.code != 0 || !result.report.Passed {
		t.Fatalf("exit %d, failed checks %v, stderr %q", result.code, result.failed(), result.stderr)
	}
	var accounts struct {
		Accounts []struct {
			Authenticate map[string]bool `json:"authenticate"`
		} `json:"accounts"`
	}
	var responses struct {
		Cases    []json.RawMessage `json:"cases"`
		Refusals []json.RawMessage `json:"refusals"`
	}
	var assets struct {
		Books []json.RawMessage `json:"books"`
	}
	readDocument(t, upgraded, "expected/accounts.json", &accounts)
	readDocument(t, upgraded, "expected/responses.json", &responses)
	readDocument(t, upgraded, "expected/library-assets.json", &assets)
	passwords := 0
	for _, account := range accounts.Accounts {
		passwords += len(account.Authenticate)
	}
	want := map[string]int{"passwords": passwords, "consumer-projection": len(responses.Cases) + len(responses.Refusals), "library-assets": len(assets.Books)}
	for name, cases := range want {
		if check, _ := result.check(name); check.Cases != cases || cases == 0 {
			t.Errorf("%s ran %d cases, the bundle records %d", name, check.Cases, cases)
		}
	}
	var names []string
	for _, check := range result.report.Checks {
		names = append(names, check.Name)
	}
	sort.Strings(names)
	if !reflect.DeepEqual(names, allChecks) {
		t.Fatalf("checks = %v", names)
	}
}

func TestEveryReleasedRowSurvivesInTheUpgradedDatabase(t *testing.T) {
	if differences := preservationDifferences(t, filepath.Join(upgraded, releasedSource), filepath.Join(upgraded, "db/primary.sqlite3")); len(differences) != 0 {
		t.Fatalf("released data changed: %v", differences)
	}
	released := openImmutable(t, filepath.Join(upgraded, releasedSource))
	for _, table := range tableNames(t, released) {
		var count int
		if err := released.QueryRow(fmt.Sprintf(`SELECT COUNT(*) FROM "%s"`, table)).Scan(&count); err != nil || count == 0 {
			t.Errorf("released table %s holds %d records (%v)", table, count, err)
		}
	}
}

func TestThePreservationComparisonCatchesLostAndChangedReleasedData(t *testing.T) {
	for name, statements := range map[string][]string{
		"changed password digest": {"UPDATE users SET password_digest = (SELECT password_digest FROM users WHERE username = 'bob') WHERE username = 'alice'"},
		"lost book":               {"DELETE FROM books WHERE id = 5"},
		"changed setting":         {"UPDATE settings SET value = 'x' WHERE key = 'prowlarr_api_key'"},
		"changed legacy token":    {"UPDATE api_tokens SET token_digest = '0' WHERE name = 'legacy-alice-search'"},
		"text became blob":        {"UPDATE users SET name = CAST(name AS BLOB) WHERE username = 'bob'"},
		"lost table":              {"DROP TABLE hardcover_connections"},
	} {
		t.Run(name, func(t *testing.T) {
			current := newVariantFrom(t, upgraded)
			current.editDatabase(statements...)
			if len(preservationDifferences(t, filepath.Join(upgraded, releasedSource), current.path("db/primary.sqlite3"))) == 0 {
				t.Fatal("the comparison accepted changed released data")
			}
		})
	}
}

func TestReleasedDataTamperedInTheUpgradedDatabaseIsRejectedByTheRightCheck(t *testing.T) {
	cases := []struct {
		name   string
		change func(*testing.T, *variant)
		want   expectation
	}{
		{"swapped released password digest", func(t *testing.T, v *variant) {
			v.editDatabase("UPDATE users SET password_digest = (SELECT password_digest FROM users WHERE username = 'bob') WHERE username = 'alice'")
		}, expectation{1, []string{"passwords"}}},
		{"tampered released one-time-password secret", func(t *testing.T, v *variant) { flipFirstPayloadByte(t, v, "users", "otp_secret", 11) }, expectation{1, []string{"encrypted-columns"}}},
		{"tampered released download client key", func(t *testing.T, v *variant) { flipFirstPayloadByte(t, v, "download_clients", "api_key", 3) }, expectation{1, []string{"encrypted-columns"}}},
		{"released book pointed at another file", func(t *testing.T, v *variant) {
			v.editDatabase("UPDATE books SET file_path = (SELECT file_path FROM books WHERE id = 6) WHERE id = 5")
		}, expectation{1, []string{"consumer-projection", "library-assets"}}},
		{"released output root removed", func(t *testing.T, v *variant) {
			v.editDatabase("UPDATE settings SET value = NULL WHERE key = 'ebook_output_path'")
		}, expectation{1, []string{"consumer-projection", "library-assets"}}},
		{"revived released deleted account", func(t *testing.T, v *variant) {
			v.editDatabase("UPDATE users SET deleted_at = NULL WHERE username = 'carol'")
		}, expectation{1, []string{"consumer-projection", "passwords"}}},
		{"released token digest changed", func(t *testing.T, v *variant) {
			v.editDatabase("UPDATE api_tokens SET token_digest = '0000000000000000000000000000000000000000000000000000000000000000' WHERE name = 'legacy-alice-search'")
		}, expectation{1, []string{"consumer-projection"}}},
		{"released token silently widened", func(t *testing.T, v *variant) {
			v.editDatabase(`UPDATE api_tokens SET scopes = '["library:read"]' WHERE name = 'legacy-alice-search'`)
		}, expectation{1, []string{"consumer-projection"}}},
		{"released token revoked", func(t *testing.T, v *variant) {
			v.editDatabase("UPDATE api_tokens SET revoked_at = '2026-01-01 00:00:00' WHERE name = 'legacy-bob-future-expiry'")
		}, expectation{1, []string{"consumer-projection"}}},
		{"migrations bypassed leaving the last version unrecorded", func(t *testing.T, v *variant) {
			v.editDatabase("DELETE FROM schema_migrations WHERE version = '20261112150000'")
		}, expectation{1, []string{"schema-revision"}}},
		{"released database presented as upgraded", func(t *testing.T, v *variant) {
			writeFile(t, v.path("db/primary.sqlite3"), readFile(t, filepath.Join(upgraded, releasedSource)), 0o640)
		}, expectation{1, []string{"consumer-projection", "schema-revision"}}},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			current := newVariantFrom(t, upgraded)
			test.change(t, current)
			current.seal()
			result := execute(t, binary, current.dir, "--legacy-sha1")
			if result.code != test.want.exit || !reflect.DeepEqual(result.failed(), test.want.failed) {
				t.Fatalf("exit %d, failed %v; want exit %d, failed %v", result.code, result.failed(), test.want.exit, test.want.failed)
			}
		})
	}
}

func TestUpgradedBundleOutputCarriesNoProvenanceOrSecrets(t *testing.T) {
	var evidence struct {
		Release map[string]any `json:"release"`
	}
	readDocument(t, upgraded, "expected/stable-upgrade.json", &evidence)
	protected := []string{upgraded, filepath.Dir(upgraded), "stable-upgrade", "released-source"}
	for _, key := range []string{"tag", "commit", "tree", "schema_blob", "migrations_tree"} {
		protected = append(protected, evidence.Release[key].(string))
	}
	protected = append(protected, stringsIn((&variant{t: t, dir: upgraded}).credentials())...)
	runs := []outcome{execute(t, binary, upgraded, "--legacy-sha1")}
	broken := newVariantFrom(t, upgraded)
	broken.editDatabase("UPDATE users SET password_digest = (SELECT password_digest FROM users WHERE username = 'bob') WHERE username = 'alice'")
	broken.seal()
	runs = append(runs, execute(t, binary, broken.dir, "--legacy-sha1"), execute(t, binary, filepath.Join(upgraded, "absent")))
	for _, result := range runs {
		combined := result.stdout + result.stderr
		for _, text := range protected {
			if len(text) >= 8 && strings.Contains(combined, text) {
				t.Fatalf("output contains protected text of length %d", len(text))
			}
		}
	}
}

func TestCheckerLeavesTheUpgradedBundleAndItsSourceSnapshotUntouched(t *testing.T) {
	var manifest map[string]any
	(&variant{t: t, dir: upgraded}).editManifest(&manifest)
	roots := []string{upgraded}
	for _, tree := range manifest["external_trees"].([]any) {
		roots = append(roots, tree.(map[string]any)["root"].(string))
	}
	before := map[string]map[string]treeState{}
	for _, root := range roots {
		before[root] = snapshotTree(t, root)
	}
	if result := execute(t, binary, upgraded, "--legacy-sha1"); result.code != 0 {
		t.Fatalf("exit %d", result.code)
	}
	for _, root := range roots {
		if !reflect.DeepEqual(before[root], snapshotTree(t, root)) {
			t.Fatalf("a tree changed while checking")
		}
	}
}

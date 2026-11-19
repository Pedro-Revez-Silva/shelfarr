//go:build e2e

package browser

import (
	"bufio"
	"encoding/json"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
)

const metadataPath = "/preview/api/v1/admin/settings/metadata"

type metadataRead struct {
	Key        string  `json:"key"`
	Value      *string `json:"value"`
	ValueType  string  `json:"value_type"`
	Rails      any     `json:"rails"`
	RailsClass string  `json:"rails_class"`
}

type metadataCapture struct {
	Definitions map[string]struct {
		Type           string `json:"type"`
		Default        any    `json:"default"`
		EnvOverridable bool   `json:"env_overridable"`
	} `json:"definitions"`
	FixtureValues map[string]any   `json:"fixture_values"`
	FixtureRows   []map[string]any `json:"fixture_rows"`
	Environment   map[string]struct {
		Variable   string `json:"variable"`
		EnvManaged bool   `json:"env_managed"`
		Value      any    `json:"value"`
	} `json:"environment_ignored"`
	Reads    []metadataRead   `json:"reads"`
	Inserted []map[string]any `json:"inserted"`
	Updated  []map[string]any `json:"updated"`
}

type openLibraryJournal struct {
	dir     string
	proxy   string
	ca      string
	journal string
	cmd     *exec.Cmd
}

var buildFake sync.Once
var fakeBinary string

func startFakeOpenLibrary(t *testing.T, response string) *openLibraryJournal {
	t.Helper()
	buildFake.Do(func() {
		fakeBinary = filepath.Join(filepath.Dir(binaryPath), "fake-openlibrary")
		build := exec.Command("go", "build", "-tags", "e2e", "-o", fakeBinary, "../fakeopenlibrary")
		build.Stderr = os.Stderr
		if err := build.Run(); err != nil {
			fakeBinary = ""
		}
	})
	if fakeBinary == "" {
		t.Fatal("cannot build the Open Library stand-in")
	}
	dir := t.TempDir()
	answer := filepath.Join(dir, "search.json")
	if err := os.WriteFile(answer, []byte(response), 0o600); err != nil {
		t.Fatal(err)
	}
	command := exec.Command(fakeBinary, "-dir", dir, "-response", answer)
	output, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		command.Process.Signal(os.Interrupt)
		command.Wait()
	})
	line, err := bufio.NewReader(output).ReadString('\n')
	if err != nil {
		t.Fatalf("the Open Library stand-in did not start: %v", err)
	}
	var ready struct{ Proxy, CA, Journal string }
	if err := json.Unmarshal([]byte(line), &ready); err != nil {
		t.Fatalf("stand-in said %q", line)
	}
	return &openLibraryJournal{dir: dir, proxy: ready.Proxy, ca: ready.CA, journal: ready.Journal, cmd: command}
}

func (j *openLibraryJournal) entries(t *testing.T) []map[string]any {
	t.Helper()
	data, err := os.ReadFile(j.journal)
	if err != nil {
		t.Fatal(err)
	}
	found := []map[string]any{}
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if line == "" {
			continue
		}
		var entry map[string]any
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Fatalf("journal line %q", line)
		}
		found = append(found, entry)
	}
	return found
}

func capturedMetadata(t *testing.T, f fixture) (metadataCapture, string) {
	t.Helper()
	var document struct {
		Metadata metadataCapture `json:"metadata_settings"`
		Discover struct {
			Query    string `json:"query"`
			Response string `json:"response"`
		} `json:"discover"`
	}
	readJSON(t, filepath.Join(f.dir, "cases.json"), &document)
	if len(document.Metadata.Reads) == 0 || len(document.Metadata.Inserted) != 2 || document.Discover.Response == "" {
		t.Fatal("the Rails capture carries no metadata settings cases")
	}
	return document.Metadata, document.Discover.Response
}

func settingsServer(t *testing.T, f fixture, copied runtimeCopy, fake *openLibraryJournal) *server {
	t.Helper()
	return startServer(t, f, copied, serverOptions{
		arguments: []string{"-open-library-search", "-login-attempts", "1000"},
		env: []string{"HTTPS_PROXY=" + fake.proxy, "SSL_CERT_FILE=" + fake.ca,
			"SHELFARR_SETTING_OPEN_LIBRARY_ENABLED=false", "SHELFARR_SETTING_OPEN_LIBRARY_SEARCH_LIMIT=3"},
	})
}

func metadataRows(t *testing.T, path string) []map[string]any {
	t.Helper()
	return rows(t, path, `SELECT key, value, value_type, category, description FROM settings WHERE key IN ('open_library_enabled', 'open_library_search_limit') ORDER BY key`)
}

func allSettings(t *testing.T, path, where string) []map[string]any {
	t.Helper()
	return rows(t, path, `SELECT key, value, value_type, category, description, CAST(created_at AS TEXT) AS created, CAST(updated_at AS TEXT) AS updated FROM settings `+where+` ORDER BY key`)
}

const unrelatedSettings = `WHERE key NOT IN ('open_library_enabled', 'open_library_search_limit')`

func settingsBody(t *testing.T, response result, status int) map[string]any {
	t.Helper()
	if response.status != status || response.headers.Get("Cache-Control") != "private, no-store" {
		t.Fatalf("settings %d %v %s", response.status, response.headers, response.body)
	}
	return response.json(t)
}

func values(body map[string]any) []any {
	saved := body["open_library"].(map[string]any)
	return []any{saved["enabled"], saved["search_limit"]}
}

func railsValue(read metadataRead) any {
	return asFloat(read.Rails)
}

func asFloat(value any) any {
	switch value := value.(type) {
	case float64:
		return value
	case json.Number:
		number, _ := value.Float64()
		return number
	}
	return value
}

func goReadsLikeRails(read metadataRead) bool {
	if read.Key == "open_library_enabled" {
		return read.RailsClass == "TrueClass" || read.RailsClass == "FalseClass"
	}
	lenient := read.Value != nil && (*read.Value == "12abc" || *read.Value == "many")
	return read.RailsClass == "Integer" && read.ValueType == "integer" && !lenient
}

func TestMetadataSettingsReadTheRowsRailsReadsAndIgnoreTheEnvironmentAsRailsDoes(t *testing.T) {
	eachFixture(t, func(t *testing.T, f fixture, copied runtimeCopy) {
		captured, response := capturedMetadata(t, f)
		for key, definition := range captured.Definitions {
			if definition.EnvOverridable || captured.Environment[key].EnvManaged || !reflect.DeepEqual(asFloat(captured.Environment[key].Value), asFloat(captured.FixtureValues[key])) {
				t.Fatalf("Rails lets the environment manage %s: %+v %+v", key, definition, captured.Environment[key])
			}
		}
		fake := startFakeOpenLibrary(t, response)
		instance := settingsServer(t, f, copied, fake)
		client := instance.browser()
		id, _ := client.signIn("browser_admin", f.personas.Passwords["browser_admin"])
		before := allSettings(t, copied.database, "")
		body := settingsBody(t, client.get(metadataPath, id), http.StatusOK)
		if got, want := values(body), []any{captured.FixtureValues["open_library_enabled"], asFloat(captured.FixtureValues["open_library_search_limit"])}; !reflect.DeepEqual(got, want) {
			t.Fatalf("Go reads %v, Rails %v", got, want)
		}
		if after := allSettings(t, copied.database, ""); !reflect.DeepEqual(before, after) {
			t.Fatal("opening the settings wrote a row")
		}
		compared, refused := 0, 0
		for _, read := range captured.Reads {
			exec1(t, copied.database, `DELETE FROM settings WHERE key = ?`, read.Key)
			exec1(t, copied.database, `INSERT INTO settings (key, value, value_type, category, created_at, updated_at) VALUES (?, ?, ?, 'open_library', '2026-11-01 00:00:00', '2026-11-01 00:00:00')`, read.Key, read.Value, read.ValueType)
			saved := settingsBody(t, client.get(metadataPath, id), http.StatusOK)["open_library"].(map[string]any)
			field := map[string]string{"open_library_enabled": "enabled", "open_library_search_limit": "search_limit"}[read.Key]
			if goReadsLikeRails(read) {
				if !reflect.DeepEqual(saved[field], railsValue(read)) {
					t.Errorf("%s %v/%s: Go %v, Rails %v", read.Key, read.Value, read.ValueType, saved[field], read.Rails)
				}
				compared++
			} else {
				if saved[field] != nil {
					t.Errorf("%s %v/%s: Go guessed %v where Rails reads %v (%s)", read.Key, read.Value, read.ValueType, saved[field], read.Rails, read.RailsClass)
				}
				refused++
			}
			exec1(t, copied.database, `DELETE FROM settings WHERE key = ?`, read.Key)
		}
		if compared != 16 || refused != 5 {
			t.Fatalf("compared %d forms, refused %d", compared, refused)
		}
		if entries := fake.entries(t); len(entries) != 0 {
			t.Fatalf("reading settings reached Open Library: %v", entries)
		}
	})
}

func TestMetadataSettingsWriteWhatRailsWritesAndDiscoverHonoursThem(t *testing.T) {
	eachFixture(t, func(t *testing.T, f fixture, copied runtimeCopy) {
		captured, response := capturedMetadata(t, f)
		fake := startFakeOpenLibrary(t, response)
		instance := settingsServer(t, f, copied, fake)
		admin := instance.browser()
		id, token := admin.signIn("browser_admin", f.personas.Passwords["browser_admin"])
		unrelated := allSettings(t, copied.database, unrelatedSettings)
		read := settingsBody(t, admin.get(metadataPath, id), http.StatusOK)

		member := instance.browser()
		memberID, memberToken := member.signIn("browser_member", f.personas.Passwords["browser_member"])
		change := `{"revision":"` + read["revision"].(string) + `","open_library":{"enabled":false,"search_limit":15}}`
		for _, refused := range []result{member.get(metadataPath, memberID), member.put(metadataPath, memberID, memberToken, change)} {
			if refused.status != http.StatusNotFound || refused.code(t) != "not_found" {
				t.Fatalf("member %d %s", refused.status, refused.body)
			}
		}
		noToken := admin.do("PUT", metadataPath, map[string]string{"X-Shelfarr-Account": id, "Origin": instance.origin}, []byte(change))
		otherOrigin := admin.do("PUT", metadataPath, map[string]string{"X-Shelfarr-Account": id, "Origin": "http://127.0.0.1:1", "X-CSRF-Token": token}, []byte(change))
		otherAccount := admin.put(metadataPath, memberID, token, change)
		if noToken.code(t) != "invalid_csrf" || otherOrigin.code(t) != "invalid_csrf" || otherAccount.code(t) != "account_changed" {
			t.Fatalf("refusals %s %s %s", noToken.body, otherOrigin.body, otherAccount.body)
		}
		if len(metadataRows(t, copied.database)) != len(captured.FixtureRows) {
			t.Fatal("a refused save wrote a row")
		}

		saved := settingsBody(t, admin.put(metadataPath, id, token, change), http.StatusOK)
		if got := values(saved); !reflect.DeepEqual(got, []any{false, 15.0}) || saved["discover"].(map[string]any)["search"] != "provider_disabled" {
			t.Fatalf("saved %v", saved)
		}
		want := captured.Inserted
		if len(captured.FixtureRows) > 0 {
			want = captured.Updated
		}
		if got := metadataRows(t, copied.database); !reflect.DeepEqual(got, want) {
			t.Fatalf("Go wrote %v, Rails writes %v", got, want)
		}
		if after := allSettings(t, copied.database, unrelatedSettings); !reflect.DeepEqual(unrelated, after) {
			t.Fatal("saving changed another setting")
		}
		reloaded := settingsBody(t, admin.get(metadataPath, id), http.StatusOK)
		if !reflect.DeepEqual(values(reloaded), values(saved)) || reloaded["revision"] != saved["revision"] {
			t.Fatalf("reload %v", reloaded)
		}
		stale := admin.put(metadataPath, id, token, change)
		if stale.status != http.StatusConflict || stale.code(t) != "settings_conflict" {
			t.Fatalf("stale %d %s", stale.status, stale.body)
		}
		query := "/preview/api/v1/discover?q=" + url.QueryEscape("reader sampler")
		off := admin.get(query, id)
		if off.status != http.StatusOK || off.json(t)["search"] != "provider_disabled" {
			t.Fatalf("discover off %d %s", off.status, off.body)
		}
		if entries := fake.entries(t); len(entries) != 0 {
			t.Fatalf("Discover reached Open Library while it was off: %v", entries)
		}

		exec1(t, copied.database, `UPDATE settings SET value = '50' WHERE key = 'open_library_search_limit'`)
		larger := settingsBody(t, admin.get(metadataPath, id), http.StatusOK)
		if values(larger)[1] != 50.0 || larger["discover"].(map[string]any)["result_limit"] != nil {
			t.Fatalf("larger %v", larger)
		}
		limitRow := allSettings(t, copied.database, `WHERE key = 'open_library_search_limit'`)
		turnedOn := settingsBody(t, admin.put(metadataPath, id, token, `{"revision":"`+larger["revision"].(string)+`","open_library":{"enabled":true}}`), http.StatusOK)
		if turnedOn["discover"].(map[string]any)["result_limit"] != 20.0 || values(turnedOn)[1] != 50.0 {
			t.Fatalf("turned on %v", turnedOn)
		}
		if after := allSettings(t, copied.database, `WHERE key = 'open_library_search_limit'`); !reflect.DeepEqual(limitRow, after) {
			t.Fatalf("an unrelated save rewrote the larger limit %v -> %v", limitRow, after)
		}
		seven := settingsBody(t, admin.put(metadataPath, id, token, `{"revision":"`+turnedOn["revision"].(string)+`","open_library":{"search_limit":7}}`), http.StatusOK)
		if seven["discover"].(map[string]any)["result_limit"] != 7.0 {
			t.Fatalf("seven %v", seven)
		}
		searched := admin.get(query, id)
		if searched.status != http.StatusOK || searched.json(t)["search"] != "available" {
			t.Fatalf("discover on %d %s", searched.status, searched.body)
		}
		requests := []map[string]any{}
		for _, entry := range fake.entries(t) {
			if entry["kind"] == "request" {
				requests = append(requests, entry)
			}
		}
		if len(requests) != 1 || !reflect.DeepEqual(requests[0]["query"].(map[string]any)["limit"], []any{"7"}) {
			t.Fatalf("Open Library saw %v", requests)
		}
		final := settingsBody(t, admin.put(metadataPath, id, token, `{"revision":"`+seven["revision"].(string)+`","open_library":{"enabled":false}}`), http.StatusOK)
		if !reflect.DeepEqual(values(final), []any{false, 7.0}) {
			t.Fatalf("final %v", final)
		}
		keepForRails(t, f, copied)
	})
}

func keepForRails(t *testing.T, f fixture, copied runtimeCopy) {
	t.Helper()
	target := os.Getenv("SHELFARR_BROWSER_GO_DIR")
	if target == "" {
		return
	}
	database := openDatabase(t, copied.database)
	if _, err := database.Exec(`PRAGMA wal_checkpoint(TRUNCATE)`); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(copied.database)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(target, "metadata-"+f.name+".sqlite3"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	state, _ := json.Marshal(map[string]any{"open_library_enabled": false, "open_library_search_limit": 7, "unrelated": allSettings(t, copied.database, unrelatedSettings)})
	if err := os.WriteFile(filepath.Join(target, "metadata-"+f.name+".json"), state, 0o600); err != nil {
		t.Fatal(err)
	}
}

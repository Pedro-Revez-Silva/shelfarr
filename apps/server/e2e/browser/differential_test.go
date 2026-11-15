//go:build e2e

package browser

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func normaliseJSON(value any) any {
	switch typed := value.(type) {
	case map[string]any:
		result := map[string]any{}
		for key, item := range typed {
			result[key] = normaliseJSON(item)
		}
		return result
	case []any:
		result := make([]any, len(typed))
		for index, item := range typed {
			result[index] = normaliseJSON(item)
		}
		return result
	case json.Number:
		rational, ok := new(big.Rat).SetString(typed.String())
		if !ok {
			return typed.String()
		}
		return rational.RatString()
	}
	return value
}

func decodeJSON(data []byte) (any, error) {
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, err
	}
	return normaliseJSON(value), nil
}

func firstDifference(path string, got, want any) string {
	switch expected := want.(type) {
	case map[string]any:
		actual, ok := got.(map[string]any)
		if !ok {
			return path + " (type)"
		}
		for key, value := range expected {
			if difference := firstDifference(path+"."+key, actual[key], value); difference != "" {
				return difference
			}
		}
		for key := range actual {
			if _, present := expected[key]; !present {
				return path + "." + key + " (unexpected)"
			}
		}
		return ""
	case []any:
		actual, ok := got.([]any)
		if !ok || len(actual) != len(expected) {
			return fmt.Sprintf("%s (length %d want %d)", path, len(actual), len(expected))
		}
		for index, value := range expected {
			if difference := firstDifference(fmt.Sprintf("%s[%d]", path, index), actual[index], value); difference != "" {
				return difference
			}
		}
		return ""
	}
	if !reflect.DeepEqual(got, want) {
		return path
	}
	return ""
}

var tolerated = map[string]bool{"date": true, "content-length": true, "content-type": true, "set-cookie": true}

func expectedBody(s step) any {
	encoded, _ := json.Marshal(s.JSON)
	value, _ := decodeJSON(encoded)
	if document, ok := value.(map[string]any); ok {
		if server, ok := document["server"].(map[string]any); ok {
			server["name"] = "127.0.0.1"
		}
	}
	return value
}

func compareStep(f fixture, s step, got result) []string {
	if s.Go != nil {
		var problems []string
		if got.status != s.Go.Status {
			problems = append(problems, fmt.Sprintf("status %d want %d", got.status, s.Go.Status))
		}
		var body struct {
			Error string `json:"error"`
		}
		json.Unmarshal(got.body, &body)
		if body.Error != s.Go.Code {
			problems = append(problems, fmt.Sprintf("error code %q want %q", body.Error, s.Go.Code))
		}
		return problems
	}
	if got.status != s.Status {
		return []string{fmt.Sprintf("status %d want %d (%s)", got.status, s.Status, got.body)}
	}
	var problems []string
	jsonBody := strings.HasPrefix(s.ResponseHeaders["content-type"], "application/json")
	for name, expected := range s.ResponseHeaders {
		switch {
		case name == "etag" && jsonBody, name == "content-length", name == "content-type" && s.JSON == nil:
			continue
		case name == "cache-control" && (s.Status == http.StatusUnauthorized || s.Status == http.StatusNotFound):
			if got.headers.Get(name) != "private, no-store" {
				problems = append(problems, fmt.Sprintf("guard error cache-control %q", got.headers.Get(name)))
			}
			continue
		}
		if value := got.headers.Get(name); value != expected {
			problems = append(problems, fmt.Sprintf("header %s: got %q want %q", name, value, expected))
		}
	}
	for name := range got.headers {
		lower := strings.ToLower(name)
		if _, expected := s.ResponseHeaders[lower]; !expected && !tolerated[lower] {
			problems = append(problems, "unexpected header "+lower)
		}
	}
	cleared := false
	for _, line := range got.headers.Values("Set-Cookie") {
		cleared = cleared || strings.HasPrefix(line, "session_id=;")
	}
	if cleared != s.ClearsSessionCookie {
		problems = append(problems, fmt.Sprintf("session cookie cleared=%t want %t", cleared, s.ClearsSessionCookie))
	}
	if s.JSON != nil {
		actual, err := decodeJSON(got.body)
		if err != nil {
			return append(problems, "body is not JSON")
		}
		if difference := firstDifference("$", actual, expectedBody(s)); difference != "" {
			problems = append(problems, "json body differs at "+difference)
		}
	} else if len(got.body) != 0 {
		problems = append(problems, "body present")
	}
	return problems
}

type replay struct {
	t        *testing.T
	f        fixture
	instance *server
	copied   runtimeCopy
	clock    string
	issued   map[string]string
}

func (r *replay) cookieHeader(name *string) string {
	if name == nil {
		return ""
	}
	return "session_id=" + r.f.personas.Personas[*name].Cookie
}

func (r *replay) request(s step) []string {
	setClock(r.t, r.clock, s.At)
	client := r.instance.bare()
	headers := map[string]string{"Accept": "application/json", "Cookie": r.cookieHeader(s.Persona)}
	for name, value := range s.Headers {
		headers[name] = value
	}
	var body []byte
	if s.Body != nil {
		body, _ = json.Marshal(s.Body)
	}
	if s.Method == "PUT" && s.Persona != nil {
		boot := client.do("GET", "/preview/api/v1/auth/bootstrap", map[string]string{"Cookie": headers["Cookie"]}, nil)
		var document struct {
			Token string `json:"csrf_token"`
			Auth  bool   `json:"authenticated"`
		}
		json.Unmarshal(boot.body, &document)
		if document.Auth {
			headers["X-CSRF-Token"] = document.Token
		}
		headers["Origin"] = r.instance.origin
	}
	got := client.do(s.Method, s.Path, headers, body)
	var problems []string
	for _, problem := range compareStep(r.f, s, got) {
		problems = append(problems, s.Name+": "+problem)
	}
	return problems
}

func (r *replay) setting(s step) {
	exec1(r.t, r.copied.database, `INSERT INTO settings (key, value, value_type, category, created_at, updated_at) VALUES (?, ?, ?, 'security', '2026-11-15 12:00:00', '2026-11-15 12:00:00') ON CONFLICT(key) DO UPDATE SET value = excluded.value, value_type = excluded.value_type`, s.Key, s.Value, s.ValueType)
}

func (r *replay) sessionRows() []map[string]any {
	return rows(r.t, r.copied.database, `SELECT CAST(id AS INTEGER) AS id, user_id, user_agent, ip_address, CAST(created_at AS TEXT) AS created_at, CAST(updated_at AS TEXT) AS updated_at FROM sessions WHERE user_id != ? ORDER BY id`, r.f.doc.Users["browser_oidc"])
}

func railsRows(s []map[string]any, oidc int64) []map[string]any {
	var kept []map[string]any
	for _, row := range s {
		if fmt.Sprint(row["user_id"]) != fmt.Sprint(oidc) {
			kept = append(kept, row)
		}
	}
	return kept
}

func sameRows(got, want []map[string]any) string {
	if len(got) != len(want) {
		return fmt.Sprintf("%d rows want %d", len(got), len(want))
	}
	for index := range want {
		for column, expected := range want[index] {
			if fmt.Sprint(got[index][column]) != fmt.Sprint(expected) && !(got[index][column] == nil && expected == nil) {
				return fmt.Sprintf("row %d column %s: got %v want %v", index, column, got[index][column], expected)
			}
		}
	}
	return ""
}

func (r *replay) login(s step) []string {
	setClock(r.t, r.clock, s.At)
	client := r.instance.browser()
	token, _ := client.bootstrap()
	password := r.f.personas.Passwords[s.PasswordOf]
	if s.WrongPassword {
		password = "Wrong-Replay-Pass9"
	}
	got := client.login(s.Username, password, token, nil)
	var problems []string
	switch {
	case s.Go != nil:
		if got.status != s.Go.Status || got.code(r.t) != s.Go.Code {
			problems = append(problems, fmt.Sprintf("answered %d %s want %d %s", got.status, got.body, s.Go.Status, s.Go.Code))
		}
	case s.SessionCreated && got.status != http.StatusOK, !s.SessionCreated && got.status != http.StatusUnauthorized:
		problems = append(problems, fmt.Sprintf("answered %d %s, Rails created a session: %t", got.status, got.body, s.SessionCreated))
	}
	if got.status == http.StatusOK {
		r.issued[s.Name] = client.cookie("session_id")
	}
	userID := r.f.doc.Users[s.PasswordOf]
	if difference := sameRows(rows(r.t, r.copied.database, `SELECT id, failed_login_count, CAST(last_failed_login_at AS TEXT) AS last_failed_login_at, last_failed_login_ip, CAST(locked_until AS TEXT) AS locked_until, CAST(updated_at AS TEXT) AS updated_at FROM users WHERE id = ?`, userID), s.UsersAfter); difference != "" {
		problems = append(problems, "users row differs: "+difference)
	}
	if difference := sameRows(r.sessionRows(), railsRows(s.SessionsAfter, r.f.doc.Users["browser_oidc"])); difference != "" {
		problems = append(problems, "sessions differ: "+difference)
	}
	var out []string
	for _, problem := range problems {
		out = append(out, s.Name+": "+problem)
	}
	return out
}

func (r *replay) logout(s step) []string {
	setClock(r.t, r.clock, time.Date(2026, 11, 15, 12, 30, 0, 0, time.UTC).Format(time.RFC3339Nano))
	client := r.instance.bare()
	cookie := map[string]string{"Cookie": r.cookieHeader(s.Persona)}
	boot := client.do("GET", "/preview/api/v1/auth/bootstrap", cookie, nil)
	document := boot.json(r.t)
	headers := map[string]string{"Cookie": cookie["Cookie"], "X-Shelfarr-Account": fmt.Sprint(document["account"]), "Origin": r.instance.origin, "X-CSRF-Token": fmt.Sprint(document["csrf_token"])}
	got := client.do("POST", "/preview/api/v1/auth/logout", headers, nil)
	var problems []string
	if got.status != http.StatusOK {
		problems = append(problems, fmt.Sprintf("logout answered %d %s", got.status, got.body))
	}
	if difference := sameRows(r.sessionRows(), railsRows(s.SessionsAfter, r.f.doc.Users["browser_oidc"])); difference != "" {
		problems = append(problems, "sessions differ: "+difference)
	}
	var out []string
	for _, problem := range problems {
		out = append(out, s.Name+": "+problem)
	}
	return out
}

func TestBrowserDifferentialAgainstRails(t *testing.T) {
	for _, f := range fixtures(t) {
		t.Run(f.name, func(t *testing.T) {
			copied := newRuntimeCopy(t, f)
			clock := filepath.Join(copied.dir, "clock")
			setClock(t, clock, f.doc.Steps[0].At)
			instance := startServer(t, f, copied, serverOptions{seam: true, clockFile: clock})
			run := &replay{t: t, f: f, instance: instance, copied: copied, clock: clock, issued: map[string]string{}}
			var failures []string
			for _, s := range f.doc.Steps {
				switch s.Kind {
				case "request":
					failures = append(failures, run.request(s)...)
				case "setting":
					run.setting(s)
				case "login":
					failures = append(failures, run.login(s)...)
				case "logout":
					failures = append(failures, run.logout(s)...)
				}
			}
			if len(failures) > 0 {
				shown := failures
				if len(shown) > 60 {
					shown = shown[:60]
				}
				t.Errorf("%d problems against Rails:\n%s", len(failures), strings.Join(shown, "\n"))
			}
			if difference := sameRows(run.sessionRows(), railsRows(f.doc.RailsFinal.Sessions, f.doc.Users["browser_oidc"])); difference != "" {
				t.Errorf("final sessions differ from Rails: %s", difference)
			}
			if difference := sameRows(rows(t, copied.database, `SELECT id, failed_login_count, CAST(last_failed_login_at AS TEXT) AS last_failed_login_at, last_failed_login_ip, CAST(locked_until AS TEXT) AS locked_until, CAST(updated_at AS TEXT) AS updated_at FROM users ORDER BY id`), f.doc.RailsFinal.Users); difference != "" {
				t.Errorf("final user lock state differs from Rails: %s", difference)
			}
			if difference := sameRows(rows(t, copied.database, `SELECT user_id, book_id, status, CAST(created_at AS TEXT) AS created_at, CAST(updated_at AS TEXT) AS updated_at FROM consumer_reading_states ORDER BY user_id, book_id`), f.doc.ReadingRows); difference != "" {
				t.Errorf("final reading states differ from Rails: %s", difference)
			}
			if code := instance.stop(); code != 0 {
				t.Errorf("server exit code %d", code)
			}
			exportForRails(t, f, copied, run.issued)
		})
	}
}

func exportForRails(t *testing.T, f fixture, copied runtimeCopy, issued map[string]string) {
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
	if err := os.WriteFile(filepath.Join(target, f.name+".sqlite3"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	encoded, _ := json.Marshal(issued)
	if err := os.WriteFile(filepath.Join(target, f.name+".cookies.json"), encoded, 0o600); err != nil {
		t.Fatal(err)
	}
}

var _ = sql.ErrNoRows

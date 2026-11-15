//go:build e2e

package httpruntime

import (
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

type mirror struct {
	database *sql.DB
}

func openMirror(t *testing.T, path string) mirror {
	t.Helper()
	database, err := sql.Open("sqlite", "file:"+path+"?mode=ro&_pragma=busy_timeout(5000)")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { database.Close() })
	return mirror{database: database}
}

func (m mirror) rows(t *testing.T, query string, arguments ...any) []map[string]any {
	t.Helper()
	rows, err := m.database.Query(query, arguments...)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	columns, _ := rows.Columns()
	result := []map[string]any{}
	for rows.Next() {
		values := make([]any, len(columns))
		pointers := make([]any, len(columns))
		for index := range values {
			pointers[index] = &values[index]
		}
		if err := rows.Scan(pointers...); err != nil {
			t.Fatal(err)
		}
		row := map[string]any{}
		for index, column := range columns {
			if raw, ok := values[index].([]byte); ok {
				values[index] = string(raw)
			}
			row[column] = values[index]
		}
		result = append(result, row)
	}
	return result
}

const progressColumns = `user_id, book_id, asset_id, CAST(locator AS TEXT) AS locator, position_seconds, version, client_mutation_id, CAST(created_at AS TEXT) AS created_at, CAST(updated_at AS TEXT) AS updated_at, CAST(observed_at AS TEXT) AS observed_at`
const readingColumns = `user_id, book_id, status, CAST(created_at AS TEXT) AS created_at, CAST(updated_at AS TEXT) AS updated_at`

func (m mirror) state(t *testing.T, book int64) caseState {
	return caseState{
		Progress: m.rows(t, `SELECT `+progressColumns+` FROM consumer_progresses WHERE book_id = ? ORDER BY user_id, id`, book),
		Reading:  m.rows(t, `SELECT `+readingColumns+` FROM consumer_reading_states WHERE book_id = ? ORDER BY user_id, id`, book),
	}
}

func (m mirror) tokenMarks(t *testing.T) map[string]map[string]any {
	marks := map[string]map[string]any{}
	for _, row := range m.rows(t, `SELECT id, CAST(last_used_at AS TEXT) AS last_used_at, CAST(updated_at AS TEXT) AS updated_at, CAST(revoked_at AS TEXT) AS revoked_at, replaces_api_token_id FROM api_tokens ORDER BY id`) {
		marks[fmt.Sprint(row["id"])] = row
	}
	return marks
}

func changedTokens(before, after map[string]map[string]any) map[string]map[string]any {
	changed := map[string]map[string]any{}
	for id, row := range after {
		if !reflect.DeepEqual(canonical(before[id]), canonical(row)) {
			changed[id] = row
		}
	}
	return changed
}

func canonical(value any) any {
	encoded, _ := json.Marshal(value)
	decoded, _ := decodeJSON(encoded)
	if document, ok := decoded.(map[string]any); ok {
		if text, ok := document["locator"].(string); ok {
			if parsed, err := decodeJSON([]byte(text)); err == nil {
				document["locator"] = parsed
			}
		}
	}
	return decoded
}

func canonicalRows(rows []map[string]any) []any {
	result := make([]any, len(rows))
	for index, row := range rows {
		result[index] = canonical(row)
	}
	return result
}

func requestBody(entry caseEntry) []byte {
	switch {
	case entry.BodyBase64 != nil:
		decoded, _ := base64.StdEncoding.DecodeString(*entry.BodyBase64)
		return decoded
	case entry.Body != nil:
		return []byte(*entry.Body)
	}
	return nil
}

func setClock(t *testing.T, path string, entry caseEntry) {
	t.Helper()
	text := ""
	if entry.At != nil {
		text = *entry.At
	}
	if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
}

func compareEffects(t *testing.T, m mirror, entry caseEntry, before map[string]map[string]any) []string {
	t.Helper()
	var problems []string
	if entry.TrackedBook != nil {
		want := entry.State
		if entry.Go != nil {
			want = entry.StateBefore
		}
		got := m.state(t, *entry.TrackedBook)
		if !reflect.DeepEqual(canonicalRows(got.Progress), canonicalRows(want.Progress)) {
			problems = append(problems, fmt.Sprintf("progress rows differ\n got %v\nwant %v", got.Progress, want.Progress))
		}
		if !reflect.DeepEqual(canonicalRows(got.Reading), canonicalRows(want.Reading)) {
			problems = append(problems, fmt.Sprintf("reading rows differ\n got %v\nwant %v", got.Reading, want.Reading))
		}
		changed := changedTokens(before, m.tokenMarks(t))
		wantChanged := entry.TokensChanged
		if wantChanged == nil {
			wantChanged = map[string]map[string]any{}
		}
		if !reflect.DeepEqual(canonical(changed), canonical(wantChanged)) {
			problems = append(problems, fmt.Sprintf("token side effects differ\n got %v\nwant %v", changed, wantChanged))
		}
	}
	return problems
}

func compareFinalRows(t *testing.T, f fixture, m mirror) {
	t.Helper()
	progress := m.rows(t, `SELECT `+progressColumns+` FROM consumer_progresses ORDER BY user_id, book_id`)
	if !reflect.DeepEqual(canonicalRows(progress), canonicalRows(f.doc.ProgressRows)) {
		t.Errorf("final consumer_progresses differ from Rails\n got %v\nwant %v", progress, f.doc.ProgressRows)
	}
	reading := m.rows(t, `SELECT `+readingColumns+` FROM consumer_reading_states ORDER BY user_id, book_id`)
	if !reflect.DeepEqual(canonicalRows(reading), canonicalRows(f.doc.ReadingRows)) {
		t.Errorf("final consumer_reading_states differ from Rails\n got %v\nwant %v", reading, f.doc.ReadingRows)
	}
}

func exportGoWrittenDatabase(t *testing.T, f fixture, copied runtimeCopy) {
	t.Helper()
	directory := os.Getenv("SHELFARR_HTTP_GO_ROWS_DIR")
	if directory == "" {
		return
	}
	database, err := sql.Open("sqlite", "file:"+copied.database)
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	if _, err := database.Exec(`PRAGMA wal_checkpoint(TRUNCATE)`); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(copied.database)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, f.name+".sqlite3"), data, 0o600); err != nil {
		t.Fatal(err)
	}
}

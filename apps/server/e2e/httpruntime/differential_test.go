//go:build e2e

package httpruntime

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

var goServerOverrides = map[string]any{
	"consumer_features":            []any{},
	"reader_features":              []any{},
	"read_along_manifest_versions": []any{},
}

var tolerantExtraHeaders = map[string]bool{"date": true, "content-length": true, "content-type": true}

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

func expectedJSON(entry caseEntry, serverVersion string) any {
	encoded, _ := json.Marshal(entry.JSON)
	value, _ := decodeJSON(encoded)
	if !strings.HasPrefix(entry.Name, "server-") {
		return value
	}
	document, ok := value.(map[string]any)
	if !ok {
		return value
	}
	for key, replacement := range goServerOverrides {
		document[key] = replacement
	}
	document["server_version"] = serverVersion
	return document
}

func requestHeaders(f fixture, entry caseEntry) map[string]string {
	headers := map[string]string{}
	for name, value := range entry.Headers {
		headers[name] = value
	}
	if entry.Authorization != nil {
		headers["Authorization"] = *entry.Authorization
	}
	if entry.Bearer != nil {
		headers["Authorization"] = "Bearer " + f.token[*entry.Bearer]
	}
	return headers
}

func compareHeaders(entry caseEntry, actual http.Header) []string {
	var problems []string
	jsonBody := strings.HasPrefix(entry.ResponseHeaders["content-type"], "application/json")
	emptyBody := entry.BodyBytes == 0 && entry.Status != http.StatusRequestedRangeNotSatisfiable
	for name, expected := range entry.ResponseHeaders {
		switch {
		case name == "etag" && jsonBody, name == "content-length" && jsonBody, name == "content-type" && emptyBody, name == "content-length" && entry.Method == "HEAD" && jsonBody:
			continue
		case name == "content-type" && entry.Status == http.StatusNotModified:
			continue
		}
		if got := actual.Get(name); got != expected {
			problems = append(problems, fmt.Sprintf("header %s: got %q want %q", name, got, expected))
		}
	}
	for name := range actual {
		lower := strings.ToLower(name)
		if _, expected := entry.ResponseHeaders[lower]; !expected && !tolerantExtraHeaders[lower] {
			problems = append(problems, "unexpected header "+lower)
		}
	}
	return problems
}

func compareEntry(f fixture, entry caseEntry, got result) []string {
	if entry.Go != nil {
		var problems []string
		if got.status != entry.Go.Status {
			problems = append(problems, fmt.Sprintf("status %d want %d", got.status, entry.Go.Status))
		}
		var body struct {
			Error string `json:"error"`
		}
		json.Unmarshal(got.body, &body)
		if entry.Method != "HEAD" && body.Error != entry.Go.Code {
			problems = append(problems, fmt.Sprintf("error code %q want %q", body.Error, entry.Go.Code))
		}
		return problems
	}
	var problems []string
	if got.status != entry.Status {
		return []string{fmt.Sprintf("status %d want %d", got.status, entry.Status)}
	}
	if strings.HasPrefix(entry.ResponseHeaders["content-type"], "text/html") && entry.BodyBytes > 0 {
		return nil
	}
	problems = append(problems, compareHeaders(entry, got.headers)...)
	if entry.JSON != nil {
		actual, err := decodeJSON(got.body)
		if err != nil {
			return append(problems, "body is not JSON")
		}
		if difference := firstDifference("$", actual, expectedJSON(entry, f.doc.ServerVersion)); difference != "" {
			problems = append(problems, "json body differs at "+difference)
		}
		return problems
	}
	if entry.Method == "HEAD" || entry.Status == http.StatusNotModified {
		if len(got.body) != 0 {
			problems = append(problems, "body present")
		}
		return problems
	}
	sum := sha256.Sum256(got.body)
	if len(got.body) != entry.BodyBytes || hex.EncodeToString(sum[:]) != entry.BodySHA256 {
		problems = append(problems, fmt.Sprintf("body bytes differ (%d want %d)", len(got.body), entry.BodyBytes))
	}
	return problems
}

func TestDifferentialAgainstRails(t *testing.T) {
	for _, f := range fixtures(t) {
		t.Run(f.name, func(t *testing.T) {
			copied := newRuntimeCopy(t, f)
			clock := filepath.Join(copied.dir, "clock")
			instance := startServer(t, f, copied, serverOptions{seam: true, clockFile: clock})
			observed := openMirror(t, copied.database)
			var failures []string
			var minted []mintedGrant
			for _, entry := range f.doc.Cases {
				if entry.SQL != "" {
					execSQL(t, copied.database, entry.SQL)
					continue
				}
				setClock(t, clock, entry)
				before := observed.tokenMarks(t)
				got := instance.doBody(context.Background(), entry.Method, entry.Path, requestHeaders(f, entry), requestBody(entry))
				if entry.Grant != nil && got.status == http.StatusCreated {
					var problems []string
					url := grantURL(got)
					got, problems = redactMintedGrant(t, f, entry, got)
					for _, problem := range problems {
						failures = append(failures, entry.Name+": "+problem)
					}
					if len(problems) == 0 {
						minted = append(minted, mintedGrant{Name: entry.Name, Label: *entry.Bearer, URL: url, Book: *entry.TrackedBook, At: *entry.At, Plaintext: entry.Grant.Plaintext})
					}
				}
				for _, problem := range compareEntry(f, entry, got) {
					failures = append(failures, entry.Name+": "+problem)
				}
				for _, problem := range compareEffects(t, observed, entry, before) {
					failures = append(failures, entry.Name+": "+problem)
				}
			}
			if len(failures) > 0 {
				shown := failures
				if len(shown) > 60 {
					shown = shown[:60]
				}
				t.Errorf("%d of %d cases differ from Rails:\n%s", len(failures), len(f.doc.Cases), strings.Join(shown, "\n"))
			}
			if code := instance.stop(); code != 0 {
				t.Errorf("server exit code %d", code)
			}
			compareTokenState(t, f, copied)
			compareFinalRows(t, f, observed)
			exportGoWrittenDatabase(t, f, copied)
			exportMintedGrants(t, f, minted)
		})
	}
}

func tokenState(t *testing.T, path string) []tokenRow {
	t.Helper()
	database, err := sql.Open("sqlite", "file:"+path+"?mode=ro")
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	rows, err := database.Query(`SELECT id, user_id, scopes, expires_at, replaces_api_token_id, connection_key, revoked_at IS NOT NULL, last_used_at IS NOT NULL, updated_at FROM api_tokens ORDER BY id`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var states []tokenRow
	for rows.Next() {
		var row tokenRow
		var user, replaces sql.NullInt64
		var expires, key sql.NullString
		if err := rows.Scan(&row.ID, &user, &row.Scopes, &expires, &replaces, &key, &row.Revoked, &row.Used, &row.UpdatedAt); err != nil {
			t.Fatal(err)
		}
		if user.Valid {
			row.UserID = &user.Int64
		}
		if replaces.Valid {
			row.Replaces = &replaces.Int64
		}
		if expires.Valid {
			row.ExpiresAt = &expires.String
		}
		if key.Valid {
			row.Key = &key.String
		}
		states = append(states, row)
	}
	return states
}

func shape(rows, before []tokenRow) []string {
	earlier := map[int64]string{}
	for _, row := range before {
		earlier[row.ID] = row.UpdatedAt
	}
	var lines []string
	for _, row := range rows {
		lines = append(lines, fmt.Sprintf("%d user=%v scopes=%s expires=%v replaces=%v key=%v revoked=%d used=%d touched=%t", row.ID, deref(row.UserID), row.Scopes, derefText(row.ExpiresAt), deref(row.Replaces), derefText(row.Key), row.Revoked, row.Used, earlier[row.ID] != row.UpdatedAt))
	}
	return lines
}

func deref(value *int64) any {
	if value == nil {
		return nil
	}
	return *value
}

func derefText(value *string) any {
	if value == nil {
		return nil
	}
	return *value
}

func compareTokenState(t *testing.T, f fixture, copied runtimeCopy) {
	t.Helper()
	want := shape(f.doc.After, f.doc.Before)
	got := shape(tokenState(t, copied.database), f.doc.Before)
	if !reflect.DeepEqual(want, got) {
		t.Errorf("token side effects differ from Rails\nwant:\n%s\ngot:\n%s", strings.Join(want, "\n"), strings.Join(got, "\n"))
	}
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

package livetest

import (
	"database/sql"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

const schema = `
CREATE TABLE schema_migrations (version varchar NOT NULL PRIMARY KEY);
CREATE TABLE settings (id integer PRIMARY KEY, key varchar NOT NULL, value text, value_type varchar NOT NULL DEFAULT 'string');
CREATE TABLE users (id integer PRIMARY KEY AUTOINCREMENT, username varchar NOT NULL, name varchar NOT NULL DEFAULT '', role integer NOT NULL DEFAULT 0, deleted_at datetime, password_digest varchar NOT NULL DEFAULT '', failed_login_count integer NOT NULL DEFAULT 0, last_failed_login_at datetime, last_failed_login_ip varchar, locked_until datetime, otp_required boolean NOT NULL DEFAULT 0, otp_secret varchar, oidc_provider varchar, oidc_uid varchar, backup_codes text, created_at datetime NOT NULL DEFAULT '2026-01-01 00:00:00', updated_at datetime NOT NULL DEFAULT '2026-01-01 00:00:00');
CREATE TABLE sessions (id integer PRIMARY KEY AUTOINCREMENT NOT NULL, created_at datetime NOT NULL, ip_address varchar, updated_at datetime NOT NULL, user_agent varchar, user_id integer NOT NULL);
CREATE TABLE hardcover_connections (id integer PRIMARY KEY, user_id integer NOT NULL, status varchar NOT NULL DEFAULT 'active');
CREATE TABLE api_tokens (id integer PRIMARY KEY, user_id integer, name varchar NOT NULL DEFAULT 'token', scopes text NOT NULL DEFAULT '[]', token_digest varchar NOT NULL, token_prefix varchar NOT NULL DEFAULT 'shf_',
  revoked_at datetime, expires_at datetime, last_used_at datetime, created_at datetime NOT NULL DEFAULT '2026-01-01 00:00:00', updated_at datetime NOT NULL DEFAULT '2026-01-01 00:00:00', replaces_api_token_id integer, connection_key varchar, issued_via varchar);
CREATE UNIQUE INDEX index_api_tokens_on_token_digest ON api_tokens (token_digest);
CREATE TABLE consumer_device_grants (id integer PRIMARY KEY AUTOINCREMENT NOT NULL, user_id integer, client_name varchar NOT NULL, device_code_digest varchar NOT NULL, user_code_digest varchar NOT NULL, expires_at datetime NOT NULL, approved_at datetime, denied_at datetime, consumed_at datetime, last_polled_at datetime, poll_interval integer NOT NULL DEFAULT 5, created_at datetime NOT NULL, updated_at datetime NOT NULL, scopes text, replaces_api_token_id integer);
CREATE UNIQUE INDEX index_consumer_device_grants_on_device_code_digest ON consumer_device_grants (device_code_digest);
CREATE UNIQUE INDEX index_consumer_device_grants_on_user_code_digest ON consumer_device_grants (user_code_digest);
CREATE TABLE books (id integer PRIMARY KEY, title varchar NOT NULL, author varchar, description text, cover_url varchar, file_path varchar, book_type integer NOT NULL DEFAULT 0, content_kind integer NOT NULL DEFAULT 0, open_library_work_id varchar);
CREATE TABLE metadata_provider_statuses (id integer PRIMARY KEY, provider varchar NOT NULL, status varchar NOT NULL DEFAULT 'unknown', rate_limited_until datetime, failure_count integer NOT NULL DEFAULT 0, created_at datetime NOT NULL DEFAULT '2026-01-01 00:00:00', updated_at datetime NOT NULL DEFAULT '2026-01-01 00:00:00');
CREATE TABLE consumer_progresses (id integer PRIMARY KEY, user_id integer NOT NULL, book_id integer NOT NULL, asset_id varchar NOT NULL, locator json, position_seconds float, version integer NOT NULL DEFAULT 1, client_mutation_id varchar NOT NULL, created_at datetime NOT NULL DEFAULT '2026-01-01 00:00:00', updated_at datetime NOT NULL, observed_at datetime);
CREATE TABLE consumer_reading_states (id integer PRIMARY KEY, user_id integer NOT NULL, book_id integer NOT NULL, status integer NOT NULL DEFAULT 0, created_at datetime NOT NULL DEFAULT '2026-01-01 00:00:00', updated_at datetime NOT NULL);
INSERT INTO schema_migrations (version) VALUES ('20261112150000');
`

func Create(t testing.TB) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "primary.sqlite3")
	database := open(t, path)
	defer database.Close()
	if _, err := database.Exec(schema); err != nil {
		t.Fatalf("schema: %v", err)
	}
	return path
}

func open(t testing.TB, path string) *sql.DB {
	t.Helper()
	database, err := sql.Open("sqlite", "file:"+path)
	if err != nil {
		t.Fatal(err)
	}
	database.SetMaxOpenConns(1)
	return database
}

func Exec(t testing.TB, path, statement string, arguments ...any) {
	t.Helper()
	database := open(t, path)
	defer database.Close()
	if _, err := database.Exec(statement, arguments...); err != nil {
		t.Fatalf("exec: %v", err)
	}
}

func Query(t testing.TB, path, statement string, arguments ...any) [][]any {
	t.Helper()
	database := open(t, path)
	defer database.Close()
	rows, err := database.Query(statement, arguments...)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	defer rows.Close()
	columns, _ := rows.Columns()
	var result [][]any
	for rows.Next() {
		values := make([]any, len(columns))
		pointers := make([]any, len(columns))
		for index := range values {
			pointers[index] = &values[index]
		}
		if err := rows.Scan(pointers...); err != nil {
			t.Fatal(err)
		}
		result = append(result, values)
	}
	return result
}

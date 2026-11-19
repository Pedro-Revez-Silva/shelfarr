package live

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"io"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/safeopen"
	_ "modernc.org/sqlite"
)

const sqliteMagic = "SQLite format 3\x00"

var SupportedRevisions = []string{"20261112150000"}

var (
	ErrNotSQLite         = errors.New("file is not a sqlite database")
	ErrSchemaUnsupported = errors.New("database schema is not supported")
	ErrBusy              = errors.New("database is busy")
	ErrUnavailable       = errors.New("database is unavailable")
)

var requiredColumns = map[string][]string{
	"schema_migrations":          {"version"},
	"settings":                   {"key", "value", "value_type"},
	"users":                      {"id", "username", "name", "role", "deleted_at", "password_digest", "failed_login_count", "last_failed_login_at", "last_failed_login_ip", "locked_until", "otp_required", "otp_secret", "oidc_provider", "oidc_uid", "updated_at"},
	"hardcover_connections":      {"user_id", "status"},
	"sessions":                   {"id", "user_id", "user_agent", "ip_address", "created_at", "updated_at"},
	"api_tokens":                 {"id", "user_id", "name", "scopes", "token_digest", "token_prefix", "revoked_at", "expires_at", "last_used_at", "created_at", "updated_at", "issued_via", "replaces_api_token_id", "connection_key"},
	"consumer_device_grants":     {"id", "user_id", "client_name", "device_code_digest", "user_code_digest", "expires_at", "approved_at", "denied_at", "consumed_at", "last_polled_at", "poll_interval", "scopes", "replaces_api_token_id", "created_at", "updated_at"},
	"books":                      {"id", "title", "author", "description", "cover_url", "file_path", "book_type", "content_kind", "open_library_work_id"},
	"metadata_provider_statuses": {"provider", "status", "rate_limited_until"},
	"consumer_progresses":        {"id", "user_id", "book_id", "asset_id", "locator", "position_seconds", "version", "observed_at", "updated_at", "client_mutation_id"},
	"consumer_reading_states":    {"id", "user_id", "book_id", "status", "updated_at"},
	"requests":                   {"id", "book_id", "user_id", "status", "attention_needed", "issue_description", "created_at", "updated_at", "completed_at", "next_retry_at"},
	"downloads":                  {"id", "request_id", "status", "progress"},
	"system_healths":             {"id", "service", "status", "last_check_at"},
}

type Options struct {
	BusyTimeout time.Duration
	MaxReaders  int
}

type DB struct {
	read  *sql.DB
	write *sql.DB
}

func dataSource(path string, busy time.Duration, queryOnly bool, immediate bool) string {
	query := url.Values{}
	query.Set("mode", "rw")
	query.Add("_pragma", "busy_timeout("+strconv.FormatInt(busy.Milliseconds(), 10)+")")
	query.Add("_pragma", "foreign_keys(0)")
	if queryOnly {
		query.Add("_pragma", "query_only(1)")
	}
	if immediate {
		query.Set("_txlock", "immediate")
	}
	return (&url.URL{Scheme: "file", Path: path, RawQuery: query.Encode()}).String()
}

func checkMagic(path string) error {
	file, err := safeopen.Regular(path)
	if err != nil {
		return ErrNotSQLite
	}
	defer file.Close()
	header := make([]byte, len(sqliteMagic))
	if _, err := io.ReadFull(file, header); err != nil || !bytes.Equal(header, []byte(sqliteMagic)) {
		return ErrNotSQLite
	}
	return nil
}

func Open(ctx context.Context, path string, options Options) (*DB, error) {
	if !strings.HasPrefix(path, "/") || strings.ContainsRune(path, 0) {
		return nil, ErrNotSQLite
	}
	if err := checkMagic(path); err != nil {
		return nil, err
	}
	busy := options.BusyTimeout
	if busy <= 0 {
		busy = 5 * time.Second
	}
	readers := options.MaxReaders
	if readers <= 0 {
		readers = 8
	}
	read, err := sql.Open("sqlite", dataSource(path, busy, true, false))
	if err != nil {
		return nil, ErrUnavailable
	}
	read.SetMaxOpenConns(readers)
	write, err := sql.Open("sqlite", dataSource(path, busy, false, true))
	if err != nil {
		read.Close()
		return nil, ErrUnavailable
	}
	write.SetMaxOpenConns(1)
	database := &DB{read: read, write: write}
	if err := database.verifySchema(ctx); err != nil {
		database.Close()
		return nil, err
	}
	return database, nil
}

func (d *DB) Close() error {
	return errors.Join(d.read.Close(), d.write.Close())
}

func (d *DB) Ready(ctx context.Context) error {
	var one int
	if err := d.read.QueryRowContext(ctx, `SELECT 1 FROM settings LIMIT 1`).Scan(&one); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return Classify(err)
	}
	return nil
}

func (d *DB) verifySchema(ctx context.Context) error {
	revision, err := d.SchemaRevision(ctx)
	if err != nil {
		return ErrSchemaUnsupported
	}
	if !contains(SupportedRevisions, revision) {
		return ErrSchemaUnsupported
	}
	for table, columns := range requiredColumns {
		present, err := d.columns(ctx, table)
		if err != nil {
			return ErrSchemaUnsupported
		}
		for _, column := range columns {
			if !present[column] {
				return ErrSchemaUnsupported
			}
		}
	}
	return nil
}

func (d *DB) columns(ctx context.Context, table string) (map[string]bool, error) {
	rows, err := d.read.QueryContext(ctx, `SELECT name FROM pragma_table_info(?)`, table)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	present := map[string]bool{}
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return nil, err
		}
		present[name] = true
	}
	return present, rows.Err()
}

func (d *DB) SchemaRevision(ctx context.Context) (string, error) {
	var version sql.NullString
	err := d.read.QueryRowContext(ctx, `SELECT CAST(MAX(CAST(version AS INTEGER)) AS TEXT) FROM schema_migrations`).Scan(&version)
	return version.String, err
}

func contains(values []string, wanted string) bool {
	for _, value := range values {
		if value == wanted {
			return true
		}
	}
	return false
}

func Classify(err error) error {
	switch {
	case err == nil:
		return nil
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return err
	}
	text := strings.ToLower(err.Error())
	if strings.Contains(text, "database is locked") || strings.Contains(text, "sqlite_busy") || strings.Contains(text, "(5)") || strings.Contains(text, "(517)") {
		return ErrBusy
	}
	return ErrUnavailable
}

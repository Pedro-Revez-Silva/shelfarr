package store

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"

	_ "modernc.org/sqlite"
)

const sqliteMagic = "SQLite format 3\x00"

var (
	ErrNotSQLite   = errors.New("file is not a sqlite database")
	ErrUnsupported = errors.New("unsupported value")
)

const (
	BookTypeAudiobook = 0
	BookTypeEbook     = 1
	BookTypeComicbook = 2
)

type DB struct {
	handle *sql.DB
}

func Open(ctx context.Context, path string) (*DB, error) {
	if err := checkMagic(path); err != nil {
		return nil, err
	}
	query := url.Values{}
	query.Set("mode", "ro")
	query.Set("immutable", "1")
	query.Add("_pragma", "query_only(1)")
	dsn := (&url.URL{Scheme: "file", Path: path, RawQuery: query.Encode()}).String()
	handle, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open database: %w", err)
	}
	handle.SetMaxOpenConns(1)
	database := &DB{handle: handle}
	if _, err := database.SchemaRevision(ctx); err != nil {
		handle.Close()
		return nil, fmt.Errorf("read database: %w", err)
	}
	return database, nil
}

func checkMagic(path string) error {
	file, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("open database file: %w", errors.Unwrap(err))
	}
	defer file.Close()
	header := make([]byte, len(sqliteMagic))
	if _, err := io.ReadFull(file, header); err != nil || !bytes.Equal(header, []byte(sqliteMagic)) {
		return ErrNotSQLite
	}
	return nil
}

func (d *DB) Close() error {
	return d.handle.Close()
}

func (d *DB) SchemaRevision(ctx context.Context) (string, error) {
	var version sql.NullString
	err := d.handle.QueryRowContext(ctx, `SELECT CAST(MAX(CAST(version AS INTEGER)) AS TEXT) FROM schema_migrations`).Scan(&version)
	return version.String, err
}

type User struct {
	ID             int64
	Username       string
	Name           string
	PasswordDigest string
	Role           int
	Deleted        bool
}

func (d *DB) UserByUsername(ctx context.Context, username string) (*User, error) {
	return d.user(ctx, `WHERE username = ? ORDER BY deleted_at IS NOT NULL, id LIMIT 1`, username)
}

func (d *DB) UserByID(ctx context.Context, id int64) (*User, error) {
	return d.user(ctx, `WHERE id = ?`, id)
}

func (d *DB) user(ctx context.Context, where string, argument any) (*User, error) {
	var user User
	var deleted sql.NullString
	row := d.handle.QueryRowContext(ctx, `SELECT id, username, name, password_digest, role, CAST(deleted_at AS TEXT) FROM users `+where, argument)
	err := row.Scan(&user.ID, &user.Username, &user.Name, &user.PasswordDigest, &user.Role, &deleted)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	user.Deleted = deleted.Valid
	return &user, nil
}

type Token struct {
	UserID     sql.NullInt64
	Scopes     string
	RevokedAt  sql.NullString
	ExpiresAt  sql.NullString
	ReplacesID sql.NullInt64
}

func (d *DB) TokenByDigest(ctx context.Context, digest string) (*Token, error) {
	var token Token
	row := d.handle.QueryRowContext(ctx, `SELECT user_id, scopes, CAST(revoked_at AS TEXT), CAST(expires_at AS TEXT), replaces_api_token_id FROM api_tokens WHERE token_digest = ?`, digest)
	err := row.Scan(&token.UserID, &token.Scopes, &token.RevokedAt, &token.ExpiresAt, &token.ReplacesID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &token, nil
}

func (d *DB) StringSetting(ctx context.Context, key string) (string, bool, error) {
	var value sql.NullString
	var valueType string
	err := d.handle.QueryRowContext(ctx, `SELECT value, value_type FROM settings WHERE key = ?`, key).Scan(&value, &valueType)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	if valueType != "string" {
		return "", false, ErrUnsupported
	}
	return value.String, value.Valid, nil
}

type Book struct {
	ID          int64
	Title       string
	Author      sql.NullString
	Description sql.NullString
	CoverURL    sql.NullString
	FilePath    sql.NullString
	BookType    int
	ContentKind int
}

const bookColumns = `id, title, author, description, cover_url, file_path, book_type, content_kind`

func scanBook(scanner interface{ Scan(...any) error }) (Book, error) {
	var book Book
	err := scanner.Scan(&book.ID, &book.Title, &book.Author, &book.Description, &book.CoverURL, &book.FilePath, &book.BookType, &book.ContentKind)
	return book, err
}

func (d *DB) AcquiredBooks(ctx context.Context, types []int) ([]Book, error) {
	rows, err := d.handle.QueryContext(ctx, `SELECT `+bookColumns+` FROM books WHERE file_path IS NOT NULL AND TRIM(file_path) <> '' AND book_type IN (`+placeholders(len(types))+`) ORDER BY id DESC`, intArguments(types)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var books []Book
	for rows.Next() {
		book, err := scanBook(rows)
		if err != nil {
			return nil, err
		}
		books = append(books, book)
	}
	return books, rows.Err()
}

func (d *DB) AcquiredBook(ctx context.Context, id int64, types []int) (*Book, error) {
	row := d.handle.QueryRowContext(ctx, `SELECT `+bookColumns+` FROM books WHERE id = ? AND file_path IS NOT NULL AND TRIM(file_path) <> '' AND book_type IN (`+placeholders(len(types))+`)`, append([]any{id}, intArguments(types)...)...)
	book, err := scanBook(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &book, nil
}

func placeholders(count int) string {
	text := make([]byte, 0, count*2)
	for index := 0; index < count; index++ {
		if index > 0 {
			text = append(text, ',')
		}
		text = append(text, '?')
	}
	return string(text)
}

func intArguments(values []int) []any {
	arguments := make([]any, len(values))
	for index, value := range values {
		arguments[index] = value
	}
	return arguments
}

type Progress struct {
	AssetID          string
	Locator          sql.NullString
	PositionSeconds  sql.NullFloat64
	Version          int64
	ObservedAt       sql.NullString
	UpdatedAt        string
	ClientMutationID string
}

func (d *DB) ProgressByBook(ctx context.Context, userID int64) (map[int64]Progress, error) {
	rows, err := d.handle.QueryContext(ctx, `SELECT book_id, asset_id, CAST(locator AS TEXT), position_seconds, version, CAST(observed_at AS TEXT), CAST(updated_at AS TEXT), client_mutation_id FROM consumer_progresses WHERE user_id = ?`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := map[int64]Progress{}
	for rows.Next() {
		var bookID int64
		var progress Progress
		if err := rows.Scan(&bookID, &progress.AssetID, &progress.Locator, &progress.PositionSeconds, &progress.Version, &progress.ObservedAt, &progress.UpdatedAt, &progress.ClientMutationID); err != nil {
			return nil, err
		}
		result[bookID] = progress
	}
	return result, rows.Err()
}

func (d *DB) ReadingStatusByBook(ctx context.Context, userID int64) (map[int64]int, error) {
	rows, err := d.handle.QueryContext(ctx, `SELECT book_id, status FROM consumer_reading_states WHERE user_id = ?`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := map[int64]int{}
	for rows.Next() {
		var bookID int64
		var status int
		if err := rows.Scan(&bookID, &status); err != nil {
			return nil, err
		}
		result[bookID] = status
	}
	return result, rows.Err()
}

var encryptedColumns = map[string]map[string]bool{
	"users":            {"otp_secret": true, "backup_codes": true},
	"download_clients": {"password": true, "api_key": true},
}

func (d *DB) EncryptedValue(ctx context.Context, table, column string, id int64) (sql.NullString, error) {
	if !encryptedColumns[table][column] {
		return sql.NullString{}, ErrUnsupported
	}
	var value sql.NullString
	err := d.handle.QueryRowContext(ctx, `SELECT `+column+` FROM `+table+` WHERE id = ?`, id).Scan(&value)
	return value, err
}

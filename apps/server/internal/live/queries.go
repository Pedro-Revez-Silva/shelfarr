package live

import (
	"context"
	"database/sql"
	"errors"
	"strings"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
)

const (
	StatusSQL   = "CASE WHEN crs.status = 2 THEN 'finished' WHEN crs.status = 1 THEN 'in_progress' WHEN crs.status = 0 THEN 'unread' WHEN cp.id IS NOT NULL THEN 'in_progress' ELSE 'unread' END"
	ActivitySQL = "CASE WHEN cp.id IS NULL THEN crs.updated_at WHEN crs.updated_at > COALESCE(cp.observed_at, cp.updated_at) THEN crs.updated_at ELSE COALESCE(cp.observed_at, cp.updated_at) END"
	TitleSort   = "LOWER(COALESCE(books.title, ''))"

	bookColumns = `books.id, books.title, books.author, books.description, books.cover_url, books.file_path, books.book_type, books.content_kind`
	acquired    = `books.file_path IS NOT NULL AND TRIM(books.file_path) <> ''`
)

type Token struct {
	ID         int64
	UserID     sql.NullInt64
	Scopes     string
	RevokedAt  sql.NullString
	ExpiresAt  sql.NullString
	ReplacesID sql.NullInt64
}

type User struct {
	ID       int64
	Username string
	Name     string
	Role     int
	Deleted  bool
}

func (d *DB) StringSetting(ctx context.Context, key string) (string, bool, error) {
	return stringSettingIn(ctx, d.read, key)
}

func stringSettingIn(ctx context.Context, q rowQuerier, key string) (string, bool, error) {
	var value sql.NullString
	var valueType string
	err := q.QueryRowContext(ctx, `SELECT value, value_type FROM settings WHERE key = ?`, key).Scan(&value, &valueType)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, Classify(err)
	}
	if valueType != "string" {
		return "", false, store.ErrUnsupported
	}
	return value.String, value.Valid, nil
}

func (d *DB) ActiveTokenByDigest(ctx context.Context, digest, now string) (*Token, error) {
	return d.activeToken(ctx, "token_digest", digest, now)
}

func (d *DB) ActiveTokenByID(ctx context.Context, id int64, now string) (*Token, error) {
	return d.activeToken(ctx, "id", id, now)
}

func (d *DB) activeToken(ctx context.Context, column string, value any, now string) (*Token, error) {
	var token Token
	err := d.read.QueryRowContext(ctx,
		`SELECT id, user_id, scopes, CAST(revoked_at AS TEXT), CAST(expires_at AS TEXT), replaces_api_token_id FROM api_tokens WHERE `+column+` = ? AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > ?) LIMIT 1`,
		value, now).Scan(&token.ID, &token.UserID, &token.Scopes, &token.RevokedAt, &token.ExpiresAt, &token.ReplacesID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, Classify(err)
	}
	return &token, nil
}

func (d *DB) UserByID(ctx context.Context, id int64) (*User, error) {
	var user User
	var deleted sql.NullString
	err := d.read.QueryRowContext(ctx, `SELECT id, username, name, role, CAST(deleted_at AS TEXT) FROM users WHERE id = ?`, id).Scan(&user.ID, &user.Username, &user.Name, &user.Role, &deleted)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, Classify(err)
	}
	user.Deleted = deleted.Valid
	return &user, nil
}

func scanBook(scanner interface{ Scan(...any) error }, extra ...any) (store.Book, error) {
	var book store.Book
	destinations := append([]any{&book.ID, &book.Title, &book.Author, &book.Description, &book.CoverURL, &book.FilePath, &book.BookType, &book.ContentKind}, extra...)
	err := scanner.Scan(destinations...)
	return book, err
}

func typePlaceholders(types []int) (string, []any) {
	marks := make([]string, len(types))
	arguments := make([]any, len(types))
	for index, value := range types {
		marks[index] = "?"
		arguments[index] = value
	}
	return strings.Join(marks, ","), arguments
}

func (d *DB) AcquiredBook(ctx context.Context, id int64, types []int) (*store.Book, error) {
	marks, arguments := typePlaceholders(types)
	row := d.read.QueryRowContext(ctx, `SELECT `+bookColumns+` FROM books WHERE books.id = ? AND `+acquired+` AND books.book_type IN (`+marks+`)`, append([]any{id}, arguments...)...)
	book, err := scanBook(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, Classify(err)
	}
	return &book, nil
}

type CatalogueQuery struct {
	UserID int64
	Types  []int
	Status string
	Search string
	Sort   string
	Limit  int
	Recent int64
	Title  *TitleBoundary
}

type TitleBoundary struct {
	Sort string
	ID   int64
}

type CatalogueRow struct {
	Book      store.Book
	TitleSort string
}

func (d *DB) Catalogue(ctx context.Context, query CatalogueQuery) ([]CatalogueRow, error) {
	marks, typeArguments := typePlaceholders(query.Types)
	sqlText := `SELECT ` + bookColumns + `, ` + TitleSort + ` FROM books ` + joins() + ` WHERE ` + acquired + ` AND books.book_type IN (` + marks + `)`
	arguments := append([]any{query.UserID, query.UserID}, typeArguments...)
	if query.Status != "" {
		sqlText += ` AND ` + StatusSQL + ` = ?`
		arguments = append(arguments, query.Status)
	}
	if query.Search != "" {
		sqlText += ` AND (books.title LIKE ? ESCAPE '\' OR books.author LIKE ? ESCAPE '\')`
		pattern := "%" + escapeLike(query.Search) + "%"
		arguments = append(arguments, pattern, pattern)
	}
	if query.Sort == "title" {
		if query.Title != nil {
			sqlText += ` AND ` + TitleSort + ` >= ? AND (` + TitleSort + ` > ? OR (` + TitleSort + ` = ? AND books.id > ?))`
			arguments = append(arguments, query.Title.Sort, query.Title.Sort, query.Title.Sort, query.Title.ID)
		}
		sqlText += ` ORDER BY ` + TitleSort + ` ASC, books.id ASC`
	} else {
		if query.Recent > 0 {
			sqlText += ` AND books.id < ?`
			arguments = append(arguments, query.Recent)
		}
		sqlText += ` ORDER BY books.id DESC`
	}
	sqlText += ` LIMIT ?`
	arguments = append(arguments, query.Limit)
	return d.catalogueRows(ctx, sqlText, arguments)
}

func joins() string {
	return `LEFT JOIN consumer_progresses cp ON cp.book_id = books.id AND cp.user_id = ? LEFT JOIN consumer_reading_states crs ON crs.book_id = books.id AND crs.user_id = ?`
}

func escapeLike(text string) string {
	var builder strings.Builder
	for _, character := range text {
		if character == '%' || character == '_' || character == '\\' {
			builder.WriteByte('\\')
		}
		builder.WriteRune(character)
	}
	return builder.String()
}

func (d *DB) catalogueRows(ctx context.Context, sqlText string, arguments []any) ([]CatalogueRow, error) {
	rows, err := d.read.QueryContext(ctx, sqlText, arguments...)
	if err != nil {
		return nil, Classify(err)
	}
	defer rows.Close()
	var result []CatalogueRow
	for rows.Next() {
		var titleSort sql.NullString
		book, err := scanBook(rows, &titleSort)
		if err != nil {
			return nil, Classify(err)
		}
		result = append(result, CatalogueRow{Book: book, TitleSort: titleSort.String})
	}
	return result, Classify(rows.Err())
}

func (d *DB) InProgress(ctx context.Context, userID int64, types []int, limit int) ([]store.Book, error) {
	marks, typeArguments := typePlaceholders(types)
	sqlText := `SELECT ` + bookColumns + ` FROM books ` + joins() + ` WHERE ` + acquired + ` AND books.book_type IN (` + marks + `) AND (books.id IN (SELECT book_id FROM consumer_progresses WHERE user_id = ?) OR books.id IN (SELECT book_id FROM consumer_reading_states WHERE user_id = ? AND status = 1)) AND ` + StatusSQL + ` = 'in_progress' ORDER BY ` + ActivitySQL + ` DESC, books.id DESC LIMIT ?`
	arguments := append([]any{userID, userID}, typeArguments...)
	arguments = append(arguments, userID, userID, limit)
	rows, err := d.read.QueryContext(ctx, sqlText, arguments...)
	if err != nil {
		return nil, Classify(err)
	}
	defer rows.Close()
	var books []store.Book
	for rows.Next() {
		book, err := scanBook(rows)
		if err != nil {
			return nil, Classify(err)
		}
		books = append(books, book)
	}
	return books, Classify(rows.Err())
}

func (d *DB) ProgressFor(ctx context.Context, userID int64, bookIDs []int64) (map[int64]store.Progress, error) {
	result := map[int64]store.Progress{}
	if len(bookIDs) == 0 {
		return result, nil
	}
	marks, arguments := idPlaceholders(bookIDs)
	rows, err := d.read.QueryContext(ctx, `SELECT book_id, asset_id, CAST(locator AS TEXT), position_seconds, version, CAST(observed_at AS TEXT), CAST(updated_at AS TEXT), client_mutation_id FROM consumer_progresses WHERE user_id = ? AND book_id IN (`+marks+`)`, append([]any{userID}, arguments...)...)
	if err != nil {
		return nil, Classify(err)
	}
	defer rows.Close()
	for rows.Next() {
		var bookID int64
		var progress store.Progress
		if err := rows.Scan(&bookID, &progress.AssetID, &progress.Locator, &progress.PositionSeconds, &progress.Version, &progress.ObservedAt, &progress.UpdatedAt, &progress.ClientMutationID); err != nil {
			return nil, Classify(err)
		}
		result[bookID] = progress
	}
	return result, Classify(rows.Err())
}

func (d *DB) StatesFor(ctx context.Context, userID int64, bookIDs []int64) (map[int64]int, error) {
	result := map[int64]int{}
	if len(bookIDs) == 0 {
		return result, nil
	}
	marks, arguments := idPlaceholders(bookIDs)
	rows, err := d.read.QueryContext(ctx, `SELECT book_id, status FROM consumer_reading_states WHERE user_id = ? AND book_id IN (`+marks+`)`, append([]any{userID}, arguments...)...)
	if err != nil {
		return nil, Classify(err)
	}
	defer rows.Close()
	for rows.Next() {
		var bookID int64
		var status int
		if err := rows.Scan(&bookID, &status); err != nil {
			return nil, Classify(err)
		}
		result[bookID] = status
	}
	return result, Classify(rows.Err())
}

func idPlaceholders(ids []int64) (string, []any) {
	marks := make([]string, len(ids))
	arguments := make([]any, len(ids))
	for index, id := range ids {
		marks[index] = "?"
		arguments[index] = id
	}
	return strings.Join(marks, ","), arguments
}

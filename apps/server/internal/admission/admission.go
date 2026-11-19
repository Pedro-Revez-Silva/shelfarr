package admission

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/fault"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/wfstore"
)

type Outcome string

const (
	Created          Outcome = "created"
	Existing         Outcome = "existing"
	AlreadyInLibrary Outcome = "already_in_library"
	AlreadyRequested Outcome = "already_requested"
)

var (
	ErrAccountUnavailable = errors.New("account_unavailable")
	ErrSchemaUnsupported  = errors.New("unsupported_schema")
	ErrStoredValue        = errors.New("unsupported_stored_value")

	SupportedRevisions = []string{"20261112150000"}

	requiredColumns = map[string][]string{
		"users":         {"id", "deleted_at"},
		"settings":      {"key", "value", "value_type"},
		"books":         {"id", "open_library_work_id", "book_type", "title", "author", "cover_url", "year", "file_path", "content_kind", "metadata_source", "acquisition_reservation_token", "acquisition_reservation_owner_type", "acquisition_reservation_owner_id", "created_at", "updated_at"},
		"requests":      {"id", "book_id", "user_id", "status", "attention_needed", "created_via", "external_source", "language", "request_scope", "retry_count", "search_generation", "search_claimed_at", "created_at", "updated_at"},
		"activity_logs": {"action", "user_id", "trackable_type", "trackable_id", "details", "ip_address", "controller", "created_at", "updated_at"},
	}
)

const (
	ebookType          = 1
	bookContentKind    = 0
	graphicContentKind = 1
	openStatuses       = "0, 1, 3, 4, 7"
	retryableStatuses  = "2, 6"
	failedStatus       = 6
	createdVia         = "api"
	externalSource     = "consumer_app"
	requestScope       = "single"
	metadataSource     = "openlibrary"
	defaultLanguage    = "en"
	activityAction     = "request.created"
	activityDetails    = `{"created_via":"api","external_source":"consumer_app"}`
)

var otherFormats = []struct {
	bookType int
	warning  string
}{
	{0, "This title exists as an audiobook. You can still request the ebook."},
	{2, "This title exists as a Comics & Manga title. You can still request the ebook."},
}

type Result struct {
	Outcome       Outcome
	RequestID     int64
	PublicationID int64
	Warnings      []string
}

type Transactor interface {
	Transact(ctx context.Context, fn func(tx *sql.Tx) error) error
}

func Submit(ctx context.Context, store Transactor, accountID int64, submission Submission, clock func() time.Time) (Result, error) {
	if err := fault.Hit(ctx, "admission.authorized"); err != nil {
		return Result{}, err
	}
	var result Result
	err := store.Transact(ctx, func(tx *sql.Tx) error {
		decided, err := admit(ctx, tx, accountID, submission, clock)
		result = decided
		return err
	})
	if err != nil {
		return Result{}, err
	}
	return result, nil
}

type storedBook struct {
	id                   int64
	title                string
	author               sql.NullString
	coverURL             sql.NullString
	year                 sql.NullInt64
	filePath             sql.NullString
	contentKind          int64
	metadataSource       sql.NullString
	reservationToken     sql.NullString
	reservationOwnerType sql.NullString
	reservationOwnerID   sql.NullInt64
}

func admit(ctx context.Context, tx *sql.Tx, accountID int64, submission Submission, clock func() time.Time) (Result, error) {
	if err := verifySchema(ctx, tx); err != nil {
		return Result{}, err
	}
	if err := requireActiveAccount(ctx, tx, accountID); err != nil {
		return Result{}, err
	}
	book, err := reusableBook(ctx, tx, submission.OpenLibraryWorkID)
	if err != nil {
		return Result{}, err
	}
	if book != nil {
		if acquired(book.filePath) {
			return Result{Outcome: AlreadyInLibrary, PublicationID: book.id}, nil
		}
		decided, found, err := openRequest(ctx, tx, book.id, accountID)
		if err != nil || found {
			return decided, err
		}
	}
	warnings, err := duplicateWarnings(ctx, tx, submission.OpenLibraryWorkID, book)
	if err != nil {
		return Result{}, err
	}
	language, err := requestLanguage(ctx, tx, submission.Language)
	if err != nil {
		return Result{}, err
	}
	stamp := wfstore.FormatTimestamp(clock())
	bookID, err := writeBook(ctx, tx, book, submission, stamp)
	if err != nil {
		return Result{}, err
	}
	if err := fault.Hit(ctx, "admission.book-written"); err != nil {
		return Result{}, err
	}
	requestID, err := insertRequest(ctx, tx, bookID, accountID, language, stamp)
	if err != nil {
		return Result{}, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO activity_logs (action, user_id, trackable_type, trackable_id, details, created_at, updated_at) VALUES (?, ?, 'Request', ?, ?, ?, ?)`,
		activityAction, accountID, requestID, activityDetails, stamp, stamp); err != nil {
		return Result{}, err
	}
	if err := fault.Hit(ctx, "admission.before-commit"); err != nil {
		return Result{}, err
	}
	return Result{Outcome: Created, RequestID: requestID, Warnings: warnings}, nil
}

func verifySchema(ctx context.Context, tx *sql.Tx) error {
	var revision sql.NullString
	if err := tx.QueryRowContext(ctx, `SELECT CAST(MAX(CAST(version AS INTEGER)) AS TEXT) FROM schema_migrations`).Scan(&revision); err != nil {
		return ErrSchemaUnsupported
	}
	if !contains(SupportedRevisions, revision.String) {
		return ErrSchemaUnsupported
	}
	for table, columns := range requiredColumns {
		present, err := tableColumns(ctx, tx, table)
		if err != nil {
			return err
		}
		for _, column := range columns {
			if !present[column] {
				return ErrSchemaUnsupported
			}
		}
	}
	return nil
}

func tableColumns(ctx context.Context, tx *sql.Tx, table string) (map[string]bool, error) {
	rows, err := tx.QueryContext(ctx, `SELECT name FROM pragma_table_info(?)`, table)
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

func contains(values []string, wanted string) bool {
	for _, value := range values {
		if value == wanted {
			return true
		}
	}
	return false
}

func requireActiveAccount(ctx context.Context, tx *sql.Tx, accountID int64) error {
	var deletedAt sql.NullString
	err := tx.QueryRowContext(ctx, `SELECT deleted_at FROM users WHERE id = ?`, accountID).Scan(&deletedAt)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return ErrAccountUnavailable
	case err != nil:
		return err
	case deletedAt.Valid:
		return ErrAccountUnavailable
	}
	return nil
}

func reusableBook(ctx context.Context, tx *sql.Tx, workID string) (*storedBook, error) {
	var book storedBook
	err := tx.QueryRowContext(ctx, `SELECT id, title, author, cover_url, year, file_path, content_kind, metadata_source,
		acquisition_reservation_token, acquisition_reservation_owner_type, acquisition_reservation_owner_id
		FROM books WHERE open_library_work_id = ? AND book_type = ? ORDER BY id DESC LIMIT 1`, workID, ebookType).
		Scan(&book.id, &book.title, &book.author, &book.coverURL, &book.year, &book.filePath, &book.contentKind, &book.metadataSource,
			&book.reservationToken, &book.reservationOwnerType, &book.reservationOwnerID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, ErrStoredValue
	}
	for _, text := range []string{book.title, book.author.String, book.coverURL.String, book.filePath.String, book.metadataSource.String, book.reservationToken.String, book.reservationOwnerType.String} {
		if !utf8.ValidString(text) {
			return nil, ErrStoredValue
		}
	}
	if book.contentKind != bookContentKind && book.contentKind != graphicContentKind {
		return nil, ErrStoredValue
	}
	return &book, nil
}

func acquired(path sql.NullString) bool {
	return path.Valid && !rubyBlank(path.String)
}

func openRequest(ctx context.Context, tx *sql.Tx, bookID, accountID int64) (Result, bool, error) {
	var requestID, ownerID int64
	err := tx.QueryRowContext(ctx, `SELECT id, user_id FROM requests WHERE book_id = ? AND status IN (`+openStatuses+`) ORDER BY id LIMIT 1`, bookID).Scan(&requestID, &ownerID)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return Result{}, false, nil
	case err != nil:
		return Result{}, false, err
	case ownerID == accountID:
		return Result{Outcome: Existing, RequestID: requestID}, true, nil
	}
	return Result{Outcome: AlreadyRequested}, true, nil
}

func duplicateWarnings(ctx context.Context, tx *sql.Tx, workID string, book *storedBook) ([]string, error) {
	for _, format := range otherFormats {
		var one int
		err := tx.QueryRowContext(ctx, `SELECT 1 FROM books WHERE open_library_work_id = ? AND book_type = ? LIMIT 1`, workID, format.bookType).Scan(&one)
		if err == nil {
			return []string{format.warning}, nil
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return nil, err
		}
	}
	if book == nil {
		return []string{}, nil
	}
	var status int64
	err := tx.QueryRowContext(ctx, `SELECT status FROM requests WHERE book_id = ? AND status IN (`+retryableStatuses+`) ORDER BY id LIMIT 1`, book.id).Scan(&status)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return []string{}, nil
	case err != nil:
		return nil, err
	case status == failedStatus:
		return []string{"A previous request for this ebook failed. You can try again."}, nil
	}
	return []string{"A previous request for this ebook was not found. You can try again."}, nil
}

func requestLanguage(ctx context.Context, tx *sql.Tx, requested *string) (string, error) {
	if requested != nil {
		return *requested, nil
	}
	var value sql.NullString
	var valueType string
	err := tx.QueryRowContext(ctx, `SELECT value, value_type FROM settings WHERE key = 'default_language'`).Scan(&value, &valueType)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return defaultLanguage, nil
	case err != nil:
		return "", ErrStoredValue
	case valueType != "string" || !utf8.ValidString(value.String):
		return "", ErrStoredValue
	case !value.Valid:
		return defaultLanguage, nil
	}
	return value.String, nil
}

func writeBook(ctx context.Context, tx *sql.Tx, book *storedBook, submission Submission, stamp string) (int64, error) {
	if book == nil {
		result, err := tx.ExecContext(ctx, `INSERT INTO books (open_library_work_id, book_type, title, author, cover_url, year, content_kind, metadata_source, created_at, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			submission.OpenLibraryWorkID, ebookType, submission.Title, submission.Author, submission.CoverURL, submission.Year, bookContentKind, metadataSource, stamp, stamp)
		if err != nil {
			return 0, err
		}
		return result.LastInsertId()
	}
	assignments, arguments := backfill(book, submission)
	if len(assignments) == 0 {
		return book.id, nil
	}
	if reservedWithoutOwner(book) {
		return 0, ErrStoredValue
	}
	arguments = append(arguments, stamp, book.id)
	_, err := tx.ExecContext(ctx, `UPDATE books SET `+strings.Join(assignments, ", ")+`, updated_at = ? WHERE id = ?`, arguments...)
	return book.id, err
}

func backfill(book *storedBook, submission Submission) ([]string, []any) {
	var assignments []string
	var arguments []any
	assign := func(column string, value any) {
		assignments = append(assignments, column+" = ?")
		arguments = append(arguments, value)
	}
	if rubyBlank(book.title) {
		assign("title", submission.Title)
	}
	if rubyBlank(book.author.String) && submission.Author != nil {
		assign("author", *submission.Author)
	}
	if rubyBlank(book.coverURL.String) && submission.CoverURL != nil {
		assign("cover_url", *submission.CoverURL)
	}
	if !book.year.Valid && submission.Year != nil {
		assign("year", *submission.Year)
	}
	if rubyBlank(book.metadataSource.String) {
		assign("metadata_source", metadataSource)
	}
	return assignments, arguments
}

func reservedWithoutOwner(book *storedBook) bool {
	return !rubyBlank(book.reservationToken.String) && (rubyBlank(book.reservationOwnerType.String) || !book.reservationOwnerID.Valid)
}

func insertRequest(ctx context.Context, tx *sql.Tx, bookID, accountID int64, language, stamp string) (int64, error) {
	result, err := tx.ExecContext(ctx, `INSERT INTO requests (book_id, user_id, status, attention_needed, created_via, external_source, language, request_scope, retry_count, search_generation, created_at, updated_at)
		VALUES (?, ?, 0, 0, ?, ?, ?, ?, 0, 0, ?, ?)`, bookID, accountID, createdVia, externalSource, language, requestScope, stamp, stamp)
	if err != nil {
		return 0, err
	}
	return result.LastInsertId()
}

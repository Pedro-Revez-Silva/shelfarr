package live

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"strings"

	"golang.org/x/text/cases"
	"golang.org/x/text/language"
	"golang.org/x/text/unicode/norm"
	"modernc.org/sqlite"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
)

const requestFoldFunction = "shelfarr_request_fold"

var RequestStatuses = map[string]int{
	"pending":           0,
	"searching":         1,
	"not_found":         2,
	"downloading":       3,
	"processing":        4,
	"completed":         5,
	"failed":            6,
	"awaiting_purchase": 7,
}

var DownloadStatuses = map[int]string{0: "queued", 1: "downloading", 2: "paused", 3: "completed", 4: "failed"}

const (
	activeRequestStatuses   = "0, 1, 3, 4"
	progressDownloadStatus  = "0, 1, 2"
	RequestFilterActive     = "active"
	MaxRequestDownloadsRead = 10
)

func init() {
	sqlite.MustRegisterDeterministicScalarFunction(requestFoldFunction, 1, foldArgument)
}

func foldArgument(_ *sqlite.FunctionContext, arguments []driver.Value) (driver.Value, error) {
	switch value := arguments[0].(type) {
	case string:
		return FoldRequestText(value), nil
	case []byte:
		return FoldRequestText(string(value)), nil
	}
	return "", nil
}

func FoldRequestText(value string) string {
	return cases.Lower(language.Und).String(norm.NFC.String(value))
}

type RequestScope struct {
	UserID int64
	All    bool
}

type RequestFilter struct {
	Status    string
	Attention bool
	Query     string
}

type RequestRow struct {
	ID               int64
	UserID           int64
	Status           int
	Attention        bool
	IssueDescription sql.NullString
	CreatedAt        string
	UpdatedAt        string
	CompletedAt      sql.NullString
	NextRetryAt      sql.NullString
	RequesterName    sql.NullString
	Book             store.Book
}

type RequestCounts struct {
	Attention int
	Active    int
}

type RequestPage struct {
	Rows     []RequestRow
	Total    int
	Page     int
	Pages    int
	Counts   RequestCounts
	Progress map[int64]int
}

type DownloadRow struct {
	Status   int
	Progress sql.NullInt64
}

const requestColumns = `requests.id, requests.user_id, requests.status, COALESCE(requests.attention_needed, 0), requests.issue_description,
	CAST(requests.created_at AS TEXT), CAST(requests.updated_at AS TEXT), CAST(requests.completed_at AS TEXT), CAST(requests.next_retry_at AS TEXT), users.name, ` + bookColumns

const requestSource = ` FROM requests JOIN books ON books.id = requests.book_id LEFT JOIN users ON users.id = requests.user_id`

func scopeCondition(scope RequestScope) (string, []any) {
	if scope.All {
		return "1 = 1", nil
	}
	return "requests.user_id = ?", []any{scope.UserID}
}

func filterConditions(scope RequestScope, filter RequestFilter) (string, []any, error) {
	condition, arguments := scopeCondition(scope)
	conditions := []string{condition}
	switch filter.Status {
	case "":
	case RequestFilterActive:
		conditions = append(conditions, "requests.status IN ("+activeRequestStatuses+") AND requests.attention_needed = 0")
	default:
		value, known := RequestStatuses[filter.Status]
		if !known {
			return "", nil, store.ErrUnsupported
		}
		conditions = append(conditions, "requests.status = ?")
		arguments = append(arguments, value)
	}
	if filter.Attention {
		conditions = append(conditions, "requests.attention_needed = 1")
	}
	if filter.Query != "" {
		pattern := "%" + escapeLike(FoldRequestText(filter.Query)) + "%"
		conditions = append(conditions, "("+requestFoldFunction+"(books.title) LIKE ? ESCAPE '\\' OR "+requestFoldFunction+"(books.author) LIKE ? ESCAPE '\\')")
		arguments = append(arguments, pattern, pattern)
	}
	return strings.Join(conditions, " AND "), arguments, nil
}

func scanRequest(scanner interface{ Scan(...any) error }) (RequestRow, error) {
	var row RequestRow
	var attention int64
	err := scanner.Scan(&row.ID, &row.UserID, &row.Status, &attention, &row.IssueDescription, &row.CreatedAt, &row.UpdatedAt, &row.CompletedAt, &row.NextRetryAt, &row.RequesterName,
		&row.Book.ID, &row.Book.Title, &row.Book.Author, &row.Book.Description, &row.Book.CoverURL, &row.Book.FilePath, &row.Book.BookType, &row.Book.ContentKind)
	row.Attention = attention == 1
	return row, err
}

func (d *DB) Requests(ctx context.Context, scope RequestScope, filter RequestFilter, page, perPage int) (RequestPage, error) {
	where, arguments, err := filterConditions(scope, filter)
	if err != nil {
		return RequestPage{}, err
	}
	tx, err := d.read.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return RequestPage{}, Classify(err)
	}
	defer tx.Rollback()
	result := RequestPage{Progress: map[int64]int{}}
	if result.Counts, err = requestCounts(ctx, tx, scope); err != nil {
		return RequestPage{}, err
	}
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*)`+requestSource+` WHERE `+where, arguments...).Scan(&result.Total); err != nil {
		return RequestPage{}, Classify(err)
	}
	result.Pages = max((result.Total+perPage-1)/perPage, 1)
	result.Page = min(max(page, 1), result.Pages)
	rows, err := tx.QueryContext(ctx, `SELECT `+requestColumns+requestSource+` WHERE `+where+` ORDER BY requests.created_at DESC, requests.id DESC LIMIT ? OFFSET ?`,
		append(arguments, perPage, (result.Page-1)*perPage)...)
	if err != nil {
		return RequestPage{}, Classify(err)
	}
	defer rows.Close()
	for rows.Next() {
		row, err := scanRequest(rows)
		if err != nil {
			return RequestPage{}, Classify(err)
		}
		result.Rows = append(result.Rows, row)
	}
	if err := rows.Err(); err != nil {
		return RequestPage{}, Classify(err)
	}
	if result.Progress, err = downloadProgress(ctx, tx, result.Rows); err != nil {
		return RequestPage{}, err
	}
	return result, nil
}

func requestCounts(ctx context.Context, tx *sql.Tx, scope RequestScope) (RequestCounts, error) {
	condition, arguments := scopeCondition(scope)
	var counts RequestCounts
	err := tx.QueryRowContext(ctx, `SELECT COALESCE(SUM(attention_needed = 1), 0), COALESCE(SUM(status IN (`+activeRequestStatuses+`) AND attention_needed = 0), 0) FROM requests WHERE `+condition, arguments...).Scan(&counts.Attention, &counts.Active)
	return counts, Classify(err)
}

func downloadProgress(ctx context.Context, tx *sql.Tx, requests []RequestRow) (map[int64]int, error) {
	result := map[int64]int{}
	var ids []int64
	for _, row := range requests {
		if row.Status == RequestStatuses["downloading"] {
			ids = append(ids, row.ID)
		}
	}
	if len(ids) == 0 {
		return result, nil
	}
	marks, arguments := idPlaceholders(ids)
	rows, err := tx.QueryContext(ctx, `SELECT request_id, MAX(progress) FROM downloads WHERE request_id IN (`+marks+`) AND status IN (`+progressDownloadStatus+`) AND progress IS NOT NULL GROUP BY request_id`, arguments...)
	if err != nil {
		return nil, Classify(err)
	}
	defer rows.Close()
	for rows.Next() {
		var id, progress int64
		if err := rows.Scan(&id, &progress); err != nil {
			return nil, Classify(err)
		}
		result[id] = int(min(max(progress, 0), 100))
	}
	return result, Classify(rows.Err())
}

type RequestDetail struct {
	Row       RequestRow
	Progress  map[int64]int
	Downloads []DownloadRow
}

func (d *DB) Request(ctx context.Context, scope RequestScope, id int64) (*RequestDetail, error) {
	condition, arguments := scopeCondition(scope)
	tx, err := d.read.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return nil, Classify(err)
	}
	defer tx.Rollback()
	row, err := scanRequest(tx.QueryRowContext(ctx, `SELECT `+requestColumns+requestSource+` WHERE requests.id = ? AND `+condition, append([]any{id}, arguments...)...))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, Classify(err)
	}
	detail := RequestDetail{Row: row}
	if detail.Progress, err = downloadProgress(ctx, tx, []RequestRow{row}); err != nil {
		return nil, err
	}
	rows, err := tx.QueryContext(ctx, `SELECT status, progress FROM downloads WHERE request_id = ? ORDER BY id DESC LIMIT ?`, id, MaxRequestDownloadsRead)
	if err != nil {
		return nil, Classify(err)
	}
	defer rows.Close()
	for rows.Next() {
		var download DownloadRow
		if err := rows.Scan(&download.Status, &download.Progress); err != nil {
			return nil, Classify(err)
		}
		detail.Downloads = append(detail.Downloads, download)
	}
	return &detail, Classify(rows.Err())
}

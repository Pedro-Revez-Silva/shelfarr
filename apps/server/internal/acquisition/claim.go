package acquisition

import (
	"context"
	"database/sql"
	"errors"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/admission"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/fault"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/gutenberg"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/wfstore"
)

const (
	StaleSearchLease = 30 * time.Minute

	pendingStatus   = 0
	searchingStatus = 1
	notFoundStatus  = 2
	ebookType       = 1
)

var (
	ErrSchemaUnsupported   = errors.New("unsupported_schema")
	ErrStoredValue         = errors.New("unsupported_stored_value")
	ErrRequestMissing      = errors.New("request_not_found")
	ErrNotPending          = errors.New("request_not_pending")
	ErrClaimed             = errors.New("request_claimed")
	ErrNotEbook            = errors.New("not_an_ebook")
	ErrAccountUnavailable  = errors.New("account_unavailable")
	ErrProviderDisabled    = errors.New("provider_disabled")
	ErrProviderInvalid     = errors.New("provider_invalid")
	ErrProviderNotLoopback = errors.New("provider_not_loopback")
	ErrOtherSources        = errors.New("other_sources_configured")
	ErrAutoSelect          = errors.New("auto_select_enabled")
	ErrOutbound            = errors.New("outbound_notifications_configured")
	ErrSuperseded          = errors.New("superseded")

	Refusals = []error{
		ErrSchemaUnsupported, ErrStoredValue, ErrRequestMissing, ErrNotPending, ErrNotEbook, ErrAccountUnavailable,
		ErrProviderDisabled, ErrProviderInvalid, ErrProviderNotLoopback, ErrOtherSources, ErrAutoSelect, ErrOutbound,
	}

	requiredColumns = map[string][]string{
		"users":                 {"id", "deleted_at"},
		"settings":              {"key", "value", "value_type"},
		"books":                 {"id", "book_type", "title", "author"},
		"requests":              {"id", "book_id", "user_id", "status", "attention_needed", "issue_description", "language", "retry_count", "next_retry_at", "search_generation", "search_claimed_at", "updated_at"},
		"search_results":        {"id", "request_id", "guid", "title", "indexer", "size_bytes", "seeders", "leechers", "download_url", "magnet_url", "info_url", "published_at", "source", "detected_language", "status", "blocklisted_at", "blocklist_reason", "provider_payload", "confidence_score", "score_breakdown", "created_at", "updated_at"},
		"downloads":             {"id", "request_id", "search_result_id", "status"},
		"store_offers":          {"request_id"},
		"request_events":        {"request_id", "download_id", "event_type", "source", "message", "level", "details", "user_visible", "created_at", "updated_at"},
		"notifications":         {"user_id", "notifiable_type", "notifiable_id", "notification_type", "title", "message", "read_at", "created_at", "updated_at"},
		"acquisition_providers": {"enabled", "supports_ebooks"},
	}
)

func Refusal(err error) error {
	for _, refusal := range Refusals {
		if errors.Is(err, refusal) {
			return refusal
		}
	}
	return nil
}

type Claim struct {
	RequestID  int64
	Generation int64
	Config     Config
	Query      gutenberg.Query
}

type requestRow struct {
	status      int64
	userID      int64
	generation  int64
	claimedAt   sql.NullString
	language    sql.NullString
	retryCount  sql.NullInt64
	bookType    int64
	title       sql.NullString
	author      sql.NullString
	accountGone bool
}

func ClaimRequest(ctx context.Context, store *wfstore.Store, requestID int64, now time.Time) (Claim, error) {
	var claim Claim
	err := store.Transact(ctx, func(tx *sql.Tx) error {
		row, config, err := eligible(ctx, tx, requestID)
		if err != nil {
			return err
		}
		if err := claimable(row); err != nil {
			return err
		}
		stamp := wfstore.FormatTimestamp(now)
		result, err := tx.ExecContext(ctx, `UPDATE requests SET status = ?, search_generation = search_generation + 1, search_claimed_at = ?,
			attention_needed = 0, issue_description = NULL, updated_at = ?
			WHERE id = ? AND book_id IS NOT NULL AND (status = ? OR (status = ? AND search_claimed_at IS NOT NULL AND search_claimed_at <= ?))`,
			searchingStatus, stamp, stamp, requestID, pendingStatus, searchingStatus, wfstore.FormatTimestamp(now.Add(-StaleSearchLease)))
		if err != nil {
			return err
		}
		if changed, err := result.RowsAffected(); err != nil || changed != 1 {
			return ErrClaimed
		}
		if err := tx.QueryRowContext(ctx, `SELECT search_generation FROM requests WHERE id = ?`, requestID).Scan(&claim.Generation); err != nil {
			return err
		}
		claim.RequestID = requestID
		claim.Config = config
		claim.Query = queryFor(row, config)
		return nil
	})
	if err != nil {
		return Claim{}, err
	}
	if err := fault.Hit(ctx, "search.claimed"); err != nil {
		return Claim{}, err
	}
	return claim, nil
}

func claimable(row requestRow) error {
	if row.status == pendingStatus || (row.status == searchingStatus && row.claimedAt.Valid) {
		return nil
	}
	return ErrNotPending
}

func eligible(ctx context.Context, tx *sql.Tx, requestID int64) (requestRow, Config, error) {
	if err := verifySchema(ctx, tx); err != nil {
		return requestRow{}, Config{}, err
	}
	row, err := readRequest(ctx, tx, requestID)
	if err != nil {
		return requestRow{}, Config{}, err
	}
	switch {
	case row.bookType != ebookType:
		return requestRow{}, Config{}, ErrNotEbook
	case row.accountGone:
		return requestRow{}, Config{}, ErrAccountUnavailable
	case !row.retryCount.Valid || row.retryCount.Int64 < 0:
		return requestRow{}, Config{}, ErrStoredValue
	}
	config, err := loadConfig(ctx, tx)
	if err != nil {
		return requestRow{}, Config{}, err
	}
	var custom int64
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM acquisition_providers WHERE enabled = 1 AND supports_ebooks = 1`).Scan(&custom); err != nil {
		return requestRow{}, Config{}, err
	}
	if custom > 0 {
		return requestRow{}, Config{}, ErrOtherSources
	}
	return row, config, nil
}

func readRequest(ctx context.Context, tx *sql.Tx, requestID int64) (requestRow, error) {
	var row requestRow
	var bookType sql.NullInt64
	var deletedAt sql.NullString
	var userFound sql.NullInt64
	err := tx.QueryRowContext(ctx, `SELECT r.status, r.user_id, r.search_generation, r.search_claimed_at, r.language, r.retry_count,
			b.book_type, b.title, b.author, u.id, u.deleted_at
		FROM requests r LEFT JOIN books b ON b.id = r.book_id LEFT JOIN users u ON u.id = r.user_id
		WHERE r.id = ? AND typeof(r.status) = 'integer' AND typeof(r.search_generation) = 'integer'`, requestID).
		Scan(&row.status, &row.userID, &row.generation, &row.claimedAt, &row.language, &row.retryCount,
			&bookType, &row.title, &row.author, &userFound, &deletedAt)
	if errors.Is(err, sql.ErrNoRows) {
		var exists int
		if tx.QueryRowContext(ctx, `SELECT 1 FROM requests WHERE id = ?`, requestID).Scan(&exists) == nil {
			return requestRow{}, ErrStoredValue
		}
		return requestRow{}, ErrRequestMissing
	}
	if err != nil {
		return requestRow{}, ErrStoredValue
	}
	for _, text := range []string{row.claimedAt.String, row.language.String, row.title.String, row.author.String} {
		if !utf8.ValidString(text) {
			return requestRow{}, ErrStoredValue
		}
	}
	row.bookType = bookType.Int64
	if !bookType.Valid {
		row.bookType = -1
	}
	row.accountGone = !userFound.Valid || deletedAt.Valid
	return row, nil
}

func verifySchema(ctx context.Context, tx *sql.Tx) error {
	var revision sql.NullString
	if err := tx.QueryRowContext(ctx, `SELECT CAST(MAX(CAST(version AS INTEGER)) AS TEXT) FROM schema_migrations`).Scan(&revision); err != nil {
		return ErrSchemaUnsupported
	}
	known := false
	for _, supported := range admission.SupportedRevisions {
		known = known || supported == revision.String
	}
	if !known {
		return ErrSchemaUnsupported
	}
	for table, columns := range requiredColumns {
		present := map[string]bool{}
		rows, err := tx.QueryContext(ctx, `SELECT name FROM pragma_table_info(?)`, table)
		if err != nil {
			return err
		}
		for rows.Next() {
			var name string
			if err := rows.Scan(&name); err != nil {
				rows.Close()
				return err
			}
			present[name] = true
		}
		if err := rows.Close(); err != nil {
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

func queryFor(row requestRow, config Config) gutenberg.Query {
	return gutenberg.Query{
		Titles:   TitleVariants(row.title.String),
		Author:   row.author.String,
		Language: effectiveLanguage(row.language, config.defaultLang),
		Limit:    config.Limit,
	}
}

func (c Claim) searchedWith(row requestRow, config Config) bool {
	query := queryFor(row, config)
	return config.Origin == c.Config.Origin && slices.Equal(query.Titles, c.Query.Titles) &&
		query.Author == c.Query.Author && query.Language == c.Query.Language && query.Limit == c.Query.Limit
}

func effectiveLanguage(language sql.NullString, fallback string) string {
	if language.Valid && !gutenberg.RubyBlank(language.String) {
		return language.String
	}
	return fallback
}

func TitleVariants(title string) []string {
	full := squish(title)
	if full == "" {
		return nil
	}
	first, second, split := cutSpacedSlash(full)
	if !split {
		return []string{full}
	}
	var variants []string
	for _, variant := range []string{squish(first), squish(second), full} {
		if gutenberg.RubyBlank(variant) || containsString(variants, variant) {
			continue
		}
		variants = append(variants, variant)
	}
	return variants
}

func squish(text string) string {
	return strings.Join(strings.FieldsFunc(text, isRubySpace), " ")
}

func isRubySpace(r rune) bool {
	return gutenberg.RubyBlank(string(r))
}

func cutSpacedSlash(text string) (string, string, bool) {
	index := strings.Index(text, " / ")
	if index < 0 {
		return "", "", false
	}
	return text[:index], text[index+3:], true
}

func containsString(values []string, wanted string) bool {
	for _, value := range values {
		if value == wanted {
			return true
		}
	}
	return false
}

func Heartbeat(ctx context.Context, store *wfstore.Store, claim Claim, now time.Time) error {
	return store.Transact(ctx, func(tx *sql.Tx) error {
		result, err := tx.ExecContext(ctx, `UPDATE requests SET search_claimed_at = ? WHERE id = ? AND status = ? AND search_generation = ? AND search_claimed_at IS NOT NULL`,
			wfstore.FormatTimestamp(now), claim.RequestID, searchingStatus, claim.Generation)
		if err != nil {
			return err
		}
		if changed, err := result.RowsAffected(); err != nil || changed != 1 {
			return ErrSuperseded
		}
		return nil
	})
}

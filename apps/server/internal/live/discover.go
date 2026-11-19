package live

import (
	"context"
	"database/sql"
	"errors"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/openlibrary"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
)

type OpenLibraryState string

const (
	OpenLibraryAvailable   OpenLibraryState = "available"
	OpenLibraryDisabled    OpenLibraryState = "provider_disabled"
	OpenLibraryNotSelected OpenLibraryState = "provider_not_selected"
	OpenLibraryPaused      OpenLibraryState = "provider_paused"
)

type OpenLibrarySettings struct {
	State       OpenLibraryState
	Limit       int
	PausedUntil time.Time
}

var otherMetadataProviders = map[string]bool{"hardcover": true, "google_books": true, "comic_vine": true}

func rubyStrip(value string) string {
	return strings.Trim(value, " \t\n\v\f\r\x00")
}

func (d *DB) OpenLibrarySettings(ctx context.Context, now time.Time) (OpenLibrarySettings, error) {
	enabled, err := d.BooleanSetting(ctx, "open_library_enabled", true)
	if err != nil {
		return OpenLibrarySettings{}, err
	}
	if !enabled {
		return OpenLibrarySettings{State: OpenLibraryDisabled}, nil
	}
	source, present, err := d.StringSetting(ctx, "metadata_source")
	if err != nil {
		return OpenLibrarySettings{}, err
	}
	if present && otherMetadataProviders[rubyStrip(source)] {
		return OpenLibrarySettings{State: OpenLibraryNotSelected}, nil
	}
	limit, err := d.openLibraryLimit(ctx)
	if err != nil {
		return OpenLibrarySettings{}, err
	}
	paused, until, err := d.openLibraryPaused(ctx, now)
	if err != nil {
		return OpenLibrarySettings{}, err
	}
	if paused {
		return OpenLibrarySettings{State: OpenLibraryPaused, Limit: limit, PausedUntil: until}, nil
	}
	return OpenLibrarySettings{State: OpenLibraryAvailable, Limit: limit}, nil
}

var railsDecimal = regexp.MustCompile(`^([+-]?)(?:0[dD])?([0-9]+(?:_[0-9]+)*)$`)

func (d *DB) openLibraryLimit(ctx context.Context) (int, error) {
	row, err := d.Setting(ctx, "open_library_search_limit")
	if err != nil {
		return 0, err
	}
	if !row.Found || !row.Value.Valid {
		return openlibrary.MaxResults, nil
	}
	parts := railsDecimal.FindStringSubmatch(strings.TrimSpace(row.Value.String))
	if row.Type != "integer" || parts == nil {
		return 0, store.ErrUnsupported
	}
	digits := strings.TrimLeft(strings.ReplaceAll(parts[2], "_", ""), "0")
	if parts[1] == "-" {
		return 0, nil
	}
	if len(digits) > 2 {
		return openlibrary.MaxResults, nil
	}
	value, _ := strconv.Atoi("0" + digits)
	return min(value, openlibrary.MaxResults), nil
}

func (d *DB) openLibraryPaused(ctx context.Context, now time.Time) (bool, time.Time, error) {
	var status string
	var until sql.NullString
	err := d.read.QueryRowContext(ctx, `SELECT status, CAST(rate_limited_until AS TEXT) FROM metadata_provider_statuses WHERE provider = 'openlibrary'`).Scan(&status, &until)
	if errors.Is(err, sql.ErrNoRows) {
		return false, time.Time{}, nil
	}
	if err != nil {
		return false, time.Time{}, Classify(err)
	}
	if status == "auth_failed" {
		return true, time.Time{}, nil
	}
	if !until.Valid || until.String == "" {
		return false, time.Time{}, nil
	}
	moment, err := store.ParseTimestamp(until.String)
	if err != nil {
		return false, time.Time{}, err
	}
	if moment.After(now) {
		return true, moment, nil
	}
	return false, time.Time{}, nil
}

type WorkCopy struct {
	WorkID string
	Book   store.Book
}

const CopiesPerFormat = 3

func (d *DB) AcquiredCopiesOfOpenLibraryWorks(ctx context.Context, workIDs []string, types []int) ([]WorkCopy, error) {
	if len(workIDs) == 0 || len(types) == 0 {
		return []WorkCopy{}, nil
	}
	workMarks := make([]string, len(workIDs))
	arguments := make([]any, 0, len(workIDs)+len(types))
	for index, id := range workIDs {
		workMarks[index] = "?"
		arguments = append(arguments, id)
	}
	typeMarks, typeArguments := typePlaceholders(types)
	arguments = append(arguments, typeArguments...)
	arguments = append(arguments, CopiesPerFormat)
	rows, err := d.read.QueryContext(ctx, `SELECT id, title, author, description, cover_url, file_path, book_type, content_kind, work FROM (SELECT `+bookColumns+`, books.open_library_work_id AS work,
		ROW_NUMBER() OVER (PARTITION BY books.open_library_work_id, books.book_type ORDER BY books.id DESC) AS depth FROM books
		WHERE books.open_library_work_id IN (`+strings.Join(workMarks, ",")+`) AND `+acquired+` AND books.book_type IN (`+typeMarks+`)) WHERE depth <= ? ORDER BY depth, id DESC`, arguments...)
	if err != nil {
		return nil, Classify(err)
	}
	defer rows.Close()
	copies := []WorkCopy{}
	for rows.Next() {
		var found WorkCopy
		book, err := scanBook(rows, &found.WorkID)
		if err != nil {
			return nil, Classify(err)
		}
		found.Book = book
		copies = append(copies, found)
	}
	if err := rows.Err(); err != nil {
		return nil, Classify(err)
	}
	return copies, nil
}

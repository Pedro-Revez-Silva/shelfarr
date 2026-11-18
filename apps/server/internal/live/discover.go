package live

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"

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
	limit, err := d.IntegerSetting(ctx, "open_library_search_limit", 20)
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
	WorkID   string
	BookID   int64
	BookType int
}

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
	rows, err := d.read.QueryContext(ctx, `SELECT books.open_library_work_id, books.book_type, MAX(books.id) FROM books WHERE books.open_library_work_id IN (`+strings.Join(workMarks, ",")+`) AND `+acquired+` AND books.book_type IN (`+typeMarks+`) GROUP BY books.open_library_work_id, books.book_type ORDER BY books.open_library_work_id, books.book_type`, arguments...)
	if err != nil {
		return nil, Classify(err)
	}
	defer rows.Close()
	copies := []WorkCopy{}
	for rows.Next() {
		var found WorkCopy
		if err := rows.Scan(&found.WorkID, &found.BookType, &found.BookID); err != nil {
			return nil, Classify(err)
		}
		copies = append(copies, found)
	}
	if err := rows.Err(); err != nil {
		return nil, Classify(err)
	}
	return copies, nil
}

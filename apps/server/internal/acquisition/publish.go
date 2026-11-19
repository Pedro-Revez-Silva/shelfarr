package acquisition

import (
	"context"
	"database/sql"
	"errors"
	"strconv"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/fault"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/gutenberg"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/wfstore"
)

type Outcome string

const (
	Candidates       Outcome = "candidates"
	NoResults        Outcome = "no_results"
	RetriesExhausted Outcome = "retries_exhausted"
	Failed           Outcome = "failed"
	Released         Outcome = "released"

	CodeConfigurationChanged  = "configuration-changed"
	CodeUnsupportedCandidates = "unsupported-candidates"

	selectionMessage = "Search results found. Please review and select a result to download."
	failureMessage   = "Search failed before any source returned results."
	gutenbergSource  = "gutenberg"
	gutenbergIndexer = "Project Gutenberg"
	rejectedStatus   = 2
	warnLevel        = 1
	activeDownloads  = "0, 1, 2"
	manualSources    = "'manual_magnet', 'manual_nzb'"
)

type Publication struct {
	Outcome   Outcome
	Code      string
	Written   int
	Preserved int
	Removed   int
}

func PublishCandidates(ctx context.Context, store *wfstore.Store, claim Claim, candidates []gutenberg.Candidate, now time.Time) (Publication, error) {
	return publish(ctx, store, claim, now, func(tx *sql.Tx, owned ownedRequest, stamp string) (Publication, error) {
		if err := clearStoreOffers(ctx, tx, claim.RequestID); err != nil {
			return Publication{}, err
		}
		publication, err := saveCandidates(ctx, tx, claim.RequestID, candidates, stamp)
		if err != nil {
			return Publication{}, err
		}
		publication.Outcome = Candidates
		return publication, attention(ctx, tx, owned, selectionMessage, stamp, "")
	})
}

func PublishNoResults(ctx context.Context, store *wfstore.Store, claim Claim, now time.Time) (Publication, error) {
	return publish(ctx, store, claim, now, func(tx *sql.Tx, owned ownedRequest, stamp string) (Publication, error) {
		if err := clearStoreOffers(ctx, tx, claim.RequestID); err != nil {
			return Publication{}, err
		}
		if owned.retryCount >= owned.config.MaxRetries {
			message := "Maximum retry attempts (" + strconv.FormatInt(owned.config.MaxRetries, 10) + ") exceeded. Manual intervention required."
			return Publication{Outcome: RetriesExhausted}, attention(ctx, tx, owned, message, stamp, "status = 2, retry_count = retry_count + 1, ")
		}
		next := wfstore.FormatTimestamp(retryAt(now, owned.retryCount, owned.config))
		_, err := tx.ExecContext(ctx, `UPDATE requests SET retry_count = retry_count + 1, status = ?, next_retry_at = ?, search_claimed_at = NULL, updated_at = ? WHERE id = ?`,
			notFoundStatus, next, stamp, claim.RequestID)
		return Publication{Outcome: NoResults}, err
	})
}

func PublishFailure(ctx context.Context, store *wfstore.Store, claim Claim, code string, now time.Time) (Publication, error) {
	return publish(ctx, store, claim, now, func(tx *sql.Tx, owned ownedRequest, stamp string) (Publication, error) {
		return Publication{Outcome: Failed, Code: code}, attention(ctx, tx, owned, failureMessage, stamp, "")
	})
}

func Release(ctx context.Context, store *wfstore.Store, claim Claim, code string, now time.Time) (Publication, error) {
	err := store.Transact(ctx, func(tx *sql.Tx) error {
		return release(ctx, tx, claim, wfstore.FormatTimestamp(now))
	})
	if err != nil {
		return Publication{}, err
	}
	return Publication{Outcome: Released, Code: code}, nil
}

func release(ctx context.Context, tx *sql.Tx, claim Claim, stamp string) error {
	result, err := tx.ExecContext(ctx, `UPDATE requests SET status = ?, search_generation = search_generation + 1, search_claimed_at = NULL,
		attention_needed = 0, issue_description = NULL, updated_at = ? WHERE id = ? AND status = ? AND search_generation = ?`,
		pendingStatus, stamp, claim.RequestID, searchingStatus, claim.Generation)
	if err != nil {
		return err
	}
	if changed, err := result.RowsAffected(); err != nil || changed != 1 {
		return ErrSuperseded
	}
	return nil
}

type ownedRequest struct {
	requestID  int64
	userID     int64
	title      string
	retryCount int64
	config     Config
}

func publish(ctx context.Context, store *wfstore.Store, claim Claim, now time.Time, write func(tx *sql.Tx, owned ownedRequest, stamp string) (Publication, error)) (Publication, error) {
	var publication Publication
	err := store.Transact(ctx, func(tx *sql.Tx) error {
		stamp := wfstore.FormatTimestamp(now)
		row, err := ownedRow(ctx, tx, claim)
		if err != nil {
			return err
		}
		_, config, err := eligible(ctx, tx, claim.RequestID)
		if err != nil && Refusal(err) == nil {
			return err
		}
		if err != nil || !config.sameSearch(claim.Config) {
			publication = Publication{Outcome: Released, Code: CodeConfigurationChanged}
			return release(ctx, tx, claim, stamp)
		}
		owned := ownedRequest{requestID: claim.RequestID, userID: row.userID, title: row.title.String, retryCount: row.retryCount.Int64, config: config}
		if publication, err = write(tx, owned, stamp); err != nil {
			return err
		}
		return fault.Hit(ctx, "search.before-commit")
	})
	if err != nil {
		return Publication{}, err
	}
	return publication, nil
}

func ownedRow(ctx context.Context, tx *sql.Tx, claim Claim) (requestRow, error) {
	if _, err := tx.ExecContext(ctx, `UPDATE requests SET search_generation = search_generation WHERE id = ?`, claim.RequestID); err != nil {
		return requestRow{}, err
	}
	row, err := readRequest(ctx, tx, claim.RequestID)
	if errors.Is(err, ErrRequestMissing) {
		return requestRow{}, ErrSuperseded
	}
	if err != nil {
		return requestRow{}, err
	}
	if row.status != searchingStatus || row.generation != claim.Generation {
		return requestRow{}, ErrSuperseded
	}
	return row, nil
}

func retryAt(now time.Time, retryCount int64, config Config) time.Time {
	hours := config.RetryMaxDays * 24
	switch {
	case config.RetryBaseHours == 0:
		hours = 0
	case retryCount < 62 && config.RetryBaseHours <= hours>>retryCount:
		hours = config.RetryBaseHours << retryCount
	}
	return now.Add(time.Duration(hours%24)*time.Hour).AddDate(0, 0, int(hours/24))
}

func clearStoreOffers(ctx context.Context, tx *sql.Tx, requestID int64) error {
	if _, err := tx.ExecContext(ctx, `DELETE FROM store_offers WHERE request_id = ?`, requestID); err != nil {
		return err
	}
	_, err := tx.ExecContext(ctx, `DELETE FROM request_events WHERE request_id = ? AND event_type = 'store_offers_found' AND source = 'store_provider'`, requestID)
	return err
}

func attention(ctx context.Context, tx *sql.Tx, owned ownedRequest, message, stamp, transition string) error {
	if _, err := tx.ExecContext(ctx, `UPDATE requests SET `+transition+`attention_needed = 1, issue_description = ?, search_claimed_at = NULL, updated_at = ? WHERE id = ?`,
		message, stamp, owned.requestID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO request_events (request_id, download_id, event_type, source, message, level, details, user_visible, created_at, updated_at)
		VALUES (?, NULL, 'attention_flagged', 'request', ?, ?, '{}', 0, ?, ?)`, owned.requestID, message, warnLevel, stamp, stamp); err != nil {
		return err
	}
	_, err := tx.ExecContext(ctx, `INSERT INTO notifications (user_id, notifiable_type, notifiable_id, notification_type, title, message, created_at, updated_at)
		VALUES (?, 'Request', ?, 'request_attention', 'Attention Needed', ?, ?, ?)`, owned.userID, owned.requestID, `"`+owned.title+`" needs your attention.`, stamp, stamp)
	return err
}

func saveCandidates(ctx context.Context, tx *sql.Tx, requestID int64, candidates []gutenberg.Candidate, stamp string) (Publication, error) {
	blocklisted, err := blocklistedGUIDs(ctx, tx, requestID)
	if err != nil {
		return Publication{}, err
	}
	removable := `FROM search_results WHERE request_id = ? AND source NOT IN (` + manualSources + `) AND blocklisted_at IS NULL
		AND id NOT IN (SELECT search_result_id FROM downloads WHERE request_id = ? AND status IN (` + activeDownloads + `) AND search_result_id IS NOT NULL)`
	if _, err := tx.ExecContext(ctx, `UPDATE downloads SET search_result_id = NULL WHERE search_result_id IN (SELECT id `+removable+`)`, requestID, requestID); err != nil {
		return Publication{}, err
	}
	removed, err := tx.ExecContext(ctx, `DELETE `+removable, requestID, requestID)
	if err != nil {
		return Publication{}, err
	}
	var publication Publication
	count, _ := removed.RowsAffected()
	publication.Removed = int(count)
	saved := map[string]bool{}
	for _, candidate := range candidates {
		if saved[candidate.GUID()] {
			continue
		}
		saved[candidate.GUID()] = true
		var existingID int64
		var status int64
		err := tx.QueryRowContext(ctx, `SELECT id, status FROM search_results WHERE request_id = ? AND guid = ?`, requestID, candidate.GUID()).Scan(&existingID, &status)
		switch {
		case errors.Is(err, sql.ErrNoRows):
			if _, err := tx.ExecContext(ctx, `INSERT INTO search_results (request_id, guid, title, indexer, size_bytes, seeders, leechers, download_url, magnet_url, info_url,
				published_at, source, detected_language, status, provider_payload, created_at, updated_at)
				VALUES (?, ?, ?, ?, NULL, NULL, NULL, ?, NULL, ?, NULL, ?, ?, 0, '{}', ?, ?)`,
				requestID, candidate.GUID(), candidate.ResultTitle(), gutenbergIndexer, candidate.DownloadURL, candidate.InfoURL, gutenbergSource,
				nullable(candidate.Language), stamp, stamp); err != nil {
				return Publication{}, err
			}
			publication.Written++
			continue
		case err != nil:
			return Publication{}, err
		}
		publication.Preserved++
		if blocklisted[candidate.GUID()] && status != rejectedStatus {
			if _, err := tx.ExecContext(ctx, `UPDATE search_results SET status = ?, updated_at = ? WHERE id = ?`, rejectedStatus, stamp, existingID); err != nil {
				return Publication{}, err
			}
		}
	}
	return publication, nil
}

func blocklistedGUIDs(ctx context.Context, tx *sql.Tx, requestID int64) (map[string]bool, error) {
	rows, err := tx.QueryContext(ctx, `SELECT guid FROM search_results WHERE request_id = ? AND source NOT IN (`+manualSources+`) AND blocklisted_at IS NOT NULL`, requestID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	found := map[string]bool{}
	for rows.Next() {
		var guid string
		if err := rows.Scan(&guid); err != nil {
			return nil, err
		}
		found[guid] = true
	}
	return found, rows.Err()
}

func nullable(text string) any {
	if text == "" {
		return nil
	}
	return text
}

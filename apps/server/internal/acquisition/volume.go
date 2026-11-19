package acquisition

import (
	"context"
	"database/sql"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/wfstore"
)

const maxListedCandidates = 50

func VolumeLibraryRoot(ctx context.Context, store *wfstore.Store) (string, error) {
	var root string
	err := store.Transact(ctx, func(tx *sql.Tx) error {
		if err := verifySchema(ctx, tx); err != nil {
			return err
		}
		if err := verifyColumns(ctx, tx, selectionColumns); err != nil {
			return err
		}
		if _, err := loadConfig(ctx, tx); err != nil {
			return err
		}
		var custom int64
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM acquisition_providers WHERE enabled = 1 AND supports_ebooks = 1`).Scan(&custom); err != nil {
			return err
		}
		if custom > 0 {
			return ErrOtherSources
		}
		stored, err := readSettings(ctx, tx)
		if err != nil {
			return err
		}
		root, err = libraryRoot(stored)
		return err
	})
	return root, err
}

type Candidate struct {
	ResultID int64
	Title    string
}

func SelectableCandidates(ctx context.Context, store *wfstore.Store, requestID int64) ([]Candidate, error) {
	var candidates []Candidate
	err := store.Transact(ctx, func(tx *sql.Tx) error {
		rows, err := tx.QueryContext(ctx, `SELECT id FROM search_results WHERE request_id = ? AND status = ? AND blocklisted_at IS NULL AND source = ?
			ORDER BY id LIMIT ?`, requestID, pendingResult, gutenbergSource, maxListedCandidates)
		if err != nil {
			return err
		}
		var ids []int64
		for rows.Next() {
			var id int64
			if err := rows.Scan(&id); err != nil {
				rows.Close()
				return err
			}
			ids = append(ids, id)
		}
		if err := rows.Close(); err != nil {
			return err
		}
		for _, id := range ids {
			plan, err := planIn(ctx, tx, requestID, id)
			if SelectionRefusal(err) != nil {
				continue
			}
			if err != nil {
				return err
			}
			if plan.Completed == 0 {
				candidates = append(candidates, Candidate{ResultID: id, Title: plan.Selection.ResultTitle.String})
			}
		}
		return nil
	})
	return candidates, err
}

func RequeueDue(ctx context.Context, store *wfstore.Store, requestID int64, now time.Time) (bool, error) {
	var requeued bool
	err := store.Transact(ctx, func(tx *sql.Tx) error {
		stamp := wfstore.FormatTimestamp(now)
		var due int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM requests WHERE id = ? AND status = ? AND next_retry_at IS NOT NULL AND next_retry_at <= ?`,
			requestID, notFoundStatus, stamp).Scan(&due); err != nil || due == 0 {
			return err
		}
		if _, _, err := eligible(ctx, tx, requestID); err != nil {
			return err
		}
		result, err := tx.ExecContext(ctx, `UPDATE requests SET status = ?, search_generation = search_generation + 1, search_claimed_at = NULL,
			attention_needed = 0, issue_description = NULL, next_retry_at = NULL, updated_at = ?
			WHERE id = ? AND status = ? AND next_retry_at IS NOT NULL AND next_retry_at <= ?`, pendingStatus, stamp, requestID, notFoundStatus, stamp)
		if err != nil {
			return err
		}
		changed, err := result.RowsAffected()
		requeued = changed == 1
		return err
	})
	return requeued, err
}

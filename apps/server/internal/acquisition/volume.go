package acquisition

import (
	"context"
	"database/sql"

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

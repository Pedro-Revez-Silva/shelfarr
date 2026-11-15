package inventory

import (
	"context"
	"database/sql"
	"errors"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/fault"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/wfstore"
)

const upsertStaged = `
INSERT INTO library_items (library_platform, library_id, audiobookshelf_id, title, subtitle, author, narrator, series, series_position, publisher, language, description, isbn, asin, published_year, missing, synced_at, created_at, updated_at)
SELECT ?, s.library_id, s.audiobookshelf_id, s.title, s.subtitle, s.author, s.narrator, s.series, s.series_position, s.publisher, s.language, s.description, s.isbn, s.asin, s.published_year, s.missing, ?, ?, ?
FROM wf_inventory_stage s WHERE s.run_id = ? AND s.library_id = ?
ON CONFLICT (library_platform, library_id, audiobookshelf_id) DO UPDATE SET
  title = excluded.title, subtitle = excluded.subtitle, author = excluded.author, narrator = excluded.narrator,
  series = excluded.series, series_position = excluded.series_position, publisher = excluded.publisher,
  language = excluded.language, description = excluded.description, isbn = excluded.isbn, asin = excluded.asin,
  published_year = excluded.published_year, missing = excluded.missing, synced_at = excluded.synced_at, updated_at = excluded.updated_at
WHERE library_items.synced_at IS NULL OR library_items.synced_at <= excluded.synced_at`

const pruneUnseen = `
DELETE FROM library_items
WHERE library_platform = ? AND library_id = ? AND (synced_at IS NULL OR synced_at <= ?)
  AND audiobookshelf_id NOT IN (SELECT audiobookshelf_id FROM wf_inventory_stage WHERE run_id = ? AND library_id = ?)`

const pruneOutOfScope = `
DELETE FROM library_items
WHERE library_platform = ? AND (synced_at IS NULL OR synced_at <= ?)
  AND library_id NOT IN (SELECT library_id FROM wf_inventory_libraries WHERE run_id = ?)`

func (w *Workflow) publish(ctx context.Context, active run) (string, error) {
	outcome := OutcomePublished
	err := w.Owner.Write(ctx, func(tx *sql.Tx) error {
		if err := w.requireActive(ctx, tx, active); err != nil {
			return err
		}
		rows, err := tx.QueryContext(ctx, `SELECT library_id, state FROM wf_inventory_libraries WHERE run_id = ?`, active.ID)
		if err != nil {
			return err
		}
		var libraries []library
		for rows.Next() {
			var entry library
			if err := rows.Scan(&entry.ID, &entry.State); err != nil {
				rows.Close()
				return err
			}
			libraries = append(libraries, entry)
		}
		if err := rows.Close(); err != nil {
			return err
		}
		var summary summary
		for _, entry := range libraries {
			switch entry.State {
			case "pending":
				return errNotReady
			case "failed":
				summary.Failed++
			case "empty":
				summary.Empty++
			case "staged":
				summary.Staged++
			}
		}
		if summary.Staged+summary.Empty == 0 {
			outcome = OutcomeAllFailed
			summary.Outcome = outcome
			return w.closeRunIn(ctx, tx, active.ID, "abandoned", summary)
		}
		platform := PlatformAudiobookshelf
		written := wfstore.FormatTimestamp(w.now())
		for _, entry := range libraries {
			if entry.State != "staged" && entry.State != "empty" {
				continue
			}
			if entry.State == "staged" {
				result, err := tx.ExecContext(ctx, upsertStaged, platform, active.SnapshotAt, written, written, active.ID, entry.ID)
				if err != nil {
					return err
				}
				changed, _ := result.RowsAffected()
				summary.Upserted += changed
			}
			result, err := tx.ExecContext(ctx, pruneUnseen, platform, entry.ID, active.SnapshotAt, active.ID, entry.ID)
			if err != nil {
				return err
			}
			removed, _ := result.RowsAffected()
			summary.Pruned += removed
		}
		if summary.Failed == 0 {
			result, err := tx.ExecContext(ctx, pruneOutOfScope, platform, active.SnapshotAt, active.ID)
			if err != nil {
				return err
			}
			summary.OutOfScope, _ = result.RowsAffected()
		}
		if err := fault.Hit(ctx, "inventory.publish-in-transaction"); err != nil {
			return err
		}
		summary.Outcome = outcome
		return w.closeRunIn(ctx, tx, active.ID, "published", summary)
	})
	if errors.Is(err, errConfigChanged) {
		return OutcomeConfigChanged, w.closeRun(ctx, active, "abandoned", OutcomeConfigChanged)
	}
	if errors.Is(err, errRunClosed) {
		return OutcomeInterrupted, nil
	}
	return outcome, err
}

var errNotReady = errors.New("libraries are still pending")

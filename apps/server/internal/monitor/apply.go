package monitor

import (
	"context"
	"database/sql"
	"encoding/json"
	"strconv"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/fault"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/qbit"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/wfstore"
)

const (
	ownedBy = `id = ? AND request_id = ? AND external_id = ? AND download_client_id IS ? AND search_result_id IS ?`

	selectedRelease = `(search_result_id IS NULL OR EXISTS (SELECT 1 FROM search_results sr WHERE sr.id = downloads.search_result_id AND sr.status = 1))`
)

func (c candidate) ownerArguments() []any {
	var client, release any
	if c.ClientRef.Valid {
		client = c.ClientRef.String
	}
	if c.SearchResultID.Valid {
		release = c.SearchResultID.Int64
	}
	return []any{c.ID, c.RequestID, c.ExternalID, client, release}
}

func (w *Workflow) recordState(ctx context.Context, entry candidate, errorCode, blockedCode string, keepBlocked bool) error {
	return w.Owner.Write(ctx, func(tx *sql.Tx) error {
		return w.recordStateIn(ctx, tx, entry, errorCode, blockedCode, keepBlocked)
	})
}

func (w *Workflow) stillOwned(ctx context.Context, tx *sql.Tx, entry candidate, requireSelected bool) (bool, error) {
	query := `SELECT COUNT(*) FROM downloads WHERE id = ? AND request_id = ? AND COALESCE(external_id, '') = ? AND download_client_id IS ? AND search_result_id IS ? AND status IN (0, 1)`
	if requireSelected {
		query += ` AND ` + selectedRelease
	}
	var count int
	err := tx.QueryRowContext(ctx, query, entry.ownerArguments()...).Scan(&count)
	return count == 1, err
}

func (w *Workflow) recordStateIn(ctx context.Context, tx *sql.Tx, entry candidate, errorCode, blockedCode string, keepBlocked bool) error {
	if owned, err := w.stillOwned(ctx, tx, entry, false); err != nil || !owned {
		return err
	}
	var errorValue, blockedValue any
	if errorCode != "" {
		errorValue = errorCode
	}
	if blockedCode != "" {
		blockedValue = blockedCode
	}
	blockedUpdate := `excluded.blocked_code`
	if keepBlocked {
		blockedUpdate = `CASE WHEN wf_download_state.token = excluded.token THEN wf_download_state.blocked_code ELSE NULL END`
	}
	_, err := tx.ExecContext(ctx, `
INSERT INTO wf_download_state (download_id, token, observed_at, error_code, blocked_code) VALUES (?, ?, ?, ?, ?)
ON CONFLICT (download_id) DO UPDATE SET observed_at = excluded.observed_at, error_code = excluded.error_code, blocked_code = `+blockedUpdate+`, token = excluded.token`,
		entry.ID, entry.token(), wfstore.FormatTimestamp(w.now()), errorValue, blockedValue)
	return err
}

func (w *Workflow) applyProgress(ctx context.Context, entry candidate, torrent *qbit.Torrent, result verdict) (verdict, error) {
	blocked := ""
	if torrent.State == qbit.Failed {
		blocked = BlockedClientFailure
		result.blocked = true
	}
	progressed, stale := false, false
	err := w.Owner.Write(ctx, func(tx *sql.Tx) error {
		progressed, stale = false, false
		owned, err := w.stillOwned(ctx, tx, entry, true)
		if err != nil {
			return err
		}
		if !owned {
			stale = true
			return nil
		}
		stamp := wfstore.FormatTimestamp(w.now())
		arguments := append([]any{torrent.Progress, stamp}, entry.ownerArguments()...)
		arguments = append(arguments, torrent.Progress)
		changed, err := tx.ExecContext(ctx, `UPDATE downloads SET progress = ?, not_found_count = 0, updated_at = ? WHERE `+ownedBy+` AND status IN (0, 1) AND (progress IS NOT ? OR not_found_count <> 0)`, arguments...)
		if err != nil {
			return err
		}
		count, _ := changed.RowsAffected()
		progressed = count == 1
		return w.recordStateIn(ctx, tx, entry, "", blocked, false)
	})
	result.progressed = err == nil && progressed
	if err == nil && stale {
		result.stale, result.blocked = true, false
	}
	return result, err
}

func (w *Workflow) applyNotFound(ctx context.Context, entry candidate, result verdict) (verdict, error) {
	counted, escalated, stale := false, false, false
	err := w.Owner.Write(ctx, func(tx *sql.Tx) error {
		counted, escalated, stale = false, false, false
		arguments := append([]any{wfstore.FormatTimestamp(w.now())}, entry.ownerArguments()...)
		changed, err := tx.ExecContext(ctx, `UPDATE downloads SET not_found_count = not_found_count + 1, updated_at = ? WHERE `+ownedBy+` AND status = 1 AND not_found_count < `+strconv.Itoa(NotFoundThreshold)+` AND `+selectedRelease, arguments...)
		if err != nil {
			return err
		}
		if count, _ := changed.RowsAffected(); count != 1 {
			stale = true
			return nil
		}
		counted = true
		var count int
		if err := tx.QueryRowContext(ctx, `SELECT not_found_count FROM downloads WHERE id = ?`, entry.ID).Scan(&count); err != nil {
			return err
		}
		blocked := ""
		if count >= NotFoundThreshold {
			blocked = BlockedNotFound
			escalated = true
		}
		return w.recordStateIn(ctx, tx, entry, "", blocked, false)
	})
	if err == nil {
		result.notFound, result.blocked, result.stale = counted, escalated, stale
	}
	return result, err
}

func (w *Workflow) applyCompletion(ctx context.Context, entry candidate, torrent *qbit.Torrent, result verdict) (verdict, error) {
	completed, stale := false, false
	err := w.Owner.Write(ctx, func(tx *sql.Tx) error {
		completed, stale = false, false
		now := wfstore.FormatTimestamp(w.now())
		var path any
		if torrent.Path != "" {
			path = torrent.Path
		}
		arguments := append([]any{path, now}, entry.ownerArguments()...)
		claimed, err := tx.ExecContext(ctx, `UPDATE downloads SET status = 3, progress = 100, not_found_count = 0, download_path = ?, updated_at = ? WHERE `+ownedBy+` AND status = 1 AND `+selectedRelease, arguments...)
		if err != nil {
			return err
		}
		if count, _ := claimed.RowsAffected(); count != 1 {
			stale = true
			return nil
		}
		if err := fault.Hit(ctx, "monitor.completion-claimed"); err != nil {
			return err
		}
		details, err := json.Marshal(map[string]string{"download_path": torrent.Path})
		if err != nil {
			return err
		}
		if torrent.Path == "" {
			details = []byte("{}")
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO request_events (request_id, download_id, event_type, source, message, level, details, user_visible, created_at, updated_at) VALUES (?, ?, 'completed', ?, 'Download completed in client', 0, ?, 0, ?, ?)`,
			entry.RequestID, entry.ID, eventSource, string(details), now, now); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO wf_postprocess_handoffs (download_id, request_id, idempotency_key, download_path, state, next_attempt_at, created_at) VALUES (?, ?, ?, ?, 'pending', ?, ?)`,
			entry.ID, entry.RequestID, handoffKey(entry.ID), path, now, now); err != nil {
			return err
		}
		if err := w.recordStateIn(ctx, tx, entry, "", "", false); err != nil {
			return err
		}
		if err := fault.Hit(ctx, "monitor.completion-before-commit"); err != nil {
			return err
		}
		completed = true
		return nil
	})
	result.completed, result.stale = err == nil && completed, err == nil && stale
	if result.completed {
		w.report("downloads.completed", map[string]any{"download": entry.ID})
		if hit := fault.Hit(ctx, "monitor.completion-committed"); hit != nil {
			return result, hit
		}
	}
	return result, err
}

func handoffKey(downloadID int64) string {
	return "shelfarr-download-completed-" + strconv.FormatInt(downloadID, 10)
}

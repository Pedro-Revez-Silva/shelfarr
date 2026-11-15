package monitor

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/fault"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/netguard"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/wfstore"
)

const (
	deliveryBatch    = 20
	maxReplyBytes    = 64 << 10
	maxBackoffFactor = 8
)

type handoff struct {
	ID         int64
	DownloadID int64
	RequestID  int64
	Key        string
	Path       sql.NullString
	Attempts   int
}

type DeliveryResult struct {
	Pending   int
	Delivered int
	Failed    int
}

func (w *Workflow) Deliver(ctx context.Context) (DeliveryResult, error) {
	pending, err := w.pending(ctx)
	if err != nil {
		return DeliveryResult{}, err
	}
	result := DeliveryResult{Pending: len(pending)}
	if w.HandoffURL == "" {
		return result, nil
	}
	timeout := w.HandoffTimeout
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	client := netguard.NewClient(timeout)
	for _, entry := range pending {
		if ctx.Err() != nil {
			return result, ctx.Err()
		}
		code := w.post(ctx, client, entry)
		if code == "" {
			if err := fault.Hit(ctx, "handoff.consumer-replied"); err != nil {
				return result, err
			}
			if err := w.markDelivered(ctx, entry); err != nil {
				return result, err
			}
			result.Delivered++
			w.report("downloads.handoff", map[string]any{"handoff": entry.ID, "outcome": "delivered"})
			continue
		}
		if ctx.Err() != nil {
			return result, ctx.Err()
		}
		if err := w.markFailed(ctx, entry, code); err != nil {
			return result, err
		}
		result.Failed++
		w.report("downloads.handoff", map[string]any{"handoff": entry.ID, "outcome": "failed", "code": code})
	}
	return result, nil
}

func (w *Workflow) pending(ctx context.Context) ([]handoff, error) {
	rows, err := w.Owner.Store().DB().QueryContext(ctx, `SELECT id, download_id, request_id, idempotency_key, download_path, attempts FROM wf_postprocess_handoffs WHERE state = 'pending' AND next_attempt_at <= ? ORDER BY id LIMIT ?`, wfstore.FormatTimestamp(w.now()), deliveryBatch)
	if err != nil {
		return nil, wfstore.Wrap(err)
	}
	defer rows.Close()
	var found []handoff
	for rows.Next() {
		var entry handoff
		if err := rows.Scan(&entry.ID, &entry.DownloadID, &entry.RequestID, &entry.Key, &entry.Path, &entry.Attempts); err != nil {
			return nil, wfstore.Wrap(err)
		}
		found = append(found, entry)
	}
	return found, wfstore.Wrap(rows.Err())
}

func (w *Workflow) post(ctx context.Context, client *http.Client, entry handoff) string {
	body, err := json.Marshal(map[string]any{
		"handoff_id":    entry.ID,
		"download_id":   entry.DownloadID,
		"request_id":    entry.RequestID,
		"event":         "download-completed",
		"download_path": entry.Path.String,
	})
	if err != nil {
		return "encode"
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, w.HandoffURL, bytes.NewReader(body))
	if err != nil {
		return "config"
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Idempotency-Key", entry.Key)
	response, err := client.Do(request)
	if err != nil {
		return "connection"
	}
	defer response.Body.Close()
	if _, err := netguard.ReadLimited(ctx, response.Body, maxReplyBytes); err != nil {
		return "connection"
	}
	if response.StatusCode < 200 || response.StatusCode > 299 {
		return "http-status"
	}
	return ""
}

func (w *Workflow) markDelivered(ctx context.Context, entry handoff) error {
	return w.Owner.Write(ctx, func(tx *sql.Tx) error {
		_, err := tx.ExecContext(ctx, `UPDATE wf_postprocess_handoffs SET state = 'delivered', attempts = attempts + 1, last_error_code = NULL, delivered_at = ? WHERE id = ? AND state = 'pending'`, wfstore.FormatTimestamp(w.now()), entry.ID)
		return err
	})
}

func (w *Workflow) markFailed(ctx context.Context, entry handoff, code string) error {
	factor := min(1<<entry.Attempts, maxBackoffFactor)
	next := w.now().Add(time.Duration(factor) * w.HandoffBackoff)
	return w.Owner.Write(ctx, func(tx *sql.Tx) error {
		_, err := tx.ExecContext(ctx, `UPDATE wf_postprocess_handoffs SET attempts = attempts + 1, last_error_code = ?, next_attempt_at = ? WHERE id = ? AND state = 'pending'`, code, wfstore.FormatTimestamp(next), entry.ID)
		return err
	})
}

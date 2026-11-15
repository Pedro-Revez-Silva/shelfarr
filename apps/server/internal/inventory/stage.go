package inventory

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/abs"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/wfstore"
)

func (w *Workflow) discover(ctx context.Context, client *abs.Client, config Config) ([]string, string) {
	if len(config.ExplicitIDs) > 0 {
		return config.ExplicitIDs, ""
	}
	libraries, err := client.Libraries(ctx)
	if err != nil {
		return nil, abs.CodeOf(err)
	}
	var ids []string
	for _, entry := range libraries {
		if entry.MediaType == "book" {
			ids = append(ids, entry.ID)
		}
	}
	return ids, ""
}

func (w *Workflow) registerLibraries(ctx context.Context, active run, ids []string) error {
	return w.Owner.Write(ctx, func(tx *sql.Tx) error {
		if err := w.requireActive(ctx, tx, active); err != nil {
			return err
		}
		for _, id := range ids {
			if _, err := tx.ExecContext(ctx, `INSERT OR IGNORE INTO wf_inventory_libraries (run_id, library_id, state) VALUES (?, ?, 'pending')`, active.ID, id); err != nil {
				return err
			}
		}
		return nil
	})
}

var errRunClosed = errors.New("run is no longer active")

func (w *Workflow) requireActive(ctx context.Context, tx *sql.Tx, active run) error {
	var state string
	if err := tx.QueryRowContext(ctx, `SELECT state FROM wf_inventory_runs WHERE id = ?`, active.ID).Scan(&state); err != nil {
		return err
	}
	if state != "fetching" {
		return errRunClosed
	}
	schedule, err := wfstore.ReadSchedule(ctx, tx, Domain)
	if err != nil {
		return err
	}
	if schedule.State != "enabled" || schedule.CancelEpoch != active.CancelEpoch {
		return context.Canceled
	}
	config, err := LoadConfig(ctx, tx)
	if err != nil {
		return err
	}
	if config.Fingerprint() != active.Fingerprint {
		return errConfigChanged
	}
	return nil
}

var errConfigChanged = errors.New("configuration changed")

func (w *Workflow) stage(ctx context.Context, active run, libraryID string, inventory abs.Inventory, fetchErr error) error {
	err := w.Owner.Write(ctx, func(tx *sql.Tx) error {
		if err := w.requireActive(ctx, tx, active); err != nil {
			return err
		}
		switch {
		case fetchErr != nil:
			_, err := tx.ExecContext(ctx, `UPDATE wf_inventory_libraries SET state = 'failed', error_code = ? WHERE run_id = ? AND library_id = ?`, abs.CodeOf(fetchErr), active.ID, libraryID)
			return err
		case inventory.Empty:
			_, err := tx.ExecContext(ctx, `UPDATE wf_inventory_libraries SET state = 'empty', item_count = 0 WHERE run_id = ? AND library_id = ?`, active.ID, libraryID)
			return err
		}
		if _, err := tx.ExecContext(ctx, `DELETE FROM wf_inventory_stage WHERE run_id = ? AND library_id = ?`, active.ID, libraryID); err != nil {
			return err
		}
		insert, err := tx.PrepareContext(ctx, `INSERT INTO wf_inventory_stage (run_id, library_id, audiobookshelf_id, title, subtitle, author, narrator, series, series_position, publisher, language, description, isbn, asin, published_year, missing) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
		if err != nil {
			return err
		}
		defer insert.Close()
		for _, item := range inventory.Items {
			if _, err := insert.ExecContext(ctx, active.ID, libraryID, item.ID, nullable(item.Title), nullable(item.Subtitle), nullable(item.Author), nullable(item.Narrator), nullable(item.Series), nullable(item.SeriesNumber), nullable(item.Publisher), nullable(item.Language), nullable(item.Description), nullable(item.ISBN), nullable(item.ASIN), nullableInt(item.PublishedYear), boolInt(item.Missing)); err != nil {
				return err
			}
		}
		_, err = tx.ExecContext(ctx, `UPDATE wf_inventory_libraries SET state = 'staged', item_count = ? WHERE run_id = ? AND library_id = ?`, len(inventory.Items), active.ID, libraryID)
		return err
	})
	return w.settle(ctx, active, err)
}

func (w *Workflow) settle(ctx context.Context, active run, err error) error {
	switch {
	case errors.Is(err, errConfigChanged):
		return w.closeRun(ctx, active, "abandoned", OutcomeConfigChanged)
	case errors.Is(err, errRunClosed):
		return nil
	}
	return err
}

func nullable(text *string) any {
	if text == nil {
		return nil
	}
	return *text
}

func nullableInt(number *int64) any {
	if number == nil {
		return nil
	}
	return *number
}

func boolInt(flag bool) int {
	if flag {
		return 1
	}
	return 0
}

func (w *Workflow) closeRun(ctx context.Context, active run, state, outcome string) error {
	return w.Owner.Write(ctx, func(tx *sql.Tx) error {
		return w.closeRunIn(ctx, tx, active.ID, state, summary{Outcome: outcome})
	})
}

type summary struct {
	Outcome    string `json:"outcome"`
	Upserted   int64  `json:"upserted,omitempty"`
	Pruned     int64  `json:"pruned,omitempty"`
	OutOfScope int64  `json:"out_of_scope_pruned,omitempty"`
	Staged     int    `json:"staged,omitempty"`
	Empty      int    `json:"empty,omitempty"`
	Failed     int    `json:"failed,omitempty"`
}

func (w *Workflow) closeRunIn(ctx context.Context, tx *sql.Tx, runID int64, state string, outcome summary) error {
	encoded, err := json.Marshal(outcome)
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM wf_inventory_stage WHERE run_id = ?`, runID); err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `UPDATE wf_inventory_runs SET state = ?, outcome = ?, finished_at = ? WHERE id = ? AND state = 'fetching'`, state, string(encoded), wfstore.FormatTimestamp(w.now()), runID)
	return err
}

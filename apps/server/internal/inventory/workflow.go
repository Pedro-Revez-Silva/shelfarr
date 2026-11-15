package inventory

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/abs"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/fault"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/wfstore"
)

const (
	Domain   = "inventory"
	stageRow = 500
)

const (
	OutcomeIdle                = "idle"
	OutcomeNotDue              = "not-due"
	OutcomeScheduleCancelled   = "schedule-cancelled"
	OutcomeNotConfigured       = "not-configured"
	OutcomePlatformUnsupported = "platform-unsupported"
	OutcomeIntervalDisabled    = "interval-disabled"
	OutcomePublished           = "published"
	OutcomeCancelled           = "cancelled"
	OutcomeConfigChanged       = "configuration-changed"
	OutcomeNoLibraries         = "no-libraries"
	OutcomeAllFailed           = "all-libraries-failed"
	OutcomeDiscoveryFailed     = "discovery-failed"
	OutcomeInterrupted         = "interrupted"
	CodeFetchDeadline          = "deadline"
)

type Event func(name string, fields map[string]any)

type Workflow struct {
	Owner         *wfstore.Owner
	Now           func() time.Time
	ABS           abs.Config
	CancelPoll    time.Duration
	FetchDeadline time.Duration
	Report        Event
}

type Result struct {
	Outcome string
	RunID   int64
}

type run struct {
	ID          int64
	Fingerprint string
	SnapshotAt  string
	CancelEpoch int64
}

type library struct {
	ID    string
	State string
}

func (w *Workflow) now() time.Time {
	if w.Now != nil {
		return w.Now()
	}
	return time.Now()
}

func (w *Workflow) report(name string, fields map[string]any) {
	if w.Report != nil {
		w.Report(name, fields)
	}
}

func (w *Workflow) Pass(ctx context.Context) (Result, error) {
	active, err := w.activeRun(ctx)
	if err != nil {
		return Result{}, err
	}
	if active == nil {
		admitted, outcome, err := w.admit(ctx)
		if err != nil {
			return Result{}, err
		}
		if admitted == nil {
			return Result{Outcome: outcome}, nil
		}
		active = admitted
		w.report("inventory.admitted", map[string]any{"run": active.ID})
		if err := fault.Hit(ctx, "inventory.admitted"); err != nil {
			return Result{RunID: active.ID}, err
		}
	}
	return w.drive(ctx, *active)
}

func (w *Workflow) activeRun(ctx context.Context) (*run, error) {
	var found run
	err := w.Owner.Store().DB().QueryRowContext(ctx, `SELECT id, scope_fingerprint, snapshot_at, cancel_epoch FROM wf_inventory_runs WHERE state = 'fetching'`).Scan(&found.ID, &found.Fingerprint, &found.SnapshotAt, &found.CancelEpoch)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, wfstore.Wrap(err)
	}
	return &found, nil
}

func (w *Workflow) admit(ctx context.Context) (*run, string, error) {
	var admitted *run
	outcome := OutcomeIdle
	err := w.Owner.Write(ctx, func(tx *sql.Tx) error {
		now := w.now()
		schedule, err := wfstore.ReadSchedule(ctx, tx, Domain)
		if err != nil {
			return err
		}
		switch {
		case schedule.State != "enabled":
			outcome = OutcomeScheduleCancelled
			return nil
		case schedule.NextDueAt > wfstore.FormatTimestamp(now):
			outcome = OutcomeNotDue
			return nil
		}
		config, err := LoadConfig(ctx, tx)
		if err != nil {
			return err
		}
		next := now.Add(config.Interval)
		switch {
		case !config.Configured():
			outcome = OutcomeNotConfigured
		case config.Platform != PlatformAudiobookshelf:
			outcome = OutcomePlatformUnsupported
		case config.Interval <= 0:
			outcome = OutcomeIntervalDisabled
		}
		if outcome != OutcomeIdle {
			next = now.Add(minimumInterval)
		}
		consumed, err := w.Owner.ConsumeSlot(ctx, tx, Domain, schedule.ControlSeq, now, next, ifEmpty(outcome, "admitted"))
		if err != nil || !consumed || outcome != OutcomeIdle {
			return err
		}
		result, err := tx.ExecContext(ctx, `INSERT INTO wf_inventory_runs (generation, cancel_epoch, platform, scope_fingerprint, snapshot_at, state, admitted_at) VALUES (?, ?, ?, ?, ?, 'fetching', ?)`,
			w.Owner.Generation, schedule.CancelEpoch, config.Platform, config.Fingerprint(), wfstore.FormatTimestamp(now), wfstore.FormatTimestamp(now))
		if err != nil {
			return err
		}
		id, err := result.LastInsertId()
		if err != nil {
			return err
		}
		admitted = &run{ID: id, Fingerprint: config.Fingerprint(), SnapshotAt: wfstore.FormatTimestamp(now), CancelEpoch: schedule.CancelEpoch}
		return nil
	})
	return admitted, outcome, err
}

func ifEmpty(value, fallback string) string {
	if value == OutcomeIdle {
		return fallback
	}
	return value
}

func (w *Workflow) drive(ctx context.Context, active run) (Result, error) {
	result := Result{RunID: active.ID, Outcome: OutcomeInterrupted}
	passCtx, stop := context.WithCancel(ctx)
	defer stop()
	go w.watchCancellation(passCtx, active, stop)

	finish := func(outcome string, err error) (Result, error) {
		result.Outcome = outcome
		if err != nil && ctx.Err() == nil && errors.Is(err, context.Canceled) {
			return w.concludeCancellation(ctx, active, result)
		}
		return result, err
	}

	if cancelled, err := w.cancelRequested(passCtx, active); err != nil {
		return finish(OutcomeInterrupted, err)
	} else if cancelled {
		return finish(OutcomeInterrupted, context.Canceled)
	}
	config, err := LoadConfig(passCtx, w.Owner.Store().DB())
	if err != nil {
		return finish(OutcomeInterrupted, err)
	}
	if config.Fingerprint() != active.Fingerprint {
		return finish(OutcomeConfigChanged, w.closeRun(ctx, active, "abandoned", OutcomeConfigChanged))
	}
	apiConfig := w.ABS
	apiConfig.BaseURL, apiConfig.APIKey = config.URL, config.APIKey
	client, err := abs.NewClient(apiConfig)
	if err != nil {
		return finish(OutcomeDiscoveryFailed, w.closeRun(ctx, active, "abandoned", OutcomeDiscoveryFailed+":"+abs.CodeOf(err)))
	}

	libraries, err := w.libraries(passCtx, active.ID)
	if err != nil {
		return finish(OutcomeInterrupted, err)
	}
	if len(libraries) == 0 {
		ids, code := w.discover(passCtx, client, config)
		if code != "" {
			if passCtx.Err() != nil {
				return finish(OutcomeInterrupted, passCtx.Err())
			}
			return finish(OutcomeDiscoveryFailed, w.closeRun(ctx, active, "abandoned", OutcomeDiscoveryFailed+":"+code))
		}
		if len(ids) == 0 {
			return finish(OutcomeNoLibraries, w.closeRun(ctx, active, "abandoned", OutcomeNoLibraries))
		}
		if err := w.registerLibraries(passCtx, active, ids); err != nil {
			return finish(OutcomeInterrupted, err)
		}
		if libraries, err = w.libraries(passCtx, active.ID); err != nil {
			return finish(OutcomeInterrupted, err)
		}
	}

	for index, entry := range libraries {
		if entry.State != "pending" {
			continue
		}
		if err := passCtx.Err(); err != nil {
			return finish(OutcomeInterrupted, err)
		}
		inventory, fetchErr := w.fetch(passCtx, client, entry.ID)
		if fetchErr != nil && passCtx.Err() != nil {
			return finish(OutcomeInterrupted, passCtx.Err())
		}
		if err := fault.Hit(passCtx, "inventory.library-fetched"); err != nil {
			return finish(OutcomeInterrupted, err)
		}
		if err := w.stage(passCtx, active, entry.ID, inventory, fetchErr); err != nil {
			return finish(OutcomeInterrupted, err)
		}
		w.report("inventory.library", map[string]any{"run": active.ID, "ordinal": index, "code": stageCode(inventory, fetchErr)})
		if err := fault.Hit(passCtx, "inventory.library-staged"); err != nil {
			return finish(OutcomeInterrupted, err)
		}
	}

	if err := fault.Hit(passCtx, "inventory.before-publish"); err != nil {
		return finish(OutcomeInterrupted, err)
	}
	outcome, err := w.publish(passCtx, active)
	if err != nil {
		return finish(OutcomeInterrupted, err)
	}
	w.report("inventory.finished", map[string]any{"run": active.ID, "outcome": outcome})
	if err := fault.Hit(passCtx, "inventory.published"); err != nil {
		return finish(outcome, err)
	}
	return finish(outcome, nil)
}

func (w *Workflow) fetch(ctx context.Context, client *abs.Client, libraryID string) (abs.Inventory, error) {
	deadline := w.FetchDeadline
	if deadline <= 0 {
		deadline = 2 * time.Minute
	}
	fetchCtx, cancel := context.WithTimeout(ctx, deadline)
	defer cancel()
	inventory, err := client.LibraryInventory(fetchCtx, libraryID)
	if err != nil && ctx.Err() == nil && fetchCtx.Err() != nil {
		return abs.Inventory{}, &abs.Error{Code: CodeFetchDeadline}
	}
	return inventory, err
}

func stageCode(inventory abs.Inventory, err error) string {
	switch {
	case err != nil:
		return abs.CodeOf(err)
	case inventory.Empty:
		return "empty"
	}
	return "complete"
}

func (w *Workflow) watchCancellation(ctx context.Context, active run, stop context.CancelFunc) {
	interval := w.CancelPoll
	if interval <= 0 {
		interval = 250 * time.Millisecond
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if cancelled, err := w.cancelRequested(ctx, active); err == nil && cancelled {
				stop()
				return
			}
		}
	}
}

func (w *Workflow) concludeCancellation(ctx context.Context, active run, result Result) (Result, error) {
	cancelled, err := w.cancelRequested(ctx, active)
	if err != nil {
		return result, err
	}
	if !cancelled {
		result.Outcome = OutcomeInterrupted
		return result, nil
	}
	result.Outcome = OutcomeCancelled
	return result, w.closeRun(ctx, active, "cancelled", OutcomeCancelled)
}

func (w *Workflow) cancelRequested(ctx context.Context, active run) (bool, error) {
	schedule, err := wfstore.ReadSchedule(ctx, w.Owner.Store().DB(), Domain)
	if err != nil {
		return false, wfstore.Wrap(err)
	}
	return schedule.State != "enabled" || schedule.CancelEpoch != active.CancelEpoch, nil
}

func (w *Workflow) libraries(ctx context.Context, runID int64) ([]library, error) {
	rows, err := w.Owner.Store().DB().QueryContext(ctx, `SELECT library_id, state FROM wf_inventory_libraries WHERE run_id = ? ORDER BY library_id`, runID)
	if err != nil {
		return nil, wfstore.Wrap(err)
	}
	defer rows.Close()
	var libraries []library
	for rows.Next() {
		var entry library
		if err := rows.Scan(&entry.ID, &entry.State); err != nil {
			return nil, wfstore.Wrap(err)
		}
		libraries = append(libraries, entry)
	}
	return libraries, wfstore.Wrap(rows.Err())
}

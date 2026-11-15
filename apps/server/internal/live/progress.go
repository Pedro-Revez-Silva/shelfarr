package live

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/checkpoint"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/fault"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/strictjson"
)

type ProgressOutcome int

const (
	ProgressApplied ProgressOutcome = iota
	ProgressReplayed
	ProgressConflict
)

type ProgressResult struct {
	Outcome  ProgressOutcome
	Progress *store.Progress
}

const progressColumns = `asset_id, CAST(locator AS TEXT), position_seconds, version, CAST(observed_at AS TEXT), CAST(updated_at AS TEXT), client_mutation_id`

func scanProgress(row interface{ Scan(...any) error }) (store.Progress, error) {
	var progress store.Progress
	err := row.Scan(&progress.AssetID, &progress.Locator, &progress.PositionSeconds, &progress.Version, &progress.ObservedAt, &progress.UpdatedAt, &progress.ClientMutationID)
	return progress, err
}

func (d *DB) SaveProgress(ctx context.Context, userID, bookID int64, write checkpoint.Write, clock func() time.Time) (ProgressResult, error) {
	tx, err := d.write.BeginTx(ctx, nil)
	if err != nil {
		return ProgressResult{}, Classify(err)
	}
	defer tx.Rollback()
	if err := fault.Hit(ctx, "progress.locked"); err != nil {
		return ProgressResult{}, err
	}
	result, err := saveIn(ctx, tx, userID, bookID, write, clock())
	if err != nil {
		return ProgressResult{}, classifyWrite(err)
	}
	if result.Outcome != ProgressApplied {
		return result, nil
	}
	if err := fault.Hit(ctx, "progress.before-commit"); err != nil {
		return ProgressResult{}, err
	}
	if err := tx.Commit(); err != nil {
		return ProgressResult{}, Classify(err)
	}
	if err := fault.Hit(ctx, "progress.committed"); err != nil {
		return ProgressResult{}, err
	}
	return result, nil
}

func classifyWrite(err error) error {
	if errors.Is(err, store.ErrUnsupported) || errors.Is(err, store.ErrTimestamp) {
		return err
	}
	return Classify(err)
}

func saveIn(ctx context.Context, tx *sql.Tx, userID, bookID int64, write checkpoint.Write, now time.Time) (ProgressResult, error) {
	var rowID int64
	var current store.Progress
	err := tx.QueryRowContext(ctx, `SELECT id, `+progressColumns+` FROM consumer_progresses WHERE user_id = ? AND book_id = ? ORDER BY id LIMIT 1`, userID, bookID).
		Scan(&rowID, &current.AssetID, &current.Locator, &current.PositionSeconds, &current.Version, &current.ObservedAt, &current.UpdatedAt, &current.ClientMutationID)
	if errors.Is(err, sql.ErrNoRows) {
		return insertProgress(ctx, tx, userID, bookID, write, now)
	}
	if err != nil {
		return ProgressResult{}, err
	}
	if current.ClientMutationID == write.MutationID {
		same, err := sameCheckpoint(current, write)
		if err != nil {
			return ProgressResult{}, err
		}
		if same {
			return ProgressResult{Outcome: ProgressReplayed, Progress: &current}, nil
		}
		return ProgressResult{Outcome: ProgressConflict, Progress: &current}, nil
	}
	if current.Version != write.ExpectedVersion {
		return ProgressResult{Outcome: ProgressConflict, Progress: &current}, nil
	}
	if !write.Resolve {
		allowed, err := chronological(current, write)
		if err != nil {
			return ProgressResult{}, err
		}
		if !allowed {
			return ProgressResult{Outcome: ProgressConflict, Progress: &current}, nil
		}
	}
	return updateProgress(ctx, tx, rowID, current, write, now)
}

func insertProgress(ctx context.Context, tx *sql.Tx, userID, bookID int64, write checkpoint.Write, now time.Time) (ProgressResult, error) {
	if write.ExpectedVersion != 0 {
		return ProgressResult{Outcome: ProgressConflict}, nil
	}
	stamp := TimestampText(now)
	inserted, err := tx.ExecContext(ctx,
		`INSERT INTO consumer_progresses (user_id, book_id, asset_id, locator, position_seconds, version, client_mutation_id, created_at, updated_at, observed_at) VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?, ?)`,
		userID, bookID, write.AssetID, nullableText(write.LocatorText), nullableFloat(write.PositionSeconds), write.MutationID, stamp, stamp, observedText(write.ObservedAt))
	if err != nil {
		return ProgressResult{}, err
	}
	id, err := inserted.LastInsertId()
	if err != nil {
		return ProgressResult{}, err
	}
	return storedResult(ctx, tx, id)
}

func updateProgress(ctx context.Context, tx *sql.Tx, rowID int64, current store.Progress, write checkpoint.Write, now time.Time) (ProgressResult, error) {
	updated, err := tx.ExecContext(ctx,
		`UPDATE consumer_progresses SET asset_id = ?, locator = ?, position_seconds = ?, version = ?, client_mutation_id = ?, observed_at = ?, updated_at = ? WHERE id = ? AND version = ?`,
		write.AssetID, nullableText(write.LocatorText), nullableFloat(write.PositionSeconds), current.Version+1, write.MutationID, observedText(write.ObservedAt), TimestampText(now), rowID, current.Version)
	if err != nil {
		return ProgressResult{}, err
	}
	if count, err := updated.RowsAffected(); err != nil || count != 1 {
		return ProgressResult{}, errors.Join(err, errProgressRaced)
	}
	return storedResult(ctx, tx, rowID)
}

var errProgressRaced = errors.New("progress changed under the write lock")

func storedResult(ctx context.Context, tx *sql.Tx, rowID int64) (ProgressResult, error) {
	stored, err := scanProgress(tx.QueryRowContext(ctx, `SELECT `+progressColumns+` FROM consumer_progresses WHERE id = ?`, rowID))
	if err != nil {
		return ProgressResult{}, err
	}
	return ProgressResult{Outcome: ProgressApplied, Progress: &stored}, nil
}

func nullableText(text *string) any {
	if text == nil {
		return nil
	}
	return *text
}

func nullableFloat(value *float64) any {
	if value == nil {
		return nil
	}
	return *value
}

func observedText(moment *time.Time) any {
	if moment == nil {
		return nil
	}
	return TimestampText(*moment)
}

func samePlace(current store.Progress, write checkpoint.Write) (bool, error) {
	if current.AssetID != write.AssetID {
		return false, nil
	}
	if current.PositionSeconds.Valid != (write.PositionSeconds != nil) || current.PositionSeconds.Valid && current.PositionSeconds.Float64 != *write.PositionSeconds {
		return false, nil
	}
	if current.Locator.Valid != (write.Locator != nil) {
		return false, nil
	}
	if !current.Locator.Valid {
		return true, nil
	}
	stored, err := strictjson.Parse([]byte(current.Locator.String))
	if err != nil {
		return false, store.ErrUnsupported
	}
	return strictjson.Equal(stored, *write.Locator), nil
}

func storedObservation(current store.Progress) (*time.Time, error) {
	if !current.ObservedAt.Valid {
		return nil, nil
	}
	moment, err := store.ParseTimestamp(current.ObservedAt.String)
	if err != nil {
		return nil, err
	}
	return &moment, nil
}

func sameCheckpoint(current store.Progress, write checkpoint.Write) (bool, error) {
	place, err := samePlace(current, write)
	if err != nil || !place {
		return false, err
	}
	return sameObservation(current, write)
}

func sameObservation(current store.Progress, write checkpoint.Write) (bool, error) {
	stored, err := storedObservation(current)
	if err != nil {
		return false, err
	}
	if stored == nil || write.ObservedAt == nil {
		return stored == nil && write.ObservedAt == nil, nil
	}
	return stored.Equal(*write.ObservedAt), nil
}

func chronological(current store.Progress, write checkpoint.Write) (bool, error) {
	stored, err := storedObservation(current)
	if err != nil {
		return false, err
	}
	if stored == nil || write.ObservedAt == nil || write.ObservedAt.After(*stored) {
		return true, nil
	}
	if !write.ObservedAt.Equal(*stored) {
		return false, nil
	}
	return samePlace(current, write)
}

func (d *DB) SetReadingStatus(ctx context.Context, userID, bookID int64, status int, clock func() time.Time) error {
	tx, err := d.write.BeginTx(ctx, nil)
	if err != nil {
		return Classify(err)
	}
	defer tx.Rollback()
	if err := fault.Hit(ctx, "status.locked"); err != nil {
		return err
	}
	now := TimestampText(clock())
	var rowID int64
	var existing int
	err = tx.QueryRowContext(ctx, `SELECT id, status FROM consumer_reading_states WHERE user_id = ? AND book_id = ? ORDER BY id LIMIT 1`, userID, bookID).Scan(&rowID, &existing)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		_, err = tx.ExecContext(ctx, `INSERT INTO consumer_reading_states (user_id, book_id, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?)`, userID, bookID, status, now, now)
	case err == nil && existing != status:
		_, err = tx.ExecContext(ctx, `UPDATE consumer_reading_states SET status = ?, updated_at = ? WHERE id = ?`, status, now, rowID)
	}
	if err != nil {
		return Classify(err)
	}
	if err := tx.Commit(); err != nil {
		return Classify(err)
	}
	return fault.Hit(ctx, "status.committed")
}

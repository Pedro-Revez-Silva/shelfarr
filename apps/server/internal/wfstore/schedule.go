package wfstore

import (
	"context"
	"database/sql"
	"time"
)

type Querier interface {
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

type Schedule struct {
	Workflow    string
	State       string
	NextDueAt   string
	ControlSeq  int64
	LastOutcome string
}

func ReadSchedule(ctx context.Context, q Querier, workflow string) (Schedule, error) {
	var schedule Schedule
	var outcome sql.NullString
	err := q.QueryRowContext(ctx, `SELECT workflow, state, next_due_at, control_seq, last_outcome FROM wf_schedule WHERE workflow = ?`, workflow).
		Scan(&schedule.Workflow, &schedule.State, &schedule.NextDueAt, &schedule.ControlSeq, &outcome)
	schedule.LastOutcome = outcome.String
	return schedule, err
}

func (s *Store) Schedule(ctx context.Context, workflow string) (Schedule, error) {
	schedule, err := ReadSchedule(ctx, s.db, workflow)
	if err != nil {
		return Schedule{}, classify(err)
	}
	return schedule, nil
}

func (s *Store) control(ctx context.Context, statement string, arguments ...any) error {
	return s.transact(ctx, func(tx *sql.Tx) error {
		_, err := tx.ExecContext(ctx, statement, arguments...)
		return err
	})
}

func (s *Store) Trigger(ctx context.Context, workflow string, now time.Time) error {
	if !validDomain(workflow) {
		return Fail(CodeUsage, nil)
	}
	stamp := FormatTimestamp(now)
	return s.control(ctx, `UPDATE wf_schedule SET next_due_at = ?, control_seq = control_seq + 1 WHERE workflow = ? AND state = 'enabled' AND next_due_at > ?`, stamp, workflow, stamp)
}

func (s *Store) Cancel(ctx context.Context, workflow string) error {
	if !validDomain(workflow) {
		return Fail(CodeUsage, nil)
	}
	return s.control(ctx, `UPDATE wf_schedule SET state = 'cancelled', control_seq = control_seq + 1 WHERE workflow = ? AND state <> 'cancelled'`, workflow)
}

func (s *Store) Resume(ctx context.Context, workflow string, now time.Time) error {
	if !validDomain(workflow) {
		return Fail(CodeUsage, nil)
	}
	return s.control(ctx, `UPDATE wf_schedule SET state = 'enabled', next_due_at = ?, control_seq = control_seq + 1 WHERE workflow = ? AND state <> 'enabled'`, FormatTimestamp(now), workflow)
}

func (o *Owner) ConsumeSlot(ctx context.Context, tx *sql.Tx, workflow string, controlSeq int64, now time.Time, next time.Time, outcome string) (bool, error) {
	result, err := tx.ExecContext(ctx, `UPDATE wf_schedule SET next_due_at = ?, last_outcome = ? WHERE workflow = ? AND state = 'enabled' AND next_due_at <= ? AND control_seq = ?`, FormatTimestamp(next), outcome, workflow, FormatTimestamp(now), controlSeq)
	if err != nil {
		return false, err
	}
	changed, err := result.RowsAffected()
	return changed == 1, err
}

func (o *Owner) RecordOutcome(ctx context.Context, workflow, outcome string) error {
	return o.Write(ctx, func(tx *sql.Tx) error {
		_, err := tx.ExecContext(ctx, `UPDATE wf_schedule SET last_outcome = ? WHERE workflow = ?`, outcome, workflow)
		return err
	})
}

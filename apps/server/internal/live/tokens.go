package live

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
)

var errAdoptionConflict = errors.New("token changed during adoption")

func TimestampText(moment time.Time) string {
	utc := moment.UTC()
	text := utc.Format("2006-01-02 15:04:05")
	if microseconds := utc.Nanosecond() / 1000; microseconds > 0 {
		text += fmt.Sprintf(".%06d", microseconds)
	}
	return text
}

func (d *DB) TouchToken(ctx context.Context, id int64, now time.Time) error {
	stamp := TimestampText(now)
	_, err := d.write.ExecContext(ctx, `UPDATE api_tokens SET last_used_at = ?, updated_at = ? WHERE id = ?`, stamp, stamp, id)
	return Classify(err)
}

type tokenState struct {
	revoked  sql.NullString
	expires  sql.NullString
	replaces sql.NullInt64
	user     sql.NullInt64
}

func (s tokenState) usable(now time.Time) (bool, error) {
	if s.revoked.Valid {
		return false, nil
	}
	if !s.expires.Valid {
		return true, nil
	}
	expiry, err := store.ParseTimestamp(s.expires.String)
	if err != nil {
		return false, err
	}
	return expiry.After(now), nil
}

func readState(ctx context.Context, tx *sql.Tx, id int64) (tokenState, bool, error) {
	var state tokenState
	err := tx.QueryRowContext(ctx, `SELECT CAST(revoked_at AS TEXT), CAST(expires_at AS TEXT), replaces_api_token_id, user_id FROM api_tokens WHERE id = ?`, id).Scan(&state.revoked, &state.expires, &state.replaces, &state.user)
	if errors.Is(err, sql.ErrNoRows) {
		return tokenState{}, false, nil
	}
	return state, err == nil, err
}

func (d *DB) RetireReplaced(ctx context.Context, token Token, now time.Time) (bool, error) {
	tx, err := d.write.BeginTx(ctx, nil)
	if err != nil {
		return false, Classify(err)
	}
	defer tx.Rollback()
	adopted, err := retireIn(ctx, tx, token, now)
	if errors.Is(err, errAdoptionConflict) {
		return false, nil
	}
	if err != nil {
		return false, Classify(err)
	}
	if err := tx.Commit(); err != nil {
		return false, Classify(err)
	}
	return adopted, nil
}

func retireIn(ctx context.Context, tx *sql.Tx, token Token, now time.Time) (bool, error) {
	if !token.ReplacesID.Valid {
		return true, nil
	}
	previousID := token.ReplacesID.Int64
	previous, found, err := readState(ctx, tx, previousID)
	if err != nil || !found || previous.user != token.UserID {
		return false, err
	}
	current, found, err := readState(ctx, tx, token.ID)
	if err != nil || !found {
		return false, err
	}
	if usable, err := current.usable(now); err != nil || !usable {
		return false, err
	}
	if !current.replaces.Valid {
		return true, nil
	}
	if current.replaces.Int64 != previousID {
		return false, nil
	}
	if usable, err := previous.usable(now); err != nil || !usable {
		return false, err
	}
	stamp := TimestampText(now)
	revoked, err := tx.ExecContext(ctx, `UPDATE api_tokens SET revoked_at = ?, updated_at = ? WHERE id = ? AND revoked_at IS NULL`, stamp, stamp, previousID)
	if err != nil {
		return false, err
	}
	if count, _ := revoked.RowsAffected(); count != 1 {
		return false, errAdoptionConflict
	}
	adopted, err := tx.ExecContext(ctx, `UPDATE api_tokens SET replaces_api_token_id = NULL, updated_at = ? WHERE id = ? AND replaces_api_token_id = ?`, stamp, token.ID, previousID)
	if err != nil {
		return false, err
	}
	if count, _ := adopted.RowsAffected(); count != 1 {
		return false, errAdoptionConflict
	}
	return true, nil
}

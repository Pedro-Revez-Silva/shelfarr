package wfstore

import (
	"context"
	"database/sql"
	"errors"
)

func Setting(ctx context.Context, q Querier, key string) (string, error) {
	var value sql.NullString
	err := q.QueryRowContext(ctx, `SELECT value FROM settings WHERE key = ?`, key).Scan(&value)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return value.String, err
}

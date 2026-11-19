package live

import (
	"context"
	"database/sql"
	"errors"
)

var HealthServices = []string{"indexer", "download_client", "download_paths", "output_paths", "audiobookshelf", "hardcover"}

var HealthStatuses = map[int64]string{0: "healthy", 1: "degraded", 2: "down", 3: "not_configured"}

const unreadableHealthStatus = -1

type ServerCounts struct {
	Users             int
	Books             int
	ActiveRequests    int
	AttentionRequests int
}

type HealthRow struct {
	Service   string
	Saved     bool
	Status    int64
	CheckedAt sql.NullString
}

type ServerOverview struct {
	Counts ServerCounts
	Health []HealthRow
}

var serverCountQueries = []string{
	`SELECT COUNT(*) FROM users WHERE deleted_at IS NULL`,
	`SELECT COUNT(*) FROM books`,
	`SELECT COUNT(*) FROM requests WHERE status IN (` + activeRequestStatuses + `)`,
	`SELECT COUNT(*) FROM requests WHERE attention_needed = 1`,
}

func (d *DB) ServerOverview(ctx context.Context, authorise func(context.Context, *sql.Tx) error) (ServerOverview, error) {
	tx, err := d.read.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return ServerOverview{}, Classify(err)
	}
	defer tx.Rollback()
	if err := authorise(ctx, tx); err != nil {
		return ServerOverview{}, err
	}
	var overview ServerOverview
	counts := []*int{&overview.Counts.Users, &overview.Counts.Books, &overview.Counts.ActiveRequests, &overview.Counts.AttentionRequests}
	for index, query := range serverCountQueries {
		if err := tx.QueryRowContext(ctx, query).Scan(counts[index]); err != nil {
			return ServerOverview{}, Classify(err)
		}
	}
	for _, service := range HealthServices {
		row := HealthRow{Service: service}
		err := tx.QueryRowContext(ctx, `SELECT CASE WHEN typeof(status) = 'integer' THEN status ELSE ? END, CAST(last_check_at AS TEXT) FROM system_healths WHERE service = ? ORDER BY id DESC LIMIT 1`,
			unreadableHealthStatus, service).Scan(&row.Status, &row.CheckedAt)
		switch {
		case err == nil:
			row.Saved = true
		case !errors.Is(err, sql.ErrNoRows):
			return ServerOverview{}, Classify(err)
		}
		overview.Health = append(overview.Health, row)
	}
	return overview, nil
}

func UserIsAdminIn(ctx context.Context, tx *sql.Tx, userID int64) (bool, error) {
	var role sql.NullInt64
	err := tx.QueryRowContext(ctx, `SELECT CASE WHEN typeof(role) = 'integer' THEN role END FROM users WHERE id = ? AND deleted_at IS NULL`, userID).Scan(&role)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, Classify(err)
	}
	return role.Valid && role.Int64 == 1, nil
}

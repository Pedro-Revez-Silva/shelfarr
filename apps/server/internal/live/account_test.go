package live

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/livetest"
)

func accountFixture(t *testing.T) (*DB, string, SessionRow) {
	t.Helper()
	path := livetest.Create(t)
	livetest.Exec(t, path, `INSERT INTO users (id, username, name, password_digest) VALUES (1, 'ada', 'Ada', 'stored-digest')`)
	livetest.Exec(t, path, `INSERT INTO sessions (id, user_id, created_at, updated_at) VALUES (5, 1, '2026-11-01 12:00:00.250000', '2026-11-01 12:00:00.250000')`)
	livetest.Exec(t, path, `INSERT INTO sessions (id, user_id, created_at, updated_at) VALUES (6, 1, '2026-11-01 12:00:00', '2026-11-01 12:00:00')`)
	created := time.Date(2026, 11, 1, 12, 0, 0, 250000000, time.UTC)
	return open(t, path), path, SessionRow{ID: 5, UserID: 1, CreatedAt: created}
}

func fixedClock(moment time.Time) func() time.Time { return func() time.Time { return moment } }

func TestAccountWritesRefuseASessionThatExpiredBeforeTheWriteLock(t *testing.T) {
	database, path, session := accountFixture(t)
	edge := session.CreatedAt.Add(30 * 24 * time.Hour)
	checked := PasswordSnapshot{Digest: "stored-digest"}
	if _, err := database.ChangePassword(context.Background(), session, checked, "new-digest", fixedClock(edge.Add(time.Microsecond))); !errors.Is(err, ErrSessionEnded) {
		t.Fatalf("an expired session changed the password: %v", err)
	}
	if _, err := database.UpdateName(context.Background(), session, "Expired", fixedClock(edge.Add(time.Microsecond))); !errors.Is(err, ErrSessionEnded) {
		t.Fatalf("an expired session changed the name: %v", err)
	}
	rows := livetest.Query(t, path, `SELECT name, password_digest, (SELECT COUNT(*) FROM sessions) FROM users WHERE id = 1`)
	if rows[0][0] != "Ada" || rows[0][1] != "stored-digest" || rows[0][2].(int64) != 2 {
		t.Fatalf("an expired session wrote %v", rows[0])
	}
	livetest.Exec(t, path, `INSERT INTO settings (key, value, value_type) VALUES ('session_max_age_days', '40', 'integer')`)
	if _, err := database.UpdateName(context.Background(), session, "Kept", fixedClock(edge.Add(time.Hour))); err != nil {
		t.Fatalf("the configured lifetime was not used: %v", err)
	}
	if _, err := database.ChangePassword(context.Background(), session, checked, "new-digest", fixedClock(edge)); err != nil {
		t.Fatalf("the boundary instant is still valid in Rails: %v", err)
	}
	livetest.Exec(t, path, `UPDATE settings SET value = 'x' WHERE key = 'session_max_age_days'`)
	if _, err := database.UpdateName(context.Background(), session, "Unsupported", fixedClock(edge)); err == nil {
		t.Fatal("an unreadable lifetime setting was guessed")
	}
}

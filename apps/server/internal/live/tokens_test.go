package live

import (
	"context"
	"database/sql"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/livetest"
)

var instant = time.Date(2026, 11, 15, 9, 30, 15, 123_456_789, time.UTC)

func TestTimestampTextFollowsActiveRecordQuoting(t *testing.T) {
	cases := map[time.Time]string{
		instant:                   "2026-11-15 09:30:15.123456",
		instant.Add(-123_456_789): "2026-11-15 09:30:15",
		instant.Add(-123_456_000): "2026-11-15 09:30:15.000000" + "",
		time.Date(2026, 1, 2, 3, 4, 5, 7_000, time.FixedZone("x", 3600)): "2026-01-02 02:04:05.000007",
	}
	delete(cases, instant.Add(-123_456_000))
	for moment, want := range cases {
		if got := TimestampText(moment); got != want {
			t.Errorf("%v: got %q want %q", moment, got, want)
		}
	}
}

func fixed(moment time.Time) func() time.Time { return func() time.Time { return moment } }

type tokenFixture struct {
	path     string
	database *DB
}

func newTokens(t *testing.T) tokenFixture {
	t.Helper()
	path := livetest.Create(t)
	livetest.Exec(t, path, `INSERT INTO users (id, username) VALUES (1, 'alice'), (2, 'bob')`)
	return tokenFixture{path: path, database: open(t, path)}
}

func (f tokenFixture) token(t *testing.T, id int64, user any, replaces any, extra string) {
	t.Helper()
	livetest.Exec(t, f.path, `INSERT INTO api_tokens (id, user_id, token_digest, replaces_api_token_id) VALUES (?, ?, ?, ?)`, id, user, "digest-"+string(rune('a'+id)), replaces)
	if extra != "" {
		livetest.Exec(t, f.path, `UPDATE api_tokens SET `+extra+` WHERE id = ?`, id)
	}
}

type tokenSnapshot struct {
	revoked, replaces, updated, used any
}

func (f tokenFixture) snapshot(t *testing.T, id int64) tokenSnapshot {
	t.Helper()
	row := livetest.Query(t, f.path, `SELECT CAST(revoked_at AS TEXT), replaces_api_token_id, CAST(updated_at AS TEXT), CAST(last_used_at AS TEXT) FROM api_tokens WHERE id = ?`, id)[0]
	return tokenSnapshot{row[0], row[1], row[2], row[3]}
}

func (f tokenFixture) lookup(t *testing.T, id int64) Token {
	t.Helper()
	var token Token
	token.ID = id
	row := livetest.Query(t, f.path, `SELECT user_id, replaces_api_token_id FROM api_tokens WHERE id = ?`, id)[0]
	if value, ok := row[0].(int64); ok {
		token.UserID = sql.NullInt64{Int64: value, Valid: true}
	}
	if value, ok := row[1].(int64); ok {
		token.ReplacesID = sql.NullInt64{Int64: value, Valid: true}
	}
	return token
}

func TestAdoptionRevokesThePreviousTokenAndClearsThePointerAtomically(t *testing.T) {
	f := newTokens(t)
	f.token(t, 1, 1, nil, "")
	f.token(t, 2, 1, 1, "")
	adopted, err := f.database.RetireReplaced(context.Background(), f.lookup(t, 2), fixed(instant))
	if err != nil || !adopted {
		t.Fatalf("%v %v", adopted, err)
	}
	if previous := f.snapshot(t, 1); previous.revoked != "2026-11-15 09:30:15.123456" || previous.updated != "2026-11-15 09:30:15.123456" {
		t.Fatalf("previous token: %+v", previous)
	}
	if current := f.snapshot(t, 2); current.replaces != nil || current.updated != "2026-11-15 09:30:15.123456" {
		t.Fatalf("adopting token: %+v", current)
	}
}

func TestAdoptionIsRefusedWithoutChangingAnything(t *testing.T) {
	cases := map[string]func(f tokenFixture, t *testing.T){
		"previous revoked": func(f tokenFixture, t *testing.T) {
			f.token(t, 1, 1, nil, "revoked_at = '2026-11-01 00:00:00'")
			f.token(t, 2, 1, 1, "")
		},
		"previous expired": func(f tokenFixture, t *testing.T) {
			f.token(t, 1, 1, nil, "expires_at = '2020-01-01 00:00:00'")
			f.token(t, 2, 1, 1, "")
		},
		"other owner":      func(f tokenFixture, t *testing.T) { f.token(t, 1, 2, nil, ""); f.token(t, 2, 1, 1, "") },
		"ownerless parent": func(f tokenFixture, t *testing.T) { f.token(t, 1, nil, nil, ""); f.token(t, 2, 1, 1, "") },
		"dangling parent":  func(f tokenFixture, t *testing.T) { f.token(t, 2, 1, 99, "") },
		"self revoked": func(f tokenFixture, t *testing.T) {
			f.token(t, 1, 1, nil, "")
			f.token(t, 2, 1, 1, "revoked_at = '2026-11-01 00:00:00'")
		},
		"self expired": func(f tokenFixture, t *testing.T) {
			f.token(t, 1, 1, nil, "")
			f.token(t, 2, 1, 1, "expires_at = '2020-01-01 00:00:00'")
		},
	}
	for name, arrange := range cases {
		t.Run(name, func(t *testing.T) {
			f := newTokens(t)
			arrange(f, t)
			before := [2]tokenSnapshot{}
			for index, id := range []int64{1, 2} {
				if len(livetest.Query(t, f.path, `SELECT 1 FROM api_tokens WHERE id = ?`, id)) > 0 {
					before[index] = f.snapshot(t, id)
				}
			}
			adopted, err := f.database.RetireReplaced(context.Background(), f.lookup(t, 2), fixed(instant))
			if err != nil || adopted {
				t.Fatalf("adopted=%v err=%v", adopted, err)
			}
			for index, id := range []int64{1, 2} {
				if len(livetest.Query(t, f.path, `SELECT 1 FROM api_tokens WHERE id = ?`, id)) > 0 && f.snapshot(t, id) != before[index] {
					t.Fatalf("token %d changed", id)
				}
			}
		})
	}
}

func TestAdoptionRollsBackTheRevocationWhenTheSecondWriteFails(t *testing.T) {
	f := newTokens(t)
	f.token(t, 1, 1, nil, "")
	f.token(t, 2, 1, 1, "")
	livetest.Exec(t, f.path, `CREATE TRIGGER refuse_pointer_clear BEFORE UPDATE OF replaces_api_token_id ON api_tokens WHEN NEW.replaces_api_token_id IS NULL BEGIN SELECT RAISE(ABORT, 'refused'); END`)
	before := f.snapshot(t, 1)
	if adopted, err := f.database.RetireReplaced(context.Background(), f.lookup(t, 2), fixed(instant)); err == nil || adopted {
		t.Fatalf("adopted=%v err=%v", adopted, err)
	}
	if f.snapshot(t, 1) != before {
		t.Fatal("the previous token stayed revoked after a failed adoption")
	}
}

func TestConcurrentAdoptionsRevokeThePreviousTokenOnce(t *testing.T) {
	f := newTokens(t)
	f.token(t, 1, 1, nil, "")
	f.token(t, 2, 1, 1, "")
	token := f.lookup(t, 2)
	var group sync.WaitGroup
	results := make([]bool, 16)
	failures := make([]error, 16)
	for index := range results {
		group.Add(1)
		go func() {
			defer group.Done()
			results[index], failures[index] = f.database.RetireReplaced(context.Background(), token, fixed(instant.Add(time.Duration(index)*time.Millisecond)))
		}()
	}
	group.Wait()
	for index := range results {
		if failures[index] != nil || !results[index] {
			t.Fatalf("attempt %d: %v %v", index, results[index], failures[index])
		}
	}
	revocations := livetest.Query(t, f.path, `SELECT CAST(revoked_at AS TEXT) FROM api_tokens WHERE id = 1`)
	stamp := revocations[0][0].(string)
	first, later := instant.Format("2006-01-02 15:04:05"), instant.Add(15*time.Millisecond).Format("2006-01-02 15:04:05")
	if len(stamp) < 19 || stamp[:19] != first || stamp[:19] > later {
		t.Fatalf("unexpected revocation time %q", stamp)
	}
	if again, err := f.database.RetireReplaced(context.Background(), token, fixed(instant.Add(time.Hour))); err != nil || !again {
		t.Fatalf("a repeat adoption failed: %v %v", again, err)
	}
	if f.snapshot(t, 1).revoked != stamp {
		t.Fatal("a repeated adoption rewrote the revocation")
	}
}

func TestActiveTokenLookupHonoursRevocationAndExpiryExactlyAsRailsQueriesThem(t *testing.T) {
	f := newTokens(t)
	f.token(t, 1, 1, nil, "")
	f.token(t, 2, 1, nil, "revoked_at = '2026-11-01 00:00:00'")
	f.token(t, 3, 1, nil, "expires_at = '2026-11-15 09:30:15.123456'")
	f.token(t, 4, 1, nil, "expires_at = '2026-11-15 09:30:15.123457'")
	f.token(t, 5, 1, nil, "expires_at = '2020-01-01 00:00:00'")
	now := TimestampText(instant)
	expected := map[int64]bool{1: true, 2: false, 3: false, 4: true, 5: false}
	for id, active := range expected {
		found, err := f.database.ActiveTokenByDigest(context.Background(), "digest-"+string(rune('a'+id)), now)
		if err != nil || (found != nil) != active {
			t.Errorf("token %d: found=%v err=%v want active=%v", id, found != nil, err, active)
		}
	}
}

func TestExpiryIsEvaluatedAfterTheAdoptionLockIsAcquired(t *testing.T) {
	cases := map[string]struct{ parent, own string }{
		"parent expires while waiting":         {"expires_at = '2026-11-15 09:30:16'", ""},
		"own credential expires while waiting": {"", "expires_at = '2026-11-15 09:30:16'"},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			f := newTokens(t)
			f.token(t, 1, 1, nil, c.parent)
			f.token(t, 2, 1, 1, c.own)
			calls := 0
			clock := func() time.Time {
				calls++
				return instant.Add(5 * time.Second)
			}
			before := [2]tokenSnapshot{f.snapshot(t, 1), f.snapshot(t, 2)}
			if adopted, err := f.database.RetireReplaced(context.Background(), f.lookup(t, 2), clock); err != nil || adopted {
				t.Fatalf("adopted=%v err=%v", adopted, err)
			}
			if calls == 0 || f.snapshot(t, 1) != before[0] || f.snapshot(t, 2) != before[1] {
				t.Fatalf("calls=%d or a token changed", calls)
			}
		})
	}
}

func TestTheClockIsReadOnlyOnceTheWriteLockIsHeld(t *testing.T) {
	f := newTokens(t)
	f.token(t, 1, 1, nil, "expires_at = '2026-11-15 09:30:16'")
	f.token(t, 2, 1, 1, "")
	holder, err := sql.Open("sqlite", "file:"+f.path+"?_txlock=immediate&_pragma=busy_timeout(5000)")
	if err != nil {
		t.Fatal(err)
	}
	defer holder.Close()
	transaction, err := holder.Begin()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := transaction.Exec(`UPDATE api_tokens SET name = 'held' WHERE id = 1`); err != nil {
		t.Fatal(err)
	}
	var released atomic.Bool
	clock := func() time.Time {
		if released.Load() {
			return instant.Add(5 * time.Second)
		}
		return instant
	}
	type outcome struct {
		adopted bool
		err     error
	}
	done := make(chan outcome, 1)
	database := open(t, f.path)
	go func() {
		adopted, err := database.RetireReplaced(context.Background(), f.lookup(t, 2), clock)
		done <- outcome{adopted, err}
	}()
	time.Sleep(100 * time.Millisecond)
	released.Store(true)
	if err := transaction.Rollback(); err != nil {
		t.Fatal(err)
	}
	got := <-done
	if got.err != nil || got.adopted {
		t.Fatalf("an adoption decided on the time before the wait: adopted=%v err=%v", got.adopted, got.err)
	}
}

package live

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/checkpoint"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/livetest"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/strictjson"
)

var (
	start    = time.Date(2026, 11, 14, 12, 0, 0, 250_000_000, time.UTC)
	assetOne = strings.Repeat("a", 64)
	assetTwo = strings.Repeat("b", 64)
)

func at(offset time.Duration) func() time.Time { return func() time.Time { return start.Add(offset) } }

func moment(offset time.Duration) *time.Time {
	value := start.Add(offset).Truncate(time.Millisecond)
	return &value
}

func place(t *testing.T, text string) (*strictjson.Value, *string) {
	t.Helper()
	parsed, err := strictjson.Parse([]byte(text))
	if err != nil {
		t.Fatal(err)
	}
	encoded := parsed.Encode()
	return &parsed, &encoded
}

func seconds(value float64) *float64 { return &value }

func audioWrite(mutation string, expected int64, position float64, observed *time.Time) checkpoint.Write {
	return checkpoint.Write{AssetID: assetOne, MutationID: mutation, ExpectedVersion: expected, PositionSeconds: seconds(position), ObservedAt: observed}
}

func ebookWrite(t *testing.T, mutation string, expected int64, locator string, observed *time.Time) checkpoint.Write {
	t.Helper()
	value, text := place(t, locator)
	return checkpoint.Write{AssetID: assetOne, MutationID: mutation, ExpectedVersion: expected, Locator: value, LocatorText: text, ObservedAt: observed}
}

type progressFixture struct {
	path     string
	database *DB
}

func newProgress(t *testing.T) progressFixture {
	t.Helper()
	path := livetest.Create(t)
	livetest.Exec(t, path, `INSERT INTO users (id, username) VALUES (1, 'alice'), (2, 'bob')`)
	return progressFixture{path: path, database: open(t, path)}
}

func (f progressFixture) save(t *testing.T, user int64, write checkpoint.Write, offset time.Duration) ProgressResult {
	t.Helper()
	result, err := f.database.SaveProgress(context.Background(), user, 7, write, at(offset))
	if err != nil {
		t.Fatalf("save: %v", err)
	}
	return result
}

func (f progressFixture) rows(t *testing.T) [][]any {
	t.Helper()
	return livetest.Query(t, f.path, `SELECT user_id, book_id, asset_id, locator, position_seconds, version, client_mutation_id, CAST(created_at AS TEXT), CAST(updated_at AS TEXT), CAST(observed_at AS TEXT) FROM consumer_progresses ORDER BY user_id, book_id`)
}

func TestTheFirstWriteStoresVersionOneWithTheServerTimeApartFromTheDeviceTime(t *testing.T) {
	f := newProgress(t)
	got := f.save(t, 1, audioWrite("m1", 0, 17.5, moment(-time.Hour)), 0)
	if got.Outcome != ProgressApplied || got.Progress.Version != 1 || got.Progress.UpdatedAt != "2026-11-14 12:00:00.250000" || got.Progress.ObservedAt.String != "2026-11-14 11:00:00.250000" {
		t.Fatalf("%+v", got)
	}
	want := [][]any{{int64(1), int64(7), assetOne, nil, 17.5, int64(1), "m1", "2026-11-14 12:00:00.250000", "2026-11-14 12:00:00.250000", "2026-11-14 11:00:00.250000"}}
	if fmt.Sprint(f.rows(t)) != fmt.Sprint(want) {
		t.Fatalf("%v", f.rows(t))
	}
}

func TestAnUnknownActivityTimeIsStoredAsNullNeverAsTheUploadTime(t *testing.T) {
	f := newProgress(t)
	got := f.save(t, 1, audioWrite("m1", 0, 1, nil), 0)
	if got.Progress.ObservedAt.Valid || f.rows(t)[0][9] != nil {
		t.Fatalf("%+v", got.Progress)
	}
}

func TestARetryOfTheSameCheckpointChangesNothingAndReportsTheOriginalVersionAndTimes(t *testing.T) {
	f := newProgress(t)
	first := f.save(t, 1, ebookWrite(t, "m1", 0, `{"href":"a.xhtml","locations":{"progression":0.5}}`, moment(-time.Hour)), 0)
	before := fmt.Sprint(f.rows(t))
	retry := f.save(t, 1, ebookWrite(t, "m1", 0, `{"locations":{"progression":0.50},"href":"a.xhtml"}`, moment(-time.Hour)), 10*time.Minute)
	if retry.Outcome != ProgressReplayed || *retry.Progress != *first.Progress || fmt.Sprint(f.rows(t)) != before {
		t.Fatalf("%+v %+v", retry, first)
	}
	later := f.save(t, 1, ebookWrite(t, "m1", 99, `{"href":"a.xhtml","locations":{"progression":0.5}}`, moment(-time.Hour)), time.Hour)
	if later.Outcome != ProgressReplayed || later.Progress.Version != 1 {
		t.Fatalf("a retry carrying a stale expected version was not recognised: %+v", later)
	}
}

func TestOneMutationIdCannotCarryDifferentData(t *testing.T) {
	changes := map[string]checkpoint.Write{
		"position": audioWrite("m1", 0, 18, moment(-time.Hour)),
		"time":     audioWrite("m1", 0, 17.5, moment(-time.Minute)),
		"no time":  audioWrite("m1", 0, 17.5, nil),
		"asset": func() checkpoint.Write {
			w := audioWrite("m1", 0, 17.5, moment(-time.Hour))
			w.AssetID = assetTwo
			return w
		}(),
		"ebook":        ebookWrite(t, "m1", 0, `{"href":"a","locations":{}}`, moment(-time.Hour)),
		"milliseconds": audioWrite("m1", 0, 17.5, moment(-time.Hour+time.Millisecond)),
	}
	for name, write := range changes {
		t.Run(name, func(t *testing.T) {
			f := newProgress(t)
			f.save(t, 1, audioWrite("m1", 0, 17.5, moment(-time.Hour)), 0)
			before := fmt.Sprint(f.rows(t))
			got := f.save(t, 1, write, time.Minute)
			if got.Outcome != ProgressConflict || got.Progress.Version != 1 || fmt.Sprint(f.rows(t)) != before {
				t.Fatalf("%+v", got)
			}
		})
	}
}

func TestAStoredLocatorIsComparedByValueTheWayRubyComparesHashes(t *testing.T) {
	f := newProgress(t)
	f.save(t, 1, ebookWrite(t, "m1", 0, `{"href":"a","locations":{"position":4,"progression":1.0},"x":[1,{"y":null}]}`, nil), 0)
	same := f.save(t, 1, ebookWrite(t, "m1", 0, `{"x":[1.0,{"y":null}],"locations":{"progression":1,"position":4.0},"href":"a"}`, nil), time.Minute)
	if same.Outcome != ProgressReplayed || same.Progress.Version != 1 {
		t.Fatalf("%+v", same)
	}
}

func TestAMissingRowOnlyAcceptsVersionZero(t *testing.T) {
	f := newProgress(t)
	got := f.save(t, 1, audioWrite("m1", 1, 1, nil), 0)
	if got.Outcome != ProgressConflict || got.Progress != nil || len(f.rows(t)) != 0 {
		t.Fatalf("%+v", got)
	}
}

func TestAnUpdateNeedsTheExactCurrentVersionAndIncrementsIt(t *testing.T) {
	f := newProgress(t)
	f.save(t, 1, audioWrite("m1", 0, 10, moment(-time.Hour)), 0)
	for _, expected := range []int64{0, 2, 99} {
		if got := f.save(t, 1, audioWrite(fmt.Sprint("x", expected), expected, 99, nil), time.Minute); got.Outcome != ProgressConflict || got.Progress.Version != 1 || got.Progress.PositionSeconds.Float64 != 10 {
			t.Fatalf("expected %d: %+v", expected, got)
		}
	}
	got := f.save(t, 1, audioWrite("m2", 1, 20, moment(-time.Minute)), time.Minute)
	if got.Outcome != ProgressApplied || got.Progress.Version != 2 || got.Progress.UpdatedAt != "2026-11-14 12:01:00.250000" || got.Progress.ObservedAt.String != "2026-11-14 11:59:00.250000" {
		t.Fatalf("%+v", got)
	}
	created := livetest.Query(t, f.path, `SELECT CAST(created_at AS TEXT) FROM consumer_progresses`)[0][0]
	if created != "2026-11-14 12:00:00.250000" {
		t.Fatalf("an update changed created_at: %v", created)
	}
}

func TestVersionsReachTheLargestAcceptedValueWithoutOverflowing(t *testing.T) {
	f := newProgress(t)
	f.save(t, 1, audioWrite("m1", 0, 1, nil), 0)
	livetest.Exec(t, f.path, `UPDATE consumer_progresses SET version = ?`, int64(checkpoint.MaxVersion))
	got := f.save(t, 1, audioWrite("m2", checkpoint.MaxVersion, 2, nil), time.Minute)
	if got.Outcome != ProgressApplied || got.Progress.Version != checkpoint.MaxVersion+1 {
		t.Fatalf("%+v", got)
	}
	if again := f.save(t, 1, audioWrite("m3", checkpoint.MaxVersion, 3, nil), time.Minute); again.Outcome != ProgressConflict {
		t.Fatalf("%+v", again)
	}
}

func TestEarlierDeviceActivityCannotReplaceLaterActivity(t *testing.T) {
	cases := []struct {
		name      string
		stored    *time.Time
		sent      *time.Time
		samePlace bool
		resolve   bool
		applied   bool
	}{
		{"later replaces earlier", moment(-time.Hour), moment(-time.Minute), false, false, true},
		{"earlier cannot replace later", moment(-time.Minute), moment(-time.Hour), false, false, false},
		{"equal time, same place is accepted", moment(-time.Hour), moment(-time.Hour), true, false, true},
		{"equal time, different place conflicts", moment(-time.Hour), moment(-time.Hour), false, false, false},
		{"unknown stored time accepts anything", nil, moment(-time.Hour), false, false, true},
		{"unknown sent time accepts anything", moment(-time.Minute), nil, false, false, true},
		{"both unknown", nil, nil, false, false, true},
		{"one millisecond earlier conflicts", moment(-time.Hour + time.Millisecond), moment(-time.Hour), false, false, false},
		{"one millisecond later is accepted", moment(-time.Hour), moment(-time.Hour + time.Millisecond), false, false, true},
		{"resolution bypasses an earlier time", moment(-time.Minute), moment(-time.Hour), false, true, true},
		{"resolution bypasses an equal time at another place", moment(-time.Hour), moment(-time.Hour), false, true, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newProgress(t)
			f.save(t, 1, audioWrite("m1", 0, 10, c.stored), 0)
			position := 99.0
			if c.samePlace {
				position = 10
			}
			write := audioWrite("m2", 1, position, c.sent)
			write.Resolve = c.resolve
			got := f.save(t, 1, write, time.Minute)
			if (got.Outcome == ProgressApplied) != c.applied {
				t.Fatalf("%+v", got)
			}
			if !c.applied && (got.Progress.Version != 1 || got.Progress.PositionSeconds.Float64 != 10) {
				t.Fatalf("a refused write changed the row: %+v", got.Progress)
			}
		})
	}
}

func TestAResolutionNeverBypassesTheVersionOrTheMutationGuard(t *testing.T) {
	f := newProgress(t)
	f.save(t, 1, audioWrite("m1", 0, 10, moment(-time.Minute)), 0)
	wrongVersion := audioWrite("m2", 0, 99, moment(-time.Hour))
	wrongVersion.Resolve = true
	if got := f.save(t, 1, wrongVersion, time.Minute); got.Outcome != ProgressConflict || got.Progress.Version != 1 {
		t.Fatalf("%+v", got)
	}
	reused := audioWrite("m1", 1, 99, moment(-time.Hour))
	reused.Resolve = true
	if got := f.save(t, 1, reused, time.Minute); got.Outcome != ProgressConflict || got.Progress.PositionSeconds.Float64 != 10 {
		t.Fatalf("%+v", got)
	}
	chosen := audioWrite("m2", 1, 99, moment(-time.Hour))
	chosen.Resolve = true
	if got := f.save(t, 1, chosen, time.Minute); got.Outcome != ProgressApplied || got.Progress.Version != 2 {
		t.Fatalf("%+v", got)
	}
	if retry := f.save(t, 1, chosen, time.Hour); retry.Outcome != ProgressReplayed || retry.Progress.Version != 2 {
		t.Fatalf("%+v", retry)
	}
}

func TestAccountsNeverSeeOrOverwriteEachOthersPlaces(t *testing.T) {
	f := newProgress(t)
	f.save(t, 1, audioWrite("m1", 0, 10, nil), 0)
	other := f.save(t, 2, audioWrite("m1", 0, 20, nil), 0)
	if other.Outcome != ProgressApplied || other.Progress.Version != 1 || other.Progress.PositionSeconds.Float64 != 20 || len(f.rows(t)) != 2 {
		t.Fatalf("%+v", other)
	}
}

func TestConcurrentFirstWritesAdmitExactlyOneAndEveryoneElseSeesItsPlace(t *testing.T) {
	f := newProgress(t)
	var applied, conflicts atomic.Int32
	var wait sync.WaitGroup
	for index := 0; index < 24; index++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			result, err := f.database.SaveProgress(context.Background(), 1, 7, audioWrite(fmt.Sprint("m", index), 0, float64(index), nil), at(0))
			switch {
			case err != nil:
				t.Errorf("%v", err)
			case result.Outcome == ProgressApplied:
				applied.Add(1)
			case result.Outcome == ProgressConflict && result.Progress != nil && result.Progress.Version == 1:
				conflicts.Add(1)
			default:
				t.Errorf("%+v", result)
			}
		}()
	}
	wait.Wait()
	if applied.Load() != 1 || conflicts.Load() != 23 || len(f.rows(t)) != 1 {
		t.Fatalf("applied=%d conflicts=%d rows=%d", applied.Load(), conflicts.Load(), len(f.rows(t)))
	}
}

func TestConcurrentUpdatesNeverLoseAWrite(t *testing.T) {
	f := newProgress(t)
	f.save(t, 1, audioWrite("start", 0, 0, nil), 0)
	const writers = 16
	var wait sync.WaitGroup
	for index := 0; index < writers; index++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			for attempt := 0; ; attempt++ {
				current, err := f.database.ProgressFor(context.Background(), 1, []int64{7})
				if err != nil {
					t.Errorf("%v", err)
					return
				}
				result, err := f.database.SaveProgress(context.Background(), 1, 7, audioWrite(fmt.Sprintf("w%d-%d", index, attempt), current[7].Version, float64(index), nil), at(0))
				if err != nil {
					t.Errorf("%v", err)
					return
				}
				if result.Outcome == ProgressApplied {
					return
				}
			}
		}()
	}
	wait.Wait()
	if version := livetest.Query(t, f.path, `SELECT version FROM consumer_progresses`)[0][0]; version != int64(writers+1) {
		t.Fatalf("a successful write was lost: version %v", version)
	}
}

func TestACorruptStoredValueIsUnsupportedNeverAConflictOrASuccess(t *testing.T) {
	f := newProgress(t)
	f.save(t, 1, ebookWrite(t, "m1", 0, `{"href":"a","locations":{}}`, moment(-time.Hour)), 0)
	livetest.Exec(t, f.path, `UPDATE consumer_progresses SET observed_at = 'garbage'`)
	_, err := f.database.SaveProgress(context.Background(), 1, 7, ebookWrite(t, "m2", 1, `{"href":"b","locations":{}}`, moment(-time.Minute)), at(0))
	if !errors.Is(err, store.ErrTimestamp) {
		t.Fatalf("%v", err)
	}
	livetest.Exec(t, f.path, `UPDATE consumer_progresses SET observed_at = '2026-11-14 11:00:00', locator = 'not json'`)
	_, err = f.database.SaveProgress(context.Background(), 1, 7, ebookWrite(t, "m1", 1, `{"href":"b","locations":{}}`, moment(-time.Hour)), at(0))
	if !errors.Is(err, store.ErrUnsupported) {
		t.Fatalf("%v", err)
	}
	if rows := f.rows(t); rows[0][6] != "m1" || rows[0][5] != int64(1) {
		t.Fatalf("a refused write changed the row: %v", rows)
	}
}

func TestTheClockIsReadAfterTheWriteLockIsHeld(t *testing.T) {
	f := newProgress(t)
	holder, err := sql.Open("sqlite", "file:"+f.path+"?_txlock=immediate&_pragma=busy_timeout(5000)")
	if err != nil {
		t.Fatal(err)
	}
	defer holder.Close()
	transaction, err := holder.Begin()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := transaction.Exec(`UPDATE users SET name = 'held' WHERE id = 1`); err != nil {
		t.Fatal(err)
	}
	var released atomic.Bool
	clock := func() time.Time {
		if released.Load() {
			return start.Add(time.Hour)
		}
		return start
	}
	database, err := Open(context.Background(), f.path, Options{BusyTimeout: 5 * time.Second})
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	done := make(chan ProgressResult, 1)
	go func() {
		result, _ := database.SaveProgress(context.Background(), 1, 7, audioWrite("m1", 0, 1, nil), clock)
		done <- result
	}()
	time.Sleep(150 * time.Millisecond)
	released.Store(true)
	transaction.Rollback()
	if got := <-done; got.Progress == nil || got.Progress.UpdatedAt != "2026-11-14 13:00:00.250000" {
		t.Fatalf("the stored time was read before the wait: %+v", got.Progress)
	}
}

func TestAHeldWriteLockIsBusyAndLeavesTheRowUntouched(t *testing.T) {
	f := newProgress(t)
	f.save(t, 1, audioWrite("m1", 0, 10, nil), 0)
	holder, err := sql.Open("sqlite", "file:"+f.path+"?_txlock=immediate&_pragma=busy_timeout(5000)")
	if err != nil {
		t.Fatal(err)
	}
	defer holder.Close()
	transaction, err := holder.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer transaction.Rollback()
	if _, err := transaction.Exec(`UPDATE users SET name = 'held' WHERE id = 1`); err != nil {
		t.Fatal(err)
	}
	before := fmt.Sprint(f.rows(t))
	started := time.Now()
	_, err = f.database.SaveProgress(context.Background(), 1, 7, audioWrite("m2", 1, 20, nil), at(0))
	if !errors.Is(err, ErrBusy) || time.Since(started) > 3*time.Second {
		t.Fatalf("%v after %s", err, time.Since(started))
	}
	if err := f.database.SetReadingStatus(context.Background(), 1, 7, 2, at(0)); !errors.Is(err, ErrBusy) {
		t.Fatalf("%v", err)
	}
	if fmt.Sprint(f.rows(t)) != before || len(livetest.Query(t, f.path, `SELECT 1 FROM consumer_reading_states`)) != 0 {
		t.Fatal("a refused write changed a row")
	}
}

func TestACancelledWriteLeavesNothingBehind(t *testing.T) {
	f := newProgress(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := f.database.SaveProgress(ctx, 1, 7, audioWrite("m1", 0, 1, nil), at(0)); !errors.Is(err, context.Canceled) {
		t.Fatalf("%v", err)
	}
	if len(f.rows(t)) != 0 {
		t.Fatal("a cancelled write left a row")
	}
}

func TestReadingStatusIsSeparateFromProgressAndOnlyAChangeMovesItsTime(t *testing.T) {
	f := newProgress(t)
	f.save(t, 1, audioWrite("m1", 0, 10, nil), 0)
	state := func() []any {
		return livetest.Query(t, f.path, `SELECT status, CAST(created_at AS TEXT), CAST(updated_at AS TEXT) FROM consumer_reading_states WHERE user_id = 1 AND book_id = 7`)[0]
	}
	if err := f.database.SetReadingStatus(context.Background(), 1, 7, 2, at(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if got := fmt.Sprint(state()); got != "[2 2026-11-14 12:01:00.250000 2026-11-14 12:01:00.250000]" {
		t.Fatal(got)
	}
	if err := f.database.SetReadingStatus(context.Background(), 1, 7, 2, at(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if got := fmt.Sprint(state()); got != "[2 2026-11-14 12:01:00.250000 2026-11-14 12:01:00.250000]" {
		t.Fatalf("repeating a status moved its time: %s", got)
	}
	if err := f.database.SetReadingStatus(context.Background(), 1, 7, 0, at(2*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if got := fmt.Sprint(state()); got != "[0 2026-11-14 12:01:00.250000 2026-11-14 14:00:00.250000]" {
		t.Fatal(got)
	}
	f.save(t, 1, audioWrite("m2", 1, 50, nil), 3*time.Hour)
	if got := fmt.Sprint(state()[0]); got != "0" {
		t.Fatalf("a later checkpoint undid an explicit status: %s", got)
	}
	if rows := livetest.Query(t, f.path, `SELECT COUNT(*) FROM consumer_reading_states`); rows[0][0] != int64(1) {
		t.Fatal("a second state row was created")
	}
	if progress := f.rows(t); progress[0][4] != 50.0 || progress[0][5] != int64(2) {
		t.Fatalf("a status change touched the saved place: %v", progress)
	}
}

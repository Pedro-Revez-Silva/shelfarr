package catalogue

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/live"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/livetest"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/readerformats"
)

const secret = "unit-test-secret-key-base-unit-test-secret-key-base"

type fixture struct {
	path      string
	catalogue Catalogue
}

func newFixture(t *testing.T) fixture {
	t.Helper()
	path := livetest.Create(t)
	database, err := live.Open(context.Background(), path, live.Options{BusyTimeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { database.Close() })
	listing, err := New(database, secret)
	if err != nil {
		t.Fatal(err)
	}
	return fixture{path: path, catalogue: listing}
}

func (f fixture) book(t *testing.T, id int, title string, bookType int, path any) {
	t.Helper()
	livetest.Exec(t, f.path, `INSERT INTO books (id, title, book_type, file_path) VALUES (?, ?, ?, ?)`, id, title, bookType, path)
}

func (f fixture) call(t *testing.T, user int64, query string, formats readerformats.Formats) (Result, error) {
	t.Helper()
	params, err := ParseQuery(query)
	if err != nil {
		t.Fatalf("query %q: %v", query, err)
	}
	return f.catalogue.Call(context.Background(), user, params, formats)
}

var legacy = readerformats.Formats{Names: []string{"epub"}}

func ids(result Result) []int64 {
	var identifiers []int64
	for _, book := range result.Books {
		identifiers = append(identifiers, book.ID)
	}
	return identifiers
}

func seedMany(t *testing.T, f fixture) {
	t.Helper()
	for id := 1; id <= 12; id++ {
		f.book(t, id, fmt.Sprintf("Book %02d", id), id%2, fmt.Sprintf("/library/%d.epub", id))
	}
	f.book(t, 13, "Comic", 2, "/library/13.cbz")
	f.book(t, 14, "Pending", 1, nil)
	f.book(t, 15, "Blank", 1, "  ")
}

func TestListingIsNewestFirstAndOnlyAcquiredReadingBooks(t *testing.T) {
	f := newFixture(t)
	seedMany(t, f)
	result, err := f.call(t, 1, "", legacy)
	if err != nil || result.NextCursor != nil {
		t.Fatal(err)
	}
	if got := ids(result); fmt.Sprint(got) != "[12 11 10 9 8 7 6 5 4 3 2 1]" {
		t.Fatalf("got %v", got)
	}
}

func TestCursorsWalkEveryBookExactlyOnceInBothOrders(t *testing.T) {
	f := newFixture(t)
	seedMany(t, f)
	for _, sort := range []string{"recent", "title"} {
		var seen []int64
		query := "limit=5&sort=" + sort
		for page := 0; page < 10; page++ {
			result, err := f.call(t, 1, query, legacy)
			if err != nil {
				t.Fatal(err)
			}
			seen = append(seen, ids(result)...)
			if result.NextCursor == nil {
				break
			}
			query = "limit=5&sort=" + sort + "&cursor=" + url.QueryEscape(*result.NextCursor)
		}
		if len(seen) != 12 {
			t.Fatalf("%s: saw %v", sort, seen)
		}
		unique := map[int64]bool{}
		for _, id := range seen {
			unique[id] = true
		}
		if len(unique) != 12 {
			t.Fatalf("%s repeated a book: %v", sort, seen)
		}
	}
}

func TestTitleOrderBreaksTiesByIdentifierAndIgnoresCase(t *testing.T) {
	f := newFixture(t)
	for id, title := range map[int]string{1: "tie", 2: "TIE", 3: "Tie", 4: "alpha", 5: "Zed"} {
		f.book(t, id, title, 1, fmt.Sprintf("/library/%d.epub", id))
	}
	first, err := f.call(t, 1, "sort=title&limit=2", legacy)
	if err != nil || fmt.Sprint(ids(first)) != "[4 1]" || first.NextCursor == nil {
		t.Fatalf("%v %v", ids(first), err)
	}
	second, _ := f.call(t, 1, "sort=title&limit=2&cursor="+url.QueryEscape(*first.NextCursor), legacy)
	third, _ := f.call(t, 1, "sort=title&limit=2&cursor="+url.QueryEscape(*second.NextCursor), legacy)
	if fmt.Sprint(ids(second), ids(third)) != "[2 3] [5]" {
		t.Fatalf("%v %v", ids(second), ids(third))
	}
}

func TestACursorBelongsToOneAccountOneQueryAndOneFormatSelection(t *testing.T) {
	f := newFixture(t)
	seedMany(t, f)
	first, _ := f.call(t, 1, "limit=3", legacy)
	cursor := "&cursor=" + url.QueryEscape(*first.NextCursor)
	refused := map[string]struct {
		user    int64
		query   string
		formats readerformats.Formats
	}{
		"other account": {2, "limit=3", legacy},
		"other query":   {1, "limit=3&q=Book", legacy},
		"other type":    {1, "limit=3&type=ebook", legacy},
		"other status":  {1, "limit=3&status=unread", legacy},
		"other sort":    {1, "limit=3&sort=title", legacy},
		"other formats": {1, "limit=3", readerformats.Formats{Names: []string{"epub", "pdf"}, Declared: true}},
	}
	for name, attempt := range refused {
		_, err := f.call(t, attempt.user, attempt.query+cursor, attempt.formats)
		var invalid Invalid
		if !errors.As(err, &invalid) || invalid.Message != "Invalid library cursor" {
			t.Errorf("%s: %v", name, err)
		}
	}
	if _, err := f.call(t, 1, "limit=7"+cursor, legacy); err != nil {
		t.Fatalf("a different page size must keep the cursor valid: %v", err)
	}
	declared := readerformats.Formats{Names: []string{"epub"}, Declared: true}
	if _, err := f.call(t, 1, "limit=3"+cursor, declared); err != nil {
		t.Fatalf("a declared epub selection keeps the legacy identity: %v", err)
	}
}

func TestForgedAndMalformedCursorsAreRefused(t *testing.T) {
	f := newFixture(t)
	seedMany(t, f)
	first, _ := f.call(t, 1, "limit=3", legacy)
	good := *first.NextCursor
	other, _ := New(f.catalogue.DB, secret+"-different")
	forged, _ := other.Call(context.Background(), 1, Params{Limit: Param{Present: true, IsString: true, Value: "3"}}, legacy)
	for name, cursor := range map[string]string{
		"truncated": good[:len(good)-1], "garbage": "not-a-cursor", "other key": *forged.NextCursor, "oversized": strings.Repeat("a", 4097), "separator only": "--",
	} {
		params := Params{Cursor: Param{Present: true, IsString: true, Value: cursor}}
		_, err := f.catalogue.Call(context.Background(), 1, params, legacy)
		var invalid Invalid
		if !errors.As(err, &invalid) {
			t.Errorf("%s: %v", name, err)
		}
	}
	blank := Params{Cursor: Param{Present: true, IsString: true, Value: "  "}}
	if _, err := f.catalogue.Call(context.Background(), 1, blank, legacy); err != nil {
		t.Fatalf("a blank cursor starts from the beginning: %v", err)
	}
}

func TestParametersAreValidatedWithTheRailsMessages(t *testing.T) {
	f := newFixture(t)
	seedMany(t, f)
	cases := map[string]string{
		"type=comic": "Unknown publication type", "status=nope": "Unknown reading status", "sort=zzz": "Unknown library sort",
		"q=" + strings.Repeat("a", 201): "Search is too long", "q%5B%5D=x": "Search is too long", "type%5B%5D=x": "Unknown publication type",
	}
	for query, message := range cases {
		_, err := f.call(t, 1, query, legacy)
		var invalid Invalid
		if !errors.As(err, &invalid) || invalid.Message != message {
			t.Errorf("%q: %v want %q", query, err, message)
		}
	}
	for _, query := range []string{"type=", "type=%20", "status=", "sort=", "q=", "q=%20%20", "limit=abc", "limit=-1", "limit%5B%5D=2", "cursor=", "zzz=1"} {
		if _, err := f.call(t, 1, query, legacy); err != nil {
			t.Errorf("%q: %v", query, err)
		}
	}
}

func TestLimitIsClampedLikeRails(t *testing.T) {
	f := newFixture(t)
	for id := 1; id <= 60; id++ {
		f.book(t, id, fmt.Sprintf("Book %02d", id), 1, fmt.Sprintf("/library/%d.epub", id))
	}
	expected := map[string]int{"": 30, "limit=1": 1, "limit=0": 1, "limit=50": 50, "limit=999": 50, "limit=1000": 30, "limit=abc": 30, "limit=007": 7, "limit=2&limit=3": 3}
	for query, want := range expected {
		result, err := f.call(t, 1, query, legacy)
		if err != nil || len(result.Books) != want {
			t.Errorf("%q: %d %v want %d", query, len(result.Books), err, want)
		}
	}
}

func TestSearchTreatsWildcardsAndBackslashesLiterally(t *testing.T) {
	f := newFixture(t)
	for id, title := range map[int]string{1: "100% Cotton", 2: "snake_case", 3: `back\slash`, 4: "plain", 5: "snakeXcase"} {
		f.book(t, id, title, 1, fmt.Sprintf("/library/%d.epub", id))
	}
	expected := map[string]string{"q=%25": "[1]", "q=_": "[2]", "q=%5C": "[3]", "q=snake_case": "[2]", "q=COTTON": "[1]", "q=snake": "[5 2]"}
	for query, want := range expected {
		result, err := f.call(t, 1, query, legacy)
		if err != nil || fmt.Sprint(ids(result)) != want {
			t.Errorf("%q: %v %v want %s", query, ids(result), err, want)
		}
	}
}

func TestStatusAndTypeFiltersUseThePerAccountState(t *testing.T) {
	f := newFixture(t)
	seedMany(t, f)
	livetest.Exec(t, f.path, `INSERT INTO consumer_reading_states (user_id, book_id, status, updated_at) VALUES (1, 3, 2, '2026-11-01 00:00:00'), (2, 4, 2, '2026-11-01 00:00:00'), (1, 5, 0, '2026-11-01 00:00:00')`)
	livetest.Exec(t, f.path, `INSERT INTO consumer_progresses (user_id, book_id, asset_id, version, client_mutation_id, updated_at) VALUES (1, 6, 'a', 1, 'm', '2026-11-01 00:00:00'), (1, 5, 'a', 1, 'm2', '2026-11-01 00:00:00')`)
	finished, _ := f.call(t, 1, "status=finished", legacy)
	inProgress, _ := f.call(t, 1, "status=in_progress", legacy)
	unread, _ := f.call(t, 1, "status=unread&type=audiobook", legacy)
	other, _ := f.call(t, 2, "status=finished", legacy)
	if fmt.Sprint(ids(finished), ids(inProgress), ids(other)) != "[3] [6] [4]" {
		t.Fatalf("%v %v %v", ids(finished), ids(inProgress), ids(other))
	}
	if fmt.Sprint(ids(unread)) != "[12 10 8 4 2]" {
		t.Fatalf("%v", ids(unread))
	}
}

func TestQueryParsingFollowsRackForTheParametersThatMatter(t *testing.T) {
	params, err := ParseQuery("q=a+b%20c&limit=2&limit=3&type%5B%5D=x&unrelated=1&sort=title")
	if err != nil {
		t.Fatal(err)
	}
	if params.Q.Value != "a b c" || params.Limit.Value != "3" || params.Type.IsString || !params.Type.Present || params.Sort.Value != "title" {
		t.Fatalf("%+v", params)
	}
	for _, bad := range []string{"q=%zz", "q=%FF", "%FF=1", "q=a&q%5B%5D=b", "q%5B%5D=a&q=b", "q=" + strings.Repeat("a", 13000)} {
		if _, err := ParseQuery(bad); !errors.Is(err, ErrBadQuery) {
			t.Errorf("%q: %v", bad, err)
		}
	}
	if params, err := ParseQuery(""); err != nil || params.Q.Present {
		t.Fatalf("%+v %v", params, err)
	}
}

func TestAWhitespaceStatusFiltersNothingButStillBindsTheCursor(t *testing.T) {
	f := newFixture(t)
	seedMany(t, f)
	plain, err := f.call(t, 1, "limit=4", legacy)
	blank, blankErr := f.call(t, 1, "limit=4&status=%20", legacy)
	if err != nil || blankErr != nil || fmt.Sprint(ids(plain)) != fmt.Sprint(ids(blank)) || len(blank.Books) != 4 {
		t.Fatalf("%v %v %v %v", ids(plain), ids(blank), err, blankErr)
	}
	if _, err := f.call(t, 1, "limit=4&cursor="+url.QueryEscape(*plain.NextCursor)+"&status=%20", legacy); err == nil {
		t.Fatal("a cursor must stay bound to the raw status text, as in Rails")
	}
}

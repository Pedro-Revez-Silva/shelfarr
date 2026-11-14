package consumer

import (
	"database/sql"
	"strings"
	"testing"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
)

func text(value string) sql.NullString {
	return sql.NullString{String: value, Valid: true}
}

func TestDescriptionIsTruncatedByCodePoint(t *testing.T) {
	short, err := truncatedDescription(sql.NullString{})
	if err != nil || short != "" {
		t.Fatalf("null = %q, %v", short, err)
	}
	long := strings.Repeat("\U0001F4D6", descriptionLimit+5)
	got, err := truncatedDescription(text(long))
	if err != nil || len([]rune(got)) != descriptionLimit {
		t.Fatalf("runes = %d, %v", len([]rune(got)), err)
	}
	exact := strings.Repeat("é", descriptionLimit)
	if got, _ := truncatedDescription(text(exact)); got != exact {
		t.Fatal("exact-length description altered")
	}
	if _, err := truncatedDescription(text("bad \xff bytes")); err == nil {
		t.Fatal("invalid utf-8 accepted")
	}
}

func TestSafeCover(t *testing.T) {
	cases := []struct {
		value string
		want  string
		err   bool
	}{
		{"https://covers.example.test/a.jpg", "https://covers.example.test/a.jpg", false},
		{"http://covers.example.test/a.jpg", "", false},
		{"https://user:pw@covers.example.test/a.jpg", "", false},
		{"https:///no-host", "", false},
		{"not a url", "", false},
		{"", "", false},
		{"HTTPS://Covers.example.test/a.jpg", "", true},
		{"https://covers.example.test/a b.jpg", "", true},
	}
	for _, testCase := range cases {
		got, err := safeCover(text(testCase.value))
		switch {
		case (err != nil) != testCase.err:
			t.Errorf("%q: err = %v", testCase.value, err)
		case testCase.want == "" && got != nil:
			t.Errorf("%q: got %q", testCase.value, *got)
		case testCase.want != "" && (got == nil || *got != testCase.want):
			t.Errorf("%q: got %v", testCase.value, got)
		}
	}
	if got, err := safeCover(sql.NullString{}); got != nil || err != nil {
		t.Errorf("null cover = %v, %v", got, err)
	}
}

func TestProgressRepresentationDistinguishesNullFromZero(t *testing.T) {
	zero := 0.0
	body, err := progressRepresentation(store.Progress{
		AssetID: "a", UpdatedAt: "1969-12-31 23:59:59.999500", Version: 2, ClientMutationID: "m",
		PositionSeconds: sql.NullFloat64{Float64: zero, Valid: true}, Locator: text(`{"locations":{"progression":0.50,"position":3}}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	if body.PositionSeconds == nil || *body.PositionSeconds != 0 || body.ObservedAt != nil || body.UpdatedAt != "1969-12-31T23:59:59.999Z" {
		t.Fatalf("body = %+v", body)
	}
	if body.Locator == nil {
		t.Fatal("locator dropped")
	}
	empty, err := progressRepresentation(store.Progress{UpdatedAt: "2026-11-13 08:30:15"})
	if err != nil || empty.PositionSeconds != nil || empty.Locator != nil || empty.ObservedAt != nil {
		t.Fatalf("empty = %+v, %v", empty, err)
	}
	for _, broken := range []store.Progress{
		{UpdatedAt: "garbage"},
		{UpdatedAt: "2026-11-13 08:30:15", ObservedAt: text("garbage")},
		{UpdatedAt: "2026-11-13 08:30:15", Locator: text("{not json")},
	} {
		if _, err := progressRepresentation(broken); err == nil {
			t.Errorf("accepted %+v", broken)
		}
	}
}

func TestReadingStatusPrecedence(t *testing.T) {
	current := view{states: map[int64]int{1: 0, 2: 2, 3: 1}}
	cases := []struct {
		book        int64
		hasProgress bool
		want        string
	}{{1, true, "unread"}, {2, false, "finished"}, {3, false, "in_progress"}, {4, true, "in_progress"}, {4, false, "unread"}}
	for _, testCase := range cases {
		if got := current.readingStatus(testCase.book, testCase.hasProgress); got != testCase.want {
			t.Errorf("book %d progress %v = %q, want %q", testCase.book, testCase.hasProgress, got, testCase.want)
		}
	}
}

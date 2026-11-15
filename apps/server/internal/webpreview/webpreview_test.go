package webpreview

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/consumer"
)

func text(value string) *string { return &value }

func publication(t *testing.T, document string) consumer.Publication {
	t.Helper()
	decoder := json.NewDecoder(strings.NewReader(document))
	decoder.UseNumber()
	var found consumer.Publication
	if err := decoder.Decode(&found); err != nil {
		t.Fatal(err)
	}
	return found
}

func TestCoverStyleIsTheRailsFnvBucket(t *testing.T) {
	want := map[string]string{"1": "plum", "2": "moss", "10": "clay", "50": "plum", "9223372036854775807": "moss"}
	for id, style := range want {
		if got := coverStyle(id); got != style {
			t.Errorf("%s: %s want %s", id, got, style)
		}
	}
}

func TestPlainTextFollowsTheRailsNormalisationAndRefusesMarkup(t *testing.T) {
	good := map[string]string{"  a   b\t\tc \n\n\n\n d \n": "a b c\n\nd", "First line\nSecond": "First line\nSecond", "": ""}
	for input, want := range good {
		if got, err := PlainText(input); err != nil || got != want {
			t.Errorf("%q: %q %v", input, got, err)
		}
	}
	for _, input := range []string{"<p>x</p>", "a > b", "fish & chips", "a\r\nb", "nul\x00", "bell\x07"} {
		if _, err := PlainText(input); err == nil {
			t.Errorf("%q was accepted", input)
		}
	}
}

func TestProgressAndLabelsFollowTheRailsHelpers(t *testing.T) {
	cases := []struct {
		document string
		label    string
		fraction string
		status   string
	}{
		{`{"id":"1","title":"T","book_type":"ebook","assets":[{"id":"a","format":"epub"}],"reading_status":"unread","progress":null}`, "Start reading", "null", "unread"},
		{`{"id":"2","title":"T","book_type":"audiobook","assets":[{"id":"a","format":"mp3"}],"reading_status":"unread","progress":null}`, "Start listening", "null", "unread"},
		{`{"id":"3","title":"T","book_type":"ebook","assets":[],"reading_status":"unread","progress":null}`, "Files unavailable", "null", "unread"},
		{`{"id":"4","title":"T","book_type":"ebook","assets":[{"id":"a"}],"reading_status":"finished","progress":null}`, "Finished", "null", "finished"},
		{`{"id":"5","title":"T","book_type":"ebook","assets":[{"id":"a"}],"reading_status":"unread","progress":{"asset_id":"a","locator":null,"version":1,"updated_at":"x"}}`, "Unread · saved place kept", "null", "unread"},
		{`{"id":"6","title":"T","book_type":"ebook","assets":[{"id":"a"}],"reading_status":"in_progress","progress":{"asset_id":"zzz","locator":null,"version":1,"updated_at":"x"}}`, "New edition · start afresh", "null", "in_progress"},
		{`{"id":"7","title":"T","book_type":"audiobook","assets":[{"id":"a"}],"reading_status":"in_progress","progress":{"asset_id":"a","position_seconds":3725.9,"version":1,"updated_at":"x"}}`, "Resume at 1:02:05", "null", "in_progress"},
		{`{"id":"8","title":"T","book_type":"ebook","assets":[{"id":"a"}],"reading_status":"in_progress","progress":{"asset_id":"a","locator":{"locations":{"totalProgression":0.125}},"version":1,"updated_at":"x"}}`, "13% read", "0.125", "in_progress"},
		{`{"id":"9","title":"T","book_type":"ebook","assets":[{"id":"a"}],"reading_status":"in_progress","progress":{"asset_id":"a","locator":{"locations":{"totalProgression":7}},"version":1,"updated_at":"x"}}`, "700% read", "1", "in_progress"},
		{`{"id":"10","title":"T","book_type":"ebook","assets":[{"id":"a"}],"reading_status":"in_progress","progress":{"asset_id":"a","locator":{"href":"c.xhtml"},"version":1,"updated_at":"x"}}`, "Continue reading", "null", "in_progress"},
	}
	for _, test := range cases {
		summary, err := Project(publication(t, test.document))
		if err != nil {
			t.Fatalf("%s: %v", test.document, err)
		}
		fraction := "null"
		if summary.Progress != nil && summary.Progress.Fraction != nil {
			encoded, _ := json.Marshal(*summary.Progress.Fraction)
			fraction = string(encoded)
		}
		if summary.ProgressLabel != test.label || fraction != test.fraction || summary.ReadingStatus != test.status {
			t.Errorf("%s: label %q fraction %s", test.document, summary.ProgressLabel, fraction)
		}
	}
}

func TestStoredValuesTheHelpersCannotReadAreRefused(t *testing.T) {
	for _, document := range []string{
		`{"id":"1","title":"T","book_type":"ebook","assets":[{"id":"a"}],"reading_status":"in_progress","progress":{"asset_id":"a","locator":[1],"version":1,"updated_at":"x"}}`,
		`{"id":"1","title":"T","book_type":"ebook","assets":[{"id":"a"}],"reading_status":"in_progress","progress":{"asset_id":"a","locator":{"locations":"x"},"version":1,"updated_at":"x"}}`,
		`{"id":"1","title":"T","book_type":"ebook","assets":[{"id":"a"}],"reading_status":"in_progress","progress":{"asset_id":"a","locator":{"locations":{"totalProgression":"0.5"}},"version":1,"updated_at":"x"}}`,
	} {
		if _, err := Project(publication(t, document)); err == nil {
			t.Errorf("accepted %s", document)
		}
	}
}

func TestFormatLabelsAndAuthorPresence(t *testing.T) {
	kind := "graphic"
	cases := map[string]consumer.Publication{
		"Audiobook": {BookType: "audiobook"}, "Comic": {BookType: "ebook", ContentKind: &kind}, "Ebook": {BookType: "ebook"},
	}
	for want, item := range cases {
		if got := formatLabel(item); got != want {
			t.Errorf("%s: %s", want, got)
		}
	}
	if presence(text("  \t")) != nil || presence(text("A")) == nil || presence(nil) != nil {
		t.Fatal("author presence")
	}
}

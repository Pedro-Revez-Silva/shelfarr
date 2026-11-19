package admission

import (
	"errors"
	"reflect"
	"strings"
	"testing"
)

func text(value string) *string { return &value }

func number(value int64) *int64 { return &value }

func TestParseSubmissionKeepsOnlyNormalisedBoundedMetadata(t *testing.T) {
	body := `{"work_id":"openlibrary:OL45804W","book_type":"ebook","title":" \t Dune \r\n","author":"  Frank Herbert ","cover_url":"https://covers.example.test/b/id/1-L.jpg?size=L","year":1965,"language":" fr ","user_id":"2","username":"bob","source_work_ids":null,"author":"Frank Herbert"}`
	got, err := ParseSubmission([]byte(body))
	if err != nil {
		t.Fatal(err)
	}
	want := Submission{OpenLibraryWorkID: "OL45804W", Title: "Dune", Author: text("Frank Herbert"), CoverURL: text("https://covers.example.test/b/id/1-L.jpg?size=L"), Year: number(1965), Language: text("fr")}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestParseSubmissionMatchesTheConsumerRequestRules(t *testing.T) {
	base := `"work_id":"openlibrary:OL1W","book_type":"ebook"`
	long := strings.Repeat("é", textLimit)
	cases := []struct {
		name string
		body string
		want error
	}{
		{"not an object", `["openlibrary:OL1W"]`, ErrInvalid},
		{"malformed JSON", `{"work_id":`, ErrInvalid},
		{"trailing data", `{` + base + `,"title":"A"}}`, ErrInvalid},
		{"missing title", `{` + base + `}`, ErrInvalid},
		{"title only spaces", `{` + base + `,"title":" \t\n "}`, ErrInvalid},
		{"title only unicode spaces", `{` + base + `,"title":"　 "}`, ErrInvalid},
		{"title of 500 characters", `{` + base + `,"title":"` + long + `"}`, nil},
		{"title of 501 characters", `{` + base + `,"title":"` + long + `a"}`, ErrInvalid},
		{"title with NUL", `{` + base + `,"title":"A\u0000B"}`, ErrInvalid},
		{"numeric title", `{` + base + `,"title":5}`, ErrInvalid},
		{"author not text", `{` + base + `,"title":"A","author":["x"]}`, ErrInvalid},
		{"author too long", `{` + base + `,"title":"A","author":"` + long + `a"}`, ErrInvalid},
		{"language too long", `{` + base + `,"title":"A","language":"abcdefghijklmnopq"}`, ErrInvalid},
		{"year as float", `{` + base + `,"title":"A","year":1965.0}`, ErrInvalid},
		{"year as exponent", `{` + base + `,"title":"A","year":1e3}`, ErrInvalid},
		{"year as text", `{` + base + `,"title":"A","year":"1965"}`, ErrInvalid},
		{"year zero", `{` + base + `,"title":"A","year":0}`, ErrInvalid},
		{"year after 3000", `{` + base + `,"title":"A","year":3001}`, ErrInvalid},
		{"year beyond int64", `{` + base + `,"title":"A","year":99999999999999999999}`, ErrInvalid},
		{"year 3000", `{` + base + `,"title":"A","year":3000}`, nil},
		{"work id without source", `{"work_id":"OL1W","book_type":"ebook","title":"A"}`, ErrInvalid},
		{"work id with a space", `{"work_id":"openlibrary:OL1W x","book_type":"ebook","title":"A"}`, ErrInvalid},
		{"work id of 161 characters", `{"work_id":"openlibrary:` + strings.Repeat("é", 161) + `","book_type":"ebook","title":"A"}`, ErrInvalid},
		{"unknown book type", `{"work_id":"openlibrary:OL1W","book_type":"comicbook","title":"A"}`, ErrInvalid},
		{"sources not a list", `{` + base + `,"title":"A","source_work_ids":"hardcover:1"}`, ErrInvalid},
		{"malformed source", `{` + base + `,"title":"A","source_work_ids":["nope"]}`, ErrInvalid},
		{"21 sources", `{` + base + `,"title":"A","source_work_ids":[` + strings.TrimSuffix(strings.Repeat(`"hardcover:1",`, 21), ",") + `]}`, ErrInvalid},
		{"audiobook", `{"work_id":"openlibrary:OL1W","book_type":"audiobook","title":"A"}`, ErrUnsupported},
		{"another provider", `{"work_id":"hardcover:1","book_type":"ebook","title":"A"}`, ErrUnsupported},
		{"legacy-shaped open library id", `{"work_id":"openlibrary:OL1M","book_type":"ebook","title":"A"}`, ErrUnsupported},
		{"alias sources", `{` + base + `,"title":"A","source_work_ids":["hardcover:1"]}`, ErrUnsupported},
		{"empty sources", `{` + base + `,"title":"A","source_work_ids":[]}`, nil},
		{"oversized body", `{` + base + `,"title":"A","pad":"` + strings.Repeat("x", MaxBodyBytes) + `"}`, ErrInvalid},
	}
	for _, entry := range cases {
		t.Run(entry.name, func(t *testing.T) {
			_, err := ParseSubmission([]byte(entry.body))
			if !errors.Is(err, entry.want) || (entry.want == nil) != (err == nil) {
				t.Fatalf("got %v, want %v", err, entry.want)
			}
		})
	}
}

func TestParseSubmissionKeepsOnlyCoversRailsWouldStoreUnchanged(t *testing.T) {
	cases := map[string]bool{
		"https://covers.example.test/a.jpg":             true,
		"https://covers.example.test":                   true,
		"https://covers.example.test?x=1":               true,
		"https://covers.example.test/a%20b.jpg":         true,
		"http://covers.example.test/a.jpg":              false,
		"HTTPS://covers.example.test/a.jpg":             false,
		"https://user:secret@covers.example.test/a.jpg": false,
		"https://covers.example.test:443/a.jpg":         false,
		"https://covers.example.test/a b.jpg":           false,
		"https://covers.example.test/a%zz.jpg":          false,
		"https://covers.example.test/a.jpg#fragment":    false,
		"https:///a.jpg":                                false,
		"https://covers.example.test/café.jpg":          false,
		"javascript:alert(1)":                           false,
		"//covers.example.test/a.jpg":                   false,
		"https://-covers.example.test/a.jpg":            false,
	}
	for cover, kept := range cases {
		body := `{"work_id":"openlibrary:OL1W","book_type":"ebook","title":"A","cover_url":` + quoteJSON(cover) + `}`
		got, err := ParseSubmission([]byte(body))
		if err != nil {
			t.Fatalf("%q: %v", cover, err)
		}
		if (got.CoverURL != nil) != kept || (kept && *got.CoverURL != cover) {
			t.Errorf("%q: kept %v, want %v", cover, got.CoverURL, kept)
		}
	}
}

func quoteJSON(value string) string {
	return `"` + strings.ReplaceAll(value, `"`, `\"`) + `"`
}

package gutenberg

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/netguard"
)

const feedHead = `<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:opds="http://opds-spec.org/">`

func listingEntry(id string) string {
	return `<entry><title>Book ` + id + `</title><id>https://www.gutenberg.org/ebooks/` + id + `.opds</id>
<link type="application/atom+xml;profile=opds-catalog" rel="subsection" href="/ebooks/` + id + `.opds"/></entry>`
}

func detailEntry(id, language, links string) string {
	return `<entry><title> Book ` + id + ` </title><id>urn:gutenberg:` + id + `:2</id><author><name> Author ` + id + ` </name></author>
<dcterms:language>` + language + `</dcterms:language>` + links + `</entry>`
}

func acquisition(mime, title, href string) string {
	return `<link type="` + mime + `" rel="http://opds-spec.org/acquisition" title="` + title + `" href="` + href + `"/>`
}

func testOrigin(t *testing.T) Origin {
	t.Helper()
	origin, err := ParseOrigin("http://127.0.0.1:8080")
	if err != nil {
		t.Fatal(err)
	}
	return origin
}

func TestListingsFollowTheRailsSelection(t *testing.T) {
	body := feedHead + `<link rel="next" href="/ebooks/search.opds/?start_index=26"/>
<entry><title>Sort Alphabetically</title><id>https://www.gutenberg.org/ebooks/search.opds/?sort_order=title</id>
<link rel="subsection" href="/ebooks/search.opds/?sort_order=title"/></entry>` +
		listingEntry("1342") + listingEntry("84") + listingEntry("1342") +
		`<entry><id>urn:gutenberg:11</id></entry>
<entry><link rel="subsection"/><link rel="subsection" href="/ebooks/98.opds"/><id>urn:gutenberg:2701</id></entry>
<entry><link rel="subsection" href="  "/><id>https://www.gutenberg.org/ebooks/1661.opds</id></entry>
<entry><title>No identifier</title></entry></feed>`
	listings, next, err := parseListings([]byte(body))
	if err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, listing := range listings {
		ids = append(ids, listing.id)
	}
	if want := []string{"1342", "84", "11", "98", "1661"}; !reflect.DeepEqual(ids, want) || !next {
		t.Errorf("ids %v next %v, want %v and a next page", ids, next, want)
	}
}

func TestDetailChoosesTheBestFormatOfTheBestEntry(t *testing.T) {
	origin := testOrigin(t)
	body := feedHead + detailEntry("1342", " EN ",
		acquisition("application/epub+zip", "EPUB (older E-readers)", "/ebooks/1342.epub.images")+
			acquisition("application/epub+zip", "EPUB3 (E-readers incl. Send-to-Kindle)", " /ebooks/1342.epub3.images ")+
			acquisition("application/epub+zip", "EPUB (no images, older E-readers)", "/ebooks/1342.epub.noimages")+
			acquisition("application/x-mobipocket-ebook", "Kindle", "/ebooks/1342.kf8.images")+
			acquisition("text/plain; charset=utf-8", "Plain Text", "/ebooks/1342.txt.utf-8")) +
		`<entry><title>Readers also downloaded</title><id>urn:gutenberg:1342:related</id><link rel="related" href="/ebooks/1342/also/"/></entry></feed>`
	parsed, err := parseDetail([]byte(body), "1342", "en", origin)
	if err != nil {
		t.Fatal(err)
	}
	want := Candidate{ID: "1342", Title: "Book 1342", Author: "Author 1342", Language: "en", FileType: "epub",
		DownloadURL: "http://127.0.0.1:8080/ebooks/1342.epub3.images", InfoURL: "http://127.0.0.1:8080/ebooks/1342"}
	if parsed.withheld || parsed.candidate == nil || *parsed.candidate != want {
		t.Fatalf("got %+v", parsed)
	}
	if title := parsed.candidate.ResultTitle(); title != "Book 1342 - Author 1342 [EPUB] [English]" {
		t.Errorf("result title %q", title)
	}
}

func TestDetailHonoursTheRequestedLanguageAndTies(t *testing.T) {
	origin := testOrigin(t)
	body := feedHead +
		detailEntry("10", "fr", acquisition("application/epub+zip", "EPUB3", "/ebooks/10.epub3")) +
		detailEntry("11", "", acquisition("application/epub+zip", "EPUB", "/ebooks/11.first.epub")+acquisition("application/epub+zip", "EPUB", "/ebooks/11.second.epub")) +
		detailEntry("12", "en", acquisition("application/epub+zip", "EPUB", "/ebooks/12.epub")) + `</feed>`
	parsed, err := parseDetail([]byte(body), "99", "en", origin)
	if err != nil || parsed.candidate == nil {
		t.Fatalf("%+v %v", parsed, err)
	}
	if parsed.candidate.ID != "11" || parsed.candidate.DownloadURL != "http://127.0.0.1:8080/ebooks/11.first.epub" || parsed.candidate.Language != "" {
		t.Errorf("got %+v", parsed.candidate)
	}
	if title := parsed.candidate.ResultTitle(); title != "Book 11 - Author 11 [EPUB]" {
		t.Errorf("result title %q", title)
	}
	anyLanguage, err := parseDetail([]byte(body), "99", " ", origin)
	if err != nil || anyLanguage.candidate == nil || anyLanguage.candidate.ID != "10" {
		t.Errorf("a blank requested language must not filter: %+v %v", anyLanguage, err)
	}
}

func TestDetailFallsBackToTheListingIdentifier(t *testing.T) {
	body := feedHead + `<entry><title>Untitled</title>` + acquisition("application/epub+zip", "EPUB", "/ebooks/7.epub") + `</entry></feed>`
	parsed, err := parseDetail([]byte(body), "7", "en", testOrigin(t))
	if err != nil || parsed.candidate == nil || parsed.candidate.ID != "7" || parsed.candidate.Author != "" || parsed.candidate.ResultTitle() != "Untitled [EPUB]" {
		t.Fatalf("%+v %v", parsed.candidate, err)
	}
}

func TestDetailWithholdsWhatThisSliceDoesNotStore(t *testing.T) {
	origin := testOrigin(t)
	for name, links := range map[string]string{
		"kindle only":       acquisition("application/x-mobipocket-ebook", "Kindle", "/ebooks/5.kf8"),
		"pdf beats nothing": acquisition("application/pdf", "PDF", "/ebooks/5.pdf"),
		"another origin":    acquisition("application/epub+zip", "EPUB3", "https://mirror.example/ebooks/5.epub3"),
		"protocol relative": acquisition("application/epub+zip", "EPUB3", "//mirror.example/ebooks/5.epub3"),
		"dot segments":      acquisition("application/epub+zip", "EPUB3", "/ebooks/../admin/5.epub3"),
		"encoded dots":      acquisition("application/epub+zip", "EPUB3", "/ebooks/%2E%2E/5.epub3"),
		"query":             acquisition("application/epub+zip", "EPUB3", "/ebooks/5.epub3?mirror=1"),
		"javascript":        acquisition("application/epub+zip", "EPUB3", "javascript:alert(1)"),
		"relative":          acquisition("application/epub+zip", "EPUB3", "ebooks/5.epub3"),
	} {
		parsed, err := parseDetail([]byte(feedHead+detailEntry("5", "en", links)+`</feed>`), "5", "en", origin)
		if err != nil || !parsed.withheld || parsed.candidate != nil {
			t.Errorf("%s: %+v %v", name, parsed, err)
		}
	}
	none, err := parseDetail([]byte(feedHead+detailEntry("5", "en", acquisition("text/html", "Read online", "/ebooks/5.html.images"))+`</feed>`), "5", "en", origin)
	if err != nil || none.withheld || none.candidate != nil {
		t.Errorf("an entry without a downloadable format is neither a candidate nor withheld: %+v %v", none, err)
	}
	sameOrigin, err := parseDetail([]byte(feedHead+detailEntry("5", "en", acquisition("application/epub+zip", "EPUB", "http://127.0.0.1:8080/ebooks/5 copy.epub"))+`</feed>`), "5", "en", origin)
	if err != nil || sameOrigin.candidate == nil || sameOrigin.candidate.DownloadURL != "http://127.0.0.1:8080/ebooks/5%20copy.epub" {
		t.Errorf("an absolute same-origin link is kept: %+v %v", sameOrigin, err)
	}
}

func TestDocumentsAreParsedWithoutExternalResources(t *testing.T) {
	for name, body := range map[string]string{
		"external entity":                `<?xml version="1.0"?><!DOCTYPE feed [<!ENTITY x SYSTEM "file:///etc/passwd">]><feed><entry><id>&x;</id></entry></feed>`,
		"internal entity":                `<?xml version="1.0"?><!DOCTYPE feed [<!ENTITY x "ebooks/1">]><feed><entry><id>&x;</id></entry></feed>`,
		"truncated":                      feedHead + listingEntry("1342"),
		"two roots":                      `<feed></feed><feed></feed>`,
		"not utf-8":                      "<feed><entry><id>urn:gutenberg:1\xff</id></entry></feed>",
		"empty":                          ``,
		"html":                           `<html><body><p>Service unavailable<br></body></html>`,
		"balanced html":                  `<html><body><p>Down for maintenance</p></body></html>`,
		"text after feed":                feedHead + listingEntry("1342") + `</feed>Service unavailable`,
		"text before feed":               `maintenance` + feedHead + `</feed>`,
		"another namespace":              `<rss:feed xmlns:rss="urn:example:status"><rss:error>Maintenance</rss:error></rss:feed>`,
		"no namespace":                   `<feed><entry><id>urn:gutenberg:1</id></entry></feed>`,
		"space after feed":               feedHead + `</feed>` + "\u00a0",
		"escaped space after feed":       feedHead + `</feed>&#x20;`,
		"cdata after feed":               "\ufeff" + feedHead + `</feed><![CDATA[ ]]>`,
		"escaped space after a bom feed": "\ufeff" + feedHead + `</feed>&#x20;`,
		"too many":                       feedHead + strings.Repeat(listingEntry("1"), maxEntries+1) + `</feed>`,
		"too deep":                       strings.Repeat("<a>", maxDepth+1) + strings.Repeat("</a>", maxDepth+1),
		"huge identifier":                feedHead + listingEntry("1234567890123") + `</feed>`,
	} {
		if _, _, err := parseListings([]byte(body)); !errors.Is(err, errMalformed) {
			t.Errorf("%s: %v", name, err)
		}
	}
}

func TestOnlyAtomLinksAnnounceAnotherPage(t *testing.T) {
	origin := testOrigin(t)
	french := detailEntry("1", "fr", acquisition("application/epub+zip", "EPUB", "/ebooks/1.epub"))
	for links, want := range map[string]bool{
		`<link rel="next" href="/ebooks/1.opds?start_index=2"/>`:                        true,
		`<x:link xmlns:x="urn:example:other" rel="next" href="/next"/>`:                 false,
		`<link xmlns:x="urn:example:other" x:rel="next" href="/next"/>`:                 false,
		`<link xmlns:x="urn:example:other" x:rel="alternate" rel="next" href="/next"/>`: true,
		`<link xmlns:x="urn:example:other" rel="alternate" x:rel="next" href="/next"/>`: false,
	} {
		parsed, err := parseDetail([]byte(feedHead+links+french+`</feed>`), "1", "en", origin)
		if err != nil || parsed.candidate != nil || parsed.nextPage != want {
			t.Errorf("%s: next page %v, want %v (%v)", links, parsed.nextPage, want, err)
		}
	}
	foreignLanguage := strings.Replace(french, "<dcterms:language>fr</dcterms:language>", `<x:language xmlns:x="urn:example:other">fr</x:language>`, 1)
	if parsed, err := parseDetail([]byte(feedHead+foreignLanguage+`</feed>`), "1", "en", origin); err != nil || parsed.candidate == nil || parsed.candidate.Language != "" {
		t.Errorf("a language outside Dublin Core terms is not the entry's language: %+v %v", parsed, err)
	}
}

func TestAByteOrderMarkIsAllowed(t *testing.T) {
	listings, _, err := parseListings([]byte("\ufeff" + feedHead + listingEntry("1342") + "</feed>\n"))
	if err != nil || len(listings) != 1 || listings[0].id != "1342" {
		t.Errorf("%v %v", listings, err)
	}
}

func TestOriginsFollowTheRailsSettingRules(t *testing.T) {
	for raw, want := range map[string]string{
		" http://127.0.0.1:8080/ ":  "http://127.0.0.1:8080",
		"http://127.0.0.1:80":       "http://127.0.0.1",
		"https://[::1]:443":         "https://[::1]",
		"https://[::1]:8443":        "https://[::1]:8443",
		"https://www.gutenberg.org": "https://www.gutenberg.org",
	} {
		origin, err := ParseOrigin(raw)
		if err != nil || origin.String() != want {
			t.Errorf("%q: %q %v, want %q", raw, origin.String(), err, want)
		}
	}
	for _, raw := range []string{"", "ftp://127.0.0.1", "http://", "http://127.0.0.1/catalog", "http://127.0.0.1/?x=1", "http://127.0.0.1/#top", "http://user:pass@127.0.0.1", "127.0.0.1:8080", "http://127.0.0.1:0", "http://127.0.0.1:70000"} {
		if _, err := ParseOrigin(raw); !errors.Is(err, ErrOrigin) {
			t.Errorf("%q accepted", raw)
		}
	}
	for raw, loopback := range map[string]bool{"http://127.0.0.1:1": true, "http://127.9.9.9": true, "http://[::1]:1": true, "http://localhost:1": false, "https://www.gutenberg.org": false, "http://10.0.0.1": false} {
		origin, _ := ParseOrigin(raw)
		if origin.Loopback() != loopback {
			t.Errorf("%q loopback %v", raw, origin.Loopback())
		}
	}
}

type catalogue struct {
	mutex    sync.Mutex
	paths    []string
	queries  []string
	handlers map[string]func(http.ResponseWriter, *http.Request)
}

func (c *catalogue) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	c.mutex.Lock()
	c.paths = append(c.paths, request.URL.Path)
	c.queries = append(c.queries, request.URL.Query().Get("query"))
	handler := c.handlers[request.URL.Path]
	c.mutex.Unlock()
	if handler == nil {
		http.NotFound(writer, request)
		return
	}
	handler(writer, request)
}

func reply(status int, body string) func(http.ResponseWriter, *http.Request) {
	return func(writer http.ResponseWriter, _ *http.Request) {
		writer.WriteHeader(status)
		writer.Write([]byte(body))
	}
}

func serve(t *testing.T, handlers map[string]func(http.ResponseWriter, *http.Request)) (*catalogue, *Client) {
	t.Helper()
	fake := &catalogue{handlers: handlers}
	server := httptest.NewServer(fake)
	t.Cleanup(server.Close)
	origin, err := ParseOrigin(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	return fake, &Client{Origin: origin, HTTP: netguard.NewClient(time.Second), RequestTimeout: 500 * time.Millisecond}
}

func TestSearchStopsAtTheFirstTitleWithResults(t *testing.T) {
	empty := feedHead + `</feed>`
	fake, client := serve(t, map[string]func(http.ResponseWriter, *http.Request){
		"/ebooks/search.opds/": func(writer http.ResponseWriter, request *http.Request) {
			if request.URL.Query().Get("query") == "The Little Prince Antoine de Saint-Exupéry" {
				writer.Write([]byte(feedHead + listingEntry("1") + listingEntry("2") + listingEntry("3") + listingEntry("4") + `</feed>`))
				return
			}
			writer.Write([]byte(empty))
		},
		"/ebooks/1.opds": reply(200, feedHead+detailEntry("1", "en", acquisition("application/epub+zip", "EPUB", "/ebooks/1.epub"))+`</feed>`),
		"/ebooks/2.opds": reply(200, feedHead+detailEntry("2", "en", acquisition("application/x-mobipocket-ebook", "Kindle", "/ebooks/2.kf8"))+`</feed>`),
		"/ebooks/3.opds": reply(404, "missing"),
	})
	beats := 0
	client.Heartbeat = func(context.Context) error { beats++; return nil }
	result, err := client.Search(context.Background(), Query{Titles: []string{"Le Petit Prince", "The Little Prince", "Le Petit Prince / The Little Prince"}, Author: "Antoine de Saint-Exupéry", Language: "en", Limit: 3})
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Candidates) != 1 || result.Candidates[0].ID != "1" || result.Withheld != 1 || result.Requests != 5 || beats != 5 {
		t.Errorf("result %+v beats %d", result, beats)
	}
	wantQueries := []string{"Le Petit Prince Antoine de Saint-Exupéry", "The Little Prince Antoine de Saint-Exupéry", "", "", ""}
	if !reflect.DeepEqual(fake.queries, wantQueries) || fake.paths[4] != "/ebooks/3.opds" {
		t.Errorf("paths %v queries %q", fake.paths, fake.queries)
	}
}

func TestProviderAnswersAreClassified(t *testing.T) {
	slow := func(writer http.ResponseWriter, request *http.Request) {
		select {
		case <-request.Context().Done():
		case <-time.After(5 * time.Second):
		}
	}
	listing := feedHead + listingEntry("1") + `</feed>`
	for name, test := range map[string]struct {
		search, detail func(http.ResponseWriter, *http.Request)
		code           string
		transient      bool
	}{
		"search unavailable": {search: reply(503, ""), code: CodeBusy, transient: true},
		"rate limited":       {search: reply(429, ""), code: CodeBusy, transient: true},
		"timeout":            {search: slow, code: CodeTimeout, transient: true},
		"partial":            {search: reply(200, listing), detail: reply(500, ""), code: CodeBusy, transient: true},
		"detail timeout":     {search: reply(200, listing), detail: slow, code: CodeTimeout, transient: true},
		"redirect": {search: func(writer http.ResponseWriter, request *http.Request) {
			http.Redirect(writer, request, "http://127.0.0.2/", http.StatusFound)
		}, code: CodeRefused},
		"forbidden":        {search: reply(403, ""), code: CodeRefused},
		"malformed":        {search: reply(200, "<feed><entry>"), code: CodeMalformed},
		"malformed detail": {search: reply(200, listing), detail: reply(200, "<html>"), code: CodeMalformed},
		"html detail":      {search: reply(200, listing), detail: reply(200, "<html><body><p>Down</p></body></html>"), code: CodeMalformed},
		"too large":        {search: reply(200, feedHead+strings.Repeat(" ", MaxResponseBytes)+`</feed>`), code: CodeTooLarge},
		"next page only":   {search: reply(200, feedHead+`<link rel="next" href="/ebooks/search.opds/?start_index=26"/></feed>`), code: CodePagination},
	} {
		t.Run(name, func(t *testing.T) {
			handlers := map[string]func(http.ResponseWriter, *http.Request){"/ebooks/search.opds/": test.search}
			if test.detail != nil {
				handlers["/ebooks/1.opds"] = test.detail
			}
			_, client := serve(t, handlers)
			_, err := client.Search(context.Background(), Query{Titles: []string{"Title"}, Limit: 10})
			var provider *Error
			if !errors.As(err, &provider) || provider.Code != test.code || provider.Transient != test.transient {
				t.Errorf("got %v, want %s transient %v", err, test.code, test.transient)
			}
		})
	}
}

func TestUnreadListingsAreNotNoResults(t *testing.T) {
	french := func(id string) string {
		return feedHead + detailEntry(id, "fr", acquisition("application/epub+zip", "EPUB", "/ebooks/"+id+".epub")) + `</feed>`
	}
	handlers := map[string]func(http.ResponseWriter, *http.Request){
		"/ebooks/search.opds/": func(writer http.ResponseWriter, request *http.Request) {
			if strings.HasPrefix(request.URL.Query().Get("query"), "Second") {
				writer.Write([]byte(feedHead + listingEntry("9") + `</feed>`))
				return
			}
			writer.Write([]byte(feedHead + listingEntry("1") + listingEntry("2") + listingEntry("3") + `</feed>`))
		},
		"/ebooks/1.opds": reply(200, french("1")),
		"/ebooks/2.opds": reply(200, french("2")),
		"/ebooks/3.opds": reply(200, french("3")),
		"/ebooks/9.opds": reply(200, feedHead+detailEntry("9", "en", acquisition("application/epub+zip", "EPUB", "/ebooks/9.epub"))+`</feed>`),
	}
	fake, client := serve(t, handlers)
	_, err := client.Search(context.Background(), Query{Titles: []string{"First"}, Language: "en", Limit: 2})
	var provider *Error
	if !errors.As(err, &provider) || provider.Code != CodePagination || len(fake.paths) != 3 {
		t.Errorf("listings beyond the limit with nothing valid: %v after %v", err, fake.paths)
	}
	result, err := client.Search(context.Background(), Query{Titles: []string{"First", "Second"}, Language: "en", Limit: 2})
	if err != nil || len(result.Candidates) != 1 || result.Candidates[0].ID != "9" {
		t.Errorf("a later title with results wins over an unread earlier page: %+v %v", result, err)
	}
	paged, pagedClient := serve(t, map[string]func(http.ResponseWriter, *http.Request){
		"/ebooks/search.opds/": reply(200, feedHead+listingEntry("1")+`</feed>`),
		"/ebooks/1.opds":       reply(200, strings.Replace(french("1"), "<entry>", `<link rel="next" href="/ebooks/1.opds?start_index=2"/><entry>`, 1)),
	})
	if _, err := pagedClient.Search(context.Background(), Query{Titles: []string{"First"}, Language: "en", Limit: 2}); !errors.As(err, &provider) || provider.Code != CodePagination || len(paged.paths) != 2 {
		t.Errorf("a book page with an unread next page and nothing valid: %v after %v", err, paged.paths)
	}
	complete, err := client.Search(context.Background(), Query{Titles: []string{"First"}, Language: "en", Limit: 3})
	if err != nil || len(complete.Candidates) != 0 || complete.Withheld != 0 {
		t.Errorf("a fully read page with nothing valid is no results: %+v %v", complete, err)
	}
}

func TestEmptyAnswersAreNotFailures(t *testing.T) {
	for name, search := range map[string]func(http.ResponseWriter, *http.Request){
		"no entries": reply(200, feedHead+`</feed>`),
		"not found":  reply(404, ""),
	} {
		_, client := serve(t, map[string]func(http.ResponseWriter, *http.Request){"/ebooks/search.opds/": search})
		result, err := client.Search(context.Background(), Query{Titles: []string{"Title"}, Limit: 10})
		if err != nil || len(result.Candidates) != 0 || result.Withheld != 0 || result.Requests != 1 {
			t.Errorf("%s: %+v %v", name, result, err)
		}
	}
}

func TestTheLimitAndTheHeartbeatBoundTheSearch(t *testing.T) {
	var entries strings.Builder
	handlers := map[string]func(http.ResponseWriter, *http.Request){}
	for id := 1; id <= 40; id++ {
		text := strconv.Itoa(id)
		entries.WriteString(listingEntry(text))
		handlers["/ebooks/"+text+".opds"] = reply(200, feedHead+detailEntry(text, "en", acquisition("application/epub+zip", "EPUB", "/ebooks/"+text+".epub"))+`</feed>`)
	}
	handlers["/ebooks/search.opds/"] = reply(200, feedHead+entries.String()+`</feed>`)
	fake, client := serve(t, handlers)
	result, err := client.Search(context.Background(), Query{Titles: []string{"Title"}, Limit: 99})
	if err != nil || len(result.Candidates) != MaxLimit || len(fake.paths) != 1+MaxLimit {
		t.Fatalf("%d candidates over %d requests: %v", len(result.Candidates), len(fake.paths), err)
	}
	stop := errors.New("superseded")
	beats := 0
	client.Heartbeat = func(context.Context) error {
		if beats++; beats == 3 {
			return stop
		}
		return nil
	}
	fake.paths = nil
	if _, err := client.Search(context.Background(), Query{Titles: []string{"Title"}, Limit: 10}); !errors.Is(err, stop) || len(fake.paths) != 3 {
		t.Errorf("a failed heartbeat must stop before the next request: %v after %d requests", err, len(fake.paths))
	}
}

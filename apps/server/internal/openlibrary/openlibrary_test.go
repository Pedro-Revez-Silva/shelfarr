package openlibrary

import (
	"context"
	"errors"
	"io"
	"net/http"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type roundTrip func(*http.Request) (*http.Response, error)

func (f roundTrip) RoundTrip(request *http.Request) (*http.Response, error) { return f(request) }

type testClock struct {
	mutex sync.Mutex
	value time.Time
}

func (c *testClock) now() time.Time {
	c.mutex.Lock()
	defer c.mutex.Unlock()
	return c.value
}

func (c *testClock) advance(by time.Duration) {
	c.mutex.Lock()
	defer c.mutex.Unlock()
	c.value = c.value.Add(by)
}

func answer(status int, contentType, body string, headers ...string) *http.Response {
	header := http.Header{}
	if contentType != "" {
		header.Set("Content-Type", contentType)
	}
	for index := 0; index+1 < len(headers); index += 2 {
		header.Set(headers[index], headers[index+1])
	}
	return &http.Response{StatusCode: status, Header: header, Body: io.NopCloser(strings.NewReader(body))}
}

func newClient(transport roundTrip) (*Client, *testClock) {
	moment := &testClock{value: time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)}
	return New("Shelfarr/test", transport, moment.now), moment
}

const recorded = `{"numFound":3,"start":0,"numFoundExact":true,"docs":[
{"key":"/works/OL27448W","title":"The Lord of the Rings","author_name":["J.R.R. Tolkien","Someone Else"],"first_publish_year":1954,"cover_i":14625765,"edition_count":256},
{"key":"/works/OL82563W","title":"Harry  Potter\nand the Philosopher's Stone","author_name":[],"first_publish_year":"1997","cover_i":-1,"edition_count":3.5},
{"key":"/works/OL27448W","title":"Duplicate key keeps the first","author_name":["Nobody"]},
{"key":"/books/OL1M","title":"An edition, not a work"},
{"key":"/works/OL0W","title":"A zero work number"},
{"key":"/works/OL5W","title":"   "},
{"key":"/works/OL6W","title":12},
{"key":["/works/OL7W"],"title":"A list key"},
{"key":"/works/OL8W","title":"Typed oddly","author_name":"Not a list","first_publish_year":1e3,"cover_i":"12","edition_count":-1},
{"key":"/works/OL9W","title":"Author is not text","author_name":[42,"Second"],"first_publish_year":10000,"cover_i":9007199254740993,"edition_count":0},
"not an object",
{"key":"/works/OL10W","title":"Tail","author_name":["\u0007Bell\u0000Author  "],"first_publish_year":1}
],"q":"anything"}`

func TestSearchSendsOneFixedHTTPSRequestAndProjectsOnlyTheFieldsItAccepts(t *testing.T) {
	var seen []*http.Request
	client, _ := newClient(func(request *http.Request) (*http.Response, error) {
		seen = append(seen, request)
		return answer(http.StatusOK, "application/json; charset=utf-8", recorded), nil
	})
	works, err := client.Search(context.Background(), "tolkien & rings/../?x=1#frag", 12)
	if err != nil {
		t.Fatal(err)
	}
	if len(seen) != 1 {
		t.Fatalf("requests %d", len(seen))
	}
	request := seen[0]
	if request.Method != http.MethodGet || request.URL.String() != "https://openlibrary.org/search.json?fields=key%2Ctitle%2Cauthor_name%2Cfirst_publish_year%2Ccover_i%2Cedition_count&limit=12&q=tolkien+%26+rings%2F..%2F%3Fx%3D1%23frag" {
		t.Fatalf("request %s %s", request.Method, request.URL)
	}
	want := http.Header{"Accept": {"application/json"}, "User-Agent": {"Shelfarr/test"}}
	if !reflect.DeepEqual(request.Header, want) {
		t.Fatalf("headers %v", request.Header)
	}
	wanted := []Work{
		{ID: "OL27448W", Title: "The Lord of the Rings", Author: "J.R.R. Tolkien", FirstPublishYear: 1954, CoverID: 14625765, EditionCount: 256, HasEditionCount: true},
		{ID: "OL82563W", Title: "Harry Potter and the Philosopher's Stone"},
		{ID: "OL8W", Title: "Typed oddly"},
		{ID: "OL9W", Title: "Author is not text", EditionCount: 0, HasEditionCount: true},
		{ID: "OL10W", Title: "Tail", Author: "Bell Author", FirstPublishYear: 1},
	}
	if !reflect.DeepEqual(works, wanted) {
		t.Fatalf("works\n got %#v\nwant %#v", works, wanted)
	}
	if works[0].CoverURL() != "https://covers.openlibrary.org/b/id/14625765-M.jpg" || works[1].CoverURL() != "" || works[0].SourceURL() != "https://openlibrary.org/works/OL27448W" {
		t.Fatalf("links %q %q %q", works[0].CoverURL(), works[1].CoverURL(), works[0].SourceURL())
	}
}

func TestTheResultLimitIsClampedAndExtraDocumentsAreDropped(t *testing.T) {
	limits := []string{}
	client, moment := newClient(func(request *http.Request) (*http.Response, error) {
		limits = append(limits, request.URL.Query().Get("limit"))
		return answer(http.StatusOK, "application/json", recorded), nil
	})
	for _, limit := range []int{0, -5, 21, 400} {
		if _, err := client.Search(context.Background(), "x", limit); err != nil {
			t.Fatal(err)
		}
		moment.advance(MinimumInterval)
	}
	if !reflect.DeepEqual(limits, []string{"1", "1", "20", "20"}) {
		t.Fatalf("limits %v", limits)
	}
	works, err := client.Search(context.Background(), "x", 2)
	if err != nil || len(works) != 2 || works[1].ID != "OL82563W" {
		t.Fatalf("two %v %v", works, err)
	}
}

func TestUnacceptableAnswersAreFailuresAndNothingIsFollowed(t *testing.T) {
	cases := map[string]*http.Response{
		"server error":      answer(http.StatusInternalServerError, "application/json", `{"docs":[]}`),
		"not found":         answer(http.StatusNotFound, "application/json", `{"docs":[]}`),
		"redirect":          answer(http.StatusFound, "text/html", "", "Location", "http://127.0.0.1:1/steal"),
		"permanent":         answer(http.StatusPermanentRedirect, "", "", "Location", "https://openlibrary.org/search.json?q=other"),
		"html":              answer(http.StatusOK, "text/html", `<html>{"docs":[]}</html>`),
		"no content type":   answer(http.StatusOK, "", `{"docs":[]}`),
		"not json":          answer(http.StatusOK, "application/json", `{"docs":[`),
		"array":             answer(http.StatusOK, "application/json", `[]`),
		"null":              answer(http.StatusOK, "application/json", `null`),
		"docs not a list":   answer(http.StatusOK, "application/json", `{"docs":{"key":"/works/OL1W"}}`),
		"trailing data":     answer(http.StatusOK, "application/json", `{"docs":[]} {}`),
		"just over a limit": answer(http.StatusOK, "application/json", `{"docs":[],"pad":"`+strings.Repeat("a", MaxResponseBytes-19)+`"}`),
	}
	for name, response := range cases {
		calls := 0
		client, _ := newClient(func(request *http.Request) (*http.Response, error) {
			calls++
			if request.URL.Host != "openlibrary.org" {
				t.Fatalf("%s followed to %s", name, request.URL)
			}
			return response, nil
		})
		works, err := client.Search(context.Background(), "dune", 5)
		if !errors.Is(err, ErrFailed) || works != nil || calls != 1 {
			t.Fatalf("%s: %v %v calls %d", name, works, err, calls)
		}
	}
}

func TestAnAnswerAtTheSizeLimitAndAnAnswerWithoutDocsAreAccepted(t *testing.T) {
	exact := `{"docs":[],"pad":"` + strings.Repeat("a", MaxResponseBytes-20) + `"}`
	if len(exact) != MaxResponseBytes {
		t.Fatalf("fixture is %d bytes", len(exact))
	}
	for _, body := range []string{exact, `{"numFound":0}`, `{"docs":null}`} {
		client, _ := newClient(func(*http.Request) (*http.Response, error) {
			return answer(http.StatusOK, "application/json", body), nil
		})
		works, err := client.Search(context.Background(), "dune", 5)
		if err != nil || works == nil || len(works) != 0 {
			t.Fatalf("%d bytes: %v %v", len(body), works, err)
		}
	}
}

func TestTransportFailuresAreUnavailableAndACallerCancellationIsReportedAsSuch(t *testing.T) {
	client, _ := newClient(func(*http.Request) (*http.Response, error) { return nil, errors.New("dial tcp: connection refused") })
	if _, err := client.Search(context.Background(), "dune", 5); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("refused %v", err)
	}
	started := make(chan struct{})
	client, _ = newClient(func(request *http.Request) (*http.Response, error) {
		close(started)
		<-request.Context().Done()
		return nil, request.Context().Err()
	})
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		<-started
		cancel()
	}()
	if _, err := client.Search(ctx, "dune", 5); !errors.Is(err, context.Canceled) || errors.Is(err, ErrUnavailable) {
		t.Fatalf("cancelled %v", err)
	}
}

func TestASlowUpstreamIsCutOffByTheSearchDeadline(t *testing.T) {
	client, _ := newClient(func(request *http.Request) (*http.Response, error) {
		<-request.Context().Done()
		return nil, request.Context().Err()
	})
	client.timeout = 30 * time.Millisecond
	started := time.Now()
	_, err := client.Search(context.Background(), "dune", 5)
	if !errors.Is(err, ErrUnavailable) || time.Since(started) > 5*time.Second {
		t.Fatalf("slow %v after %v", err, time.Since(started))
	}
	if SearchTimeout != 8*time.Second || New("x", nil, nil).timeout != SearchTimeout {
		t.Fatalf("production deadline %v", SearchTimeout)
	}
}

type stalledBody struct{ ctx context.Context }

func (b stalledBody) Read([]byte) (int, error) {
	<-b.ctx.Done()
	return 0, b.ctx.Err()
}

func (b stalledBody) Close() error { return nil }

func TestABodyThatStallsIsCutOffByTheSearchDeadline(t *testing.T) {
	client, _ := newClient(func(request *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: http.StatusOK, Header: http.Header{"Content-Type": {"application/json"}}, Body: stalledBody{request.Context()}}, nil
	})
	client.timeout = 30 * time.Millisecond
	if _, err := client.Search(context.Background(), "dune", 5); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("stalled body %v", err)
	}
}

func TestTooManyRequestsPausesEverySearchWithoutContactingOpenLibrary(t *testing.T) {
	var calls atomic.Int32
	retryAfter := "120"
	client, moment := newClient(func(*http.Request) (*http.Response, error) {
		calls.Add(1)
		return answer(http.StatusTooManyRequests, "text/plain", "slow down", "Retry-After", retryAfter), nil
	})
	var throttled Throttled
	if _, err := client.Search(context.Background(), "dune", 5); !errors.As(err, &throttled) || !throttled.Upstream || throttled.RetryAfter != 120*time.Second {
		t.Fatalf("first %v", err)
	}
	moment.advance(119 * time.Second)
	if _, err := client.Search(context.Background(), "other", 5); !errors.As(err, &throttled) || !throttled.Upstream || throttled.RetryAfter != time.Second || calls.Load() != 1 {
		t.Fatalf("paused %v calls %d", err, calls.Load())
	}
	moment.advance(time.Second)
	retryAfter = "Wed, 21 Oct 2015 07:28:00 GMT"
	if _, err := client.Search(context.Background(), "dune", 5); !errors.As(err, &throttled) || throttled.RetryAfter != time.Minute || calls.Load() != 2 {
		t.Fatalf("date header %v calls %d", err, calls.Load())
	}
	moment.advance(time.Minute)
	retryAfter = "999999"
	if _, err := client.Search(context.Background(), "dune", 5); !errors.As(err, &throttled) || throttled.RetryAfter != 15*time.Minute {
		t.Fatalf("capped %v", err)
	}
}

func TestOneSearchASecondAndAtMostTwoAtOnceLeaveThisServer(t *testing.T) {
	release := make(chan struct{})
	entered := make(chan struct{}, 4)
	var calls atomic.Int32
	client, moment := newClient(func(*http.Request) (*http.Response, error) {
		calls.Add(1)
		entered <- struct{}{}
		<-release
		return answer(http.StatusOK, "application/json", `{"docs":[]}`), nil
	})
	var throttled Throttled
	results := make(chan error, 2)
	go func() { _, err := client.Search(context.Background(), "a", 5); results <- err }()
	<-entered
	if _, err := client.Search(context.Background(), "b", 5); !errors.As(err, &throttled) || throttled.Upstream || throttled.RetryAfter != time.Second {
		t.Fatalf("within a second %v", err)
	}
	moment.advance(time.Second)
	go func() { _, err := client.Search(context.Background(), "c", 5); results <- err }()
	<-entered
	moment.advance(time.Second)
	if _, err := client.Search(context.Background(), "d", 5); !errors.As(err, &throttled) || throttled.Upstream || calls.Load() != 2 {
		t.Fatalf("third at once %v calls %d", err, calls.Load())
	}
	close(release)
	for range 2 {
		if err := <-results; err != nil {
			t.Fatal(err)
		}
	}
	moment.advance(time.Second)
	if _, err := client.Search(context.Background(), "e", 5); err != nil {
		t.Fatalf("after release %v", err)
	}
}

func TestQueriesAreTrimmedBoundedAndPlainText(t *testing.T) {
	cases := map[string]struct {
		query   string
		problem QueryProblem
	}{
		"  dune 　":                      {"dune", ""},
		"":                              {"", "blank"},
		" \t\n ":                        {"", "blank"},
		strings.Repeat("é", 200):        {strings.Repeat("é", 200), ""},
		strings.Repeat("é", 201):        {"", "too_long"},
		"  " + strings.Repeat("a", 200): {strings.Repeat("a", 200), ""},
		"tab\tinside":                   {"", "invalid"},
		"nul\x00":                       {"", "invalid"},
		"\xff\xfe":                      {"", "invalid"},
		"Ender's Game & <b>bold</b> 📚":  {"Ender's Game & <b>bold</b> 📚", ""},
	}
	for raw, want := range cases {
		query, problem := NormaliseQuery(raw)
		if query != want.query || problem != want.problem {
			t.Fatalf("%q gave %q %q", raw, query, problem)
		}
	}
}

package openlibrary

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

const (
	Origin           = "https://openlibrary.org"
	CoversOrigin     = "https://covers.openlibrary.org"
	ProviderName     = "Open Library"
	searchPath       = "/search.json"
	searchFields     = "key,title,author_name,first_publish_year,cover_i,edition_count"
	MaxQueryRunes    = 200
	MaxResults       = 20
	MaxResponseBytes = 1 << 20
	SearchTimeout    = 8 * time.Second
	MinimumInterval  = time.Second
	MaxConcurrent    = 2
	defaultPause     = time.Minute
	longestPause     = 15 * time.Minute
	maxTitleRunes    = 500
	maxAuthorRunes   = 300
	maxCoverID       = 1 << 53
	maxEditionCount  = 10_000_000
)

var (
	ErrUnavailable = errors.New("open library could not be reached")
	ErrFailed      = errors.New("open library answered with something this server does not accept")
	workKey        = regexp.MustCompile(`^/works/(OL[1-9][0-9]{0,11}W)$`)
	delaySeconds   = regexp.MustCompile(`^[0-9]+$`)
)

type Throttled struct {
	RetryAfter time.Duration
	Upstream   bool
}

func (t Throttled) Error() string {
	if t.Upstream {
		return "open library asked this server to slow down"
	}
	return "this server's open library search budget is in use"
}

type Work struct {
	ID               string
	Title            string
	Author           string
	FirstPublishYear int
	CoverID          int64
	EditionCount     int
	HasEditionCount  bool
}

func (w Work) SourceURL() string { return Origin + "/works/" + w.ID }

func (w Work) CoverURL() string {
	if w.CoverID <= 0 {
		return ""
	}
	return CoversOrigin + "/b/id/" + strconv.FormatInt(w.CoverID, 10) + "-M.jpg"
}

type Client struct {
	http      *http.Client
	userAgent string
	now       func() time.Time
	slots     chan struct{}
	timeout   time.Duration

	mutex       sync.Mutex
	nextAllowed time.Time
	pausedUntil time.Time
}

func NewTransport() *http.Transport {
	dialer := &net.Dialer{Timeout: 5 * time.Second, KeepAlive: 30 * time.Second}
	return &http.Transport{
		Proxy:                  http.ProxyFromEnvironment,
		DialContext:            dialer.DialContext,
		DisableKeepAlives:      true,
		TLSNextProto:           map[string]func(string, *tls.Conn) http.RoundTripper{},
		TLSHandshakeTimeout:    5 * time.Second,
		ResponseHeaderTimeout:  SearchTimeout,
		MaxConnsPerHost:        MaxConcurrent,
		MaxResponseHeaderBytes: 64 << 10,
	}
}

func New(userAgent string, transport http.RoundTripper, now func() time.Time) *Client {
	if now == nil {
		now = time.Now
	}
	return &Client{
		http: &http.Client{
			Transport: transport,
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
		userAgent: userAgent,
		now:       now,
		slots:     make(chan struct{}, MaxConcurrent),
		timeout:   SearchTimeout,
	}
}

func (c *Client) admit() (func(), error) {
	c.mutex.Lock()
	defer c.mutex.Unlock()
	moment := c.now()
	if moment.Before(c.pausedUntil) {
		return nil, Throttled{RetryAfter: c.pausedUntil.Sub(moment), Upstream: true}
	}
	if moment.Before(c.nextAllowed) {
		return nil, Throttled{RetryAfter: c.nextAllowed.Sub(moment)}
	}
	select {
	case c.slots <- struct{}{}:
	default:
		return nil, Throttled{RetryAfter: MinimumInterval}
	}
	c.nextAllowed = moment.Add(MinimumInterval)
	return func() { <-c.slots }, nil
}

func (c *Client) pause(header string) time.Duration {
	wait := defaultPause
	if trimmed := strings.TrimSpace(header); delaySeconds.MatchString(trimmed) {
		digits := strings.TrimLeft(trimmed, "0")
		wait = longestPause
		if seconds, err := strconv.Atoi("0" + digits); err == nil && len(digits) <= 6 {
			wait = time.Duration(seconds) * time.Second
		}
	}
	wait = min(max(wait, MinimumInterval), longestPause)
	c.mutex.Lock()
	defer c.mutex.Unlock()
	if until := c.now().Add(wait); until.After(c.pausedUntil) {
		c.pausedUntil = until
	}
	return wait
}

func SearchURL(query string, limit int) string {
	values := url.Values{}
	values.Set("q", query)
	values.Set("limit", strconv.Itoa(limit))
	values.Set("fields", searchFields)
	return Origin + searchPath + "?" + values.Encode()
}

func (c *Client) Search(ctx context.Context, query string, limit int) ([]Work, error) {
	if limit <= 0 {
		return []Work{}, nil
	}
	limit = min(limit, MaxResults)
	done, err := c.admit()
	if err != nil {
		return nil, err
	}
	defer done()
	bounded, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()
	request, err := http.NewRequestWithContext(bounded, http.MethodGet, SearchURL(query, limit), nil)
	if err != nil {
		return nil, ErrFailed
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("User-Agent", c.userAgent)
	response, err := c.http.Do(request)
	if err != nil {
		return nil, transportFailure(ctx)
	}
	defer response.Body.Close()
	switch {
	case response.StatusCode == http.StatusTooManyRequests:
		return nil, Throttled{RetryAfter: c.pause(response.Header.Get("Retry-After")), Upstream: true}
	case response.StatusCode != http.StatusOK:
		return nil, ErrFailed
	}
	if media, _, err := mime.ParseMediaType(response.Header.Get("Content-Type")); err != nil || media != "application/json" {
		return nil, ErrFailed
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, MaxResponseBytes+1))
	if err != nil {
		return nil, transportFailure(ctx)
	}
	if len(body) > MaxResponseBytes {
		return nil, ErrFailed
	}
	return Project(body, limit)
}

func transportFailure(ctx context.Context) error {
	if ctx.Err() != nil {
		return ctx.Err()
	}
	return ErrUnavailable
}

func Project(body []byte, limit int) ([]Work, error) {
	if !json.Valid(body) {
		return nil, ErrFailed
	}
	var top map[string]json.RawMessage
	if err := json.Unmarshal(body, &top); err != nil || top == nil {
		return nil, ErrFailed
	}
	raw := top["docs"]
	var docs []json.RawMessage
	if len(raw) == 0 || raw[0] != '[' || json.Unmarshal(raw, &docs) != nil {
		return nil, ErrFailed
	}
	works := make([]Work, 0, min(len(docs), limit))
	seen := map[string]bool{}
	for _, doc := range docs {
		if len(works) >= limit {
			break
		}
		work, ok := projectDoc(doc)
		if !ok || seen[work.ID] {
			continue
		}
		seen[work.ID] = true
		works = append(works, work)
	}
	return works, nil
}

func projectDoc(raw json.RawMessage) (Work, bool) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil || fields == nil {
		return Work{}, false
	}
	key, ok := stringField(fields["key"])
	if !ok {
		return Work{}, false
	}
	match := workKey.FindStringSubmatch(key)
	if match == nil {
		return Work{}, false
	}
	title, ok := stringField(fields["title"])
	title = displayText(title, maxTitleRunes)
	if !ok || title == "" {
		return Work{}, false
	}
	work := Work{ID: match[1], Title: title}
	var authors []json.RawMessage
	if json.Unmarshal(fields["author_name"], &authors) == nil && len(authors) > 0 {
		if author, ok := stringField(authors[0]); ok {
			work.Author = displayText(author, maxAuthorRunes)
		}
	}
	if year, ok := integerField(fields["first_publish_year"], 1, 9999); ok {
		work.FirstPublishYear = int(year)
	}
	if cover, ok := integerField(fields["cover_i"], 1, maxCoverID); ok {
		work.CoverID = cover
	}
	if count, ok := integerField(fields["edition_count"], 0, maxEditionCount); ok {
		work.EditionCount, work.HasEditionCount = int(count), true
	}
	return work, true
}

func stringField(raw json.RawMessage) (string, bool) {
	var text string
	if len(raw) == 0 || raw[0] != '"' || json.Unmarshal(raw, &text) != nil {
		return "", false
	}
	return text, true
}

func integerField(raw json.RawMessage, low, high int64) (int64, bool) {
	text := string(raw)
	if text == "" || strings.ContainsAny(text, ".eE") {
		return 0, false
	}
	value, err := strconv.ParseInt(text, 10, 64)
	if err != nil || value < low || value > high {
		return 0, false
	}
	return value, true
}

func displayText(text string, limit int) string {
	cleaned := strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || r == utf8.RuneError {
			return ' '
		}
		return r
	}, text)
	cleaned = strings.Join(strings.Fields(cleaned), " ")
	if utf8.RuneCountInString(cleaned) <= limit {
		return cleaned
	}
	runes := []rune(cleaned)
	return strings.TrimSpace(string(runes[:limit-1])) + "…"
}

type QueryProblem string

func NormaliseQuery(raw string) (string, QueryProblem) {
	if !utf8.ValidString(raw) {
		return "", "invalid"
	}
	trimmed := strings.TrimFunc(raw, unicode.IsSpace)
	if trimmed == "" {
		return "", "blank"
	}
	if utf8.RuneCountInString(trimmed) > MaxQueryRunes {
		return "", "too_long"
	}
	if strings.IndexFunc(trimmed, unicode.IsControl) >= 0 {
		return "", "invalid"
	}
	return trimmed, ""
}

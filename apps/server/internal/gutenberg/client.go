package gutenberg

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/netguard"
)

const (
	MaxResponseBytes = 1 << 20
	MinLimit         = 1
	MaxLimit         = 25
	searchPath       = "/ebooks/search.opds/"
	userAgent        = "Shelfarr/1.0 (+https://github.com/Pedro-Revez-Silva/shelfarr)"

	CodeUnreachable = "provider-unreachable"
	CodeTimeout     = "provider-timeout"
	CodeBusy        = "provider-busy"
	CodeRefused     = "provider-refused"
	CodeMalformed   = "provider-malformed"
	CodeTooLarge    = "provider-too-large"
	CodePagination  = "provider-pagination"
)

type Error struct {
	Code      string
	Transient bool
}

func (e *Error) Error() string { return e.Code }

func fail(code string) *Error {
	return &Error{Code: code, Transient: code == CodeUnreachable || code == CodeTimeout || code == CodeBusy}
}

type Query struct {
	Titles   []string
	Author   string
	Language string
	Limit    int
}

type Result struct {
	Candidates []Candidate
	Withheld   int
	Requests   int
}

type Client struct {
	Origin         Origin
	HTTP           *http.Client
	RequestTimeout time.Duration
	Heartbeat      func(ctx context.Context) error
}

func (c *Client) Search(ctx context.Context, query Query) (Result, error) {
	limit := min(max(query.Limit, MinLimit), MaxLimit)
	var result Result
	unread := false
	for _, title := range query.Titles {
		found, more, err := c.searchTitle(ctx, &result, keywords(title, query.Author), query.Language, limit)
		if err != nil {
			return result, err
		}
		if len(found.Candidates) > 0 || found.Withheld > 0 {
			result.Candidates, result.Withheld = found.Candidates, found.Withheld
			return result, nil
		}
		unread = unread || more
	}
	if unread {
		return result, fail(CodePagination)
	}
	return result, nil
}

func keywords(title, author string) string {
	var parts []string
	for _, part := range []string{title, author} {
		if !RubyBlank(part) {
			parts = append(parts, part)
		}
	}
	return strings.Join(parts, " ")
}

func (c *Client) searchTitle(ctx context.Context, progress *Result, keywords, language string, limit int) (Result, bool, error) {
	var found Result
	if RubyBlank(keywords) {
		return found, false, nil
	}
	body, missing, err := c.fetch(ctx, progress, c.Origin.resource(searchPath, url.Values{"query": {keywords}}))
	if err != nil || missing {
		return found, false, err
	}
	listings, nextPage, err := parseListings(body)
	if err != nil {
		return found, false, fail(CodeMalformed)
	}
	unread := nextPage || len(listings) > limit
	if len(listings) > limit {
		listings = listings[:limit]
	}
	for _, listing := range listings {
		body, missing, err := c.fetch(ctx, progress, c.Origin.resource("/ebooks/"+listing.id+".opds", nil))
		if err != nil {
			return Result{}, false, err
		}
		if missing {
			continue
		}
		parsed, err := parseDetail(body, listing.id, language, c.Origin)
		if err != nil {
			return Result{}, false, fail(CodeMalformed)
		}
		switch {
		case parsed.withheld:
			found.Withheld++
		case parsed.candidate != nil:
			found.Candidates = append(found.Candidates, *parsed.candidate)
		}
	}
	return found, unread, nil
}

func (c *Client) fetch(ctx context.Context, progress *Result, resource string) ([]byte, bool, error) {
	if err := ctx.Err(); err != nil {
		return nil, false, err
	}
	progress.Requests++
	body, missing, err := c.get(ctx, resource)
	if ctx.Err() != nil {
		return nil, false, ctx.Err()
	}
	if err != nil {
		return nil, false, err
	}
	if c.Heartbeat != nil {
		if err := c.Heartbeat(ctx); err != nil {
			return nil, false, err
		}
	}
	return body, missing, nil
}

func (c *Client) get(ctx context.Context, resource string) ([]byte, bool, error) {
	requestCtx, cancel := context.WithTimeout(ctx, c.RequestTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(requestCtx, http.MethodGet, resource, nil)
	if err != nil {
		return nil, false, fail(CodeRefused)
	}
	request.Header.Set("User-Agent", userAgent)
	response, err := c.HTTP.Do(request)
	if err != nil {
		return nil, false, transportFailure(requestCtx, err)
	}
	defer response.Body.Close()
	switch {
	case response.StatusCode == http.StatusNotFound:
		return nil, true, nil
	case response.StatusCode == http.StatusRequestTimeout || response.StatusCode == http.StatusTooEarly || response.StatusCode == http.StatusTooManyRequests || response.StatusCode >= 500:
		return nil, false, fail(CodeBusy)
	case response.StatusCode != http.StatusOK:
		return nil, false, fail(CodeRefused)
	}
	body, err := netguard.ReadLimited(requestCtx, response.Body, MaxResponseBytes)
	switch {
	case errors.Is(err, netguard.ErrTooLarge):
		return nil, false, fail(CodeTooLarge)
	case err != nil:
		return nil, false, transportFailure(requestCtx, err)
	}
	return body, false, nil
}

func transportFailure(requestCtx context.Context, err error) error {
	if errors.Is(requestCtx.Err(), context.DeadlineExceeded) {
		return fail(CodeTimeout)
	}
	var timeout interface{ Timeout() bool }
	if errors.As(err, &timeout) && timeout.Timeout() {
		return fail(CodeTimeout)
	}
	return fail(CodeUnreachable)
}

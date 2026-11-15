package abs

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/netguard"
)

const (
	CodeAuth         = "auth"
	CodeConnection   = "connection"
	CodeStatus       = "http-status"
	CodeMalformed    = "malformed"
	CodeTruncated    = "truncated"
	CodeInconsistent = "inconsistent"
	CodeTooLarge     = "too-large"
	CodeNotFound     = "library-not-found"
	CodeConfig       = "config"
	CodeDestination  = "destination-refused"
	CodeRedirect     = "redirect"
	CodeCancelled    = "cancelled"
)

var errMalformedValue = errors.New("unsupported value type")

type Error struct {
	Code   string
	Status int
}

func (e *Error) Error() string {
	if e.Status != 0 {
		return e.Code + ":" + strconv.Itoa(e.Status)
	}
	return e.Code
}

func CodeOf(err error) string {
	var typed *Error
	if errors.As(err, &typed) {
		if typed.Status != 0 {
			return typed.Code + "-" + strconv.Itoa(typed.Status)
		}
		return typed.Code
	}
	return CodeConnection
}

type Config struct {
	BaseURL        string
	APIKey         string
	PageSize       int
	MaxPageBytes   int64
	MaxItems       int
	RequestTimeout time.Duration
}

type Client struct {
	base     *url.URL
	key      string
	http     *http.Client
	pageSize int
	maxBytes int64
	maxItems int
}

func NewClient(config Config) (*Client, error) {
	base, err := netguard.ValidateBaseURL(config.BaseURL)
	if err != nil || config.APIKey == "" {
		return nil, &Error{Code: CodeConfig}
	}
	client := &Client{base: base, key: config.APIKey, pageSize: config.PageSize, maxBytes: config.MaxPageBytes, maxItems: config.MaxItems}
	if client.pageSize <= 0 {
		client.pageSize = 500
	}
	if client.maxBytes <= 0 {
		client.maxBytes = 8 << 20
	}
	if client.maxItems <= 0 {
		client.maxItems = 100_000
	}
	timeout := config.RequestTimeout
	if timeout <= 0 {
		timeout = 15 * time.Second
	}
	client.http = netguard.NewClient(timeout)
	return client, nil
}

type Library struct {
	ID        string
	MediaType string
}

func (c *Client) Libraries(ctx context.Context) ([]Library, error) {
	body, err := c.get(ctx, "/api/libraries", nil)
	if err != nil {
		return nil, err
	}
	var document struct {
		Libraries *[]struct {
			ID        string `json:"id"`
			MediaType string `json:"mediaType"`
		} `json:"libraries"`
	}
	if err := decodeStrict(body, &document); err != nil || document.Libraries == nil {
		return nil, &Error{Code: CodeMalformed}
	}
	libraries := make([]Library, 0, len(*document.Libraries))
	for _, entry := range *document.Libraries {
		if entry.ID == "" {
			return nil, &Error{Code: CodeMalformed}
		}
		libraries = append(libraries, Library{ID: entry.ID, MediaType: entry.MediaType})
	}
	return libraries, nil
}

type Inventory struct {
	Items []Item
	Empty bool
}

var libraryIdentifier = regexp.MustCompile(`^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$`)

func (c *Client) LibraryInventory(ctx context.Context, libraryID string) (Inventory, error) {
	if !libraryIdentifier.MatchString(libraryID) || libraryID == ".." {
		return Inventory{}, &Error{Code: CodeConfig}
	}
	var items []Item
	seen := map[string]bool{}
	total := -1
	for page := 0; ; page++ {
		if total >= 0 && page > (total+c.pageSize-1)/c.pageSize+1 {
			return Inventory{}, &Error{Code: CodeInconsistent}
		}
		query := url.Values{}
		query.Set("limit", strconv.Itoa(c.pageSize))
		query.Set("page", strconv.Itoa(page))
		body, err := c.get(ctx, "/api/libraries/"+libraryID+"/items", query)
		if err != nil {
			var typed *Error
			if page == 0 && errors.As(err, &typed) && typed.Code == CodeStatus && (typed.Status == 404 || typed.Status == 410) {
				return Inventory{}, &Error{Code: CodeNotFound, Status: typed.Status}
			}
			return Inventory{}, err
		}
		results, pageTotal, err := decodePage(body)
		if err != nil {
			return Inventory{}, err
		}
		if pageTotal > c.maxItems {
			return Inventory{}, &Error{Code: CodeTooLarge}
		}
		if total < 0 {
			total = pageTotal
		} else if pageTotal != total {
			return Inventory{}, &Error{Code: CodeInconsistent}
		}
		if len(results) > c.pageSize {
			return Inventory{}, &Error{Code: CodeMalformed}
		}
		for _, raw := range results {
			item, err := parseItem(raw)
			if err != nil {
				return Inventory{}, &Error{Code: CodeMalformed}
			}
			if seen[item.ID] {
				return Inventory{}, &Error{Code: CodeInconsistent}
			}
			seen[item.ID] = true
			items = append(items, item)
		}
		switch {
		case total == 0 && len(items) == 0 && page == 0:
			return Inventory{Empty: true}, nil
		case total == 0:
			return Inventory{}, &Error{Code: CodeInconsistent}
		case len(items) == total:
			return Inventory{Items: items}, nil
		case len(items) > total:
			return Inventory{}, &Error{Code: CodeInconsistent}
		case len(results) < c.pageSize:
			return Inventory{}, &Error{Code: CodeTruncated}
		}
	}
}

func decodePage(body []byte) ([]any, int, error) {
	var document struct {
		Results *[]any          `json:"results"`
		Total   json.RawMessage `json:"total"`
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.UseNumber()
	if err := decoder.Decode(&document); err != nil || document.Results == nil || len(document.Total) == 0 {
		return nil, 0, &Error{Code: CodeMalformed}
	}
	if _, err := decoder.Token(); err != io.EOF {
		return nil, 0, &Error{Code: CodeMalformed}
	}
	total, err := strconv.Atoi(string(document.Total))
	if err != nil || total < 0 {
		return nil, 0, &Error{Code: CodeMalformed}
	}
	return *document.Results, total, nil
}

func decodeStrict(body []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(body))
	if err := decoder.Decode(target); err != nil {
		return err
	}
	if _, err := decoder.Token(); err != io.EOF {
		return errors.New("trailing data")
	}
	return nil
}

func (c *Client) get(ctx context.Context, path string, query url.Values) ([]byte, error) {
	target := *c.base
	target.Path = path
	target.RawPath = ""
	target.RawQuery = query.Encode()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, target.String(), nil)
	if err != nil {
		return nil, &Error{Code: CodeConfig}
	}
	request.Header.Set("Authorization", "Bearer "+c.key)
	request.Header.Set("Accept", "application/json")
	response, err := c.http.Do(request)
	if err != nil {
		return nil, transportError(ctx, err)
	}
	defer response.Body.Close()
	switch {
	case netguard.IsRedirect(response.StatusCode):
		return nil, &Error{Code: CodeRedirect, Status: response.StatusCode}
	case response.StatusCode == 401 || response.StatusCode == 403:
		return nil, &Error{Code: CodeAuth, Status: response.StatusCode}
	case response.StatusCode != 200:
		return nil, &Error{Code: CodeStatus, Status: response.StatusCode}
	}
	body, err := netguard.ReadLimited(ctx, response.Body, c.maxBytes)
	if err != nil {
		return nil, transportError(ctx, err)
	}
	return body, nil
}

func transportError(ctx context.Context, err error) error {
	switch {
	case ctx.Err() != nil:
		return &Error{Code: CodeCancelled}
	case errors.Is(err, netguard.ErrTooLarge):
		return &Error{Code: CodeTooLarge}
	case errors.Is(err, netguard.ErrDestination):
		return &Error{Code: CodeDestination}
	}
	return &Error{Code: CodeConnection}
}

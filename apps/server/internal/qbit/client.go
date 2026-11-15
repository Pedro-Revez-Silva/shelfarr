package qbit

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/http"
	"net/url"
	"path"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/netguard"
)

const (
	CodeAuth        = "auth"
	CodeConnection  = "connection"
	CodeStatus      = "http-status"
	CodeMalformed   = "malformed"
	CodeTooLarge    = "too-large"
	CodeConfig      = "config"
	CodeDestination = "destination-refused"
	CodeRedirect    = "redirect"
	CodeCancelled   = "cancelled"
	CodeInvalidHash = "invalid-hash"

	apiKeyPrefix = "qbt_"
	apiKeyLength = 32
)

type Class string

const (
	Downloading Class = "downloading"
	Paused      Class = "paused"
	Completed   Class = "completed"
	Failed      Class = "failed"
	Queued      Class = "queued"
)

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
	Username       string
	Password       string
	APIKey         string
	MaxBytes       int64
	RequestTimeout time.Duration
}

type Client struct {
	base     *url.URL
	username string
	password string
	apiKey   string
	http     *http.Client
	maxBytes int64

	mutex  sync.Mutex
	cookie string
}

func ValidAPIKey(key string) bool {
	return strings.HasPrefix(key, apiKeyPrefix) && len(key) == apiKeyLength
}

func NewClient(config Config) (*Client, error) {
	base, err := netguard.ValidateBaseURL(config.BaseURL)
	if err != nil {
		return nil, &Error{Code: CodeConfig}
	}
	client := &Client{base: base, username: config.Username, password: config.Password, maxBytes: config.MaxBytes}
	if ValidAPIKey(config.APIKey) {
		client.apiKey = config.APIKey
	} else if config.Username == "" {
		return nil, &Error{Code: CodeConfig}
	}
	if client.maxBytes <= 0 {
		client.maxBytes = 1 << 20
	}
	timeout := config.RequestTimeout
	if timeout <= 0 {
		timeout = 15 * time.Second
	}
	client.http = netguard.NewClient(timeout)
	return client, nil
}

type Torrent struct {
	Hash      string
	Name      string
	Progress  int
	State     Class
	SizeBytes int64
	Path      string
}

var hashPattern = regexp.MustCompile(`^(?:[0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$`)

func (c *Client) Torrent(ctx context.Context, hash string) (*Torrent, error) {
	if !hashPattern.MatchString(hash) {
		return nil, &Error{Code: CodeInvalidHash}
	}
	body, err := c.authenticatedGet(ctx, "/api/v2/torrents/info", url.Values{"hashes": {hash}})
	if err != nil {
		return nil, err
	}
	return parseTorrents(body, hash)
}

func (c *Client) authenticatedGet(ctx context.Context, path string, query url.Values) ([]byte, error) {
	for attempt := 0; ; attempt++ {
		if err := c.ensureSession(ctx); err != nil {
			return nil, err
		}
		status, body, err := c.do(ctx, http.MethodGet, path, query, nil)
		if err != nil {
			return nil, err
		}
		if (status == 401 || status == 403) && c.apiKey == "" && attempt == 0 {
			c.clearSession()
			continue
		}
		if status == 401 || status == 403 {
			c.clearSession()
		}
		return body, statusError(status)
	}
}

func statusError(status int) error {
	switch {
	case status == 200:
		return nil
	case netguard.IsRedirect(status):
		return &Error{Code: CodeRedirect, Status: status}
	case status == 401 || status == 403:
		return &Error{Code: CodeAuth, Status: status}
	}
	return &Error{Code: CodeStatus, Status: status}
}

func (c *Client) ensureSession(ctx context.Context) error {
	if c.apiKey != "" {
		return nil
	}
	c.mutex.Lock()
	defer c.mutex.Unlock()
	if c.cookie != "" {
		return nil
	}
	form := url.Values{"username": {c.username}, "password": {c.password}}
	status, body, cookie, err := c.send(ctx, http.MethodPost, "/api/v2/auth/login", nil, strings.NewReader(form.Encode()), "")
	if err != nil {
		return err
	}
	if status == 403 || status == 401 {
		return &Error{Code: CodeAuth, Status: status}
	}
	accepted := (status == 200 && strings.TrimSpace(string(body)) == "Ok.") || (status == 204 && cookie != "")
	if !accepted {
		if status == 200 {
			return &Error{Code: CodeAuth}
		}
		return statusError(status)
	}
	if cookie == "" {
		return &Error{Code: CodeAuth}
	}
	c.cookie = cookie
	return nil
}

func (c *Client) clearSession() {
	c.mutex.Lock()
	c.cookie = ""
	c.mutex.Unlock()
}

func (c *Client) currentCookie() string {
	c.mutex.Lock()
	defer c.mutex.Unlock()
	return c.cookie
}

func (c *Client) do(ctx context.Context, method, path string, query url.Values, body io.Reader) (int, []byte, error) {
	status, data, _, err := c.send(ctx, method, path, query, body, c.currentCookie())
	return status, data, err
}

func (c *Client) send(ctx context.Context, method, requestPath string, query url.Values, body io.Reader, cookie string) (int, []byte, string, error) {
	target := *c.base
	target.Path = path.Join("/", c.base.Path, requestPath)
	target.RawPath = ""
	target.RawQuery = query.Encode()
	request, err := http.NewRequestWithContext(ctx, method, target.String(), body)
	if err != nil {
		return 0, nil, "", &Error{Code: CodeConfig}
	}
	origin := c.base.Scheme + "://" + c.base.Host
	request.Header.Set("Referer", origin)
	request.Header.Set("Origin", origin)
	if body != nil {
		request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	switch {
	case c.apiKey != "":
		request.Header.Set("Authorization", "Bearer "+c.apiKey)
	case cookie != "":
		request.Header.Set("Cookie", cookie)
	}
	response, err := c.http.Do(request)
	if err != nil {
		return 0, nil, "", transportError(ctx, err)
	}
	defer response.Body.Close()
	data, err := netguard.ReadLimited(ctx, response.Body, c.maxBytes)
	if err != nil {
		return 0, nil, "", transportError(ctx, err)
	}
	return response.StatusCode, data, sessionCookie(response), nil
}

func sessionCookie(response *http.Response) string {
	for _, cookie := range response.Cookies() {
		if cookie.Name != "" && cookie.Value != "" {
			return cookie.Name + "=" + cookie.Value
		}
	}
	return ""
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

type rawTorrent struct {
	Hash        *string         `json:"hash"`
	Name        *string         `json:"name"`
	Progress    json.RawMessage `json:"progress"`
	State       *string         `json:"state"`
	Size        json.RawMessage `json:"size"`
	ContentPath *string         `json:"content_path"`
	SavePath    *string         `json:"save_path"`
}

func parseTorrents(body []byte, wanted string) (*Torrent, error) {
	var list []rawTorrent
	decoder := json.NewDecoder(bytes.NewReader(body))
	if err := decoder.Decode(&list); err != nil || list == nil {
		return nil, &Error{Code: CodeMalformed}
	}
	if _, err := decoder.Token(); err != io.EOF {
		return nil, &Error{Code: CodeMalformed}
	}
	switch len(list) {
	case 0:
		return nil, nil
	case 1:
	default:
		return nil, &Error{Code: CodeMalformed}
	}
	entry := list[0]
	if entry.Hash == nil || !strings.EqualFold(*entry.Hash, wanted) || entry.Name == nil || entry.State == nil {
		return nil, &Error{Code: CodeMalformed}
	}
	progress, err := parseNumber(entry.Progress)
	if err != nil || progress < 0 || progress > 1 {
		return nil, &Error{Code: CodeMalformed}
	}
	size, err := parseNumber(entry.Size)
	if err != nil || size < 0 || size > math.MaxInt64/2 || size != math.Trunc(size) {
		return nil, &Error{Code: CodeMalformed}
	}
	return &Torrent{
		Hash:      strings.ToLower(*entry.Hash),
		Name:      *entry.Name,
		Progress:  int(math.Round(progress * 100)),
		State:     classify(*entry.State),
		SizeBytes: int64(size),
		Path:      downloadPath(entry),
	}, nil
}

func parseNumber(raw json.RawMessage) (float64, error) {
	if len(raw) == 0 || raw[0] == '"' {
		return 0, errors.New("not a number")
	}
	value, err := strconv.ParseFloat(string(raw), 64)
	if err != nil || math.IsNaN(value) || math.IsInf(value, 0) {
		return 0, errors.New("not a number")
	}
	return value, nil
}

func downloadPath(entry rawTorrent) string {
	content, save, name := value(entry.ContentPath), value(entry.SavePath), value(entry.Name)
	switch {
	case strings.TrimSpace(content) != "":
		return content
	case strings.TrimSpace(save) != "" && strings.TrimSpace(name) != "":
		return strings.TrimRight(save, "/") + "/" + strings.TrimLeft(name, "/")
	}
	return save
}

func value(text *string) string {
	if text == nil {
		return ""
	}
	return *text
}

func classify(state string) Class {
	switch state {
	case "downloading", "forcedDL", "metaDL", "queuedDL", "allocating", "checkingDL":
		return Downloading
	case "stalledDL", "pausedDL", "stoppedDL":
		return Paused
	case "uploading", "forcedUP", "stalledUP", "queuedUP", "pausedUP", "stoppedUP", "checkingUP":
		return Completed
	case "error", "missingFiles":
		return Failed
	}
	return Queued
}

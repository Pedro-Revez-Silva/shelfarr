package consumer

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/account"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/library"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
)

const (
	cacheControl     = "private, no-store"
	descriptionLimit = 20_000
	listLimit        = 30
	assetsPath       = "/api/consumer/v1/library/"
)

var (
	ErrUnsupportedPagination = errors.New("catalogue pagination is not supported")
	ErrUnsupportedValue      = errors.New("unsupported stored value")
	bookIDPattern            = regexp.MustCompile(`^[1-9][0-9]{0,18}$`)
	defaultTypes             = []int{store.BookTypeEbook, store.BookTypeAudiobook}
)

type Source interface {
	account.Directory
	library.Settings
	AcquiredBooks(ctx context.Context, types []int) ([]store.Book, error)
	AcquiredBook(ctx context.Context, id int64, types []int) (*store.Book, error)
	ProgressByBook(ctx context.Context, userID int64) (map[int64]store.Progress, error)
	ReadingStatusByBook(ctx context.Context, userID int64) (map[int64]int, error)
}

type Request struct {
	Path          string
	Authorization string
}

type Response struct {
	Status       int
	CacheControl string
	Body         []byte
}

type Service struct {
	Source Source
	Now    func() time.Time
}

type meBody struct {
	ID       string   `json:"id"`
	Name     string   `json:"name"`
	Username string   `json:"username"`
	Scopes   []string `json:"scopes"`
}

type assetBody struct {
	ID         string `json:"id"`
	Filename   string `json:"filename"`
	Format     string `json:"format"`
	MediaType  string `json:"media_type"`
	SizeBytes  int64  `json:"size_bytes"`
	Position   int    `json:"position"`
	ContentURL string `json:"content_url"`

	PageCount       *int   `json:"page_count,omitempty"`
	ReadingOrderURL string `json:"reading_order_url,omitempty"`
}

type progressBody struct {
	AssetID          string   `json:"asset_id"`
	Locator          any      `json:"locator"`
	PositionSeconds  *float64 `json:"position_seconds"`
	Version          int64    `json:"version"`
	ObservedAt       *string  `json:"observed_at"`
	UpdatedAt        string   `json:"updated_at"`
	ClientMutationID string   `json:"client_mutation_id"`
}

type publicationBody struct {
	ID            string        `json:"id"`
	Title         string        `json:"title"`
	Author        *string       `json:"author"`
	Description   string        `json:"description"`
	BookType      string        `json:"book_type"`
	ContentKind   *string       `json:"content_kind,omitempty"`
	CoverURL      *string       `json:"cover_url"`
	Assets        []assetBody   `json:"assets"`
	Progress      *progressBody `json:"progress"`
	ReadingStatus string        `json:"reading_status"`
}

type listBody struct {
	Items      []publicationBody `json:"items"`
	NextCursor *string           `json:"next_cursor"`
}

func (s Service) Respond(ctx context.Context, request Request) (Response, error) {
	principal, err := account.Authenticate(ctx, s.Source, request.Authorization, s.Now())
	if err != nil {
		return Response{}, err
	}
	if principal == nil {
		return reply(401, nil)
	}
	if !principal.HasScope("library:read") {
		return reply(403, map[string]string{"error": "insufficient_scope", "required_scope": "library:read"})
	}
	switch {
	case request.Path == "/api/consumer/v1/me":
		return reply(200, meBody{ID: strconv.FormatInt(principal.UserID, 10), Name: principal.Name, Username: principal.Username, Scopes: principal.VisibleScopes()})
	case request.Path == "/api/consumer/v1/library":
		return s.list(ctx, principal)
	case strings.HasPrefix(request.Path, assetsPath) && bookIDPattern.MatchString(strings.TrimPrefix(request.Path, assetsPath)):
		return s.show(ctx, principal, strings.TrimPrefix(request.Path, assetsPath))
	}
	return reply(404, nil)
}

func reply(status int, body any) (Response, error) {
	response := Response{Status: status, CacheControl: cacheControl}
	if body == nil {
		return response, nil
	}
	encoded, err := json.Marshal(body)
	if err != nil {
		return Response{}, err
	}
	response.Body = encoded
	return response, nil
}

type view struct {
	lister   library.Lister
	progress map[int64]store.Progress
	states   map[int64]int
	declared bool
}

func (s Service) newView(ctx context.Context, principal *account.Principal) (view, error) {
	roots, err := library.OutputRoots(ctx, s.Source)
	if err != nil {
		return view{}, err
	}
	progress, err := s.Source.ProgressByBook(ctx, principal.UserID)
	if err != nil {
		return view{}, err
	}
	states, err := s.Source.ReadingStatusByBook(ctx, principal.UserID)
	if err != nil {
		return view{}, err
	}
	return view{lister: library.Lister{Roots: roots}, progress: progress, states: states}, nil
}

func (s Service) list(ctx context.Context, principal *account.Principal) (Response, error) {
	books, err := s.Source.AcquiredBooks(ctx, defaultTypes)
	if err != nil {
		return Response{}, err
	}
	if len(books) > listLimit {
		return Response{}, ErrUnsupportedPagination
	}
	current, err := s.newView(ctx, principal)
	if err != nil {
		return Response{}, err
	}
	items := make([]publicationBody, 0, len(books))
	for _, book := range books {
		item, err := current.publication(ctx, book)
		if err != nil {
			return Response{}, err
		}
		items = append(items, item)
	}
	return reply(200, listBody{Items: items})
}

func (s Service) show(ctx context.Context, principal *account.Principal, rawID string) (Response, error) {
	id, err := strconv.ParseInt(rawID, 10, 64)
	if err != nil {
		return reply(404, nil)
	}
	book, err := s.Source.AcquiredBook(ctx, id, defaultTypes)
	if err != nil {
		return Response{}, err
	}
	if book == nil {
		return reply(404, nil)
	}
	current, err := s.newView(ctx, principal)
	if err != nil {
		return Response{}, err
	}
	item, err := current.publication(ctx, *book)
	if err != nil {
		return Response{}, err
	}
	return reply(200, item)
}

func (v view) publication(ctx context.Context, book store.Book) (publicationBody, error) {
	description, err := truncatedDescription(book.Description)
	if err != nil {
		return publicationBody{}, err
	}
	cover, err := SafeCover(book.CoverURL)
	if err != nil {
		return publicationBody{}, err
	}
	listing, err := v.lister.List(ctx, book, book.FilePath.String)
	if err != nil {
		return publicationBody{}, err
	}
	progress, hasProgress := v.progress[book.ID]
	body := publicationBody{
		ID: strconv.FormatInt(book.ID, 10), Title: book.Title, Author: nullable(book.Author), Description: description,
		BookType: "ebook", CoverURL: cover, Assets: assetBodies(book, listing), ReadingStatus: v.readingStatus(book.ID, hasProgress),
	}
	if book.BookType == store.BookTypeAudiobook {
		body.BookType = "audiobook"
	}
	if v.declared {
		kind := "book"
		if book.BookType != store.BookTypeAudiobook && (book.BookType == store.BookTypeComicbook || book.ContentKind == store.ContentKindGraphic) {
			kind = "graphic"
		}
		body.ContentKind = &kind
	}
	if hasProgress {
		converted, err := progressRepresentation(progress)
		if err != nil {
			return publicationBody{}, err
		}
		body.Progress = &converted
	}
	return body, nil
}

func assetBodies(book store.Book, listing library.Listing) []assetBody {
	bodies := make([]assetBody, 0, len(listing.Assets))
	for _, asset := range listing.Assets {
		contentURL := assetsPath + strconv.FormatInt(book.ID, 10) + "/assets/" + asset.ID
		body := assetBody{
			ID: asset.ID, Filename: asset.Filename, Format: asset.Format, MediaType: asset.MediaType, SizeBytes: asset.SizeBytes,
			Position: asset.Position, ContentURL: contentURL,
		}
		if asset.Format == "cbz" {
			pages := asset.PageCount
			body.PageCount, body.ReadingOrderURL = &pages, contentURL+"/reading_order"
		}
		bodies = append(bodies, body)
	}
	return bodies
}

var statusNames = map[int]string{0: "unread", 1: "in_progress", 2: "finished"}

func (v view) readingStatus(bookID int64, hasProgress bool) string {
	if status, present := v.states[bookID]; present {
		return statusNames[status]
	}
	if hasProgress {
		return "in_progress"
	}
	return "unread"
}

func nullable(value sql.NullString) *string {
	if !value.Valid {
		return nil
	}
	return &value.String
}

func truncatedDescription(value sql.NullString) (string, error) {
	if !utf8.ValidString(value.String) {
		return "", ErrUnsupportedValue
	}
	if len(value.String) <= descriptionLimit {
		return value.String, nil
	}
	runes := []rune(value.String)
	if len(runes) > descriptionLimit {
		runes = runes[:descriptionLimit]
	}
	return string(runes), nil
}

func SafeCover(value sql.NullString) (*string, error) {
	if !value.Valid {
		return nil, nil
	}
	parsed, err := url.Parse(value.String)
	if err != nil || !strings.EqualFold(parsed.Scheme, "https") {
		return nil, nil
	}
	if parsed.Host == "" || parsed.User != nil {
		return nil, nil
	}
	if parsed.String() != value.String {
		return nil, ErrUnsupportedValue
	}
	return &value.String, nil
}

func progressRepresentation(progress store.Progress) (progressBody, error) {
	body := progressBody{AssetID: progress.AssetID, Version: progress.Version, ClientMutationID: progress.ClientMutationID}
	if progress.Locator.Valid {
		decoder := json.NewDecoder(strings.NewReader(progress.Locator.String))
		decoder.UseNumber()
		if err := decoder.Decode(&body.Locator); err != nil {
			return progressBody{}, ErrUnsupportedValue
		}
	}
	if progress.PositionSeconds.Valid {
		body.PositionSeconds = &progress.PositionSeconds.Float64
	}
	updated, err := store.ParseTimestamp(progress.UpdatedAt)
	if err != nil {
		return progressBody{}, err
	}
	body.UpdatedAt = store.FormatISO8601Millis(updated)
	if progress.ObservedAt.Valid {
		observed, err := store.ParseTimestamp(progress.ObservedAt.String)
		if err != nil {
			return progressBody{}, err
		}
		text := store.FormatISO8601Millis(observed)
		body.ObservedAt = &text
	}
	return body, nil
}

package gohttp

import (
	"context"
	"errors"
	"log/slog"
	"math"
	"net/http"
	"net/url"
	"strconv"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/consumer"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/library"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/live"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/media"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/openlibrary"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/webpreview"
)

const (
	discoverServerOff   = "server_off"
	maxDiscoverRequests = 8
	maxFallbackProbes   = 30
)

var discoverCopyTypes = []struct {
	value int
	name  string
}{{store.BookTypeEbook, "ebook"}, {store.BookTypeAudiobook, "audiobook"}, {store.BookTypeComicbook, "comicbook"}}

type discoverProvider struct {
	Name string `json:"name"`
	URL  string `json:"url"`
}

type discoverCopy struct {
	BookType      string `json:"book_type"`
	PublicationID string `json:"publication_id"`
}

type discoverItem struct {
	ID               string         `json:"id"`
	Title            string         `json:"title"`
	Author           *string        `json:"author"`
	FirstPublishYear *int           `json:"first_publish_year"`
	EditionCount     *int           `json:"edition_count"`
	CoverURL         *string        `json:"cover_url"`
	SourceURL        string         `json:"source_url"`
	Library          []discoverCopy `json:"library"`
}

type discoverAnswer struct {
	Account    string           `json:"account"`
	Provider   discoverProvider `json:"provider"`
	Search     string           `json:"search"`
	RetryAfter *int             `json:"retry_after,omitempty"`
	Query      *string          `json:"query"`
	Items      []discoverItem   `json:"items"`
}

func discoverQuery(raw string) (query string, present bool, ok bool) {
	values, err := url.ParseQuery(raw)
	if err != nil {
		return "", false, false
	}
	found := values["q"]
	switch len(found) {
	case 0:
		return "", false, true
	case 1:
		return found[0], true, true
	}
	return "", false, false
}

func (a *App) webDiscover(w http.ResponseWriter, r *http.Request, session browserSession, result *outcome) {
	raw, present, ok := discoverQuery(r.URL.RawQuery)
	if !ok {
		problem(w, result, http.StatusUnprocessableEntity, "invalid_query")
		return
	}
	answer := discoverAnswer{Account: session.account(), Provider: discoverProvider{Name: openlibrary.ProviderName, URL: openlibrary.Origin}, Items: []discoverItem{}}
	if present {
		query, problemKind := openlibrary.NormaliseQuery(raw)
		if problemKind != "" {
			problem(w, result, http.StatusUnprocessableEntity, "invalid_query")
			return
		}
		answer.Query = &query
	}
	settings, err := a.discoverSettings(r.Context())
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	answer.Search = string(settings.State)
	if !settings.PausedUntil.IsZero() {
		seconds := int(math.Ceil(settings.PausedUntil.Sub(a.now()).Seconds()))
		answer.RetryAfter = &seconds
	}
	if answer.Query == nil || settings.State != live.OpenLibraryAvailable {
		result.set(http.StatusOK, "")
		writeJSON(w, http.StatusOK, answer)
		return
	}
	if settings.Limit <= 0 {
		result.set(http.StatusOK, "")
		writeJSON(w, http.StatusOK, answer)
		return
	}
	roots, err := a.resolveRoots(r.Context())
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	works, err := a.searchOpenLibrary(r.Context(), *answer.Query, settings.Limit)
	if err != nil {
		a.discoverFailure(w, result, err)
		return
	}
	items, err := a.discoverItems(r.Context(), session.user.ID, roots, works)
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	answer.Items = items
	result.set(http.StatusOK, "")
	writeJSON(w, http.StatusOK, answer)
}

func (a *App) discoverSettings(ctx context.Context) (live.OpenLibrarySettings, error) {
	if a.openLibrary == nil {
		return live.OpenLibrarySettings{State: discoverServerOff}, nil
	}
	return a.db.OpenLibrarySettings(ctx, a.now())
}

func (a *App) searchOpenLibrary(ctx context.Context, query string, limit int) ([]openlibrary.Work, error) {
	started := time.Now()
	works, err := a.openLibrary.Search(ctx, query, limit)
	outcome := "ok"
	var throttled openlibrary.Throttled
	switch {
	case errors.As(err, &throttled) && throttled.Upstream:
		outcome = "rate_limited"
	case errors.As(err, &throttled):
		outcome = "throttled"
	case errors.Is(err, openlibrary.ErrUnavailable):
		outcome = "unavailable"
	case errors.Is(err, openlibrary.ErrFailed):
		outcome = "failed"
	case err != nil:
		outcome = "cancelled"
	}
	a.logger.Info("open_library", slog.String("outcome", outcome), slog.Int("results", len(works)), slog.Int64("duration_ms", time.Since(started).Milliseconds()))
	return works, err
}

func (a *App) discoverFailure(w http.ResponseWriter, result *outcome, err error) {
	var throttled openlibrary.Throttled
	switch {
	case errors.As(err, &throttled):
		w.Header().Set("Retry-After", strconv.Itoa(int(math.Ceil(throttled.RetryAfter.Seconds()))))
		problem(w, result, http.StatusTooManyRequests, "search_rate_limited")
	case errors.Is(err, openlibrary.ErrUnavailable):
		problem(w, result, http.StatusServiceUnavailable, "search_unavailable")
	case errors.Is(err, openlibrary.ErrFailed):
		problem(w, result, http.StatusBadGateway, "search_failed")
	default:
		mapFailure(w, result, err)
	}
}

func unlinkable(err error) bool {
	return errors.Is(err, library.ErrReference) || errors.Is(err, library.ErrUnsupportedPath) || errors.Is(err, library.ErrUnsupportedRoot) ||
		errors.Is(err, consumer.ErrUnsupportedValue) || errors.Is(err, store.ErrUnsupported) || errors.Is(err, store.ErrTimestamp) || errors.Is(err, media.ErrNoPinnedOpen) ||
		errors.Is(err, webpreview.ErrUnsupported)
}

func (a *App) openableCopies(ctx context.Context, userID int64, roots []string, copies []live.WorkCopy) (map[string]map[int]int64, error) {
	held := map[string]map[int]int64{}
	tried := map[string]map[int]bool{}
	fallbacks := 0
	for _, found := range copies {
		if _, chosen := held[found.WorkID][found.Book.BookType]; chosen {
			continue
		}
		if tried[found.WorkID][found.Book.BookType] {
			if fallbacks >= maxFallbackProbes {
				continue
			}
			fallbacks++
		}
		if tried[found.WorkID] == nil {
			tried[found.WorkID] = map[int]bool{}
		}
		tried[found.WorkID][found.Book.BookType] = true
		opens, err := a.detailOpens(ctx, userID, roots, found.Book)
		if err != nil {
			return nil, err
		}
		if !opens {
			continue
		}
		if held[found.WorkID] == nil {
			held[found.WorkID] = map[int]int64{}
		}
		held[found.WorkID][found.Book.BookType] = found.Book.ID
	}
	return held, nil
}

func (a *App) detailOpens(ctx context.Context, userID int64, roots []string, book store.Book) (bool, error) {
	items, err := a.publications(ctx, userID, []store.Book{book}, webFormats, roots)
	if unlinkable(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	detail, err := webpreview.ProjectDetail(items[0])
	if unlinkable(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return detail.Availability == "available", nil
}

func (a *App) discoverItems(ctx context.Context, userID int64, roots []string, works []openlibrary.Work) ([]discoverItem, error) {
	ids := make([]string, len(works))
	for index, work := range works {
		ids[index] = work.ID
	}
	types := make([]int, len(discoverCopyTypes))
	for index, kind := range discoverCopyTypes {
		types[index] = kind.value
	}
	copies, err := a.db.AcquiredCopiesOfOpenLibraryWorks(ctx, ids, types)
	if err != nil {
		return nil, err
	}
	held, err := a.openableCopies(ctx, userID, roots, copies)
	if err != nil {
		return nil, err
	}
	items := make([]discoverItem, len(works))
	for index, work := range works {
		item := discoverItem{ID: work.ID, Title: work.Title, SourceURL: work.SourceURL(), Library: []discoverCopy{}}
		if work.Author != "" {
			item.Author = &work.Author
		}
		if work.FirstPublishYear > 0 {
			item.FirstPublishYear = &work.FirstPublishYear
		}
		if work.HasEditionCount {
			item.EditionCount = &work.EditionCount
		}
		if cover := work.CoverURL(); cover != "" {
			item.CoverURL = &cover
		}
		for _, kind := range discoverCopyTypes {
			if id, found := held[work.ID][kind.value]; found {
				item.Library = append(item.Library, discoverCopy{BookType: kind.name, PublicationID: strconv.FormatInt(id, 10)})
			}
		}
		items[index] = item
	}
	return items, nil
}

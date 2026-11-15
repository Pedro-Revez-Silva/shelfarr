package gohttp

import (
	"context"
	"errors"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/account"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/assetid"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/catalogue"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/comic"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/consumer"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/library"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/live"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/media"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/readerformats"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
)

var (
	bookID  = regexp.MustCompile(`^[1-9][0-9]{0,18}$`)
	assetID = regexp.MustCompile(`^[0-9a-f]{64}$`)
)

const (
	continueSlice = 20
	continueScan  = 200
)

func headerValue(r *http.Request, name string) (string, bool) {
	values := r.Header.Values(name)
	if len(values) == 0 {
		return "", false
	}
	return strings.Join(values, ", "), true
}

func (a *App) resolveRoots(ctx context.Context) ([]string, error) {
	roots, err := library.OutputRoots(ctx, a.db)
	if err != nil {
		return nil, err
	}
	for _, root := range roots {
		if !withinAny(root, a.explicitRoots) {
			return nil, errRootNotAllowed
		}
	}
	return roots, nil
}

func withinAny(path string, roots []string) bool {
	for _, root := range roots {
		if path == root || strings.HasPrefix(path, strings.TrimRight(root, "/")+"/") {
			return true
		}
	}
	return false
}

func declareVary(w http.ResponseWriter, names ...string) {
	existing := w.Header().Get("Vary")
	parts := []string{}
	if existing != "" {
		parts = append(parts, existing)
	}
	parts = append(parts, names...)
	w.Header().Set("Vary", strings.Join(parts, ", "))
}

func (a *App) readerFormats(w http.ResponseWriter, r *http.Request, result *outcome) (readerformats.Formats, bool) {
	declareVary(w, readerformats.FormatsHeader)
	value, present := headerValue(r, readerformats.FormatsHeader)
	formats, err := readerformats.ParseFormats(value, present)
	var invalid readerformats.Invalid
	if errors.As(err, &invalid) {
		result.set(http.StatusBadRequest, "invalid_request")
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_request", "message": invalid.Message})
		return formats, false
	}
	return formats, true
}

func (a *App) me(w http.ResponseWriter, principal *account.Principal, result *outcome) {
	result.set(http.StatusOK, "")
	writeJSON(w, http.StatusOK, consumer.NewMe(strconv.FormatInt(principal.UserID, 10), principal.Name, principal.Username, principal.VisibleScopes()))
}

func (a *App) publications(ctx context.Context, userID int64, books []store.Book, formats readerformats.Formats, roots []string) ([]consumer.Publication, error) {
	ids := make([]int64, len(books))
	for index, book := range books {
		ids[index] = book.ID
	}
	progress, err := a.db.ProgressFor(ctx, userID, ids)
	if err != nil {
		return nil, err
	}
	states, err := a.db.StatesFor(ctx, userID, ids)
	if err != nil {
		return nil, err
	}
	view := consumer.NewViewFor(roots, formats.Names, progress, states, formats.Declared)
	items := make([]consumer.Publication, 0, len(books))
	for _, book := range books {
		item, err := view.Publication(ctx, book)
		if err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, nil
}

func (a *App) library(w http.ResponseWriter, r *http.Request, principal *account.Principal, result *outcome) {
	formats, ok := a.readerFormats(w, r, result)
	if !ok {
		return
	}
	params, err := catalogue.ParseQuery(r.URL.RawQuery)
	if err != nil {
		problem(w, result, http.StatusBadRequest, "bad_request")
		return
	}
	found, err := a.catalogue.Call(r.Context(), principal.UserID, params, formats)
	var invalid catalogue.Invalid
	if errors.As(err, &invalid) {
		result.set(http.StatusBadRequest, "invalid_request")
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_request", "message": invalid.Message})
		return
	}
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	declareVary(w, readerformats.FormatsHeader)
	roots, err := a.resolveRoots(r.Context())
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	items, err := a.publications(r.Context(), principal.UserID, found.Books, formats, roots)
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	result.set(http.StatusOK, "")
	writeJSON(w, http.StatusOK, consumer.NewPublicationList(items, found.NextCursor))
}

func continueLimit(param catalogue.Param) int {
	if !param.IsString || len(param.Value) == 0 || len(param.Value) > 3 {
		return 10
	}
	for _, character := range param.Value {
		if character < '0' || character > '9' {
			return 10
		}
	}
	number, _ := strconv.Atoi(param.Value)
	return min(max(number, 1), 20)
}

func (a *App) continueReading(w http.ResponseWriter, r *http.Request, principal *account.Principal, result *outcome) {
	formats, ok := a.readerFormats(w, r, result)
	if !ok {
		return
	}
	params, err := catalogue.ParseQuery(r.URL.RawQuery)
	if err != nil {
		problem(w, result, http.StatusBadRequest, "bad_request")
		return
	}
	limit := continueLimit(params.Limit)
	books, err := a.db.InProgress(r.Context(), principal.UserID, catalogue.ReadingTypes("", formats.Graphic()), continueScan)
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	roots, err := a.resolveRoots(r.Context())
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	items := []consumer.Publication{}
	for start := 0; start < len(books) && len(items) < limit; start += continueSlice {
		page, err := a.publications(r.Context(), principal.UserID, books[start:min(start+continueSlice, len(books))], formats, roots)
		if err != nil {
			mapFailure(w, result, err)
			return
		}
		for _, item := range page {
			if len(item.Assets) == 0 {
				continue
			}
			if progressAsset, hasProgress := item.ProgressAssetID(); hasProgress && !item.HasAsset(progressAsset) {
				continue
			}
			items = append(items, item)
			if len(items) >= limit {
				break
			}
		}
	}
	result.set(http.StatusOK, "")
	writeJSON(w, http.StatusOK, map[string][]consumer.Publication{"items": items})
}

func (a *App) publication(w http.ResponseWriter, r *http.Request, principal *account.Principal, rawID string, result *outcome) {
	formats, ok := a.readerFormats(w, r, result)
	if !ok {
		return
	}
	book, ok := a.lookupBook(w, r, rawID, catalogue.ReadingTypes("", formats.Graphic()), result)
	if !ok {
		return
	}
	declareVary(w, readerformats.FeaturesHeader)
	value, present := headerValue(r, readerformats.FeaturesHeader)
	readAlong, err := readerformats.ParseFeatures(value, present)
	var invalid readerformats.Invalid
	switch {
	case errors.As(err, &invalid):
		result.set(http.StatusBadRequest, "invalid_request")
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_request", "message": invalid.Message})
		return
	case readAlong:
		problem(w, result, http.StatusNotImplemented, "unsupported_reader_feature")
		return
	}
	roots, err := a.resolveRoots(r.Context())
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	items, err := a.publications(r.Context(), principal.UserID, []store.Book{*book}, formats, roots)
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	result.set(http.StatusOK, "")
	writeJSON(w, http.StatusOK, items[0])
}

func (a *App) lookupBook(w http.ResponseWriter, r *http.Request, rawID string, types []int, result *outcome) (*store.Book, bool) {
	if !bookID.MatchString(rawID) {
		problem(w, result, http.StatusNotFound, "not_found")
		return nil, false
	}
	id, err := strconv.ParseInt(rawID, 10, 64)
	if err != nil {
		problem(w, result, http.StatusNotFound, "not_found")
		return nil, false
	}
	book, err := a.db.AcquiredBook(r.Context(), id, types)
	if err != nil {
		mapFailure(w, result, err)
		return nil, false
	}
	if book == nil {
		problem(w, result, http.StatusNotFound, "not_found")
		return nil, false
	}
	return book, true
}

var (
	allReadingFormats = []string{"epub", "pdf", "cbz"}
	comicFormats      = []string{"cbz"}
	allBookTypes      = []int{store.BookTypeEbook, store.BookTypeAudiobook, store.BookTypeComicbook}
)

const documentPolicy = "default-src 'none'; sandbox; frame-ancestors 'none'; form-action 'none'; base-uri 'none'"

func fixedLayout(format string) bool {
	return format == "pdf" || format == "cbz"
}

func (a *App) findAsset(w http.ResponseWriter, r *http.Request, found route, formats []string, result *outcome) (*store.Book, *library.Asset, bool) {
	book, ok := a.lookupBook(w, r, found.id, allBookTypes, result)
	if !ok {
		return nil, nil, false
	}
	roots, err := a.resolveRoots(r.Context())
	if err != nil {
		mapFailure(w, result, err)
		return nil, nil, false
	}
	if !assetID.MatchString(found.assetID) {
		problem(w, result, http.StatusGone, "asset_unavailable")
		return nil, nil, false
	}
	located, err := library.Lister{Roots: roots, Formats: formats}.Find(r.Context(), *book, book.FilePath.String, found.assetID)
	if err != nil {
		mapFailure(w, result, err)
		return nil, nil, false
	}
	if located.Asset == nil {
		problem(w, result, http.StatusGone, "asset_unavailable")
		return nil, nil, false
	}
	return book, located.Asset, true
}

func (a *App) assetFailure(w http.ResponseWriter, result *outcome, err error) {
	switch {
	case errors.Is(err, media.ErrNoPinnedOpen), errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		mapFailure(w, result, err)
	default:
		problem(w, result, http.StatusGone, "asset_unavailable")
	}
}

func (a *App) openAsset(w http.ResponseWriter, result *outcome, book store.Book, asset library.Asset) (*os.File, bool) {
	file, err := openVerified(book, asset)
	if err != nil {
		a.assetFailure(w, result, err)
		return nil, false
	}
	return file, true
}

func readPages(ctx context.Context, book store.Book, asset library.Asset) ([]comic.Page, error) {
	file, err := openVerified(book, asset)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	return comic.Pages(ctx, file, asset.SizeBytes)
}

func (a *App) asset(w http.ResponseWriter, r *http.Request, principal *account.Principal, found route, result *outcome) {
	book, chosen, ok := a.findAsset(w, r, found, allReadingFormats, result)
	if !ok {
		return
	}
	file, ok := a.openAsset(w, result, *book, *chosen)
	if !ok {
		return
	}
	defer file.Close()
	served := media.Asset{ID: chosen.ID, Filename: chosen.Filename, MediaType: chosen.MediaType, Size: chosen.SizeBytes, Disposition: "inline"}
	if fixedLayout(chosen.Format) {
		served.Disposition, served.ContentSecurityPolicy = "attachment", documentPolicy
	}
	result.set(http.StatusOK, "")
	media.Serve(w, r, file, served, a.config.StreamWriteStall)
}

type readingOrderBody struct {
	AssetID string       `json:"asset_id"`
	Format  string       `json:"format"`
	Items   []comic.Page `json:"items"`
}

func (a *App) readingOrder(w http.ResponseWriter, r *http.Request, principal *account.Principal, found route, result *outcome) {
	book, chosen, ok := a.findAsset(w, r, found, comicFormats, result)
	if !ok {
		return
	}
	if chosen.Format != "cbz" {
		problem(w, result, http.StatusGone, "asset_unavailable")
		return
	}
	pages, err := readPages(r.Context(), *book, *chosen)
	if err != nil {
		a.assetFailure(w, result, err)
		return
	}
	result.set(http.StatusOK, "")
	writeJSON(w, http.StatusOK, readingOrderBody{AssetID: chosen.ID, Format: "cbz", Items: pages})
}

var errAssetChanged = errors.New("media edition changed while opening")

func openVerified(book store.Book, asset library.Asset) (*os.File, error) {
	file, err := media.OpenPinned(asset.Root, asset.Path)
	if err != nil {
		return nil, err
	}
	info, err := file.Stat()
	if err != nil {
		file.Close()
		return nil, err
	}
	stat, err := assetid.StatOf(info)
	if err != nil {
		file.Close()
		return nil, err
	}
	current := assetid.ID(assetid.Input{BookID: book.ID, StoredPath: book.FilePath.String, CanonicalPath: asset.Path, Stat: stat})
	if current != asset.ID {
		file.Close()
		return nil, errAssetChanged
	}
	return file, nil
}

type androidChannel struct {
	FeedURL         string `json:"feed_url"`
	DownloadPageURL string `json:"download_page_url"`
}

func (a *App) server(w http.ResponseWriter, result *outcome) {
	channels := map[string]androidChannel{}
	for _, name := range a.config.AndroidChannels {
		page := "/apps/android"
		if name != "release" {
			page += "?channel=" + name
		}
		channels[name] = androidChannel{FeedURL: "/apps/android/" + name + ".json", DownloadPageURL: page}
	}
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	result.set(http.StatusOK, "")
	writeJSON(w, http.StatusOK, map[string]any{
		"schema_version":               1,
		"server_version":               a.config.ServerVersion,
		"consumer_api_versions":        []int{1},
		"consumer_features":            []string{},
		"reader_formats":               []string{"cbz", "epub", "pdf"},
		"reader_features":              []string{},
		"read_along_manifest_versions": []int{},
		"android":                      channels,
	})
}

func (a *App) ready(w http.ResponseWriter, r *http.Request, result *outcome) {
	checks := map[string]string{"database": "ok", "library_roots": "ok"}
	if err := a.db.Ready(r.Context()); err != nil {
		checks["database"] = "unavailable"
		if errors.Is(err, live.ErrBusy) {
			checks["database"] = "busy"
		}
	}
	for _, root := range a.explicitRoots {
		if info, err := os.Stat(root); err != nil || !info.IsDir() {
			checks["library_roots"] = "missing"
		}
	}
	ready := checks["database"] == "ok" && checks["library_roots"] == "ok"
	status := http.StatusOK
	if !ready {
		status = http.StatusServiceUnavailable
	}
	result.set(status, "")
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, status, map[string]any{"ready": ready, "checks": checks})
}

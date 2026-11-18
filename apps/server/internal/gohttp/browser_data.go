package gohttp

import (
	"errors"
	"net/http"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/catalogue"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/checkpoint"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/consumer"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/readerformats"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/webpreview"
)

var (
	webFormats = readerformats.Formats{Names: []string{"cbz", "epub", "pdf"}, Declared: true}
)

const webContinueLimit = 3

func (a *App) browserData(w http.ResponseWriter, r *http.Request, found route, result *outcome) {
	media := found.kind == routeBrowserMedia
	readerOnly := media || found.kind == routeBrowserReader || found.kind == routeBrowserProgress
	if readerOnly && !a.readerInstalled() || found.kind == routeBrowserReadingOrder && !a.pagesInstalled() {
		w.Header().Set("Cache-Control", "private, no-store")
		problem(w, result, http.StatusNotFound, "not_found")
		return
	}
	if media && a.previewConfigured() && !sameOriginFetch(r) {
		problem(w, result, http.StatusForbidden, "cross_site_refused")
		return
	}
	session, ok := a.guard(w, r, result, !media)
	if !ok {
		return
	}
	if media && found.account != session.account() {
		problem(w, result, http.StatusUnauthorized, "account_changed")
		return
	}
	mutation := found.kind == routeBrowserStatus || found.kind == routeBrowserDecide || found.kind == routeBrowserProgress && r.Method == http.MethodPut
	if mutation && !a.mutationAllowed(w, r, *session, result) {
		return
	}
	switch found.kind {
	case routeBrowserSession:
		a.webSession(w, r, *session, result)
	case routeBrowserLibrary:
		a.webLibrary(w, r, *session, result)
	case routeBrowserContinue:
		a.webContinue(w, r, *session, result)
	case routeBrowserPublication:
		a.webPublication(w, r, *session, found.id, result)
	case routeBrowserStatus:
		a.webReadingStatus(w, r, *session, found.id, result)
	case routeBrowserConnect:
		a.connectInspect(w, r, *session, result)
	case routeBrowserDecide:
		a.connectDecide(w, r, *session, result)
	case routeBrowserReader:
		a.webReader(w, r, *session, found.id, result)
	case routeBrowserProgress:
		a.webProgress(w, r, *session, found.id, result)
	case routeBrowserMedia:
		a.webMedia(w, r, found, result)
	case routeBrowserReadingOrder:
		a.webReadingOrder(w, r, *session, found, result)
	}
}

func (a *App) webSession(w http.ResponseWriter, r *http.Request, session browserSession, result *outcome) {
	catalogue, err := a.db.HardcoverCatalogAvailable(r.Context(), session.user.ID)
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	discover := "/search"
	if catalogue {
		discover = "/discover"
	}
	value := map[string]any{
		"account": map[string]string{"id": session.account(), "name": session.user.Name},
		"server":  map[string]string{"name": hostName(r, a.fallbackHost()), "version": a.config.ServerVersion},
		"links":   map[string]string{"legacy_library": "/read", "discover": discover, "requests": "/requests", "account": "/profile"},
	}
	if session.user.Admin {
		value["admin"] = map[string]string{"url": "/admin"}
	}
	result.set(http.StatusOK, "")
	writeJSON(w, http.StatusOK, value)
}

func (a *App) fallbackHost() string {
	origin := a.config.BrowserOrigin
	for _, prefix := range []string{"http://", "https://"} {
		if len(origin) > len(prefix) && origin[:len(prefix)] == prefix {
			return origin[len(prefix):]
		}
	}
	return "localhost"
}

func (a *App) webPublications(r *http.Request, userID int64, books []store.Book) ([]consumer.Publication, error) {
	roots, err := a.resolveRoots(r.Context())
	if err != nil {
		return nil, err
	}
	ids := make([]int64, len(books))
	for index, book := range books {
		ids[index] = book.ID
	}
	progress, err := a.db.ProgressFor(r.Context(), userID, ids)
	if err != nil {
		return nil, err
	}
	states, err := a.db.StatesFor(r.Context(), userID, ids)
	if err != nil {
		return nil, err
	}
	view := consumer.NewViewFor(roots, webFormats.Names, progress, states, true)
	items := make([]consumer.Publication, 0, len(books))
	for _, book := range books {
		item, err := view.Publication(r.Context(), book)
		if err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, nil
}

func summaries(items []consumer.Publication) ([]webpreview.Summary, error) {
	projected := make([]webpreview.Summary, 0, len(items))
	for _, item := range items {
		summary, err := webpreview.Project(item)
		if err != nil {
			return nil, err
		}
		projected = append(projected, summary)
	}
	return projected, nil
}

func (a *App) webLibrary(w http.ResponseWriter, r *http.Request, session browserSession, result *outcome) {
	params, err := catalogue.ParseQuery(r.URL.RawQuery)
	if err != nil {
		problem(w, result, http.StatusBadRequest, "bad_request")
		return
	}
	found, err := a.catalogue.Call(r.Context(), session.user.ID, params, webFormats)
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
	items, err := a.webPublications(r, session.user.ID, found.Books)
	if err == nil {
		var projected []webpreview.Summary
		if projected, err = summaries(items); err == nil {
			result.set(http.StatusOK, "")
			writeJSON(w, http.StatusOK, map[string]any{"account": session.account(), "items": projected, "next_cursor": found.NextCursor})
			return
		}
	}
	mapFailure(w, result, err)
}

func (a *App) webContinue(w http.ResponseWriter, r *http.Request, session browserSession, result *outcome) {
	params, err := catalogue.ParseQuery(r.URL.RawQuery)
	if err != nil {
		problem(w, result, http.StatusBadRequest, "bad_request")
		return
	}
	kind := ""
	if params.Type.IsString && (params.Type.Value == "ebook" || params.Type.Value == "audiobook") {
		kind = params.Type.Value
	}
	books, err := a.db.InProgress(r.Context(), session.user.ID, catalogue.ReadingTypes(kind, true), continueScan)
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	chosen := []consumer.Publication{}
	for start := 0; start < len(books) && len(chosen) < webContinueLimit; start += continueSlice {
		page, err := a.webPublications(r, session.user.ID, books[start:min(start+continueSlice, len(books))])
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
			chosen = append(chosen, item)
			if len(chosen) >= webContinueLimit {
				break
			}
		}
	}
	projected, err := summaries(chosen)
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	result.set(http.StatusOK, "")
	writeJSON(w, http.StatusOK, map[string]any{"account": session.account(), "items": projected})
}

func (a *App) webBook(w http.ResponseWriter, r *http.Request, rawID string, result *outcome) (*store.Book, bool) {
	book, ok := a.lookupBook(w, r, rawID, allBookTypes, result)
	if !ok {
		return nil, false
	}
	return book, true
}

func (a *App) webPublication(w http.ResponseWriter, r *http.Request, session browserSession, rawID string, result *outcome) {
	book, ok := a.webBook(w, r, rawID, result)
	if !ok {
		return
	}
	items, err := a.webPublications(r, session.user.ID, []store.Book{*book})
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	a.respondDetail(w, session, items[0], result)
}

func (a *App) respondDetail(w http.ResponseWriter, session browserSession, item consumer.Publication, result *outcome) {
	detail, err := webpreview.ProjectDetail(item)
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	result.set(http.StatusOK, "")
	writeJSON(w, http.StatusOK, map[string]any{"account": session.account(), "publication": detail})
}

func (a *App) webReadingStatus(w http.ResponseWriter, r *http.Request, session browserSession, rawID string, result *outcome) {
	document, ok := a.decode(w, r, result)
	if !ok {
		return
	}
	book, ok := a.webBook(w, r, rawID, result)
	if !ok {
		return
	}
	name, err := document.Status()
	var invalid checkpoint.Invalid
	if errors.As(err, &invalid) {
		writeInvalid(w, result, "invalid_reading_status", invalid.Message)
		return
	}
	items, err := a.webPublications(r, session.user.ID, []store.Book{*book})
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	items[0].ReadingStatus = name
	if _, err := webpreview.ProjectDetail(items[0]); err != nil {
		mapFailure(w, result, err)
		return
	}
	if err := a.db.SetReadingStatus(r.Context(), session.user.ID, book.ID, statusValues[name], a.now); err != nil {
		mapFailure(w, result, err)
		return
	}
	a.respondDetail(w, session, items[0], result)
}

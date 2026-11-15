package gohttp

import (
	"context"
	"errors"
	"io"
	"mime"
	"net"
	"net/http"
	"os"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/account"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/checkpoint"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/consumer"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/library"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/live"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
)

var graphicTypes = []int{store.BookTypeEbook, store.BookTypeAudiobook, store.BookTypeComicbook}

var statusValues = map[string]int{"unread": 0, "in_progress": 1, "finished": 2}

const (
	mediaMissing = "Media is missing or outside the authorized library"
	assetGone    = "This asset is no longer available; refresh the publication"
)

type bodyFailure struct {
	status int
	code   string
}

func (a *App) readBody(w http.ResponseWriter, r *http.Request) ([]byte, *bodyFailure) {
	return a.readLimitedBody(w, r, checkpoint.MaxBodyBytes)
}

func (a *App) readLimitedBody(w http.ResponseWriter, r *http.Request, limit int64) ([]byte, *bodyFailure) {
	if r.ContentLength != 0 {
		mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
		if err != nil || mediaType != "application/json" {
			return nil, &bodyFailure{http.StatusUnsupportedMediaType, "unsupported_media_type"}
		}
	}
	if r.ContentLength > limit {
		w.Header().Set("Connection", "close")
		return nil, &bodyFailure{http.StatusRequestEntityTooLarge, "request_too_large"}
	}
	control := http.NewResponseController(w)
	control.SetReadDeadline(time.Now().Add(a.config.BodyTimeout))
	data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, limit))
	var tooLarge *http.MaxBytesError
	var network net.Error
	switch {
	case err == nil:
		return data, nil
	case errors.As(err, &tooLarge):
		w.Header().Set("Connection", "close")
		return nil, &bodyFailure{http.StatusRequestEntityTooLarge, "request_too_large"}
	case errors.Is(err, os.ErrDeadlineExceeded), errors.As(err, &network) && network.Timeout():
		w.Header().Set("Connection", "close")
		return nil, &bodyFailure{http.StatusRequestTimeout, "request_body_timeout"}
	case errors.Is(err, context.Canceled):
		return nil, &bodyFailure{499, "client_closed"}
	}
	w.Header().Set("Connection", "close")
	return nil, &bodyFailure{http.StatusBadRequest, "invalid_request_body"}
}

func (a *App) writeBodyFailure(w http.ResponseWriter, result *outcome, failure *bodyFailure) {
	if failure.status == 499 {
		result.set(499, failure.code)
		return
	}
	problem(w, result, failure.status, failure.code)
}

func (a *App) decode(w http.ResponseWriter, r *http.Request, result *outcome) (checkpoint.Document, bool) {
	body, failure := a.readBody(w, r)
	if failure != nil {
		a.writeBodyFailure(w, result, failure)
		return checkpoint.Document{}, false
	}
	document, err := checkpoint.Decode(body)
	if err != nil {
		declareVary(w, "Accept", "X-Requested-With")
		problem(w, result, http.StatusBadRequest, "invalid_json")
		return checkpoint.Document{}, false
	}
	return document, true
}

func (a *App) checkpointBook(w http.ResponseWriter, r *http.Request, rawID string, result *outcome) (*store.Book, bool) {
	book, ok := a.lookupBook(w, r, rawID, graphicTypes, result)
	if !ok {
		return nil, false
	}
	if book.BookType == store.BookTypeComicbook {
		problem(w, result, http.StatusNotImplemented, "unsupported_publication_kind")
		return nil, false
	}
	return book, true
}

func (a *App) progress(w http.ResponseWriter, r *http.Request, principal *account.Principal, rawID string, result *outcome) {
	if r.Method == http.MethodPut {
		a.updateProgress(w, r, principal, rawID, result)
		return
	}
	book, ok := a.checkpointBook(w, r, rawID, result)
	if !ok {
		return
	}
	stored, err := a.db.ProgressFor(r.Context(), principal.UserID, []int64{book.ID})
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	var current *store.Progress
	if progress, present := stored[book.ID]; present {
		current = &progress
	}
	a.respondStored(w, result, http.StatusOK, "", current)
}

func (a *App) respondStored(w http.ResponseWriter, result *outcome, status int, code string, progress *store.Progress) {
	var representation *consumer.Progress
	if progress != nil {
		converted, err := consumer.NewProgress(*progress)
		if err != nil {
			mapFailure(w, result, err)
			return
		}
		representation = &converted
	}
	result.set(status, code)
	body := map[string]any{"progress": representation}
	if code != "" {
		body["error"] = code
	}
	writeJSON(w, status, body)
}

func (a *App) updateProgress(w http.ResponseWriter, r *http.Request, principal *account.Principal, rawID string, result *outcome) {
	document, ok := a.decode(w, r, result)
	if !ok {
		return
	}
	book, ok := a.checkpointBook(w, r, rawID, result)
	if !ok {
		return
	}
	write, err := document.Progress(book.BookType == store.BookTypeAudiobook, a.now())
	var invalid checkpoint.Invalid
	if errors.As(err, &invalid) {
		writeInvalid(w, result, "invalid_progress", invalid.Message)
		return
	}
	if message, failure := a.confirmAsset(r.Context(), *book, write.AssetID); failure != nil {
		mapFailure(w, result, failure)
		return
	} else if message != "" {
		writeInvalid(w, result, "invalid_progress", message)
		return
	}
	saved, err := a.db.SaveProgress(r.Context(), principal.UserID, book.ID, write, a.now)
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	if saved.Outcome == live.ProgressConflict {
		a.respondStored(w, result, http.StatusConflict, "progress_conflict", saved.Progress)
		return
	}
	a.respondStored(w, result, http.StatusOK, "", saved.Progress)
}

func writeInvalid(w http.ResponseWriter, result *outcome, code, message string) {
	result.set(http.StatusUnprocessableEntity, code)
	writeJSON(w, http.StatusUnprocessableEntity, map[string]string{"error": code, "message": message})
}

func (a *App) confirmAsset(ctx context.Context, book store.Book, wanted string) (string, error) {
	roots, err := a.resolveRoots(ctx)
	if err != nil {
		return "", err
	}
	listing, err := library.Lister{Roots: roots, Formats: allReadingFormats}.List(book, book.FilePath.String)
	if err != nil {
		return "", err
	}
	if listing.Unavailable {
		return mediaMissing, nil
	}
	for _, asset := range listing.Assets {
		if asset.ID != wanted {
			continue
		}
		if asset.Format == "pdf" || asset.Format == "cbz" {
			return "", errUnsupportedAsset
		}
		return "", nil
	}
	return assetGone, nil
}

func (a *App) readingStatus(w http.ResponseWriter, r *http.Request, principal *account.Principal, rawID string, result *outcome) {
	formats, ok := a.readerFormats(w, r, result)
	if !ok {
		return
	}
	document, ok := a.decode(w, r, result)
	if !ok {
		return
	}
	book, ok := a.checkpointBook(w, r, rawID, result)
	if !ok {
		return
	}
	name, err := document.Status()
	var invalid checkpoint.Invalid
	if errors.As(err, &invalid) {
		writeInvalid(w, result, "invalid_reading_status", invalid.Message)
		return
	}
	roots, err := a.resolveRoots(r.Context())
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	items, err := a.publications(r.Context(), principal.UserID, []store.Book{*book}, formats.Declared, roots)
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	if err := a.db.SetReadingStatus(r.Context(), principal.UserID, book.ID, statusValues[name], a.now); err != nil {
		mapFailure(w, result, err)
		return
	}
	items[0].ReadingStatus = name
	result.set(http.StatusOK, "")
	writeJSON(w, http.StatusOK, items[0])
}

var errUnsupportedAsset = errors.New("asset format is not supported")

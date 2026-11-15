package gohttp

import (
	"context"
	"errors"
	"io"
	"mime"
	"net"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/account"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/checkpoint"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/comic"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/consumer"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/library"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/live"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/media"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
)

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
	return a.readBounded(w, r, limit)
}

func (a *App) readBounded(w http.ResponseWriter, r *http.Request, limit int64) ([]byte, *bodyFailure) {
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
	return a.lookupBook(w, r, rawID, allBookTypes, result)
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
	if message, failure := a.confirmPlace(r.Context(), *book, write); failure != nil {
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

func (a *App) confirmPlace(ctx context.Context, book store.Book, write checkpoint.Write) (string, error) {
	roots, err := a.resolveRoots(ctx)
	if err != nil {
		return "", err
	}
	found, err := library.Lister{Roots: roots, Formats: allReadingFormats}.Find(ctx, book, book.FilePath.String, write.AssetID)
	switch {
	case err != nil:
		return "", err
	case found.Unavailable:
		return mediaMissing, nil
	case found.Asset == nil:
		return assetGone, nil
	case write.Locator == nil || !fixedLayout(found.Asset.Format):
		return "", nil
	}
	place, err := checkpoint.FixedLayout(*write.Locator, found.Asset.Format)
	var invalid checkpoint.Invalid
	switch {
	case errors.As(err, &invalid):
		return invalid.Message, nil
	case err != nil:
		return "", err
	case found.Asset.Format == "pdf":
		return "", nil
	}
	return a.confirmPage(ctx, book, *found.Asset, place)
}

func (a *App) confirmPage(ctx context.Context, book store.Book, asset library.Asset, place checkpoint.Place) (string, error) {
	pages, err := readPages(ctx, book, asset)
	var invalid comic.Invalid
	switch {
	case errors.Is(err, media.ErrNoPinnedOpen), errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return "", err
	case errors.Is(err, errAssetChanged):
		return "This media edition changed while opening", nil
	case errors.As(err, &invalid):
		return "This comic archive is unsupported or unsafe", nil
	case err != nil:
		return "This media edition is unavailable", nil
	}
	if place.Page > int64(len(pages)) || pages[place.Page-1].Href != place.Href || pages[place.Page-1].MediaType != place.MediaType {
		return "This page is not page " + strconv.FormatInt(place.Page, 10) + " of the comic's reading order; refresh the publication", nil
	}
	return "", nil
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
	items, err := a.publications(r.Context(), principal.UserID, []store.Book{*book}, formats, roots)
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

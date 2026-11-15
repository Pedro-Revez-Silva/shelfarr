package gohttp

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/account"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/consumer"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/library"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/live"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/media"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
)

type outcome struct {
	status int
	code   string
}

func (o *outcome) set(status int, code string) {
	o.status, o.code = status, code
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	encoded, err := json.Marshal(body)
	if err != nil {
		status, encoded = http.StatusInternalServerError, []byte(`{"error":"internal_error"}`)
	}
	header := w.Header()
	header.Set("Content-Type", "application/json; charset=utf-8")
	header.Set("Content-Length", strconv.Itoa(len(encoded)))
	w.WriteHeader(status)
	w.Write(encoded)
}

func writeEmpty(w http.ResponseWriter, status int) {
	w.Header().Set("Content-Length", "0")
	w.WriteHeader(status)
}

func problem(w http.ResponseWriter, result *outcome, status int, code string) {
	result.set(status, code)
	writeJSON(w, status, map[string]string{"error": code})
}

func mapFailure(w http.ResponseWriter, result *outcome, err error) {
	switch {
	case errors.Is(err, context.Canceled):
		result.set(499, "client_closed")
	case errors.Is(err, context.DeadlineExceeded):
		w.Header().Set("Retry-After", "1")
		problem(w, result, http.StatusServiceUnavailable, "request_timeout")
	case errors.Is(err, live.ErrBusy):
		w.Header().Set("Retry-After", "1")
		problem(w, result, http.StatusServiceUnavailable, "database_busy")
	case errors.Is(err, live.ErrUnavailable):
		problem(w, result, http.StatusServiceUnavailable, "database_unavailable")
	case errors.Is(err, errRootNotAllowed):
		problem(w, result, http.StatusServiceUnavailable, "library_root_not_allowed")
	case errors.Is(err, library.ErrReference), errors.Is(err, library.ErrUnsupportedPath), errors.Is(err, library.ErrUnsupportedRoot):
		problem(w, result, http.StatusNotImplemented, "unsupported_library_layout")
	case errors.Is(err, consumer.ErrUnsupportedValue), errors.Is(err, store.ErrUnsupported), errors.Is(err, store.ErrTimestamp), errors.Is(err, account.ErrUnsupportedScopes):
		problem(w, result, http.StatusNotImplemented, "unsupported_stored_value")
	case errors.Is(err, errUnsupportedAsset):
		problem(w, result, http.StatusNotImplemented, "unsupported_asset_format")
	case errors.Is(err, media.ErrNoPinnedOpen):
		problem(w, result, http.StatusNotImplemented, "confined_open_unsupported")
	default:
		problem(w, result, http.StatusInternalServerError, "internal_error")
	}
}

package gohttp

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/bearer"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/catalogue"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/csrf"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/live"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/loginlimit"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/railsmsg"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/transfergrant"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/webassets"
)

var errRootNotAllowed = errors.New("library root is outside the configured roots")

type App struct {
	config        Config
	db            *live.DB
	auth          bearer.Authenticator
	catalogue     catalogue.Catalogue
	explicitRoots []string
	metadata      chan struct{}
	streams       chan struct{}
	logger        *slog.Logger
	now           func() time.Time
	cookies       railsmsg.Verifier
	tokens        csrf.Tokens
	limiter       *loginlimit.Limiter
	deviceLimiter *loginlimit.Limiter
	tokenLimiter  *loginlimit.Limiter
	grants        live.GrantSource
	transfers     transfergrant.Grants
	previewIDs    map[string]bool
	web           *webUI
}

func NewApp(config Config, database *live.DB, explicitRoots []string, logger *slog.Logger, now func() time.Time) (*App, error) {
	if err := config.Validate(); err != nil {
		return nil, err
	}
	listing, err := catalogue.New(database, config.SecretKeyBase)
	if err != nil {
		return nil, err
	}
	cookies, err := railsmsg.NewVerifier(config.SecretKeyBase, signedCookieSalt)
	if err != nil {
		return nil, err
	}
	tokens, err := csrf.New(config.SecretKeyBase)
	if err != nil {
		return nil, err
	}
	transfers, err := transfergrant.New(config.SecretKeyBase)
	if err != nil {
		return nil, err
	}
	previewIDs := map[string]bool{}
	for _, id := range config.PreviewUserIDs {
		previewIDs[id] = true
	}
	var web *webUI
	if config.WebAssetsDir != "" {
		bundle, err := webassets.Load(config.WebAssetsDir)
		if err != nil {
			return nil, err
		}
		if web, err = newWebUI(bundle); err != nil {
			return nil, err
		}
	}
	return &App{
		config:        config,
		db:            database,
		auth:          bearer.Authenticator{DB: database, Now: now},
		catalogue:     listing,
		explicitRoots: explicitRoots,
		metadata:      make(chan struct{}, config.MaxMetadataRequests),
		streams:       make(chan struct{}, config.MaxMediaStreams),
		logger:        logger,
		now:           now,
		cookies:       cookies,
		tokens:        tokens,
		limiter:       loginlimit.New(config.LoginAttempts, config.LoginWindow, config.MaxLoginWorkers),
		deviceLimiter: loginlimit.New(deviceAttempts, deviceWindow, 1),
		tokenLimiter:  loginlimit.New(tokenAttempts, tokenWindow, 1),
		grants:        newGrantSource(),
		transfers:     transfers,
		previewIDs:    previewIDs,
		web:           web,
	}, nil
}

func setDefaultHeaders(header http.Header) {
	header.Set("X-Frame-Options", "SAMEORIGIN")
	header.Set("X-XSS-Protection", "0")
	header.Set("X-Content-Type-Options", "nosniff")
	header.Set("X-Permitted-Cross-Domain-Policies", "none")
	header.Set("Referrer-Policy", "same-origin")
}

func (a *App) acquire(slots chan struct{}) bool {
	select {
	case slots <- struct{}{}:
		return true
	default:
		return false
	}
}

func release(slots chan struct{}) { <-slots }

type statusWriter struct {
	http.ResponseWriter
	status  int
	written int64
}

func (s *statusWriter) WriteHeader(status int) {
	if s.status == 0 {
		s.status = status
	}
	s.ResponseWriter.WriteHeader(status)
}

func (s *statusWriter) Write(data []byte) (int, error) {
	if s.status == 0 {
		s.status = http.StatusOK
	}
	count, err := s.ResponseWriter.Write(data)
	s.written += int64(count)
	return count, err
}

func (s *statusWriter) Unwrap() http.ResponseWriter { return s.ResponseWriter }

func (a *App) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	started := time.Now()
	found := classify(r.Method, r.URL.Path)
	result := &outcome{}
	recorder := &statusWriter{ResponseWriter: w}
	defer func() {
		if recovered := recover(); recovered != nil {
			if recovered == http.ErrAbortHandler {
				panic(recovered)
			}
			if recorder.status == 0 {
				problem(recorder, result, http.StatusInternalServerError, "internal_error")
			} else {
				result.set(recorder.status, "internal_error")
			}
		}
		a.logRequest(r, found, recorder, result, started)
	}()
	setDefaultHeaders(recorder.Header())
	a.dispatch(recorder, r, found, result)
}

func (a *App) logRequest(r *http.Request, found route, recorder *statusWriter, result *outcome, started time.Time) {
	status := recorder.status
	if status == 0 {
		status = result.status
	}
	level := slog.LevelInfo
	if status >= 500 {
		level = slog.LevelWarn
	}
	a.logger.LogAttrs(r.Context(), level, "request",
		slog.String("method", r.Method), slog.String("route", found.name), slog.Int("status", status),
		slog.Int64("bytes", recorder.written), slog.Int64("duration_ms", time.Since(started).Milliseconds()), slog.String("code", result.code))
}

func (a *App) dispatch(w http.ResponseWriter, r *http.Request, found route, result *outcome) {
	if found.web && a.web == nil {
		found = route{kind: routeNone}
	}
	if found.web && !a.previewConfigured() {
		w.Header().Set("Cache-Control", "private, no-store")
		problem(w, result, http.StatusNotFound, "not_found")
		return
	}
	switch found.kind {
	case routeNone:
		problem(w, result, http.StatusNotFound, "not_found")
		return
	case routeWrongMethod:
		if found.name == "browser_media" {
			setBrowserMediaPrivacy(w.Header())
		}
		w.Header().Set("Allow", found.allow)
		problem(w, result, http.StatusMethodNotAllowed, "method_not_allowed")
		return
	case routeExcluded:
		problem(w, result, http.StatusNotImplemented, "not_implemented_in_go_runtime")
		return
	case routeUp:
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
		return
	case routeWebIndex, routeWebShell, routeWebAsset:
		a.serveWeb(w, r, found, result)
		return
	}
	slots := a.metadata
	if found.kind == routeAsset || found.kind == routeTransfer || found.kind == routeBrowserMedia {
		slots = a.streams
	}
	if found.kind == routeTransfer {
		setTransferPrivacy(w.Header())
	}
	if found.kind == routeBrowserMedia {
		setBrowserMediaPrivacy(w.Header())
	}
	if !a.acquire(slots) {
		w.Header().Set("Retry-After", "1")
		problem(w, result, http.StatusServiceUnavailable, "server_busy")
		return
	}
	defer release(slots)
	ctx, cancel := context.WithTimeout(r.Context(), a.config.RequestTimeout)
	defer cancel()
	r = r.WithContext(ctx)
	switch found.kind {
	case routeReady:
		a.ready(w, r, result)
	case routeServer:
		a.server(w, result)
	case routeAuthDevice:
		a.device(w, r, result)
	case routeAuthToken:
		a.exchange(w, r, result)
	case routeBrowserSession, routeBrowserLibrary, routeBrowserContinue, routeBrowserPublication, routeBrowserStatus, routeBrowserConnect, routeBrowserDecide,
		routeBrowserReader, routeBrowserProgress, routeBrowserMedia:
		a.browserData(w, r, found, result)
	case routeAuthBootstrap:
		a.bootstrap(w, r, result)
	case routeAuthLogin:
		a.login(w, r, result)
	case routeAuthLogout:
		a.logout(w, r, result)
	case routeTransfer:
		a.transfer(w, r, found, result)
	case routeMe, routeLibrary, routeContinue, routePublication, routeProgress, routeReadingStatus, routeAsset, routeReadingOrder, routeTransferGrant, routeAuthRevoke:
		a.authenticated(w, r, found, result)
	}
}

func (a *App) authenticated(w http.ResponseWriter, r *http.Request, found route, result *outcome) {
	header := w.Header()
	header.Set("Cache-Control", "private, no-store")
	header.Set("Referrer-Policy", "no-referrer")
	principal, err := a.auth.Authenticate(r.Context(), strings.Join(r.Header.Values("Authorization"), ", "))
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	if principal == nil {
		result.set(http.StatusUnauthorized, "unauthorized")
		writeEmpty(w, http.StatusUnauthorized)
		return
	}
	required := requiredScope(r.Method, found)
	if required != "" && !principal.HasScope(required) {
		result.set(http.StatusForbidden, "insufficient_scope")
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "insufficient_scope", "required_scope": required})
		return
	}
	switch found.kind {
	case routeMe:
		a.me(w, principal, result)
	case routeLibrary:
		a.library(w, r, principal, result)
	case routeContinue:
		a.continueReading(w, r, principal, result)
	case routePublication:
		a.publication(w, r, principal, found.id, result)
	case routeProgress:
		a.progress(w, r, principal, found.id, result)
	case routeReadingStatus:
		a.readingStatus(w, r, principal, found.id, result)
	case routeAsset:
		a.serveAsset(w, r, found, result)
	case routeTransferGrant:
		a.transferGrant(w, r, principal, found, result)
	case routeReadingOrder:
		a.readingOrder(w, r, principal, found, result)
	case routeAuthRevoke:
		a.revoke(w, r, principal, result)
	}
}

func requiredScope(method string, found route) string {
	if found.kind == routeAuthRevoke {
		return ""
	}
	if found.kind == routeReadingStatus || found.kind == routeProgress && method == http.MethodPut {
		return "progress:write"
	}
	return "library:read"
}

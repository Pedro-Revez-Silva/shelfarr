package gohttp

import (
	"context"
	"database/sql"
	"errors"
	"io"
	"log"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/live"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/media"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/ownership"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/webassets"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/wfstore"
)

const responseGrace = 2 * time.Second

type StartError struct{ Code string }

func (e StartError) Error() string { return e.Code }

func start(code string) error { return StartError{Code: code} }

func Run(ctx context.Context, config Config, logger *slog.Logger, announce func(net.Addr)) error {
	if err := config.Validate(); err != nil {
		return start("config")
	}
	roots, err := ResolveRoots(config.LibraryRoots)
	if err != nil {
		return start("library-roots")
	}
	if config.WebAssetsDir != "" {
		bundle, err := webassets.Load(config.WebAssetsDir)
		if err != nil {
			return start("web-assets")
		}
		if config.WebOffline && bundle.ReaderEngine() == "" {
			return start("web-offline")
		}
	}
	if !media.ConfinedOpenSupported() {
		return start("confined-open")
	}
	if config.AcquisitionWorkdir != "" {
		if code := acquisitionPreflight(config); code != "" {
			return start(code)
		}
	}
	release, code := acquireOwnership(config)
	if code != "" {
		return start(code)
	}
	defer release()
	database, err := live.Open(ctx, config.DatabasePath, live.Options{BusyTimeout: config.BusyTimeout})
	switch {
	case errors.Is(err, live.ErrNotSQLite):
		return start("database-not-sqlite")
	case errors.Is(err, live.ErrSchemaUnsupported):
		return start("database-schema")
	case err != nil:
		return start("database-unavailable")
	}
	defer database.Close()
	clock := config.Clock
	if clock == nil {
		clock = time.Now
	}
	app, err := NewApp(config, database, roots, logger, clock)
	if errors.Is(err, webassets.ErrInvalid) {
		return start("web-assets")
	}
	if err != nil {
		return start("config")
	}
	if config.AcquisitionWorkdir != "" {
		service, code := openAcquisition(ctx, config, roots, logger, clock)
		if service == nil {
			return start(code)
		}
		defer service.close()
		app.attachAcquisition(service)
	}
	listener, err := net.Listen("tcp", config.Listen)
	if err != nil {
		return start("listen")
	}
	workerCtx, stopWorker := context.WithCancel(context.Background())
	defer app.stopAcquisition(stopWorker, config.ShutdownTimeout)
	if app.acquisition != nil {
		go app.acquisition.run(workerCtx)
	}
	server := newServer(app, config)
	if announce != nil {
		announce(listener.Addr())
	}
	failed := make(chan error, 1)
	go func() { failed <- server.Serve(listener) }()
	select {
	case err := <-failed:
		return err
	case <-ctx.Done():
	}
	shutdown, cancel := context.WithTimeout(context.Background(), config.ShutdownTimeout)
	defer cancel()
	if err := server.Shutdown(shutdown); err != nil {
		server.Close()
	}
	return nil
}

func newServer(handler http.Handler, config Config) *http.Server {
	return &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: config.ReadHeaderTimeout,
		ReadTimeout:       config.ReadTimeout,
		WriteTimeout:      config.RequestTimeout + responseGrace,
		IdleTimeout:       config.IdleTimeout,
		MaxHeaderBytes:    config.MaxHeaderBytes,
		BaseContext:       func(net.Listener) context.Context { return context.Background() },
		ErrorLog:          log.New(io.Discard, "", 0),
	}
}

func (a *App) attachAcquisition(service *acquisitionService) {
	service.authority = func(ctx context.Context, tx *sql.Tx, job selectionJob) error {
		if err := a.authorityIn(ctx, tx, authority{sessionID: job.sessionID, userID: job.userID, admin: true}); err != nil {
			return err
		}
		return a.servedRootsIn(ctx, tx)
	}
	service.allowRoot = func(ctx context.Context, root string) bool {
		roots, err := a.resolveRoots(ctx)
		return err == nil && withinAny(root, roots)
	}
	a.acquisition = service
}

func (a *App) stopAcquisition(stop context.CancelFunc, wait time.Duration) {
	stop()
	if a.acquisition == nil {
		return
	}
	select {
	case <-a.acquisition.stopped:
	case <-time.After(wait):
	}
}

func acquireOwnership(config Config) (func(), string) {
	if config.AcquisitionWorkdir != "" {
		lock, err := wfstore.LockBeneath(config.AcquisitionWorkdir, strings.TrimSuffix(acquisitionLockName, ".lock"))
		switch {
		case errors.Is(err, wfstore.ErrAlreadyOwned):
			return nil, "lock-held"
		case err != nil:
			return nil, "acquisition-volume"
		}
		return func() { lock.Close() }, ""
	}
	lock, err := ownership.Acquire(config.LockPath)
	switch {
	case errors.Is(err, ownership.ErrHeld):
		return nil, "lock-held"
	case err != nil:
		return nil, "lock"
	}
	return func() { lock.Release() }, ""
}

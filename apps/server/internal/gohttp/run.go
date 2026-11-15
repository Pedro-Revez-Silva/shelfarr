package gohttp

import (
	"context"
	"errors"
	"io"
	"log"
	"log/slog"
	"net"
	"net/http"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/live"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/media"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/ownership"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/webassets"
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
	if !media.ConfinedOpenSupported() {
		return start("confined-open")
	}
	lock, err := ownership.Acquire(config.LockPath)
	switch {
	case errors.Is(err, ownership.ErrHeld):
		return start("lock-held")
	case err != nil:
		return start("lock")
	}
	defer lock.Release()
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
	listener, err := net.Listen("tcp", config.Listen)
	if err != nil {
		return start("listen")
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

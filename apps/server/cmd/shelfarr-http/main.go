package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/gohttp"
)

const (
	exitUsage  = 2
	exitOwned  = 3
	exitFailed = 1
)

type listFlag []string

func (l *listFlag) String() string     { return strings.Join(*l, ",") }
func (l *listFlag) Set(v string) error { *l = append(*l, v); return nil }

func main() {
	os.Exit(run(os.Args[1:], os.Stderr))
}

func run(args []string, stderr *os.File) int {
	flags := flag.NewFlagSet("shelfarr-http", flag.ContinueOnError)
	flags.SetOutput(stderr)
	var config gohttp.Config
	var roots listFlag
	var secretFile, channels string
	experimental := flags.Bool("experimental", false, "acknowledge that this runtime is experimental and not a production server")
	flags.StringVar(&config.DatabasePath, "database", "", "absolute path of an existing compatible SQLite database")
	flags.StringVar(&config.LockPath, "lock-file", "", "absolute path of the single-owner lock file")
	flags.Var(&roots, "library-root", "absolute library root; repeatable")
	flags.StringVar(&secretFile, "secret-key-base-file", "", "file holding the Rails secret key base")
	flags.StringVar(&config.Listen, "listen", "127.0.0.1:3100", "listen address")
	flags.BoolVar(&config.AllowPublicBind, "allow-non-loopback", false, "permit a listen address that is not loopback")
	flags.StringVar(&config.ServerVersion, "server-version", "unknown", "version reported by server.json")
	flags.StringVar(&channels, "android-channels", "release", "Android channels reported by server.json")
	flags.IntVar(&config.MaxMetadataRequests, "max-metadata-requests", 0, "concurrent metadata requests")
	flags.IntVar(&config.MaxMediaStreams, "max-media-streams", 0, "concurrent media streams")
	flags.DurationVar(&config.StreamWriteStall, "stream-write-stall", 0, "longest a media client may stall a single write")
	flags.DurationVar(&config.RequestTimeout, "request-timeout", 0, "deadline for the database and filesystem work of one request")
	flags.DurationVar(&config.BusyTimeout, "busy-timeout", 0, "how long SQLite waits for a competing writer")
	flags.DurationVar(&config.ShutdownTimeout, "shutdown-timeout", 0, "how long shutdown waits for running requests")
	flags.DurationVar(&config.ReadHeaderTimeout, "read-header-timeout", 0, "deadline for receiving request headers")
	if err := flags.Parse(args); err != nil {
		return exitUsage
	}
	if !*experimental {
		fmt.Fprintln(stderr, "refused: this runtime is experimental and default-off; pass -experimental")
		return exitUsage
	}
	config.LibraryRoots = roots
	config.AndroidChannels = gohttp.ParseAndroidChannels(channels)
	secret, err := gohttp.ResolveSecretKeyBase(os.Getenv, secretFile)
	if err != nil {
		fmt.Fprintf(stderr, "refused: %s\n", secretDiagnostic(err))
		return exitUsage
	}
	config.SecretKeyBase = secret
	logger := slog.New(slog.NewJSONHandler(stderr, nil))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	err = gohttp.Run(ctx, config, logger, func(address net.Addr) {
		logger.Info("listening", slog.String("address", address.String()))
	})
	var started gohttp.StartError
	switch {
	case err == nil:
		return 0
	case errors.As(err, &started) && started.Code == "lock-held":
		fmt.Fprintln(stderr, "refused: lock-held")
		return exitOwned
	case errors.As(err, &started):
		fmt.Fprintf(stderr, "refused: %s\n", started.Code)
		return exitUsage
	}
	logger.Error("stopped", slog.String("code", "serve-failed"))
	return exitFailed
}

func secretDiagnostic(err error) string {
	switch {
	case errors.Is(err, gohttp.ErrSecretMissing):
		return "secret-key-base-missing"
	case errors.Is(err, gohttp.ErrSecretAmbiguous):
		return "secret-key-base-ambiguous"
	case errors.Is(err, gohttp.ErrMasterKeyMode):
		return "master-key-mode-unsupported"
	}
	return "secret-key-base-unusable"
}

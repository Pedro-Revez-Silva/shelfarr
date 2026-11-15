package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/arcrypt"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/bundle"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/compat"
)

const (
	exitPassed  = 0
	exitFailed  = 1
	exitRefused = 2
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(arguments []string, stdout, stderr io.Writer) int {
	if len(arguments) == 0 || arguments[0] != "compat-check" {
		fmt.Fprintln(stderr, "usage: shelfarr-compat compat-check --bundle DIRECTORY [--timeout 60s] [--legacy-sha1]")
		return exitRefused
	}
	flags := flag.NewFlagSet("compat-check", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	directory := flags.String("bundle", "", "fixture bundle directory")
	timeout := flags.Duration("timeout", time.Minute, "cooperative time limit")
	legacy := flags.Bool("legacy-sha1", false, "also try the legacy SHA1 key derivation")
	if err := flags.Parse(arguments[1:]); err != nil || *directory == "" || *timeout <= 0 || *timeout > 10*time.Minute {
		fmt.Fprintln(stderr, "usage: shelfarr-compat compat-check --bundle DIRECTORY [--timeout 60s] [--legacy-sha1]")
		return exitRefused
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	report, err := compat.Run(ctx, *directory, compat.Options{Timeout: *timeout, LegacySHA1: *legacy})
	if err != nil {
		fmt.Fprintln(stderr, "refused:", describe(err))
		return exitRefused
	}
	encoder := json.NewEncoder(stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(report); err != nil {
		return exitRefused
	}
	if !report.Passed {
		return exitFailed
	}
	return exitPassed
}

func describe(err error) string {
	var typed *bundle.Error
	switch {
	case errors.As(err, &typed):
		return typed.Error()
	case errors.Is(err, context.DeadlineExceeded):
		return "time limit exceeded"
	case errors.Is(err, context.Canceled):
		return "interrupted"
	}
	if kind := arcrypt.KindOf(err); kind != "" {
		return "encryption " + string(kind)
	}
	return "bundle could not be read"
}

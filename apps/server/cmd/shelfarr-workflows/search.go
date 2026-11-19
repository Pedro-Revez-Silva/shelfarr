package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/acquisition"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/fault"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/gutenberg"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/netguard"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/wfstore"
)

const (
	maxRequestTimeout = time.Minute
	maxSearchDeadline = 20 * time.Minute
	settleTimeout     = 10 * time.Second

	codeSearchDeadline = "search-deadline"
)

type searchOptions struct {
	requestID      int64
	requestTimeout time.Duration
	deadline       time.Duration
	busy           time.Duration
}

func parseSearch(arguments []string, flags *flag.FlagSet, workdir *string, stderr io.Writer) (searchOptions, bool) {
	var options searchOptions
	request := flags.String("request", "", "")
	flags.DurationVar(&options.requestTimeout, "request-timeout", 15*time.Second, "")
	flags.DurationVar(&options.deadline, "deadline", 5*time.Minute, "")
	flags.DurationVar(&options.busy, "busy-timeout", 5*time.Second, "")
	valid := flags.Parse(arguments) == nil && *workdir != "" && flags.NArg() == 0
	if valid {
		options.requestID, valid = parseAccount(*request)
	}
	valid = valid && options.requestTimeout > 0 && options.requestTimeout <= maxRequestTimeout &&
		options.deadline > 0 && options.deadline <= maxSearchDeadline && options.busy > 0
	if !valid {
		fmt.Fprintln(stderr, usage)
	}
	return options, valid
}

func searchRequest(workdir string, options searchOptions, out *reporter) int {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	store, code := openStore(ctx, workdir, options.busy, out)
	if store == nil {
		return code
	}
	defer store.Close()
	claim, err := acquisition.ClaimRequest(ctx, store, options.requestID, time.Now())
	switch {
	case errors.Is(err, acquisition.ErrClaimed):
		out.emit("refused", map[string]any{"code": acquisition.ErrClaimed.Error()})
		return exitAlreadyOwned
	case acquisition.Refusal(err) != nil:
		return reject(acquisition.Refusal(err), out)
	case err != nil:
		fault.Observe(err)
		out.emit("error", map[string]any{"workflow": "search", "code": wfstore.CodeOf(err)})
		return exitRecoverable
	}
	out.emit("claimed", map[string]any{"request_id": strconv.FormatInt(claim.RequestID, 10), "generation": claim.Generation})

	searchCtx, cancel := context.WithTimeout(ctx, options.deadline)
	client := &gutenberg.Client{
		Origin:         claim.Config.Origin,
		HTTP:           netguard.NewClient(options.requestTimeout),
		RequestTimeout: options.requestTimeout,
		Heartbeat: func(ctx context.Context) error {
			return acquisition.Heartbeat(ctx, store, claim, time.Now())
		},
	}
	result, searchErr := client.Search(searchCtx, claim.Query)
	if searchErr == nil {
		searchErr = fault.Hit(searchCtx, "search.fetched")
	}
	interrupted := ctx.Err() != nil
	deadlineExceeded := errors.Is(searchCtx.Err(), context.DeadlineExceeded)
	cancel()

	settleCtx, settled := context.WithTimeout(context.WithoutCancel(ctx), settleTimeout)
	defer settled()
	publication, err := settle(settleCtx, store, claim, result, searchErr, interrupted, deadlineExceeded)
	fields := map[string]any{"request_id": strconv.FormatInt(claim.RequestID, 10), "generation": claim.Generation, "requests": result.Requests}
	switch {
	case errors.Is(err, acquisition.ErrSuperseded):
		fields["outcome"] = "superseded"
		out.emit("search", fields)
		return exitFenced
	case err != nil:
		fault.Observe(err)
		out.emit("error", map[string]any{"workflow": "search", "code": wfstore.CodeOf(err)})
		return exitRecoverable
	}
	fields["outcome"] = string(publication.Outcome)
	fields["candidates"] = len(result.Candidates)
	fields["withheld"] = result.Withheld
	fields["written"] = publication.Written
	fields["preserved"] = publication.Preserved
	fields["removed"] = publication.Removed
	if publication.Code != "" {
		fields["code"] = publication.Code
	}
	out.emit("search", fields)
	if publication.Outcome == acquisition.Failed || publication.Outcome == acquisition.Released {
		return exitRecoverable
	}
	return exitOK
}

func settle(ctx context.Context, store *wfstore.Store, claim acquisition.Claim, result gutenberg.Result, searchErr error, interrupted, deadlineExceeded bool) (acquisition.Publication, error) {
	now := time.Now()
	var provider *gutenberg.Error
	switch {
	case errors.Is(searchErr, acquisition.ErrSuperseded):
		return acquisition.Publication{}, searchErr
	case interrupted:
		return acquisition.Release(ctx, store, claim, wfstore.CodeCancelled, now)
	case deadlineExceeded:
		return acquisition.Release(ctx, store, claim, codeSearchDeadline, now)
	case errors.As(searchErr, &provider) && !provider.Transient:
		return acquisition.PublishFailure(ctx, store, claim, provider.Code, now)
	case errors.As(searchErr, &provider):
		return acquisition.Release(ctx, store, claim, provider.Code, now)
	case searchErr != nil:
		fault.Observe(searchErr)
		return acquisition.Release(ctx, store, claim, wfstore.CodeOf(searchErr), now)
	case len(result.Candidates) > 0:
		return acquisition.PublishCandidates(ctx, store, claim, result.Candidates, now)
	case result.Withheld > 0:
		return acquisition.Release(ctx, store, claim, acquisition.CodeUnsupportedCandidates, now)
	}
	return acquisition.PublishNoResults(ctx, store, claim, now)
}

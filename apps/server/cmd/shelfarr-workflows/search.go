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

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/acquire"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/acquisition"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/fault"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/wfstore"
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
	valid = valid && options.requestTimeout > 0 && options.requestTimeout <= acquire.MaxRequestTimeout &&
		options.deadline > 0 && options.deadline <= acquire.MaxSearchDeadline && options.busy > 0
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
	report, err := acquire.Search(ctx, store, options.requestID, acquire.SearchOptions{
		RequestTimeout: options.requestTimeout,
		Deadline:       options.deadline,
		Claimed: func(claim acquisition.Claim) {
			out.emit("claimed", map[string]any{"request_id": strconv.FormatInt(claim.RequestID, 10), "generation": claim.Generation})
		},
	})
	if !report.Claimed() {
		switch {
		case errors.Is(err, acquisition.ErrClaimed):
			out.emit("refused", map[string]any{"code": acquisition.ErrClaimed.Error()})
			return exitAlreadyOwned
		case acquisition.Refusal(err) != nil:
			return reject(acquisition.Refusal(err), out)
		}
		fault.Observe(err)
		out.emit("error", map[string]any{"workflow": "search", "code": wfstore.CodeOf(err)})
		return exitRecoverable
	}
	fields := map[string]any{"request_id": strconv.FormatInt(report.Claim.RequestID, 10), "generation": report.Claim.Generation, "requests": report.Requests}
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
	publication := report.Publication
	fields["outcome"] = string(publication.Outcome)
	fields["candidates"] = report.Candidates
	fields["withheld"] = report.Withheld
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

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
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/wfstore"
)

type downloadOptions struct {
	requestID      int64
	resultID       int64
	requestTimeout time.Duration
	deadline       time.Duration
	busy           time.Duration
}

func parseDownload(arguments []string, flags *flag.FlagSet, workdir *string, stderr io.Writer) (downloadOptions, bool) {
	var options downloadOptions
	request := flags.String("request", "", "")
	result := flags.String("result", "", "")
	flags.DurationVar(&options.requestTimeout, "request-timeout", 15*time.Second, "")
	flags.DurationVar(&options.deadline, "deadline", 10*time.Minute, "")
	flags.DurationVar(&options.busy, "busy-timeout", 5*time.Second, "")
	valid := flags.Parse(arguments) == nil && *workdir != "" && flags.NArg() == 0
	if valid {
		options.requestID, valid = parseAccount(*request)
	}
	if valid {
		options.resultID, valid = parseAccount(*result)
	}
	valid = valid && options.requestTimeout > 0 && options.requestTimeout <= acquire.MaxRequestTimeout &&
		options.deadline > 0 && options.deadline <= acquire.MaxDownloadDeadline && options.busy > 0
	if !valid {
		fmt.Fprintln(stderr, usage)
	}
	return options, valid
}

func downloadResult(workdir string, options downloadOptions, out *reporter) int {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	store, code := openStore(ctx, workdir, options.busy, out)
	if store == nil {
		return code
	}
	defer store.Close()
	report, err := acquire.Download(ctx, store, options.requestID, options.resultID, acquire.DownloadOptions{RequestTimeout: options.requestTimeout, Deadline: options.deadline})
	switch {
	case errors.Is(err, acquire.ErrBusy):
		out.emit("refused", map[string]any{"code": acquire.ErrBusy.Error()})
		return exitAlreadyOwned
	case acquisition.SelectionRefusal(err) != nil:
		return reject(acquisition.SelectionRefusal(err), out)
	case err != nil:
		out.emit("error", map[string]any{"workflow": "download", "code": wfstore.CodeOf(err)})
		return exitRecoverable
	}
	fields := map[string]any{"request_id": strconv.FormatInt(options.requestID, 10), "result_id": strconv.FormatInt(options.resultID, 10), "outcome": string(report.Outcome)}
	if report.Fetched {
		fields["bytes"] = report.Bytes
		fields["sha256"] = report.SHA256
	}
	switch report.Outcome {
	case acquire.AlreadyCompleted:
		fields["download_id"] = strconv.FormatInt(report.DownloadID, 10)
		out.emit("download", fields)
		return exitOK
	case acquire.Completed:
		fields["adopted"] = report.Adopted
		fields["download_id"] = strconv.FormatInt(report.DownloadID, 10)
		out.emit("download", fields)
		return exitOK
	case acquire.Superseded:
		out.emit("download", fields)
		return exitFenced
	}
	fields["code"] = report.Code
	out.emit("download", fields)
	return exitRecoverable
}

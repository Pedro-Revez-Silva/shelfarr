package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/acquisition"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/bookfile"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/fault"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/gutenberg"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/netguard"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/wfstore"
)

const (
	maxBookBytes        = 250 << 20
	maxDownloadDeadline = 30 * time.Minute
	acquisitionLock     = "acquisition"

	codeAcquisitionBusy = "acquisition_busy"
	codeDownloadInvalid = "download-invalid"
	codeDownloadExpired = "download-deadline"
	codeFileExists      = "library-file-exists"
	codePathUnsafe      = "library-path-unsafe"
	codeRootChanged     = "library-root-changed"
	codeStaging         = "staging-unavailable"
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
	valid = valid && options.requestTimeout > 0 && options.requestTimeout <= maxRequestTimeout &&
		options.deadline > 0 && options.deadline <= maxDownloadDeadline && options.busy > 0
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
	lock, err := store.Hold(acquisitionLock)
	if errors.Is(err, wfstore.ErrAlreadyOwned) {
		out.emit("refused", map[string]any{"code": codeAcquisitionBusy})
		return exitAlreadyOwned
	}
	if err != nil {
		return downloadError(err, out)
	}
	defer lock.Close()
	plan, err := acquisition.PlanSelection(ctx, store, options.requestID, options.resultID)
	if refusal := acquisition.SelectionRefusal(err); refusal != nil {
		return reject(refusal, out)
	}
	if err != nil {
		return downloadError(err, out)
	}
	fields := map[string]any{"request_id": strconv.FormatInt(options.requestID, 10), "result_id": strconv.FormatInt(options.resultID, 10)}
	if plan.Completed != 0 {
		fields["outcome"] = "already_completed"
		fields["download_id"] = strconv.FormatInt(plan.Completed, 10)
		out.emit("download", fields)
		return exitOK
	}
	selection := plan.Selection
	root, err := bookfile.OpenRoot(store.Dir, selection.Root)
	if err != nil {
		return reject(acquisition.ErrLibraryRoot, out)
	}
	staged, err := root.Stage()
	if err != nil {
		return failDownload(fields, codeStaging, out)
	}
	defer staged.Close()
	digest, failure := fetch(ctx, selection, staged, options)
	if failure != "" {
		return failDownload(fields, failure, out)
	}
	if ctx.Err() != nil {
		return failDownload(fields, wfstore.CodeCancelled, out)
	}
	fields["bytes"] = staged.Size
	fields["sha256"] = hex.EncodeToString(digest)
	settleCtx, settled := context.WithTimeout(context.WithoutCancel(ctx), settleTimeout)
	defer settled()
	return publish(settleCtx, store, root, staged, selection, digest, fields, out)
}

func fetch(ctx context.Context, selection acquisition.Selection, staged *bookfile.Staged, options downloadOptions) ([]byte, string) {
	fetchCtx, cancel := context.WithTimeout(ctx, options.deadline)
	defer cancel()
	httpClient := netguard.NewClient(options.requestTimeout)
	httpClient.Timeout = 0
	client := &gutenberg.Client{Origin: selection.Origin, HTTP: httpClient, RequestTimeout: options.requestTimeout}
	hash := sha256.New()
	_, err := client.Download(fetchCtx, selection.DownloadURL, io.MultiWriter(staged.File, hash), maxBookBytes)
	var provider *gutenberg.Error
	switch {
	case ctx.Err() != nil:
		return nil, wfstore.CodeCancelled
	case errors.Is(fetchCtx.Err(), context.DeadlineExceeded):
		return nil, codeDownloadExpired
	case errors.As(err, &provider):
		return nil, provider.Code
	case err != nil:
		fault.Observe(err)
		return nil, codeStaging
	}
	if err := staged.Seal(); err != nil {
		fault.Observe(err)
		return nil, codeStaging
	}
	if err := bookfile.CheckEPUB(fetchCtx, staged.File, staged.Size); err != nil {
		if ctx.Err() != nil {
			return nil, wfstore.CodeCancelled
		}
		return nil, codeDownloadInvalid
	}
	if err := fault.Hit(ctx, "download.fetched"); err != nil {
		return nil, wfstore.CodeOf(err)
	}
	return hash.Sum(nil), ""
}

func publish(ctx context.Context, store *wfstore.Store, root *bookfile.Root, staged *bookfile.Staged, selection acquisition.Selection, digest []byte, fields map[string]any, out *reporter) int {
	placement := bookfile.Placement{Folders: selection.Folders[:], Name: selection.Name}
	published, err := root.Publish(staged, placement, digest)
	switch {
	case errors.Is(err, bookfile.ErrExists):
		return failDownload(fields, codeFileExists, out)
	case errors.Is(err, bookfile.ErrUnsafe):
		return failDownload(fields, codePathUnsafe, out)
	case errors.Is(err, bookfile.ErrRootChanged):
		return failDownload(fields, codeRootChanged, out)
	case err != nil && !published.Linked:
		fault.Observe(err)
		return failDownload(fields, codeStaging, out)
	}
	withdraw := func() {
		if published.Linked {
			root.Remove(placement, published.Identity)
		}
	}
	if err == nil {
		err = fault.Hit(ctx, "download.linked")
	}
	if err != nil {
		withdraw()
		return downloadError(err, out)
	}
	verify := func() error {
		found, present, err := root.Identify(placement)
		if err != nil || !present || found != published.Identity {
			return acquisition.ErrSuperseded
		}
		return nil
	}
	downloadID, err := acquisition.Complete(ctx, store, selection, verify, time.Now())
	if err != nil {
		if referenced, checkErr := acquisition.Referenced(ctx, store, selection.BookPath()); checkErr != nil || referenced {
			return downloadError(err, out)
		}
		withdraw()
		if errors.Is(err, acquisition.ErrSuperseded) {
			fields["outcome"] = "superseded"
			out.emit("download", fields)
			return exitFenced
		}
		return downloadError(err, out)
	}
	fields["outcome"] = "completed"
	fields["adopted"] = !published.Linked
	fields["download_id"] = strconv.FormatInt(downloadID, 10)
	out.emit("download", fields)
	return exitOK
}

func failDownload(fields map[string]any, code string, out *reporter) int {
	fields["outcome"] = "failed"
	fields["code"] = code
	out.emit("download", fields)
	return exitRecoverable
}

func downloadError(err error, out *reporter) int {
	fault.Observe(err)
	out.emit("error", map[string]any{"workflow": "download", "code": wfstore.CodeOf(err)})
	return exitRecoverable
}

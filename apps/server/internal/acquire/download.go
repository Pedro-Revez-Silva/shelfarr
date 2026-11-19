package acquire

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/acquisition"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/bookfile"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/fault"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/gutenberg"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/netguard"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/wfstore"
)

const (
	MaxBookBytes        = 250 << 20
	MaxDownloadDeadline = 30 * time.Minute
	AcquisitionLock     = "acquisition"

	CodeDownloadInvalid = "download-invalid"
	CodeUnreadable      = "download-unreadable"
	CodeDownloadExpired = "download-deadline"
	CodeFileExists      = "library-file-exists"
	CodePathUnsafe      = "library-path-unsafe"
	CodeRootChanged     = "library-root-changed"
	CodeStaging         = "staging-unavailable"
)

var (
	ErrBusy    = errors.New("acquisition_busy")
	ErrRevoked = errors.New("authority_changed")
)

type DownloadOutcome string

const (
	AlreadyCompleted DownloadOutcome = "already_completed"
	Completed        DownloadOutcome = "completed"
	DownloadFailed   DownloadOutcome = "failed"
	Superseded       DownloadOutcome = "superseded"
	Revoked          DownloadOutcome = "revoked"
)

type DownloadOptions struct {
	RequestTimeout time.Duration
	Deadline       time.Duration
	Clock          func() time.Time
	AllowRoot      func(ctx context.Context, root string) bool
	Authorize      acquisition.Authorize
	Readable       bool
}

func (o DownloadOptions) now() time.Time {
	if o.Clock != nil {
		return o.Clock()
	}
	return time.Now()
}

type DownloadReport struct {
	Outcome    DownloadOutcome
	Code       string
	DownloadID int64
	Fetched    bool
	Bytes      int64
	SHA256     string
	Adopted    bool
}

func Download(ctx context.Context, store *wfstore.Store, requestID, resultID int64, options DownloadOptions) (DownloadReport, error) {
	lock, err := store.HoldBeneath(AcquisitionLock)
	if errors.Is(err, wfstore.ErrAlreadyOwned) {
		return DownloadReport{}, ErrBusy
	}
	if err != nil {
		fault.Observe(err)
		return DownloadReport{}, err
	}
	defer lock.Close()
	plan, err := acquisition.PlanSelection(ctx, store, requestID, resultID)
	if refusal := acquisition.SelectionRefusal(err); refusal != nil {
		return DownloadReport{}, refusal
	}
	if err != nil {
		fault.Observe(err)
		return DownloadReport{}, err
	}
	if plan.Completed != 0 {
		return DownloadReport{Outcome: AlreadyCompleted, DownloadID: plan.Completed}, nil
	}
	selection := plan.Selection
	if options.AllowRoot != nil && !options.AllowRoot(ctx, selection.Root) {
		return DownloadReport{}, acquisition.ErrLibraryRoot
	}
	root, err := bookfile.OpenRoot(store.Dir, selection.Root)
	if err != nil {
		return DownloadReport{}, acquisition.ErrLibraryRoot
	}
	staged, err := root.Stage()
	if err != nil {
		return failed(DownloadReport{}, CodeStaging), nil
	}
	defer staged.Close()
	digest, failure := fetch(ctx, selection, staged, options)
	if failure != "" {
		return failed(DownloadReport{}, failure), nil
	}
	if ctx.Err() != nil {
		return failed(DownloadReport{}, wfstore.CodeCancelled), nil
	}
	report := DownloadReport{Fetched: true, Bytes: staged.Size, SHA256: hex.EncodeToString(digest)}
	settleCtx, settled := context.WithTimeout(context.WithoutCancel(ctx), SettleTimeout)
	defer settled()
	return publish(settleCtx, store, root, staged, selection, digest, report, options)
}

func failed(report DownloadReport, code string) DownloadReport {
	report.Outcome = DownloadFailed
	report.Code = code
	return report
}

func fetch(ctx context.Context, selection acquisition.Selection, staged *bookfile.Staged, options DownloadOptions) ([]byte, string) {
	fetchCtx, cancel := context.WithTimeout(ctx, options.Deadline)
	defer cancel()
	httpClient := netguard.NewClient(options.RequestTimeout)
	httpClient.Timeout = 0
	client := &gutenberg.Client{Origin: selection.Origin, HTTP: httpClient, RequestTimeout: options.RequestTimeout}
	hash := sha256.New()
	_, err := client.Download(fetchCtx, selection.DownloadURL, io.MultiWriter(staged.File, hash), MaxBookBytes)
	var provider *gutenberg.Error
	switch {
	case ctx.Err() != nil:
		return nil, wfstore.CodeCancelled
	case errors.Is(fetchCtx.Err(), context.DeadlineExceeded):
		return nil, CodeDownloadExpired
	case errors.As(err, &provider):
		return nil, provider.Code
	case err != nil:
		fault.Observe(err)
		return nil, CodeStaging
	}
	if err := staged.Seal(); err != nil {
		fault.Observe(err)
		return nil, CodeStaging
	}
	if err := bookfile.CheckEPUB(fetchCtx, staged.File, staged.Size); err != nil {
		if ctx.Err() != nil {
			return nil, wfstore.CodeCancelled
		}
		return nil, CodeDownloadInvalid
	}
	if options.Readable {
		if err := bookfile.CheckReadableEPUB(fetchCtx, staged.File, staged.Size); err != nil {
			if ctx.Err() != nil {
				return nil, wfstore.CodeCancelled
			}
			return nil, CodeUnreadable
		}
	}
	if err := fault.Hit(ctx, "download.fetched"); err != nil {
		return nil, wfstore.CodeOf(err)
	}
	return hash.Sum(nil), ""
}

func publish(ctx context.Context, store *wfstore.Store, root *bookfile.Root, staged *bookfile.Staged, selection acquisition.Selection, digest []byte, report DownloadReport, options DownloadOptions) (DownloadReport, error) {
	placement := bookfile.Placement{Folders: selection.Folders[:], Name: selection.Name}
	published, err := root.Publish(staged, placement, digest)
	switch {
	case errors.Is(err, bookfile.ErrExists):
		return failed(report, CodeFileExists), nil
	case errors.Is(err, bookfile.ErrUnsafe):
		return failed(report, CodePathUnsafe), nil
	case errors.Is(err, bookfile.ErrRootChanged):
		return failed(report, CodeRootChanged), nil
	case err != nil && !published.Linked:
		fault.Observe(err)
		return failed(report, CodeStaging), nil
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
		fault.Observe(err)
		return report, err
	}
	verify := func() error {
		found, present, err := root.Identify(placement)
		if err != nil || !present || found != published.Identity {
			return acquisition.ErrSuperseded
		}
		return nil
	}
	downloadID, err := acquisition.Complete(ctx, store, selection, options.Authorize, verify, options.now())
	if err != nil {
		if referenced, checkErr := acquisition.Referenced(ctx, store, selection.BookPath()); checkErr != nil || referenced {
			fault.Observe(err)
			return report, err
		}
		withdraw()
		if errors.Is(err, acquisition.ErrSuperseded) {
			report.Outcome = Superseded
			return report, nil
		}
		if errors.Is(err, ErrRevoked) {
			report.Outcome = Revoked
			return report, nil
		}
		fault.Observe(err)
		return report, err
	}
	report.Outcome = Completed
	report.Adopted = !published.Linked
	report.DownloadID = downloadID
	return report, nil
}

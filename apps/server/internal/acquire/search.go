package acquire

import (
	"context"
	"errors"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/acquisition"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/fault"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/gutenberg"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/netguard"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/wfstore"
)

const (
	MaxRequestTimeout = time.Minute
	MaxSearchDeadline = 20 * time.Minute
	SettleTimeout     = 10 * time.Second

	CodeSearchDeadline = "search-deadline"
)

type SearchOptions struct {
	RequestTimeout time.Duration
	Deadline       time.Duration
	Clock          func() time.Time
	Claimed        func(acquisition.Claim)
}

func (o SearchOptions) now() time.Time {
	if o.Clock != nil {
		return o.Clock()
	}
	return time.Now()
}

type SearchReport struct {
	Claim       acquisition.Claim
	Requests    int
	Candidates  int
	Withheld    int
	Publication acquisition.Publication
}

func (r SearchReport) Claimed() bool { return r.Claim.RequestID != 0 }

func Search(ctx context.Context, store *wfstore.Store, requestID int64, options SearchOptions) (SearchReport, error) {
	claim, err := acquisition.ClaimRequest(ctx, store, requestID, options.now())
	if err != nil {
		return SearchReport{}, err
	}
	report := SearchReport{Claim: claim}
	if options.Claimed != nil {
		options.Claimed(claim)
	}

	searchCtx, cancel := context.WithTimeout(ctx, options.Deadline)
	client := &gutenberg.Client{
		Origin:         claim.Config.Origin,
		HTTP:           netguard.NewClient(options.RequestTimeout),
		RequestTimeout: options.RequestTimeout,
		Heartbeat: func(ctx context.Context) error {
			return acquisition.Heartbeat(ctx, store, claim, options.now())
		},
	}
	result, searchErr := client.Search(searchCtx, claim.Query)
	if searchErr == nil {
		searchErr = fault.Hit(searchCtx, "search.fetched")
	}
	interrupted := ctx.Err() != nil
	deadlineExceeded := errors.Is(searchCtx.Err(), context.DeadlineExceeded)
	cancel()
	report.Requests = result.Requests

	settleCtx, settled := context.WithTimeout(context.WithoutCancel(ctx), SettleTimeout)
	defer settled()
	publication, err := settle(settleCtx, store, claim, result, searchErr, interrupted, deadlineExceeded, options.now())
	if err != nil {
		return report, err
	}
	report.Publication = publication
	report.Candidates = len(result.Candidates)
	report.Withheld = result.Withheld
	return report, nil
}

func settle(ctx context.Context, store *wfstore.Store, claim acquisition.Claim, result gutenberg.Result, searchErr error, interrupted, deadlineExceeded bool, now time.Time) (acquisition.Publication, error) {
	var provider *gutenberg.Error
	switch {
	case errors.Is(searchErr, acquisition.ErrSuperseded):
		return acquisition.Publication{}, searchErr
	case interrupted:
		return acquisition.Release(ctx, store, claim, wfstore.CodeCancelled, now)
	case deadlineExceeded:
		return acquisition.Release(ctx, store, claim, CodeSearchDeadline, now)
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

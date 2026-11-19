package gohttp

import (
	"context"
	"database/sql"
	"errors"
	"log/slog"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/acquire"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/acquisition"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/bookfile"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/wfstore"
)

const (
	acquisitionLockName   = "http.lock"
	defaultAcquisitionGap = 2 * time.Second
	providerTimeout       = 15 * time.Second
	searchDeadline        = 5 * time.Minute
	downloadDeadline      = 10 * time.Minute
	claimedElsewhereWait  = time.Minute
	failedSearchWait      = time.Minute
	refusedSearchWait     = 15 * time.Minute
	longestReleaseWait    = 15 * time.Minute
	pendingScan           = 100
	maxRememberedJobs     = 64

	selectionQueued      = "queued"
	selectionDownloading = "downloading"
	selectionFailed      = "failed"
	selectionCompleted   = "completed"

	searchRetryScheduled = "retry_scheduled"
	searchRefused        = "refused"
	searchWaiting        = "waiting"
)

var errAcquisitionBusy = errors.New("acquisition_busy")

type parkedSearch struct {
	state string
	code  string
	until time.Time
	wait  time.Duration
}

type selectionJob struct {
	requestID int64
	resultID  int64
	sessionID int64
	userID    int64
	state     string
	code      string
}

type acquisitionService struct {
	store   *wfstore.Store
	offers  *offeredWorks
	logger  *slog.Logger
	now     func() time.Time
	wake    chan struct{}
	stopped chan struct{}

	mutex  sync.Mutex
	parked map[int64]parkedSearch
	jobs   map[int64]*selectionJob
	order  []int64
	active *selectionJob

	authority func(ctx context.Context, tx *sql.Tx, job selectionJob) error
	allowRoot func(root string) bool
}

const requestScope = `b.book_type = 1 AND b.open_library_work_id IS NOT NULL AND r.created_via = 'api' AND r.external_source = 'consumer_app'`

func loopbackOrigin(origin string) bool {
	parsed, err := url.Parse(origin)
	if err != nil {
		return false
	}
	ip := net.ParseIP(parsed.Hostname())
	return ip != nil && ip.IsLoopback()
}

func loopbackAddress(address string) bool {
	host, port, err := net.SplitHostPort(address)
	ip := net.ParseIP(host)
	return err == nil && port != "" && ip != nil && ip.IsLoopback()
}

func privateDirectory(path string) bool {
	info, err := os.Lstat(path)
	return err == nil && info.IsDir() && info.Mode()&os.ModeSymlink == 0 && info.Mode().Perm()&0o077 == 0
}

func acquisitionPreflight(config Config) string {
	dir := config.AcquisitionWorkdir
	if !filepath.IsAbs(dir) || filepath.Clean(dir) != dir ||
		config.DatabasePath != filepath.Join(dir, wfstore.DatabaseName) ||
		config.LockPath != filepath.Join(dir, wfstore.LocksDir, acquisitionLockName) ||
		config.AllowPublicBind || !loopbackOrigin(config.BrowserOrigin) || len(config.PreviewUserIDs) == 0 ||
		!privateDirectory(dir) || !privateDirectory(filepath.Join(dir, wfstore.LocksDir)) {
		return "acquisition-volume"
	}
	if config.OpenLibrarySearch && !loopbackAddress(config.OpenLibraryFixture) {
		return "acquisition-network"
	}
	return ""
}

func openAcquisition(ctx context.Context, config Config, roots []string, logger *slog.Logger, now func() time.Time) (*acquisitionService, string) {
	store, err := wfstore.Open(ctx, config.AcquisitionWorkdir, wfstore.Options{BusyTimeoutMillis: int(config.BusyTimeout / time.Millisecond)})
	if err != nil {
		return nil, "acquisition-volume"
	}
	root, err := acquisition.VolumeLibraryRoot(ctx, store)
	if err == nil {
		_, err = bookfile.OpenRoot(store.Dir, root)
	}
	if err != nil || !withinAny(root, roots) {
		store.Close()
		return nil, "acquisition-settings"
	}
	return &acquisitionService{
		store:   store,
		offers:  newOfferedWorks(now),
		logger:  logger,
		now:     now,
		wake:    make(chan struct{}, 1),
		stopped: make(chan struct{}),
		parked:  map[int64]parkedSearch{},
		jobs:    map[int64]*selectionJob{},
	}, ""
}

func (s *acquisitionService) close() { s.store.Close() }

func (s *acquisitionService) nudge() {
	select {
	case s.wake <- struct{}{}:
	default:
	}
}

func (s *acquisitionService) run(ctx context.Context) {
	defer close(s.stopped)
	for ctx.Err() == nil {
		if job, found := s.nextSelection(); found {
			s.download(ctx, job)
			continue
		}
		requestID, found, err := s.nextSearch(ctx)
		if err != nil {
			s.logger.Warn("acquisition", slog.String("step", "scan"), slog.String("code", wfstore.CodeOf(err)))
		}
		if found {
			s.search(ctx, requestID)
			continue
		}
		timer := time.NewTimer(defaultAcquisitionGap)
		select {
		case <-ctx.Done():
		case <-s.wake:
		case <-timer.C:
		}
		timer.Stop()
	}
}

func (s *acquisitionService) nextSearch(ctx context.Context) (int64, bool, error) {
	now := s.now()
	stale := wfstore.FormatTimestamp(now.Add(-acquisition.StaleSearchLease))
	due := wfstore.FormatTimestamp(now)
	for offset := 0; ; offset += pendingScan {
		ids, err := s.claimable(ctx, stale, due, offset)
		if err != nil {
			return 0, false, err
		}
		if id, found := s.firstUnparked(ids, now); found {
			return id, true, nil
		}
		if len(ids) < pendingScan {
			return 0, false, nil
		}
	}
}

func (s *acquisitionService) claimable(ctx context.Context, stale, due string, offset int) ([]int64, error) {
	rows, err := s.store.DB().QueryContext(ctx, `SELECT r.id FROM requests r JOIN books b ON b.id = r.book_id
		WHERE `+requestScope+` AND (r.status = 0 OR (r.status = 1 AND r.search_claimed_at IS NOT NULL AND r.search_claimed_at <= ?)
			OR (r.status = 2 AND r.next_retry_at IS NOT NULL AND r.next_retry_at <= ?))
		ORDER BY r.created_at, r.id LIMIT ? OFFSET ?`, stale, due, pendingScan, offset)
	if err != nil {
		return nil, wfstore.Wrap(err)
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, wfstore.Wrap(err)
		}
		ids = append(ids, id)
	}
	return ids, wfstore.Wrap(rows.Err())
}

func (s *acquisitionService) firstUnparked(ids []int64, now time.Time) (int64, bool) {
	s.mutex.Lock()
	defer s.mutex.Unlock()
	for _, id := range ids {
		if parked, found := s.parked[id]; !found || !now.Before(parked.until) {
			return id, true
		}
	}
	return 0, false
}

func (s *acquisitionService) inScope(ctx context.Context, requestID int64) (bool, error) {
	var count int
	err := s.store.DB().QueryRowContext(ctx, `SELECT COUNT(*) FROM requests r JOIN books b ON b.id = r.book_id WHERE r.id = ? AND `+requestScope, requestID).Scan(&count)
	return count == 1, wfstore.Wrap(err)
}

func (s *acquisitionService) search(ctx context.Context, requestID int64) {
	if _, err := acquisition.RequeueDue(ctx, s.store, requestID, s.now()); err != nil {
		s.park(requestID, searchWaiting, wfstore.CodeOf(err), failedSearchWait)
		s.logger.Warn("acquisition", slog.String("step", "requeue"), slog.Int64("request_id", requestID), slog.String("code", wfstore.CodeOf(err)))
		return
	}
	report, err := acquire.Search(ctx, s.store, requestID, acquire.SearchOptions{RequestTimeout: providerTimeout, Deadline: searchDeadline, Clock: s.now})
	attributes := []any{slog.String("step", "search"), slog.Int64("request_id", requestID)}
	switch {
	case !report.Claimed() && errors.Is(err, acquisition.ErrClaimed):
		s.park(requestID, searchWaiting, acquisition.ErrClaimed.Error(), claimedElsewhereWait)
		attributes = append(attributes, slog.String("outcome", "claimed_elsewhere"))
	case !report.Claimed() && acquisition.Refusal(err) != nil:
		s.park(requestID, searchRefused, acquisition.Refusal(err).Error(), refusedSearchWait)
		attributes = append(attributes, slog.String("outcome", "refused"), slog.String("code", acquisition.Refusal(err).Error()))
	case errors.Is(err, acquisition.ErrSuperseded):
		s.unpark(requestID)
		attributes = append(attributes, slog.String("outcome", "superseded"))
	case err != nil:
		s.park(requestID, searchWaiting, wfstore.CodeOf(err), failedSearchWait)
		attributes = append(attributes, slog.String("outcome", "error"), slog.String("code", wfstore.CodeOf(err)))
	case report.Publication.Outcome == acquisition.Released:
		s.backOff(requestID, report.Publication.Code)
		attributes = append(attributes, slog.String("outcome", string(acquisition.Released)), slog.String("code", report.Publication.Code))
	default:
		s.unpark(requestID)
		attributes = append(attributes, slog.String("outcome", string(report.Publication.Outcome)), slog.Int("candidates", report.Candidates))
		if report.Publication.Code != "" {
			attributes = append(attributes, slog.String("code", report.Publication.Code))
		}
	}
	s.logger.Info("acquisition", attributes...)
}

func (s *acquisitionService) park(requestID int64, state, code string, wait time.Duration) {
	s.mutex.Lock()
	defer s.mutex.Unlock()
	s.prune()
	s.parked[requestID] = parkedSearch{state: state, code: code, until: s.now().Add(wait), wait: wait}
}

func (s *acquisitionService) prune() {
	forgotten := s.now().Add(-2 * longestReleaseWait)
	for id, parked := range s.parked {
		if parked.until.Before(forgotten) {
			delete(s.parked, id)
		}
	}
}

func (s *acquisitionService) backOff(requestID int64, code string) {
	s.mutex.Lock()
	defer s.mutex.Unlock()
	s.prune()
	wait := failedSearchWait
	if previous, found := s.parked[requestID]; found && previous.state == searchRetryScheduled {
		wait = min(previous.wait*2, longestReleaseWait)
	}
	s.parked[requestID] = parkedSearch{state: searchRetryScheduled, code: code, until: s.now().Add(wait), wait: wait}
}

func (s *acquisitionService) unpark(requestID int64) {
	s.mutex.Lock()
	defer s.mutex.Unlock()
	delete(s.parked, requestID)
}

func (s *acquisitionService) searchNote(requestID int64) (parkedSearch, bool) {
	s.mutex.Lock()
	defer s.mutex.Unlock()
	parked, found := s.parked[requestID]
	return parked, found
}

func (s *acquisitionService) enqueue(job selectionJob) (selectionJob, error) {
	s.mutex.Lock()
	defer s.mutex.Unlock()
	if s.active != nil {
		if s.active.requestID == job.requestID && s.active.resultID == job.resultID {
			if s.active.state == selectionQueued {
				s.active.sessionID, s.active.userID = job.sessionID, job.userID
			}
			return *s.active, nil
		}
		return *s.active, errAcquisitionBusy
	}
	job.state = selectionQueued
	stored := job
	s.active = &stored
	s.remember(&stored)
	s.nudge()
	return stored, nil
}

func (s *acquisitionService) remember(job *selectionJob) {
	if _, known := s.jobs[job.requestID]; !known {
		s.order = append(s.order, job.requestID)
	}
	s.jobs[job.requestID] = job
	for len(s.order) > maxRememberedJobs {
		oldest := s.order[0]
		s.order = s.order[1:]
		if s.active == nil || s.active.requestID != oldest {
			delete(s.jobs, oldest)
		}
	}
}

func (s *acquisitionService) selection(requestID int64) (selectionJob, bool) {
	s.mutex.Lock()
	defer s.mutex.Unlock()
	job, found := s.jobs[requestID]
	if !found {
		return selectionJob{}, false
	}
	return *job, true
}

func (s *acquisitionService) nextSelection() (selectionJob, bool) {
	s.mutex.Lock()
	defer s.mutex.Unlock()
	if s.active == nil || s.active.state != selectionQueued {
		return selectionJob{}, false
	}
	s.active.state = selectionDownloading
	return *s.active, true
}

func (s *acquisitionService) finish(state, code string) {
	s.mutex.Lock()
	defer s.mutex.Unlock()
	if s.active == nil {
		return
	}
	s.active.state = state
	s.active.code = code
	s.active = nil
}

func (s *acquisitionService) download(ctx context.Context, job selectionJob) {
	attributes := []any{slog.String("step", "download"), slog.Int64("request_id", job.requestID), slog.Int64("result_id", job.resultID)}
	options := acquire.DownloadOptions{RequestTimeout: providerTimeout, Deadline: downloadDeadline, Clock: s.now, AllowRoot: s.allowRoot}
	if s.authority != nil {
		options.Authorize = func(ctx context.Context, tx *sql.Tx) error { return s.authority(ctx, tx, job) }
		if err := s.store.Transact(ctx, func(tx *sql.Tx) error { return options.Authorize(ctx, tx) }); err != nil {
			code := wfstore.CodeOf(err)
			if errors.Is(err, acquire.ErrRevoked) {
				code = acquire.ErrRevoked.Error()
			}
			s.finish(selectionFailed, code)
			s.logger.Info("acquisition", append(attributes, slog.String("outcome", selectionFailed), slog.String("code", code))...)
			return
		}
	}
	report, err := acquire.Download(ctx, s.store, job.requestID, job.resultID, options)
	state, code := selectionFailed, ""
	switch {
	case errors.Is(err, acquire.ErrBusy):
		code = acquire.ErrBusy.Error()
	case acquisition.SelectionRefusal(err) != nil:
		code = acquisition.SelectionRefusal(err).Error()
	case err != nil:
		code = wfstore.CodeOf(err)
	case report.Outcome == acquire.Completed || report.Outcome == acquire.AlreadyCompleted:
		state = selectionCompleted
	case report.Outcome == acquire.Superseded:
		code = string(acquire.Superseded)
	case report.Outcome == acquire.Revoked:
		code = acquire.ErrRevoked.Error()
	default:
		code = report.Code
	}
	s.finish(state, code)
	attributes = append(attributes, slog.String("outcome", state))
	if code != "" {
		attributes = append(attributes, slog.String("code", code))
	}
	s.logger.Info("acquisition", attributes...)
}

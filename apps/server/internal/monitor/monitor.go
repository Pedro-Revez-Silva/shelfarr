package monitor

import (
	"context"
	"database/sql"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/arcrypt"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/fault"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/qbit"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/wfstore"
)

const (
	Domain            = "downloads"
	NotFoundThreshold = 3
	eventSource       = "GoDownloadMonitor"
	maxCandidates     = 2000

	statusQueued      = 0
	statusDownloading = 1
	statusCompleted   = 3

	BlockedClientFailure  = "client-reported-failure"
	BlockedNotFound       = "not-found-threshold"
	BlockedClientType     = "client-unsupported"
	BlockedDirect         = "direct-download-unsupported"
	BlockedNotDispatched  = "not-dispatched"
	ErrorCredentials      = "credential-decrypt"
	CodePassDeadline      = "pass-deadline"
	OutcomeNotDue         = "not-due"
	OutcomeCancelled      = "schedule-cancelled"
	OutcomeCycleCompleted = "cycle-completed"
)

type Event func(name string, fields map[string]any)

type Workflow struct {
	Owner          *wfstore.Owner
	Now            func() time.Time
	QBit           qbit.Config
	Concurrency    int
	PassDeadline   time.Duration
	HandoffURL     string
	HandoffBackoff time.Duration
	HandoffTimeout time.Duration
	Report         Event
}

type Totals struct {
	Observed    int
	Progressed  int
	Completed   int
	NotFound    int
	Blocked     int
	Errors      int
	Stale       int
	Interrupted int
}

type CycleResult struct {
	Outcome string
	Totals  Totals
}

type candidate struct {
	ID             int64
	RequestID      int64
	Status         int
	ExternalID     string
	ClientRef      sql.NullString
	DownloadType   string
	SearchResultID sql.NullInt64
	Progress       int
	NotFoundCount  int
	Client         *clientRow
}

type clientRow struct {
	ID       int64
	Type     string
	URL      string
	Username sql.NullString
	Password sql.NullString
	APIKey   sql.NullString
	Enabled  bool
}

func (c candidate) token() string {
	return fmt.Sprintf("%d:%d:%s:%s:%d", c.ID, c.RequestID, c.ClientRef.String, c.ExternalID, c.SearchResultID.Int64)
}

func (w *Workflow) now() time.Time {
	if w.Now != nil {
		return w.Now()
	}
	return time.Now()
}

func (w *Workflow) report(name string, fields map[string]any) {
	if w.Report != nil {
		w.Report(name, fields)
	}
}

func (w *Workflow) Cycle(ctx context.Context) (CycleResult, error) {
	due, outcome, controlSeq, err := w.due(ctx)
	if err != nil || !due {
		return CycleResult{Outcome: outcome}, err
	}
	deadline := w.PassDeadline
	if deadline <= 0 {
		deadline = 2 * time.Minute
	}
	cycleCtx, cancel := context.WithTimeout(ctx, deadline)
	defer cancel()
	candidates, err := w.candidates(cycleCtx)
	if err != nil {
		return CycleResult{}, err
	}
	totals, err := w.pollAll(cycleCtx, candidates)
	result := CycleResult{Outcome: OutcomeCycleCompleted, Totals: totals}
	if err != nil {
		return result, err
	}
	if cycleCtx.Err() != nil {
		if ctx.Err() == nil {
			return result, wfstore.Fail(CodePassDeadline, nil)
		}
		return result, ctx.Err()
	}
	w.report("downloads.cycle", map[string]any{"observed": totals.Observed, "progressed": totals.Progressed, "completed": totals.Completed, "not_found": totals.NotFound, "blocked": totals.Blocked, "errors": totals.Errors, "stale": totals.Stale})
	return result, w.finishCycle(ctx, controlSeq)
}

func (w *Workflow) due(ctx context.Context) (bool, string, int64, error) {
	schedule, err := wfstore.ReadSchedule(ctx, w.Owner.Store().DB(), Domain)
	if err != nil {
		return false, "", 0, wfstore.Wrap(err)
	}
	switch {
	case schedule.State != "enabled":
		return false, OutcomeCancelled, 0, nil
	case schedule.NextDueAt > wfstore.FormatTimestamp(w.now()):
		return false, OutcomeNotDue, 0, nil
	}
	return true, "", schedule.ControlSeq, nil
}

func (w *Workflow) finishCycle(ctx context.Context, controlSeq int64) error {
	return w.Owner.Write(ctx, func(tx *sql.Tx) error {
		value, err := wfstore.Setting(ctx, tx, "download_check_interval")
		if err != nil {
			return err
		}
		interval := 60
		if parsed, err := strconv.Atoi(strings.TrimSpace(value)); err == nil {
			interval = min(max(parsed, 1), 86_400)
		}
		now := w.now()
		_, err = w.Owner.ConsumeSlot(ctx, tx, Domain, controlSeq, now, now.Add(time.Duration(interval)*time.Second), "cycle-completed")
		return err
	})
}

const candidateQuery = `
SELECT d.id, d.request_id, d.status, COALESCE(d.external_id, ''), d.download_client_id, COALESCE(d.download_type, ''), d.search_result_id, COALESCE(d.progress, 0), d.not_found_count,
       c.id, c.client_type, c.url, c.username, c.password, c.api_key, c.enabled
FROM downloads d
LEFT JOIN download_clients c ON CAST(c.id AS TEXT) = d.download_client_id
WHERE d.status IN (0, 1)
ORDER BY d.id
LIMIT ?`

func (w *Workflow) candidates(ctx context.Context) ([]candidate, error) {
	rows, err := w.Owner.Store().DB().QueryContext(ctx, candidateQuery, maxCandidates)
	if err != nil {
		return nil, wfstore.Wrap(err)
	}
	defer rows.Close()
	var found []candidate
	for rows.Next() {
		var entry candidate
		var clientID sql.NullInt64
		var clientType, clientURL sql.NullString
		var username, password, apiKey sql.NullString
		var enabled sql.NullBool
		if err := rows.Scan(&entry.ID, &entry.RequestID, &entry.Status, &entry.ExternalID, &entry.ClientRef, &entry.DownloadType, &entry.SearchResultID, &entry.Progress, &entry.NotFoundCount,
			&clientID, &clientType, &clientURL, &username, &password, &apiKey, &enabled); err != nil {
			return nil, wfstore.Wrap(err)
		}
		if clientID.Valid {
			entry.Client = &clientRow{ID: clientID.Int64, Type: clientType.String, URL: clientURL.String, Username: username, Password: password, APIKey: apiKey, Enabled: enabled.Bool}
		}
		found = append(found, entry)
	}
	return found, wfstore.Wrap(rows.Err())
}

type sessions struct {
	mutex     sync.Mutex
	clients   map[int64]*qbit.Client
	failures  map[int64]string
	decryptor *arcrypt.Decryptor
	template  qbit.Config
}

func (s *sessions) client(row *clientRow) (*qbit.Client, string) {
	s.mutex.Lock()
	defer s.mutex.Unlock()
	if built, ok := s.clients[row.ID]; ok {
		return built, ""
	}
	if code, ok := s.failures[row.ID]; ok {
		return nil, code
	}
	config := s.template
	config.BaseURL = row.URL
	config.Username = row.Username.String
	var ok bool
	if config.Password, ok = s.decrypt(row.Password); !ok {
		s.failures[row.ID] = ErrorCredentials
		return nil, ErrorCredentials
	}
	if config.APIKey, ok = s.decrypt(row.APIKey); !ok {
		s.failures[row.ID] = ErrorCredentials
		return nil, ErrorCredentials
	}
	built, err := qbit.NewClient(config)
	if err != nil {
		code := qbit.CodeOf(err)
		s.failures[row.ID] = code
		return nil, code
	}
	s.clients[row.ID] = built
	return built, ""
}

func (s *sessions) decrypt(value sql.NullString) (string, bool) {
	if !value.Valid || value.String == "" {
		return "", true
	}
	plain, err := s.decryptor.Decrypt([]byte(value.String))
	if err != nil {
		return "", false
	}
	return string(plain), true
}

func (w *Workflow) pollAll(ctx context.Context, candidates []candidate) (Totals, error) {
	keys := w.Owner.Store().Keys()
	decryptor, err := arcrypt.NewDecryptor(keys.PrimaryKey, keys.KeyDerivationSalt, arcrypt.Options{LegacySHA1: keys.LegacySHA1})
	if err != nil {
		return Totals{}, wfstore.Fail(wfstore.CodeDatabase, err)
	}
	pool := &sessions{clients: map[int64]*qbit.Client{}, failures: map[int64]string{}, decryptor: decryptor, template: w.QBit}
	workers := w.Concurrency
	if workers <= 0 {
		workers = 4
	}
	var (
		mutex  sync.Mutex
		totals Totals
		fatal  error
		first  error
		group  sync.WaitGroup
		slots  = make(chan struct{}, workers)
	)
	for _, entry := range candidates {
		if ctx.Err() != nil {
			break
		}
		slots <- struct{}{}
		group.Add(1)
		go func(entry candidate) {
			defer func() {
				<-slots
				group.Done()
			}()
			verdict, err := w.handle(ctx, pool, entry)
			mutex.Lock()
			defer mutex.Unlock()
			verdict.addTo(&totals)
			switch {
			case err == nil:
			case wfstore.CodeOf(err) == wfstore.CodeFenced:
				if fatal == nil {
					fatal = err
				}
			case first == nil && ctx.Err() == nil:
				first = err
			}
		}(entry)
	}
	group.Wait()
	if fatal != nil {
		return totals, fatal
	}
	return totals, first
}

type verdict struct {
	observed, progressed, completed, notFound, blocked, failed, stale, interrupted bool
}

func (v verdict) addTo(totals *Totals) {
	count := func(flag bool, target *int) {
		if flag {
			*target++
		}
	}
	count(v.observed, &totals.Observed)
	count(v.progressed, &totals.Progressed)
	count(v.completed, &totals.Completed)
	count(v.notFound, &totals.NotFound)
	count(v.blocked, &totals.Blocked)
	count(v.failed, &totals.Errors)
	count(v.stale, &totals.Stale)
	count(v.interrupted, &totals.Interrupted)
}

func (w *Workflow) handle(ctx context.Context, pool *sessions, entry candidate) (result verdict, err error) {
	defer func() {
		if recovered := recover(); recovered != nil {
			result.failed = true
			err = wfstore.Fail("panic", fmt.Errorf("recovered"))
			w.report("downloads.panic", map[string]any{"download": entry.ID})
		}
	}()
	if blocked := staticBlock(entry); blocked != "" {
		result.blocked = true
		return result, w.recordState(ctx, entry, "", blocked, false)
	}
	if entry.Client == nil || !entry.Client.Enabled {
		return result, nil
	}
	client, code := pool.client(entry.Client)
	if client == nil {
		result.failed = true
		return result, w.recordState(ctx, entry, code, "", true)
	}
	torrent, pollErr := client.Torrent(ctx, entry.ExternalID)
	if pollErr != nil {
		if ctx.Err() != nil {
			result.interrupted = true
			return result, nil
		}
		result.failed = true
		return result, w.recordState(ctx, entry, qbit.CodeOf(pollErr), "", true)
	}
	result.observed = true
	if err := fault.Hit(ctx, "monitor.observed"); err != nil {
		return result, err
	}
	switch {
	case torrent == nil:
		return w.applyNotFound(ctx, entry, result)
	case torrent.State == qbit.Completed:
		return w.applyCompletion(ctx, entry, torrent, result)
	}
	return w.applyProgress(ctx, entry, torrent, result)
}

func staticBlock(entry candidate) string {
	switch {
	case entry.DownloadType == "direct":
		return BlockedDirect
	case entry.ExternalID == "":
		return BlockedNotDispatched
	case entry.Client != nil && entry.Client.Enabled && entry.Client.Type != "qbittorrent":
		return BlockedClientType
	}
	return ""
}

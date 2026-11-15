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
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/abs"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/fault"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/inventory"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/monitor"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/qbit"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/wfstore"
)

const (
	exitOK           = 0
	exitRecoverable  = 1
	exitUsage        = 2
	exitAlreadyOwned = 3
	exitFenced       = 4
	exitRefused      = 5
	exitPrepare      = 6

	usage = `usage:
  shelfarr-workflows prepare --bundle DIR --workdir NEW_DIR
  shelfarr-workflows run --workdir DIR [--workflows inventory,downloads] [--once] [options]
  shelfarr-workflows trigger|cancel|resume --workdir DIR --workflow inventory|downloads
  shelfarr-workflows status --workdir DIR
Experimental. Works only on a directory created by 'prepare' from a fixture bundle.`
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

type reporter struct {
	mutex   sync.Mutex
	encoder *json.Encoder
	errors  int
}

func (r *reporter) emit(name string, fields map[string]any) {
	r.mutex.Lock()
	defer r.mutex.Unlock()
	line := map[string]any{"event": name}
	for key, value := range fields {
		line[key] = value
	}
	r.encoder.Encode(line)
}

func (r *reporter) fail(workflow, code string) {
	r.mutex.Lock()
	r.errors++
	r.mutex.Unlock()
	r.emit("error", map[string]any{"workflow": workflow, "code": code})
}

func (r *reporter) observe(name string, fields map[string]any) {
	r.emit(name, fields)
	if name != "inventory.library" {
		return
	}
	if code, _ := fields["code"].(string); code != "complete" && code != "empty" {
		r.fail("inventory", code)
	}
}

func (r *reporter) failures() int {
	r.mutex.Lock()
	defer r.mutex.Unlock()
	return r.errors
}

func run(arguments []string, stdout, stderr io.Writer) int {
	if len(arguments) == 0 {
		fmt.Fprintln(stderr, usage)
		return exitUsage
	}
	out := &reporter{encoder: json.NewEncoder(stdout)}
	flags := flag.NewFlagSet(arguments[0], flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	workdir := flags.String("workdir", "", "")
	switch arguments[0] {
	case "prepare":
		bundleDir := flags.String("bundle", "", "")
		if flags.Parse(arguments[1:]) != nil || *workdir == "" || *bundleDir == "" {
			fmt.Fprintln(stderr, usage)
			return exitUsage
		}
		return prepare(*bundleDir, *workdir, out)
	case "trigger", "cancel", "resume":
		workflow := flags.String("workflow", "", "")
		if flags.Parse(arguments[1:]) != nil || *workdir == "" || *workflow == "" {
			fmt.Fprintln(stderr, usage)
			return exitUsage
		}
		return control(arguments[0], *workdir, *workflow, out)
	case "status":
		if flags.Parse(arguments[1:]) != nil || *workdir == "" {
			fmt.Fprintln(stderr, usage)
			return exitUsage
		}
		return status(*workdir, out)
	case "run":
		return runService(arguments[1:], flags, workdir, out, stderr)
	}
	fmt.Fprintln(stderr, usage)
	return exitUsage
}

func prepare(bundleDir, workdir string, out *reporter) int {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	if err := wfstore.Prepare(ctx, bundleDir, workdir); err != nil {
		out.emit("refused", map[string]any{"code": wfstore.CodeOf(err)})
		return exitPrepare
	}
	out.emit("prepared", nil)
	return exitOK
}

func openStore(ctx context.Context, workdir string, busy time.Duration, out *reporter) (*wfstore.Store, int) {
	store, err := wfstore.Open(ctx, workdir, wfstore.Options{BusyTimeoutMillis: int(busy / time.Millisecond)})
	if err != nil {
		out.emit("refused", map[string]any{"code": wfstore.CodeOf(err)})
		return nil, exitRefused
	}
	return store, exitOK
}

func control(action, workdir, workflow string, out *reporter) int {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	store, code := openStore(ctx, workdir, 0, out)
	if store == nil {
		return code
	}
	defer store.Close()
	var err error
	switch action {
	case "trigger":
		err = store.Trigger(ctx, workflow, time.Now())
	case "cancel":
		err = store.Cancel(ctx, workflow)
	case "resume":
		err = store.Resume(ctx, workflow, time.Now())
	}
	if err != nil {
		out.emit("error", map[string]any{"workflow": workflow, "code": wfstore.CodeOf(err)})
		return exitRecoverable
	}
	out.emit(action, map[string]any{"workflow": workflow})
	return exitOK
}

func status(workdir string, out *reporter) int {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	store, code := openStore(ctx, workdir, 0, out)
	if store == nil {
		return code
	}
	defer store.Close()
	report := map[string]any{}
	for _, domain := range wfstore.Domains {
		schedule, err := store.Schedule(ctx, domain)
		if err != nil {
			out.emit("error", map[string]any{"code": wfstore.CodeOf(err)})
			return exitRecoverable
		}
		report[domain] = map[string]any{"state": schedule.State, "next_due_at": schedule.NextDueAt, "last_outcome": schedule.LastOutcome}
	}
	counts := func(name, query string) {
		rows, err := store.DB().QueryContext(ctx, query)
		if err != nil {
			return
		}
		defer rows.Close()
		found := map[string]int{}
		for rows.Next() {
			var key string
			var count int
			if rows.Scan(&key, &count) == nil {
				found[key] = count
			}
		}
		report[name] = found
	}
	counts("inventory_runs", `SELECT state, COUNT(*) FROM wf_inventory_runs GROUP BY state`)
	counts("handoffs", `SELECT state, COUNT(*) FROM wf_postprocess_handoffs GROUP BY state`)
	counts("blocked_downloads", `SELECT blocked_code, COUNT(*) FROM wf_download_state WHERE blocked_code IS NOT NULL GROUP BY blocked_code`)
	out.emit("status", report)
	return exitOK
}

type serviceOptions struct {
	workflows    string
	once         bool
	tick         time.Duration
	concurrency  int
	handoffURL   string
	backoff      time.Duration
	requestLimit time.Duration
	busy         time.Duration
	passDeadline time.Duration
	grace        time.Duration
	pageSize     int
}

func runService(arguments []string, flags *flag.FlagSet, workdir *string, out *reporter, stderr io.Writer) int {
	var options serviceOptions
	flags.StringVar(&options.workflows, "workflows", "inventory,downloads", "")
	flags.BoolVar(&options.once, "once", false, "")
	flags.DurationVar(&options.tick, "tick", time.Second, "")
	flags.IntVar(&options.concurrency, "concurrency", 4, "")
	flags.StringVar(&options.handoffURL, "handoff-url", "", "")
	flags.DurationVar(&options.backoff, "handoff-backoff", 30*time.Second, "")
	flags.DurationVar(&options.requestLimit, "request-timeout", 15*time.Second, "")
	flags.DurationVar(&options.busy, "busy-timeout", 5*time.Second, "")
	flags.DurationVar(&options.passDeadline, "pass-deadline", 2*time.Minute, "")
	flags.DurationVar(&options.grace, "shutdown-grace", 20*time.Second, "")
	flags.IntVar(&options.pageSize, "page-size", 500, "")
	selected := map[string]bool{}
	if flags.Parse(arguments) != nil || *workdir == "" || options.tick <= 0 || options.concurrency < 1 || options.concurrency > 32 || options.busy <= 0 {
		fmt.Fprintln(stderr, usage)
		return exitUsage
	}
	for _, name := range strings.Split(options.workflows, ",") {
		if name = strings.TrimSpace(name); name != "inventory" && name != "downloads" || selected[name] {
			fmt.Fprintln(stderr, usage)
			return exitUsage
		}
		selected[name] = true
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	store, code := openStore(ctx, *workdir, options.busy, out)
	if store == nil {
		return code
	}
	defer store.Close()

	var owners []*wfstore.Owner
	defer func() {
		for _, owner := range owners {
			owner.Release()
		}
	}()
	names := make([]string, 0, len(selected))
	for name := range selected {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		owner, err := store.Acquire(ctx, name)
		if err != nil {
			out.emit("refused", map[string]any{"domain": name, "code": wfstore.CodeOf(err)})
			if errors.Is(err, wfstore.ErrAlreadyOwned) {
				return exitAlreadyOwned
			}
			return exitRecoverable
		}
		owners = append(owners, owner)
		out.emit("owner", map[string]any{"domain": name, "generation": owner.Generation})
	}

	service := &service{options: options, out: out, owners: map[string]*wfstore.Owner{}}
	for _, owner := range owners {
		service.owners[owner.Domain] = owner
	}
	return service.run(ctx)
}

type service struct {
	options serviceOptions
	out     *reporter
	owners  map[string]*wfstore.Owner
	fenced  chan struct{}
	once    sync.Once
}

func (s *service) run(ctx context.Context) int {
	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	s.fenced = make(chan struct{})
	var group sync.WaitGroup
	start := func(name string, loop func(ctx context.Context) bool) {
		group.Add(1)
		go func() {
			defer group.Done()
			s.supervise(runCtx, name, loop)
		}()
	}
	if owner := s.owners["inventory"]; owner != nil {
		workflow := &inventory.Workflow{Owner: owner, ABS: abs.Config{PageSize: s.options.pageSize, RequestTimeout: s.options.requestLimit}, Report: s.out.observe}
		start("inventory", func(ctx context.Context) bool {
			result, err := workflow.Pass(ctx)
			s.after("inventory", err)
			if err == nil {
				s.out.emit("inventory.pass", map[string]any{"outcome": result.Outcome})
				if result.Outcome == inventory.OutcomeAllFailed || result.Outcome == inventory.OutcomeDiscoveryFailed {
					s.out.fail("inventory", result.Outcome)
				}
			}
			return err == nil
		})
	}
	if owner := s.owners["downloads"]; owner != nil {
		workflow := &monitor.Workflow{
			Owner: owner, QBit: qbit.Config{RequestTimeout: s.options.requestLimit}, Concurrency: s.options.concurrency,
			PassDeadline: s.options.passDeadline, HandoffURL: s.options.handoffURL, HandoffBackoff: s.options.backoff,
			HandoffTimeout: s.options.requestLimit, Report: s.out.emit,
		}
		start("downloads", func(ctx context.Context) bool {
			result, err := workflow.Cycle(ctx)
			s.after("downloads", err)
			if err == nil {
				s.out.emit("downloads.pass", map[string]any{"outcome": result.Outcome})
			}
			return err == nil
		})
		start("handoffs", func(ctx context.Context) bool {
			result, err := workflow.Deliver(ctx)
			s.after("handoffs", err)
			if err == nil {
				s.out.emit("handoffs.pass", map[string]any{"pending": result.Pending, "delivered": result.Delivered, "failed": result.Failed})
			}
			return err == nil
		})
	}

	finished := make(chan struct{})
	go func() {
		group.Wait()
		close(finished)
	}()
	select {
	case <-s.fenced:
		cancel()
	case <-finished:
	case <-ctx.Done():
	}
	cancel()
	select {
	case <-finished:
	case <-time.After(s.options.grace):
		s.out.emit("shutdown", map[string]any{"outcome": "grace-exceeded"})
		return exitRecoverable
	}
	switch {
	case isClosed(s.fenced):
		return exitFenced
	case s.out.failures() > 0 && s.options.once:
		return exitRecoverable
	}
	s.out.emit("shutdown", map[string]any{"outcome": "clean"})
	return exitOK
}

func isClosed(channel chan struct{}) bool {
	select {
	case <-channel:
		return true
	default:
		return false
	}
}

func (s *service) after(workflow string, err error) {
	if err == nil {
		return
	}
	fault.Observe(err)
	code := wfstore.CodeOf(err)
	if code == wfstore.CodeCancelled {
		return
	}
	if code == wfstore.CodeFenced {
		s.once.Do(func() { close(s.fenced) })
	}
	s.out.fail(workflow, code)
}

func (s *service) supervise(ctx context.Context, name string, pass func(ctx context.Context) bool) {
	for {
		func() {
			defer func() {
				if recovered := recover(); recovered != nil {
					s.out.fail(name, "panic")
				}
			}()
			pass(ctx)
		}()
		if s.options.once || ctx.Err() != nil {
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(s.options.tick):
		}
	}
}

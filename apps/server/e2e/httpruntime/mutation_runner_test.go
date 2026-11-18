//go:build e2e

package httpruntime

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"flag"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

type verdict int

const (
	survived verdict = iota
	detected
	unproven
)

type mutantRunner struct {
	timeout  time.Duration
	budget   time.Duration
	shortest time.Duration
	sweep    func(marker string) bool
}

const (
	mutantRunTimeout = 10 * time.Minute
	cleanupMargin    = 30 * time.Second
	alarmMargin      = 20 * time.Second
	frame            = "\x16"
	runMarkerName    = "SHELFARR_MUTANT_RUN"
)

var errLeftovers = errors.New("processes were left running")

var (
	runCounter     atomic.Int64
	childRunner    = mutantRunner{timeout: mutantRunTimeout, budget: mutantRunTimeout + alarmMargin, shortest: 30 * time.Second}
	processStarted = time.Now()
)

func stageDeadline(t *testing.T) time.Time {
	deadline, _ := t.Deadline()
	if timeout, ok := flag.Lookup("test.timeout").Value.(flag.Getter).Get().(time.Duration); ok && timeout > 0 {
		if started := processStarted.Add(timeout); deadline.IsZero() || started.Before(deadline) {
			deadline = started
		}
	}
	return deadline
}

type processState struct {
	parent  int
	session int
}

func stateOf(pid int) (processState, bool) {
	stat, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
	if err != nil {
		return processState{}, false
	}
	end := bytes.LastIndexByte(stat, ')')
	if end < 0 {
		return processState{}, false
	}
	fields := strings.Fields(string(stat[end+1:]))
	if len(fields) < 4 || fields[0] == "Z" {
		return processState{}, false
	}
	parent, parentErr := strconv.Atoi(fields[1])
	session, sessionErr := strconv.Atoi(fields[3])
	return processState{parent: parent, session: session}, parentErr == nil && sessionErr == nil
}

func descendsFromThisProcess(pid int) bool {
	for hops := 0; hops < 64 && pid > 1; hops++ {
		state, ok := stateOf(pid)
		if !ok {
			return false
		}
		if state.parent == os.Getpid() {
			return true
		}
		pid = state.parent
	}
	return false
}

func carriesMarker(pid int, marker string) bool {
	environment, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/environ")
	if err != nil {
		return false
	}
	for _, variable := range bytes.Split(environment, []byte{0}) {
		if string(variable) == marker {
			return true
		}
	}
	return false
}

func ownedByRun(pid int, marker string) bool {
	return carriesMarker(pid, marker) && descendsFromThisProcess(pid)
}

var adoptOrphans sync.Once

func becomeSubreaper() {
	adoptOrphans.Do(func() { unix.Prctl(unix.PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) })
}

func newRunMarker() string {
	random := make([]byte, 8)
	rand.Read(random)
	return runMarkerName + "=" + strconv.Itoa(os.Getpid()) + "-" + strconv.FormatInt(runCounter.Add(1), 10) + "-" + hex.EncodeToString(random)
}

var processTable = "/proc"

func stopRun(marker string) bool {
	emptyScans := 0
	for round := 0; round < 40; round++ {
		entries, err := os.ReadDir(processTable)
		if err != nil {
			emptyScans = 0
			time.Sleep(25 * time.Millisecond)
			continue
		}
		members := 0
		for _, entry := range entries {
			pid, err := strconv.Atoi(entry.Name())
			if err != nil || pid == os.Getpid() || !ownedByRun(pid, marker) {
				continue
			}
			members++
			descriptor, err := unix.PidfdOpen(pid, 0)
			if err != nil {
				continue
			}
			if ownedByRun(pid, marker) {
				unix.PidfdSendSignal(descriptor, unix.SIGKILL, nil, 0)
				var info unix.Siginfo
				unix.Waitid(unix.P_PIDFD, descriptor, &info, unix.WEXITED|unix.WNOHANG, nil)
			}
			unix.Close(descriptor)
		}
		if members > 0 {
			emptyScans = 0
		} else if emptyScans++; emptyScans == 2 {
			return true
		}
		time.Sleep(25 * time.Millisecond)
	}
	return false
}

func (r mutantRunner) limits(deadline time.Time) (time.Duration, time.Duration, bool) {
	budget := r.budget
	if !deadline.IsZero() {
		budget = min(budget, time.Until(deadline)-cleanupMargin)
	}
	timeout := min(r.timeout, budget-alarmMargin)
	return timeout, budget, timeout >= r.shortest
}

type runResult struct {
	output    string
	exitCode  int
	err       error
	exhausted bool
	leftovers bool
}

func (r mutantRunner) runInSession(ctx context.Context, directory, program string, arguments ...string) runResult {
	becomeSubreaper()
	command := exec.CommandContext(ctx, program, arguments...)
	command.Dir = directory
	marker := newRunMarker()
	command.Env = append(os.Environ(), "GOMAXPROCS=4", marker)
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	command.WaitDelay = 10 * time.Second
	var output bytes.Buffer
	command.Stdout, command.Stderr = &output, &output
	err := command.Run()
	exhausted := ctx.Err() != nil
	sweep := r.sweep
	if sweep == nil {
		sweep = stopRun
	}
	result := runResult{output: output.String(), exitCode: -1, err: err, exhausted: exhausted, leftovers: !sweep(marker)}
	var exit *exec.ExitError
	if command.ProcessState != nil && (err == nil || errors.As(err, &exit)) {
		result.exitCode = command.ProcessState.ExitCode()
	}
	return result
}

func (r mutantRunner) build(directory string, deadline time.Time) (string, error) {
	_, budget, enough := r.limits(deadline)
	if !enough {
		return "no time is left in the stage for the build", context.DeadlineExceeded
	}
	ctx, cancel := context.WithTimeout(context.Background(), budget)
	defer cancel()
	result := r.runInSession(ctx, directory, "go", "build", "-p", "2", "./...")
	if result.exhausted {
		return "the build exhausted its budget", context.DeadlineExceeded
	}
	if result.leftovers {
		return "the build left processes running", errLeftovers
	}
	return result.output, result.err
}

func (r mutantRunner) test(directory, packagePath, pattern string, tagged bool, deadline time.Time) (verdict, string) {
	timeout, budget, enough := r.limits(deadline)
	if !enough {
		return unproven, "no time is left in the stage for this run"
	}
	ctx, cancel := context.WithTimeout(context.Background(), budget)
	defer cancel()
	binary := filepath.Join(directory, ".mutant-tests", strconv.FormatInt(time.Now().UnixNano(), 36)+".test")
	compile := []string{"test", "-c", "-p", "2", "-o", binary}
	if tagged {
		compile = append(compile, "-tags", "e2e")
	}
	built := r.runInSession(ctx, directory, "go", append(compile, packagePath)...)
	switch {
	case built.exhausted:
		return unproven, "the test build exhausted its budget:\n" + tail(built.output)
	case built.leftovers:
		return unproven, "the test build left processes running"
	case built.err != nil:
		return unproven, "the tests do not build:\n" + tail(built.output)
	}
	if _, err := os.Stat(binary); err != nil {
		return unproven, "the package has no tests to run"
	}
	arguments := []string{"-test.v=test2json", "-test.count=1", "-test.timeout=" + timeout.String()}
	if pattern != "" {
		arguments = append(arguments, "-test.run="+pattern)
	}
	ran := r.runInSession(ctx, filepath.Join(directory, packagePath), binary, arguments...)
	return classifyMutantRun(ran)
}

func classifyMutantRun(ran runResult) (verdict, string) {
	failures, skips, finishedFailing, finishedPassing, crashedTest := 0, 0, false, false, false
	lastFrame := ""
	for _, line := range strings.Split(ran.output, "\n") {
		marker := strings.LastIndex(line, frame)
		if marker < 0 {
			if strings.TrimSpace(line) != "" && strings.HasPrefix(lastFrame, "--- FAIL: ") && strings.HasPrefix(line, "panic: ") && !strings.HasPrefix(line, "panic: test timed out") {
				crashedTest = true
			}
			if strings.TrimSpace(line) != "" {
				lastFrame = ""
			}
			continue
		}
		finishedFailing, finishedPassing, crashedTest = false, false, false
		lastFrame = line[marker+len(frame):]
		switch {
		case strings.HasPrefix(lastFrame, "--- FAIL: "):
			failures++
		case strings.HasPrefix(lastFrame, "--- SKIP: "):
			skips++
		case lastFrame == "FAIL":
			finishedFailing = true
		case lastFrame == "PASS":
			finishedPassing = true
		}
	}
	evidence := tail(ran.output)
	switch {
	case ran.exhausted:
		return unproven, "the run exhausted its budget and was cancelled:\n" + evidence
	case ran.leftovers:
		return unproven, "the run left processes running after its clean-up, so it proves nothing:\n" + evidence
	case skips > 0:
		return unproven, "a test was skipped, so the run proves nothing:\n" + evidence
	case ran.exitCode == 0 && finishedPassing && failures == 0:
		return survived, ""
	case ran.exitCode == 1 && finishedFailing && failures > 0, ran.exitCode == 2 && crashedTest:
		return detected, ""
	}
	return unproven, "the run did not finish with a failed assertion or a crash inside a started test (exit " + strconv.Itoa(ran.exitCode) + "):\n" + evidence
}

type mutantStep func() (verdict, string)

func firstDetection(steps []mutantStep) (bool, string) {
	for _, step := range steps {
		switch outcome, evidence := step(); outcome {
		case detected:
			return true, ""
		case unproven:
			return false, evidence
		}
	}
	return false, "no assertion failed for this mutant"
}

func TestAMutantIsKilledByItsFirstAssertionAndNeverByARunThatProvesNothing(t *testing.T) {
	var ran []string
	step := func(name string, outcome verdict) mutantStep {
		return func() (verdict, string) {
			ran = append(ran, name)
			return outcome, name
		}
	}
	for name, test := range map[string]struct {
		steps  []mutantStep
		killed bool
		ran    string
	}{
		"a unit assertion skips the scenario":       {[]mutantStep{step("unit", detected), step("scenario", detected)}, true, "unit"},
		"a surviving unit run reaches the scenario": {[]mutantStep{step("unit", survived), step("scenario", detected)}, true, "unit scenario"},
		"an unproven unit run fails at once":        {[]mutantStep{step("unit", unproven), step("scenario", detected)}, false, "unit"},
		"an unproven scenario fails":                {[]mutantStep{step("unit", survived), step("scenario", unproven)}, false, "unit scenario"},
		"every run survives":                        {[]mutantStep{step("unit", survived), step("scenario", survived)}, false, "unit scenario"},
		"no runs":                                   {nil, false, ""},
	} {
		ran = nil
		killed, _ := firstDetection(test.steps)
		if killed != test.killed || strings.Join(ran, " ") != test.ran {
			t.Errorf("%s: killed=%v after %v", name, killed, ran)
		}
	}
}

func writeProbeModule(t *testing.T, test string) string {
	t.Helper()
	directory := t.TempDir()
	for name, content := range map[string]string{"go.mod": "module probe\n\ngo 1.21\n", "probe_test.go": test} {
		if err := os.WriteFile(filepath.Join(directory, name), []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return directory
}

func alive(pid int) bool {
	_, ok := stateOf(pid)
	return ok
}

func childPid(t *testing.T, pidFile string) int {
	t.Helper()
	data, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatal("the child of the probe was never started")
	}
	pid, _ := strconv.Atoi(string(data))
	return pid
}

const startChild = `
	child := exec.Command("sleep", "300")
	child.Start()
	os.WriteFile(PIDFILE, []byte(strconv.Itoa(child.Process.Pid)), 0o600)
`

func TestAMutantIsKilledOnlyByAnAssertionInARunThatFinishedNormally(t *testing.T) {
	runner := mutantRunner{timeout: 3 * time.Second, budget: 60 * time.Second}
	pidFile := filepath.Join(t.TempDir(), "child.pid")
	child := strings.ReplaceAll(startChild, "PIDFILE", strconv.Quote(pidFile))
	cases := map[string]struct {
		source string
		want   verdict
	}{
		"an assertion failure": {`package probe
import "testing"
func TestA(t *testing.T) { t.Fatal("wrong") }`, detected},
		"a failing parallel subtest beside passing tests": {`package probe
import "testing"
func TestA(t *testing.T) { t.Run("sub", func(t *testing.T) { t.Parallel(); t.Error("wrong") }) }
func TestB(t *testing.T) {}`, detected},
		"an assertion that mentions every alarm": {`package probe
import ("fmt"; "testing")
func TestA(t *testing.T) { fmt.Println("panic: test timed out after 1s\n[setup failed]\nsignal: killed"); t.Fatal("build failed") }`, detected},
		"an assertion after output without a newline": {`package probe
import ("fmt"; "testing")
func TestA(t *testing.T) { fmt.Print("no newline"); t.Fatal("wrong") }`, detected},
		"a pass after output without a newline": {`package probe
import ("fmt"; "testing")
func TestA(t *testing.T) { fmt.Print("no newline") }`, survived},
		"a skipped test beside a failure": {`package probe
import "testing"
func TestA(t *testing.T) { t.Skip("setup") }
func TestB(t *testing.T) { t.Error("wrong") }`, unproven},
		"a skipped test": {`package probe
import "testing"
func TestA(t *testing.T) { t.Skip("setup") }`, unproven},
		"a test that prints a framed pass after failing": {`package probe
import ("fmt"; "os"; "testing")
func TestMain(m *testing.M) { code := m.Run(); fmt.Println("\x16PASS"); os.Exit(code) }
func TestA(t *testing.T) { t.Error("wrong") }`, unproven},
		"a pass": {`package probe
import "testing"
func TestA(t *testing.T) {}`, survived},
		"a crash inside a started test": {`package probe
import "testing"
func TestA(t *testing.T) { var rows []int; _ = rows[0] }`, detected},
		"a crash inside a started subtest": {`package probe
import "testing"
func TestA(t *testing.T) { t.Run("sub", func(t *testing.T) { var row map[string]any; _ = row["x"].(string) }) }`, detected},
		"a panic after the tests finished": {`package probe
import "testing"
func TestMain(m *testing.M) { m.Run(); panic("after") }
func TestA(t *testing.T) { t.Error("wrong") }`, unproven},
		"a hang that meets the Go alarm": {`package probe
import "testing"
func TestA(t *testing.T) { select {} }`, unproven},
		"an assertion failure beside a hang": {`package probe
import "testing"
func TestA(t *testing.T) { t.Error("wrong") }
func TestB(t *testing.T) { select {} }`, unproven},
		"a compile error": {`package probe
import "testing"
func TestA(t *testing.T) { undefined() }`, unproven},
		"a TestMain that fakes a failure and exits": {`package probe
import ("fmt"; "os"; "testing")
func TestMain(m *testing.M) { fmt.Println("=== RUN   TestA\n--- FAIL: TestA (0.00s)\nFAIL"); os.Exit(1) }
func TestA(t *testing.T) {}`, unproven},
		"a TestMain that exits with another status after the tests": {`package probe
import ("os"; "testing")
func TestMain(m *testing.M) { m.Run(); os.Exit(3) }
func TestA(t *testing.T) { t.Error("wrong") }`, unproven},
		"a panic before any test runs": {`package probe
import "testing"
var _ = func() int { panic("init") }()
func TestA(t *testing.T) {}`, unproven},
		"an assertion before the test process is killed": {`package probe
import ("os"; "syscall"; "testing")
func TestA(t *testing.T) { t.Error("wrong") }
func TestB(t *testing.T) { syscall.Kill(os.Getpid(), syscall.SIGKILL) }`, unproven},
		"a process killed after its last test": {`package probe
import ("os"; "syscall"; "testing")
func TestMain(m *testing.M) { m.Run(); syscall.Kill(os.Getpid(), syscall.SIGKILL) }
func TestA(t *testing.T) { t.Error("wrong") }`, unproven},
		"a hang with a surviving child": {`package probe
import ("os"; "os/exec"; "strconv"; "testing")
func TestA(t *testing.T) {` + child + `	select {}
}`, unproven},
	}
	for name, test := range cases {
		got, evidence := runner.test(writeProbeModule(t, test.source), ".", "", false, time.Time{})
		if got != test.want {
			t.Errorf("%s: verdict %d, want %d\n%s", name, got, test.want, evidence)
		}
	}
	if pid := childPid(t, pidFile); alive(pid) {
		syscall.Kill(pid, syscall.SIGKILL)
		t.Fatal("a process started by a timed-out mutant run survived it")
	}
}

func TestAMutantRunThatExhaustsItsBudgetIsCancelledWithItsWholeSession(t *testing.T) {
	runner := mutantRunner{timeout: time.Hour, budget: alarmMargin + 5*time.Second}
	pidFile := filepath.Join(t.TempDir(), "child.pid")
	directory := writeProbeModule(t, `package probe
import ("os"; "os/exec"; "strconv"; "testing"; "time")
func TestMain(m *testing.M) {
	_ = m`+strings.ReplaceAll(startChild, "PIDFILE", strconv.Quote(pidFile))+`	time.Sleep(time.Hour)
}
func TestA(t *testing.T) {}`)
	started := time.Now()
	got, evidence := runner.test(directory, ".", "", false, time.Time{})
	if got != unproven || !strings.Contains(evidence, "exhausted its budget") || time.Since(started) > alarmMargin+40*time.Second {
		t.Fatalf("verdict %d after %s: %s", got, time.Since(started), evidence)
	}
	if pid := childPid(t, pidFile); alive(pid) {
		syscall.Kill(pid, syscall.SIGKILL)
		t.Fatal("cancelling a mutant run left a process of its session running")
	}
}

func TestAMutantRunIsBoundedByWhatIsLeftOfTheStage(t *testing.T) {
	runner := childRunner
	for name, test := range map[string]struct {
		left            time.Duration
		timeout, budget time.Duration
		enough          bool
	}{
		"no stage deadline":  {0, 10 * time.Minute, 10*time.Minute + alarmMargin, true},
		"a distant deadline": {time.Hour, 10 * time.Minute, 10*time.Minute + alarmMargin, true},
		"a near deadline":    {5 * time.Minute, 5*time.Minute - cleanupMargin - alarmMargin, 5*time.Minute - cleanupMargin, true},
		"too little left":    {cleanupMargin + alarmMargin + childRunner.shortest - time.Second, 0, 0, false},
	} {
		deadline := time.Time{}
		if test.left > 0 {
			deadline = time.Now().Add(test.left)
		}
		timeout, budget, enough := runner.limits(deadline)
		if enough != test.enough || enough && (timeout-test.timeout).Abs() > time.Second || enough && (budget-test.budget).Abs() > time.Second {
			t.Errorf("%s: timeout %s budget %s enough %v", name, timeout, budget, enough)
		}
	}
	if verdict, evidence := runner.test(t.TempDir(), ".", "", false, time.Now().Add(time.Minute)); verdict != unproven || !strings.Contains(evidence, "no time is left") {
		t.Fatalf("a run was started without the time to finish it: %d %s", verdict, evidence)
	}
	if test, _ := t.Deadline(); !test.IsZero() && stageDeadline(t).After(test) {
		t.Fatalf("the stage deadline %v is later than the test deadline %v", stageDeadline(t), test)
	}
}

func TestTheSweepStopsEveryProcessOfTheRunAndNothingElse(t *testing.T) {
	becomeSubreaper()
	marker, other := newRunMarker(), newRunMarker()
	start := func(environment ...string) int {
		command := exec.Command("sh", "-c", "sleep 60 & echo $!; wait")
		command.Env = append([]string{"PATH=" + os.Getenv("PATH")}, environment...)
		reader, writer, err := os.Pipe()
		if err != nil {
			t.Fatal(err)
		}
		command.Stdout = writer
		if err := command.Start(); err != nil {
			t.Fatal(err)
		}
		writer.Close()
		line := make([]byte, 32)
		count, _ := reader.Read(line)
		child, _ := strconv.Atoi(strings.TrimSpace(string(line[:count])))
		if child == 0 {
			t.Fatal("the probe child was never started")
		}
		t.Cleanup(func() {
			syscall.Kill(child, syscall.SIGKILL)
			command.Process.Kill()
			command.Wait()
		})
		return child
	}
	owned := start(marker)
	parallel := start(other)
	suffixed := start("UNRELATED=" + marker)
	unmarked := start()
	stopRun(marker)
	if alive(owned) {
		t.Fatal("a process of the run survived the sweep")
	}
	for name, pid := range map[string]int{"a parallel run": parallel, "a variable ending in the marker": suffixed, "an unmarked process": unmarked} {
		if !alive(pid) {
			t.Errorf("the sweep stopped %s", name)
		}
	}
}

func TestAVerdictIsTakenWhenTheRunEndsNotAfterItsCleanUp(t *testing.T) {
	directory := writeProbeModule(t, `package probe
import "testing"
func TestA(t *testing.T) { t.Fatal("wrong") }`)
	budget := alarmMargin + 5*time.Second
	begin, sweeps := time.Now(), 0
	slow := mutantRunner{timeout: time.Hour, budget: budget, sweep: func(marker string) bool {
		cleaned := stopRun(marker)
		if sweeps++; sweeps == 2 {
			time.Sleep(time.Until(begin.Add(budget + time.Second)))
		}
		return cleaned
	}}
	if got, evidence := slow.test(directory, ".", "", false, time.Time{}); got != detected || sweeps != 2 || time.Since(begin) < budget {
		t.Fatalf("a failed assertion was lost to a clean-up that outlasted the budget: %d after %d clean-ups %s", got, sweeps, evidence)
	}
	stuck := mutantRunner{timeout: 20 * time.Second, budget: 40 * time.Second, sweep: func(string) bool { return false }}
	if got, evidence := stuck.test(directory, ".", "", false, time.Time{}); got != unproven || !strings.Contains(evidence, "processes running") {
		t.Fatalf("a run that left processes running was credited: %d %s", got, evidence)
	}
}

func TestASetupFailureUnderAMutantRunIsASkipThatProvesNothing(t *testing.T) {
	t.Setenv(runMarkerName, "probe")
	missing := fixture{name: "probe", dir: t.TempDir(), doc: casesDocument{Database: "missing.sqlite3"}}
	unwritable := filepath.Join(t.TempDir(), "absent")
	for name, prepare := range map[string]func(t *testing.T){
		"a missing database":                    func(t *testing.T) {},
		"a private directory that cannot exist": func(t *testing.T) { t.Setenv("TMPDIR", unwritable) },
	} {
		skipped := false
		t.Run(name, func(t *testing.T) {
			defer func() { skipped = t.Skipped() }()
			prepare(t)
			newRuntimeCopy(t, missing)
		})
		if !skipped {
			t.Errorf("%s was not skipped under a mutant run", name)
		}
	}
}

func TestACleanUpThatCannotReadTheProcessTableIsNeverClean(t *testing.T) {
	processTable = filepath.Join(t.TempDir(), "absent")
	t.Cleanup(func() { processTable = "/proc" })
	if stopRun(newRunMarker()) {
		t.Fatal("a clean-up that could not list processes reported that none were left")
	}
}

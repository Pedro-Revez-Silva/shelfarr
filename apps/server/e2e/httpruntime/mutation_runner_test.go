//go:build e2e

package httpruntime

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
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
}

const (
	mutantRunTimeout = 10 * time.Minute
	cleanupMargin    = 30 * time.Second
	alarmMargin      = 20 * time.Second
	runMarkerName    = "SHELFARR_MUTANT_RUN"
)

var (
	childRunner = mutantRunner{timeout: mutantRunTimeout, budget: mutantRunTimeout + alarmMargin, shortest: 30 * time.Second}
	runCounter  atomic.Int64
)

func sweepRun(marker string) {
	entries, _ := os.ReadDir("/proc")
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil || pid == os.Getpid() {
			continue
		}
		environment, err := os.ReadFile("/proc/" + entry.Name() + "/environ")
		if err != nil {
			continue
		}
		for _, variable := range bytes.Split(environment, []byte{0}) {
			if string(variable) == marker {
				syscall.Kill(pid, syscall.SIGKILL)
				break
			}
		}
	}
}

func (r mutantRunner) limits(deadline time.Time) (time.Duration, time.Duration, bool) {
	budget := r.budget
	if !deadline.IsZero() {
		budget = min(budget, time.Until(deadline)-cleanupMargin)
	}
	timeout := min(r.timeout, budget-alarmMargin)
	return timeout, budget, timeout >= r.shortest
}

func (r mutantRunner) run(directory string, budget time.Duration, arguments ...string) (string, error, error) {
	ctx, cancel := context.WithTimeout(context.Background(), budget)
	defer cancel()
	marker := runMarkerName + "=" + strconv.Itoa(os.Getpid()) + "-" + strconv.FormatInt(runCounter.Add(1), 10)
	command := exec.CommandContext(ctx, "go", arguments...)
	command.Dir = directory
	command.Env = append(os.Environ(), "GOMAXPROCS=4", marker)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error { return syscall.Kill(-command.Process.Pid, syscall.SIGKILL) }
	command.WaitDelay = 10 * time.Second
	var output bytes.Buffer
	command.Stdout, command.Stderr = &output, &output
	err := command.Run()
	if command.Process != nil {
		syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
	}
	sweepRun(marker)
	return output.String(), err, ctx.Err()
}

func (r mutantRunner) build(directory string, deadline time.Time) (string, error) {
	_, budget, enough := r.limits(deadline)
	if !enough {
		return "no time is left in the stage for the build", context.DeadlineExceeded
	}
	text, err, exhausted := r.run(directory, budget, "build", "-p", "2", "./...")
	if exhausted != nil {
		return "the build exhausted its budget", exhausted
	}
	return text, err
}

func (r mutantRunner) test(directory, packagePath, pattern string, tagged bool, deadline time.Time) (verdict, string) {
	timeout, budget, enough := r.limits(deadline)
	if !enough {
		return unproven, "no time is left in the stage for this run"
	}
	arguments := []string{"test", "-json", "-count=1", "-p", "2", "-timeout", timeout.String()}
	if tagged {
		arguments = append(arguments, "-tags", "e2e")
	}
	if pattern != "" {
		arguments = append(arguments, "-run", pattern)
	}
	arguments = append(arguments, packagePath)
	text, err, exhausted := r.run(directory, budget, arguments...)
	return classifyMutantRun(text, err, exhausted)
}

type testEvent struct {
	Action string
	Test   string
	Output string
}

type runSummary struct {
	failedTests int
	alarm       bool
	abnormal    bool
	output      strings.Builder
}

func summarise(text string) *runSummary {
	summary := &runSummary{}
	started, finished := map[string]bool{}, map[string]bool{}
	for _, line := range strings.Split(text, "\n") {
		var event testEvent
		if json.Unmarshal([]byte(line), &event) != nil || event.Action == "" {
			if strings.TrimSpace(line) != "" {
				summary.output.WriteString(line + "\n")
			}
			continue
		}
		switch event.Action {
		case "build-fail":
			summary.abnormal = true
		case "run":
			started[event.Test] = true
		case "pass", "skip":
			finished[event.Test] = true
		case "fail":
			finished[event.Test] = true
			if event.Test != "" && started[event.Test] {
				summary.failedTests++
			}
		case "output", "build-output":
			summary.output.WriteString(event.Output)
			if strings.HasPrefix(event.Output, "panic: test timed out after") {
				summary.alarm = true
			}
			if event.Test == "" && (strings.Contains(event.Output, "[setup failed]") || strings.Contains(event.Output, "[build failed]")) {
				summary.abnormal = true
			}
		}
	}
	for test := range started {
		if !finished[test] {
			summary.abnormal = true
		}
	}
	return summary
}

func classifyMutantRun(text string, err, exhausted error) (verdict, string) {
	summary := summarise(text)
	evidence := tail(summary.output.String())
	switch {
	case exhausted != nil:
		return unproven, "the run exhausted its budget and was cancelled:\n" + evidence
	case summary.alarm:
		return unproven, "a test hit the Go timeout, which proves nothing:\n" + evidence
	case summary.abnormal:
		return unproven, "the run did not build, set up or terminate normally:\n" + evidence
	case err == nil && summary.failedTests == 0:
		return survived, ""
	case err != nil && summary.failedTests > 0:
		return detected, ""
	}
	return unproven, "the run failed without an assertion failing:\n" + evidence
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

func TestAMutantRunNeverCountsATimeoutOrACancellationAsADetection(t *testing.T) {
	runner := mutantRunner{timeout: 2 * time.Second, budget: 60 * time.Second}
	pidFile := filepath.Join(t.TempDir(), "child.pid")
	cases := map[string]struct {
		source string
		want   verdict
	}{
		"an assertion failure": {`package probe
import "testing"
func TestA(t *testing.T) { t.Fatal("wrong") }`, detected},
		"a panic": {`package probe
import "testing"
func TestA(t *testing.T) { panic("boom") }`, detected},
		"a pass": {`package probe
import "testing"
func TestA(t *testing.T) {}`, survived},
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
		"an assertion that mentions a failed build": {`package probe
import "testing"
func TestA(t *testing.T) { t.Fatal("build failed [setup failed] panic: test timed out after") }`, detected},
		"a TestMain that exits after printing a panic": {`package probe
import ("fmt"; "os"; "testing")
func TestMain(m *testing.M) { fmt.Println("panic: nothing ran"); os.Exit(1) }
func TestA(t *testing.T) {}`, unproven},
		"a TestMain that prints a failure line and exits": {`package probe
import ("fmt"; "os"; "testing")
func TestMain(m *testing.M) { fmt.Println("--- FAIL: TestA (0.00s)"); os.Exit(1) }
func TestA(t *testing.T) {}`, unproven},
		"a panic before any test runs": {`package probe
import "testing"
var _ = func() int { panic("init") }()
func TestA(t *testing.T) {}`, unproven},
		"an assertion before the test process is killed": {`package probe
import ("os"; "syscall"; "testing")
func TestA(t *testing.T) { t.Error("wrong") }
func TestB(t *testing.T) { syscall.Kill(os.Getpid(), syscall.SIGKILL) }`, unproven},
		"a hang with a surviving child": {`package probe
import ("os"; "os/exec"; "strconv"; "testing")
func TestA(t *testing.T) {
	child := exec.Command("sleep", "300")
	child.Start()
	os.WriteFile("` + pidFile + `", []byte(strconv.Itoa(child.Process.Pid)), 0o600)
	select {}
}`, unproven},
	}
	for name, test := range cases {
		got, evidence := runner.test(writeProbeModule(t, test.source), ".", "", false, time.Time{})
		if got != test.want {
			t.Errorf("%s: verdict %d, want %d\n%s", name, got, test.want, evidence)
		}
	}
	data, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatal("the child of the hanging test was never started")
	}
	pid, _ := strconv.Atoi(string(data))
	if syscall.Kill(pid, 0) == nil {
		syscall.Kill(pid, syscall.SIGKILL)
		t.Fatal("a process started by a timed-out mutant run survived it")
	}
}

func TestAMutantRunThatExhaustsItsBudgetIsCancelledWithItsProcessGroup(t *testing.T) {
	runner := mutantRunner{timeout: time.Hour, budget: alarmMargin + 2*time.Second}
	pidFile := filepath.Join(t.TempDir(), "child.pid")
	directory := writeProbeModule(t, `package probe
import ("os"; "os/exec"; "strconv"; "testing"; "time")
func TestMain(m *testing.M) {
	_ = m
	child := exec.Command("sleep", "300")
	child.Start()
	os.WriteFile("`+pidFile+`", []byte(strconv.Itoa(child.Process.Pid)), 0o600)
	time.Sleep(time.Hour)
}
func TestA(t *testing.T) {}`)
	started := time.Now()
	got, evidence := runner.test(directory, ".", "", false, time.Time{})
	if got != unproven || !strings.Contains(evidence, "exhausted its budget") || time.Since(started) > alarmMargin+30*time.Second {
		t.Fatalf("verdict %d after %s: %s", got, time.Since(started), evidence)
	}
	data, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatal("the child of the hanging test was never started")
	}
	pid, _ := strconv.Atoi(string(data))
	if syscall.Kill(pid, 0) == nil {
		syscall.Kill(pid, syscall.SIGKILL)
		t.Fatal("cancelling a mutant run left its process group running")
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
}

func TestTheSweepKillsOnlyProcessesThatCarryTheExactRunMarker(t *testing.T) {
	marker := runMarkerName + "=" + strconv.Itoa(os.Getpid()) + "-sweep"
	start := func(variable string) *exec.Cmd {
		command := exec.Command("sleep", "60")
		command.Env = []string{"PATH=" + os.Getenv("PATH"), variable}
		if err := command.Start(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { command.Process.Kill(); command.Wait() })
		return command
	}
	owned := start(marker)
	unrelated := start("UNRELATED=" + marker)
	longer := start(marker + "0")
	sweepRun(marker)
	if state, _ := owned.Process.Wait(); state == nil || state.Sys().(syscall.WaitStatus).Signal() != syscall.SIGKILL {
		t.Fatal("the process that carries the marker survived the sweep")
	}
	for name, command := range map[string]*exec.Cmd{"a variable ending in the marker": unrelated, "a longer marker": longer} {
		if err := command.Process.Signal(syscall.Signal(0)); err != nil {
			t.Errorf("%s was killed: %v", name, err)
		}
	}
}

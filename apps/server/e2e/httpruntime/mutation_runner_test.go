//go:build e2e

package httpruntime

import (
	"bytes"
	"context"
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
	timeout time.Duration
	budget  time.Duration
}

var childRunner = mutantRunner{timeout: mutantRunTimeout, budget: mutantRunTimeout + 30*time.Second}

const mutantRunTimeout = 10 * time.Minute

var runCounter atomic.Int64

const runMarkerName = "SHELFARR_MUTANT_RUN"

func sweepRun(marker string) {
	entries, _ := os.ReadDir("/proc")
	needle := []byte(marker + "\x00")
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil || pid == os.Getpid() {
			continue
		}
		environment, err := os.ReadFile("/proc/" + entry.Name() + "/environ")
		if err == nil && bytes.Contains(environment, needle) {
			syscall.Kill(pid, syscall.SIGKILL)
		}
	}
}

func (r mutantRunner) command(ctx context.Context, directory string, marker string, arguments ...string) *exec.Cmd {
	command := exec.CommandContext(ctx, "go", arguments...)
	command.Dir = directory
	command.Env = append(os.Environ(), "GOMAXPROCS=4", marker)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error { return syscall.Kill(-command.Process.Pid, syscall.SIGKILL) }
	command.WaitDelay = 10 * time.Second
	return command
}

func (r mutantRunner) run(directory string, arguments ...string) (string, error, error) {
	ctx, cancel := context.WithTimeout(context.Background(), r.budget)
	defer cancel()
	marker := runMarkerName + "=" + strconv.Itoa(os.Getpid()) + "-" + strconv.FormatInt(runCounter.Add(1), 10)
	command := r.command(ctx, directory, marker, arguments...)
	var output bytes.Buffer
	command.Stdout, command.Stderr = &output, &output
	err := command.Run()
	if command.Process != nil {
		syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
	}
	sweepRun(marker)
	return output.String(), err, ctx.Err()
}

func (r mutantRunner) build(directory string) (string, error) {
	text, err, budget := r.run(directory, "build", "-p", "2", "./...")
	if budget != nil {
		return "the build exhausted its budget", budget
	}
	return text, err
}

func (r mutantRunner) test(directory, packagePath, pattern string, tagged bool) (verdict, string) {
	arguments := []string{"test", "-count=1", "-p", "2", "-timeout", r.timeout.String()}
	if tagged {
		arguments = append(arguments, "-tags", "e2e")
	}
	if pattern != "" {
		arguments = append(arguments, "-run", pattern)
	}
	arguments = append(arguments, packagePath)
	text, err, budget := r.run(directory, arguments...)
	return classifyMutantRun(text, err, budget)
}

func classifyMutantRun(text string, err, budget error) (verdict, string) {
	switch {
	case budget != nil:
		return unproven, "the run exhausted its budget and was cancelled:\n" + tail(text)
	case err == nil:
		return survived, ""
	case strings.Contains(text, "panic: test timed out after"):
		return unproven, "a test hit the Go timeout, which proves nothing:\n" + tail(text)
	case strings.Contains(text, "build failed") || strings.Contains(text, "[setup failed]"):
		return unproven, "the run failed to build:\n" + tail(text)
	case strings.Contains(text, "--- FAIL") || strings.Contains(text, "panic:"):
		return detected, ""
	}
	return unproven, "the run failed without an assertion failing:\n" + tail(text)
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
		got, evidence := runner.test(writeProbeModule(t, test.source), ".", "", false)
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
	runner := mutantRunner{timeout: time.Hour, budget: 2 * time.Second}
	pidFile := filepath.Join(t.TempDir(), "child.pid")
	directory := writeProbeModule(t, `package probe
import ("os"; "os/exec"; "strconv"; "testing")
func TestA(t *testing.T) {
	child := exec.Command("sleep", "300")
	child.Start()
	os.WriteFile("`+pidFile+`", []byte(strconv.Itoa(child.Process.Pid)), 0o600)
	select {}
}`)
	started := time.Now()
	got, evidence := runner.test(directory, ".", "", false)
	if got != unproven || !strings.Contains(evidence, "exhausted its budget") || time.Since(started) > 30*time.Second {
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

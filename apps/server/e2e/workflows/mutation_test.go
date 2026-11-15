//go:build e2e

package workflows

import (
	"context"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type edit struct {
	old   string
	new   string
	count int
}

type mutant struct {
	name     string
	file     string
	edits    []edit
	scenario string
	unit     string
}

func replace(old, replacement string) []edit {
	return []edit{{old: old, new: replacement, count: 1}}
}

var mutants = []mutant{
	{name: "inventory: a failed fetch is staged as an authoritative empty inventory", file: "internal/inventory/stage.go", edits: replace("case fetchErr != nil:", "case false:"),
		scenario: "TestUnreliableInventoriesNeverChangeLiveInventory|TestPartialFailurePublishes"},
	{name: "inventory: a truncated page list is accepted as complete", file: "internal/abs/client.go", edits: replace("return Inventory{}, &Error{Code: CodeTruncated}", "return Inventory{Items: items}, nil"),
		unit: "./internal/abs/"},
	{name: "inventory: more items than the total are accepted as complete", file: "internal/abs/client.go", edits: replace("case len(items) == total:", "case len(items) >= total:"),
		unit: "./internal/abs/"},
	{name: "inventory: a total that arrives as text is accepted", file: "internal/abs/client.go", edits: []edit{
		{"strconv.Atoi(string(document.Total))", "strconv.Atoi(strings.Trim(string(document.Total), \"\\\"\"))", 1},
		{"\t\"strconv\"\n", "\t\"strconv\"\n\t\"strings\"\n", 1},
	}, unit: "./internal/abs/"},
	{name: "inventory: configuration is not rechecked while staging and publishing", file: "internal/inventory/stage.go", edits: replace("config.Fingerprint() != active.Fingerprint", "false && config.Fingerprint() != active.Fingerprint"),
		scenario: "TestConfigurationChangedDuringFetchPublishesNothing|TestConfigurationChangedBeforePublication"},
	{name: "inventory: pruning ignores the snapshot time guard", file: "internal/inventory/publish.go", edits: replace("WHERE library_platform = ? AND library_id = ? AND (synced_at IS NULL OR synced_at <= ?)", "WHERE library_platform = ? AND library_id = ? AND (1 OR ? IS NULL)"),
		scenario: "TestExplicitEmptyInventoryRemovesOnlyItsOwnLibrary"},
	{name: "inventory: libraries are pruned as out of scope after a partial failure", file: "internal/inventory/publish.go", edits: replace("if summary.Failed == 0 {", "if true {"),
		scenario: "TestPartialFailurePublishesOnlyCompleteLibraries"},
	{name: "inventory: a restart forgets the admitted run", file: "internal/inventory/workflow.go", edits: replace("FROM wf_inventory_runs WHERE state = 'fetching'`", "FROM wf_inventory_runs WHERE state = 'nothing-is-active'`"),
		scenario: "TestCrashRecoveryAtEveryInventoryBoundary|TestShutdownDuringAFetch"},
	{name: "inventory: cancellation leaves the run active", file: "internal/inventory/workflow.go", edits: replace(`return result, w.closeRun(ctx, active, "cancelled", OutcomeCancelled)`, "return result, nil"),
		scenario: "TestCancellationIsPersisted"},
	{name: "ownership: writes are not fenced by the generation", file: "internal/wfstore/owner.go", edits: replace("if current != o.Generation {", "if false {"),
		scenario: "TestSupersededOwnerCannotPublish"},
	{name: "ownership: the kernel lock is never taken", file: "internal/wfstore/lock_unix.go", edits: replace("func lockExclusive(file *os.File) error {", "func lockExclusive(file *os.File) error {\n\tif true {\n\t\treturn nil\n\t}"),
		scenario: "TestSecondInstanceOfADomain"},
	{name: "isolation: a group readable directory is accepted", file: "internal/wfstore/store.go", edits: replace("info.Mode().Perm()&0o077 != 0", "false"),
		scenario: "TestRunOnlyAcceptsADirectoryPreparedFromABundle"},
	{name: "isolation: non-loopback destinations are dialled", file: "internal/netguard/netguard.go", edits: replace("if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {", "if ip := net.ParseIP(host); false && (ip == nil || !ip.IsLoopback()) {"),
		scenario: "TestDestinationsOutsideLoopbackAreNeverContacted"},
	{name: "downloads: the torrent identity is not part of the ownership check", file: "internal/monitor/apply.go", edits: replace("external_id = ? AND download_client_id IS ?", "(external_id = ? OR 1) AND download_client_id IS ?"),
		scenario: "TestOldObservationsCannotActOnACancelledOrReplacedAttempt"},
	{name: "downloads: the selected release is not part of the ownership check", file: "internal/monitor/apply.go", edits: replace("(search_result_id IS NULL OR EXISTS (SELECT 1 FROM search_results sr WHERE sr.id = downloads.search_result_id AND sr.status = 1))", "1"),
		scenario: "TestOldObservationsCannotActOnACancelledOrReplacedAttempt|TestOnlyAnEmptyAnswer"},
	{name: "downloads: a cancelled download can still be completed", file: "internal/monitor/apply.go", edits: replace("AND status = 1 AND `+selectedRelease, arguments...)\n\t\tif err != nil {\n\t\t\treturn err\n\t\t}\n\t\tif count, _ := claimed", "AND status IN (0, 1, 2, 3, 4) AND `+selectedRelease, arguments...)\n\t\tif err != nil {\n\t\t\treturn err\n\t\t}\n\t\tif count, _ := claimed"),
		scenario: "TestOldObservationsCannotActOnACancelledOrReplacedAttempt"},
	{name: "downloads: client errors are treated as not found", file: "internal/monitor/monitor.go", edits: replace("if pollErr != nil {", "if false {"),
		scenario: "TestClientErrorsAreNeverTreatedAsNotFound|TestAnUnreachableClient"},
	{name: "downloads: unchanged progress is rewritten", file: "internal/monitor/apply.go", edits: replace("AND (progress IS NOT ? OR not_found_count <> 0)", "AND (1 OR ? IS NULL)"),
		scenario: "TestProgressIsPersistedTruthfullyAndOnlyWhenItChanges"},
	{name: "downloads: a failed handoff delivery is marked delivered", file: "internal/monitor/deliver.go", edits: replace("if response.StatusCode < 200 || response.StatusCode > 299 {", "if false {"),
		scenario: "TestFailedHandoffStaysPending|TestHandoffRedelivery"},
	{name: "downloads: observations are not bounded in concurrency", file: "internal/monitor/monitor.go", edits: replace("slots  = make(chan struct{}, workers)", "slots  = make(chan struct{}, workers*100)"),
		scenario: "TestOnlyTheConfiguredNumberOfObservationsRunAtOnce"},
	{name: "downloads: an incomplete cycle consumes its schedule slot", file: "internal/monitor/monitor.go", edits: replace("if cycleCtx.Err() != nil {\n\t\tif ctx.Err() == nil {", "if false {\n\t\tif ctx.Err() == nil {"),
		scenario: "TestACycleThatExceedsItsDeadlineIsReportedAndRetried"},
	{name: "downloads: a cycle consumes a slot created by a control change during it", file: "internal/wfstore/schedule.go", edits: replace("AND next_due_at <= ? AND control_seq = ?", "AND next_due_at <= ? AND ? IS NOT NULL"),
		scenario: "TestControlChangesDuringACycleKeepTheScheduleDue"},
	{name: "inventory: a cancellation epoch change does not cancel the run", file: "internal/inventory/workflow.go", edits: replace("schedule.State != \"enabled\" || schedule.CancelEpoch != active.CancelEpoch", "schedule.State != \"enabled\""),
		scenario: "TestCancellationSurvivesAResume"},
	{name: "inventory: the credential is not part of the configuration fingerprint", file: "internal/inventory/config.go", edits: replace("+ \"\\x00\" + c.APIKey + \"\\x00\" + scope", "+ \"\\x00\" + scope"),
		scenario: "TestCredentialChangesAbandonAStagedRun"},
	{name: "downloads: progress ignores the selected release", file: "internal/monitor/apply.go", edits: replace("owned, err := w.stillOwned(ctx, tx, entry, true)", "owned, err := w.stillOwned(ctx, tx, entry, false)"),
		scenario: "TestStaleObservationsWriteNeitherProgressNorState"},
	{name: "downloads: handoff backoff overflows for large attempt counts", file: "internal/monitor/deliver.go", edits: replace("factor := 1 << min(entry.Attempts, maxBackoffShift)", "factor := 1 << entry.Attempts"),
		scenario: "TestHandoffBackoffStaysCapped"},
	{name: "downloads: the torrent state mapping loses completion", file: "internal/qbit/client.go", edits: replace(`case "uploading", "forcedUP", "stalledUP", "queuedUP", "pausedUP", "stoppedUP", "checkingUP":`, `case "forcedUP", "stalledUP", "queuedUP", "pausedUP", "stoppedUP", "checkingUP":`),
		unit: "./internal/qbit/"},
	{name: "downloads: progress above one is accepted", file: "internal/qbit/client.go", edits: replace("progress < 0 || progress > 1", "progress < 0 || progress > 100"),
		unit: "./internal/qbit/"},
	{name: "extraction: the publication year is read from the whole string", file: "internal/abs/extract.go", edits: replace("regexp.MustCompile(`\\d{4}`)", "regexp.MustCompile(`^\\d{4}$`)"),
		unit: "./internal/abs/"},
	{name: "extraction: author precedence is reversed", file: "internal/abs/extract.go", edits: replace("dig(raw, \"author\"),\n\t\tdig(raw, \"authorName\"),", "dig(raw, \"authorName\"),\n\t\tdig(raw, \"author\"),"),
		unit: "./internal/abs/"},
}

func copyModule(t *testing.T, destination string) {
	t.Helper()
	source, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range []string{"go.mod", "go.sum", "cmd", "internal"} {
		root := filepath.Join(source, entry)
		err := filepath.WalkDir(root, func(path string, dirEntry fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			relative, _ := filepath.Rel(source, path)
			target := filepath.Join(destination, relative)
			if dirEntry.IsDir() {
				return os.MkdirAll(target, 0o700)
			}
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			return os.WriteFile(target, data, 0o600)
		})
		if err != nil {
			t.Fatal(err)
		}
	}
}

func applyEdits(t *testing.T, dir string, entry mutant) {
	t.Helper()
	path := filepath.Join(dir, entry.file)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	for _, change := range entry.edits {
		if got := strings.Count(text, change.old); got != change.count {
			t.Fatalf("the mutation text occurs %d times, want %d: %q", got, change.count, change.old)
		}
		text = strings.ReplaceAll(text, change.old, change.new)
	}
	if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
}

func buildMutant(t *testing.T, dir, name, tags string) string {
	t.Helper()
	output := filepath.Join(dir, name)
	arguments := []string{"build", "-trimpath", "-o", output}
	if tags != "" {
		arguments = append(arguments, "-tags", tags)
	}
	command := exec.Command("go", append(arguments, "./cmd/shelfarr-workflows")...)
	command.Dir = dir
	command.Env = append(os.Environ(), "CGO_ENABLED=0")
	if combined, err := command.CombinedOutput(); err != nil {
		t.Fatalf("mutant build failed: %v\n%s", err, combined)
	}
	return output
}

func TestMutantsAreDetected(t *testing.T) {
	if os.Getenv("SHELFARR_WORKFLOW_FAULT_BINARY") != "" {
		t.Skip("running inside a mutant")
	}
	limit := make(chan struct{}, 4)
	for _, entry := range mutants {
		entry := entry
		t.Run(entry.name, func(t *testing.T) {
			t.Parallel()
			limit <- struct{}{}
			defer func() { <-limit }()
			dir := t.TempDir()
			copyModule(t, dir)
			applyEdits(t, dir, entry)
			ctx, cancel := context.WithTimeout(context.Background(), 8*time.Minute)
			defer cancel()
			var command *exec.Cmd
			if entry.unit != "" {
				command = exec.CommandContext(ctx, "go", "test", "-count=1", entry.unit)
				command.Dir = dir
			} else {
				fault := buildMutant(t, dir, "mutant-fault", "faultinject")
				plain := buildMutant(t, dir, "mutant-plain", "")
				command = exec.CommandContext(ctx, "go", "test", "-tags", "e2e", "-count=1", "-run", entry.scenario, "./e2e/workflows/")
				command.Dir, _ = filepath.Abs("../..")
				command.Env = append(os.Environ(), "SHELFARR_WORKFLOW_FAULT_BINARY="+fault, "SHELFARR_WORKFLOW_PLAIN_BINARY="+plain)
			}
			output, err := command.CombinedOutput()
			text := string(output)
			if err == nil {
				t.Fatalf("the mutant survived:\n%s", text)
			}
			if strings.Contains(text, "build failed") || !strings.Contains(text, "--- FAIL") {
				t.Fatalf("the mutant was not rejected by an assertion:\n%s", text)
			}
		})
	}
}

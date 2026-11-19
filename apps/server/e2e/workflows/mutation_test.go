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
	{name: "downloads: progress ignores the selected release", file: "internal/monitor/apply.go", edits: replace("progressed, stale = false, false\n\t\towned, err := w.stillOwned(ctx, tx, entry, true)", "progressed, stale = false, false\n\t\towned, err := w.stillOwned(ctx, tx, entry, false)"),
		scenario: "TestStaleObservationsWriteNeitherProgressNorState"},
	{name: "downloads: handoff backoff overflows for large attempt counts", file: "internal/monitor/deliver.go", edits: replace("factor := 1 << min(entry.Attempts, maxBackoffShift)", "factor := 1 << entry.Attempts"),
		scenario: "TestHandoffBackoffStaysCapped"},
	{name: "downloads: state is recorded for a replaced release", file: "internal/monitor/apply.go", edits: replace("if owned, err := w.stillOwned(ctx, tx, entry, true); err != nil || !owned {\n\t\treturn err\n\t}\n\treturn w.writeStateIn", "if owned, err := w.stillOwned(ctx, tx, entry, false); err != nil || !owned {\n\t\treturn err\n\t}\n\treturn w.writeStateIn"),
		scenario: "TestStaleErrorAndBlockedStatesAreNeverWritten"},
	{name: "downloads: completion leaves earlier error state in place", file: "internal/monitor/apply.go", edits: replace("if err := w.writeStateIn(ctx, tx, entry, \"\", \"\", false); err != nil {", "if err := w.recordStateIn(ctx, tx, entry, \"\", \"\", false); err != nil {"),
		scenario: "TestCompletionClearsEarlierErrorAndBlockedState"},
	{name: "downloads: the torrent state mapping loses completion", file: "internal/qbit/client.go", edits: replace(`case "uploading", "forcedUP", "stalledUP", "queuedUP", "pausedUP", "stoppedUP", "checkingUP":`, `case "forcedUP", "stalledUP", "queuedUP", "pausedUP", "stoppedUP", "checkingUP":`),
		unit: "./internal/qbit/"},
	{name: "downloads: progress above one is accepted", file: "internal/qbit/client.go", edits: replace("progress < 0 || progress > 1", "progress < 0 || progress > 100"),
		unit: "./internal/qbit/"},
	{name: "extraction: the publication year is read from the whole string", file: "internal/abs/extract.go", edits: replace("regexp.MustCompile(`\\d{4}`)", "regexp.MustCompile(`^\\d{4}$`)"),
		unit: "./internal/abs/"},
	{name: "admission: the oldest of several matching books is reused", file: "internal/admission/admission.go", edits: replace("book_type = ? ORDER BY id DESC LIMIT 1", "book_type = ? ORDER BY id LIMIT 1"),
		scenario: "TestRequestAdmissionMatchesTheRailsContract"},
	{name: "admission: another account's open request is answered as the caller's", file: "internal/admission/admission.go", edits: replace("AND status IN (`+openStatuses+`) AND user_id = ? ORDER BY id LIMIT 1`", "AND status IN (`+openStatuses+`) AND ? IS NOT NULL ORDER BY id LIMIT 1`"),
		scenario: "TestRequestAdmissionMatchesTheRailsContract|TestRequestAdmissionSerializesConcurrentAttempts"},
	{name: "admission: an acquired older copy of the work is ignored", file: "internal/admission/admission.go", edits: replace("\tfor rows.Next() {\n\t\tvar id int64", "\tif rows.Next() {\n\t\tvar id int64"),
		scenario: "TestRequestAdmissionMatchesTheRailsContract|TestRequestAdmissionConsidersEveryCopyOfTheWork"},
	{name: "admission: the caller's own request behind another account's is not found", file: "internal/admission/admission.go", edits: replace("AND status IN (`+openStatuses+`) AND user_id = ? ORDER BY id LIMIT 1`, workID, accountID)", "AND status IN (`+openStatuses+`) AND user_id = ? AND 0 ORDER BY id LIMIT 1`, workID, accountID)"),
		scenario: "TestRequestAdmissionMatchesTheRailsContract"},
	{name: "admission: an acquired book with id 0 counts as absent", file: "internal/admission/admission.go", edits: replace("if inLibrary {", "if inLibrary && publication != 0 {"),
		scenario: "TestRequestAdmissionConsidersEveryCopyOfTheWork"},
	{name: "admission: an unknown request status is ignored", file: "internal/admission/admission.go", edits: replace("if unknown > 0 {", "if false {"),
		scenario: "TestRequestAdmissionMatchesTheRailsContract"},
	{name: "admission: the body is read without watching for a stop", file: "cmd/shelfarr-workflows/request.go", edits: replace("case <-ctx.Done():\n\t\treturn nil, ctx.Err()\n", ""),
		scenario: "TestRequestAdmissionStopsWhileWaitingForItsBody"},
	{name: "admission: a request awaiting purchase is not open", file: "internal/admission/admission.go", edits: replace(`openStatuses       = "0, 1, 3, 4, 7"`, `openStatuses       = "0, 1, 3, 4"`),
		scenario: "TestRequestAdmissionMatchesTheRailsContract"},
	{name: "admission: a whitespace-only file path counts as acquired", file: "internal/admission/admission.go", edits: replace("return path.Valid && !rubyBlank(path.String)", "return path.Valid && path.String != \"\""),
		scenario: "TestRequestAdmissionMatchesTheRailsContract"},
	{name: "admission: a deleted account may request", file: "internal/admission/admission.go", edits: replace("case deletedAt.Valid:", "case false:"),
		scenario: "TestRequestAdmissionMatchesTheRailsContract|TestRequestAdmissionRechecksTheAccountInsideTheTransaction"},
	{name: "admission: a stored blank title is kept", file: "internal/admission/admission.go", edits: replace("if rubyBlank(book.title) {", "if book.title == \"\" {"),
		scenario: "TestRequestAdmissionMatchesTheRailsContract"},
	{name: "admission: another format of the work is not reported", file: "internal/admission/admission.go", edits: replace("return []string{format.warning}, nil", "continue"),
		scenario: "TestRequestAdmissionMatchesTheRailsContract"},
	{name: "admission: a newer schema is accepted", file: "internal/admission/admission.go", edits: replace("if !contains(SupportedRevisions, revision.String) {", "if false {"),
		scenario: "TestRequestAdmissionRefusesAnUnknownSchema"},
	{name: "admission: a failure after the inserts still commits", file: "internal/admission/admission.go", edits: replace(`if err := fault.Hit(ctx, "admission.before-commit"); err != nil {`, `if err := fault.Hit(ctx, "admission.before-commit"); err != nil && false {`),
		scenario: "TestRequestAdmissionLeavesNothingWhenItStopsBeforeCommit"},
	{name: "admission: the write lock is taken only at the first write", file: "internal/wfstore/store.go", edits: replace(`query.Set("_txlock", "immediate")`, `query.Set("_txlock", "deferred")`),
		scenario: "TestRequestAdmissionSerializesConcurrentAttempts"},
	{name: "admission: titles are stored unstripped", file: "internal/admission/submission.go", edits: replace("stripped := rubyStrip(value.Text)\n\treturn stripped, !rubyBlank(stripped)", "stripped := value.Text\n\treturn stripped, !rubyBlank(stripped)"),
		unit: "./internal/admission/"},
	{name: "admission: a plain http cover is kept", file: "internal/admission/submission.go", edits: replace("`\\Ahttps://[A-Za-z0-9]", "`\\Ahttps?://[A-Za-z0-9]"),
		unit: "./internal/admission/"},
	{name: "admission: alias work ids are admitted", file: "internal/admission/submission.go", edits: replace(`bookType.Text != "ebook" || sources > 0 {`, `bookType.Text != "ebook" || sources > maxSourceWorkIDs {`),
		unit: "./internal/admission/"},
	{name: "search: a live claim of another worker is taken over", file: "internal/acquisition/claim.go", edits: replace("AND search_claimed_at IS NOT NULL AND search_claimed_at <= ?))`,", "AND search_claimed_at IS NOT NULL AND ? IS NOT NULL))`,"),
		scenario: "TestGutenbergSearchSurvivesAKill|TestGutenbergSearchRefusesWorkItMustNotClaim"},
	{name: "search: a heartbeat does not move the lease", file: "internal/acquisition/claim.go", edits: replace("`UPDATE requests SET search_claimed_at = ? WHERE id = ?", "`UPDATE requests SET search_claimed_at = CASE WHEN ? IS NOT NULL THEN search_claimed_at END WHERE id = ?"),
		scenario: "TestGutenbergSearchDiscardsASupersededAnswer"},
	{name: "search: a cleared claim still publishes", file: "internal/acquisition/publish.go", edits: replace(" || !row.claimedAt.Valid {", " {"),
		scenario: "TestGutenbergSearchDiscardsASupersededAnswer"},
	{name: "search: a changed request language still publishes", file: "internal/acquisition/claim.go", edits: replace("query.Author == c.Query.Author && query.Language == c.Query.Language && query.Limit == c.Query.Limit", "query.Author == c.Query.Author && query.Limit == c.Query.Limit"),
		scenario: "TestGutenbergSearchDiscardsASupersededAnswer"},
	{name: "search: an answer that is not an OPDS feed is read as empty", file: "internal/gutenberg/opds.go", edits: replace("if root.name != \"feed\" {", "if false {"),
		scenario: "TestGutenbergProviderFailuresAreNeverReadAsNoResults"},
	{name: "search: an unread book page with nothing valid is read as no results", file: "internal/gutenberg/client.go", edits: replace("unread = unread || parsed.nextPage", "unread = unread || false"),
		scenario: "TestGutenbergProviderFailuresAreNeverReadAsNoResults"},
	{name: "search: elements and attributes of other namespaces are read as Atom", file: "internal/gutenberg/opds.go", edits: replace(`return "{" + name.Space + "}" + name.Local`, "return name.Local"),
		unit: "./internal/gutenberg/"},
	{name: "search: escaped text outside the feed is read as white space", file: "internal/gutenberg/opds.go", edits: []edit{{"bytes.Trim(body[start:decoder.InputOffset()], ", "bytes.Trim(token, ", 1}, {"\t\tstart := decoder.InputOffset()\n", "", 1}}, unit: "./internal/gutenberg/"},
	{name: "search: a repeated or rebound attribute is read", file: "internal/gutenberg/opds.go", edits: replace(`if seen[attribute.Name] || (attribute.Name.Space == "xmlns" && attribute.Value == "") {`, "if false {"),
		unit: "./internal/gutenberg/"},
	{name: "search: an unread page with nothing valid is read as no results", file: "internal/gutenberg/client.go", edits: replace("if unread {", "if false {"),
		scenario: "TestGutenbergProviderFailuresAreNeverReadAsNoResults"},
	{name: "search: publication is not fenced by the claim generation", file: "internal/acquisition/publish.go", edits: replace("if row.status != searchingStatus || row.generation != claim.Generation || !row.claimedAt.Valid {", "if row.status != searchingStatus || !row.claimedAt.Valid {"),
		scenario: "TestGutenbergSearchDiscardsASupersededAnswer"},
	{name: "search: a heartbeat renews a superseded claim", file: "internal/acquisition/claim.go", edits: replace("WHERE id = ? AND status = ? AND search_generation = ? AND search_claimed_at IS NOT NULL`", "WHERE id = ? AND status = ? AND search_generation >= ? AND search_claimed_at IS NOT NULL`"),
		scenario: "TestGutenbergSearchDiscardsASupersededAnswer"},
	{name: "search: a transient provider failure is published as no results", file: "cmd/shelfarr-workflows/search.go", edits: replace("return acquisition.Release(ctx, store, claim, provider.Code, now)", "return acquisition.PublishNoResults(ctx, store, claim, now)"),
		scenario: "TestGutenbergProviderFailuresAreNeverReadAsNoResults"},
	{name: "search: a malformed catalogue answer is read as an empty one", file: "internal/gutenberg/client.go", edits: replace("return found, false, fail(CodeMalformed)", "return found, false, nil"),
		unit: "./internal/gutenberg/"},
	{name: "search: a download link to another origin is stored", file: "internal/gutenberg/origin.go", edits: replace(`if strings.HasPrefix(link, "//") || !safePath.MatchString(link) {`, "if false {"),
		scenario: "TestGutenbergProviderFailuresAreNeverReadAsNoResults"},
	{name: "search: a catalogue outside loopback is accepted", file: "internal/acquisition/settings.go", edits: replace("if !origin.Loopback() {", "if false {"),
		scenario: "TestGutenbergSearchRefusesWorkItMustNotClaim"},
	{name: "search: an enabled custom provider is ignored", file: "internal/acquisition/claim.go", edits: replace("if custom > 0 {", "if false {"),
		scenario: "TestGutenbergSearchRefusesWorkItMustNotClaim"},
	{name: "search: manual and blocklisted results are replaced", file: "internal/acquisition/publish.go", edits: replace("AND source NOT IN (` + manualSources + `) AND blocklisted_at IS NULL\n", "AND 1\n"),
		scenario: "TestGutenbergSearchPublishesCandidatesForManualSelection"},
	{name: "search: a configuration change during the search is published", file: "internal/acquisition/publish.go", edits: replace("if err != nil || !claim.searchedWith(current, config) {", "if !claim.searchedWith(current, config) && false {"),
		scenario: "TestGutenbergSearchDiscardsASupersededAnswer"},
	{name: "download: a library root writable by others is accepted", file: "internal/bookfile/root_linux.go", edits: replace("status.Mode&0o022 != 0", "false"),
		scenario: "TestGutenbergDownloadRefusesBeforeAnyEffect"},
	{name: "download: symbolic links and mounts are followed out of the library", file: "internal/bookfile/root_linux.go", edits: replace("confined     = unix.RESOLVE_BENEATH | unix.RESOLVE_NO_SYMLINKS | unix.RESOLVE_NO_MAGICLINKS | unix.RESOLVE_NO_XDEV", "confined     = 0"),
		scenario: "TestGutenbergDownloadNeverReplacesOrEscapesTheLibrary|TestGutenbergDownloadRefusesBeforeAnyEffect"},
	{name: "download: a file the workflow does not own is removed", file: "internal/bookfile/root_linux.go", edits: replace(" || (Identity{Device: uint64(status.Dev), Inode: uint64(status.Ino)}) != owned {", " {"),
		scenario: "TestGutenbergDownloadSurvivesKillsAtEveryBoundary"},
	{name: "download: recovery forgets an intent without removing its orphan", file: "cmd/shelfarr-workflows/download.go", edits: replace("\tif !referenced {", "\tif referenced && false {"),
		scenario: "TestGutenbergDownloadSurvivesKillsAtEveryBoundary"},
	{name: "download: completion is not fenced by the selection that was read", file: "internal/acquisition/selection.go", edits: replace("if err != nil || current.Completed != 0 || current.Selection != selection {", "if err != nil || current.Completed != 0 {"),
		scenario: "TestGutenbergDownloadDiscardsASupersededSelection"},
	{name: "download: the library root is not rechecked before completion", file: "cmd/shelfarr-workflows/download.go", edits: replace("if err := root.Unchanged(); err != nil {", "if false {"),
		scenario: "TestGutenbergDownloadDiscardsASupersededSelection"},
	{name: "download: bytes that are not an EPUB are published", file: "cmd/shelfarr-workflows/download.go", edits: replace("if err := bookfile.CheckEPUB(fetchCtx, staged.File, staged.Size); err != nil {", "if err := bookfile.CheckEPUB(fetchCtx, staged.File, staged.Size); err != nil && false {"),
		scenario: "TestGutenbergDownloadFailuresWriteNothing"},
	{name: "download: the size limit is applied only after reading everything", file: "internal/gutenberg/download.go", edits: replace("io.LimitReader(response.Body, limit+1)", "response.Body"),
		scenario: "TestGutenbergDownloadFailuresWriteNothing"},
	{name: "download: a completed request is downloaded again", file: "internal/acquisition/selection.go", edits: replace("if row.status == completedRequest {", "if false {"),
		scenario: "TestGutenbergDownloadPublishesOneLibraryEbook"},
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

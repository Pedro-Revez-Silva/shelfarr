//go:build e2e

package workflows

import (
	"bytes"
	"cmp"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
)

const admissionEvidenceEnvironment = "SHELFARR_ADMISSION_EVIDENCE"

const seededStamp = "2026-11-01 10:00:00.000000"

var admissionTables = []string{"books", "requests", "activity_logs"}

type admissionAnswer struct {
	code    int
	event   string
	fields  event
	outcome string
}

func (w *workdir) admit(binary string, injected faults, account string, body string) admissionAnswer {
	w.t.Helper()
	command := exec.Command(binary, "request", "--workdir", w.dir, "--account", account)
	command.Env = append([]string{"PATH=" + os.Getenv("PATH")}, injected.environment()...)
	command.Dir = w.t.TempDir()
	command.Stdin = strings.NewReader(body)
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	err := command.Run()
	answer := admissionAnswer{code: command.ProcessState.ExitCode()}
	var exit *exec.ExitError
	if err != nil && !errors.As(err, &exit) {
		w.t.Fatalf("request did not run: %v", err)
	}
	lines := strings.Split(strings.TrimSpace(stdout.String()), "\n")
	if stdout.Len() > 0 {
		if len(lines) != 1 || json.Unmarshal([]byte(lines[0]), &answer.fields) != nil {
			w.t.Fatalf("request output is not one JSON line: %q %q", stdout.String(), stderr.String())
		}
		answer.event = answer.fields.name()
		answer.outcome = answer.fields.text("outcome")
		if answer.event == "rejected" {
			answer.outcome = answer.fields.text("code")
		}
	}
	return answer
}

type admissionCase struct {
	Name          string          `json:"name"`
	Account       string          `json:"account"`
	AccountID     int64           `json:"account_id"`
	Body          json.RawMessage `json:"body"`
	Oracle        bool            `json:"oracle"`
	Difference    string          `json:"difference,omitempty"`
	Outcome       string          `json:"outcome"`
	RequestID     string          `json:"request_id,omitempty"`
	PublicationID string          `json:"publication_id,omitempty"`
	Warnings      []string        `json:"warnings"`
}

type admissionExpectation struct {
	name          string
	account       string
	body          string
	oracle        bool
	difference    string
	outcome       string
	sameRequestAs string
	requestOnBook string
	publication   string
	warnings      []string
	stored        map[string]string
}

type seededLibrary struct {
	users map[string]int64
	books map[string]int64
}

func (s seededLibrary) resolve(reference string) string {
	if id, ok := s.books[reference]; ok {
		return itoa(id)
	}
	return reference
}

func seedAdmissionLibrary(t *testing.T, db *sql.DB, defaultLanguage string) seededLibrary {
	t.Helper()
	library := seededLibrary{users: map[string]int64{}, books: map[string]int64{}}
	for _, username := range []string{"alice", "bob", "carol"} {
		library.users[username] = scalar[int64](t, db, `SELECT id FROM users WHERE username = ?`, username)
	}
	if scalar[int64](t, db, `SELECT COUNT(*) FROM users WHERE username = 'carol' AND deleted_at IS NOT NULL`) != 1 {
		t.Fatal("the fixture's carol must be a deleted account")
	}
	type seededBook struct {
		key, work, title, path, hardcover, metadataSource, token string
		bookType, contentKind                                    int
		blankTitle                                               bool
	}
	books := []seededBook{
		{key: "acquired", work: "OL1001W", title: "Seeded Acquired", path: "/library/seeded/acquired.epub", bookType: 1},
		{key: "searching", work: "OL1002W", title: "Seeded Searching", bookType: 1},
		{key: "history", work: "OL1003W", title: "Seeded History", bookType: 1},
		{key: "listening", work: "OL1004W", title: "Seeded Listening", path: "/library/seeded/listening", bookType: 0},
		{key: "completed-elsewhere", work: "OL1005W", title: "Seeded Completed Elsewhere", bookType: 1},
		{key: "alias", work: "OL1006W", hardcover: "hc-1006", metadataSource: "hardcover", bookType: 1, blankTitle: true},
		{key: "older-copy", work: "OL1007W", title: "Seeded Older Copy", path: "/library/seeded/older.epub", bookType: 1},
		{key: "newer-copy", work: "OL1007W", title: "Seeded Newer Copy", bookType: 1},
		{key: "blank-path", work: "OL1009W", title: "Seeded Blank Path", path: "\t ", bookType: 1},
		{key: "graphic", work: "OL1010W", title: "Seeded Graphic Novel", bookType: 1, contentKind: 1, metadataSource: "-"},
		{key: "awaiting", work: "OL1011W", title: "Seeded Awaiting", bookType: 1},
		{key: "comic", work: "OL1013W", title: "Seeded Comic", path: "/library/seeded/comic.cbz", bookType: 2, contentKind: 1},
		{key: "reserved-ownerless", work: "OL1014W", token: "seeded-ownerless-token", bookType: 1, blankTitle: true},
	}
	for index, book := range books {
		id := int64(1001 + index)
		library.books[book.key] = id
		nullable := func(value string) any {
			if value == "" {
				return nil
			}
			return value
		}
		title := book.title
		if book.blankTitle {
			title = " "
		}
		source := any("openlibrary")
		switch book.metadataSource {
		case "-":
			source = nil
		case "":
		default:
			source = book.metadataSource
		}
		exec1(t, db, `INSERT INTO books (id, open_library_work_id, hardcover_id, book_type, content_kind, title, file_path, metadata_source, acquisition_reservation_token, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			id, book.work, nullable(book.hardcover), book.bookType, book.contentKind, title, nullable(book.path), source, nullable(book.token), seededStamp, seededStamp)
	}
	requests := []struct {
		id      int64
		book    string
		account string
		status  int
	}{
		{501, "searching", "bob", 1},
		{502, "history", "bob", 2},
		{503, "history", "alice", 6},
		{504, "completed-elsewhere", "alice", 5},
		{505, "awaiting", "alice", 7},
		{506, "acquired", "bob", 0},
	}
	for _, request := range requests {
		exec1(t, db, `INSERT INTO requests (id, book_id, user_id, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)`,
			request.id, library.books[request.book], library.users[request.account], request.status, seededStamp, seededStamp)
	}
	library.books["released-acquired"] = scalar[int64](t, db, `SELECT id FROM books WHERE title = 'The Quiet Library'`)
	library.books["released-unacquired"] = scalar[int64](t, db, `SELECT id FROM books WHERE title = 'Not Yet Acquired'`)
	exec1(t, db, `UPDATE books SET open_library_work_id = 'OL2001W' WHERE id = ?`, library.books["released-acquired"])
	exec1(t, db, `UPDATE books SET open_library_work_id = 'OL2002W' WHERE id = ?`, library.books["released-unacquired"])
	if defaultLanguage != "" {
		exec1(t, db, `INSERT INTO settings (key, value, value_type, category, created_at, updated_at) VALUES ('default_language', ?, 'string', 'language', ?, ?)`, defaultLanguage, seededStamp, seededStamp)
	}
	return library
}

func admissionBody(work string, extra string) string {
	body := `{"work_id":"openlibrary:` + work + `","book_type":"ebook","title":"Admitted ` + work + `"`
	if extra != "" {
		body += "," + extra
	}
	return body + "}"
}

func admissionScenarios() []admissionExpectation {
	none := []string{}
	return []admissionExpectation{
		{name: "fresh-created", account: "alice", body: admissionBody("OL3001W", `"author":" Frank Herbert ","cover_url":"https://covers.example.test/3001.jpg","year":1965,"language":"fr"`), oracle: true, outcome: "created", warnings: none,
			stored: map[string]string{"b.title": "string:Admitted OL3001W", "b.author": "string:Frank Herbert", "b.cover_url": "string:https://covers.example.test/3001.jpg", "b.year": "int64:1965", "b.content_kind": "int64:0", "b.metadata_source": "string:openlibrary", "b.language": "string:en", "b.file_path": "NULL", "r.language": "string:fr"}},
		{name: "fresh-repeat", account: "alice", body: admissionBody("OL3001W", `"author":"Someone Else"`), oracle: true, outcome: "existing", sameRequestAs: "fresh-created"},
		{name: "fresh-other-account", account: "bob", body: admissionBody("OL3001W", ""), oracle: true, outcome: "already_requested"},
		{name: "acquired", account: "bob", body: admissionBody("OL1001W", ""), oracle: true, outcome: "already_in_library", publication: "acquired"},
		{name: "active-other-account", account: "alice", body: admissionBody("OL1002W", ""), oracle: true, outcome: "already_requested"},
		{name: "active-own", account: "bob", body: admissionBody("OL1002W", ""), oracle: true, outcome: "existing"},
		{name: "retry-after-history", account: "alice", body: admissionBody("OL1003W", ""), oracle: true, outcome: "created", requestOnBook: "history", warnings: []string{"A previous request for this ebook was not found. You can try again."}},
		{name: "same-work-other-format", account: "alice", body: admissionBody("OL1004W", ""), oracle: true, outcome: "created", warnings: []string{"This title exists as an audiobook. You can still request the ebook."}},
		{name: "completed-without-file", account: "bob", body: admissionBody("OL1005W", ""), oracle: true, outcome: "created", requestOnBook: "completed-elsewhere", warnings: none},
		{name: "alias-backfill", account: "bob", body: admissionBody("OL1006W", `"author":"Alias Author","cover_url":"https://covers.example.test/1006.jpg","year":2001`), oracle: true, outcome: "created", requestOnBook: "alias", warnings: none,
			stored: map[string]string{"b.title": "string:Admitted OL1006W", "b.author": "string:Alias Author", "b.cover_url": "string:https://covers.example.test/1006.jpg", "b.year": "int64:2001", "b.metadata_source": "string:hardcover", "b.hardcover_id": "string:hc-1006"}},
		{name: "newest-duplicate-book", account: "alice", body: admissionBody("OL1007W", ""), oracle: true, outcome: "created", requestOnBook: "newer-copy", warnings: none},
		{name: "blank-path-not-acquired", account: "alice", body: admissionBody("OL1009W", ""), oracle: true, outcome: "created", requestOnBook: "blank-path", warnings: none},
		{name: "graphic-kind-kept", account: "alice", body: admissionBody("OL1010W", ""), oracle: true, outcome: "created", requestOnBook: "graphic", warnings: none,
			stored: map[string]string{"b.title": "string:Seeded Graphic Novel", "b.content_kind": "int64:1", "b.metadata_source": "string:openlibrary"}},
		{name: "awaiting-purchase-own", account: "alice", body: admissionBody("OL1011W", ""), oracle: true, outcome: "existing"},
		{name: "comic-warning", account: "bob", body: admissionBody("OL1013W", ""), oracle: true, outcome: "created", warnings: []string{"This title exists as a Comics & Manga title. You can still request the ebook."}},
		{name: "adopted-acquired", account: "alice", body: admissionBody("OL2001W", ""), oracle: true, outcome: "already_in_library", publication: "released-acquired"},
		{name: "adopted-unacquired", account: "bob", body: admissionBody("OL2002W", `"cover_url":"https://covers.example.test/2002.jpg"`), oracle: true, outcome: "created", requestOnBook: "released-unacquired", warnings: none},
		{name: "reserved-without-owner", account: "alice", body: admissionBody("OL1014W", ""), oracle: true, outcome: "unsupported_stored_value"},
		{name: "deleted-account", account: "carol", body: admissionBody("OL3002W", ""), oracle: true, outcome: "account_unavailable"},
		{name: "blank-title", account: "alice", body: `{"work_id":"openlibrary:OL3008W","book_type":"ebook","title":" \t "}`, oracle: true, outcome: "invalid_request"},
		{name: "fractional-year", account: "alice", body: admissionBody("OL3008W", `"year":1965.0`), oracle: true, outcome: "invalid_request"},
		{name: "malformed-work-id", account: "alice", body: `{"work_id":"nope","book_type":"ebook","title":"Nope"}`, oracle: true, outcome: "invalid_request"},
		{name: "default-language", account: "alice", body: admissionBody("OL3003W", ""), oracle: true, outcome: "created", warnings: none,
			stored: map[string]string{"r.language": "DEFAULT_LANGUAGE", "b.language": "string:en"}},
		{name: "insecure-cover-dropped", account: "alice", body: admissionBody("OL3004W", `"cover_url":"http://insecure.example.test/3004.jpg"`), oracle: true, outcome: "created", warnings: none,
			stored: map[string]string{"b.cover_url": "NULL"}},
		{name: "uppercase-cover-scheme", account: "bob", body: admissionBody("OL3005W", `"cover_url":"HTTPS://covers.example.test/3005.jpg"`), oracle: true, difference: "cover_normalised_by_rails", outcome: "created", warnings: none},
		{name: "on-behalf-fields-ignored", account: "bob", body: admissionBody("OL3006W", `"user_id":"ALICE_ID","username":"alice"`), oracle: true, outcome: "created", warnings: none,
			stored: map[string]string{"r.language": "DEFAULT_LANGUAGE"}},
		{name: "unsupported-provider", account: "alice", body: `{"work_id":"hardcover:123","book_type":"ebook","title":"Elsewhere"}`, outcome: "unsupported_request"},
		{name: "unsupported-format", account: "alice", body: `{"work_id":"openlibrary:OL3001W","book_type":"audiobook","title":"Admitted OL3001W"}`, outcome: "unsupported_request"},
		{name: "unsupported-aliases", account: "alice", body: admissionBody("OL3007W", `"source_work_ids":["hardcover:9"]`), outcome: "unsupported_request"},
		{name: "missing-account", account: "missing", body: admissionBody("OL3002W", ""), outcome: "account_unavailable"},
	}
}

func TestRequestAdmissionMatchesTheRailsContract(t *testing.T) {
	for _, bundle := range []struct {
		name, path, defaultLanguage string
	}{{"current", currentBundle, "de"}, {"upgrade", upgradeBundle, ""}} {
		t.Run(bundle.name, func(t *testing.T) {
			w := prepare(t, bundle.path)
			db := w.open()
			library := seedAdmissionLibrary(t, db, bundle.defaultLanguage)
			before := digests(t, db, admissionTables...)
			workerTables := workerDigests(t, db)
			beforeRows := map[string]int64{}
			for _, table := range admissionTables {
				beforeRows[table] = scalar[int64](t, db, `SELECT COUNT(*) FROM "`+table+`"`)
			}
			lastBook := scalar[int64](t, db, `SELECT MAX(id) FROM books`)
			evidence := admissionEvidence(t, bundle.name)
			snapshot(t, db, filepath.Join(evidence, "before.sqlite3"))

			var recorded []admissionCase
			byName := map[string]admissionCase{}
			created := 0
			for _, scenario := range admissionScenarios() {
				accountID := library.users[scenario.account]
				account := itoa(accountID)
				if scenario.account == "missing" {
					account = "999999"
				}
				body := strings.ReplaceAll(scenario.body, "ALICE_ID", itoa(library.users["alice"]))
				answer := w.admit(plainBinary, faults{}, account, body)
				entry := admissionCase{Name: scenario.name, Account: scenario.account, AccountID: accountID, Body: json.RawMessage(body), Oracle: scenario.oracle,
					Difference: scenario.difference, Outcome: answer.outcome, RequestID: answer.fields.text("request_id"), PublicationID: answer.fields.text("publication_id"), Warnings: warningsOf(answer.fields)}
				checkAdmission(t, db, library, cmp.Or(bundle.defaultLanguage, "en"), scenario, entry, answer, byName)
				if entry.Outcome == "created" {
					created++
				}
				recorded = append(recorded, entry)
				byName[scenario.name] = entry
			}

			requireSame(t, before, digests(t, db, admissionTables...))
			if !reflect.DeepEqual(workerTables, workerDigests(t, db)) {
				t.Error("admission wrote a worker table")
			}
			if added := scalar[int64](t, db, `SELECT COUNT(*) FROM requests`) - beforeRows["requests"]; added != int64(created) {
				t.Errorf("%d requests added for %d created answers", added, created)
			}
			if added := scalar[int64](t, db, `SELECT COUNT(*) FROM activity_logs`) - beforeRows["activity_logs"]; added != int64(created) {
				t.Errorf("%d activity rows added for %d created answers", added, created)
			}
			if orphans := scalar[int64](t, db, `SELECT COUNT(*) FROM books WHERE id > ? AND id NOT IN (SELECT book_id FROM requests)`, lastBook); orphans != 0 {
				t.Errorf("%d new books without a request", orphans)
			}
			if verdict := scalar[string](t, db, `PRAGMA integrity_check`); verdict != "ok" {
				t.Errorf("integrity_check: %s", verdict)
			}
			snapshot(t, db, filepath.Join(evidence, "after.sqlite3"))
			writeJSON(t, filepath.Join(evidence, "cases.json"), map[string]any{"bundle": bundle.name, "users": library.users, "books": library.books, "cases": recorded})
		})
	}
}

func checkAdmission(t *testing.T, db *sql.DB, library seededLibrary, defaultLanguage string, scenario admissionExpectation, entry admissionCase, answer admissionAnswer, byName map[string]admissionCase) {
	t.Helper()
	wantEvent, wantCode := "request", 0
	switch scenario.outcome {
	case "invalid_request", "unsupported_request", "account_unavailable", "unsupported_stored_value":
		wantEvent, wantCode = "rejected", 7
	}
	if answer.event != wantEvent || answer.code != wantCode || entry.Outcome != scenario.outcome {
		t.Fatalf("%s: got %s/%s exit %d, want %s/%s exit %d", scenario.name, answer.event, entry.Outcome, answer.code, wantEvent, scenario.outcome, wantCode)
	}
	if entry.Outcome == "created" && !reflect.DeepEqual(entry.Warnings, scenario.warnings) {
		t.Errorf("%s: warnings %q, want %q", scenario.name, entry.Warnings, scenario.warnings)
	}
	if (wantEvent == "rejected" || scenario.outcome == "already_requested") && len(answer.fields) != 2 {
		t.Errorf("%s: the answer discloses more than its outcome: %v", scenario.name, answer.fields)
	}
	if scenario.publication != "" && entry.PublicationID != library.resolve(scenario.publication) {
		t.Errorf("%s: publication %q, want %q", scenario.name, entry.PublicationID, library.resolve(scenario.publication))
	}
	if scenario.sameRequestAs != "" && entry.RequestID != byName[scenario.sameRequestAs].RequestID {
		t.Errorf("%s: request %q, want the earlier %q", scenario.name, entry.RequestID, byName[scenario.sameRequestAs].RequestID)
	}
	if scenario.outcome == "existing" {
		owner := scalar[int64](t, db, `SELECT user_id FROM requests WHERE id = ?`, entry.RequestID)
		if owner != library.users[scenario.account] {
			t.Errorf("%s: existing answer named another account's request", scenario.name)
		}
	}
	if entry.Outcome != "created" {
		return
	}
	row := rows(t, db, `SELECT r.user_id, r.status, r.created_via, r.external_source, r.request_scope, r.search_generation, r.search_claimed_at, r.attention_needed, r.retry_count, r.created_at = r.updated_at, b.book_type
		FROM requests r JOIN books b ON b.id = r.book_id WHERE r.id = ?`, entry.RequestID)
	want := []string{"int64:" + itoa(library.users[scenario.account]), "int64:0", "string:api", "string:consumer_app", "string:single", "int64:0", "NULL", "int64:0", "int64:0", "int64:1", "int64:1"}
	if len(row) != 1 || !reflect.DeepEqual(row[0], want) {
		t.Errorf("%s: request row %v, want a pending api request of the caller %v", scenario.name, row, want)
	}
	if scenario.requestOnBook != "" {
		book := scalar[int64](t, db, `SELECT book_id FROM requests WHERE id = ?`, entry.RequestID)
		if book != library.books[scenario.requestOnBook] {
			t.Errorf("%s: request on book %d, want the existing book %d", scenario.name, book, library.books[scenario.requestOnBook])
		}
	}
	for column, value := range scenario.stored {
		if value == "DEFAULT_LANGUAGE" {
			value = "string:" + defaultLanguage
		}
		stored := rows(t, db, `SELECT `+column+` FROM requests r JOIN books b ON b.id = r.book_id WHERE r.id = ?`, entry.RequestID)
		if len(stored) != 1 || stored[0][0] != value {
			t.Errorf("%s: %s is %v, want %s", scenario.name, column, stored, value)
		}
	}
	activity := rows(t, db, `SELECT action, user_id, trackable_type, details, ip_address, controller FROM activity_logs WHERE trackable_id = ? AND trackable_type = 'Request'`, entry.RequestID)
	wantActivity := []string{"string:request.created", "int64:" + itoa(library.users[scenario.account]), "string:Request", `string:{"created_via":"api","external_source":"consumer_app"}`, "NULL", "NULL"}
	if len(activity) != 1 || !reflect.DeepEqual(activity[0], wantActivity) {
		t.Errorf("%s: activity %v", scenario.name, activity)
	}
}

func warningsOf(fields event) []string {
	raw, ok := fields["warnings"].([]any)
	if !ok {
		return nil
	}
	warnings := []string{}
	for _, item := range raw {
		text, _ := item.(string)
		warnings = append(warnings, text)
	}
	return warnings
}

func workerDigests(t *testing.T, db *sql.DB) map[string][][]string {
	t.Helper()
	result := map[string][][]string{}
	for _, line := range rows(t, db, `SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'wf_%'`) {
		name := strings.TrimPrefix(line[0], "string:")
		result[name] = rows(t, db, `SELECT * FROM "`+name+`" ORDER BY 1, 2`)
	}
	return result
}

func admissionEvidence(t *testing.T, name string) string {
	t.Helper()
	root := os.Getenv(admissionEvidenceEnvironment)
	if root == "" {
		root = t.TempDir()
	}
	dir := filepath.Join(root, name)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	return dir
}

func snapshot(t *testing.T, db *sql.DB, path string) {
	t.Helper()
	os.Remove(path)
	exec1(t, db, `VACUUM INTO ?`, path)
}

func writeJSON(t *testing.T, path string, value any) {
	t.Helper()
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
}

func admissionCounts(t *testing.T, db *sql.DB, work string) [3]int64 {
	t.Helper()
	return [3]int64{
		scalar[int64](t, db, `SELECT COUNT(*) FROM books WHERE open_library_work_id = ?`, work),
		scalar[int64](t, db, `SELECT COUNT(*) FROM requests WHERE book_id IN (SELECT id FROM books WHERE open_library_work_id = ?)`, work),
		scalar[int64](t, db, `SELECT COUNT(*) FROM activity_logs WHERE trackable_type = 'Request' AND trackable_id IN (SELECT r.id FROM requests r JOIN books b ON b.id = r.book_id WHERE b.open_library_work_id = ?)`, work),
	}
}

func concurrentAdmissions(w *workdir, accounts []string, body string) []admissionAnswer {
	answers := make([]admissionAnswer, len(accounts))
	var group sync.WaitGroup
	start := make(chan struct{})
	for index, account := range accounts {
		group.Add(1)
		go func() {
			defer group.Done()
			<-start
			answers[index] = w.admit(plainBinary, faults{}, account, body)
		}()
	}
	close(start)
	group.Wait()
	return answers
}

func TestRequestAdmissionSerializesConcurrentAttempts(t *testing.T) {
	w := prepare(t, currentBundle)
	db := w.open()
	library := seedAdmissionLibrary(t, db, "")
	alice, bob := itoa(library.users["alice"]), itoa(library.users["bob"])

	t.Run("same account", func(t *testing.T) {
		answers := concurrentAdmissions(w, []string{alice, alice, alice, alice, alice, alice, alice, alice}, admissionBody("OL4001W", ""))
		created, existing, ids := 0, 0, map[string]bool{}
		for _, answer := range answers {
			switch answer.outcome {
			case "created":
				created++
			case "existing":
				existing++
			default:
				t.Fatalf("unexpected answer %v exit %d", answer.fields, answer.code)
			}
			ids[answer.fields.text("request_id")] = true
		}
		if created != 1 || existing != 7 || len(ids) != 1 {
			t.Errorf("created %d existing %d over %d request ids", created, existing, len(ids))
		}
		if counts := admissionCounts(t, db, "OL4001W"); counts != [3]int64{1, 1, 1} {
			t.Errorf("books, requests, activity = %v", counts)
		}
	})

	t.Run("competing accounts", func(t *testing.T) {
		accounts := []string{alice, bob, alice, bob, alice, bob, alice, bob}
		answers := concurrentAdmissions(w, accounts, admissionBody("OL4002W", ""))
		winner := ""
		for index, answer := range answers {
			if answer.outcome == "created" {
				if winner != "" {
					t.Fatal("two accounts created a request for the same ebook")
				}
				winner = accounts[index]
			}
		}
		if winner == "" {
			t.Fatal("no attempt created the request")
		}
		for index, answer := range answers {
			want := "already_requested"
			if accounts[index] == winner {
				want = "existing"
			}
			if answer.outcome == "created" {
				continue
			}
			if answer.outcome != want {
				t.Errorf("account %s got %s, want %s", accounts[index], answer.outcome, want)
			}
			if want == "already_requested" && len(answer.fields) != 2 {
				t.Errorf("a competing account learned more than the outcome: %v", answer.fields)
			}
		}
		if counts := admissionCounts(t, db, "OL4002W"); counts != [3]int64{1, 1, 1} {
			t.Errorf("books, requests, activity = %v", counts)
		}
	})
}

func TestRequestAdmissionLeavesNothingWhenItStopsBeforeCommit(t *testing.T) {
	w := prepare(t, currentBundle)
	db := w.open()
	library := seedAdmissionLibrary(t, db, "")
	alice := itoa(library.users["alice"])
	before := digests(t, db)

	killed := w.admit(faultBinary, newFaults(t, map[string]string{"admission.book-written": "kill"}), alice, admissionBody("OL5001W", ""))
	if killed.code != -1 || killed.event != "" {
		t.Fatalf("the process was not killed inside the transaction: exit %d %v", killed.code, killed.fields)
	}
	failed := w.admit(faultBinary, newFaults(t, map[string]string{"admission.before-commit": "error"}), alice, admissionBody("OL5001W", ""))
	if failed.code != 1 || failed.event != "error" || failed.fields.text("code") != "db-error" {
		t.Fatalf("an aborted transaction answered %v exit %d", failed.fields, failed.code)
	}
	requireSame(t, before, digests(t, db))
	if counts := admissionCounts(t, db, "OL5001W"); counts != [3]int64{0, 0, 0} {
		t.Fatalf("an abandoned admission left books, requests, activity = %v", counts)
	}
	if verdict := scalar[string](t, db, `PRAGMA integrity_check`); verdict != "ok" {
		t.Fatalf("integrity_check: %s", verdict)
	}

	retried := w.admit(plainBinary, faults{}, alice, admissionBody("OL5001W", ""))
	repeated := w.admit(plainBinary, faults{}, alice, admissionBody("OL5001W", ""))
	if retried.outcome != "created" || repeated.outcome != "existing" || repeated.fields.text("request_id") != retried.fields.text("request_id") {
		t.Fatalf("retry after restart answered %v then %v", retried.fields, repeated.fields)
	}
	if counts := admissionCounts(t, db, "OL5001W"); counts != [3]int64{1, 1, 1} {
		t.Fatalf("after the retry books, requests, activity = %v", counts)
	}
}

func TestRequestAdmissionRechecksTheAccountInsideTheTransaction(t *testing.T) {
	w := prepare(t, currentBundle)
	db := w.open()
	library := seedAdmissionLibrary(t, db, "")
	injected := newFaults(t, map[string]string{"admission.authorized": "park"})
	answer := make(chan admissionAnswer, 1)
	go func() {
		answer <- w.admit(faultBinary, injected, itoa(library.users["bob"]), admissionBody("OL5002W", ""))
	}()
	injected.reached(t, "admission.authorized")
	exec1(t, db, `UPDATE users SET deleted_at = ? WHERE id = ?`, seededStamp, library.users["bob"])
	injected.release(t, "admission.authorized")
	stale := <-answer
	if stale.code != 7 || stale.outcome != "account_unavailable" {
		t.Fatalf("an account deleted after authorization answered %v exit %d", stale.fields, stale.code)
	}
	if counts := admissionCounts(t, db, "OL5002W"); counts != [3]int64{0, 0, 0} {
		t.Fatalf("books, requests, activity = %v", counts)
	}
}

func TestRequestAdmissionRefusesAnUnknownSchema(t *testing.T) {
	w := prepare(t, currentBundle)
	db := w.open()
	library := seedAdmissionLibrary(t, db, "")
	exec1(t, db, `INSERT INTO schema_migrations (version) VALUES ('29991231000000')`)
	before := digests(t, db)
	answer := w.admit(plainBinary, faults{}, itoa(library.users["alice"]), admissionBody("OL5003W", ""))
	if answer.code != 7 || answer.outcome != "unsupported_schema" {
		t.Fatalf("a newer schema answered %v exit %d", answer.fields, answer.code)
	}
	requireSame(t, before, digests(t, db))
}

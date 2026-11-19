//go:build e2e

package workflows

import (
	"archive/zip"
	"bufio"
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"hash/crc32"
	"io"
	"io/fs"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/assetid"
)

const (
	downloadEvidenceEnvironment = "SHELFARR_DOWNLOAD_EVIDENCE"
	bookLink                    = "/ebooks/1342.epub3.images"
	bookGUID                    = "gutenberg:1342"
	otherGUID                   = "gutenberg:37431"
	epubType                    = "application/epub+zip"
)

var acquisitionTables = []string{"requests", "search_results", "downloads", "request_events", "notifications", "books", "activity_logs"}

func syntheticEPUB(t *testing.T, chapter string) []byte {
	t.Helper()
	var buffer bytes.Buffer
	archive := zip.NewWriter(&buffer)
	mimetype := []byte(epubType)
	header := &zip.FileHeader{Name: "mimetype", Method: zip.Store, CRC32: crc32.ChecksumIEEE(mimetype), CompressedSize64: uint64(len(mimetype)), UncompressedSize64: uint64(len(mimetype))}
	writer, err := archive.CreateRaw(header)
	if err != nil {
		t.Fatal(err)
	}
	writer.Write(mimetype)
	files := []struct{ name, body string }{
		{"META-INF/container.xml", `<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>`},
		{"OEBPS/content.opf", `<?xml version="1.0" encoding="UTF-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:synthetic:1342</dc:identifier><dc:title>Pride and Prejudice</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">2026-11-19T10:00:00Z</meta></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="c1" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c1"/></spine></package>`},
		{"OEBPS/nav.xhtml", `<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="chapter.xhtml">Chapter 1</a></li></ol></nav></body></html>`},
		{"OEBPS/chapter.xhtml", `<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter 1</title></head><body><p>` + chapter + `</p></body></html>`},
	}
	for _, file := range files {
		writer, err := archive.Create(file.name)
		if err != nil {
			t.Fatal(err)
		}
		writer.Write([]byte(file.body))
	}
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

func digestOf(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

type acquisitionSetup struct {
	*searchSetup
	library string
	request int64
	result  int64
	other   int64
	book    int64
	epub    []byte
}

func newAcquisition(t *testing.T, bundle, parent string) *acquisitionSetup {
	t.Helper()
	if parent == "" {
		parent = t.TempDir()
	}
	setup := &acquisitionSetup{searchSetup: newSearchSetupIn(t, bundle, parent), epub: syntheticEPUB(t, "It is a truth universally acknowledged.")}
	setup.disableCustomProviders(t)
	setup.library = filepath.Join(setup.w.dir, "library")
	if err := os.Mkdir(setup.library, 0o755); err != nil {
		t.Fatal(err)
	}
	putSetting(t, setup.db, "ebook_output_path", "string", setup.library)
	setup.request = setup.admit(t, "Pride and Prejudice", "Jane Austen")
	if outcome := setup.search(t, plainBinary, faults{}, setup.request); outcome.code != 0 || last(t, outcome, "search").text("outcome") != "candidates" {
		t.Fatalf("search did not publish candidates: %s", outcome.output)
	}
	setup.result = scalar[int64](t, setup.db, `SELECT id FROM search_results WHERE request_id = ? AND guid = ?`, setup.request, bookGUID)
	setup.other = scalar[int64](t, setup.db, `SELECT id FROM search_results WHERE request_id = ? AND guid = ?`, setup.request, otherGUID)
	setup.book = scalar[int64](t, setup.db, `SELECT book_id FROM requests WHERE id = ?`, setup.request)
	setup.serveBook(setup.epub)
	setup.fake.reset()
	return setup
}

func (a *acquisitionSetup) serveBook(body []byte) {
	a.fake.set(reply{Path: bookLink, Status: 200, Body: string(body), ContentType: epubType})
}

func (a *acquisitionSetup) start(t *testing.T, binary string, injected faults, chosen int64, options ...string) *process {
	t.Helper()
	return a.w.binary(binary, injected, append([]string{"download", "--workdir", a.w.dir, "--request", itoa(a.request), "--result", itoa(chosen), "--request-timeout", "2s"}, options...)...)
}

func (a *acquisitionSetup) download(t *testing.T, binary string, injected faults, chosen int64, options ...string) result {
	t.Helper()
	run := a.start(t, binary, injected, chosen, options...)
	code := run.wait()
	return result{code: code, events: run.snapshot(), output: run.output()}
}

func (a *acquisitionSetup) bookPath() string {
	return filepath.Join(a.library, "shelfarr-gutenberg", "book-"+itoa(a.book), "gutenberg-1342.epub")
}

func (a *acquisitionSetup) entries(t *testing.T) []string {
	t.Helper()
	var found []string
	filepath.WalkDir(a.library, func(path string, entry fs.DirEntry, err error) error {
		if err != nil && path == a.library && os.IsNotExist(err) {
			return nil
		}
		if err != nil {
			t.Fatal(err)
		}
		if path != a.library {
			relative, _ := filepath.Rel(a.library, path)
			if entry.IsDir() {
				relative += "/"
			}
			found = append(found, relative)
		}
		return nil
	})
	sort.Strings(found)
	return found
}

func (a *acquisitionSetup) intent(t *testing.T) []string {
	t.Helper()
	var values []string
	for _, line := range rows(t, a.db, `SELECT value FROM wf_meta WHERE key = 'acquisition.publication'`) {
		values = append(values, line[0])
	}
	return values
}

type frozen struct {
	tables  map[string]string
	library []string
}

func (a *acquisitionSetup) freeze(t *testing.T) frozen {
	t.Helper()
	return frozen{tables: digests(t, a.db), library: a.entries(t)}
}

func (a *acquisitionSetup) requireUnchanged(t *testing.T, before frozen) {
	t.Helper()
	requireSame(t, before.tables, digests(t, a.db))
	if after := a.entries(t); !reflect.DeepEqual(after, before.library) {
		t.Errorf("library changed from %v to %v", before.library, after)
	}
	if intents := a.intent(t); len(intents) != 0 {
		t.Errorf("an intent is left: %v", intents)
	}
}

func outcomeOf(t *testing.T, run result) event {
	t.Helper()
	for index := len(run.events) - 1; index >= 0; index-- {
		switch run.events[index].name() {
		case "download", "rejected", "refused", "error":
			return run.events[index]
		}
	}
	t.Fatalf("no answer: %s", run.output)
	return nil
}

func (a *acquisitionSetup) requireCompleted(t *testing.T, run result, before frozen) int64 {
	t.Helper()
	answer := outcomeOf(t, run)
	if run.code != 0 || answer.name() != "download" || answer.text("outcome") != "completed" || answer.text("sha256") != digestOf(a.epub) || answer.number("bytes") != int64(len(a.epub)) {
		t.Fatalf("exit %d: %s", run.code, run.output)
	}
	for _, leaked := range []string{"127.0.0.1", a.library, "Pride", "epub3"} {
		if strings.Contains(run.output, leaked) {
			t.Errorf("the decision log carries %q: %s", leaked, run.output)
		}
	}
	download := scalar[int64](t, a.db, `SELECT id FROM downloads WHERE request_id = ? AND status = 3`, a.request)
	if answer.text("download_id") != itoa(download) {
		t.Errorf("reported download %s, stored %d", answer.text("download_id"), download)
	}
	path := a.bookPath()
	stored, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(stored, a.epub) {
		t.Fatalf("library file: %v", err)
	}
	info, _ := os.Lstat(path)
	if !info.Mode().IsRegular() || info.Mode().Perm()&0o022 != 0 {
		t.Errorf("library file mode %v", info.Mode())
	}
	book := a.book
	if got := a.entries(t); !reflect.DeepEqual(got, append(append([]string{}, before.library...), "shelfarr-gutenberg/", "shelfarr-gutenberg/book-"+itoa(book)+"/", "shelfarr-gutenberg/book-"+itoa(book)+"/gutenberg-1342.epub")) {
		t.Errorf("library entries %v", got)
	}
	state := rows(t, a.db, `SELECT status, completed_at IS NOT NULL, completed_at = updated_at, attention_needed, issue_description, next_retry_at, search_claimed_at, search_generation, retry_count FROM requests WHERE id = ?`, a.request)
	if want := [][]string{{"int64:5", "int64:1", "int64:1", "int64:0", "NULL", "NULL", "NULL", "int64:1", "int64:0"}}; !reflect.DeepEqual(state, want) {
		t.Errorf("request %v", state)
	}
	results := rows(t, a.db, `SELECT guid, status, updated_at = (SELECT updated_at FROM requests WHERE id = ?) FROM search_results WHERE request_id = ? ORDER BY id`, a.request, a.request)
	for _, line := range results {
		wantStatus, moved := "int64:2", "int64:0"
		if line[0] == "string:"+bookGUID {
			wantStatus, moved = "int64:1", "int64:1"
		}
		if line[1] != wantStatus || line[2] != moved {
			t.Errorf("search result %v", line)
		}
	}
	origin := a.fake.server.URL
	title := "Pride and Prejudice - Austen, Jane [EPUB] [English]"
	downloads := rows(t, a.db, `SELECT request_id, search_result_id, name, size_bytes, status, download_type, download_path, external_id, progress, not_found_count,
		replace_library_file, configuration_failure, download_client_id, post_processing_job_id, external_id_released_at, library_replacement_state,
		COALESCE(direct_reservation_token, direct_staging_path, direct_destination_path, direct_book_path, direct_output_root, direct_content_manifest), created_at = updated_at
		FROM downloads WHERE request_id = ?`, a.request)
	wantDownload := [][]string{{"int64:" + itoa(a.request), "int64:" + itoa(a.result), "string:" + title, "NULL", "int64:3", "string:direct", "string:" + path, "NULL", "int64:0", "int64:0",
		"int64:0", "int64:0", "NULL", "NULL", "NULL", "NULL", "NULL", "int64:1"}}
	if !reflect.DeepEqual(downloads, wantDownload) {
		t.Errorf("download\n%v\nwant\n%v", downloads, wantDownload)
	}
	if got := scalar[string](t, a.db, `SELECT download_url FROM search_results WHERE id = ?`, a.result); got != origin+bookLink {
		t.Errorf("selected result links %s", got)
	}
	books := rows(t, a.db, `SELECT file_path, reference_target_roots, acquisition_reservation_token, acquisition_reservation_owner_type, acquisition_reservation_owner_id FROM books WHERE id = ?`, book)
	if want := [][]string{{"string:" + path, "NULL", "NULL", "NULL", "NULL"}}; !reflect.DeepEqual(books, want) {
		t.Errorf("book %v", books)
	}
	events := rows(t, a.db, `SELECT event_type, source, message, level, details, user_visible, download_id FROM request_events WHERE request_id = ? AND event_type <> 'attention_flagged' ORDER BY id`, a.request)
	wantEvents := [][]string{
		{"string:download_queued", "string:request", "string:Download queued from manual result selection", "int64:0", `string:{"search_result_id":` + itoa(a.result) + `,"title":"` + title + `","trigger":"manual_select"}`, "int64:0", "int64:" + itoa(download)},
		{"string:dispatch_started", "string:DownloadJob", "string:Started dispatching download to a client", "int64:0", `string:{"request_status":"downloading"}`, "int64:0", "int64:" + itoa(download)},
		{"string:completed", "string:DownloadJob", "string:Direct download completed", "int64:0", "string:{}", "int64:0", "int64:" + itoa(download)},
	}
	if !reflect.DeepEqual(events, wantEvents) {
		t.Errorf("events\n%v\nwant\n%v", events, wantEvents)
	}
	notifications := rows(t, a.db, `SELECT user_id, notification_type, title, message, read_at FROM notifications WHERE notifiable_type = 'Request' AND notifiable_id = ? AND notification_type = 'request_completed'`, a.request)
	if want := [][]string{{"int64:" + itoa(a.users["alice"]), "string:request_completed", "string:Book Ready", `string:"Pride and Prejudice" is now available for download.`, "NULL"}}; !reflect.DeepEqual(notifications, want) {
		t.Errorf("notifications %v", notifications)
	}
	activity := rows(t, a.db, `SELECT user_id, details, ip_address, controller FROM activity_logs WHERE action = 'request.completed' AND trackable_type = 'Request' AND trackable_id = ?`, a.request)
	if want := [][]string{{"int64:" + itoa(a.users["alice"]), "string:{}", "NULL", "NULL"}}; !reflect.DeepEqual(activity, want) {
		t.Errorf("activity %v", activity)
	}
	after := digests(t, a.db, acquisitionTables...)
	for table, digest := range before.tables {
		if _, written := after[table]; written && after[table] != digest {
			t.Errorf("table %s changed", table)
		}
	}
	if intents := a.intent(t); len(intents) != 0 {
		t.Errorf("an intent is left: %v", intents)
	}
	if verdict := scalar[string](t, a.db, `PRAGMA integrity_check`); verdict != "ok" {
		t.Errorf("integrity_check: %s", verdict)
	}
	if got := a.fake.requests(); !reflect.DeepEqual(got, []string{bookLink + "?"}) {
		t.Errorf("catalogue requests %v", got)
	}
	return download
}

var (
	httpBuild  sync.Once
	httpBinary string
	httpError  error
)

func goCatalogueBinary(t *testing.T) string {
	t.Helper()
	httpBuild.Do(func() {
		httpBinary = filepath.Join(buildScratch, "shelfarr-http")
		command := exec.Command("go", "build", "-trimpath", "-o", httpBinary, "./cmd/shelfarr-http")
		command.Dir = "../.."
		command.Env = append(os.Environ(), "CGO_ENABLED=0")
		if output, err := command.CombinedOutput(); err != nil {
			httpError = err
			httpBinary = string(output)
		}
	})
	if httpError != nil {
		t.Fatalf("building shelfarr-http: %v %s", httpError, httpBinary)
	}
	return httpBinary
}

type bundleCredentials struct {
	Tokens map[string]string `json:"tokens"`
}

func bearerOf(t *testing.T, bundle, label string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(bundle, "secrets", "credentials.json"))
	if err != nil {
		t.Fatal(err)
	}
	var credentials bundleCredentials
	if err := json.Unmarshal(data, &credentials); err != nil || credentials.Tokens[label] == "" {
		t.Fatalf("no %s token", label)
	}
	return credentials.Tokens[label]
}

var listeningAddress = regexp.MustCompile(`"address":"([^"]+)"`)

func (a *acquisitionSetup) deliverThroughGoCatalogue(t *testing.T, bundle string) (string, []byte) {
	t.Helper()
	runtime := t.TempDir()
	secret := make([]byte, 32)
	rand.Read(secret)
	secretFile := filepath.Join(runtime, "secret")
	if err := os.WriteFile(secretFile, []byte(hex.EncodeToString(secret)), 0o600); err != nil {
		t.Fatal(err)
	}
	media := scalar[string](t, a.db, `SELECT value FROM settings WHERE key = 'audiobook_output_path'`)
	command := exec.Command(goCatalogueBinary(t), "-experimental", "-database", a.w.database(), "-lock-file", filepath.Join(runtime, "http.lock"),
		"-listen", "127.0.0.1:0", "-library-root", a.library, "-library-root", media)
	command.Env = []string{"PATH=" + os.Getenv("PATH"), "SECRET_KEY_BASE_FILE=" + secretFile}
	stderr, err := command.StderrPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		command.Process.Signal(os.Interrupt)
		command.Wait()
	})
	address := make(chan string, 1)
	var logged bytes.Buffer
	var logMutex sync.Mutex
	go func() {
		scanner := bufio.NewScanner(stderr)
		for scanner.Scan() {
			logMutex.Lock()
			logged.WriteString(scanner.Text() + "\n")
			logMutex.Unlock()
			if match := listeningAddress.FindStringSubmatch(scanner.Text()); match != nil {
				select {
				case address <- match[1]:
				default:
				}
			}
		}
	}()
	var base string
	select {
	case found := <-address:
		base = "http://" + found
	case <-time.After(20 * time.Second):
		logMutex.Lock()
		defer logMutex.Unlock()
		t.Fatalf("shelfarr-http did not start: %s", logged.String())
	}
	token := bearerOf(t, bundle, "alice-full")
	get := func(path string) (int, []byte) {
		request, _ := http.NewRequest(http.MethodGet, base+path, nil)
		request.Header.Set("Authorization", "Bearer "+token)
		response, err := http.DefaultClient.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		body, _ := io.ReadAll(response.Body)
		return response.StatusCode, body
	}
	book := a.book
	status, body := get("/api/consumer/v1/library/" + itoa(book))
	var publication struct {
		Assets []struct {
			ID        string `json:"id"`
			Format    string `json:"format"`
			MediaType string `json:"media_type"`
			SizeBytes int64  `json:"size_bytes"`
		} `json:"assets"`
	}
	if status != 200 || json.Unmarshal(body, &publication) != nil || len(publication.Assets) != 1 {
		t.Fatalf("Go catalogue publication %d: %s", status, body)
	}
	asset := publication.Assets[0]
	if asset.Format != "epub" || asset.MediaType != epubType || asset.SizeBytes != int64(len(a.epub)) {
		t.Errorf("Go catalogue asset %+v", asset)
	}
	path := a.bookPath()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	stat, err := assetid.StatOf(info)
	if err != nil {
		t.Fatal(err)
	}
	if want := assetid.ID(assetid.Input{BookID: book, StoredPath: path, CanonicalPath: path, Stat: stat}); asset.ID != want {
		t.Errorf("asset id %s, identity of the final file %s", asset.ID, want)
	}
	status, delivered := get("/api/consumer/v1/library/" + itoa(book) + "/assets/" + asset.ID)
	if status != 200 || !bytes.Equal(delivered, a.epub) {
		t.Errorf("Go delivery %d of %d bytes", status, len(delivered))
	}
	return asset.ID, delivered
}

type downloadCase struct {
	Name       string  `json:"name"`
	Bundle     string  `json:"bundle"`
	RequestID  int64   `json:"request_id"`
	ResultID   int64   `json:"result_id"`
	BookID     int64   `json:"book_id"`
	DownloadID int64   `json:"download_id"`
	Origin     string  `json:"origin"`
	BookLink   string  `json:"book_link"`
	BookFile   string  `json:"book_file"`
	BookPath   string  `json:"book_path"`
	SHA256     string  `json:"sha256"`
	Bytes      int     `json:"bytes"`
	AssetID    string  `json:"asset_id"`
	Library    string  `json:"library"`
	Routes     []reply `json:"routes"`
}

func downloadEvidence(t *testing.T, name string) string {
	t.Helper()
	root := os.Getenv(downloadEvidenceEnvironment)
	if root == "" {
		return t.TempDir()
	}
	dir := filepath.Join(root, name)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestGutenbergDownloadPublishesOneLibraryEbook(t *testing.T) {
	for _, bundle := range []struct{ name, path string }{{"current", currentBundle}, {"upgrade", upgradeBundle}} {
		t.Run(bundle.name, func(t *testing.T) {
			evidence := downloadEvidence(t, "download-"+bundle.name)
			setup := newAcquisition(t, bundle.path, evidence)
			before := setup.freeze(t)
			snapshot(t, setup.db, filepath.Join(evidence, "before.sqlite3"))

			run := setup.download(t, plainBinary, faults{}, setup.result)
			download := setup.requireCompleted(t, run, before)
			snapshot(t, setup.db, filepath.Join(evidence, "after.sqlite3"))
			assetID, _ := setup.deliverThroughGoCatalogue(t, bundle.path)

			completed := setup.freeze(t)
			setup.fake.reset()
			repeat := setup.download(t, plainBinary, faults{}, setup.result)
			if answer := outcomeOf(t, repeat); repeat.code != 0 || answer.text("outcome") != "already_completed" || answer.text("download_id") != itoa(download) {
				t.Errorf("repeating the same result: exit %d %s", repeat.code, repeat.output)
			}
			different := setup.download(t, plainBinary, faults{}, setup.other)
			if answer := outcomeOf(t, different); different.code != 7 || answer.text("code") != "request_not_selectable" {
				t.Errorf("selecting another result of the acquired request: exit %d %s", different.code, different.output)
			}
			if len(setup.fake.requests()) != 0 {
				t.Errorf("a settled request contacted the catalogue: %v", setup.fake.requests())
			}
			setup.requireUnchanged(t, completed)

			bookFile := filepath.Join(evidence, "book.epub")
			if err := os.WriteFile(bookFile, setup.epub, 0o600); err != nil {
				t.Fatal(err)
			}
			writeJSON(t, filepath.Join(evidence, "case.json"), downloadCase{
				Name: "completed", Bundle: bundle.name, RequestID: setup.request, ResultID: setup.result, DownloadID: download,
				BookID: setup.book, Origin: setup.fake.server.URL,
				BookLink: bookLink, BookFile: bookFile, BookPath: setup.bookPath(), SHA256: digestOf(setup.epub), Bytes: len(setup.epub),
				AssetID: assetID, Library: setup.library, Routes: setup.fake.table(),
			})
		})
	}
}

func (a *acquisitionSetup) requireNothingWritten(t *testing.T, run result, before frozen, exit int, outcome, code string) {
	t.Helper()
	answer := outcomeOf(t, run)
	got := answer.text("outcome")
	if answer.name() == "rejected" || answer.name() == "refused" {
		got = answer.name()
	}
	if run.code != exit || got != outcome || answer.text("code") != code {
		t.Errorf("exit %d, want %d %s %s: %s", run.code, exit, outcome, code, run.output)
	}
	a.requireUnchanged(t, before)
}

func TestGutenbergDownloadRefusesBeforeAnyEffect(t *testing.T) {
	cases := []struct {
		name   string
		code   string
		result func(a *acquisitionSetup) int64
		change func(t *testing.T, a *acquisitionSetup)
	}{
		{"library root outside the disposable directory", "library_root_not_disposable", nil, func(t *testing.T, a *acquisitionSetup) {
			putSetting(t, a.db, "ebook_output_path", "string", scalar[string](t, a.db, `SELECT value FROM settings WHERE key = 'audiobook_output_path'`))
		}},
		{"library root is the disposable directory", "library_root_not_disposable", nil, func(t *testing.T, a *acquisitionSetup) {
			putSetting(t, a.db, "ebook_output_path", "string", a.w.dir)
		}},
		{"library root reached through a symbolic link", "library_root_not_disposable", nil, func(t *testing.T, a *acquisitionSetup) {
			if err := os.Symlink(a.library, filepath.Join(a.w.dir, "linked")); err != nil {
				t.Fatal(err)
			}
			putSetting(t, a.db, "ebook_output_path", "string", filepath.Join(a.w.dir, "linked"))
		}},
		{"library root with a trailing slash", "library_root_not_disposable", nil, func(t *testing.T, a *acquisitionSetup) {
			putSetting(t, a.db, "ebook_output_path", "string", a.library+"/")
		}},
		{"library root writable by others", "library_root_not_disposable", nil, func(t *testing.T, a *acquisitionSetup) {
			if err := os.Chmod(a.library, 0o777); err != nil {
				t.Fatal(err)
			}
		}},
		{"library root missing", "library_root_not_disposable", nil, func(t *testing.T, a *acquisitionSetup) {
			os.Remove(a.library)
			putSetting(t, a.db, "ebook_output_path", "string", filepath.Join(a.w.dir, "absent"))
		}},
		{"library root not a stored setting", "library_root_not_disposable", nil, func(t *testing.T, a *acquisitionSetup) {
			exec1(t, a.db, `DELETE FROM settings WHERE key = 'ebook_output_path'`)
		}},
		{"library scan configured", "library_scan_configured", nil, func(t *testing.T, a *acquisitionSetup) {
			putSetting(t, a.db, "audiobookshelf_url", "string", "http://127.0.0.1:9")
			putSetting(t, a.db, "audiobookshelf_api_key", "string", "synthetic")
		}},
		{"import permissions configured", "import_permissions_configured", nil, func(t *testing.T, a *acquisitionSetup) {
			putSetting(t, a.db, "library_import_file_mode", "string", "0644")
		}},
		{"automatic selection enabled", "auto_select_enabled", nil, func(t *testing.T, a *acquisitionSetup) {
			putSetting(t, a.db, "auto_select_enabled", "boolean", "true")
		}},
		{"public catalogue", "provider_not_loopback", nil, func(t *testing.T, a *acquisitionSetup) {
			putSetting(t, a.db, "gutenberg_url", "string", "https://www.gutenberg.org")
		}},
		{"deleted account", "account_unavailable", nil, func(t *testing.T, a *acquisitionSetup) {
			exec1(t, a.db, `UPDATE users SET deleted_at = ? WHERE id = ?`, seededStamp, a.users["alice"])
		}},
		{"pending request", "request_not_selectable", nil, func(t *testing.T, a *acquisitionSetup) {
			exec1(t, a.db, `UPDATE requests SET status = 0 WHERE id = ?`, a.request)
		}},
		{"live search claim", "request_not_selectable", nil, func(t *testing.T, a *acquisitionSetup) {
			exec1(t, a.db, `UPDATE requests SET search_claimed_at = ? WHERE id = ?`, seededStamp, a.request)
		}},
		{"missing result", "result_not_found", func(*acquisitionSetup) int64 { return 999999 }, nil},
		{"result of another request", "result_not_found", func(a *acquisitionSetup) int64 {
			other := a.admit(a.w.t, "Frankenstein", "Mary Shelley")
			return exec1(a.w.t, a.db, `INSERT INTO search_results (request_id, guid, title, source, status, download_url, provider_payload, created_at, updated_at)
				VALUES (?, 'gutenberg:84', 'Frankenstein', 'gutenberg', 0, ?, '{}', ?, ?)`, other, a.fake.server.URL+"/ebooks/84.epub3.images", seededStamp, seededStamp)
		}, nil},
		{"blocklisted result", "result_not_selectable", nil, func(t *testing.T, a *acquisitionSetup) {
			exec1(t, a.db, `UPDATE search_results SET blocklisted_at = ?, blocklist_reason = 'seeded' WHERE id = ?`, seededStamp, a.result)
		}},
		{"rejected result", "result_not_selectable", nil, func(t *testing.T, a *acquisitionSetup) {
			exec1(t, a.db, `UPDATE search_results SET status = 2 WHERE id = ?`, a.result)
		}},
		{"result of another source", "result_not_selectable", nil, func(t *testing.T, a *acquisitionSetup) {
			exec1(t, a.db, `UPDATE search_results SET source = 'prowlarr' WHERE id = ?`, a.result)
		}},
		{"link on another loopback origin", "result_off_origin", nil, func(t *testing.T, a *acquisitionSetup) {
			exec1(t, a.db, `UPDATE search_results SET download_url = 'http://127.0.0.2:9/ebooks/1342.epub3.images' WHERE id = ?`, a.result)
		}},
		{"link with a query", "result_off_origin", nil, func(t *testing.T, a *acquisitionSetup) {
			exec1(t, a.db, `UPDATE search_results SET download_url = ? WHERE id = ?`, a.fake.server.URL+bookLink+"?file=/etc/passwd", a.result)
		}},
		{"link escaping the catalogue path", "result_off_origin", nil, func(t *testing.T, a *acquisitionSetup) {
			exec1(t, a.db, `UPDATE search_results SET download_url = ? WHERE id = ?`, a.fake.server.URL+"/ebooks/../1342.epub", a.result)
		}},
		{"Kindle link", "result_not_epub", nil, func(t *testing.T, a *acquisitionSetup) {
			exec1(t, a.db, `UPDATE search_results SET download_url = ? WHERE id = ?`, a.fake.server.URL+"/ebooks/1342.kf8.images", a.result)
		}},
		{"PDF link", "result_not_epub", nil, func(t *testing.T, a *acquisitionSetup) {
			exec1(t, a.db, `UPDATE search_results SET download_url = ? WHERE id = ?`, a.fake.server.URL+"/ebooks/1342.epub.pdf", a.result)
		}},
		{"book already acquired", "book_acquired", nil, func(t *testing.T, a *acquisitionSetup) {
			exec1(t, a.db, `UPDATE books SET file_path = '/library/elsewhere.epub' WHERE id = ?`, a.book)
		}},
		{"book reserved by another acquisition", "book_acquired", nil, func(t *testing.T, a *acquisitionSetup) {
			exec1(t, a.db, `UPDATE books SET acquisition_reservation_token = 'seeded', acquisition_reservation_owner_type = 'Download', acquisition_reservation_owner_id = 9 WHERE id = ?`, a.book)
		}},
		{"queued download", "downloads_active", nil, func(t *testing.T, a *acquisitionSetup) {
			exec1(t, a.db, `INSERT INTO downloads (request_id, search_result_id, status, created_at, updated_at) VALUES (?, ?, 0, ?, ?)`, a.request, a.other, seededStamp, seededStamp)
		}},
		{"failed download awaiting direct recovery", "downloads_active", nil, func(t *testing.T, a *acquisitionSetup) {
			exec1(t, a.db, `INSERT INTO downloads (request_id, search_result_id, status, download_type, direct_staging_path, created_at, updated_at) VALUES (?, ?, 4, 'direct', '/staging', ?, ?)`, a.request, a.other, seededStamp, seededStamp)
		}},
	}
	for _, entry := range cases {
		t.Run(entry.name, func(t *testing.T) {
			setup := newAcquisition(t, currentBundle, "")
			chosen := setup.result
			if entry.result != nil {
				chosen = entry.result(setup)
			}
			if entry.change != nil {
				entry.change(t, setup)
			}
			before := setup.freeze(t)
			run := setup.download(t, plainBinary, faults{}, chosen)
			setup.requireNothingWritten(t, run, before, 7, "rejected", entry.code)
			if requests := setup.fake.requests(); len(requests) != 0 {
				t.Errorf("a refused selection contacted the catalogue: %v", requests)
			}
		})
	}
}

func truncatedBook(declared int, body []byte) func(http.ResponseWriter) {
	return func(writer http.ResponseWriter) {
		writer.Header().Set("Content-Type", epubType)
		writer.Header().Set("Content-Length", itoa(int64(declared)))
		writer.WriteHeader(200)
		writer.Write(body)
		if hijacker, ok := writer.(http.Hijacker); ok {
			connection, _, err := hijacker.Hijack()
			if err == nil {
				connection.Close()
			}
		}
	}
}

func TestGutenbergDownloadFailuresWriteNothing(t *testing.T) {
	plain := syntheticEPUB(t, "valid")
	compressedMimetype := func() []byte {
		var buffer bytes.Buffer
		archive := zip.NewWriter(&buffer)
		for _, name := range []string{"mimetype", "META-INF/container.xml"} {
			writer, _ := archive.Create(name)
			writer.Write([]byte(epubType))
		}
		archive.Close()
		return buffer.Bytes()
	}()
	cases := []struct {
		name    string
		code    string
		answer  reply
		options []string
	}{
		{"missing book", "provider-refused", reply{Status: 404, Body: "Not Found"}, nil},
		{"busy catalogue", "provider-busy", reply{Status: 503, Body: "busy"}, nil},
		{"redirect", "provider-refused", reply{Status: 302, Body: "http://127.0.0.1:9/elsewhere.epub"}, nil},
		{"maintenance page", "download-not-a-book", reply{Status: 200, Body: "<html><body>maintenance</body></html>", ContentType: "text/html; charset=utf-8"}, nil},
		{"JSON answer", "download-not-a-book", reply{Status: 200, Body: `{"error":"no"}`, ContentType: "application/json"}, nil},
		{"garbage labelled as EPUB", "download-invalid", reply{Status: 200, Body: "PK\x03\x04 not really a zip", ContentType: epubType}, nil},
		{"HTML labelled as EPUB", "download-invalid", reply{Status: 200, Body: "<!doctype html><title>x</title>", ContentType: epubType}, nil},
		{"ZIP that is not an EPUB", "download-invalid", reply{Status: 200, Body: string(compressedMimetype), ContentType: epubType}, nil},
		{"EPUB cut short", "download-invalid", reply{Status: 200, Body: string(plain[:len(plain)-40]), ContentType: epubType}, nil},
		{"connection closed before the announced length", "download-truncated", reply{serve: truncatedBook(len(plain), plain[:200])}, nil},
		{"announced length over the limit", "provider-too-large", reply{serve: truncatedBook(250<<20+1, nil)}, nil},
		{"body over the limit", "provider-too-large", reply{serve: func(writer http.ResponseWriter) {
			writer.Header().Set("Content-Type", epubType)
			writer.WriteHeader(200)
			chunk := make([]byte, 1<<20)
			for {
				if _, err := writer.Write(chunk); err != nil {
					return
				}
			}
		}}, []string{"--deadline", "20s"}},
		{"slow catalogue past the deadline", "download-deadline", reply{Status: 200, Body: string(plain), ContentType: epubType, delay: 3 * time.Second}, []string{"--deadline", "1s"}},
	}
	for _, entry := range cases {
		t.Run(entry.name, func(t *testing.T) {
			setup := newAcquisition(t, currentBundle, "")
			answer := entry.answer
			answer.Path = bookLink
			setup.fake.set(answer)
			before := setup.freeze(t)
			run := setup.download(t, plainBinary, faults{}, setup.result, entry.options...)
			setup.requireNothingWritten(t, run, before, 1, "failed", entry.code)
		})
	}
	t.Run("terminated while downloading", func(t *testing.T) {
		setup := newAcquisition(t, currentBundle, "")
		arrived := make(chan struct{}, 1)
		setup.fake.set(reply{Path: bookLink, Status: 200, Body: string(setup.epub), ContentType: epubType, delay: 20 * time.Second, before: func() { arrived <- struct{}{} }})
		before := setup.freeze(t)
		running := setup.start(t, plainBinary, faults{}, setup.result)
		select {
		case <-arrived:
		case <-time.After(waitLimit):
			t.Fatal("the download never reached the catalogue")
		}
		code := running.terminate()
		setup.requireNothingWritten(t, result{code: code, events: running.snapshot(), output: running.output()}, before, 1, "failed", "cancelled")
	})
}

func TestGutenbergDownloadSurvivesKillsAtEveryBoundary(t *testing.T) {
	for _, point := range []struct {
		name    string
		intent  bool
		linked  bool
		removed bool
	}{{"download.fetched", false, false, false}, {"download.intent", true, false, false}, {"download.linked", true, true, true}, {"download.before-commit", true, true, true}} {
		t.Run(point.name, func(t *testing.T) {
			var evidence string
			if point.name == "download.linked" {
				evidence = downloadEvidence(t, "download-interrupted")
			}
			setup := newAcquisition(t, currentBundle, evidence)
			before := setup.freeze(t)
			killed := setup.download(t, faultBinary, newFaults(t, map[string]string{point.name: "kill"}), setup.result)
			if killed.code != -1 {
				t.Fatalf("exit %d: %s", killed.code, killed.output)
			}
			requireSame(t, before.tables, digests(t, setup.db))
			if got := len(setup.intent(t)) == 1; got != point.intent {
				t.Errorf("intent recorded %v", got)
			}
			if _, err := os.Lstat(setup.bookPath()); (err == nil) != point.linked {
				t.Errorf("library file present %v", err == nil)
			}
			if state := stateOf(t, setup.db, setup.request); state.Status != 1 || state.Attention != 1 || state.Claimed {
				t.Errorf("an interrupted download changed the visible request: %+v", state)
			}
			if evidence != "" {
				snapshot(t, setup.db, filepath.Join(evidence, "before.sqlite3"))
			}
			setup.fake.reset()
			rerun := setup.download(t, plainBinary, faults{}, setup.result)
			recovered := 0
			for _, entry := range rerun.events {
				if entry.name() == "recovered" {
					recovered++
					if removed, _ := entry["removed"].(bool); removed != point.removed {
						t.Errorf("recovery removed %v", removed)
					}
				}
			}
			if recovered != map[bool]int{true: 1, false: 0}[point.intent] {
				t.Errorf("%d recoveries: %s", recovered, rerun.output)
			}
			download := setup.requireCompleted(t, rerun, before)
			if evidence != "" {
				snapshot(t, setup.db, filepath.Join(evidence, "after.sqlite3"))
				bookFile := filepath.Join(evidence, "book.epub")
				os.WriteFile(bookFile, setup.epub, 0o600)
				writeJSON(t, filepath.Join(evidence, "case.json"), downloadCase{
					Name: "interrupted", Bundle: "current", RequestID: setup.request, ResultID: setup.result, DownloadID: download, BookID: setup.book,
					Origin: setup.fake.server.URL, BookLink: bookLink, BookFile: bookFile, BookPath: setup.bookPath(), SHA256: digestOf(setup.epub),
					Bytes: len(setup.epub), Library: setup.library, Routes: setup.fake.table(),
				})
			}
		})
	}
	t.Run("external kill while publishing", func(t *testing.T) {
		setup := newAcquisition(t, upgradeBundle, "")
		before := setup.freeze(t)
		injected := newFaults(t, map[string]string{"download.linked": "park"})
		running := setup.start(t, faultBinary, injected, setup.result)
		injected.reached(t, "download.linked")
		if code := running.kill(); code != -1 {
			t.Fatalf("exit %d", code)
		}
		if _, err := os.Lstat(setup.bookPath()); err != nil {
			t.Fatalf("the parked publication left no file: %v", err)
		}
		requireSame(t, before.tables, digests(t, setup.db))
		setup.fake.reset()
		rerun := setup.download(t, plainBinary, faults{}, setup.result)
		setup.requireCompleted(t, rerun, before)
	})
	t.Run("a different file left at the destination is preserved", func(t *testing.T) {
		setup := newAcquisition(t, currentBundle, "")
		before := setup.freeze(t)
		if killed := setup.download(t, faultBinary, newFaults(t, map[string]string{"download.linked": "kill"}), setup.result); killed.code != -1 {
			t.Fatalf("exit %d", killed.code)
		}
		foreign := []byte("an operator's own file")
		os.Remove(setup.bookPath())
		if err := os.WriteFile(setup.bookPath(), foreign, 0o644); err != nil {
			t.Fatal(err)
		}
		rerun := setup.download(t, plainBinary, faults{}, setup.result)
		answer := outcomeOf(t, rerun)
		if rerun.code != 1 || answer.text("code") != "library-file-exists" || setup.intent(t) != nil {
			t.Errorf("exit %d: %s", rerun.code, rerun.output)
		}
		if data, _ := os.ReadFile(setup.bookPath()); !bytes.Equal(data, foreign) {
			t.Errorf("the foreign file changed")
		}
		requireSame(t, before.tables, digests(t, setup.db))
	})
}

func TestGutenbergDownloadIsOneAttemptAtATime(t *testing.T) {
	setup := newAcquisition(t, currentBundle, "")
	before := setup.freeze(t)
	injected := newFaults(t, map[string]string{"download.fetched": "park"})
	first := setup.start(t, faultBinary, injected, setup.result)
	injected.reached(t, "download.fetched")
	var group sync.WaitGroup
	answers := make([]result, 5)
	for index := range answers {
		group.Add(1)
		go func() {
			defer group.Done()
			chosen := setup.result
			if index%2 == 1 {
				chosen = setup.other
			}
			answers[index] = setup.download(t, plainBinary, faults{}, chosen)
		}()
	}
	group.Wait()
	for _, answer := range answers {
		if found := outcomeOf(t, answer); answer.code != 3 || found.name() != "refused" || found.text("code") != "acquisition_busy" {
			t.Errorf("a concurrent attempt: exit %d %s", answer.code, answer.output)
		}
	}
	if requests := setup.fake.requests(); len(requests) != 1 {
		t.Errorf("catalogue requests %v", requests)
	}
	injected.release(t, "download.fetched")
	code := first.wait()
	setup.requireCompleted(t, result{code: code, events: first.snapshot(), output: first.output()}, before)

	completed := setup.freeze(t)
	for index := range answers {
		group.Add(1)
		go func() {
			defer group.Done()
			answers[index] = setup.download(t, plainBinary, faults{}, setup.result)
		}()
	}
	group.Wait()
	for _, answer := range answers {
		found := outcomeOf(t, answer)
		if !(answer.code == 0 && found.text("outcome") == "already_completed") && !(answer.code == 3 && found.text("code") == "acquisition_busy") {
			t.Errorf("a repeated attempt: exit %d %s", answer.code, answer.output)
		}
	}
	setup.requireUnchanged(t, completed)
}

func TestGutenbergDownloadDiscardsASupersededSelection(t *testing.T) {
	cases := []struct {
		name   string
		change func(t *testing.T, a *acquisitionSetup)
	}{
		{"request searched again", func(t *testing.T, a *acquisitionSetup) {
			exec1(t, a.db, `UPDATE requests SET status = 0, search_generation = search_generation + 1, updated_at = ? WHERE id = ?`, seededStamp, a.request)
		}},
		{"request edited", func(t *testing.T, a *acquisitionSetup) {
			exec1(t, a.db, `UPDATE requests SET updated_at = ? WHERE id = ?`, seededStamp, a.request)
		}},
		{"result rejected", func(t *testing.T, a *acquisitionSetup) {
			exec1(t, a.db, `UPDATE search_results SET status = 2 WHERE id = ?`, a.result)
		}},
		{"book acquired elsewhere", func(t *testing.T, a *acquisitionSetup) {
			exec1(t, a.db, `UPDATE books SET file_path = '/library/elsewhere.epub' WHERE id = ?`, a.book)
		}},
		{"account deleted", func(t *testing.T, a *acquisitionSetup) {
			exec1(t, a.db, `UPDATE users SET deleted_at = ? WHERE id = ?`, seededStamp, a.users["alice"])
		}},
		{"library root moved", func(t *testing.T, a *acquisitionSetup) {
			if err := os.Rename(a.library, a.library+".moved"); err != nil {
				t.Fatal(err)
			}
			if err := os.Mkdir(a.library, 0o755); err != nil {
				t.Fatal(err)
			}
		}},
	}
	for _, entry := range cases {
		t.Run(entry.name, func(t *testing.T) {
			setup := newAcquisition(t, currentBundle, "")
			injected := newFaults(t, map[string]string{"download.linked": "park"})
			running := setup.start(t, faultBinary, injected, setup.result)
			injected.reached(t, "download.linked")
			entry.change(t, setup)
			changed := setup.freeze(t)
			injected.release(t, "download.linked")
			code := running.wait()
			answer := outcomeOf(t, result{events: running.snapshot(), output: running.output()})
			if code != 4 || answer.text("outcome") != "superseded" {
				t.Errorf("exit %d: %s", code, running.output())
			}
			library := []string{"shelfarr-gutenberg/"}
			if entry.name == "library root moved" {
				library = nil
			}
			setup.requireUnchanged(t, frozen{tables: changed.tables, library: library})
			if entries, _ := os.ReadDir(setup.library + ".moved"); len(entries) > 1 {
				t.Errorf("the moved root keeps %d entries", len(entries))
			}
		})
	}
	t.Run("failure inside the completion transaction", func(t *testing.T) {
		setup := newAcquisition(t, currentBundle, "")
		before := setup.freeze(t)
		run := setup.download(t, faultBinary, newFaults(t, map[string]string{"download.before-commit": "error"}), setup.result)
		if answer := outcomeOf(t, run); run.code != 1 || answer.name() != "error" {
			t.Errorf("exit %d: %s", run.code, run.output)
		}
		setup.requireUnchanged(t, frozen{tables: before.tables, library: []string{"shelfarr-gutenberg/"}})
	})
}

func TestGutenbergDownloadNeverReplacesOrEscapesTheLibrary(t *testing.T) {
	t.Run("existing file at the destination", func(t *testing.T) {
		setup := newAcquisition(t, currentBundle, "")
		if err := os.MkdirAll(filepath.Dir(setup.bookPath()), 0o755); err != nil {
			t.Fatal(err)
		}
		existing := []byte("an existing library file")
		if err := os.WriteFile(setup.bookPath(), existing, 0o644); err != nil {
			t.Fatal(err)
		}
		before := setup.freeze(t)
		run := setup.download(t, plainBinary, faults{}, setup.result)
		setup.requireNothingWritten(t, run, before, 1, "failed", "library-file-exists")
		if data, _ := os.ReadFile(setup.bookPath()); !bytes.Equal(data, existing) {
			t.Errorf("the existing file changed")
		}
	})
	t.Run("destination folder is a symbolic link out of the library", func(t *testing.T) {
		setup := newAcquisition(t, currentBundle, "")
		outside := t.TempDir()
		if err := os.Symlink(outside, filepath.Join(setup.library, "shelfarr-gutenberg")); err != nil {
			t.Fatal(err)
		}
		before := setup.freeze(t)
		run := setup.download(t, plainBinary, faults{}, setup.result)
		setup.requireNothingWritten(t, run, before, 1, "failed", "library-path-unsafe")
		if entries, _ := os.ReadDir(outside); len(entries) != 0 {
			t.Errorf("wrote %d entries outside the library", len(entries))
		}
	})
}

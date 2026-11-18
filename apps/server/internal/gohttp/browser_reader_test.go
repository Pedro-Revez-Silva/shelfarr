//go:build linux

package gohttp

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/livetest"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/webassets/webassetstest"
)

const (
	readerEpubBytes = "PK synthetic epub bytes for the browser reader"
	readerMutation  = "0d6f2f4e-1b8a-4c1e-9a77-6c1f8f3e2b10"
	readerMutation2 = "1e7a3a5f-2c9b-4d2f-8b88-7d2a9a4f3c21"
)

type readerFixture struct {
	h      *browserHarness
	alice  *browserClient
	token  string
	epub   string
	pdf    string
	tracks []string
}

type readerEnvelope struct {
	Account     string `json:"account"`
	Publication struct {
		BookType     string   `json:"book_type"`
		OtherFormats []string `json:"other_formats"`
		Progress     any      `json:"progress"`
		Assets       []struct {
			ID        string `json:"id"`
			Filename  string `json:"filename"`
			Format    string `json:"format"`
			MediaType string `json:"media_type"`
			SizeBytes int64  `json:"size_bytes"`
			Position  int    `json:"position"`
			URL       string `json:"url"`
		} `json:"assets"`
	} `json:"publication"`
}

const (
	expectedReaderPolicy = "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline' blob:; font-src 'self' blob: data:; img-src 'self' https: blob: data:; media-src 'self'; connect-src 'self'; frame-src 'self'; manifest-src 'none'; form-action 'none'; base-uri 'self'; frame-ancestors 'self'; object-src 'none'"
	expectedMediaPolicy  = "default-src 'none'; sandbox; frame-ancestors 'none'; form-action 'none'; base-uri 'none'"
)

func newReaderFixture(t *testing.T) *readerFixture {
	return newReaderFixtureWith(t, true)
}

func newReaderFixtureWith(t *testing.T, engine bool) *readerFixture {
	t.Helper()
	directory := t.TempDir()
	if engine {
		webassetstest.WriteWithReaderEngine(t, directory)
	} else {
		webassetstest.Write(t, directory)
	}
	h := newBrowserHarness(t, func(config *Config) { config.WebAssetsDir = directory })
	folder := filepath.Join(h.root, "Mixed Book")
	h.file("Mixed Book/Mixed Book.epub", readerEpubBytes)
	h.file("Mixed Book/Mixed Book.pdf", "%PDF-1.4\n"+strings.Repeat("x", 600))
	h.addBook(7, "Mixed Book", store.BookTypeEbook, folder)
	h.file("Spoken/Part 1.wav", "RIFF one")
	h.file("Spoken/Part 2.wav", "RIFF two")
	h.addBook(8, "Spoken", store.BookTypeAudiobook, filepath.Join(h.root, "Spoken"))
	alice := h.client()
	token := alice.signIn("alice", alicePassword)
	fixture := &readerFixture{h: h, alice: alice, token: token}
	if !engine {
		return fixture
	}
	ebook := fixture.reader(t, alice, "7")
	for _, asset := range ebook.Publication.Assets {
		if asset.Format == "epub" {
			fixture.epub = asset.ID
		}
	}
	audio := fixture.reader(t, alice, "8")
	for _, asset := range audio.Publication.Assets {
		fixture.tracks = append(fixture.tracks, asset.ID)
	}
	native := h.do(http.MethodGet, "/api/consumer/v1/library/7", map[string]string{"Authorization": "Bearer " + rawToken, "X-Shelfarr-Reader-Formats": "epub,pdf"})
	var listed struct {
		Assets []struct {
			ID     string `json:"id"`
			Format string `json:"format"`
		} `json:"assets"`
	}
	if err := json.Unmarshal(native.Body.Bytes(), &listed); err != nil {
		t.Fatal(err)
	}
	for _, asset := range listed.Assets {
		if asset.Format == "pdf" {
			fixture.pdf = asset.ID
		}
	}
	if fixture.epub == "" || fixture.pdf == "" || len(fixture.tracks) != 2 {
		t.Fatalf("fixture assets missing: %+v", fixture)
	}
	return fixture
}

func (f *readerFixture) reader(t *testing.T, client *browserClient, id string) readerEnvelope {
	t.Helper()
	recorder := client.get("/preview/api/v1/library/" + id + "/reader")
	if recorder.Code != http.StatusOK || recorder.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatalf("reader %s: %d %s", id, recorder.Code, recorder.Body.String())
	}
	var envelope readerEnvelope
	if err := json.Unmarshal(recorder.Body.Bytes(), &envelope); err != nil {
		t.Fatal(err)
	}
	return envelope
}

func (f *readerFixture) put(client *browserClient, token, id, body string) *httptest.ResponseRecorder {
	return client.send(http.MethodPut, "/preview/api/v1/library/"+id+"/progress", body, map[string]string{"X-Shelfarr-Account": client.account, "Origin": browserOrigin, "X-CSRF-Token": token})
}

func (f *readerFixture) epubPlace(expected int, mutation, observed string) string {
	return `{"asset_id":"` + f.epub + `","locator":{"href":"OEBPS/two.xhtml","type":"application/xhtml+xml","locations":{"progression":0.25,"totalProgression":0.5,"cfi":"epubcfi(/6/4!/4/2/1:0)"}},"expected_version":` + jsonInt(expected) + `,"client_mutation_id":"` + mutation + `","observed_at":"` + observed + `"}`
}

func jsonInt(value int) string {
	encoded, _ := json.Marshal(value)
	return string(encoded)
}

func progressRows(t *testing.T, h *browserHarness) [][]any {
	t.Helper()
	return livetest.Query(t, h.path, `SELECT version, client_mutation_id, observed_at FROM consumer_progresses ORDER BY id`)
}

func TestTheReaderDescribesOnlyBrowserReadableFilesWithAccountBoundMediaAddresses(t *testing.T) {
	f := newReaderFixture(t)
	ebook := f.reader(t, f.alice, "7")
	if ebook.Account != "1" || ebook.Publication.BookType != "ebook" || len(ebook.Publication.Assets) != 1 || ebook.Publication.Progress != nil {
		t.Fatalf("ebook reader: %+v", ebook)
	}
	asset := ebook.Publication.Assets[0]
	if asset.Format != "epub" || asset.MediaType != "application/epub+zip" || asset.URL != "/preview/api/v1/accounts/1/library/7/assets/"+asset.ID || asset.SizeBytes != int64(len(readerEpubBytes)) {
		t.Errorf("epub asset: %+v", asset)
	}
	if strings.Join(ebook.Publication.OtherFormats, ",") != "pdf" {
		t.Errorf("the PDF must be reported as not readable here: %v", ebook.Publication.OtherFormats)
	}
	audio := f.reader(t, f.alice, "8")
	if audio.Publication.BookType != "audiobook" || len(audio.Publication.Assets) != 2 || audio.Publication.Assets[0].Filename != "Part 1.wav" || audio.Publication.Assets[1].Position != 1 || len(audio.Publication.OtherFormats) != 0 {
		t.Errorf("audio reader: %+v", audio.Publication)
	}
	if rows := progressRows(t, f.h); len(rows) != 0 {
		t.Errorf("opening the reader wrote %v", rows)
	}
	for name, headers := range map[string]map[string]string{"no account": {}, "another account": {"X-Shelfarr-Account": "2"}} {
		recorder := f.alice.send(http.MethodGet, "/preview/api/v1/library/7/reader", "", headers)
		if recorder.Code != http.StatusUnauthorized || decoded(t, recorder)["error"] != "account_changed" {
			t.Errorf("%s: %d %s", name, recorder.Code, recorder.Body.String())
		}
	}
	signedOut := f.h.client()
	if recorder := signedOut.send(http.MethodGet, "/preview/api/v1/library/7/reader", "", map[string]string{"X-Shelfarr-Account": "1", "Authorization": "Bearer " + rawToken}); recorder.Code != http.StatusUnauthorized || decoded(t, recorder)["error"] != "signed_out" {
		t.Errorf("a bearer credential must not open the browser reader: %d %s", recorder.Code, recorder.Body.String())
	}
	if recorder := f.alice.get("/preview/api/v1/library/999/reader"); recorder.Code != http.StatusNotFound {
		t.Errorf("unknown book: %d", recorder.Code)
	}
}

func TestBrowserProgressUsesTheSameCompareAndSetRowsAsTheNativeAPI(t *testing.T) {
	f := newReaderFixture(t)
	path := "/preview/api/v1/library/7/progress"
	if recorder := f.alice.get(path); recorder.Code != http.StatusOK || recorder.Body.String() != `{"account":"1","progress":null}` {
		t.Fatalf("empty progress: %d %s", recorder.Code, recorder.Body.String())
	}
	first := f.put(f.alice, f.token, "7", f.epubPlace(0, readerMutation, "2026-11-15T11:59:00.250Z"))
	body := decoded(t, first)
	saved, _ := body["progress"].(map[string]any)
	if first.Code != http.StatusOK || body["account"] != "1" || saved["version"] != float64(1) || saved["observed_at"] != "2026-11-15T11:59:00.250Z" || saved["client_mutation_id"] != readerMutation {
		t.Fatalf("first save: %d %s", first.Code, first.Body.String())
	}
	replay := f.put(f.alice, f.token, "7", f.epubPlace(5, readerMutation, "2026-11-15T11:59:00.250Z"))
	if replay.Code != http.StatusOK || replay.Body.String() != first.Body.String() {
		t.Errorf("an identical retry must return the stored row unchanged: %d %s", replay.Code, replay.Body.String())
	}
	stale := f.put(f.alice, f.token, "7", f.epubPlace(0, readerMutation2, "2026-11-15T11:59:30.000Z"))
	conflict := decoded(t, stale)
	current, _ := conflict["progress"].(map[string]any)
	if stale.Code != http.StatusConflict || conflict["error"] != "progress_conflict" || conflict["account"] != "1" || current["version"] != float64(1) {
		t.Errorf("a stale version must be a conflict with the current place: %d %s", stale.Code, stale.Body.String())
	}
	older := f.put(f.alice, f.token, "7", f.epubPlace(1, readerMutation2, "2026-11-15T11:58:00.000Z"))
	if older.Code != http.StatusConflict {
		t.Errorf("an older activity time must not replace a later place: %d %s", older.Code, older.Body.String())
	}
	if recorder := f.alice.get(path); recorder.Code != http.StatusOK || !strings.Contains(recorder.Body.String(), `"version":1`) || !strings.Contains(recorder.Body.String(), `"cfi":"epubcfi(/6/4!/4/2/1:0)"`) {
		t.Errorf("stored progress: %s", recorder.Body.String())
	}
	rows := progressRows(t, f.h)
	if fmt.Sprint(rows) != "[[1 "+readerMutation+" 2026-11-15 11:59:00.25 +0000 UTC]]" {
		t.Errorf("rows: %v", rows)
	}
	native := f.h.do(http.MethodGet, "/api/consumer/v1/library/7/progress", map[string]string{"Authorization": "Bearer " + rawToken})
	if native.Code != http.StatusOK || !strings.Contains(native.Body.String(), `"client_mutation_id":"`+readerMutation+`"`) {
		t.Errorf("the native API must read the place the browser saved: %d %s", native.Code, native.Body.String())
	}
	states := livetest.Query(t, f.h.path, `SELECT COUNT(*) FROM consumer_reading_states`)
	if states[0][0] != int64(0) {
		t.Errorf("saving a place must not choose a reading status: %v", states)
	}
}

func TestBrowserProgressWritesNeedTheOriginTheTokenAndTheAccount(t *testing.T) {
	f := newReaderFixture(t)
	body := f.epubPlace(0, readerMutation, "2026-11-15T11:59:00.250Z")
	path := "/preview/api/v1/library/7/progress"
	cases := map[string]map[string]string{
		"no token":      {"X-Shelfarr-Account": "1", "Origin": browserOrigin},
		"other origin":  {"X-Shelfarr-Account": "1", "Origin": "http://evil.test", "X-CSRF-Token": f.token},
		"cross site":    {"X-Shelfarr-Account": "1", "Origin": browserOrigin, "X-CSRF-Token": f.token, "Sec-Fetch-Site": "cross-site"},
		"wrong account": {"X-Shelfarr-Account": "2", "Origin": browserOrigin, "X-CSRF-Token": f.token},
		"no account":    {"Origin": browserOrigin, "X-CSRF-Token": f.token},
	}
	for name, headers := range cases {
		recorder := f.alice.send(http.MethodPut, path, body, headers)
		if recorder.Code != http.StatusUnprocessableEntity && recorder.Code != http.StatusUnauthorized {
			t.Errorf("%s: %d %s", name, recorder.Code, recorder.Body.String())
		}
	}
	bearer := f.h.send(http.MethodPut, path, map[string]string{"Authorization": "Bearer " + rawToken, "Content-Type": "application/json", "X-Shelfarr-Account": "1", "Origin": browserOrigin}, body)
	if bearer.Code != http.StatusUnauthorized || decoded(t, bearer)["error"] != "signed_out" {
		t.Errorf("a bearer credential must not write browser progress: %d %s", bearer.Code, bearer.Body.String())
	}
	cookie := "session_id=" + f.alice.cookies["session_id"]
	native := f.h.send(http.MethodPut, "/api/consumer/v1/library/7/progress", map[string]string{"Cookie": cookie, "Content-Type": "application/json"}, body)
	if native.Code != http.StatusUnauthorized {
		t.Errorf("a session cookie must not write native progress: %d %s", native.Code, native.Body.String())
	}
	if rows := progressRows(t, f.h); len(rows) != 0 {
		t.Errorf("refused writes stored %v", rows)
	}
}

func TestBrowserMediaIsBoundToTheAccountInItsAddressAndNeverRedirects(t *testing.T) {
	f := newReaderFixture(t)
	address := "/preview/api/v1/accounts/1/library/7/assets/" + f.epub
	full := f.alice.send(http.MethodGet, address, "", map[string]string{"Sec-Fetch-Site": "same-origin"})
	header := full.Header()
	if full.Code != http.StatusOK || full.Body.String() != readerEpubBytes {
		t.Fatalf("media: %d %q", full.Code, full.Body.String())
	}
	want := map[string]string{
		"Content-Type": "application/epub+zip", "Cache-Control": "private, no-store", "Cross-Origin-Resource-Policy": "same-origin", "X-Content-Type-Options": "nosniff",
		"Accept-Ranges": "bytes", "ETag": `"` + f.epub + `"`, "Content-Security-Policy": expectedMediaPolicy, "Referrer-Policy": "no-referrer",
	}
	for name, value := range want {
		if header.Get(name) != value {
			t.Errorf("%s = %q, want %q", name, header.Get(name), value)
		}
	}
	partial := f.alice.send(http.MethodGet, address, "", map[string]string{"Range": "bytes=0-1"})
	if partial.Code != http.StatusPartialContent || partial.Body.String() != "PK" || partial.Header().Get("Content-Range") != "bytes 0-1/"+jsonInt(len(readerEpubBytes)) {
		t.Errorf("range: %d %q %v", partial.Code, partial.Body.String(), partial.Header())
	}
	track := f.alice.send(http.MethodHead, "/preview/api/v1/accounts/1/library/8/assets/"+f.tracks[1], "", nil)
	if track.Code != http.StatusOK || track.Header().Get("Content-Type") != "audio/wav" || track.Body.Len() != 0 {
		t.Errorf("audio head: %d %v", track.Code, track.Header())
	}
	refusals := []struct {
		name    string
		client  *browserClient
		path    string
		headers map[string]string
		status  int
		code    string
	}{
		{"another account in the address", f.alice, "/preview/api/v1/accounts/2/library/7/assets/" + f.epub, nil, http.StatusUnauthorized, "account_changed"},
		{"signed out", f.h.client(), address, nil, http.StatusUnauthorized, "signed_out"},
		{"a bearer credential", f.h.client(), address, map[string]string{"Authorization": "Bearer " + rawToken}, http.StatusUnauthorized, "signed_out"},
		{"cross site before authentication", f.h.client(), address, map[string]string{"Sec-Fetch-Site": "cross-site"}, http.StatusForbidden, "cross_site_refused"},
		{"same site", f.alice, address, map[string]string{"Sec-Fetch-Site": "same-site"}, http.StatusForbidden, "cross_site_refused"},
		{"a PDF is not read in the browser", f.alice, "/preview/api/v1/accounts/1/library/7/assets/" + f.pdf, nil, http.StatusGone, "asset_unavailable"},
		{"a track of another book", f.alice, "/preview/api/v1/accounts/1/library/7/assets/" + f.tracks[0], nil, http.StatusGone, "asset_unavailable"},
	}
	for _, refusal := range refusals {
		recorder := refusal.client.send(http.MethodGet, refusal.path, "", refusal.headers)
		if recorder.Code != refusal.status || recorder.Header().Get("Location") != "" || recorder.Header().Get("Content-Type") != "application/json; charset=utf-8" || decoded(t, recorder)["error"] != refusal.code {
			t.Errorf("%s: %d %v %s", refusal.name, recorder.Code, recorder.Header(), recorder.Body.String())
		}
		if recorder.Header().Get("Cache-Control") != "private, no-store" || recorder.Header().Get("Cross-Origin-Resource-Policy") != "same-origin" {
			t.Errorf("%s: refusal headers %v", refusal.name, recorder.Header())
		}
	}
	if recorder := f.alice.send(http.MethodPost, address, "", nil); recorder.Code != http.StatusMethodNotAllowed || recorder.Header().Get("Allow") != "GET, HEAD" || recorder.Header().Get("Cache-Control") != "private, no-store" || recorder.Header().Get("Cross-Origin-Resource-Policy") != "same-origin" {
		t.Errorf("post: %d %v", recorder.Code, recorder.Header())
	}
	bob := f.h.client()
	bob.signIn("bob", bobPassword)
	if recorder := bob.send(http.MethodGet, address, "", nil); recorder.Code != http.StatusUnauthorized || decoded(t, recorder)["error"] != "account_changed" {
		t.Errorf("an old tab's address must not serve another signed-in account: %d %s", recorder.Code, recorder.Body.String())
	}
	native := f.h.send(http.MethodGet, "/api/consumer/v1/library/7/assets/"+f.epub, map[string]string{"Cookie": "session_id=" + f.alice.cookies["session_id"]}, "")
	if native.Code != http.StatusUnauthorized {
		t.Errorf("a session cookie must not fetch native asset bytes: %d", native.Code)
	}
}

func TestTheReaderShellHasItsOwnScopedPolicyAndExistsOnlyWithAReaderEngine(t *testing.T) {
	directory := t.TempDir()
	listed := webassetstest.WriteWithReaderEngine(t, directory)
	h := newBrowserHarness(t, func(config *Config) { config.WebAssetsDir = directory })
	client := h.client()
	recorder := client.send(http.MethodGet, "/preview/library/7/read", "", nil)
	if recorder.Code != http.StatusOK || recorder.Header().Get("Content-Security-Policy") != expectedReaderPolicy || recorder.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatalf("reader shell: %d %v", recorder.Code, recorder.Header())
	}
	boot := regexp.MustCompile(`<script type="application/json" id="shelfarr-boot">(.*)</script>`).FindStringSubmatch(recorder.Body.String())
	var decodedBoot map[string]any
	if boot == nil || json.Unmarshal([]byte(boot[1]), &decodedBoot) != nil || fmt.Sprint(decodedBoot) != fmt.Sprint(map[string]any{"version": float64(1), "runtime": "go", "view": "reader", "mount": "/preview", "api": "/preview/api/v1", "reader_engine": "/preview/assets/" + listed.Entry.ReaderEngine}) {
		t.Errorf("reader boot: %v", boot)
	}
	if engine := client.send(http.MethodGet, "/preview/assets/"+listed.Entry.ReaderEngine, "", nil); engine.Code != http.StatusOK || engine.Header().Get("Content-Type") != "text/javascript; charset=utf-8" {
		t.Errorf("engine: %d %v", engine.Code, engine.Header())
	}
	library := client.send(http.MethodGet, "/preview/library/7", "", nil)
	if library.Header().Get("Content-Security-Policy") != webContentPolicy || strings.Contains(library.Body.String(), "reader_engine") {
		t.Errorf("the Library policy and boot must stay unchanged: %v", library.Header())
	}
	for _, path := range []string{"/preview/library/7/read/", "/preview/library/0/read", "/preview/library/7/reader", "/preview/library/7/read/extra"} {
		if recorder := client.send(http.MethodGet, path, "", nil); recorder.Code != http.StatusNotFound || strings.Contains(recorder.Body.String(), "<html") {
			t.Errorf("%s: %d", path, recorder.Code)
		}
	}
	if recorder := client.send(http.MethodPost, "/preview/library/7/read", "", nil); recorder.Code != http.StatusMethodNotAllowed {
		t.Errorf("post: %d", recorder.Code)
	}
	plain, _ := webHarness(t, nil)
	if recorder := plain.client().send(http.MethodGet, "/preview/library/7/read", "", nil); recorder.Code != http.StatusNotFound || strings.Contains(recorder.Body.String(), "<html") {
		t.Errorf("without a reader engine the reader must not exist: %d", recorder.Code)
	}
	off := newBrowserHarness(t, func(config *Config) { config.WebAssetsDir = directory; config.PreviewUserIDs = nil })
	if recorder := off.client().send(http.MethodGet, "/preview/library/7/read", "", nil); recorder.Code != http.StatusNotFound {
		t.Errorf("default-off: %d", recorder.Code)
	}
}

func TestTheReaderAPIsExistOnlyWhileAReaderBundleIsInstalled(t *testing.T) {
	f := newReaderFixtureWith(t, false)
	if recorder := f.alice.get("/preview/api/v1/library/7"); recorder.Code != http.StatusOK {
		t.Fatalf("the preview JSON must stay available without a reader: %d", recorder.Code)
	}
	address := "/preview/api/v1/accounts/1/library/7/assets/" + strings.Repeat("a", 64)
	for _, request := range []struct{ method, path string }{
		{http.MethodGet, "/preview/api/v1/library/7/reader"},
		{http.MethodGet, "/preview/api/v1/library/7/progress"},
		{http.MethodPut, "/preview/api/v1/library/7/progress"},
		{http.MethodGet, address},
		{http.MethodHead, address},
	} {
		recorder := f.alice.send(request.method, request.path, `{}`, map[string]string{"X-Shelfarr-Account": "1", "Origin": browserOrigin, "X-CSRF-Token": f.token})
		if recorder.Code != http.StatusNotFound || recorder.Header().Get("Cache-Control") != "private, no-store" {
			t.Errorf("%s %s without a reader bundle: %d %v", request.method, request.path, recorder.Code, recorder.Header())
		}
	}
	if rows := progressRows(t, f.h); len(rows) != 0 {
		t.Errorf("a refused write stored %v", rows)
	}
}

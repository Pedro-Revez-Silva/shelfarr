//go:build linux

package gohttp

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/account"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/library"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/livetest"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
)

const (
	progressToken  = "progress-writer-bearer-token"
	readOnlyToken  = "read-only-bearer-token"
	writeOnlyToken = "write-only-bearer-token"
	otherToken     = "second-account-bearer-token"
	mutationOne    = "6f1c8d2e-3b4a-4c5d-8e9f-0a1b2c3d4e5f"
	mutationTwo    = "7a2d9e3f-4c5b-4d6e-9fa0-1b2c3d4e5f60"
	mutationThree  = "8b3eaf40-5d6c-4e7f-a0b1-2c3d4e5f6071"
)

func (h *harness) send(method, target string, headers map[string]string, body string) *httptest.ResponseRecorder {
	h.t.Helper()
	request := httptest.NewRequest(method, target, strings.NewReader(body))
	for name, value := range headers {
		request.Header.Set(name, value)
	}
	recorder := httptest.NewRecorder()
	h.app.ServeHTTP(recorder, request)
	return recorder
}

func jsonHeaders(token string) map[string]string {
	return map[string]string{"Authorization": "Bearer " + token, "Content-Type": "application/json"}
}

func (h *harness) writer(extra func(*Config)) *harness {
	h.t.Helper()
	livetest.Exec(h.t, h.path, `PRAGMA journal_mode=WAL`)
	livetest.Exec(h.t, h.path, `INSERT INTO users (id, username, name) VALUES (2, 'bob', 'Bob')`)
	for _, token := range []struct {
		id     int
		user   int
		raw    string
		scopes string
	}{{2, 1, progressToken, `["library:read","progress:write"]`}, {3, 1, readOnlyToken, `["library:read"]`}, {4, 1, writeOnlyToken, `["progress:write"]`}, {5, 2, otherToken, `["library:read","progress:write"]`}} {
		livetest.Exec(h.t, h.path, `INSERT INTO api_tokens (id, user_id, token_digest, scopes) VALUES (?, ?, ?, ?)`, token.id, token.user, account.TokenDigest(token.raw), token.scopes)
	}
	return h
}

type shelf struct {
	h       *harness
	epub    int
	audio   int
	epubID  string
	audioID string
}

func (h *harness) shelf() shelf {
	h.t.Helper()
	h.writer(nil)
	h.addBook(1, "Generated Book", store.BookTypeEbook, h.file("Book.epub", "an epub"))
	h.addBook(2, "Generated Listen", store.BookTypeAudiobook, h.file("Listen.mp3", "an audio stream"))
	lib := shelf{h: h, epub: 1, audio: 2}
	lib.epubID, lib.audioID = h.assetOf(1), h.assetOf(2)
	return lib
}

func (h *harness) assetOf(book int) string {
	h.t.Helper()
	recorder := h.do(http.MethodGet, fmt.Sprintf("/api/consumer/v1/library/%d", book), jsonHeaders(progressToken))
	var publication struct {
		Assets []struct {
			ID string `json:"id"`
		} `json:"assets"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &publication); err != nil || len(publication.Assets) != 1 {
		h.t.Fatalf("%d %s", recorder.Code, recorder.Body.String())
	}
	return publication.Assets[0].ID
}

func (l shelf) audioBody(mutation string, version int, seconds float64, extra string) string {
	return fmt.Sprintf(`{"asset_id":"%s","expected_version":%d,"client_mutation_id":"%s","position_seconds":%v%s}`, l.audioID, version, mutation, seconds, extra)
}

func (l shelf) epubBody(mutation string, version int, locator, extra string) string {
	return fmt.Sprintf(`{"asset_id":"%s","expected_version":%d,"client_mutation_id":"%s","locator":%s%s}`, l.epubID, version, mutation, locator, extra)
}

func (l shelf) put(book int, token, body string) *httptest.ResponseRecorder {
	return l.h.send(http.MethodPut, fmt.Sprintf("/api/consumer/v1/library/%d/progress", book), jsonHeaders(token), body)
}

func (l shelf) get(book int, token string) map[string]any {
	l.h.t.Helper()
	recorder := l.h.do(http.MethodGet, fmt.Sprintf("/api/consumer/v1/library/%d/progress", book), jsonHeaders(token))
	return decodeObject(l.h.t, recorder, http.StatusOK)
}

func decodeObject(t *testing.T, recorder *httptest.ResponseRecorder, status int) map[string]any {
	t.Helper()
	var parsed map[string]any
	if recorder.Code != status || json.Unmarshal(recorder.Body.Bytes(), &parsed) != nil {
		t.Fatalf("status %d (want %d): %s", recorder.Code, status, recorder.Body.String())
	}
	return parsed
}

func TestAudioCheckpointsRoundTripThroughTheRealHandlerAndAnotherAccountSeesNothing(t *testing.T) {
	lib := newHarness(t, nil).shelf()
	if got := lib.get(2, progressToken); got["progress"] != nil {
		t.Fatalf("%v", got)
	}
	written := decodeObject(t, lib.put(2, progressToken, lib.audioBody(mutationOne, 0, 17.5, `,"observed_at":"2026-11-07T10:15:30.123456+01:00"`)), http.StatusOK)["progress"].(map[string]any)
	if written["position_seconds"] != 17.5 || written["version"] != 1.0 || written["observed_at"] != "2026-11-07T09:15:30.123Z" || written["client_mutation_id"] != mutationOne || written["asset_id"] != lib.audioID || written["locator"] != nil {
		t.Fatalf("%v", written)
	}
	if written["updated_at"] == written["observed_at"] {
		t.Fatal("the device activity time was replaced by the receipt time")
	}
	if got := lib.get(2, progressToken)["progress"]; fmt.Sprint(got) != fmt.Sprint(written) {
		t.Fatalf("a read differs from the write response:\n%v\n%v", got, written)
	}
	if got := lib.get(2, otherToken); got["progress"] != nil {
		t.Fatalf("another account read a place: %v", got)
	}
	publication := decodeObject(t, lib.h.do(http.MethodGet, "/api/consumer/v1/library/2", jsonHeaders(progressToken)), http.StatusOK)
	if fmt.Sprint(publication["progress"]) != fmt.Sprint(written) || publication["reading_status"] != "in_progress" {
		t.Fatalf("%v", publication)
	}
	if decodeObject(t, lib.h.do(http.MethodGet, "/api/consumer/v1/library/2", jsonHeaders(otherToken)), http.StatusOK)["reading_status"] != "unread" {
		t.Fatal("status leaked between accounts")
	}
}

func TestEbookLocatorsRoundTripWithEveryAcceptedFieldIncludingReadAlong(t *testing.T) {
	lib := newHarness(t, nil).shelf()
	locator := `{"href":"OEBPS/chapter.xhtml","type":"application/xhtml+xml","title":"One","locations":{"progression":0.3,"totalProgression":0.2,"position":4,"readAlong":{"generation":"` + strings.Repeat("c", 64) + `","audio":2,"offset_ms":1500},"cfi":"/2/4"},"text":{"highlight":"x"},"vendor":[1,null]}`
	written := decodeObject(t, lib.put(1, progressToken, lib.epubBody(mutationOne, 0, locator, "")), http.StatusOK)["progress"].(map[string]any)
	var want any
	json.Unmarshal([]byte(locator), &want)
	if fmt.Sprint(written["locator"]) != fmt.Sprint(want) || written["position_seconds"] != nil || written["asset_id"] != lib.epubID {
		t.Fatalf("%v", written)
	}
	if got := lib.get(1, progressToken)["progress"]; fmt.Sprint(got) != fmt.Sprint(written) {
		t.Fatalf("%v", got)
	}
}

func TestHeadReadsAndNeverWrites(t *testing.T) {
	lib := newHarness(t, nil).shelf()
	lib.put(2, progressToken, lib.audioBody(mutationOne, 0, 5, ""))
	recorder := lib.h.send(http.MethodHead, "/api/consumer/v1/library/2/progress", jsonHeaders(progressToken), lib.audioBody(mutationTwo, 1, 99, ""))
	if recorder.Code != http.StatusOK || recorder.Header().Get("Content-Length") == "" {
		t.Fatalf("%d %q", recorder.Code, recorder.Body.String())
	}
	if rows := livetest.Query(t, lib.h.path, `SELECT version, position_seconds FROM consumer_progresses`); fmt.Sprint(rows) != "[[1 5]]" {
		t.Fatalf("%v", rows)
	}
}

func TestEveryProgressAndStatusAnswerCarriesTheNativeCacheAndReferrerHeaders(t *testing.T) {
	lib := newHarness(t, nil).shelf()
	for _, recorder := range []*httptest.ResponseRecorder{
		lib.h.do(http.MethodGet, "/api/consumer/v1/library/2/progress", jsonHeaders(progressToken)),
		lib.put(2, progressToken, lib.audioBody(mutationOne, 0, 5, "")),
		lib.put(2, progressToken, lib.audioBody(mutationTwo, 0, 6, "")),
		lib.put(2, progressToken, "{"),
		lib.put(2, readOnlyToken, lib.audioBody(mutationThree, 0, 5, "")),
		lib.h.send(http.MethodPut, "/api/consumer/v1/library/2/reading_status", jsonHeaders(progressToken), `{"status":"finished"}`),
		lib.h.send(http.MethodPut, "/api/consumer/v1/library/2/reading_status", jsonHeaders(progressToken), `{"status":"x"}`),
		lib.h.do(http.MethodGet, "/api/consumer/v1/library/2/progress", map[string]string{}),
	} {
		if recorder.Header().Get("Cache-Control") != "private, no-store" || recorder.Header().Get("Referrer-Policy") != "no-referrer" {
			t.Errorf("%d: %v", recorder.Code, recorder.Header())
		}
		if recorder.Code != http.StatusUnauthorized && !strings.HasPrefix(recorder.Header().Get("Content-Type"), "application/json") {
			t.Errorf("%d: %q", recorder.Code, recorder.Header().Get("Content-Type"))
		}
	}
}

func TestScopesAreExactAndAReadOnlyCredentialCannotWrite(t *testing.T) {
	lib := newHarness(t, nil).shelf()
	cases := []struct {
		name, method, path, token string
		status                    int
		required                  string
	}{
		{"read progress needs library:read", "GET", "/library/2/progress", writeOnlyToken, 403, "library:read"},
		{"head progress needs library:read", "HEAD", "/library/2/progress", writeOnlyToken, 403, "library:read"},
		{"write progress needs progress:write", "PUT", "/library/2/progress", readOnlyToken, 403, "progress:write"},
		{"write status needs progress:write", "PUT", "/library/2/reading_status", readOnlyToken, 403, "progress:write"},
		{"write status does not need library:read", "PUT", "/library/2/reading_status", writeOnlyToken, 200, ""},
		{"read progress with library:read", "GET", "/library/2/progress", readOnlyToken, 200, ""},
	}
	for _, c := range cases {
		recorder := lib.h.send(c.method, "/api/consumer/v1"+c.path, jsonHeaders(c.token), `{"status":"finished"}`)
		if recorder.Code != c.status {
			t.Errorf("%s: %d %s", c.name, recorder.Code, recorder.Body.String())
			continue
		}
		if c.required != "" && (c.method != "HEAD" && !strings.Contains(recorder.Body.String(), fmt.Sprintf(`"required_scope":"%s"`, c.required)) || !strings.Contains(recorder.Body.String(), "insufficient_scope") && c.method != "HEAD") {
			t.Errorf("%s: %s", c.name, recorder.Body.String())
		}
	}
	if rows := livetest.Query(t, lib.h.path, `SELECT COUNT(*) FROM consumer_progresses`); rows[0][0] != int64(0) {
		t.Fatal("a refused write stored a place")
	}
	if rows := livetest.Query(t, lib.h.path, `SELECT COUNT(*) FROM consumer_reading_states WHERE user_id = 1`); rows[0][0] != int64(1) {
		t.Fatal("exactly the one permitted status write must exist")
	}
}

func TestAnAdministratorScopeCannotBeGrantedByATokenOfAnOrdinaryAccount(t *testing.T) {
	lib := newHarness(t, nil).shelf()
	livetest.Exec(t, lib.h.path, `INSERT INTO api_tokens (id, user_id, token_digest, scopes) VALUES (9, 1, ?, '["requests:admin","users:write","progress:write"]')`, account.TokenDigest("broad-token"))
	recorder := lib.h.send(http.MethodPut, "/api/consumer/v1/library/2/reading_status", jsonHeaders("broad-token"), `{"status":"finished"}`)
	if recorder.Code != http.StatusOK {
		t.Fatalf("%d %s", recorder.Code, recorder.Body.String())
	}
}

func TestAuthenticationFailuresAreEmptyAndNeverTouchProgress(t *testing.T) {
	lib := newHarness(t, nil).shelf()
	for name, headers := range map[string]map[string]string{
		"no header": {"Content-Type": "application/json"}, "wrong token": jsonHeaders("nope"), "basic": {"Authorization": "Basic YWxpY2U6eA==", "Content-Type": "application/json"},
		"cookie only": {"Cookie": "session_id=" + progressToken, "Content-Type": "application/json"},
	} {
		recorder := lib.h.send(http.MethodPut, "/api/consumer/v1/library/2/progress", headers, lib.audioBody(mutationOne, 0, 5, ""))
		if recorder.Code != http.StatusUnauthorized || recorder.Body.Len() != 0 {
			t.Errorf("%s: %d %q", name, recorder.Code, recorder.Body.String())
		}
	}
	livetest.Exec(t, lib.h.path, `UPDATE api_tokens SET revoked_at = '2026-01-01 00:00:00' WHERE id = 2`)
	if got := lib.put(2, progressToken, lib.audioBody(mutationOne, 0, 5, "")); got.Code != http.StatusUnauthorized {
		t.Fatalf("revoked: %d", got.Code)
	}
	livetest.Exec(t, lib.h.path, `UPDATE api_tokens SET revoked_at = NULL, expires_at = '2020-01-01 00:00:00' WHERE id = 2`)
	if got := lib.put(2, progressToken, lib.audioBody(mutationOne, 0, 5, "")); got.Code != http.StatusUnauthorized {
		t.Fatalf("expired: %d", got.Code)
	}
	livetest.Exec(t, lib.h.path, `UPDATE api_tokens SET expires_at = NULL WHERE id = 2`)
	livetest.Exec(t, lib.h.path, `UPDATE users SET deleted_at = '2026-01-01 00:00:00' WHERE id = 1`)
	if got := lib.put(2, progressToken, lib.audioBody(mutationOne, 0, 5, "")); got.Code != http.StatusUnauthorized {
		t.Fatalf("deleted owner: %d", got.Code)
	}
	if rows := livetest.Query(t, lib.h.path, `SELECT COUNT(*) FROM consumer_progresses`); rows[0][0] != int64(0) {
		t.Fatal("an unauthenticated write stored a place")
	}
}

func TestARefusedWriteStillRecordsCredentialUseAndNothingElse(t *testing.T) {
	lib := newHarness(t, nil).shelf()
	if got := lib.put(2, progressToken, `{`); got.Code != http.StatusBadRequest {
		t.Fatal(got.Code)
	}
	if rows := livetest.Query(t, lib.h.path, `SELECT last_used_at IS NOT NULL FROM api_tokens WHERE id = 2`); rows[0][0] != int64(1) {
		t.Fatal("authentication did not record use")
	}
	if rows := livetest.Query(t, lib.h.path, `SELECT (SELECT COUNT(*) FROM consumer_progresses), (SELECT COUNT(*) FROM consumer_reading_states)`); fmt.Sprint(rows) != "[[0 0]]" {
		t.Fatalf("%v", rows)
	}
}

func TestWrongMethodsAreAnsweredBeforeAuthenticationWithTheRoutesOwnAllowList(t *testing.T) {
	lib := newHarness(t, nil).shelf()
	used := func() any {
		return livetest.Query(t, lib.h.path, `SELECT CAST(last_used_at AS TEXT) FROM api_tokens WHERE id = 2`)[0][0]
	}
	before := used()
	for method, allow := range map[string]string{"POST": "GET, HEAD, PUT", "DELETE": "GET, HEAD, PUT", "PATCH": "GET, HEAD, PUT"} {
		recorder := lib.h.send(method, "/api/consumer/v1/library/2/progress", jsonHeaders(progressToken), "{}")
		if recorder.Code != http.StatusMethodNotAllowed || recorder.Header().Get("Allow") != allow {
			t.Errorf("progress %s: %d %q", method, recorder.Code, recorder.Header().Get("Allow"))
		}
	}
	for _, method := range []string{"GET", "HEAD", "POST", "DELETE", "PATCH"} {
		recorder := lib.h.send(method, "/api/consumer/v1/library/2/reading_status", jsonHeaders(progressToken), "{}")
		if recorder.Code != http.StatusMethodNotAllowed || recorder.Header().Get("Allow") != "PUT" {
			t.Errorf("status %s: %d %q", method, recorder.Code, recorder.Header().Get("Allow"))
		}
	}
	if used() != before {
		t.Fatal("a refused verb recorded credential use")
	}
}

func TestBooksThatAreNotReachableAreNotFoundOrExplicitlyUnsupported(t *testing.T) {
	lib := newHarness(t, nil).shelf()
	lib.h.addBook(3, "Pending", store.BookTypeEbook, "")
	livetest.Exec(t, lib.h.path, `UPDATE books SET file_path = NULL WHERE id = 3`)
	lib.h.addBook(4, "Comic", store.BookTypeComicbook, lib.h.file("Comic.epub", "comic"))
	for _, target := range []string{"99", "0", "01", "abc", "3", "9223372036854775808", "1%20"} {
		for _, method := range []string{"GET", "PUT"} {
			recorder := lib.h.send(method, "/api/consumer/v1/library/"+target+"/progress", jsonHeaders(progressToken), lib.audioBody(mutationOne, 0, 1, ""))
			if recorder.Code != http.StatusNotFound {
				t.Errorf("%s %s: %d", method, target, recorder.Code)
			}
		}
		if recorder := lib.h.send("PUT", "/api/consumer/v1/library/"+target+"/reading_status", jsonHeaders(progressToken), `{"status":"finished"}`); recorder.Code != http.StatusNotFound {
			t.Errorf("status %s: %d", target, recorder.Code)
		}
	}
	for _, request := range [][2]string{{"GET", "progress"}, {"PUT", "progress"}, {"PUT", "reading_status"}} {
		recorder := lib.h.send(request[0], "/api/consumer/v1/library/4/"+request[1], jsonHeaders(progressToken), `{"status":"finished"}`)
		if recorder.Code != http.StatusNotImplemented || !strings.Contains(recorder.Body.String(), "unsupported_publication_kind") {
			t.Errorf("comic %v: %d %s", request, recorder.Code, recorder.Body.String())
		}
	}
	if rows := livetest.Query(t, lib.h.path, `SELECT (SELECT COUNT(*) FROM consumer_progresses), (SELECT COUNT(*) FROM consumer_reading_states)`); fmt.Sprint(rows) != "[[0 0]]" {
		t.Fatalf("%v", rows)
	}
}

func TestValidationAnswersMatchRailsAndKeepTheSavedPlace(t *testing.T) {
	lib := newHarness(t, nil).shelf()
	lib.put(2, progressToken, lib.audioBody(mutationOne, 0, 64, ""))
	cases := map[string]string{
		"missing asset":     `{"expected_version":1,"client_mutation_id":"` + mutationTwo + `","position_seconds":1}`,
		"version as string": `{"asset_id":"` + lib.audioID + `","expected_version":"1","client_mutation_id":"` + mutationTwo + `","position_seconds":1}`,
		"negative seconds":  lib.audioBody(mutationTwo, 1, -1, ""),
		"too many seconds":  lib.audioBody(mutationTwo, 1, 999999999, ""),
		"bad time":          lib.audioBody(mutationTwo, 1, 5, `,"observed_at":"2026-02-30T10:00:00Z"`),
		"bad resolve":       lib.audioBody(mutationTwo, 1, 5, `,"resolve_conflict":"true"`),
		"locator on audio":  lib.audioBody(mutationTwo, 1, 5, `,"locator":{"href":"a","locations":{}}`),
		"unknown asset":     strings.Replace(lib.audioBody(mutationTwo, 1, 5, ""), lib.audioID, strings.Repeat("0", 64), 1),
		"epub asset":        strings.Replace(lib.audioBody(mutationTwo, 1, 5, ""), lib.audioID, lib.epubID, 1),
	}
	for name, body := range cases {
		recorder := lib.put(2, progressToken, body)
		parsed := decodeObject(t, recorder, http.StatusUnprocessableEntity)
		if parsed["error"] != "invalid_progress" || parsed["message"] == "" {
			t.Errorf("%s: %v", name, parsed)
		}
	}
	if rows := livetest.Query(t, lib.h.path, `SELECT version, position_seconds FROM consumer_progresses`); fmt.Sprint(rows) != "[[1 64]]" {
		t.Fatalf("%v", rows)
	}
}

func TestUnsupportedAssetsAreNeverAcceptedWithAnUnvalidatedLocator(t *testing.T) {
	lib := newHarness(t, nil).shelf()
	lib.h.addBook(5, "Mixed", store.BookTypeEbook, filepathJoin(lib.h, "Mixed"))
	os.MkdirAll(filepathJoin(lib.h, "Mixed"), 0o700)
	os.WriteFile(filepathJoin(lib.h, "Mixed/Mixed.epub"), []byte("epub"), 0o600)
	os.WriteFile(filepathJoin(lib.h, "Mixed/Mixed.pdf"), []byte("%PDF-1.4\n"+strings.Repeat("x", 600)), 0o600)
	var pdf string
	mixed := store.Book{ID: 5, BookType: store.BookTypeEbook, FilePath: sql.NullString{String: filepathJoin(lib.h, "Mixed"), Valid: true}}
	listing, err := library.Lister{Roots: []string{lib.h.root}, Formats: allReadingFormats}.List(mixed, mixed.FilePath.String)
	if err != nil {
		t.Fatal(err)
	}
	for _, asset := range listing.Assets {
		if asset.Format == "pdf" {
			pdf = asset.ID
		}
	}
	if pdf == "" {
		t.Fatal("the fixture has no PDF")
	}
	body := fmt.Sprintf(`{"asset_id":"%s","expected_version":0,"client_mutation_id":"%s","locator":{"href":"document.pdf","type":"application/pdf","locations":{"position":3}}}`, pdf, mutationOne)
	recorder := lib.put(5, progressToken, body)
	if recorder.Code != http.StatusNotImplemented || !strings.Contains(recorder.Body.String(), "unsupported_asset_format") {
		t.Fatalf("%d %s", recorder.Code, recorder.Body.String())
	}
	if rows := livetest.Query(t, lib.h.path, `SELECT COUNT(*) FROM consumer_progresses`); rows[0][0] != int64(0) {
		t.Fatal("an unvalidated page place was stored")
	}
}

func TestAReplacedFileInvalidatesItsAssetForWritesAndTheSavedPlaceStays(t *testing.T) {
	lib := newHarness(t, nil).shelf()
	lib.put(2, progressToken, lib.audioBody(mutationOne, 0, 5, ""))
	path := lib.h.root + "/Listen.mp3"
	os.WriteFile(path+".new", []byte("different audio stream bytes"), 0o600)
	os.Rename(path+".new", path)
	recorder := lib.put(2, progressToken, lib.audioBody(mutationTwo, 1, 9, ""))
	parsed := decodeObject(t, recorder, http.StatusUnprocessableEntity)
	if parsed["message"] != assetGone {
		t.Fatalf("%v", parsed)
	}
	os.Remove(path)
	recorder = lib.put(2, progressToken, lib.audioBody(mutationTwo, 1, 9, ""))
	if parsed := decodeObject(t, recorder, http.StatusUnprocessableEntity); parsed["message"] != mediaMissing {
		t.Fatalf("%v", parsed)
	}
	if rows := livetest.Query(t, lib.h.path, `SELECT version, position_seconds FROM consumer_progresses`); fmt.Sprint(rows) != "[[1 5]]" {
		t.Fatalf("%v", rows)
	}
	if got := lib.get(2, progressToken)["progress"]; got == nil {
		t.Fatal("the saved place is no longer readable once the file is gone")
	}
}

func TestConflictsCarryTheCurrentPlaceAndMissingRowsCarryNull(t *testing.T) {
	lib := newHarness(t, nil).shelf()
	missing := decodeObject(t, lib.put(2, progressToken, lib.audioBody(mutationOne, 3, 5, "")), http.StatusConflict)
	if progress, present := missing["progress"]; !present || progress != nil || missing["error"] != "progress_conflict" {
		t.Fatalf("%v", missing)
	}
	first := decodeObject(t, lib.put(2, progressToken, lib.audioBody(mutationOne, 0, 5, "")), http.StatusOK)["progress"]
	stale := decodeObject(t, lib.put(2, progressToken, lib.audioBody(mutationTwo, 0, 9, "")), http.StatusConflict)
	if fmt.Sprint(stale["progress"]) != fmt.Sprint(first) || stale["error"] != "progress_conflict" {
		t.Fatalf("%v", stale)
	}
	reused := decodeObject(t, lib.put(2, progressToken, lib.audioBody(mutationOne, 1, 9, "")), http.StatusConflict)
	if fmt.Sprint(reused["progress"]) != fmt.Sprint(first) {
		t.Fatalf("%v", reused)
	}
	retry := decodeObject(t, lib.put(2, progressToken, lib.audioBody(mutationOne, 0, 5, "")), http.StatusOK)["progress"]
	if fmt.Sprint(retry) != fmt.Sprint(first) {
		t.Fatalf("a retry did not return the original checkpoint:\n%v\n%v", retry, first)
	}
}

func TestStatusIsSeparateFromProgressAndImmediatelyVisibleEverywhere(t *testing.T) {
	lib := newHarness(t, nil).shelf()
	written := decodeObject(t, lib.put(2, progressToken, lib.audioBody(mutationOne, 0, 5, "")), http.StatusOK)["progress"]
	status := func(name string) map[string]any {
		return decodeObject(t, lib.h.send(http.MethodPut, "/api/consumer/v1/library/2/reading_status", jsonHeaders(progressToken), fmt.Sprintf(`{"status":%q}`, name)), http.StatusOK)
	}
	finished := status("finished")
	if finished["reading_status"] != "finished" || fmt.Sprint(finished["progress"]) != fmt.Sprint(written) || finished["id"] != "2" || finished["book_type"] != "audiobook" {
		t.Fatalf("%v", finished)
	}
	lib.put(2, progressToken, lib.audioBody(mutationTwo, 1, 50, ""))
	listed := decodeObject(t, lib.h.do(http.MethodGet, "/api/consumer/v1/library?status=finished", jsonHeaders(progressToken)), http.StatusOK)["items"].([]any)
	if len(listed) != 1 || listed[0].(map[string]any)["id"] != "2" {
		t.Fatalf("%v", listed)
	}
	if kept := decodeObject(t, lib.h.do(http.MethodGet, "/api/consumer/v1/library/2", jsonHeaders(progressToken)), http.StatusOK); kept["reading_status"] != "finished" || kept["progress"].(map[string]any)["position_seconds"] != 50.0 {
		t.Fatalf("%v", kept)
	}
	if got := decodeObject(t, lib.h.do(http.MethodGet, "/api/consumer/v1/continue", jsonHeaders(progressToken)), http.StatusOK)["items"].([]any); len(got) != 0 {
		t.Fatalf("a finished title is still continued: %v", got)
	}
	if unread := status("unread"); unread["reading_status"] != "unread" || unread["progress"] == nil {
		t.Fatalf("marking unread discarded the saved place: %v", unread)
	}
	if got := decodeObject(t, lib.h.do(http.MethodGet, "/api/consumer/v1/continue", jsonHeaders(progressToken)), http.StatusOK)["items"].([]any); len(got) != 0 {
		t.Fatalf("an unread title is continued: %v", got)
	}
	if again := status("in_progress"); again["reading_status"] != "in_progress" {
		t.Fatalf("%v", again)
	}
	if got := decodeObject(t, lib.h.do(http.MethodGet, "/api/consumer/v1/continue", jsonHeaders(progressToken)), http.StatusOK)["items"].([]any); len(got) != 1 {
		t.Fatalf("%v", got)
	}
}

func TestReadingStatusValidationAndFormatHeaders(t *testing.T) {
	lib := newHarness(t, nil).shelf()
	url := "/api/consumer/v1/library/1/reading_status"
	for _, body := range []string{`{"status":"unknown"}`, `{"status":["finished"]}`, `{"status":null}`, `{}`, `[]`, `null`, ``, `{"status":"Finished"}`} {
		recorder := lib.h.send(http.MethodPut, url, jsonHeaders(progressToken), body)
		parsed := decodeObject(t, recorder, http.StatusUnprocessableEntity)
		if parsed["error"] != "invalid_reading_status" || parsed["message"] != "Choose unread, in_progress, or finished" {
			t.Errorf("%q: %v", body, parsed)
		}
	}
	headers := jsonHeaders(progressToken)
	headers["X-Shelfarr-Reader-Formats"] = "mobi"
	if recorder := lib.h.send(http.MethodPut, url, headers, `{"status":"finished"}`); recorder.Code != http.StatusBadRequest || !strings.Contains(recorder.Body.String(), "invalid_request") {
		t.Fatalf("%d %s", recorder.Code, recorder.Body.String())
	}
	headers["X-Shelfarr-Reader-Formats"] = "pdf"
	if recorder := lib.h.send(http.MethodPut, url, headers, `{"status":"finished"}`); recorder.Code != http.StatusNotImplemented || !strings.Contains(recorder.Body.String(), "unsupported_reader_format") {
		t.Fatalf("%d %s", recorder.Code, recorder.Body.String())
	}
	headers["X-Shelfarr-Reader-Formats"] = "epub"
	declared := decodeObject(t, lib.h.send(http.MethodPut, url, headers, `{"status":"finished"}`), http.StatusOK)
	if declared["content_kind"] != "book" || declared["reading_status"] != "finished" {
		t.Fatalf("%v", declared)
	}
	if rows := livetest.Query(t, lib.h.path, `SELECT COUNT(*) FROM consumer_reading_states`); rows[0][0] != int64(1) {
		t.Fatalf("a refused status write left state: %v", rows)
	}
}

func TestBodiesAreBoundedTypedAndNeverReadBeforeAuthentication(t *testing.T) {
	lib := newHarness(t, nil).shelf()
	url := "/api/consumer/v1/library/2/progress"
	oversized := lib.audioBody(mutationOne, 0, 1, `,"padding":"`+strings.Repeat("x", 70_000)+`"`)
	recorder := lib.h.send(http.MethodPut, url, jsonHeaders(progressToken), oversized)
	if recorder.Code != http.StatusRequestEntityTooLarge || !strings.Contains(recorder.Body.String(), "request_too_large") {
		t.Fatalf("%d %s", recorder.Code, recorder.Body.String())
	}
	request := httptest.NewRequest(http.MethodPut, url, io.NopCloser(strings.NewReader(oversized)))
	request.ContentLength = -1
	for name, value := range jsonHeaders(progressToken) {
		request.Header.Set(name, value)
	}
	chunked := httptest.NewRecorder()
	lib.h.app.ServeHTTP(chunked, request)
	if chunked.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("a body without a length was not bounded: %d", chunked.Code)
	}
	for _, contentType := range []string{"text/plain", "application/x-www-form-urlencoded", "application/jsonx", "", "multipart/form-data"} {
		headers := map[string]string{"Authorization": "Bearer " + progressToken}
		if contentType != "" {
			headers["Content-Type"] = contentType
		}
		if got := lib.h.send(http.MethodPut, url, headers, lib.audioBody(mutationOne, 0, 1, "")); got.Code != http.StatusUnsupportedMediaType {
			t.Errorf("%q: %d", contentType, got.Code)
		}
	}
	for _, contentType := range []string{"application/json", "Application/JSON; charset=utf-8", "application/json;charset=UTF-8"} {
		headers := map[string]string{"Authorization": "Bearer " + progressToken, "Content-Type": contentType}
		if got := lib.h.send(http.MethodPut, url, headers, lib.audioBody(mutationOne, 0, 1, "")); got.Code != http.StatusOK && got.Code != http.StatusConflict {
			t.Errorf("%q: %d %s", contentType, got.Code, got.Body.String())
		}
	}
	if got := lib.h.send(http.MethodPut, url, map[string]string{"Authorization": "Bearer " + progressToken}, ""); got.Code != http.StatusUnprocessableEntity {
		t.Errorf("an empty body without a type: %d", got.Code)
	}
	for _, body := range []string{"{", `{"a":}`, "[1,", `{"a":1}x`, "\xff", `{"a":NaN}`} {
		if got := lib.put(2, progressToken, body); got.Code != http.StatusBadRequest || !strings.Contains(got.Body.String(), "invalid_json") {
			t.Errorf("%q: %d %s", body, got.Code, got.Body.String())
		}
	}
	for _, body := range []string{"[]", "null", `"x"`, "5", ""} {
		if got := lib.put(2, progressToken, body); got.Code != http.StatusUnprocessableEntity {
			t.Errorf("%q: %d", body, got.Code)
		}
	}
	unreadable := &countingBody{}
	probe := httptest.NewRequest(http.MethodPut, url, unreadable)
	probe.Header.Set("Content-Type", "application/json")
	rejected := httptest.NewRecorder()
	lib.h.app.ServeHTTP(rejected, probe)
	if rejected.Code != http.StatusUnauthorized || unreadable.reads.Load() != 0 {
		t.Fatalf("an unauthenticated body was read: %d %d", rejected.Code, unreadable.reads.Load())
	}
}

type countingBody struct{ reads atomic.Int32 }

func (c *countingBody) Read([]byte) (int, error) {
	c.reads.Add(1)
	return 0, io.EOF
}

func TestConcurrentFirstWritesThroughTheHandlerAdmitOneAndReportTheRest(t *testing.T) {
	lib := newHarness(t, func(c *Config) { c.MaxMetadataRequests = 64 }).shelf()
	var statuses sync.Map
	var wait sync.WaitGroup
	var created, conflicted atomic.Int32
	for index := 0; index < 20; index++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			mutation := fmt.Sprintf("00000000-0000-4000-8000-%012d", index)
			recorder := lib.put(2, progressToken, lib.audioBody(mutation, 0, float64(index), ""))
			switch recorder.Code {
			case http.StatusOK:
				created.Add(1)
			case http.StatusConflict:
				conflicted.Add(1)
			default:
				statuses.Store(index, true)
				t.Logf("unexpected %d %s", recorder.Code, recorder.Body.String())
			}
		}()
	}
	wait.Wait()
	unexpected := 0
	statuses.Range(func(any, any) bool { unexpected++; return true })
	if created.Load() != 1 || conflicted.Load() != 19 || unexpected != 0 {
		t.Fatalf("created=%d conflicted=%d unexpected=%d", created.Load(), conflicted.Load(), unexpected)
	}
}

func TestLogsNeverContainBodiesLocatorsAssetsOrTokens(t *testing.T) {
	lib := newHarness(t, nil).shelf()
	lib.put(1, progressToken, lib.epubBody(mutationOne, 0, `{"href":"secret-chapter.xhtml","locations":{"progression":0.5}}`, ""))
	lib.put(2, progressToken, lib.audioBody(mutationTwo, 0, 9, `,"observed_at":"2026-11-07T10:15:30Z"`))
	lib.put(2, progressToken, "secret-malformed-body")
	logged := lib.h.logs.String()
	for _, sensitive := range []string{"secret-chapter", mutationOne, mutationTwo, lib.audioID, lib.epubID, progressToken, "secret-malformed", "observed_at", "2026-11-07", "Listen.mp3", lib.h.root} {
		if strings.Contains(logged, sensitive) {
			t.Errorf("the log leaks %q", sensitive)
		}
	}
	if !strings.Contains(logged, `"route":"progress"`) {
		t.Fatalf("%s", logged)
	}
}

func filepathJoin(h *harness, name string) string { return h.root + "/" + name }

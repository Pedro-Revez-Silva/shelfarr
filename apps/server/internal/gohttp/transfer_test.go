//go:build linux

package gohttp

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/livetest"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
)

type transferShelf struct {
	h     *harness
	asset string
	grant string
	url   string
	body  string
}

func (h *harness) sendBody(method, target, body string, headers map[string]string) *httptest.ResponseRecorder {
	h.t.Helper()
	request := httptest.NewRequest(method, target, strings.NewReader(body))
	for name, value := range headers {
		request.Header.Set(name, value)
	}
	recorder := httptest.NewRecorder()
	h.app.ServeHTTP(recorder, request)
	return recorder
}

func (h *harness) clock(moment time.Time) {
	h.app.now = func() time.Time { return moment }
	h.app.auth.Now = h.app.now
}

func newTransferShelf(t *testing.T, adjust func(*harness)) transferShelf {
	t.Helper()
	h := newHarness(t, nil)
	if adjust != nil {
		adjust(h)
	}
	body := strings.Repeat("0123456789abcdef", 64)
	h.addBook(1, "Book", store.BookTypeEbook, h.file("Book.epub", body))
	var listing struct {
		Items []struct {
			Assets []struct{ ID string } `json:"assets"`
		} `json:"items"`
	}
	if err := json.Unmarshal(h.do(http.MethodGet, "/api/consumer/v1/library", authorised()).Body.Bytes(), &listing); err != nil || len(listing.Items) != 1 {
		t.Fatal("the shelf has no book")
	}
	shelf := transferShelf{h: h, asset: listing.Items[0].Assets[0].ID, body: body}
	shelf.grant, shelf.url = shelf.mint()
	return shelf
}

func (s transferShelf) mintPath() string {
	return "/api/consumer/v1/library/1/assets/" + s.asset + "/transfer_grant"
}

func (s transferShelf) mint() (string, string) {
	s.h.t.Helper()
	recorder := s.h.sendBody(http.MethodPost, s.mintPath(), `{}`, map[string]string{"Authorization": "Bearer " + rawToken, "Content-Type": "application/json"})
	var minted struct{ URL, ExpiresAt string }
	if recorder.Code != http.StatusCreated || json.Unmarshal(recorder.Body.Bytes(), &minted) != nil {
		s.h.t.Fatalf("mint: %d %s", recorder.Code, recorder.Body.String())
	}
	return minted.URL[strings.Index(minted.URL, "grant=")+len("grant="):], minted.URL
}

func (s transferShelf) fetch(method string, headers map[string]string) *httptest.ResponseRecorder {
	return s.h.sendBody(method, s.url, "", headers)
}

func (s transferShelf) status(t *testing.T) (int, string) {
	t.Helper()
	recorder := s.fetch(http.MethodGet, nil)
	if recorder.Code == http.StatusUnauthorized {
		return recorder.Code, errorCode(t, recorder)
	}
	return recorder.Code, ""
}

func TestAMintedGrantIsARelativePathThatFetchesTheAssetWithoutTheBearer(t *testing.T) {
	moment := time.Date(2026, 11, 15, 10, 0, 0, 987_654_000, time.UTC)
	shelf := newTransferShelf(t, func(h *harness) { h.clock(moment) })
	recorder := shelf.h.sendBody(http.MethodPost, shelf.mintPath(), "", map[string]string{"Authorization": "Bearer " + rawToken})
	var minted map[string]string
	json.Unmarshal(recorder.Body.Bytes(), &minted)
	if recorder.Code != http.StatusCreated || len(minted) != 2 || minted["expires_at"] != "2026-11-16T10:00:00Z" {
		t.Fatalf("%d %s", recorder.Code, recorder.Body.String())
	}
	if !strings.HasPrefix(minted["url"], "/api/consumer/v1/library/1/assets/"+shelf.asset+"/transfer?grant=") || recorder.Header().Get("Location") != "" {
		t.Fatalf("not a relative transfer path: %q", minted["url"])
	}
	for _, leaked := range []string{rawToken, shelf.h.root, shelf.h.path, testSecret} {
		if strings.Contains(recorder.Body.String(), leaked) {
			t.Fatalf("the mint response leaks %q", leaked)
		}
	}
	for _, method := range []string{http.MethodGet, http.MethodHead} {
		got := shelf.fetch(method, nil)
		header := got.Header()
		if got.Code != http.StatusOK || header.Get("Cache-Control") != "private, no-store" || header.Get("Referrer-Policy") != "no-referrer" || header.Get("ETag") != `"`+shelf.asset+`"` || header.Get("Location") != "" || header.Get("Content-Length") != "1024" {
			t.Fatalf("%s: %d %v", method, got.Code, header)
		}
		if (method == http.MethodGet) != (got.Body.String() == shelf.body) {
			t.Fatalf("%s delivered %d bytes", method, got.Body.Len())
		}
	}
	part := shelf.fetch(http.MethodGet, map[string]string{"Range": "bytes=-16"})
	if part.Code != http.StatusPartialContent || part.Body.String() != shelf.body[len(shelf.body)-16:] {
		t.Fatalf("%d %q", part.Code, part.Body.String())
	}
	if shelf.fetch(http.MethodGet, map[string]string{"If-None-Match": `"` + shelf.asset + `"`}).Code != http.StatusNotModified {
		t.Fatal("the validator is not honoured")
	}
	if got := shelf.fetch(http.MethodGet, map[string]string{"Range": "bytes=5000-"}); got.Code != http.StatusRequestedRangeNotSatisfiable {
		t.Fatalf("%d", got.Code)
	}
}

func TestAGrantNeverTouchesOrAdoptsTheCredentialAndNeverMovesReadingState(t *testing.T) {
	shelf := newTransferShelf(t, nil)
	livetest.Exec(t, shelf.h.path, `INSERT INTO api_tokens (id, user_id, token_digest, scopes, replaces_api_token_id) VALUES (2, 1, 'other-digest', '["library:read"]', 1)`)
	tokens := func() [][]any {
		return livetest.Query(t, shelf.h.path, `SELECT id, CAST(last_used_at AS TEXT), CAST(updated_at AS TEXT), CAST(revoked_at AS TEXT), replaces_api_token_id FROM api_tokens ORDER BY id`)
	}
	before := tokens()
	progress := livetest.Query(t, shelf.h.path, `SELECT COUNT(*) FROM consumer_progresses`)[0][0]
	shelf.h.clock(time.Now().Add(time.Hour))
	for _, method := range []string{http.MethodGet, http.MethodHead, http.MethodGet} {
		if shelf.fetch(method, nil).Code != http.StatusOK {
			t.Fatal("the grant was refused")
		}
	}
	after := tokens()
	for index := range before {
		for column := range before[index] {
			if before[index][column] != after[index][column] {
				t.Fatalf("a transfer changed api_tokens row %v column %d", before[index][0], column)
			}
		}
	}
	if livetest.Query(t, shelf.h.path, `SELECT COUNT(*) FROM consumer_progresses`)[0][0] != progress || livetest.Query(t, shelf.h.path, `SELECT COUNT(*) FROM consumer_reading_states`)[0][0] != int64(0) {
		t.Fatal("a transfer moved reading state")
	}
}

func TestEveryUseRechecksTheLiveTokenOwnerAndScope(t *testing.T) {
	shelf := newTransferShelf(t, nil)
	livetest.Exec(t, shelf.h.path, `INSERT INTO users (id, username, name) VALUES (2, 'bob', 'Bob')`)
	for name, change := range map[string][2]string{
		"revoked":         {`UPDATE api_tokens SET revoked_at = '2026-01-01 00:00:00' WHERE id = 1`, `UPDATE api_tokens SET revoked_at = NULL WHERE id = 1`},
		"expired":         {`UPDATE api_tokens SET expires_at = '2020-01-01 00:00:00' WHERE id = 1`, `UPDATE api_tokens SET expires_at = NULL WHERE id = 1`},
		"scope removed":   {`UPDATE api_tokens SET scopes = '["progress:write"]' WHERE id = 1`, `UPDATE api_tokens SET scopes = '["library:read"]' WHERE id = 1`},
		"scope garbage":   {`UPDATE api_tokens SET scopes = 'not json' WHERE id = 1`, `UPDATE api_tokens SET scopes = '["library:read"]' WHERE id = 1`},
		"another owner":   {`UPDATE api_tokens SET user_id = 2 WHERE id = 1`, `UPDATE api_tokens SET user_id = 1 WHERE id = 1`},
		"no owner":        {`UPDATE api_tokens SET user_id = NULL WHERE id = 1`, `UPDATE api_tokens SET user_id = 1 WHERE id = 1`},
		"deleted owner":   {`UPDATE users SET deleted_at = '2026-01-01 00:00:00' WHERE id = 1`, `UPDATE users SET deleted_at = NULL WHERE id = 1`},
		"missing owner":   {`UPDATE api_tokens SET user_id = 99 WHERE id = 1`, `UPDATE api_tokens SET user_id = 1 WHERE id = 1`},
		"deleted token":   {`DELETE FROM api_tokens WHERE id = 1`, `INSERT INTO api_tokens (id, user_id, token_digest, scopes) VALUES (1, 1, 'restored', '["library:read"]')`},
		"spaced scope":    {`UPDATE api_tokens SET scopes = '["progress:write", "search:read"]' WHERE id = 1`, `UPDATE api_tokens SET scopes = '"search:read library:read"' WHERE id = 1`},
		"scope null":      {`UPDATE api_tokens SET scopes = 'null' WHERE id = 1`, `UPDATE api_tokens SET scopes = '["library:read"]' WHERE id = 1`},
		"scope object":    {`UPDATE api_tokens SET scopes = '{"library:read":true}' WHERE id = 1`, `UPDATE api_tokens SET scopes = '["library:read"]' WHERE id = 1`},
		"admin scope too": {`UPDATE api_tokens SET scopes = '["requests:admin"]' WHERE id = 1`, `UPDATE api_tokens SET scopes = '["requests:admin","library:read"]' WHERE id = 1`},
	} {
		t.Run(name, func(t *testing.T) {
			if status, _ := shelf.status(t); status != http.StatusOK {
				t.Fatalf("baseline %d", status)
			}
			livetest.Exec(t, shelf.h.path, change[0])
			if status, code := shelf.status(t); status != http.StatusUnauthorized || code != "invalid_grant" {
				t.Fatalf("the change was not seen: %d %s", status, code)
			}
			if got := shelf.fetch(http.MethodHead, nil); got.Code != http.StatusUnauthorized {
				t.Fatalf("HEAD: %d", got.Code)
			}
			livetest.Exec(t, shelf.h.path, change[1])
			if status, _ := shelf.status(t); status != http.StatusOK {
				t.Fatalf("the restored state was not seen: %d", status)
			}
		})
	}
}

func TestAGrantStopsAtItsDayAndAtTheTokensOwnExpiry(t *testing.T) {
	issued := time.Date(2026, 11, 15, 10, 0, 0, 987_654_000, time.UTC)
	day := time.Date(2026, 11, 16, 10, 0, 0, 987_000_000, time.UTC)
	tokenExpiry := time.Date(2026, 11, 15, 12, 0, 0, 500_000_000, time.UTC)
	for name, test := range map[string]struct {
		expiry string
		alive  []time.Time
		dead   []time.Time
	}{
		"a day":     {"", []time.Time{issued.Add(-time.Hour), issued, day.Add(-time.Microsecond)}, []time.Time{day, day.Add(time.Microsecond), day.Add(time.Hour)}},
		"the token": {"2026-11-15 12:00:00.500700", []time.Time{tokenExpiry.Add(-time.Microsecond), tokenExpiry.Add(-time.Hour)}, []time.Time{tokenExpiry, tokenExpiry.Add(300 * time.Microsecond), tokenExpiry.Add(time.Second)}},
	} {
		t.Run(name, func(t *testing.T) {
			shelf := newTransferShelf(t, func(h *harness) {
				h.clock(issued)
				if test.expiry != "" {
					livetest.Exec(t, h.path, `UPDATE api_tokens SET expires_at = ? WHERE id = 1`, test.expiry)
				}
			})
			for _, moment := range test.alive {
				shelf.h.clock(moment)
				if status, _ := shelf.status(t); status != http.StatusOK {
					t.Errorf("at %v: %d", moment, status)
				}
			}
			for _, moment := range test.dead {
				shelf.h.clock(moment)
				if status, code := shelf.status(t); status != http.StatusUnauthorized || code != "invalid_grant" {
					t.Errorf("at %v: %d", moment, status)
				}
			}
		})
	}
}

func TestTheMintedExpiryIsTheTokensOwnWhenItIsSooner(t *testing.T) {
	issued := time.Date(2026, 11, 15, 10, 0, 0, 0, time.UTC)
	for expiry, want := range map[string]string{"2026-11-15 12:30:45.999999": "2026-11-15T12:30:45Z", "2026-12-15 12:00:00": "2026-11-16T10:00:00Z", "2026-11-16 10:00:00": "2026-11-16T10:00:00Z"} {
		shelf := newTransferShelf(t, func(h *harness) {
			h.clock(issued)
			livetest.Exec(t, h.path, `UPDATE api_tokens SET expires_at = ? WHERE id = 1`, expiry)
		})
		recorder := shelf.h.sendBody(http.MethodPost, shelf.mintPath(), "", map[string]string{"Authorization": "Bearer " + rawToken})
		var minted map[string]string
		json.Unmarshal(recorder.Body.Bytes(), &minted)
		if minted["expires_at"] != want {
			t.Errorf("token expiring %s: %v", expiry, minted)
		}
	}
}

func TestOnlyTheLiteralGrantQueryAuthenticatesAndNothingElseCanRepairIt(t *testing.T) {
	shelf := newTransferShelf(t, nil)
	path := strings.Split(shelf.url, "?")[0]
	grant := shelf.grant
	for query, accepted := range map[string]bool{
		"grant=" + grant: true, "": false, "grant=": false, "grant=" + grant + "&grant=" + grant: false, "grant=" + grant + "&x=1": false, "x=1&grant=" + grant: false,
		"grant=" + grant + ";x=1": false, "gr%61nt=" + grant: false, "GRANT=" + grant: false, "grant[]=" + grant: false, "x[grant]=" + grant: false,
		"grant=" + grant + "%": false, "grant=" + grant + "%FF": false, "grant=" + grant + "A": false, "grant=" + grant[:len(grant)-1]: false, "grant=" + rawToken: false,
	} {
		for _, headers := range []map[string]string{nil, authorised(), {"Authorization": "Bearer nonsense", "Cookie": "session_id=junk"}} {
			got := shelf.h.sendBody(http.MethodGet, path+"?"+query, "", headers)
			if accepted != (got.Code == http.StatusOK) || !accepted && (got.Code != http.StatusUnauthorized || errorCode(t, got) != "invalid_grant") {
				t.Errorf("%q with %v: %d", query, headers, got.Code)
			}
			if got.Header().Get("Cache-Control") != "private, no-store" || got.Header().Get("Referrer-Policy") != "no-referrer" {
				t.Errorf("%q: the answer is not private", query)
			}
		}
	}
	if got := shelf.h.do(http.MethodGet, path, authorised()); got.Code != http.StatusUnauthorized {
		t.Fatalf("the bearer alone opened the transfer route: %d", got.Code)
	}
}

func TestAGrantOpensOnlyItsOwnBookAndAssetOnlyOnTheTransferRouteAndNeverActsAsACredential(t *testing.T) {
	shelf := newTransferShelf(t, nil)
	shelf.h.addBook(2, "Other", store.BookTypeEbook, shelf.h.file("Other.epub", "other"))
	other := "/api/consumer/v1/library/2/assets/" + shelf.asset + "/transfer?grant=" + shelf.grant
	swapped := "/api/consumer/v1/library/1/assets/" + strings.Repeat("b", 64) + "/transfer?grant=" + shelf.grant
	for _, target := range []string{other, swapped} {
		if got := shelf.h.sendBody(http.MethodGet, target, "", nil); got.Code != http.StatusUnauthorized || errorCode(t, got) != "invalid_grant" {
			t.Errorf("%s: %d", target, got.Code)
		}
	}
	for _, target := range []string{
		"/api/consumer/v1/library/1/assets/" + shelf.asset + "?grant=" + shelf.grant, "/api/consumer/v1/library/1?grant=" + shelf.grant, "/api/consumer/v1/library?grant=" + shelf.grant,
		"/api/consumer/v1/me?grant=" + shelf.grant, "/api/consumer/v1/library/1/progress?grant=" + shelf.grant, "/api/consumer/v1/continue?grant=" + shelf.grant,
	} {
		if got := shelf.h.sendBody(http.MethodGet, target, "", nil); got.Code != http.StatusUnauthorized {
			t.Errorf("%s accepted a grant: %d", target, got.Code)
		}
	}
	for _, target := range []string{"/api/consumer/v1/library", "/api/consumer/v1/me", "/api/consumer/v1/library/1/assets/" + shelf.asset} {
		if got := shelf.h.sendBody(http.MethodGet, target, "", map[string]string{"Authorization": "Bearer " + shelf.grant}); got.Code != http.StatusUnauthorized {
			t.Errorf("%s accepted a grant as a bearer: %d", target, got.Code)
		}
	}
	if got := shelf.h.sendBody(http.MethodPut, "/api/consumer/v1/library/1/progress?grant="+shelf.grant, `{}`, map[string]string{"Content-Type": "application/json"}); got.Code != http.StatusUnauthorized {
		t.Errorf("a grant authorised a progress write: %d", got.Code)
	}
	if got := shelf.h.sendBody(http.MethodPost, strings.Split(shelf.mintPath(), "?")[0]+"?grant="+shelf.grant, "", nil); got.Code != http.StatusUnauthorized {
		t.Errorf("a grant minted another grant: %d", got.Code)
	}
}

func TestOnlyGetAndHeadReachTheTransferAndOnlyPostReachesTheMint(t *testing.T) {
	shelf := newTransferShelf(t, nil)
	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete, http.MethodOptions} {
		if got := shelf.fetch(method, authorised()); got.Code != http.StatusNotFound {
			t.Errorf("%s transfer: %d", method, got.Code)
		}
	}
	for _, method := range []string{http.MethodGet, http.MethodHead, http.MethodPut, http.MethodDelete} {
		if got := shelf.h.sendBody(method, shelf.mintPath(), "", authorised()); got.Code != http.StatusNotFound {
			t.Errorf("%s transfer_grant: %d", method, got.Code)
		}
	}
	for _, target := range []string{shelf.mintPath() + ".json", strings.Split(shelf.url, "?")[0] + ".json?grant=" + shelf.grant, shelf.mintPath() + "/"} {
		if got := shelf.h.sendBody(http.MethodPost, target, "", authorised()); got.Code != http.StatusNotFound {
			t.Errorf("%s: %d", target, got.Code)
		}
	}
}

func TestMintingFollowsTheBearerContractAndRefusesWhatIsNotAnAcquiredCurrentAsset(t *testing.T) {
	shelf := newTransferShelf(t, nil)
	json := map[string]string{"Authorization": "Bearer " + rawToken, "Content-Type": "application/json"}
	book := "/api/consumer/v1/library/1/assets/"
	for name, test := range map[string]struct {
		target, body string
		headers      map[string]string
		status       int
		code         string
	}{
		"unauthenticated": {shelf.mintPath(), "", nil, http.StatusUnauthorized, ""},
		"wrong scope":     {shelf.mintPath(), "", map[string]string{"Authorization": "Bearer " + rawToken}, http.StatusCreated, ""},
		"unknown asset":   {book + strings.Repeat("0", 64) + "/transfer_grant", "", authorised(), http.StatusGone, "asset_unavailable"},
		"malformed asset": {book + "not-an-asset/transfer_grant", "", authorised(), http.StatusGone, "asset_unavailable"},
		"unknown book":    {"/api/consumer/v1/library/9/assets/" + shelf.asset + "/transfer_grant", "", authorised(), http.StatusNotFound, "not_found"},
		"malformed book":  {"/api/consumer/v1/library/1x/assets/" + shelf.asset + "/transfer_grant", "", authorised(), http.StatusNotFound, "not_found"},
		"bad json":        {shelf.mintPath(), "{", json, http.StatusBadRequest, "invalid_json"},
		"json null":       {shelf.mintPath(), "null", json, http.StatusCreated, ""},
		"form body":       {shelf.mintPath(), "a=1", authorised(), http.StatusCreated, ""},
		"oversized":       {shelf.mintPath(), strings.Repeat("x", 65*1024), json, http.StatusRequestEntityTooLarge, "request_too_large"},
		"at the limit":    {shelf.mintPath(), `{"x":"` + strings.Repeat("a", 64*1024-8) + `"}`, json, http.StatusCreated, ""},
	} {
		got := shelf.h.sendBody(http.MethodPost, test.target, test.body, test.headers)
		if got.Code != test.status || (test.code != "" && errorCode(t, got) != test.code) {
			t.Errorf("%s: %d %s", name, got.Code, got.Body.String())
		}
	}
	livetest.Exec(t, shelf.h.path, `UPDATE api_tokens SET scopes = '["progress:write"]' WHERE id = 1`)
	got := shelf.h.sendBody(http.MethodPost, shelf.mintPath(), "", authorised())
	var refused map[string]string
	if err := jsonUnmarshal(got.Body.Bytes(), &refused); err != nil || got.Code != http.StatusForbidden || refused["error"] != "insufficient_scope" || refused["required_scope"] != "library:read" {
		t.Fatalf("%d %s", got.Code, got.Body.String())
	}
}

func jsonUnmarshal(data []byte, into any) error { return json.Unmarshal(data, into) }

func TestRemovedAndReplacedAssetsAnswerGoneAndNotFoundLikeTheBearerRoute(t *testing.T) {
	shelf := newTransferShelf(t, nil)
	shelf.h.file("Book.epub.new", "a different media edition")
	if err := renameFile(shelf.h.root+"/Book.epub.new", shelf.h.root+"/Book.epub"); err != nil {
		t.Fatal(err)
	}
	if got := shelf.fetch(http.MethodGet, nil); got.Code != http.StatusGone || errorCode(t, got) != "asset_unavailable" || strings.Contains(got.Body.String(), shelf.h.root) || got.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatalf("a replaced file: %d %s", got.Code, got.Body.String())
	}
	if got := shelf.h.sendBody(http.MethodPost, shelf.mintPath(), "", authorised()); got.Code != http.StatusGone {
		t.Fatalf("minting for a replaced file: %d", got.Code)
	}
	livetest.Exec(t, shelf.h.path, `UPDATE books SET file_path = NULL WHERE id = 1`)
	if got := shelf.fetch(http.MethodGet, nil); got.Code != http.StatusNotFound || errorCode(t, got) != "not_found" {
		t.Fatalf("a removed book: %d %s", got.Code, got.Body.String())
	}
}

func TestTransfersAreAdmittedLikeMediaStreams(t *testing.T) {
	shelf := newTransferShelf(t, func(h *harness) { h.app.streams = make(chan struct{}, 1) })
	shelf.h.app.streams <- struct{}{}
	got := shelf.fetch(http.MethodGet, nil)
	if got.Code != http.StatusServiceUnavailable || got.Header().Get("Retry-After") == "" || got.Header().Get("Cache-Control") != "private, no-store" || got.Header().Get("Referrer-Policy") != "no-referrer" {
		t.Fatalf("a full media pool admitted a transfer or answered it in the open: %d %v", got.Code, got.Header())
	}
	if got := shelf.h.sendBody(http.MethodPost, shelf.mintPath(), "", authorised()); got.Code != http.StatusCreated {
		t.Fatalf("a full media pool blocked a mint: %d", got.Code)
	}
}

func TestGrantsNeverReachTheLogOnAnyPath(t *testing.T) {
	shelf := newTransferShelf(t, nil)
	path := strings.Split(shelf.url, "?")[0]
	for _, target := range []string{
		shelf.url, strings.Replace(shelf.url, "/transfer?", "/elsewhere?", 1), "/api/consumer/v1/nowhere?grant=" + shelf.grant, "/nowhere?gr%61nt=" + shelf.grant + "&x[grant]=" + shelf.grant,
		path + "?grant=" + shelf.grant + "%", path + "?grant=" + shelf.grant + "&grant=" + shelf.grant, path + "?Grant=" + shelf.grant, "/api/consumer/v1/me?grant=" + shelf.grant,
	} {
		shelf.h.sendBody(http.MethodGet, target, "", map[string]string{"Authorization": "Bearer " + shelf.grant})
		shelf.h.sendBody(http.MethodHead, target, "", nil)
	}
	shelf.h.app.db = nil
	shelf.h.sendBody(http.MethodGet, shelf.url, "", nil)
	logged := shelf.h.logs.String()
	for _, sensitive := range []string{shelf.grant, rawToken, testSecret, "grant=", "Authorization"} {
		if strings.Contains(logged, sensitive) {
			t.Errorf("the log contains %q", sensitive)
		}
	}
	if !strings.Contains(logged, `"route":"transfer"`) || !strings.Contains(logged, `"code":"invalid_grant"`) {
		t.Fatalf("transfers are not logged: %s", logged)
	}
}

func renameFile(from, to string) error { return os.Rename(from, to) }

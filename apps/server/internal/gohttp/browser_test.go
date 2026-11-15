//go:build linux

package gohttp

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/live"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/livetest"
)

const (
	browserOrigin = "http://127.0.0.1:3100"
	alicePassword = "Unit-Alice-Passw0rd-Sentinel"
	bobPassword   = "Unit-Bob-Passw0rd-Sentinel"
)

type clock struct {
	mutex sync.Mutex
	value time.Time
}

func (c *clock) Now() time.Time {
	c.mutex.Lock()
	defer c.mutex.Unlock()
	return c.value
}

func (c *clock) Advance(by time.Duration) {
	c.mutex.Lock()
	defer c.mutex.Unlock()
	c.value = c.value.Add(by)
}

type browserHarness struct {
	*harness
	clock *clock
}

func newBrowserHarness(t *testing.T, adjust func(*Config)) *browserHarness {
	t.Helper()
	h := newHarness(t, func(config *Config) {
		config.PreviewUserIDs = []string{"1", "2"}
		config.BrowserOrigin = browserOrigin
		config.LoginAttempts = 1000
		if adjust != nil {
			adjust(config)
		}
	})
	moment := &clock{value: time.Date(2026, 11, 15, 12, 0, 0, 123456000, time.UTC)}
	h.app.now = moment.Now
	livetest.Exec(t, h.path, `PRAGMA journal_mode=WAL`)
	hash := func(password string) string {
		digest, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.MinCost)
		if err != nil {
			t.Fatal(err)
		}
		return string(digest)
	}
	livetest.Exec(t, h.path, `UPDATE users SET password_digest = ?, role = 1 WHERE id = 1`, hash(alicePassword))
	livetest.Exec(t, h.path, `INSERT INTO users (id, username, name, password_digest) VALUES (2, 'bob', 'Bob', ?)`, hash(bobPassword))
	return &browserHarness{harness: h, clock: moment}
}

type browserClient struct {
	h       *browserHarness
	cookies map[string]string
	account string
}

func (h *browserHarness) client() *browserClient {
	return &browserClient{h: h, cookies: map[string]string{}}
}

func (c *browserClient) send(method, path, body string, headers map[string]string) *httptest.ResponseRecorder {
	c.h.t.Helper()
	request := httptest.NewRequest(method, path, strings.NewReader(body))
	request.RemoteAddr = "127.0.0.1:50000"
	pairs := make([]string, 0, len(c.cookies))
	for name, value := range c.cookies {
		pairs = append(pairs, name+"="+value)
	}
	if len(pairs) > 0 {
		request.Header.Set("Cookie", strings.Join(pairs, "; "))
	}
	if body != "" {
		request.Header.Set("Content-Type", "application/json")
	}
	for name, value := range headers {
		request.Header.Set(name, value)
	}
	recorder := httptest.NewRecorder()
	c.h.app.ServeHTTP(recorder, request)
	for _, cookie := range recorder.Result().Cookies() {
		if cookie.MaxAge < 0 {
			delete(c.cookies, cookie.Name)
		} else {
			c.cookies[cookie.Name] = cookie.Value
		}
	}
	return recorder
}

func decoded(t *testing.T, recorder *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var value map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &value); err != nil {
		t.Fatalf("not json: %q", recorder.Body.String())
	}
	return value
}

func (c *browserClient) bootstrap() (token string, body map[string]any) {
	c.h.t.Helper()
	recorder := c.send(http.MethodGet, "/preview/api/v1/auth/bootstrap", "", nil)
	if recorder.Code != http.StatusOK {
		c.h.t.Fatalf("bootstrap %d %s", recorder.Code, recorder.Body.String())
	}
	body = decoded(c.h.t, recorder)
	token, _ = body["csrf_token"].(string)
	return token, body
}

func (c *browserClient) login(username, password, token string) *httptest.ResponseRecorder {
	payload, _ := json.Marshal(map[string]string{"username": username, "password": password})
	return c.send(http.MethodPost, "/preview/api/v1/auth/login", string(payload), map[string]string{"Origin": browserOrigin, "X-CSRF-Token": token})
}

func (c *browserClient) signIn(username, password string) string {
	c.h.t.Helper()
	token, _ := c.bootstrap()
	recorder := c.login(username, password, token)
	if recorder.Code != http.StatusOK {
		c.h.t.Fatalf("login %d %s", recorder.Code, recorder.Body.String())
	}
	body := decoded(c.h.t, recorder)
	c.account, _ = body["account"].(string)
	return body["csrf_token"].(string)
}

func (c *browserClient) get(path string) *httptest.ResponseRecorder {
	return c.send(http.MethodGet, path, "", map[string]string{"X-Shelfarr-Account": c.account})
}

func (c *browserClient) putStatus(path, token, status string) *httptest.ResponseRecorder {
	return c.send(http.MethodPut, path, `{"status":"`+status+`"}`, map[string]string{"X-Shelfarr-Account": c.account, "Origin": browserOrigin, "X-CSRF-Token": token})
}

func TestTheBrowserPreviewIsOffUnlessAnExplicitWellFormedUserListIsConfigured(t *testing.T) {
	for _, raw := range []string{"", "  ", "abc", "1,,2", "0", "01", "1 2", strings.Repeat("1,", 100) + "1"} {
		ids, wellFormed := ParsePreviewUsers(raw)
		if len(ids) != 0 {
			t.Fatalf("%q configured %v", raw, ids)
		}
		if raw != "" && raw != "  " && wellFormed {
			t.Fatalf("%q reported well formed", raw)
		}
	}
	ids, ok := ParsePreviewUsers(" 7 , 7,12 ")
	if !ok || strings.Join(ids, ",") != "7,12" {
		t.Fatalf("parsed %v %v", ids, ok)
	}
	h := newBrowserHarness(t, func(config *Config) { config.PreviewUserIDs = nil })
	client := h.client()
	for _, target := range []struct{ method, path string }{
		{"GET", "/preview/api/v1/session"}, {"GET", "/preview/api/v1/library"}, {"GET", "/preview/api/v1/continue"}, {"GET", "/preview/api/v1/library/1"},
		{"GET", "/preview/api/v1/auth/bootstrap"}, {"POST", "/preview/api/v1/auth/login"}, {"POST", "/preview/api/v1/auth/logout"}, {"PUT", "/preview/api/v1/library/1/reading_status"},
	} {
		recorder := client.send(target.method, target.path, "", map[string]string{"X-Shelfarr-Account": "1", "Origin": browserOrigin})
		if recorder.Code != http.StatusNotFound || errorCode(t, recorder) != "not_found" {
			t.Fatalf("%s %s answered %d", target.method, target.path, recorder.Code)
		}
	}
	if rows := livetest.Query(t, h.path, `SELECT COUNT(*) FROM sessions`); rows[0][0].(int64) != 0 {
		t.Fatal("a disabled preview created a session")
	}
}

func TestSignedOutAndAccountChangedAnswersMatchTheRailsGuardOrder(t *testing.T) {
	h := newBrowserHarness(t, nil)
	h.addBook(10, "Quiet", 1, h.file("quiet.epub", "x"))
	client := h.client()
	recorder := client.send("GET", "/preview/api/v1/library", "", map[string]string{"X-Shelfarr-Account": "1"})
	if recorder.Code != http.StatusUnauthorized || errorCode(t, recorder) != "signed_out" || recorder.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatalf("signed out %d %s", recorder.Code, recorder.Body.String())
	}
	client.signIn("alice", alicePassword)
	for _, header := range []map[string]string{nil, {"X-Shelfarr-Account": "2"}, {"X-Shelfarr-Account": "1, 1"}, {"X-Shelfarr-Account": "01"}} {
		recorder = client.send("GET", "/preview/api/v1/session", "", header)
		if recorder.Code != http.StatusUnauthorized || errorCode(t, recorder) != "account_changed" {
			t.Fatalf("header %v answered %d", header, recorder.Code)
		}
	}
	livetest.Exec(t, h.path, `UPDATE users SET deleted_at = '2026-11-15 11:00:00' WHERE id = 1`)
	recorder = client.get("/preview/api/v1/session")
	if recorder.Code != http.StatusUnauthorized || errorCode(t, recorder) != "signed_out" {
		t.Fatalf("deleted user %d", recorder.Code)
	}
	if rows := livetest.Query(t, h.path, `SELECT COUNT(*) FROM sessions WHERE user_id = 1`); rows[0][0].(int64) != 0 {
		t.Fatal("the deleted user's session row survived, as Rails destroys it")
	}
}

func TestAUserOutsideTheAllowlistIsNotFoundEverywhereAndCannotSignIn(t *testing.T) {
	h := newBrowserHarness(t, func(config *Config) { config.PreviewUserIDs = []string{"1"} })
	client := h.client()
	token, _ := client.bootstrap()
	recorder := client.login("bob", bobPassword, token)
	if recorder.Code != http.StatusUnauthorized || errorCode(t, recorder) != "invalid_credentials" {
		t.Fatalf("nonmember login %d %s", recorder.Code, recorder.Body.String())
	}
	if rows := livetest.Query(t, h.path, `SELECT COUNT(*) FROM sessions`); rows[0][0].(int64) != 0 {
		t.Fatal("a nonmember got a session")
	}
	if rows := livetest.Query(t, h.path, `SELECT failed_login_count FROM users WHERE id = 2`); rows[0][0].(int64) != 0 {
		t.Fatal("a nonmember's state was written")
	}
	livetest.Exec(t, h.path, `INSERT INTO sessions (user_id, created_at, updated_at) VALUES (2, '2026-11-15 11:59:00.000001', '2026-11-15 11:59:00.000001')`)
	cookie, _ := h.app.cookies.GenerateMessage(json.RawMessage("1"), sessionPurpose, h.clock.Now().Add(time.Hour))
	client.cookies[sessionCookieName] = url.QueryEscape(cookie)
	client.account = "2"
	for _, path := range []string{"/preview/api/v1/session", "/preview/api/v1/library", "/preview/api/v1/continue", "/preview/api/v1/library/1", "/preview/api/v1/auth/bootstrap"} {
		recorder = client.get(path)
		if recorder.Code != http.StatusNotFound || errorCode(t, recorder) != "not_found" {
			t.Fatalf("%s answered %d", path, recorder.Code)
		}
	}
}

func TestSessionCookiesAreRefusedWhenTamperedWrongPurposeExpiredOrOversized(t *testing.T) {
	h := newBrowserHarness(t, nil)
	livetest.Exec(t, h.path, `INSERT INTO sessions (id, user_id, created_at, updated_at) VALUES (5, 1, '2026-11-15 11:00:00.000001', '2026-11-15 11:00:00.000001')`)
	good, _ := h.app.cookies.GenerateMessage(json.RawMessage("5"), sessionPurpose, h.clock.Now().Add(time.Hour))
	wrongPurpose, _ := h.app.cookies.GenerateMessage(json.RawMessage("5"), "cookie.other", h.clock.Now().Add(time.Hour))
	expired, _ := h.app.cookies.GenerateMessage(json.RawMessage("5"), sessionPurpose, h.clock.Now())
	stringID, _ := h.app.cookies.GenerateMessage(json.RawMessage(`"5"`), sessionPurpose, h.clock.Now().Add(time.Hour))
	floatID, _ := h.app.cookies.GenerateMessage(json.RawMessage("5.0"), sessionPurpose, h.clock.Now().Add(time.Hour))
	listID, _ := h.app.cookies.GenerateMessage(json.RawMessage("[5]"), sessionPurpose, h.clock.Now().Add(time.Hour))
	other, _ := mustVerifier(t, "another-secret-key-base-another-secret-key-base").GenerateMessage(json.RawMessage("5"), sessionPurpose, h.clock.Now().Add(time.Hour))
	cases := map[string]struct {
		value string
		want  int
	}{
		"valid": {url.QueryEscape(good), 200}, "string id": {url.QueryEscape(stringID), 200}, "wrong purpose": {url.QueryEscape(wrongPurpose), 401},
		"expired envelope": {url.QueryEscape(expired), 401}, "float id": {url.QueryEscape(floatID), 401}, "list id": {url.QueryEscape(listID), 401},
		"other key": {url.QueryEscape(other), 401}, "tampered": {url.QueryEscape(good[:len(good)-2] + "00"), 401}, "unescaped plus": {strings.ReplaceAll(good, "+", "%2B") + "x", 401},
		"empty": {"", 401}, "oversized": {strings.Repeat("A", maxCookieValue+1), 401}, "raw base64 plus": {good, 0},
	}
	for name, test := range cases {
		client := h.client()
		client.cookies[sessionCookieName] = test.value
		client.account = "1"
		recorder := client.get("/preview/api/v1/session")
		if test.want != 0 && recorder.Code != test.want {
			t.Errorf("%s answered %d", name, recorder.Code)
		}
	}
}

func mustVerifier(t *testing.T, secret string) interface {
	GenerateMessage(json.RawMessage, string, time.Time) (string, error)
} {
	t.Helper()
	other := newHarness(t, func(config *Config) { config.SecretKeyBase = secret })
	return other.app.cookies
}

func TestSessionMaxAgeUsesTheSettingWithAnExactBoundaryAndDestroysTheExpiredRow(t *testing.T) {
	h := newBrowserHarness(t, nil)
	livetest.Exec(t, h.path, `INSERT INTO settings (key, value, value_type) VALUES ('session_max_age_days', '7', 'integer')`)
	boundary := h.clock.Now().Add(-7 * 24 * time.Hour)
	for id, created := range map[int]time.Time{1: boundary, 2: boundary.Add(-time.Microsecond), 3: boundary.Add(time.Microsecond)} {
		livetest.Exec(t, h.path, `INSERT INTO sessions (id, user_id, created_at, updated_at) VALUES (?, 1, ?, ?)`, id, live.TimestampText(created), live.TimestampText(created))
	}
	for id, want := range map[int]int{1: 200, 2: 401, 3: 200} {
		cookie, _ := h.app.cookies.GenerateMessage(json.RawMessage(strconv.Itoa(id)), sessionPurpose, h.clock.Now().Add(time.Hour))
		client := h.client()
		client.cookies[sessionCookieName] = url.QueryEscape(cookie)
		client.account = "1"
		recorder := client.get("/preview/api/v1/session")
		if recorder.Code != want {
			t.Fatalf("session %d answered %d, want %d", id, recorder.Code, want)
		}
		if want == 401 && !strings.Contains(recorder.Header().Get("Set-Cookie"), "session_id=;") {
			t.Fatalf("the expired cookie was not cleared: %q", recorder.Header().Get("Set-Cookie"))
		}
	}
	rows := livetest.Query(t, h.path, `SELECT id FROM sessions ORDER BY id`)
	if len(rows) != 2 || rows[0][0].(int64) != 1 || rows[1][0].(int64) != 3 {
		t.Fatalf("remaining sessions %v", rows)
	}
	livetest.Exec(t, h.path, `UPDATE settings SET value = 'seven' WHERE key = 'session_max_age_days'`)
	cookie, _ := h.app.cookies.GenerateMessage(json.RawMessage("1"), sessionPurpose, h.clock.Now().Add(time.Hour))
	client := h.client()
	client.cookies[sessionCookieName] = url.QueryEscape(cookie)
	client.account = "1"
	if recorder := client.get("/preview/api/v1/session"); recorder.Code != http.StatusNotImplemented {
		t.Fatalf("an unreadable setting answered %d, want a refusal, not a silent sign-out or an open door", recorder.Code)
	}
}

func TestAMissingUserBehindAValidSessionIsSignedOutAndTheRowIsKept(t *testing.T) {
	h := newBrowserHarness(t, nil)
	livetest.Exec(t, h.path, `INSERT INTO sessions (id, user_id, created_at, updated_at) VALUES (9, 77, '2026-11-15 11:00:00', '2026-11-15 11:00:00')`)
	cookie, _ := h.app.cookies.GenerateMessage(json.RawMessage("9"), sessionPurpose, h.clock.Now().Add(time.Hour))
	client := h.client()
	client.cookies[sessionCookieName] = url.QueryEscape(cookie)
	client.account = "77"
	if recorder := client.get("/preview/api/v1/session"); recorder.Code != http.StatusUnauthorized {
		t.Fatalf("answered %d", recorder.Code)
	}
	if rows := livetest.Query(t, h.path, `SELECT COUNT(*) FROM sessions WHERE id = 9`); rows[0][0].(int64) != 1 {
		t.Fatal("the unknown user's row was destroyed; Rails would keep it")
	}
}

func TestLoginCreatesARailsShapedSessionAndLogoutRevokesIt(t *testing.T) {
	h := newBrowserHarness(t, nil)
	client := h.client()
	token := client.signIn("alice", alicePassword)
	rows := livetest.Query(t, h.path, `SELECT id, user_id, CAST(created_at AS TEXT), CAST(updated_at AS TEXT), user_agent, ip_address FROM sessions`)
	if len(rows) != 1 || rows[0][1].(int64) != 1 || rows[0][2] != "2026-11-15 12:00:00.123456" || rows[0][3] != rows[0][2] || rows[0][5] != "127.0.0.1" {
		t.Fatalf("session row %v", rows)
	}
	if client.cookies[nonceCookieName] != "" {
		t.Fatal("the login nonce survived the login")
	}
	recorder := client.get("/preview/api/v1/session")
	if recorder.Code != http.StatusOK {
		t.Fatalf("session %d", recorder.Code)
	}
	body := decoded(t, recorder)
	if body["account"].(map[string]any)["id"] != "1" || body["admin"].(map[string]any)["url"] != "/admin" {
		t.Fatalf("body %v", body)
	}
	if recorder = client.send("POST", "/preview/api/v1/auth/logout", "", map[string]string{"X-Shelfarr-Account": "1", "Origin": browserOrigin}); recorder.Code != http.StatusUnprocessableEntity {
		t.Fatalf("logout without a token answered %d", recorder.Code)
	}
	if recorder = client.send("POST", "/preview/api/v1/auth/logout", "", map[string]string{"X-Shelfarr-Account": "2", "Origin": browserOrigin, "X-CSRF-Token": token}); recorder.Code != http.StatusUnauthorized || errorCode(t, recorder) != "account_changed" {
		t.Fatalf("logout for another account answered %d", recorder.Code)
	}
	stale := client.cookies[sessionCookieName]
	if recorder = client.send("POST", "/preview/api/v1/auth/logout", "", map[string]string{"X-Shelfarr-Account": "1", "Origin": browserOrigin, "X-CSRF-Token": token}); recorder.Code != http.StatusOK {
		t.Fatalf("logout answered %d %s", recorder.Code, recorder.Body.String())
	}
	if rows := livetest.Query(t, h.path, `SELECT COUNT(*) FROM sessions`); rows[0][0].(int64) != 0 {
		t.Fatal("logout left the row")
	}
	replay := h.client()
	replay.cookies[sessionCookieName] = stale
	replay.account = "1"
	if recorder = replay.get("/preview/api/v1/session"); recorder.Code != http.StatusUnauthorized {
		t.Fatalf("a revoked cookie answered %d", recorder.Code)
	}
}

func TestCSRFRequiresTheCanonicalOriginASessionBoundTokenAndTheAccountForEveryMutation(t *testing.T) {
	h := newBrowserHarness(t, nil)
	h.addBook(10, "Quiet", 1, h.file("quiet.epub", "x"))
	client := h.client()
	token := client.signIn("alice", alicePassword)
	path := "/preview/api/v1/library/10/reading_status"
	good := map[string]string{"X-Shelfarr-Account": "1", "Origin": browserOrigin, "X-CSRF-Token": token}
	mutate := func(change func(map[string]string)) map[string]string {
		headers := map[string]string{}
		for name, value := range good {
			headers[name] = value
		}
		change(headers)
		return headers
	}
	for name, headers := range map[string]map[string]string{
		"missing token":   mutate(func(m map[string]string) { delete(m, "X-CSRF-Token") }),
		"wrong token":     mutate(func(m map[string]string) { m["X-CSRF-Token"] = token[:len(token)-2] + "AA" }),
		"missing origin":  mutate(func(m map[string]string) { delete(m, "Origin") }),
		"null origin":     mutate(func(m map[string]string) { m["Origin"] = "null" }),
		"cross origin":    mutate(func(m map[string]string) { m["Origin"] = "http://evil.example" }),
		"same host port":  mutate(func(m map[string]string) { m["Origin"] = "http://127.0.0.1:3101" }),
		"cross site":      mutate(func(m map[string]string) { m["Sec-Fetch-Site"] = "cross-site" }),
		"same site only":  mutate(func(m map[string]string) { m["Sec-Fetch-Site"] = "same-site" }),
		"login token":     mutate(func(m map[string]string) { m["X-CSRF-Token"], _ = h.loginToken() }),
		"foreign session": mutate(func(m map[string]string) { m["X-CSRF-Token"] = h.otherSessionToken() }),
	} {
		recorder := client.send("PUT", path, `{"status":"finished"}`, headers)
		if recorder.Code != http.StatusUnprocessableEntity || errorCode(t, recorder) != "invalid_csrf" {
			t.Errorf("%s answered %d %s", name, recorder.Code, recorder.Body.String())
		}
	}
	if recorder := client.send("PUT", path, `{"status":"finished"}`, mutate(func(m map[string]string) { m["X-Shelfarr-Account"] = "2" })); recorder.Code != http.StatusUnauthorized || errorCode(t, recorder) != "account_changed" {
		t.Errorf("stale account answered %d", recorder.Code)
	}
	if rows := livetest.Query(t, h.path, `SELECT COUNT(*) FROM consumer_reading_states`); rows[0][0].(int64) != 0 {
		t.Fatal("a refused request wrote a status")
	}
	same := mutate(func(m map[string]string) { m["Sec-Fetch-Site"] = "same-origin" })
	for repeat := 0; repeat < 2; repeat++ {
		if recorder := client.send("PUT", path, `{"status":"finished"}`, same); recorder.Code != http.StatusOK {
			t.Fatalf("a valid same-origin write answered %d %s", recorder.Code, recorder.Body.String())
		}
	}
	h.clock.Advance(3 * time.Hour)
	if recorder := client.send("PUT", path, `{"status":"unread"}`, good); recorder.Code != http.StatusUnprocessableEntity {
		t.Fatalf("an expired token answered %d", recorder.Code)
	}
	if recorder := client.send("PUT", path, `{"status":"unread"}`, map[string]string{"X-Shelfarr-Account": "1", "Origin": browserOrigin, "Authorization": "Bearer " + authorisedToken()}); recorder.Code != http.StatusUnprocessableEntity {
		t.Fatalf("a bearer token stood in for the token: %d", recorder.Code)
	}
}

func authorisedToken() string { return rawToken }

func (h *browserHarness) loginToken() (string, string) {
	client := h.client()
	token, _ := client.bootstrap()
	return token, client.cookies[nonceCookieName]
}

func (h *browserHarness) otherSessionToken() string {
	client := h.client()
	return client.signIn("bob", bobPassword)
}

func TestLoginCSRFIsBoundToTheBrowsersNonceAndOrigin(t *testing.T) {
	h := newBrowserHarness(t, nil)
	attacker := h.client()
	attackerToken, _ := attacker.bootstrap()
	victim := h.client()
	victimToken, _ := victim.bootstrap()
	check := func(name string, recorder *httptest.ResponseRecorder) {
		t.Helper()
		if recorder.Code != http.StatusUnprocessableEntity || errorCode(t, recorder) != "invalid_csrf" {
			t.Errorf("%s answered %d", name, recorder.Code)
		}
	}
	check("token minted for another browser", victim.login("alice", alicePassword, attackerToken))
	check("no token", victim.login("alice", alicePassword, ""))
	h.clock.Advance(11 * time.Minute)
	check("expired token", victim.login("alice", alicePassword, victimToken))
	fresh := h.client()
	token, _ := fresh.bootstrap()
	payload := `{"username":"alice","password":"` + alicePassword + `"}`
	for name, headers := range map[string]map[string]string{
		"cross origin": {"Origin": "http://evil.example", "X-CSRF-Token": token},
		"null origin":  {"Origin": "null", "X-CSRF-Token": token},
		"no origin":    {"X-CSRF-Token": token},
	} {
		if recorder := fresh.send("POST", "/preview/api/v1/auth/login", payload, headers); recorder.Code != http.StatusUnprocessableEntity {
			t.Errorf("%s answered %d", name, recorder.Code)
		}
	}
	nonceless := h.client()
	nonceless.send("GET", "/preview/api/v1/auth/bootstrap", "", nil)
	delete(nonceless.cookies, nonceCookieName)
	if recorder := nonceless.login("alice", alicePassword, token); recorder.Code != http.StatusUnprocessableEntity {
		t.Errorf("a token without its nonce cookie answered %d", recorder.Code)
	}
	if rows := livetest.Query(t, h.path, `SELECT COUNT(*) FROM sessions`); rows[0][0].(int64) != 0 {
		t.Fatal("a refused login created a session")
	}
	if recorder := fresh.login("alice", alicePassword, token); recorder.Code != http.StatusOK {
		t.Fatalf("the genuine login answered %d %s", recorder.Code, recorder.Body.String())
	}
}

func TestLoginRefusesUnportedModesWithoutCreatingASession(t *testing.T) {
	h := newBrowserHarness(t, nil)
	livetest.Exec(t, h.path, `UPDATE users SET otp_required = 1, otp_secret = 'ciphertext' WHERE id = 2`)
	client := h.client()
	token, _ := client.bootstrap()
	if recorder := client.login("bob", bobPassword, token); recorder.Code != http.StatusNotImplemented || errorCode(t, recorder) != "mfa_not_supported" {
		t.Fatalf("mfa answered %d %s", recorder.Code, recorder.Body.String())
	}
	if recorder := client.login("bob", "wrong-password-value", token); recorder.Code != http.StatusUnauthorized {
		t.Fatalf("a wrong password for an mfa account answered %d", recorder.Code)
	}
	livetest.Exec(t, h.path, `UPDATE users SET otp_required = 0, otp_secret = NULL, oidc_provider = 'issuer', oidc_uid = 'subject' WHERE id = 2`)
	if recorder := client.login("bob", bobPassword, token); recorder.Code != http.StatusNotImplemented || errorCode(t, recorder) != "oidc_account_not_supported" {
		t.Fatalf("oidc answered %d", recorder.Code)
	}
	livetest.Exec(t, h.path, `INSERT INTO settings (key, value, value_type) VALUES ('auth_disabled', 'true', 'boolean')`)
	_, body := client.bootstrap()
	if body["sign_in"].(map[string]any)["available"] != false || body["sign_in"].(map[string]any)["reason"] != "auth_disabled" {
		t.Fatalf("bootstrap %v", body)
	}
	if recorder := client.login("alice", alicePassword, token); recorder.Code != http.StatusNotImplemented || errorCode(t, recorder) != "sign_in_unsupported" {
		t.Fatalf("passwordless answered %d", recorder.Code)
	}
	livetest.Exec(t, h.path, `UPDATE settings SET value = 'false' WHERE key = 'auth_disabled'`)
	h.app.config.PasswordlessEnv = true
	if recorder := client.login("alice", alicePassword, token); recorder.Code != http.StatusNotImplemented {
		t.Fatalf("DISABLE_AUTH answered %d", recorder.Code)
	}
	h.app.config.PasswordlessEnv = false
	livetest.Exec(t, h.path, `UPDATE settings SET value_type = 'string' WHERE key = 'auth_disabled'`)
	if recorder := client.login("alice", alicePassword, token); recorder.Code != http.StatusNotImplemented || errorCode(t, recorder) != "unsupported_stored_value" {
		t.Fatalf("an ambiguous setting answered %d", recorder.Code)
	}
	if rows := livetest.Query(t, h.path, `SELECT COUNT(*) FROM sessions`); rows[0][0].(int64) != 0 {
		t.Fatal("an unported mode created a session")
	}
}

func TestInvalidCredentialsAreGenericAndLockoutIsAtomic(t *testing.T) {
	h := newBrowserHarness(t, nil)
	client := h.client()
	token, _ := client.bootstrap()
	responses := map[string]string{}
	for name, attempt := range map[string][2]string{"unknown": {"nobody", "x"}, "wrong": {"alice", "wrong-password-value"}, "weird": {"AL ICE", "x"}, "oversize": {"alice", strings.Repeat("a", 73)}} {
		recorder := client.login(attempt[0], attempt[1], token)
		if recorder.Code != http.StatusUnauthorized {
			t.Fatalf("%s answered %d", name, recorder.Code)
		}
		responses[name] = recorder.Body.String()
	}
	if responses["unknown"] != responses["wrong"] || responses["unknown"] != `{"error":"invalid_credentials"}` {
		t.Fatalf("responses differ: %v", responses)
	}
	rows := livetest.Query(t, h.path, `SELECT failed_login_count, last_failed_login_ip, locked_until FROM users WHERE id = 1`)
	if rows[0][0].(int64) != 1 || rows[0][1] != "127.0.0.1" || rows[0][2] != nil {
		t.Fatalf("state %v", rows)
	}
	for attempt := 0; attempt < 4; attempt++ {
		client.login("alice", "wrong-password-value", token)
	}
	rows = livetest.Query(t, h.path, `SELECT failed_login_count, CAST(locked_until AS TEXT) FROM users WHERE id = 1`)
	if rows[0][0].(int64) != 5 || rows[0][1] != "2026-11-15 12:15:00.123456" {
		t.Fatalf("locked state %v", rows)
	}
	if recorder := client.login("alice", alicePassword, token); recorder.Code != http.StatusUnauthorized || recorder.Body.String() != `{"error":"invalid_credentials"}` {
		t.Fatalf("a locked account with the right password answered %d %s", recorder.Code, recorder.Body.String())
	}
	if rows = livetest.Query(t, h.path, `SELECT failed_login_count FROM users WHERE id = 1`); rows[0][0].(int64) != 5 {
		t.Fatal("a locked account kept counting")
	}
	h.clock.Advance(15*time.Minute + time.Second)
	fresh := h.client()
	if recorder := fresh.login("alice", alicePassword, func() string { token, _ := fresh.bootstrap(); return token }()); recorder.Code != http.StatusOK {
		t.Fatalf("after the lock expired: %d", recorder.Code)
	}
	if rows = livetest.Query(t, h.path, `SELECT failed_login_count, locked_until, last_failed_login_at, last_failed_login_ip FROM users WHERE id = 1`); rows[0][0].(int64) != 0 || rows[0][1] != nil || rows[0][2] != nil || rows[0][3] != nil {
		t.Fatalf("success did not reset the counters: %v", rows)
	}
	logs := h.logs.String()
	for _, secret := range []string{alicePassword, bobPassword, "wrong-password-value", "alice", token} {
		if strings.Contains(logs, secret) {
			t.Fatalf("the logs contain %q", secret)
		}
	}
}

func TestLoginIsRateLimitedAndBoundsConcurrentPasswordChecks(t *testing.T) {
	h := newBrowserHarness(t, func(config *Config) {
		config.LoginAttempts = 3
		config.MaxLoginWorkers = 1
		config.LoginWait = 50 * time.Millisecond
	})
	client := h.client()
	token, _ := client.bootstrap()
	for attempt := 0; attempt < 3; attempt++ {
		if recorder := client.login("nobody", "x", token); recorder.Code != http.StatusUnauthorized {
			t.Fatalf("attempt %d answered %d", attempt, recorder.Code)
		}
	}
	recorder := client.login("alice", alicePassword, token)
	if recorder.Code != http.StatusTooManyRequests || recorder.Header().Get("Retry-After") == "" || errorCode(t, recorder) != "rate_limited" {
		t.Fatalf("answered %d %v", recorder.Code, recorder.Header())
	}
	h.clock.Advance(3*time.Minute + time.Second)
	if recorder = client.login("alice", alicePassword, token); recorder.Code != http.StatusOK {
		t.Fatalf("after the window: %d", recorder.Code)
	}
	if !h.app.limiter.Acquire(t.Context(), time.Second) {
		t.Fatal("no worker slot")
	}
	defer h.app.limiter.Release()
	other := h.client()
	otherToken, _ := other.bootstrap()
	if recorder = other.login("alice", alicePassword, otherToken); recorder.Code != http.StatusServiceUnavailable || recorder.Header().Get("Retry-After") == "" {
		t.Fatalf("a full worker pool answered %d", recorder.Code)
	}
}

func TestLoginBodiesAreBoundedAndTyped(t *testing.T) {
	h := newBrowserHarness(t, nil)
	client := h.client()
	token, _ := client.bootstrap()
	headers := map[string]string{"Origin": browserOrigin, "X-CSRF-Token": token}
	for name, test := range map[string]struct {
		body string
		want int
	}{
		"not json": {"{", 400}, "array": {"[]", 400}, "missing password": {`{"username":"alice"}`, 400}, "number password": {`{"username":"alice","password":1}`, 400},
		"oversized": {`{"username":"alice","password":"` + strings.Repeat("a", maxLoginBody) + `"}`, 413}, "empty": {"", 400},
	} {
		if recorder := client.send("POST", "/preview/api/v1/auth/login", test.body, headers); recorder.Code != test.want {
			t.Errorf("%s answered %d", name, recorder.Code)
		}
	}
	headers["Content-Type"] = "text/plain"
	if recorder := client.send("POST", "/preview/api/v1/auth/login", `{"username":"alice","password":"x"}`, headers); recorder.Code != http.StatusUnsupportedMediaType {
		t.Errorf("text/plain answered %d", recorder.Code)
	}
}

func TestLoginWhileSignedInIsRefusedAndAnUnknownSessionCookieIsIgnoredNotAdopted(t *testing.T) {
	h := newBrowserHarness(t, nil)
	client := h.client()
	client.signIn("alice", alicePassword)
	token, _ := client.bootstrap()
	if recorder := client.login("bob", bobPassword, token); recorder.Code != http.StatusUnprocessableEntity && recorder.Code != http.StatusConflict {
		t.Fatalf("login over a session answered %d", recorder.Code)
	}
	planted := h.client()
	forged, _ := h.app.cookies.GenerateMessage(json.RawMessage("4242"), sessionPurpose, h.clock.Now().Add(time.Hour))
	planted.cookies[sessionCookieName] = url.QueryEscape(forged)
	planted.signIn("bob", bobPassword)
	if planted.cookies[sessionCookieName] == url.QueryEscape(forged) {
		t.Fatal("the planted session id survived the login")
	}
	if rows := livetest.Query(t, h.path, `SELECT COUNT(*) FROM sessions WHERE id = 4242`); rows[0][0].(int64) != 0 {
		t.Fatal("a planted id became a session")
	}
}

func TestOnlyTheBrowserRoutesReadCookiesAndOnlyTheNativeRoutesReadBearers(t *testing.T) {
	h := newBrowserHarness(t, nil)
	h.addBook(10, "Quiet", 1, h.file("quiet.epub", "x"))
	client := h.client()
	client.signIn("alice", alicePassword)
	cookie := client.cookies[sessionCookieName]
	native := h.client()
	native.cookies[sessionCookieName] = cookie
	if recorder := native.send("GET", "/api/consumer/v1/me", "", nil); recorder.Code != http.StatusUnauthorized {
		t.Fatalf("a cookie authenticated the native API: %d", recorder.Code)
	}
	bearerOnly := h.client()
	if recorder := bearerOnly.send("GET", "/preview/api/v1/library", "", map[string]string{"Authorization": "Bearer " + rawToken, "X-Shelfarr-Account": "1"}); recorder.Code != http.StatusUnauthorized {
		t.Fatalf("a bearer token authenticated the browser API: %d", recorder.Code)
	}
	if recorder := client.send("OPTIONS", "/preview/api/v1/library", "", map[string]string{"Origin": "http://evil.example", "Access-Control-Request-Method": "GET"}); recorder.Code != http.StatusMethodNotAllowed || recorder.Header().Get("Access-Control-Allow-Origin") != "" || recorder.Header().Get("Access-Control-Allow-Credentials") != "" {
		t.Fatalf("preflight answered %d %v", recorder.Code, recorder.Header())
	}
	if recorder := client.get("/preview/api/v1/library"); recorder.Header().Get("Access-Control-Allow-Origin") != "" {
		t.Fatal("a CORS header was sent")
	}
}

func TestSecureCookiesFollowTheConfiguredScheme(t *testing.T) {
	h := newBrowserHarness(t, func(config *Config) { config.BrowserOrigin = "https://shelf.example.test" })
	client := h.client()
	token, _ := client.bootstrap()
	recorder := client.send("POST", "/preview/api/v1/auth/login", `{"username":"alice","password":"`+alicePassword+`"}`, map[string]string{"Origin": "https://shelf.example.test", "X-CSRF-Token": token})
	if recorder.Code != http.StatusOK {
		t.Fatalf("answered %d %s", recorder.Code, recorder.Body.String())
	}
	for _, line := range recorder.Result().Header.Values("Set-Cookie") {
		if !strings.Contains(line, "Secure") || !strings.Contains(line, "HttpOnly") {
			t.Fatalf("cookie without the flags: %q", line)
		}
		if strings.HasPrefix(line, "session_id=") && (!strings.Contains(line, "SameSite=Lax") || !strings.Contains(line, "Path=/;") || strings.Contains(line, "Max-Age")) {
			t.Fatalf("session cookie %q", line)
		}
	}
	for _, origin := range []string{"http://127.0.0.1:80", "https://Shelf.Example.test:443", "https://shelf.example.test/", "https://shelf.example.test/sub", "ftp://x", "https://u@x", "x"} {
		config := Config{BrowserOrigin: origin}
		got, err := CanonicalOrigin(config.BrowserOrigin)
		_ = got
		if origin == "http://127.0.0.1:80" || origin == "https://Shelf.Example.test:443" {
			if err != nil {
				t.Errorf("%q refused", origin)
			}
		} else if err == nil {
			t.Errorf("%q accepted", origin)
		}
	}
}

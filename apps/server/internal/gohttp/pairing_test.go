//go:build linux

package gohttp

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/account"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/devicegrant"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/live"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/livetest"
)

type pairing struct {
	*browserHarness
}

func newPairing(t *testing.T) pairing {
	t.Helper()
	h := newBrowserHarness(t, nil)
	livetest.Exec(t, h.path, `UPDATE users SET role = 0 WHERE id = 1`)
	h.app.auth.Now = h.clock.Now
	return pairing{h}
}

func stamp(value any) any {
	if moment, ok := value.(time.Time); ok {
		return live.TimestampText(moment)
	}
	return value
}

func (p pairing) post(path, body string, headers map[string]string) *httptest.ResponseRecorder {
	p.t.Helper()
	request := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
	request.RemoteAddr = "127.0.0.1:50000"
	request.Header.Set("Content-Type", "application/json")
	for name, value := range headers {
		request.Header.Set(name, value)
	}
	recorder := httptest.NewRecorder()
	p.app.ServeHTTP(recorder, request)
	return recorder
}

func bearerHeader(raw string) map[string]string {
	return map[string]string{"Authorization": "Bearer " + raw}
}

func (p pairing) device(body string, headers map[string]string) (*httptest.ResponseRecorder, map[string]any) {
	p.t.Helper()
	recorder := p.post("/api/consumer/v1/auth/device", body, headers)
	var parsed map[string]any
	json.Unmarshal(recorder.Body.Bytes(), &parsed)
	return recorder, parsed
}

func (p pairing) poll(deviceCode string) (*httptest.ResponseRecorder, map[string]any) {
	p.t.Helper()
	recorder := p.post("/api/consumer/v1/auth/token", `{"device_code":"`+deviceCode+`"}`, nil)
	var parsed map[string]any
	json.Unmarshal(recorder.Body.Bytes(), &parsed)
	return recorder, parsed
}

func (p pairing) seedToken(id int64, userID int64, raw, scopes, key string, extra string) {
	p.t.Helper()
	var keyValue any
	if key != "" {
		keyValue = key
	}
	livetest.Exec(p.t, p.path, `INSERT INTO api_tokens (id, user_id, name, token_digest, token_prefix, scopes, connection_key, issued_via, created_at, updated_at) VALUES (?, ?, 'seed', ?, ?, ?, ?, 'consumer_device', '2026-11-14 00:00:00', '2026-11-14 00:00:00')`, id, userID, account.TokenDigest(raw), raw[:12], scopes, keyValue)
	if extra != "" {
		livetest.Exec(p.t, p.path, `UPDATE api_tokens SET `+extra+` WHERE id = ?`, id)
	}
}

func (p pairing) consent(userCode, decision string, client *browserClient, token string) *httptest.ResponseRecorder {
	payload, _ := json.Marshal(map[string]string{"user_code": userCode, "decision": decision})
	return client.send(http.MethodPost, "/preview/api/v1/connect", string(payload), map[string]string{"X-Shelfarr-Account": client.account, "Origin": browserOrigin, "X-CSRF-Token": token})
}

func TestDeviceCreationAnswersTheRailsShapeAndStoresOnlyDigests(t *testing.T) {
	p := newPairing(t)
	recorder, body := p.device(`{"client_name":"  Reader App  "}`, map[string]string{"Host": "attacker.example", "X-Forwarded-Host": "attacker.example", "X-Forwarded-Proto": "https", "Forwarded": "host=attacker.example"})
	if recorder.Code != http.StatusOK {
		t.Fatalf("%d %s", recorder.Code, recorder.Body.String())
	}
	if recorder.Header().Get("Cache-Control") != "private, no-store" || recorder.Header().Get("Referrer-Policy") != "no-referrer" {
		t.Fatalf("headers %v", recorder.Header())
	}
	device, user := body["device_code"].(string), body["user_code"].(string)
	if !regexp.MustCompile(`^[0-9a-f]{64}$`).MatchString(device) || !regexp.MustCompile(`^[BCDFGHJKLMNPQRSTVWXYZ23456789]{4}-[BCDFGHJKLMNPQRSTVWXYZ23456789]{4}$`).MatchString(user) {
		t.Fatalf("shapes %q %q", device, user)
	}
	if body["verification_uri"] != browserOrigin+"/consumer/connect" || body["verification_uri_complete"] != browserOrigin+"/consumer/connect?user_code="+user || body["expires_in"] != float64(600) || body["interval"] != float64(5) || len(body) != 6 {
		t.Fatalf("body %v", body)
	}
	rows := livetest.Query(t, p.path, `SELECT user_id, client_name, device_code_digest, user_code_digest, expires_at, approved_at, denied_at, consumed_at, last_polled_at, poll_interval, scopes, replaces_api_token_id, created_at, updated_at FROM consumer_device_grants`)
	if len(rows) != 1 {
		t.Fatalf("rows %v", rows)
	}
	row := rows[0]
	for index := range row {
		row[index] = stamp(row[index])
	}
	if row[0] != nil || row[1] != "Reader App" || row[2] != devicegrant.Digest(device) || row[3] != devicegrant.Digest(strings.ReplaceAll(user, "-", "")) || row[4] != "2026-11-15 12:10:00.123456" || row[9] != int64(5) || row[10] != nil || row[11] != nil || row[12] != "2026-11-15 12:00:00.123456" || row[13] != row[12] {
		t.Fatalf("stored %v", row)
	}
	for _, index := range []int{5, 6, 7, 8} {
		if row[index] != nil {
			t.Fatalf("column %d set: %v", index, row[index])
		}
	}
	if logs := p.logs.String(); strings.Contains(logs, device) || strings.Contains(logs, user) || strings.Contains(logs, strings.ReplaceAll(user, "-", "")) {
		t.Fatalf("a code reached the logs: %s", logs)
	}
}

func TestDeviceCreationNeedsTheConfiguredOriginAndNeverTheHostHeader(t *testing.T) {
	h := newBrowserHarness(t, func(config *Config) { config.BrowserOrigin = "" })
	p := pairing{h}
	recorder, _ := p.device(`{"client_name":"App"}`, map[string]string{"Host": "attacker.example"})
	if recorder.Code != http.StatusNotImplemented || errorCode(t, recorder) != "browser_origin_not_configured" {
		t.Fatalf("%d %s", recorder.Code, recorder.Body.String())
	}
	if rows := livetest.Query(t, p.path, `SELECT COUNT(*) FROM consumer_device_grants`); rows[0][0].(int64) != 0 {
		t.Fatal("a refused request stored a grant")
	}
}

func TestDeviceCreationRefusesBadInputBeforeAnyWrite(t *testing.T) {
	p := newPairing(t)
	p.seedToken(10, 1, "shf_validvalidvalidvalid", `["library:read"]`, "", "")
	for name, test := range map[string]struct {
		body    string
		headers map[string]string
		status  int
		code    string
	}{
		"missing name":      {`{}`, nil, 400, "invalid_request"},
		"empty body":        {``, nil, 400, "invalid_request"},
		"array body":        {`[1]`, nil, 400, "invalid_request"},
		"number name":       {`{"client_name":5}`, nil, 400, "invalid_request"},
		"blank name":        {`{"client_name":"    "}`, nil, 400, "invalid_request"},
		"long name":         {`{"client_name":"` + strings.Repeat("n", 81) + `"}`, nil, 400, "invalid_request"},
		"scope list":        {`{"client_name":"App","scope":["library:read"]}`, nil, 400, "invalid_scope"},
		"privileged scope":  {`{"client_name":"App","scope":"library:read requests:admin"}`, nil, 400, "invalid_scope"},
		"partial bundle":    {`{"client_name":"App","scope":"search:read"}`, nil, 400, "invalid_scope"},
		"malformed json":    {`{"client_name":`, nil, 400, "invalid_json"},
		"wrong media type":  {`client_name=App`, map[string]string{"Content-Type": "application/x-www-form-urlencoded"}, 415, "unsupported_media_type"},
		"oversized body":    {`{"client_name":"App","pad":"` + strings.Repeat("x", 70000) + `"}`, nil, 413, "request_too_large"},
		"name before token": {`{"client_name":5}`, bearerHeader("shf_garbagegarbagegarbage"), 400, "invalid_request"},
	} {
		recorder, _ := p.device(test.body, test.headers)
		if recorder.Code != test.status || errorCode(t, recorder) != test.code {
			t.Errorf("%s: %d %s", name, recorder.Code, recorder.Body.String())
		}
	}
	if rows := livetest.Query(t, p.path, `SELECT COUNT(*) FROM consumer_device_grants`); rows[0][0].(int64) != 0 {
		t.Fatal("a refused request stored a grant")
	}
}

func TestAnAuthorizationHeaderAlwaysRequestsAnUpgradeNeverAFallback(t *testing.T) {
	p := newPairing(t)
	p.seedToken(10, 1, "shf_validvalidvalidvalid", `["library:read","progress:write"]`, "", "")
	p.seedToken(11, 1, "shf_revokedrevokedrevoked", `["library:read"]`, "", "revoked_at = '2026-11-14 01:00:00'")
	p.seedToken(12, 1, "shf_expiredexpiredexpired", `["library:read"]`, "", "expires_at = '2026-11-15 11:00:00'")
	p.seedToken(13, 1, "shf_progressonlyprogress", `["progress:write"]`, "", "")
	p.seedToken(14, 2, "shf_deletedownerdeleted", `["library:read"]`, "", "")
	livetest.Exec(t, p.path, `UPDATE users SET deleted_at = '2026-11-14 00:00:00' WHERE id = 2`)
	livetest.Exec(t, p.path, `INSERT INTO api_tokens (id, user_id, token_digest, scopes) VALUES (15, NULL, ?, '["library:read"]')`, account.TokenDigest("shf_ownerlessownerless"))
	livetest.Exec(t, p.path, `INSERT INTO api_tokens (id, user_id, token_digest, scopes) VALUES (16, 99, ?, '["library:read"]')`, account.TokenDigest("shf_orphanorphanorphan"))
	for name, headers := range map[string]map[string]string{
		"revoked": bearerHeader("shf_revokedrevokedrevoked"), "expired": bearerHeader("shf_expiredexpiredexpired"), "no library scope": bearerHeader("shf_progressonlyprogress"),
		"deleted owner": bearerHeader("shf_deletedownerdeleted"), "ownerless": bearerHeader("shf_ownerlessownerless"), "orphan": bearerHeader("shf_orphanorphanorphan"),
		"unknown": bearerHeader("shf_unknownunknownunknown"), "basic": {"Authorization": "Basic YTpi"}, "bearer alone": {"Authorization": "Bearer"}, "garbage": {"Authorization": "x"},
	} {
		recorder, _ := p.device(`{"client_name":"App","scope":"library:read progress:write search:read requests:read requests:write"}`, headers)
		if recorder.Code != http.StatusUnauthorized || recorder.Body.Len() != 0 {
			t.Errorf("%s: %d %q", name, recorder.Code, recorder.Body.String())
		}
	}
	if rows := livetest.Query(t, p.path, `SELECT COUNT(*) FROM consumer_device_grants`); rows[0][0].(int64) != 0 {
		t.Fatal("a refused upgrade stored a grant")
	}
	for _, blank := range []string{"", "   "} {
		if recorder, _ := p.device(`{"client_name":"App"}`, map[string]string{"Authorization": blank}); recorder.Code != http.StatusOK {
			t.Errorf("a blank Authorization header is no credential: %d", recorder.Code)
		}
	}
	recorder, _ := p.device(`{"client_name":"App","scope":"library:read progress:write search:read requests:read requests:write"}`, bearerHeader("shf_validvalidvalidvalid"))
	if recorder.Code != http.StatusOK {
		t.Fatalf("%d %s", recorder.Code, recorder.Body.String())
	}
	rows := livetest.Query(t, p.path, `SELECT replaces_api_token_id, scopes FROM consumer_device_grants ORDER BY id DESC LIMIT 1`)
	if rows[0][0] != int64(10) || rows[0][1] != `["library:read","progress:write","search:read","requests:read","requests:write"]` {
		t.Fatalf("upgrade grant %v", rows[0])
	}
	if used := livetest.Query(t, p.path, `SELECT last_used_at FROM api_tokens WHERE id = 10`)[0][0]; used == nil {
		t.Fatal("authenticating the upgrade did not touch the credential as Rails does")
	}
}

func TestTheFullFlowIssuesOneTokenOnceAndAnyReplayIsExpired(t *testing.T) {
	p := newPairing(t)
	_, body := p.device(`{"client_name":"Reader App"}`, nil)
	device, user := body["device_code"].(string), body["user_code"].(string)
	recorder, answer := p.poll(device)
	if recorder.Code != 400 || answer["error"] != "authorization_pending" {
		t.Fatalf("first poll %d %s", recorder.Code, recorder.Body.String())
	}
	if polled := livetest.Query(t, p.path, `SELECT CAST(last_polled_at AS TEXT), poll_interval FROM consumer_device_grants`)[0]; polled[0] != "2026-11-15 12:00:00.123456" || polled[1] != int64(5) {
		t.Fatalf("pending poll was not committed: %v", polled)
	}
	recorder, answer = p.poll(device)
	if recorder.Code != 400 || answer["error"] != "slow_down" {
		t.Fatalf("early poll %d %s", recorder.Code, recorder.Body.String())
	}
	for _, want := range []int64{10, 15, 20} {
		if interval := livetest.Query(t, p.path, `SELECT poll_interval FROM consumer_device_grants`)[0][0]; interval != want {
			t.Fatalf("interval %v want %d", interval, want)
		}
		p.poll(device)
	}
	client := p.client()
	token := client.signIn("alice", alicePassword)
	if recorder := p.consent(user, "allow", client, token); recorder.Code != 200 {
		t.Fatalf("allow %d %s", recorder.Code, recorder.Body.String())
	}
	p.clock.Advance(61 * time.Second)
	recorder, answer = p.poll(device)
	if recorder.Code != 200 || recorder.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatalf("exchange %d %s", recorder.Code, recorder.Body.String())
	}
	raw := answer["access_token"].(string)
	if !regexp.MustCompile(`^shf_[1-9A-HJ-NP-Za-km-z]{40}$`).MatchString(raw) || answer["token_type"] != "Bearer" || answer["scope"] != "library:read progress:write" || answer["expires_in"] != float64(2592000) || len(answer) != 4 {
		t.Fatalf("answer %v", answer)
	}
	stored := livetest.Query(t, p.path, `SELECT user_id, name, scopes, token_digest, token_prefix, expires_at, issued_via, replaces_api_token_id, connection_key, revoked_at, created_at, updated_at FROM api_tokens WHERE issued_via = 'consumer_device'`)
	if len(stored) != 1 || stored[0][0] != int64(1) || stored[0][1] != "Reader App" || stored[0][2] != `["library:read","progress:write"]` || stored[0][3] != account.TokenDigest(raw) || stored[0][4] != raw[:12] || stamp(stored[0][5]) != "2026-12-15 12:01:01.123456" || stored[0][7] != nil || stored[0][9] != nil {
		t.Fatalf("token row %v", stored)
	}
	if !regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`).MatchString(stored[0][8].(string)) {
		t.Fatalf("connection key %v", stored[0][8])
	}
	if used := p.do(http.MethodGet, "/api/consumer/v1/me", bearerHeader(raw)); used.Code != 200 {
		t.Fatalf("the issued token does not work: %d", used.Code)
	}
	for index := 0; index < 3; index++ {
		p.clock.Advance(61 * time.Second)
		recorder, answer = p.poll(device)
		if recorder.Code != 400 || answer["error"] != "expired_token" {
			t.Fatalf("replay %d %s", recorder.Code, recorder.Body.String())
		}
	}
	if count := livetest.Query(t, p.path, `SELECT COUNT(*) FROM api_tokens WHERE issued_via = 'consumer_device'`)[0][0]; count != int64(1) {
		t.Fatalf("%v tokens", count)
	}
	if logs := p.logs.String(); strings.Contains(logs, raw) || strings.Contains(logs, device) || strings.Contains(logs, user) {
		t.Fatal("a secret reached the logs")
	}
}

func TestADeviceGrantNeverGrantsAdministratorEvenToAnAdministrator(t *testing.T) {
	p := newPairing(t)
	livetest.Exec(t, p.path, `UPDATE users SET role = 1 WHERE id = 1`)
	_, body := p.device(`{"client_name":"Admin Phone","scope":"library:read progress:write search:read requests:read requests:write"}`, nil)
	client := p.client()
	token := client.signIn("alice", alicePassword)
	p.consent(body["user_code"].(string), "allow", client, token)
	_, answer := p.poll(body["device_code"].(string))
	if answer["scope"] != "library:read progress:write search:read requests:read requests:write" {
		t.Fatalf("%v", answer)
	}
	me := p.do(http.MethodGet, "/api/consumer/v1/me", bearerHeader(answer["access_token"].(string)))
	var parsed struct {
		Scopes []string `json:"scopes"`
	}
	json.Unmarshal(me.Body.Bytes(), &parsed)
	for _, scope := range parsed.Scopes {
		if scope == "requests:admin" || scope == "users:write" {
			t.Fatalf("administrator scope %s", scope)
		}
	}
}

func TestExpiryDenialAndConsumptionPrecedenceMatchRails(t *testing.T) {
	p := newPairing(t)
	issue := func() (string, string) {
		_, body := p.device(`{"client_name":"App"}`, nil)
		return body["device_code"].(string), body["user_code"].(string)
	}
	device, user := issue()
	client := p.client()
	token := client.signIn("alice", alicePassword)
	p.consent(user, "deny", client, token)
	if recorder, answer := p.poll(device); recorder.Code != 400 || answer["error"] != "access_denied" {
		t.Fatalf("denied: %s", recorder.Body.String())
	}
	if rows := livetest.Query(t, p.path, `SELECT consumed_at FROM consumer_device_grants WHERE device_code_digest = ?`, devicegrant.Digest(device)); rows[0][0] != nil {
		t.Fatal("a denied grant must not be consumed")
	}
	p.clock.Advance(10*time.Minute - time.Microsecond)
	if _, answer := p.poll(device); answer["error"] != "access_denied" {
		t.Fatalf("one microsecond before expiry: %v", answer)
	}
	p.clock.Advance(time.Microsecond)
	if _, answer := p.poll(device); answer["error"] != "expired_token" {
		t.Fatalf("exact expiry instant must be expired: %v", answer)
	}
	deleted, deletedUser := issue()
	p.consent(deletedUser, "allow", client, token)
	livetest.Exec(t, p.path, `UPDATE users SET deleted_at = '2026-11-15 12:00:00' WHERE id = 1`)
	if _, answer := p.poll(deleted); answer["error"] != "access_denied" {
		t.Fatalf("deleted approver: %v", answer)
	}
	if count := livetest.Query(t, p.path, `SELECT COUNT(*) FROM api_tokens WHERE issued_via = 'consumer_device'`)[0][0]; count != int64(0) {
		t.Fatal("a token was issued for a deleted account")
	}
	if _, answer := p.poll("not-a-code"); answer["error"] != "expired_token" {
		t.Fatalf("garbage code: %v", answer)
	}
	if _, answer := p.poll(strings.Repeat("0", 64)); answer["error"] != "expired_token" {
		t.Fatalf("unknown code: %v", answer)
	}
	if _, answer := p.poll(strings.ToUpper(device)); answer["error"] != "expired_token" {
		t.Fatalf("uppercase code: %v", answer)
	}
	for _, body := range []string{`{}`, `{"device_code":5}`, `{"device_code":null}`, `{"device_code":["x"]}`, ``, `[1]`} {
		recorder := p.post("/api/consumer/v1/auth/token", body, nil)
		if recorder.Code != 400 || errorCode(t, recorder) != "expired_token" {
			t.Errorf("%s: %d %s", body, recorder.Code, recorder.Body.String())
		}
	}
}

func TestTheIntervalGrowsToSixtyAndPendingPollsDoNotGrowIt(t *testing.T) {
	p := newPairing(t)
	_, body := p.device(`{"client_name":"App"}`, nil)
	device := body["device_code"].(string)
	p.poll(device)
	for index := 0; index < 14; index++ {
		p.poll(device)
	}
	if interval := livetest.Query(t, p.path, `SELECT poll_interval FROM consumer_device_grants`)[0][0]; interval != int64(60) {
		t.Fatalf("interval %v", interval)
	}
	p.clock.Advance(60*time.Second + time.Microsecond)
	if recorder, answer := p.poll(device); recorder.Code != 400 || answer["error"] != "authorization_pending" {
		t.Fatalf("a polite poll after backoff: %s", recorder.Body.String())
	}
	if interval := livetest.Query(t, p.path, `SELECT poll_interval FROM consumer_device_grants`)[0][0]; interval != int64(60) {
		t.Fatalf("interval %v", interval)
	}
	p.clock.Advance(60*time.Second - time.Microsecond)
	if _, answer := p.poll(device); answer["error"] != "slow_down" {
		t.Fatalf("a poll one microsecond early: %v", answer)
	}
	p.clock.Advance(60*time.Second + time.Second)
	if _, answer := p.poll(device); answer["error"] != "authorization_pending" {
		t.Fatalf("a poll after the (now 60 second) interval: %v", answer)
	}
	p.clock.Advance(60 * time.Second)
	if _, answer := p.poll(device); answer["error"] != "authorization_pending" {
		t.Fatalf("a poll exactly at the interval is on time in Rails: %v", answer)
	}
}

func TestUpgradeKeepsTheOldCredentialUntilTheNewOneIsUsedAndRevokeEndsTheWholeFamily(t *testing.T) {
	p := newPairing(t)
	p.seedToken(10, 1, "shf_originaloriginaloriginal", `["library:read","progress:write"]`, "", "")
	_, body := p.device(`{"client_name":"App","scope":"library:read progress:write search:read requests:read requests:write"}`, bearerHeader("shf_originaloriginaloriginal"))
	device, user := body["device_code"].(string), body["user_code"].(string)
	wrong := p.client()
	wrongToken := wrong.signIn("bob", bobPassword)
	recorder := p.consent(user, "allow", wrong, wrongToken)
	if recorder.Code != http.StatusForbidden || errorCode(t, recorder) != "different_account" {
		t.Fatalf("other account: %d %s", recorder.Code, recorder.Body.String())
	}
	if grant := livetest.Query(t, p.path, `SELECT user_id, approved_at, denied_at FROM consumer_device_grants`)[0]; grant[0] != nil || grant[1] != nil || grant[2] != nil {
		t.Fatalf("a different account changed the grant: %v", grant)
	}
	owner := p.client()
	ownerToken := owner.signIn("alice", alicePassword)
	if recorder := p.consent(user, "allow", owner, ownerToken); recorder.Code != 200 {
		t.Fatalf("owner: %d %s", recorder.Code, recorder.Body.String())
	}
	p.clock.Advance(10 * time.Second)
	recorder, answer := p.poll(device)
	if recorder.Code != 200 {
		t.Fatalf("%s", recorder.Body.String())
	}
	fresh := answer["access_token"].(string)
	keys := livetest.Query(t, p.path, `SELECT id, connection_key, replaces_api_token_id, revoked_at FROM api_tokens WHERE id >= 10 ORDER BY id`)
	if keys[0][1] == nil || keys[0][1] != keys[1][1] || keys[1][2] != int64(10) || keys[0][3] != nil {
		t.Fatalf("lineage %v", keys)
	}
	if code := p.do(http.MethodGet, "/api/consumer/v1/me", bearerHeader("shf_originaloriginaloriginal")).Code; code != 200 {
		t.Fatalf("the old credential must work until the new one is used: %d", code)
	}
	if code := p.do(http.MethodGet, "/api/consumer/v1/me", bearerHeader(fresh)).Code; code != 200 {
		t.Fatalf("new credential %d", code)
	}
	if code := p.do(http.MethodGet, "/api/consumer/v1/me", bearerHeader("shf_originaloriginaloriginal")).Code; code != 401 {
		t.Fatalf("adoption retires the old credential: %d", code)
	}
	if revoked := livetest.Query(t, p.path, `SELECT revoked_at FROM api_tokens WHERE id = 1`)[0][0]; revoked != nil {
		t.Fatalf("adopting the replacement must not revoke it: %v", revoked)
	}
	_, pendingUpgrade := p.device(`{"client_name":"App","scope":"library:read progress:write search:read requests:read requests:write"}`, bearerHeader(fresh))
	revoke := p.post("/api/consumer/v1/auth/revoke", `{}`, bearerHeader(fresh))
	if revoke.Code != http.StatusNoContent || revoke.Body.Len() != 0 || revoke.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatalf("revoke %d %q", revoke.Code, revoke.Body.String())
	}
	if code := p.do(http.MethodGet, "/api/consumer/v1/me", bearerHeader(fresh)).Code; code != 401 {
		t.Fatalf("revoked %d", code)
	}
	if denied := livetest.Query(t, p.path, `SELECT denied_at FROM consumer_device_grants WHERE device_code_digest = ?`, devicegrant.Digest(pendingUpgrade["device_code"].(string)))[0][0]; denied == nil {
		t.Fatal("explicit revoke must deny an unconsumed upgrade of the same connection")
	}
	if _, answer := p.poll(pendingUpgrade["device_code"].(string)); answer["error"] != "access_denied" {
		t.Fatalf("%v", answer)
	}
}

func TestRevokeStaysInsideTheOwnersConnectionAndKeepsLegacyTokensAlone(t *testing.T) {
	p := newPairing(t)
	p.seedToken(10, 1, "shf_familyonefamilyone1", `["library:read"]`, "key-a", "")
	p.seedToken(11, 1, "shf_familyonefamilyone2", `["progress:write"]`, "key-a", "")
	p.seedToken(12, 2, "shf_otheraccountsamekey", `["library:read"]`, "key-a", "")
	p.seedToken(13, 1, "shf_sameownerotherkey1", `["library:read"]`, "key-b", "")
	p.seedToken(14, 1, "shf_legacyblankkeyone1", `["library:read"]`, "", "")
	p.seedToken(15, 1, "shf_legacyblankkeytwo2", `["library:read"]`, "", "")
	p.seedToken(16, 1, "shf_whitespacekeytoken", `["library:read"]`, "  ", "")
	p.seedToken(17, 1, "shf_whitespacekeytwo22", `["library:read"]`, "  ", "")
	revoked := func() []int64 {
		var ids []int64
		for _, row := range livetest.Query(t, p.path, `SELECT id FROM api_tokens WHERE revoked_at IS NOT NULL ORDER BY id`) {
			ids = append(ids, row[0].(int64))
		}
		return ids
	}
	if recorder := p.post("/api/consumer/v1/auth/revoke", `{}`, bearerHeader("shf_familyonefamilyone2")); recorder.Code != 204 {
		t.Fatalf("a token without library:read can still revoke: %d", recorder.Code)
	}
	if got := revoked(); len(got) != 2 || got[0] != 10 || got[1] != 11 {
		t.Fatalf("family %v", got)
	}
	p.post("/api/consumer/v1/auth/revoke", `{}`, bearerHeader("shf_legacyblankkeyone1"))
	p.post("/api/consumer/v1/auth/revoke", `{}`, bearerHeader("shf_whitespacekeytoken"))
	if got := revoked(); len(got) != 4 || got[2] != 14 || got[3] != 16 {
		t.Fatalf("a blank connection key revokes the token alone: %v", got)
	}
	if code := p.post("/api/consumer/v1/auth/revoke", `{}`, nil).Code; code != 401 {
		t.Fatalf("anonymous revoke %d", code)
	}
	if code := p.post("/api/consumer/v1/auth/revoke", `{}`, bearerHeader("shf_familyonefamilyone1")).Code; code != 401 {
		t.Fatalf("an already revoked token cannot revoke %d", code)
	}
	if recorder := p.do(http.MethodGet, "/api/consumer/v1/auth/revoke", bearerHeader("shf_sameownerotherkey1")); recorder.Code != 404 {
		t.Fatalf("GET revoke %d", recorder.Code)
	}
}

func TestPublicEndpointsAreRateLimitedWithRailsCounts(t *testing.T) {
	p := newPairing(t)
	for index := 1; index <= 21; index++ {
		recorder, _ := p.device(`{"client_name":"App"}`, nil)
		want := http.StatusOK
		if index > 20 {
			want = http.StatusTooManyRequests
		}
		if recorder.Code != want {
			t.Fatalf("device %d answered %d", index, recorder.Code)
		}
		if want == http.StatusTooManyRequests && (errorCode(t, recorder) != "slow_down" || recorder.Header().Get("Retry-After") == "") {
			t.Fatalf("limited answer %s", recorder.Body.String())
		}
	}
	for index := 1; index <= 121; index++ {
		recorder := p.post("/api/consumer/v1/auth/token", `{}`, nil)
		want := http.StatusBadRequest
		if index > 120 {
			want = http.StatusTooManyRequests
		}
		if recorder.Code != want {
			t.Fatalf("token %d answered %d", index, recorder.Code)
		}
	}
	p.clock.Advance(4 * time.Minute)
	if recorder, _ := p.device(`{"client_name":"App"}`, nil); recorder.Code != http.StatusOK {
		t.Fatalf("the window did not reopen: %d", recorder.Code)
	}
}

func TestOnlyGrantsExpiredForMoreThanADayAreCleanedUp(t *testing.T) {
	p := newPairing(t)
	insert := func(suffix, expires string) {
		livetest.Exec(t, p.path, `INSERT INTO consumer_device_grants (client_name, device_code_digest, user_code_digest, expires_at, created_at, updated_at) VALUES (?, ?, ?, ?, '2026-11-01 00:00:00', '2026-11-01 00:00:00')`, "old"+suffix, "d"+suffix, "u"+suffix, expires)
	}
	insert("1", "2026-11-14 11:59:59.999999")
	insert("2", "2026-11-14 12:00:00.123456")
	insert("3", "2026-11-14 12:00:00.123457")
	insert("4", "2026-11-16 00:00:00")
	p.device(`{"client_name":"App"}`, nil)
	var kept []string
	for _, row := range livetest.Query(t, p.path, `SELECT client_name FROM consumer_device_grants WHERE client_name LIKE 'old%' ORDER BY id`) {
		kept = append(kept, row[0].(string))
	}
	if strings.Join(kept, ",") != "old2,old3,old4" {
		t.Fatalf("kept %v", kept)
	}
}

func TestCodeCollisionsAreRetriedAndExhaustionLeavesNothingBehind(t *testing.T) {
	p := newPairing(t)
	first, err := devicegrant.NewCodes(devicegrant.RandomSource())
	if err != nil {
		t.Fatal(err)
	}
	second, _ := devicegrant.NewCodes(devicegrant.RandomSource())
	calls := 0
	p.app.grants.Codes = func() (devicegrant.Codes, error) {
		calls++
		if calls <= 1 || calls == 2 {
			return first, nil
		}
		return second, nil
	}
	if recorder, _ := p.device(`{"client_name":"One"}`, nil); recorder.Code != 200 {
		t.Fatalf("%d", recorder.Code)
	}
	calls = 0
	if recorder, body := p.device(`{"client_name":"Two"}`, nil); recorder.Code != 200 || body["device_code"] != second.Device {
		t.Fatalf("a collision was not retried: %d %s", recorder.Code, recorder.Body.String())
	}
	p.app.grants.Codes = func() (devicegrant.Codes, error) { return first, nil }
	recorder, _ := p.device(`{"client_name":"Three"}`, nil)
	if recorder.Code != 500 || errorCode(t, recorder) != "internal_error" {
		t.Fatalf("exhaustion %d %s", recorder.Code, recorder.Body.String())
	}
	if rows := livetest.Query(t, p.path, `SELECT COUNT(*) FROM consumer_device_grants`); rows[0][0].(int64) != 2 {
		t.Fatalf("grants %v", rows)
	}
	p.app.grants.Codes = func() (devicegrant.Codes, error) { return devicegrant.Codes{}, devicegrant.ErrRandom }
	if recorder, _ := p.device(`{"client_name":"Four"}`, nil); recorder.Code != 500 {
		t.Fatalf("random failure %d", recorder.Code)
	}
	if !strings.Contains(p.logs.String(), `"event":"pairing.entropy_failed"`) {
		t.Fatal("an entropy failure must be visible to the operator")
	}
}

func TestARandomFailureDuringExchangeConsumesNothingAndALaterPollSucceeds(t *testing.T) {
	p := newPairing(t)
	_, body := p.device(`{"client_name":"App"}`, nil)
	client := p.client()
	token := client.signIn("alice", alicePassword)
	p.consent(body["user_code"].(string), "allow", client, token)
	good := p.app.grants.AccessToken
	p.app.grants.AccessToken = func() (string, error) { return "", devicegrant.ErrRandom }
	p.clock.Advance(10 * time.Second)
	if recorder, _ := p.poll(body["device_code"].(string)); recorder.Code != 500 || errorCode(t, recorder) != "internal_error" {
		t.Fatalf("%d %s", recorder.Code, recorder.Body.String())
	}
	if rows := livetest.Query(t, p.path, `SELECT consumed_at FROM consumer_device_grants`); rows[0][0] != nil {
		t.Fatal("a failed issue consumed the grant")
	}
	if count := livetest.Query(t, p.path, `SELECT COUNT(*) FROM api_tokens WHERE issued_via = 'consumer_device'`)[0][0]; count != int64(0) {
		t.Fatal("a failed issue left a token")
	}
	p.app.grants.AccessToken = good
	p.clock.Advance(10 * time.Second)
	if recorder, _ := p.poll(body["device_code"].(string)); recorder.Code != 200 {
		t.Fatalf("%d", recorder.Code)
	}
}

func TestConsentJSONGuardsEveryDecision(t *testing.T) {
	p := newPairing(t)
	_, body := p.device(`{"client_name":"Reader"}`, nil)
	user := body["user_code"].(string)
	anonymous := p.client()
	if recorder := anonymous.send(http.MethodGet, "/preview/api/v1/connect?user_code="+user, "", map[string]string{"X-Shelfarr-Account": "1"}); recorder.Code != 401 || errorCode(t, recorder) != "signed_out" {
		t.Fatalf("anonymous inspect %d", recorder.Code)
	}
	client := p.client()
	token := client.signIn("alice", alicePassword)
	inspect := client.get("/preview/api/v1/connect?user_code=" + strings.ToLower(user))
	var seen struct {
		Account string `json:"account"`
		Name    string `json:"account_name"`
		Grant   *struct {
			Pending    bool     `json:"pending"`
			Decidable  bool     `json:"decidable"`
			ClientName string   `json:"client_name"`
			Upgrade    bool     `json:"upgrade"`
			Requesting bool     `json:"requesting"`
			Scopes     []string `json:"scopes"`
			ExpiresAt  string   `json:"expires_at"`
		} `json:"grant"`
	}
	json.Unmarshal(inspect.Body.Bytes(), &seen)
	if inspect.Code != 200 || seen.Account != "1" || seen.Name != "Alice" || seen.Grant == nil || !seen.Grant.Decidable || seen.Grant.ClientName != "Reader" || seen.Grant.Upgrade || seen.Grant.Requesting || strings.Join(seen.Grant.Scopes, " ") != "library:read progress:write" || seen.Grant.ExpiresAt != "2026-11-15T12:10:00.123Z" {
		t.Fatalf("inspect %d %s", inspect.Code, inspect.Body.String())
	}
	if grant := livetest.Query(t, p.path, `SELECT user_id, approved_at, denied_at FROM consumer_device_grants`)[0]; grant[0] != nil || grant[1] != nil || grant[2] != nil {
		t.Fatalf("inspection decided the grant: %v", grant)
	}
	head := client.send(http.MethodHead, "/preview/api/v1/connect?user_code="+user, "", map[string]string{"X-Shelfarr-Account": "1"})
	if head.Code != 200 || livetest.Query(t, p.path, `SELECT approved_at FROM consumer_device_grants`)[0][0] != nil {
		t.Fatal("HEAD must never decide")
	}
	payload := `{"user_code":"` + user + `","decision":"allow"}`
	for name, test := range map[string]struct {
		headers map[string]string
		status  int
		code    string
	}{
		"no csrf":      {map[string]string{"X-Shelfarr-Account": "1", "Origin": browserOrigin}, 422, "invalid_csrf"},
		"wrong csrf":   {map[string]string{"X-Shelfarr-Account": "1", "Origin": browserOrigin, "X-CSRF-Token": "v1.s.1.AAAA"}, 422, "invalid_csrf"},
		"no origin":    {map[string]string{"X-Shelfarr-Account": "1", "X-CSRF-Token": token}, 422, "invalid_csrf"},
		"null origin":  {map[string]string{"X-Shelfarr-Account": "1", "Origin": "null", "X-CSRF-Token": token}, 422, "invalid_csrf"},
		"other origin": {map[string]string{"X-Shelfarr-Account": "1", "Origin": "http://evil.example", "X-CSRF-Token": token}, 422, "invalid_csrf"},
		"cross site":   {map[string]string{"X-Shelfarr-Account": "1", "Origin": browserOrigin, "Sec-Fetch-Site": "cross-site", "X-CSRF-Token": token}, 422, "invalid_csrf"},
		"no account":   {map[string]string{"Origin": browserOrigin, "X-CSRF-Token": token}, 401, "account_changed"},
		"other acount": {map[string]string{"X-Shelfarr-Account": "2", "Origin": browserOrigin, "X-CSRF-Token": token}, 401, "account_changed"},
	} {
		recorder := client.send(http.MethodPost, "/preview/api/v1/connect", payload, test.headers)
		if recorder.Code != test.status || errorCode(t, recorder) != test.code {
			t.Errorf("%s: %d %s", name, recorder.Code, recorder.Body.String())
		}
	}
	if grant := livetest.Query(t, p.path, `SELECT user_id, approved_at, denied_at FROM consumer_device_grants`)[0]; grant[0] != nil || grant[1] != nil || grant[2] != nil {
		t.Fatalf("a refused request decided the grant: %v", grant)
	}
	good := map[string]string{"X-Shelfarr-Account": "1", "Origin": browserOrigin, "X-CSRF-Token": token}
	for name, test := range map[string]struct {
		body   string
		status int
		code   string
	}{
		"bad decision": {`{"user_code":"` + user + `","decision":"maybe"}`, 400, "invalid_request"},
		"no decision":  {`{"user_code":"` + user + `"}`, 400, "invalid_request"},
		"bad code":     {`{"user_code":"AAAA-AAAA","decision":"allow"}`, 422, "invalid_grant"},
		"unknown code": {`{"user_code":"BCDF-GHJK","decision":"allow"}`, 422, "invalid_grant"},
		"no code":      {`{"decision":"allow"}`, 422, "invalid_grant"},
		"code number":  {`{"user_code":12345678,"decision":"allow"}`, 422, "invalid_grant"},
		"malformed":    {`{`, 400, "invalid_json"},
	} {
		recorder := client.send(http.MethodPost, "/preview/api/v1/connect", test.body, good)
		if recorder.Code != test.status || errorCode(t, recorder) != test.code {
			t.Errorf("%s: %d %s", name, recorder.Code, recorder.Body.String())
		}
	}
	allowed := client.send(http.MethodPost, "/preview/api/v1/connect", payload, good)
	if allowed.Code != 200 || !strings.Contains(allowed.Body.String(), `"decision":"allowed"`) {
		t.Fatalf("allow %d %s", allowed.Code, allowed.Body.String())
	}
	again := client.send(http.MethodPost, "/preview/api/v1/connect", payload, good)
	if again.Code != 422 || errorCode(t, again) != "invalid_grant" {
		t.Fatalf("a decided grant cannot be decided twice: %d", again.Code)
	}
	if gone := client.get("/preview/api/v1/connect?user_code=" + user); !strings.Contains(gone.Body.String(), `"grant":null`) {
		t.Fatalf("a decided grant is no longer shown: %s", gone.Body.String())
	}
	if put := client.send(http.MethodPut, "/preview/api/v1/connect", payload, good); put.Code != 405 || put.Header().Get("Allow") != "GET, HEAD, POST" {
		t.Fatalf("PUT %d", put.Code)
	}
}

func TestConsentStaysOffForAnAccountOutsideTheAllowlistAndShowsADifferentAccountOnlyAsPending(t *testing.T) {
	p := newPairing(t)
	p.seedToken(10, 1, "shf_originaloriginaloriginal", `["library:read"]`, "", "")
	_, body := p.device(`{"client_name":"Reader","scope":"library:read progress:write search:read requests:read requests:write"}`, bearerHeader("shf_originaloriginaloriginal"))
	user := body["user_code"].(string)
	bob := p.client()
	bobToken := bob.signIn("bob", bobPassword)
	inspect := bob.get("/preview/api/v1/connect?user_code=" + user)
	if inspect.Code != 200 || strings.Contains(inspect.Body.String(), "Reader") || !strings.Contains(inspect.Body.String(), `"decidable":false`) {
		t.Fatalf("another account learned the app's name or could decide: %s", inspect.Body.String())
	}
	if recorder := p.consent(user, "deny", bob, bobToken); recorder.Code != 403 {
		t.Fatalf("%d", recorder.Code)
	}
	alice := p.client()
	aliceToken := alice.signIn("alice", alicePassword)
	view := alice.get("/preview/api/v1/connect?user_code=" + user)
	if !strings.Contains(view.Body.String(), `"upgrade":true`) || !strings.Contains(view.Body.String(), `"requesting":true`) {
		t.Fatalf("%s", view.Body.String())
	}
	livetest.Exec(t, p.path, `UPDATE api_tokens SET revoked_at = '2026-11-15 11:00:00' WHERE id = 10`)
	if recorder := p.consent(user, "allow", alice, aliceToken); recorder.Code != 200 {
		t.Fatalf("Rails lets the owner decide; exchange enforces usability: %d %s", recorder.Code, recorder.Body.String())
	}
	p.clock.Advance(10 * time.Second)
	if _, answer := p.poll(body["device_code"].(string)); answer["error"] != "access_denied" {
		t.Fatalf("%v", answer)
	}
	if consumed := livetest.Query(t, p.path, `SELECT consumed_at FROM consumer_device_grants`)[0][0]; consumed == nil {
		t.Fatal("a refused upgrade is consumed")
	}
	if count := livetest.Query(t, p.path, `SELECT COUNT(*) FROM api_tokens WHERE id > 10`)[0][0]; count != int64(0) {
		t.Fatal("a refused upgrade issued a token")
	}
}

func TestStoredGrantsFromRailsOrOlderCodeRemainReadable(t *testing.T) {
	p := newPairing(t)
	for _, scopes := range []string{"NULL", "''", "'not json'", `'["search:read"]'`, `'"library:read"'`} {
		livetest.Exec(t, p.path, `DELETE FROM consumer_device_grants`)
		code := strings.Repeat("a", 64)
		livetest.Exec(t, p.path, `INSERT INTO consumer_device_grants (user_id, client_name, device_code_digest, user_code_digest, expires_at, approved_at, scopes, created_at, updated_at) VALUES (1, 'Legacy', ?, 'u', '2026-11-15 12:05:00', '2026-11-15 12:00:00', `+scopes+`, '2026-11-15 12:00:00', '2026-11-15 12:00:00')`, devicegrant.Digest(code))
		recorder, answer := p.poll(code)
		if recorder.Code != 200 || answer["scope"] != "library:read progress:write" {
			t.Fatalf("%s: %d %s", scopes, recorder.Code, recorder.Body.String())
		}
	}
	livetest.Exec(t, p.path, `DELETE FROM consumer_device_grants`)
	livetest.Exec(t, p.path, `INSERT INTO consumer_device_grants (user_id, client_name, device_code_digest, user_code_digest, expires_at, approved_at, created_at, updated_at) VALUES (1, 'Corrupt', ?, 'u', 'not a time', '2026-11-15 12:00:00', '2026-11-15 12:00:00', '2026-11-15 12:00:00')`, devicegrant.Digest(strings.Repeat("b", 64)))
	if recorder, _ := p.poll(strings.Repeat("b", 64)); recorder.Code != http.StatusNotImplemented || errorCode(t, recorder) != "unsupported_stored_value" {
		t.Fatalf("a corrupt timestamp must be refused, not guessed: %d %s", recorder.Code, recorder.Body.String())
	}
}

func holdWriteLock(t *testing.T, path string) func() {
	t.Helper()
	database, err := sql.Open("sqlite", "file:"+path+"?_pragma=busy_timeout(5000)")
	if err != nil {
		t.Fatal(err)
	}
	conn, err := database.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := conn.ExecContext(context.Background(), `BEGIN IMMEDIATE`); err != nil {
		t.Fatal(err)
	}
	return func() {
		conn.ExecContext(context.Background(), `ROLLBACK`)
		conn.Close()
		database.Close()
	}
}

func TestABusyDatabaseIsServiceUnavailableNeverUnauthorizedAndWritesNothing(t *testing.T) {
	p := newPairing(t)
	p.seedToken(10, 1, "shf_originaloriginaloriginal", `["library:read"]`, "", "")
	_, body := p.device(`{"client_name":"App"}`, nil)
	release := holdWriteLock(t, p.path)
	defer release()
	for name, recorder := range map[string]*httptest.ResponseRecorder{
		"device": func() *httptest.ResponseRecorder { r, _ := p.device(`{"client_name":"Other"}`, nil); return r }(),
		"token":  func() *httptest.ResponseRecorder { r, _ := p.poll(body["device_code"].(string)); return r }(),
		"revoke": p.post("/api/consumer/v1/auth/revoke", `{}`, bearerHeader("shf_originaloriginaloriginal")),
	} {
		if recorder.Code != http.StatusServiceUnavailable || errorCode(t, recorder) != "database_busy" || recorder.Header().Get("Retry-After") == "" {
			t.Errorf("%s answered %d %s", name, recorder.Code, recorder.Body.String())
		}
	}
	release()
	if rows := livetest.Query(t, p.path, `SELECT COUNT(*) FROM consumer_device_grants`); rows[0][0].(int64) != 1 {
		t.Fatalf("grants %v", rows)
	}
	if polled := livetest.Query(t, p.path, `SELECT last_polled_at FROM consumer_device_grants`)[0][0]; polled != nil {
		t.Fatal("a busy poll left a trace")
	}
}

//go:build linux

package gohttp

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	"golang.org/x/crypto/bcrypt"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/livetest"
)

const newAlicePassword = "Unit-Alice-Changed-Passw0rd"

func (c *browserClient) writeAccount(method, path, token string, body any) *httptest.ResponseRecorder {
	c.h.t.Helper()
	encoded, err := json.Marshal(body)
	if err != nil {
		c.h.t.Fatal(err)
	}
	return c.send(method, path, string(encoded), map[string]string{"X-Shelfarr-Account": c.account, "Origin": browserOrigin, "X-CSRF-Token": token})
}

func (c *browserClient) rename(token, name string) *httptest.ResponseRecorder {
	return c.writeAccount(http.MethodPut, "/preview/api/v1/account/profile", token, map[string]string{"name": name})
}

func (c *browserClient) changePassword(token, current, password, confirmation string) *httptest.ResponseRecorder {
	return c.writeAccount(http.MethodPost, "/preview/api/v1/account/password", token, map[string]string{"current_password": current, "password": password, "password_confirmation": confirmation})
}

func userColumn(t *testing.T, path, column string, id int) string {
	t.Helper()
	rows := livetest.Query(t, path, `SELECT CAST(`+column+` AS TEXT) FROM users WHERE id = ?`, id)
	text, _ := rows[0][0].(string)
	return text
}

func sessionIDs(t *testing.T, path string, userID int) []int64 {
	t.Helper()
	ids := []int64{}
	for _, row := range livetest.Query(t, path, `SELECT id FROM sessions WHERE user_id = ? ORDER BY id`, userID) {
		ids = append(ids, row[0].(int64))
	}
	return ids
}

func fieldErrors(t *testing.T, recorder *httptest.ResponseRecorder) map[string][]string {
	t.Helper()
	var body struct {
		Account string              `json:"account"`
		Error   string              `json:"error"`
		Errors  map[string][]string `json:"errors"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil || recorder.Code != http.StatusUnprocessableEntity || body.Account == "" {
		t.Fatalf("not a validation answer: %d %s", recorder.Code, recorder.Body.String())
	}
	return body.Errors
}

func TestTheAccountProfileIsTheSignedInUsersOwnAndNeedsTheAccountHeader(t *testing.T) {
	h := newBrowserHarness(t, nil)
	client := h.client()
	if recorder := client.send(http.MethodGet, "/preview/api/v1/account", "", map[string]string{"X-Shelfarr-Account": "1"}); recorder.Code != http.StatusUnauthorized || errorCode(t, recorder) != "signed_out" {
		t.Fatalf("signed out %d", recorder.Code)
	}
	client.signIn("alice", alicePassword)
	recorder := client.get("/preview/api/v1/account")
	if recorder.Code != http.StatusOK || recorder.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatalf("account %d %v", recorder.Code, recorder.Header())
	}
	want := map[string]any{"account": "1", "profile": map[string]any{"id": "1", "username": "alice", "name": "Alice"}}
	if got := decoded(t, recorder); !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v", got)
	}
	for _, header := range []map[string]string{nil, {"X-Shelfarr-Account": "2"}, {"X-Shelfarr-Account": "01"}} {
		if recorder := client.send(http.MethodGet, "/preview/api/v1/account", "", header); recorder.Code != http.StatusUnauthorized || errorCode(t, recorder) != "account_changed" {
			t.Fatalf("header %v answered %d", header, recorder.Code)
		}
	}
	for _, target := range []struct{ method, path string }{
		{http.MethodPost, "/preview/api/v1/account"}, {http.MethodGet, "/preview/api/v1/account/profile"}, {http.MethodPatch, "/preview/api/v1/account/profile"},
		{http.MethodGet, "/preview/api/v1/account/password"}, {http.MethodPut, "/preview/api/v1/account/password"},
	} {
		if recorder := client.send(target.method, target.path, "", map[string]string{"X-Shelfarr-Account": "1"}); recorder.Code != http.StatusMethodNotAllowed {
			t.Fatalf("%s %s answered %d", target.method, target.path, recorder.Code)
		}
	}
}

func TestAccountWritesNeedTheSessionTokenOriginAndAccount(t *testing.T) {
	h := newBrowserHarness(t, nil)
	client := h.client()
	token := client.signIn("alice", alicePassword)
	bodies := map[string]string{"/preview/api/v1/account/profile": `{"name":"Mallory"}`, "/preview/api/v1/account/password": `{"current_password":"` + alicePassword + `","password":"` + newAlicePassword + `","password_confirmation":"` + newAlicePassword + `"}`}
	methods := map[string]string{"/preview/api/v1/account/profile": http.MethodPut, "/preview/api/v1/account/password": http.MethodPost}
	digest := userColumn(t, h.path, "password_digest", 1)
	for path, body := range bodies {
		for name, headers := range map[string]map[string]string{
			"no token":      {"X-Shelfarr-Account": "1", "Origin": browserOrigin},
			"bad token":     {"X-Shelfarr-Account": "1", "Origin": browserOrigin, "X-CSRF-Token": token + "x"},
			"other origin":  {"X-Shelfarr-Account": "1", "Origin": "http://evil.test", "X-CSRF-Token": token},
			"cross site":    {"X-Shelfarr-Account": "1", "Origin": browserOrigin, "X-CSRF-Token": token, "Sec-Fetch-Site": "cross-site"},
			"other account": {"X-Shelfarr-Account": "2", "Origin": browserOrigin, "X-CSRF-Token": token},
		} {
			recorder := client.send(methods[path], path, body, headers)
			wanted := http.StatusUnprocessableEntity
			if name == "other account" {
				wanted = http.StatusUnauthorized
			}
			if recorder.Code != wanted {
				t.Fatalf("%s %s answered %d %s", path, name, recorder.Code, recorder.Body.String())
			}
		}
	}
	if userColumn(t, h.path, "name", 1) != "Alice" || userColumn(t, h.path, "password_digest", 1) != digest {
		t.Fatal("a refused write changed the account")
	}
	anonymous := h.client()
	anonymousToken, _ := anonymous.bootstrap()
	anonymous.account = "1"
	if recorder := anonymous.rename(anonymousToken, "Mallory"); recorder.Code != http.StatusUnauthorized || errorCode(t, recorder) != "signed_out" {
		t.Fatalf("anonymous rename %d", recorder.Code)
	}
}

func TestDisplayNamesAreSavedAsTypedAndOnlyWhenTheyChange(t *testing.T) {
	h := newBrowserHarness(t, nil)
	client := h.client()
	token := client.signIn("alice", alicePassword)
	h.clock.Advance(1500)
	name := "  Zoë 📚 ​✨  "
	recorder := client.rename(token, name)
	if recorder.Code != http.StatusOK {
		t.Fatalf("rename %d %s", recorder.Code, recorder.Body.String())
	}
	want := map[string]any{"account": "1", "profile": map[string]any{"id": "1", "username": "alice", "name": name}}
	if got := decoded(t, recorder); !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v", got)
	}
	if stored := userColumn(t, h.path, "name", 1); stored != name {
		t.Fatalf("stored %q", stored)
	}
	if stamp := userColumn(t, h.path, "updated_at", 1); stamp != "2026-11-15 12:00:00.123457" {
		t.Fatalf("updated_at %q", stamp)
	}
	h.clock.Advance(3_000_000_000)
	if recorder := client.rename(token, name); recorder.Code != http.StatusOK {
		t.Fatalf("same name %d", recorder.Code)
	}
	if stamp := userColumn(t, h.path, "updated_at", 1); stamp != "2026-11-15 12:00:00.123457" {
		t.Fatalf("an unchanged name was written again: %q", stamp)
	}
	session := decoded(t, client.get("/preview/api/v1/session"))
	if session["account"].(map[string]any)["name"] != name {
		t.Fatalf("the header source still shows %v", session["account"])
	}
	if userColumn(t, h.path, "name", 2) != "Bob" {
		t.Fatal("another account changed")
	}
}

func TestBlankNamesAndInvalidBodiesWriteNothing(t *testing.T) {
	h := newBrowserHarness(t, nil)
	client := h.client()
	token := client.signIn("alice", alicePassword)
	for _, blank := range []string{"", "   ", " 　\t"} {
		recorder := client.rename(token, blank)
		if got := fieldErrors(t, recorder); !reflect.DeepEqual(got, map[string][]string{"name": {"can't be blank"}}) || errorCode(t, recorder) != "invalid_profile" {
			t.Fatalf("%q: %v", blank, got)
		}
	}
	headers := map[string]string{"X-Shelfarr-Account": "1", "Origin": browserOrigin, "X-CSRF-Token": token}
	for _, body := range []string{`{}`, `{"name":1}`, `{"name":null}`, `["x"]`, `{"name":"\ud800"}`, "{\"name\":\"\xff\"}"} {
		if recorder := client.send(http.MethodPut, "/preview/api/v1/account/profile", body, headers); recorder.Code != http.StatusBadRequest || errorCode(t, recorder) != "invalid_json" {
			t.Fatalf("%q answered %d", body, recorder.Code)
		}
	}
	if recorder := client.send(http.MethodPut, "/preview/api/v1/account/profile", `{"name":"a","name":"Last"}`, headers); recorder.Code != http.StatusOK || userColumn(t, h.path, "name", 1) != "Last" {
		t.Fatalf("a repeated member is not read as JSON.parse reads it: %d", recorder.Code)
	}
	oversized := `{"name":"` + strings.Repeat("x", 4096) + `"}`
	if recorder := client.send(http.MethodPut, "/preview/api/v1/account/profile", oversized, headers); recorder.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized %d", recorder.Code)
	}
	recorder := client.writeAccount(http.MethodPut, "/preview/api/v1/account/profile", token, map[string]any{"name": "Alice R", "username": "mallory", "role": 1, "id": 2, "password_digest": "x"})
	if recorder.Code != http.StatusOK {
		t.Fatalf("extra members %d", recorder.Code)
	}
	if userColumn(t, h.path, "username", 1) != "alice" || userColumn(t, h.path, "name", 2) != "Bob" || userColumn(t, h.path, "role", 1) != "1" || userColumn(t, h.path, "password_digest", 1) == "x" {
		t.Fatal("a member other than the name was applied")
	}
	if userColumn(t, h.path, "name", 1) != "Alice R" {
		t.Fatal("the name was not saved")
	}
}

func TestAStoredRecordRailsWouldRefuseIsRefusedWithItsMessages(t *testing.T) {
	h := newBrowserHarness(t, nil)
	client := h.client()
	token := client.signIn("alice", alicePassword)
	livetest.Exec(t, h.path, `UPDATE users SET username = 'Alice Smith', oidc_provider = 'sso' WHERE id = 1`)
	got := fieldErrors(t, client.rename(token, "New"))
	want := map[string][]string{"username": {"only allows lowercase letters, numbers, and underscores"}, "oidc_uid": {"can't be blank"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v", got)
	}
	got = fieldErrors(t, client.changePassword(token, alicePassword, newAlicePassword, newAlicePassword))
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("password got %v", got)
	}
	if userColumn(t, h.path, "name", 1) != "Alice" {
		t.Fatal("an invalid record was saved")
	}
	livetest.Exec(t, h.path, `UPDATE users SET username = 'bob', oidc_provider = NULL WHERE id = 1`)
	if got := fieldErrors(t, client.rename(token, "New")); !reflect.DeepEqual(got, map[string][]string{"username": {"has already been taken"}}) {
		t.Fatalf("duplicate username %v", got)
	}
	livetest.Exec(t, h.path, `UPDATE users SET deleted_at = '2026-11-15 11:00:00' WHERE id = 2`)
	if recorder := client.rename(token, "New"); recorder.Code != http.StatusOK {
		t.Fatalf("a deleted account's username still blocks: %d", recorder.Code)
	}
}

func TestAPasswordChangeKeepsThisSessionAndEndsOnlyTheAccountsOtherBrowserSessions(t *testing.T) {
	h := newBrowserHarness(t, nil)
	other := h.client()
	other.signIn("alice", alicePassword)
	bob := h.client()
	bob.signIn("bob", bobPassword)
	client := h.client()
	token := client.signIn("alice", alicePassword)
	livetest.Exec(t, h.path, `INSERT INTO api_tokens (id, user_id, token_digest, scopes) VALUES (7, 1, 'digest-7', '["library:read"]')`)
	before := sessionIDs(t, h.path, 1)
	if len(before) != 2 {
		t.Fatalf("sessions %v", before)
	}
	h.clock.Advance(2_000_000)
	recorder := client.changePassword(token, alicePassword, newAlicePassword, newAlicePassword)
	if recorder.Code != http.StatusOK {
		t.Fatalf("change %d %s", recorder.Code, recorder.Body.String())
	}
	if strings.Contains(recorder.Body.String(), newAlicePassword) || strings.Contains(recorder.Body.String(), "$2a$") {
		t.Fatal("the answer carries a password or digest")
	}
	want := map[string]any{"account": "1", "profile": map[string]any{"id": "1", "username": "alice", "name": "Alice"}}
	if got := decoded(t, recorder); !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v", got)
	}
	digest := userColumn(t, h.path, "password_digest", 1)
	cost, err := bcrypt.Cost([]byte(digest))
	if err != nil || cost != 12 || !strings.HasPrefix(digest, "$2a$12$") || bcrypt.CompareHashAndPassword([]byte(digest), []byte(newAlicePassword)) != nil {
		t.Fatalf("digest %.7s cost %d", digest, cost)
	}
	if stamp := userColumn(t, h.path, "updated_at", 1); stamp != "2026-11-15 12:00:00.125456" {
		t.Fatalf("updated_at %q", stamp)
	}
	if after := sessionIDs(t, h.path, 1); len(after) != 1 || after[0] != before[1] {
		t.Fatalf("sessions after %v (before %v)", after, before)
	}
	if len(sessionIDs(t, h.path, 2)) != 1 {
		t.Fatal("another account's session was ended")
	}
	if rows := livetest.Query(t, h.path, `SELECT COUNT(*) FROM api_tokens WHERE user_id = 1 AND revoked_at IS NULL`); rows[0][0].(int64) != 2 {
		t.Fatal("API tokens were revoked, which Rails does not do")
	}
	if recorder := client.get("/preview/api/v1/library"); recorder.Code != http.StatusOK {
		t.Fatalf("the current session stopped working: %d", recorder.Code)
	}
	if recorder := client.rename(token, "Still Alice"); recorder.Code != http.StatusOK {
		t.Fatalf("the current CSRF token stopped working: %d", recorder.Code)
	}
	if recorder := other.get("/preview/api/v1/session"); recorder.Code != http.StatusUnauthorized || errorCode(t, recorder) != "signed_out" {
		t.Fatalf("the other session survived: %d", recorder.Code)
	}
	if recorder := bob.get("/preview/api/v1/session"); recorder.Code != http.StatusOK {
		t.Fatalf("bob was signed out: %d", recorder.Code)
	}
	fresh := h.client()
	freshToken, _ := fresh.bootstrap()
	if recorder := fresh.login("alice", alicePassword, freshToken); recorder.Code != http.StatusUnauthorized {
		t.Fatalf("the old password still signs in: %d", recorder.Code)
	}
	fresh.signIn("alice", newAlicePassword)
}

func TestAWrongCurrentPasswordOrInvalidNewPasswordWritesNothing(t *testing.T) {
	h := newBrowserHarness(t, nil)
	other := h.client()
	other.signIn("alice", alicePassword)
	client := h.client()
	token := client.signIn("alice", alicePassword)
	digest := userColumn(t, h.path, "password_digest", 1)
	cases := []struct {
		current, password, confirmation string
		want                            map[string][]string
	}{
		{"Wrong-Passw0rd-123", newAlicePassword, newAlicePassword, map[string][]string{"current_password": {"is incorrect"}}},
		{"Wrong-Passw0rd-123", "short", "other", map[string][]string{"current_password": {"is incorrect"}}},
		{alicePassword + strings.Repeat("x", 80), newAlicePassword, newAlicePassword, map[string][]string{"current_password": {"is incorrect"}}},
		{"", newAlicePassword, newAlicePassword, map[string][]string{"current_password": {"is incorrect"}}},
		{alicePassword, "short", "short", map[string][]string{"password": {"is too short (minimum is 12 characters)", "must include at least one lowercase letter, one uppercase letter, and one number"}}},
		{alicePassword, newAlicePassword, newAlicePassword + "x", map[string][]string{"password_confirmation": {"doesn't match Password"}}},
		{alicePassword, "", "", map[string][]string{"password": {"can't be blank"}}},
		{alicePassword, strings.Repeat(" ", 14), strings.Repeat(" ", 14), map[string][]string{"password": {"must include at least one lowercase letter, one uppercase letter, and one number"}}},
	}
	for _, c := range cases {
		recorder := client.changePassword(token, c.current, c.password, c.confirmation)
		if got := fieldErrors(t, recorder); !reflect.DeepEqual(got, c.want) || errorCode(t, recorder) != "invalid_password" {
			t.Fatalf("%q/%q: %v", c.password, c.confirmation, got)
		}
	}
	if userColumn(t, h.path, "password_digest", 1) != digest || len(sessionIDs(t, h.path, 1)) != 2 || userColumn(t, h.path, "failed_login_count", 1) != "0" {
		t.Fatal("a refused change wrote something")
	}
	headers := map[string]string{"X-Shelfarr-Account": "1", "Origin": browserOrigin, "X-CSRF-Token": token}
	for _, body := range []string{`{}`, `{"current_password":"x","password":"y"}`, `{"current_password":1,"password":"y","password_confirmation":"y"}`} {
		if recorder := client.send(http.MethodPost, "/preview/api/v1/account/password", body, headers); recorder.Code != http.StatusBadRequest {
			t.Fatalf("%s answered %d", body, recorder.Code)
		}
	}
	if logs := h.logs.String(); strings.Contains(logs, alicePassword) || strings.Contains(logs, newAlicePassword) || strings.Contains(logs, digest) || !strings.Contains(logs, `"event":"password.incorrect"`) {
		t.Fatalf("logs %s", logs)
	}
}

func TestOIDCAccountsFollowTheRailsPasswordRulesAndUnusableDigestsAreRefused(t *testing.T) {
	h := newBrowserHarness(t, nil)
	client := h.client()
	token := client.signIn("alice", alicePassword)
	livetest.Exec(t, h.path, `UPDATE users SET oidc_provider = 'sso', oidc_uid = 'abc' WHERE id = 1`)
	if recorder := client.changePassword(token, alicePassword, "short", "short"); recorder.Code != http.StatusOK {
		t.Fatalf("OIDC short password %d %s", recorder.Code, recorder.Body.String())
	}
	tooCostly, _ := bcrypt.GenerateFromPassword([]byte("x"), 4)
	livetest.Exec(t, h.path, `UPDATE users SET password_digest = ? WHERE id = 1`, "$2a$15$"+string(tooCostly)[7:])
	if recorder := client.changePassword(token, "short", newAlicePassword, newAlicePassword); recorder.Code != http.StatusNotImplemented || errorCode(t, recorder) != "unsupported_stored_value" {
		t.Fatalf("costly digest %d", recorder.Code)
	}
}

func TestPasswordChangesAreRateLimitedPerAddress(t *testing.T) {
	h := newBrowserHarness(t, func(config *Config) { config.LoginAttempts = 3 })
	client := h.client()
	token := client.signIn("alice", alicePassword)
	for attempt := 0; attempt < 2; attempt++ {
		if recorder := client.changePassword(token, "Wrong-Passw0rd-123", newAlicePassword, newAlicePassword); recorder.Code != http.StatusUnprocessableEntity {
			t.Fatalf("attempt %d answered %d", attempt, recorder.Code)
		}
	}
	recorder := client.changePassword(token, alicePassword, newAlicePassword, newAlicePassword)
	if recorder.Code != http.StatusTooManyRequests || recorder.Header().Get("Retry-After") == "" {
		t.Fatalf("limit %d", recorder.Code)
	}
}

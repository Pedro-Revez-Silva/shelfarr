//go:build linux

package gohttp

import (
	"net/http"
	"reflect"
	"testing"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/livetest"
)

func TestUnsupportedSessionLifetimeCannotCreateASessionOrResetFailures(t *testing.T) {
	for _, setting := range []struct {
		name      string
		value     string
		valueType string
	}{
		{"wrong type", "7", "string"},
		{"not a number", "seven", "integer"},
		{"negative", "-1", "integer"},
		{"out of range", "36501", "integer"},
	} {
		t.Run(setting.name, func(t *testing.T) {
			h := newBrowserHarness(t, nil)
			livetest.Exec(t, h.path, `INSERT INTO settings (key, value, value_type) VALUES ('session_max_age_days', ?, ?)`, setting.value, setting.valueType)
			livetest.Exec(t, h.path, `UPDATE users SET failed_login_count = 2, locked_until = '2026-11-14 12:00:00', last_failed_login_at = '2026-11-14 11:00:00', last_failed_login_ip = '127.0.0.2' WHERE id = 1`)
			before := loginState(t, h)
			client := h.client()
			token, _ := client.bootstrap()
			response := client.login("alice", alicePassword, token)
			if response.Code != http.StatusNotImplemented || errorCode(t, response) != "unsupported_stored_value" {
				t.Fatalf("login refusal: %d %s", response.Code, response.Body.String())
			}
			if rows := livetest.Query(t, h.path, `SELECT COUNT(*) FROM sessions`); rows[0][0].(int64) != 0 {
				t.Fatalf("a refused login created %v sessions", rows[0][0])
			}
			if !reflect.DeepEqual(before, loginState(t, h)) {
				t.Fatal("a refused login changed the failure or lockout state")
			}
			if _, present := client.cookies[sessionCookieName]; present {
				t.Fatal("a refused login issued a session cookie")
			}
		})
	}
}

func loginState(t *testing.T, h *browserHarness) [][]any {
	t.Helper()
	return livetest.Query(t, h.path, `SELECT failed_login_count, locked_until, last_failed_login_at, last_failed_login_ip, updated_at FROM users WHERE id = 1`)
}

func TestAccountRefusalsPrecedeUnsupportedSessionLifetime(t *testing.T) {
	for _, account := range []struct {
		name   string
		setup  func(*testing.T, *browserHarness)
		status int
		code   string
	}{
		{"locked", func(t *testing.T, h *browserHarness) {
			livetest.Exec(t, h.path, `UPDATE users SET locked_until = '2026-11-16 12:00:00' WHERE id = 1`)
		}, http.StatusUnauthorized, "invalid_credentials"},
		{"second factor", func(t *testing.T, h *browserHarness) {
			livetest.Exec(t, h.path, `UPDATE users SET otp_required = 1, otp_secret = 'unported-secret' WHERE id = 1`)
		}, http.StatusNotImplemented, "mfa_not_supported"},
		{"OIDC", func(t *testing.T, h *browserHarness) {
			livetest.Exec(t, h.path, `UPDATE users SET oidc_provider = 'provider', oidc_uid = 'subject' WHERE id = 1`)
		}, http.StatusNotImplemented, "oidc_account_not_supported"},
		{"passwordless", func(t *testing.T, h *browserHarness) {
			livetest.Exec(t, h.path, `INSERT INTO settings (key, value, value_type) VALUES ('auth_disabled', 'true', 'boolean')`)
		}, http.StatusNotImplemented, "sign_in_unsupported"},
	} {
		t.Run(account.name, func(t *testing.T) {
			h := newBrowserHarness(t, nil)
			account.setup(t, h)
			livetest.Exec(t, h.path, `INSERT INTO settings (key, value, value_type) VALUES ('session_max_age_days', '-1', 'integer')`)
			before := loginState(t, h)
			client := h.client()
			token, _ := client.bootstrap()
			response := client.login("alice", alicePassword, token)
			if response.Code != account.status || errorCode(t, response) != account.code {
				t.Fatalf("account refusal: %d %s", response.Code, response.Body.String())
			}
			if rows := livetest.Query(t, h.path, `SELECT COUNT(*) FROM sessions`); rows[0][0].(int64) != 0 {
				t.Fatalf("a refused login created %v sessions", rows[0][0])
			}
			if !reflect.DeepEqual(before, loginState(t, h)) {
				t.Fatal("a refused login changed the account state")
			}
			if _, present := client.cookies[sessionCookieName]; present {
				t.Fatal("a refused login issued a session cookie")
			}
		})
	}
}

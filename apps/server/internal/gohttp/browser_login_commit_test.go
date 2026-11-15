//go:build linux

package gohttp

import (
	"net/http"
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
			livetest.Exec(t, h.path, `UPDATE users SET failed_login_count = 2 WHERE id = 1`)
			client := h.client()
			token, _ := client.bootstrap()
			response := client.login("alice", alicePassword, token)
			if response.Code != http.StatusNotImplemented || errorCode(t, response) != "unsupported_stored_value" {
				t.Fatalf("login refusal: %d %s", response.Code, response.Body.String())
			}
			if rows := livetest.Query(t, h.path, `SELECT COUNT(*) FROM sessions`); rows[0][0].(int64) != 0 {
				t.Fatalf("a refused login created %v sessions", rows[0][0])
			}
			if rows := livetest.Query(t, h.path, `SELECT failed_login_count FROM users WHERE id = 1`); rows[0][0].(int64) != 2 {
				t.Fatalf("a refused login changed the failure count to %v", rows[0][0])
			}
			if _, present := client.cookies[sessionCookieName]; present {
				t.Fatal("a refused login issued a session cookie")
			}
		})
	}
}

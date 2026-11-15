//go:build e2e

package pairing

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"
)

type api struct {
	t        testing.TB
	instance *server
	f        fixture
	clock    string
}

func (a api) at(moment time.Time) { setClock(a.t, a.clock, moment.UTC().Format(time.RFC3339Nano)) }

func (a api) post(path string, headers map[string]string, body string) result {
	a.t.Helper()
	merged := map[string]string{"Accept": "application/json"}
	for name, value := range headers {
		merged[name] = value
	}
	var payload []byte
	if body != "" {
		payload = []byte(body)
	}
	return a.instance.bare().do("POST", path, merged, payload)
}

func (a api) device(body string, bearer string) (result, map[string]any) {
	a.t.Helper()
	headers := map[string]string{}
	if bearer != "" {
		headers["Authorization"] = "Bearer " + bearer
	}
	got := a.post("/api/consumer/v1/auth/device", headers, body)
	var parsed map[string]any
	json.Unmarshal(got.body, &parsed)
	return got, parsed
}

func (a api) poll(deviceCode string) (result, map[string]any) {
	a.t.Helper()
	got := a.post("/api/consumer/v1/auth/token", nil, `{"device_code":"`+deviceCode+`"}`)
	var parsed map[string]any
	json.Unmarshal(got.body, &parsed)
	return got, parsed
}

func (a api) me(token string) int {
	a.t.Helper()
	return a.instance.bare().do("GET", "/api/consumer/v1/me", map[string]string{"Authorization": "Bearer " + token, "Accept": "application/json"}, nil).status
}

func (a api) revoke(token string) int {
	a.t.Helper()
	return a.post("/api/consumer/v1/auth/revoke", map[string]string{"Authorization": "Bearer " + token}, "{}").status
}

type consenter struct {
	client  *browser
	account string
	origin  string
}

func (a api) consenter(name string) consenter {
	a.t.Helper()
	client := a.instance.browser()
	account, _ := client.signIn(name, a.f.secrets.Passwords[name])
	return consenter{client: client, account: account, origin: a.instance.origin}
}

func (c consenter) decide(userCode, decision string) result {
	token, _ := c.client.bootstrap()
	payload, _ := json.Marshal(map[string]string{"user_code": userCode, "decision": decision})
	return c.client.do("POST", "/preview/api/v1/connect", map[string]string{"X-Shelfarr-Account": c.account, "Origin": c.origin, "X-CSRF-Token": token, "Accept": "application/json"}, payload)
}

func (c consenter) inspect(userCode string) result {
	return c.client.do("GET", "/preview/api/v1/connect?user_code="+userCode, map[string]string{"X-Shelfarr-Account": c.account, "Accept": "application/json"}, nil)
}

func str(value any) string {
	text, _ := value.(string)
	return text
}

func mustStatus(t testing.TB, label string, got result, want int) {
	t.Helper()
	if got.status != want {
		t.Fatalf("%s answered %d, want %d", label, got.status, want)
	}
}

func contains(text string, parts ...string) bool {
	for _, part := range parts {
		if !strings.Contains(text, part) {
			return false
		}
	}
	return true
}

var _ = http.StatusOK

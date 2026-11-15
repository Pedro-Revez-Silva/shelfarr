//go:build e2e

package browser

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"
)

func eachFixture(t *testing.T, run func(t *testing.T, f fixture, copied runtimeCopy)) {
	t.Helper()
	for _, f := range fixtures(t) {
		t.Run(f.name, func(t *testing.T) { run(t, f, newRuntimeCopy(t, f)) })
	}
}

func secretsOf(f fixture) []string {
	found := []string{}
	for _, password := range f.personas.Passwords {
		found = append(found, password)
	}
	for _, p := range f.personas.Personas {
		found = append(found, p.Cookie)
	}
	return found
}

func noSecrets(t *testing.T, text string, secrets ...string) {
	t.Helper()
	for _, secret := range secrets {
		if secret != "" && strings.Contains(text, secret) {
			t.Fatalf("a synthetic secret appears in the output: %.12s…", secret)
		}
	}
}

func hash(t *testing.T, password string, cost int) string {
	t.Helper()
	digest, err := bcrypt.GenerateFromPassword([]byte(password), cost)
	if err != nil {
		t.Fatal(err)
	}
	return string(digest)
}

func TestBrowserSessionLifecycleOverRealHTTP(t *testing.T) {
	eachFixture(t, func(t *testing.T, f fixture, copied runtimeCopy) {
		instance := startServer(t, f, copied, serverOptions{})
		client := instance.browser()
		pre, body := client.bootstrap()
		if body["authenticated"] != false || body["sign_in"].(map[string]any)["available"] != true {
			t.Fatalf("bootstrap %v", body)
		}
		for _, line := range client.do("GET", "/preview/api/v1/auth/bootstrap", nil, nil).headers.Values("Set-Cookie") {
			if !strings.HasPrefix(line, "shelfarr_login=") || !strings.Contains(line, "HttpOnly") || !strings.Contains(line, "SameSite=Strict") || !strings.Contains(line, "Path=/preview/api/v1/auth") || strings.Contains(line, "Secure") {
				t.Fatalf("nonce cookie %q", line)
			}
		}
		payload, _ := json.Marshal(map[string]string{"username": "browser_member", "password": f.personas.Passwords["browser_member"]})
		login := client.do("POST", "/preview/api/v1/auth/login", map[string]string{"Origin": instance.origin, "X-CSRF-Token": pre}, payload)
		if login.status != http.StatusOK {
			t.Fatalf("login %d %s", login.status, login.body)
		}
		var sessionLine string
		for _, line := range login.headers.Values("Set-Cookie") {
			if strings.HasPrefix(line, "session_id=") {
				sessionLine = line
			}
		}
		for _, wanted := range []string{"Path=/;", "HttpOnly", "SameSite=Lax", "Expires="} {
			if !strings.Contains(sessionLine+";", wanted) {
				t.Fatalf("session cookie %q lacks %q", sessionLine, wanted)
			}
		}
		rawValue := strings.TrimPrefix(strings.SplitN(sessionLine, ";", 2)[0], "session_id=")
		if strings.ContainsAny(rawValue, "+/=") || !strings.Contains(rawValue, "%") {
			t.Fatalf("the session cookie is not escaped the way Rails and Rack read it: %q", rawValue)
		}
		if strings.Contains(sessionLine, "Secure") || strings.Contains(sessionLine, "Max-Age") {
			t.Fatalf("session cookie %q", sessionLine)
		}
		document := login.json(t)
		account, token := document["account"].(string), document["csrf_token"].(string)
		if account != fmt.Sprint(f.doc.Users["browser_member"]) {
			t.Fatalf("account %s", account)
		}
		if client.cookie("shelfarr_login") != "" {
			t.Fatal("the login nonce survived the login")
		}
		session := client.get("/preview/api/v1/session", account)
		if session.status != http.StatusOK || session.headers.Get("Cache-Control") != "private, no-store" || session.headers.Get("Access-Control-Allow-Origin") != "" {
			t.Fatalf("session %d %v", session.status, session.headers)
		}
		library := client.get("/preview/api/v1/library", account)
		if library.status != http.StatusOK || library.json(t)["account"] != account {
			t.Fatalf("library %d", library.status)
		}
		if replay := client.login("browser_member", f.personas.Passwords["browser_member"], pre, nil); replay.status != http.StatusUnprocessableEntity && replay.status != http.StatusConflict {
			t.Fatalf("the anonymous token logged in again: %d", replay.status)
		}
		book := firstBook(t, library)
		status := "/preview/api/v1/library/" + book + "/reading_status"
		for name, headers := range map[string]map[string]string{
			"no token":       {"X-Shelfarr-Account": account, "Origin": instance.origin},
			"bad token":      {"X-Shelfarr-Account": account, "Origin": instance.origin, "X-CSRF-Token": token + "x"},
			"anonymous":      {"X-Shelfarr-Account": account, "Origin": instance.origin, "X-CSRF-Token": pre},
			"other origin":   {"X-Shelfarr-Account": account, "Origin": "http://evil.example", "X-CSRF-Token": token},
			"null origin":    {"X-Shelfarr-Account": account, "Origin": "null", "X-CSRF-Token": token},
			"no origin":      {"X-Shelfarr-Account": account, "X-CSRF-Token": token},
			"cross site":     {"X-Shelfarr-Account": account, "Origin": instance.origin, "X-CSRF-Token": token, "Sec-Fetch-Site": "cross-site"},
			"scheme swapped": {"X-Shelfarr-Account": account, "Origin": strings.Replace(instance.origin, "http://", "https://", 1), "X-CSRF-Token": token},
		} {
			response := client.do("PUT", status, headers, []byte(`{"status":"finished"}`))
			if response.status != http.StatusUnprocessableEntity || response.code(t) != "invalid_csrf" {
				t.Errorf("%s answered %d %s", name, response.status, response.body)
			}
		}
		if changed := client.put(status, "99999", token, `{"status":"finished"}`); changed.status != http.StatusUnauthorized || changed.code(t) != "account_changed" {
			t.Errorf("a stale account tab answered %d", changed.status)
		}
		if rows := rows(t, copied.database, `SELECT COUNT(*) AS n FROM consumer_reading_states WHERE user_id = ? AND book_id = ?`, f.doc.Users["browser_member"], book); rows[0]["n"].(int64) != 0 {
			t.Fatal("a refused request wrote a reading state")
		}
		if written := client.put(status, account, token, `{"status":"finished"}`); written.status != http.StatusOK {
			t.Fatalf("a valid write answered %d %s", written.status, written.body)
		}
		if again := client.put(status, account, token, `{"status":"in_progress"}`); again.status != http.StatusOK {
			t.Fatalf("the same session token could not be used again: %d", again.status)
		}
		sessionValue := client.cookie("session_id")
		if before := count(t, copied.database, `SELECT COUNT(*) FROM sessions WHERE user_id = ?`, f.doc.Users["browser_member"]); before < 2 {
			t.Fatalf("sessions %d", before)
		}
		if refused := client.logout("99999", token); refused.status != http.StatusUnauthorized {
			t.Fatalf("logout for another account answered %d", refused.status)
		}
		if refused := client.do("POST", "/preview/api/v1/auth/logout", map[string]string{"X-Shelfarr-Account": account, "Origin": instance.origin}, nil); refused.status != http.StatusUnprocessableEntity {
			t.Fatalf("logout without a token answered %d", refused.status)
		}
		if out := client.logout(account, token); out.status != http.StatusOK || client.cookie("session_id") != "" {
			t.Fatalf("logout %d", out.status)
		}
		stale := instance.bare()
		headers := map[string]string{"Cookie": "session_id=" + sessionValue, "X-Shelfarr-Account": account}
		if replay := stale.do("GET", "/preview/api/v1/session", headers, nil); replay.status != http.StatusUnauthorized || replay.code(t) != "signed_out" {
			t.Fatalf("a revoked cookie answered %d", replay.status)
		}
		headers["Origin"], headers["X-CSRF-Token"] = instance.origin, token
		if replay := stale.do("PUT", status, headers, []byte(`{"status":"unread"}`)); replay.status != http.StatusUnauthorized {
			t.Fatalf("a revoked session wrote: %d", replay.status)
		}
		fresh := instance.browser()
		_, again := fresh.signIn("browser_member", f.personas.Passwords["browser_member"])
		if again == token {
			t.Fatal("two sessions share a token")
		}
		if reuse := fresh.put(status, account, token, `{"status":"unread"}`); reuse.status != http.StatusUnprocessableEntity {
			t.Fatalf("a token from a revoked session worked in a new one: %d", reuse.status)
		}
		noSecrets(t, instance.log.String(), append(secretsOf(f), token, pre, again, sessionValue)...)
	})
}

func firstBook(t *testing.T, library result) string {
	t.Helper()
	items := library.json(t)["items"].([]any)
	if len(items) == 0 {
		t.Fatal("the library is empty")
	}
	return items[len(items)-1].(map[string]any)["id"].(string)
}

func TestBrowserSessionsSurviveARestartAndRailsCookiesWorkOnTheProductionClock(t *testing.T) {
	eachFixture(t, func(t *testing.T, f fixture, copied runtimeCopy) {
		first := startServer(t, f, copied, serverOptions{})
		client := first.browser()
		account, _ := client.signIn("browser_admin", f.personas.Passwords["browser_admin"])
		first.stop()
		second := startServer(t, f, copied, serverOptions{})
		client.server = second
		if response := client.get("/preview/api/v1/session", account); response.status != http.StatusOK {
			t.Fatalf("a Go session did not survive a restart: %d", response.status)
		}
		_, token := func() (string, string) {
			response := client.do("GET", "/preview/api/v1/auth/bootstrap", nil, nil).json(t)
			return response["account"].(string), response["csrf_token"].(string)
		}()
		if out := client.logout(account, token); out.status != http.StatusOK {
			t.Fatalf("logout after a restart answered %d", out.status)
		}
		rails := second.bare()
		for _, name := range []string{"alice", "bob", "admin", "member", "login-member", "login-admin"} {
			user := fmt.Sprint(f.personas.Personas[name].UserID)
			response := rails.do("GET", "/preview/api/v1/session", map[string]string{"Cookie": "session_id=" + f.personas.Personas[name].Cookie, "X-Shelfarr-Account": user}, nil)
			if response.status != http.StatusOK {
				t.Errorf("the Rails cookie of %s answered %d %s", name, response.status, response.body)
			}
		}
		tampered := f.personas.Personas["alice"].Cookie
		tampered = tampered[:len(tampered)-3] + "000"
		for name, cookie := range map[string]string{"tampered": tampered, "wrong purpose": f.personas.Personas["wrong-purpose"].Cookie, "unknown row": f.personas.Personas["unknown-session"].Cookie, "truncated": tampered[:40], "huge": strings.Repeat("A", 4000)} {
			response := rails.do("GET", "/preview/api/v1/session", map[string]string{"Cookie": "session_id=" + cookie, "X-Shelfarr-Account": "1"}, nil)
			if response.status != http.StatusUnauthorized || response.code(t) != "signed_out" {
				t.Errorf("%s answered %d", name, response.status)
			}
		}
		noSecrets(t, second.log.String(), secretsOf(f)...)
	})
}

func TestBrowserEndpointsAreOffWithoutAnExplicitWellFormedUserList(t *testing.T) {
	eachFixture(t, func(t *testing.T, f fixture, copied runtimeCopy) {
		alice := f.personas.Personas["alice"]
		before := count(t, copied.database, `SELECT COUNT(*) FROM sessions`)
		for name, options := range map[string]serverOptions{
			"unset": {noUsers: true}, "empty": {users: " "}, "malformed": {users: "1,x"}, "zero": {users: "0"}, "too many": {users: strings.Repeat("1,", 100) + "1"},
			"environment": {noUsers: true, env: []string{"SHELFARR_WEB_PREVIEW_USER_IDS=abc"}},
		} {
			if options.users == " " {
				options.users = " "
			}
			instance := startServer(t, f, copied, options)
			client := instance.bare()
			for _, target := range []string{"/preview/api/v1/session", "/preview/api/v1/library", "/preview/api/v1/continue", "/preview/api/v1/library/1", "/preview/api/v1/auth/bootstrap"} {
				response := client.do("GET", target, map[string]string{"Cookie": "session_id=" + alice.Cookie, "X-Shelfarr-Account": fmt.Sprint(alice.UserID)}, nil)
				if response.status != http.StatusNotFound || response.code(t) != "not_found" {
					t.Errorf("%s: %s answered %d", name, target, response.status)
				}
			}
			payload, _ := json.Marshal(map[string]string{"username": "browser_member", "password": f.personas.Passwords["browser_member"]})
			if response := client.do("POST", "/preview/api/v1/auth/login", map[string]string{"Origin": instance.origin}, payload); response.status != http.StatusNotFound {
				t.Errorf("%s: login answered %d", name, response.status)
			}
			instance.stop()
		}
		if after := count(t, copied.database, `SELECT COUNT(*) FROM sessions`); after != before {
			t.Fatalf("a disabled preview wrote sessions: %d to %d", before, after)
		}
		both := startServerExpectingRefusal(t, f, copied, []string{"-preview-user-ids", "1"}, []string{"SHELFARR_WEB_PREVIEW_USER_IDS=1"})
		if !strings.Contains(both, "preview-user-ids-ambiguous") {
			t.Fatalf("flag and variable together: %s", both)
		}
	})
}

func startServerExpectingRefusal(t *testing.T, f fixture, copied runtimeCopy, extra []string, environment []string) string {
	t.Helper()
	arguments := []string{"-experimental", "-database", copied.database, "-lock-file", copied.lock + ".other", "-listen", "127.0.0.1:" + freePort(t), "-library-root", f.doc.BundleMediaRoot}
	command := exec.Command(binaryPath, append(arguments, extra...)...)
	command.Env = append([]string{"PATH=" + os.Getenv("PATH"), "SECRET_KEY_BASE_FILE=" + f.secretFile()}, environment...)
	output, err := command.CombinedOutput()
	if err == nil {
		t.Fatalf("the server started: %s", output)
	}
	return string(output)
}

func TestBrowserRuntimeNeverCreatesAKeyAndRefusesWithoutOneOrWithoutAnOrigin(t *testing.T) {
	eachFixture(t, func(t *testing.T, f fixture, copied runtimeCopy) {
		command := exec.Command(binaryPath, "-experimental", "-database", copied.database, "-lock-file", copied.lock, "-listen", "127.0.0.1:"+freePort(t), "-library-root", f.doc.BundleMediaRoot, "-preview-user-ids", "1")
		command.Env = []string{"PATH=" + os.Getenv("PATH")}
		output, err := command.CombinedOutput()
		if err == nil || !strings.Contains(string(output), "secret-key-base-missing") {
			t.Fatalf("a missing key was tolerated: %v %s", err, output)
		}
		master := exec.Command(binaryPath, "-experimental", "-database", copied.database, "-lock-file", copied.lock, "-listen", "127.0.0.1:"+freePort(t), "-library-root", f.doc.BundleMediaRoot, "-preview-user-ids", "1")
		master.Env = []string{"PATH=" + os.Getenv("PATH"), "RAILS_MASTER_KEY=00000000000000000000000000000000"}
		if output, err := master.CombinedOutput(); err == nil || !strings.Contains(string(output), "master-key-mode-unsupported") {
			t.Fatalf("credentials mode was tolerated: %v %s", err, output)
		}
		noOrigin := startServer(t, f, copied, serverOptions{noOrigin: true})
		client := noOrigin.browser()
		token, body := client.bootstrap()
		if body["sign_in"].(map[string]any)["available"] != false || body["sign_in"].(map[string]any)["reason"] != "browser_origin_not_configured" {
			t.Fatalf("bootstrap %v", body)
		}
		if response := client.login("browser_member", f.personas.Passwords["browser_member"], token, map[string]string{"Origin": "http://127.0.0.1:1"}); response.status != http.StatusNotImplemented {
			t.Fatalf("sign-in without a configured origin answered %d", response.status)
		}
		if count(t, copied.database, `SELECT COUNT(*) FROM sessions WHERE created_at > '2026-11-15 12:05:00'`) != 0 {
			t.Fatal("a session was created")
		}
		rails := f.personas.Personas["alice"]
		if response := noOrigin.bare().do("GET", "/preview/api/v1/session", map[string]string{"Cookie": "session_id=" + rails.Cookie, "X-Shelfarr-Account": fmt.Sprint(rails.UserID)}, nil); response.status != http.StatusOK {
			t.Fatalf("a read-only preview answered %d", response.status)
		}
	})
}

func TestBrowserRefusesUnportedSignInModesWithoutCreatingASession(t *testing.T) {
	eachFixture(t, func(t *testing.T, f fixture, copied runtimeCopy) {
		instance := startServer(t, f, copied, serverOptions{})
		before := count(t, copied.database, `SELECT COUNT(*) FROM sessions`)
		cases := map[string][3]any{
			"second factor":         {"alice", http.StatusNotImplemented, "mfa_not_supported"},
			"oidc linked":           {"browser_oidc", http.StatusNotImplemented, "oidc_account_not_supported"},
			"wrong password mfa":    {"alice", http.StatusUnauthorized, "invalid_credentials"},
			"outside the allowlist": {"browser_outsider", http.StatusUnauthorized, "invalid_credentials"},
			"deleted":               {"carol", http.StatusUnauthorized, "invalid_credentials"},
		}
		for name, expected := range cases {
			client := instance.browser()
			token, _ := client.bootstrap()
			username := expected[0].(string)
			password := f.personas.Passwords[username]
			if name == "wrong password mfa" {
				password = "Wrong-Password-1x"
			}
			response := client.login(username, password, token, nil)
			if response.status != expected[1].(int) || response.code(t) != expected[2].(string) {
				t.Errorf("%s answered %d %s", name, response.status, response.body)
			}
			if client.cookie("session_id") != "" {
				t.Errorf("%s set a session cookie", name)
			}
		}
		exec1(t, copied.database, `INSERT INTO settings (key, value, value_type, category, created_at, updated_at) VALUES ('auth_disabled', 'true', 'boolean', 'security', '2026-11-15 12:00:00', '2026-11-15 12:00:00') ON CONFLICT(key) DO UPDATE SET value = 'true', value_type = 'boolean'`)
		client := instance.browser()
		token, body := client.bootstrap()
		if body["sign_in"].(map[string]any)["reason"] != "auth_disabled" {
			t.Fatalf("bootstrap %v", body)
		}
		if response := client.login("browser_member", f.personas.Passwords["browser_member"], token, nil); response.status != http.StatusNotImplemented || response.code(t) != "sign_in_unsupported" {
			t.Fatalf("a passwordless deployment answered %d %s", response.status, response.body)
		}
		exec1(t, copied.database, `UPDATE settings SET value = 'false' WHERE key = 'auth_disabled'`)
		instance.stop()
		environment := startServer(t, f, copied, serverOptions{env: []string{"DISABLE_AUTH=true"}})
		client = environment.browser()
		token, _ = client.bootstrap()
		if response := client.login("browser_member", f.personas.Passwords["browser_member"], token, nil); response.status != http.StatusNotImplemented {
			t.Fatalf("DISABLE_AUTH answered %d", response.status)
		}
		if after := count(t, copied.database, `SELECT COUNT(*) FROM sessions`); after != before {
			t.Fatalf("an unported mode created %d sessions", after-before)
		}
		for _, state := range rows(t, copied.database, `SELECT username, failed_login_count FROM users WHERE username IN ('browser_oidc', 'browser_outsider', 'carol')`) {
			if state["failed_login_count"].(int64) != 0 {
				t.Errorf("%v was written", state)
			}
		}
	})
}

func TestBrowserLockoutIsAtomicUnderConcurrentWrongPasswords(t *testing.T) {
	eachFixture(t, func(t *testing.T, f fixture, copied runtimeCopy) {
		instance := startServer(t, f, copied, serverOptions{arguments: []string{"-login-attempts", "1000"}})
		var wait sync.WaitGroup
		statuses := make(chan int, 40)
		for attempt := 0; attempt < 40; attempt++ {
			wait.Add(1)
			go func() {
				defer wait.Done()
				client := instance.browser()
				token, _ := client.bootstrap()
				statuses <- client.login("browser_lockable", "Wrong-Concurrent-1x", token, nil).status
			}()
		}
		wait.Wait()
		close(statuses)
		for status := range statuses {
			if status != http.StatusUnauthorized {
				t.Errorf("a wrong password answered %d", status)
			}
		}
		state := rows(t, copied.database, `SELECT failed_login_count, locked_until IS NOT NULL AS locked FROM users WHERE username = 'browser_lockable'`)[0]
		if state["failed_login_count"].(int64) != 5 || state["locked"].(int64) != 1 {
			t.Fatalf("the counter is not exactly the threshold: %v", state)
		}
		client := instance.browser()
		token, _ := client.bootstrap()
		if response := client.login("browser_lockable", f.personas.Passwords["browser_lockable"], token, nil); response.status != http.StatusUnauthorized {
			t.Fatalf("a locked account signed in: %d", response.status)
		}
		var group sync.WaitGroup
		ids := make(chan string, 12)
		for attempt := 0; attempt < 12; attempt++ {
			group.Add(1)
			go func() {
				defer group.Done()
				visitor := instance.browser()
				account, _ := visitor.signIn("browser_admin", f.personas.Passwords["browser_admin"])
				ids <- account + ":" + visitor.cookie("session_id")
			}()
		}
		group.Wait()
		close(ids)
		seen := map[string]bool{}
		for id := range ids {
			seen[id] = true
		}
		if len(seen) != 12 {
			t.Fatalf("concurrent sign-ins collided: %d distinct sessions", len(seen))
		}
		noSecrets(t, instance.log.String(), append(secretsOf(f), "Wrong-Concurrent-1x")...)
	})
}

func TestBrowserPasswordCostAndRateAreBounded(t *testing.T) {
	eachFixture(t, func(t *testing.T, f fixture, copied runtimeCopy) {
		cheap := hash(t, "Cost-Probe-Password-1x", bcrypt.MinCost)
		exec1(t, copied.database, `UPDATE users SET password_digest = ? WHERE username = 'browser_member'`, strings.Replace(cheap, "$04$", "$15$", 1))
		instance := startServer(t, f, copied, serverOptions{arguments: []string{"-login-attempts", "4", "-login-window", "1h"}})
		client := instance.browser()
		token, _ := client.bootstrap()
		started := time.Now()
		if response := client.login("browser_member", "Cost-Probe-Password-1x", token, nil); response.status != http.StatusNotImplemented || response.code(t) != "unsupported_stored_value" {
			t.Fatalf("an over-cost digest answered %d %s", response.status, response.body)
		}
		if time.Since(started) > 3*time.Second {
			t.Fatal("an over-cost digest was computed")
		}
		for attempt := 0; attempt < 3; attempt++ {
			client.login("nobody", "x", token, nil)
		}
		limited := client.login("nobody", "x", token, nil)
		if limited.status != http.StatusTooManyRequests || limited.headers.Get("Retry-After") == "" || limited.code(t) != "rate_limited" {
			t.Fatalf("the fifth attempt answered %d %v", limited.status, limited.headers)
		}
		if data := client.get("/preview/api/v1/session", "1"); data.status != http.StatusUnauthorized {
			t.Fatalf("rate limiting leaked into data requests: %d", data.status)
		}
	})
}

func rawRequest(t *testing.T, address, text string, hold time.Duration) string {
	t.Helper()
	connection, err := net.Dial("tcp", address)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	connection.SetDeadline(time.Now().Add(15 * time.Second))
	connection.Write([]byte(text))
	time.Sleep(hold)
	buffer := make([]byte, 4096)
	count, _ := connection.Read(buffer)
	return string(buffer[:count])
}

func TestBrowserBodiesAndCookiesAreBounded(t *testing.T) {
	eachFixture(t, func(t *testing.T, f fixture, copied runtimeCopy) {
		instance := startServer(t, f, copied, serverOptions{arguments: []string{"-body-timeout", "400ms"}})
		client := instance.browser()
		token, _ := client.bootstrap()
		headers := map[string]string{"Origin": instance.origin, "X-CSRF-Token": token}
		big := []byte(`{"username":"browser_member","password":"` + strings.Repeat("a", 5000) + `"}`)
		if response := client.do("POST", "/preview/api/v1/auth/login", headers, big); response.status != http.StatusRequestEntityTooLarge {
			t.Errorf("an oversized body answered %d", response.status)
		}
		plain := map[string]string{"Origin": instance.origin, "X-CSRF-Token": token, "Content-Type": "text/plain"}
		if response := client.do("POST", "/preview/api/v1/auth/login", plain, []byte("x")); response.status != http.StatusUnsupportedMediaType {
			t.Errorf("a plain body answered %d", response.status)
		}
		address := strings.TrimPrefix(instance.base, "http://")
		nonce := client.cookie("shelfarr_login")
		stalled := fmt.Sprintf("POST /preview/api/v1/auth/login HTTP/1.1\r\nHost: %s\r\nOrigin: %s\r\nX-CSRF-Token: %s\r\nCookie: shelfarr_login=%s\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{\"user", address, instance.origin, token, nonce)
		if answer := rawRequest(t, address, stalled, 2*time.Second); !strings.Contains(answer, "408") {
			t.Errorf("a stalled body answered %q", answer)
		}
		huge := fmt.Sprintf("GET /preview/api/v1/session HTTP/1.1\r\nHost: %s\r\nCookie: session_id=%s\r\n\r\n", address, strings.Repeat("A", 40000))
		if answer := rawRequest(t, address, huge, 100*time.Millisecond); !strings.Contains(answer, "431") {
			t.Errorf("an oversized cookie header answered %q", answer)
		}
		medium := client.do("GET", "/preview/api/v1/session", map[string]string{"Cookie": "session_id=" + strings.Repeat("A", 8000), "X-Shelfarr-Account": "1"}, nil)
		if medium.status != http.StatusUnauthorized {
			t.Errorf("a long cookie answered %d", medium.status)
		}
		duplicate := instance.bare().do("GET", "/preview/api/v1/session", map[string]string{"Cookie": "session_id=garbage; session_id=" + f.personas.Personas["alice"].Cookie, "X-Shelfarr-Account": "1"}, nil)
		if duplicate.status != http.StatusUnauthorized {
			t.Errorf("the first duplicate cookie must decide, as in Rack: %d", duplicate.status)
		}
		if native := instance.bare().do("GET", "/api/consumer/v1/me", map[string]string{"Cookie": "session_id=" + f.personas.Personas["alice"].Cookie}, nil); native.status != http.StatusUnauthorized {
			t.Errorf("a session cookie authenticated the native API: %d", native.status)
		}
		if option := instance.bare().do("OPTIONS", "/preview/api/v1/library", map[string]string{"Origin": "http://evil.example", "Access-Control-Request-Method": "GET"}, nil); option.status != http.StatusMethodNotAllowed || option.headers.Get("Access-Control-Allow-Origin") != "" {
			t.Errorf("a preflight answered %d %v", option.status, option.headers)
		}
	})
}

func TestBrowserExpiryUsesTheProductionClock(t *testing.T) {
	eachFixture(t, func(t *testing.T, f fixture, copied runtimeCopy) {
		instance := startServer(t, f, copied, serverOptions{})
		client := instance.browser()
		account, _ := client.signIn("browser_member", f.personas.Passwords["browser_member"])
		stamp := func(offset time.Duration) string {
			moment := time.Now().UTC().Add(offset)
			return moment.Format("2006-01-02 15:04:05") + fmt.Sprintf(".%06d", moment.Nanosecond()/1000)
		}
		newest := count(t, copied.database, `SELECT MAX(id) FROM sessions`)
		exec1(t, copied.database, `UPDATE sessions SET created_at = ?, updated_at = ? WHERE id = ?`, stamp(-30*24*time.Hour+3*time.Second), stamp(0), newest)
		if response := client.get("/preview/api/v1/session", account); response.status != http.StatusOK {
			t.Fatalf("a session inside its age answered %d", response.status)
		}
		time.Sleep(3500 * time.Millisecond)
		if response := client.get("/preview/api/v1/session", account); response.status != http.StatusUnauthorized {
			t.Fatalf("a session past its age answered %d", response.status)
		}
		if count(t, copied.database, `SELECT COUNT(*) FROM sessions WHERE id = ?`, newest) != 0 {
			t.Fatal("the expired row was kept, Rails destroys it")
		}
	})
}

func TestBrowserLoginFaultsLeaveNoOrphansAndRefuseStaleCredentials(t *testing.T) {
	eachFixture(t, func(t *testing.T, f fixture, copied runtimeCopy) {
		directory := t.TempDir()
		member := f.personas.Passwords["browser_member"]
		before := count(t, copied.database, `SELECT COUNT(*) FROM sessions`)
		parked := startServer(t, f, copied, serverOptions{seam: true, faults: "login.checked=park", faultDir: directory})
		client := parked.browser()
		token, _ := client.bootstrap()
		outcome := make(chan result, 1)
		go func() { outcome <- client.login("browser_member", member, token, nil) }()
		waitFor(t, filepath.Join(directory, "login.checked.reached"))
		exec1(t, copied.database, `UPDATE users SET password_digest = ? WHERE username = 'browser_member'`, hash(t, "Changed-While-Checking-1x", bcrypt.MinCost))
		os.WriteFile(filepath.Join(directory, "login.checked.release"), nil, 0o600)
		if response := <-outcome; response.status != http.StatusUnauthorized || response.code(t) != "invalid_credentials" {
			t.Fatalf("a credential changed during the check still signed in: %d %s", response.status, response.body)
		}
		if after := count(t, copied.database, `SELECT COUNT(*) FROM sessions`); after != before {
			t.Fatal("a stale credential created a session")
		}
		parked.stop()
		exec1(t, copied.database, `UPDATE users SET password_digest = ? WHERE username = 'browser_member'`, hash(t, member, bcrypt.MinCost))

		passwordlessDirectory := t.TempDir()
		passwordless := startServer(t, f, copied, serverOptions{seam: true, faults: "login.checked=park", faultDir: passwordlessDirectory})
		client = passwordless.browser()
		token, _ = client.bootstrap()
		outcome = make(chan result, 1)
		go func() { outcome <- client.login("browser_member", member, token, nil) }()
		waitFor(t, filepath.Join(passwordlessDirectory, "login.checked.reached"))
		exec1(t, copied.database, `INSERT INTO settings (key, value, value_type, category, created_at, updated_at) VALUES ('auth_disabled', 'true', 'boolean', 'security', '2026-11-15 12:00:00', '2026-11-15 12:00:00') ON CONFLICT(key) DO UPDATE SET value = 'true', value_type = 'boolean'`)
		os.WriteFile(filepath.Join(passwordlessDirectory, "login.checked.release"), nil, 0o600)
		if response := <-outcome; response.status != http.StatusNotImplemented || response.code(t) != "sign_in_unsupported" {
			t.Fatalf("a deployment that became passwordless during the check signed in: %d %s", response.status, response.body)
		}
		if after := count(t, copied.database, `SELECT COUNT(*) FROM sessions`); after != before {
			t.Fatal("a passwordless deployment got a session")
		}
		exec1(t, copied.database, `UPDATE settings SET value = 'false' WHERE key = 'auth_disabled'`)
		passwordless.stop()

		lockWaiter := startServer(t, f, copied, serverOptions{})
		client = lockWaiter.browser()
		token, _ = client.bootstrap()
		held := openDatabase(t, copied.database)
		connection, err := held.Conn(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		if _, err := connection.ExecContext(context.Background(), `BEGIN IMMEDIATE`); err != nil {
			t.Fatal(err)
		}
		waiting := make(chan result, 1)
		go func() { waiting <- client.login("browser_member", member, token, nil) }()
		time.Sleep(600 * time.Millisecond)
		connection.ExecContext(context.Background(), `UPDATE users SET deleted_at = '2026-11-15 12:00:00' WHERE username = 'browser_member'`)
		connection.ExecContext(context.Background(), `COMMIT`)
		connection.Close()
		if response := <-waiting; response.status != http.StatusUnauthorized {
			t.Fatalf("an account deleted while the login waited for the write lock signed in: %d", response.status)
		}
		if after := count(t, copied.database, `SELECT COUNT(*) FROM sessions`); after != before {
			t.Fatal("a deleted account got a session")
		}
		exec1(t, copied.database, `UPDATE users SET deleted_at = NULL WHERE username = 'browser_member'`)
		lockWaiter.stop()

		for _, point := range []string{"login.before-commit", "login.committed"} {
			killed := startServer(t, f, copied, serverOptions{seam: true, faults: point + "=kill", faultDir: directory})
			client = killed.browser()
			token, _ = client.bootstrap()
			payload, _ := json.Marshal(map[string]string{"username": "browser_member", "password": member})
			request, _ := http.NewRequest("POST", killed.base+"/preview/api/v1/auth/login", bytes.NewReader(payload))
			request.Header.Set("Content-Type", "application/json")
			request.Header.Set("Origin", killed.origin)
			request.Header.Set("X-CSRF-Token", token)
			if response, err := client.client.Do(request); err == nil {
				response.Body.Close()
				t.Fatalf("%s: the client received an answer", point)
			}
			killed.kill()
			stored := count(t, copied.database, `SELECT COUNT(*) FROM sessions`)
			if point == "login.before-commit" && stored != before || point == "login.committed" && stored != before+1 {
				t.Fatalf("%s left %d sessions (from %d)", point, stored, before)
			}
			recovered := startServer(t, f, copied, serverOptions{})
			retry := recovered.browser()
			if _, _ = retry.signIn("browser_member", member); count(t, copied.database, `SELECT COUNT(*) FROM sessions`) != stored+1 {
				t.Fatalf("%s: the retry did not create exactly one session", point)
			}
			recovered.stop()
			before = count(t, copied.database, `SELECT COUNT(*) FROM sessions`)
		}

		abandoned := startServer(t, f, copied, serverOptions{seam: true, faults: "login.locked=park", faultDir: directory})
		client = abandoned.browser()
		token, _ = client.bootstrap()
		ctx, cancel := context.WithCancel(context.Background())
		payload, _ := json.Marshal(map[string]string{"username": "browser_member", "password": member})
		request, _ := http.NewRequestWithContext(ctx, "POST", abandoned.base+"/preview/api/v1/auth/login", bytes.NewReader(payload))
		request.Header.Set("Content-Type", "application/json")
		request.Header.Set("Origin", abandoned.origin)
		request.Header.Set("X-CSRF-Token", token)
		request.AddCookie(&http.Cookie{Name: "shelfarr_login", Value: client.cookie("shelfarr_login")})
		done := make(chan struct{})
		go func() { http.DefaultClient.Do(request); close(done) }()
		waitFor(t, filepath.Join(directory, "login.locked.reached"))
		cancel()
		<-done
		time.Sleep(300 * time.Millisecond)
		if after := count(t, copied.database, `SELECT COUNT(*) FROM sessions`); after != before {
			t.Fatalf("an abandoned login created a session: %d to %d", before, after)
		}
		noSecrets(t, abandoned.log.String(), secretsOf(f)...)
	})
}

func waitFor(t *testing.T, path string) {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("%s never appeared", filepath.Base(path))
}

func TestBrowserDataRefusesWhatTheRuntimeCannotRenderInsteadOfEmptyingIt(t *testing.T) {
	eachFixture(t, func(t *testing.T, f fixture, copied runtimeCopy) {
		instance := startServer(t, f, copied, serverOptions{})
		client := instance.browser()
		account, token := client.signIn("browser_member", f.personas.Passwords["browser_member"])
		library := client.get("/preview/api/v1/library", account)
		book := firstBook(t, library)
		mixed := filepath.Join(f.doc.ExtraMediaRoot, "Mixed Formats")
		sparse := filepath.Join(f.doc.ExtraMediaRoot, "browser-comic.epub")
		cases := map[string]struct {
			setup string
			args  []any
			code  string
		}{
			"pdf and cbz assets":    {`UPDATE books SET file_path = ? WHERE id = ?`, []any{mixed, book}, "unsupported_asset_format"},
			"html in a description": {`UPDATE books SET description = '<p>Hi</p>' WHERE id = ? AND ? <> ''`, []any{book, mixed}, "unsupported_stored_value"},
			"a comic record":        {`UPDATE books SET book_type = 2, file_path = ? WHERE id = ?`, []any{sparse, book}, "unsupported_publication_kind"},
		}
		original := rows(t, copied.database, `SELECT file_path, description, book_type FROM books WHERE id = ?`, book)[0]
		for name, test := range cases {
			exec1(t, copied.database, test.setup, test.args...)
			detail := client.get("/preview/api/v1/library/"+book, account)
			if detail.status != http.StatusNotImplemented || detail.code(t) != test.code {
				t.Errorf("%s: detail answered %d %s", name, detail.status, detail.body)
			}
			if name != "html in a description" {
				if list := client.get("/preview/api/v1/library", account); list.status != http.StatusNotImplemented {
					t.Errorf("%s: the listing answered %d, it must not silently drop the book", name, list.status)
				}
			}
			write := client.put("/preview/api/v1/library/"+book+"/reading_status", account, token, `{"status":"finished"}`)
			if write.status != http.StatusNotImplemented {
				t.Errorf("%s: the status write answered %d", name, write.status)
			}
			if count(t, copied.database, `SELECT COUNT(*) FROM consumer_reading_states WHERE book_id = ? AND user_id = ?`, book, f.doc.Users["browser_member"]) != 0 {
				t.Errorf("%s: a refused status write stored a row", name)
			}
			exec1(t, copied.database, `UPDATE books SET file_path = ?, description = ?, book_type = ? WHERE id = ?`, original["file_path"], original["description"], original["book_type"], book)
		}
		if client.get("/preview/api/v1/library/"+book, account).status != http.StatusOK {
			t.Fatal("the restored book is not served")
		}
	})
}

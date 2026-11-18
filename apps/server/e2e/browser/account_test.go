//go:build e2e

package browser

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/account"
)

type accountRule struct {
	Kind         string          `json:"kind"`
	Name         string          `json:"name"`
	Password     string          `json:"password"`
	Confirmation string          `json:"confirmation"`
	OIDC         bool            `json:"oidc"`
	Rails        json.RawMessage `json:"rails"`
}

type accountCapture struct {
	Rules                []accountRule  `json:"rules"`
	ProductionBcryptCost json.Number    `json:"production_bcrypt_cost"`
	RailsEffects         map[string]any `json:"rails_effects"`
}

const (
	profilePath  = "/preview/api/v1/account/profile"
	passwordPath = "/preview/api/v1/account/password"
)

var railsTimestamp = regexp.MustCompile(`^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d(\.\d{6})?$`)

func capturedAccount(t *testing.T, f fixture) accountCapture {
	t.Helper()
	var document struct {
		Account accountCapture `json:"account"`
	}
	readJSON(t, filepath.Join(f.dir, "cases.json"), &document)
	if len(document.Account.Rules) == 0 || document.Account.RailsEffects == nil {
		t.Fatal("the Rails capture carries no account cases")
	}
	return document.Account
}

func railsVerdict(t *testing.T, rule accountRule) (account.FieldErrors, bool) {
	t.Helper()
	if string(rule.Rails) == `"raises"` {
		return nil, true
	}
	found := account.FieldErrors{}
	if err := json.Unmarshal(rule.Rails, &found); err != nil {
		t.Fatalf("rails verdict %s", rule.Rails)
	}
	return found, false
}

func deliberatePassword(rule accountRule) bool {
	return rule.Password == "" || strings.ContainsRune(rule.Password, 0) || !rule.OIDC && account.Blank(rule.Password)
}

func goPasswordVerdict(rule accountRule) account.FieldErrors {
	return account.NewPasswordErrors(rule.Password, rule.Confirmation, rule.OIDC)
}

func TestAccountRulesMatchTheRailsModel(t *testing.T) {
	for _, f := range fixtures(t) {
		t.Run(f.name, func(t *testing.T) {
			captured := capturedAccount(t, f)
			if captured.ProductionBcryptCost.String() != "12" || account.PasswordCost != 12 {
				t.Fatalf("Rails produces cost %s digests in production, Go %d", captured.ProductionBcryptCost, account.PasswordCost)
			}
			compared, deliberate := 0, 0
			for _, rule := range captured.Rules {
				rails, raises := railsVerdict(t, rule)
				switch {
				case rule.Kind == "name":
					if got := account.NameErrors(rule.Name); !reflect.DeepEqual(got, rails) {
						t.Errorf("name %q: Go %v, Rails %v", rule.Name, got, rails)
					}
					compared++
				case deliberatePassword(rule):
					got := goPasswordVerdict(rule)
					if len(got["password"]) == 0 || !raises && len(rails["password"]) != 0 {
						t.Errorf("password %q: Go %v must refuse what Rails accepts or crashes on (%s)", rule.Password, got, rule.Rails)
					}
					deliberate++
				default:
					if got := goPasswordVerdict(rule); !reflect.DeepEqual(got, rails) {
						t.Errorf("password %q/%q oidc=%t: Go %v, Rails %v", rule.Password, rule.Confirmation, rule.OIDC, got, rails)
					}
					compared++
				}
			}
			if compared < 50 || deliberate != 8 {
				t.Fatalf("compared %d cases, %d deliberate differences", compared, deliberate)
			}
		})
	}
}

func (b *browser) accountWrite(method, path, account, token string, body any) result {
	b.t.Helper()
	encoded, err := json.Marshal(body)
	if err != nil {
		b.t.Fatal(err)
	}
	return b.do(method, path, map[string]string{"X-Shelfarr-Account": account, "Accept": "application/json", "Content-Type": "application/json", "Origin": b.server.origin, "X-CSRF-Token": token}, encoded)
}

func (b *browser) rename(account, token, name string) result {
	return b.accountWrite(http.MethodPut, profilePath, account, token, map[string]string{"name": name})
}

func (b *browser) changePassword(account, token, current, password, confirmation string) result {
	return b.accountWrite(http.MethodPost, passwordPath, account, token, map[string]string{"current_password": current, "password": password, "password_confirmation": confirmation})
}

func errorsOf(t *testing.T, response result) account.FieldErrors {
	t.Helper()
	var body struct {
		Account string              `json:"account"`
		Errors  account.FieldErrors `json:"errors"`
	}
	if response.status != http.StatusUnprocessableEntity || json.Unmarshal(response.body, &body) != nil || body.Account == "" {
		t.Fatalf("not a validation answer: %d %s", response.status, response.body)
	}
	return body.Errors
}

func userValue(t *testing.T, path, column, username string) string {
	t.Helper()
	found := rows(t, path, `SELECT CAST(`+column+` AS TEXT) AS value FROM users WHERE username = ?`, username)
	value, _ := found[0]["value"].(string)
	return value
}

func tokenRows(t *testing.T, path string) []map[string]any {
	t.Helper()
	return rows(t, path, `SELECT id, user_id, CAST(revoked_at AS TEXT) AS revoked, CAST(updated_at AS TEXT) AS updated, token_digest FROM api_tokens ORDER BY id`)
}

func personaStatus(t *testing.T, instance *server, f fixture, name string) int {
	t.Helper()
	p := f.personas.Personas[name]
	return instance.bare().do("GET", "/preview/api/v1/session", map[string]string{"Cookie": "session_id=" + p.Cookie, "X-Shelfarr-Account": jsonID(p.UserID), "Accept": "application/json"}, nil).status
}

func jsonID(id int64) string {
	encoded, _ := json.Marshal(id)
	return string(encoded)
}

func accountServer(t *testing.T, f fixture, copied runtimeCopy, options serverOptions) *server {
	t.Helper()
	options.arguments = append(options.arguments, "-login-attempts", "1000")
	return startServer(t, f, copied, options)
}

func TestAccountChangesOverRealHTTPHaveTheRailsEffects(t *testing.T) {
	eachFixture(t, func(t *testing.T, f fixture, copied runtimeCopy) {
		captured := capturedAccount(t, f)
		rails := captured.RailsEffects
		for _, key := range []string{"own_sessions_after", "other_sessions_kept", "tokens_unchanged", "new_password_authenticates"} {
			if rails[key] != true {
				t.Fatalf("the Rails reference run did not show %s: %v", key, rails)
			}
		}
		if rails["renamed"] != "Zoë 📚" || rails["blank_name_status"] != json.Number("422") {
			t.Fatalf("Rails reference rename %v", rails)
		}
		instance := accountServer(t, f, copied, serverOptions{})
		original := f.personas.Passwords["browser_account"]
		client := instance.browser()
		id, token := client.signIn("browser_account", original)
		before := map[string]string{"updated": userValue(t, copied.database, "updated_at", "browser_account"), "name": userValue(t, copied.database, "name", "browser_account")}
		shown := client.get("/preview/api/v1/account", id)
		want := map[string]any{"account": id, "profile": map[string]any{"id": id, "username": "browser_account", "name": "Browser account"}}
		if shown.status != http.StatusOK || !reflect.DeepEqual(shown.json(t), want) {
			t.Fatalf("account %d %s", shown.status, shown.body)
		}
		if userValue(t, copied.database, "updated_at", "browser_account") != before["updated"] {
			t.Fatal("opening the account wrote to it")
		}
		if got := errorsOf(t, client.rename(id, token, "   ")); !reflect.DeepEqual(got, account.FieldErrors{"name": {"can't be blank"}}) {
			t.Fatalf("blank %v", got)
		}
		name := "Zoë 📚 \u2728 \u05e9\u05dc\u05d5\u05dd"
		if response := client.rename(id, token, name); response.status != http.StatusOK || userValue(t, copied.database, "name", "browser_account") != name {
			t.Fatalf("rename %d %s", response.status, response.body)
		}
		if stamp := userValue(t, copied.database, "updated_at", "browser_account"); !railsTimestamp.MatchString(stamp) || stamp == before["updated"] {
			t.Fatalf("updated_at %q", stamp)
		}
		digest := userValue(t, copied.database, "password_digest", "browser_account")
		if got := errorsOf(t, client.changePassword(id, token, "Wrong-Passw0rd-123", "Go-Changed-Passw0rd-1", "Go-Changed-Passw0rd-1")); !reflect.DeepEqual(got, account.FieldErrors{"current_password": {"is incorrect"}}) {
			t.Fatalf("wrong current %v", got)
		}
		if userValue(t, copied.database, "password_digest", "browser_account") != digest {
			t.Fatal("a wrong current password changed the digest")
		}
		for _, persona := range []string{"account-elsewhere", "account-elsewhere-b", "alice", "bob", "member"} {
			if status := personaStatus(t, instance, f, persona); status != http.StatusOK {
				t.Fatalf("%s was not signed in before the change: %d", persona, status)
			}
		}
		tokens := tokenRows(t, copied.database)
		others := rows(t, copied.database, `SELECT id FROM sessions WHERE user_id != ? ORDER BY id`, f.doc.Users["browser_account"])
		changed := "Go-Changed-Passw0rd-1"
		if response := client.changePassword(id, token, original, changed, changed); response.status != http.StatusOK || strings.Contains(string(response.body), changed) {
			t.Fatalf("change %d %s", response.status, response.body)
		}
		stored := userValue(t, copied.database, "password_digest", "browser_account")
		if cost, err := bcrypt.Cost([]byte(stored)); err != nil || cost != 12 || !strings.HasPrefix(stored, "$2a$12$") || bcrypt.CompareHashAndPassword([]byte(stored), []byte(changed)) != nil {
			t.Fatalf("digest %.7s", stored)
		}
		if own := rows(t, copied.database, `SELECT id FROM sessions WHERE user_id = ?`, f.doc.Users["browser_account"]); len(own) != 1 {
			t.Fatalf("own sessions after %v", own)
		}
		if after := rows(t, copied.database, `SELECT id FROM sessions WHERE user_id != ? ORDER BY id`, f.doc.Users["browser_account"]); !reflect.DeepEqual(after, others) {
			t.Fatal("another account's sessions changed")
		}
		if !reflect.DeepEqual(tokenRows(t, copied.database), tokens) {
			t.Fatal("API tokens changed, which the Rails password change does not do")
		}
		for persona, wanted := range map[string]int{"account-elsewhere": http.StatusUnauthorized, "account-elsewhere-b": http.StatusUnauthorized, "alice": http.StatusOK, "bob": http.StatusOK, "member": http.StatusOK} {
			if status := personaStatus(t, instance, f, persona); status != wanted {
				t.Fatalf("%s answered %d after the change", persona, status)
			}
		}
		if response := client.get("/preview/api/v1/library", id); response.status != http.StatusOK {
			t.Fatalf("the current session stopped working: %d", response.status)
		}
		if response := client.rename(id, token, name); response.status != http.StatusOK {
			t.Fatalf("the current CSRF token stopped working: %d", response.status)
		}
		fresh := instance.browser()
		pre, _ := fresh.bootstrap()
		if response := fresh.login("browser_account", original, pre, nil); response.status != http.StatusUnauthorized {
			t.Fatalf("the old password still signs in: %d", response.status)
		}
		fresh.signIn("browser_account", changed)

		legacy := instance.browser()
		legacyID, legacyToken := legacy.signIn("browser_legacy", f.personas.Passwords["browser_legacy"])
		if old := userValue(t, copied.database, "password_digest", "browser_legacy"); !strings.HasPrefix(old, "$2y$10$") {
			t.Fatalf("legacy digest %.7s", old)
		}
		legacyChanged := "Go-Legacy-Passw0rd-2"
		if response := legacy.changePassword(legacyID, legacyToken, f.personas.Passwords["browser_legacy"], legacyChanged, legacyChanged); response.status != http.StatusOK {
			t.Fatalf("legacy change %d %s", response.status, response.body)
		}
		if status := personaStatus(t, instance, f, "legacy-elsewhere"); status != http.StatusUnauthorized {
			t.Fatalf("the legacy account's other session survived: %d", status)
		}

		current := changed
		for _, rule := range captured.Rules {
			if rule.Kind != "password" || rule.OIDC {
				continue
			}
			response := client.changePassword(id, token, current, rule.Password, rule.Confirmation)
			expected := goPasswordVerdict(rule)
			if len(expected) == 0 {
				if response.status != http.StatusOK {
					t.Fatalf("%q answered %d %s", rule.Password, response.status, response.body)
				}
				current = rule.Password
				continue
			}
			if got := errorsOf(t, response); !reflect.DeepEqual(got, expected) {
				t.Fatalf("%q over HTTP: %v, rules %v", rule.Password, got, expected)
			}
		}
		if logs := instance.log.String(); strings.Contains(logs, changed) || strings.Contains(logs, original) || strings.Contains(logs, "$2a$") || strings.Contains(logs, "$2y$") {
			t.Fatal("a password or digest reached the log")
		}
		exportAccountForRails(t, f, copied, map[string]string{
			"cookie": client.cookie("session_id"), "password": current, "old_password": original, "name": name,
			"legacy_password": legacyChanged, "legacy_old_password": f.personas.Passwords["browser_legacy"],
		})
	})
}

func exportAccountForRails(t *testing.T, f fixture, copied runtimeCopy, state map[string]string) {
	t.Helper()
	target := os.Getenv("SHELFARR_BROWSER_GO_DIR")
	if target == "" {
		return
	}
	database := openDatabase(t, copied.database)
	if _, err := database.Exec(`PRAGMA wal_checkpoint(TRUNCATE)`); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(copied.database)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(target, "account-"+f.name+".sqlite3"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	encoded, _ := json.Marshal(state)
	if err := os.WriteFile(filepath.Join(target, "account-"+f.name+".json"), encoded, 0o600); err != nil {
		t.Fatal(err)
	}
}

type parkedChange struct {
	instance  *server
	client    *browser
	id, token string
	directory string
	outcome   chan result
}

func parkPasswordChange(t *testing.T, f fixture, copied runtimeCopy, point, password string, clock ...string) parkedChange {
	t.Helper()
	directory := t.TempDir()
	options := serverOptions{seam: true, faults: point + "=park", faultDir: directory}
	if len(clock) == 1 {
		options.clockFile = clock[0]
	}
	instance := accountServer(t, f, copied, options)
	client := instance.browser()
	id, token := client.signIn("browser_account", f.personas.Passwords["browser_account"])
	outcome := make(chan result, 1)
	go func() {
		outcome <- client.changePassword(id, token, f.personas.Passwords["browser_account"], password, password)
	}()
	waitFor(t, filepath.Join(directory, point+".reached"))
	return parkedChange{instance: instance, client: client, id: id, token: token, directory: directory, outcome: outcome}
}

func (p parkedChange) release(t *testing.T, point string) result {
	t.Helper()
	if err := os.WriteFile(filepath.Join(p.directory, point+".release"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	return <-p.outcome
}

func TestAccountPasswordChangesRecheckEverythingInsideTheWrite(t *testing.T) {
	eachFixture(t, func(t *testing.T, f fixture, copied runtimeCopy) {
		original := f.personas.Passwords["browser_account"]
		digest := userValue(t, copied.database, "password_digest", "browser_account")
		owned := count(t, copied.database, `SELECT COUNT(*) FROM sessions WHERE user_id = ?`, f.doc.Users["browser_account"])

		parked := parkPasswordChange(t, f, copied, "password.checked", "Parked-Passw0rd-1")
		holder := openDatabase(t, copied.database)
		started := time.Now()
		if _, err := holder.Exec(`BEGIN IMMEDIATE; UPDATE users SET updated_at = updated_at WHERE id = -1; COMMIT`); err != nil || time.Since(started) > time.Second {
			t.Fatalf("a write lock was held while the passwords were checked: %v after %v", err, time.Since(started))
		}
		elsewhere := hash(t, "Changed-Elsewhere-1x", bcrypt.MinCost)
		exec1(t, copied.database, `UPDATE users SET password_digest = ? WHERE username = 'browser_account'`, elsewhere)
		if response := parked.release(t, "password.checked"); response.status != http.StatusConflict || response.code(t) != "account_conflict" {
			t.Fatalf("an overlapping change was overwritten: %d %s", response.status, response.body)
		}
		if userValue(t, copied.database, "password_digest", "browser_account") != elsewhere || count(t, copied.database, `SELECT COUNT(*) FROM sessions WHERE user_id = ?`, f.doc.Users["browser_account"]) != owned+1 {
			t.Fatal("the refused change wrote something")
		}
		parked.instance.stop()
		exec1(t, copied.database, `UPDATE users SET password_digest = ? WHERE username = 'browser_account'`, digest)

		parked = parkPasswordChange(t, f, copied, "password.checked", "Parked-Passw0rd-1")
		exec1(t, copied.database, `UPDATE users SET oidc_provider = 'sso', oidc_uid = 'late' WHERE username = 'browser_account'`)
		if response := parked.release(t, "password.checked"); response.status != http.StatusConflict {
			t.Fatalf("a sign-in link added meanwhile was ignored: %d", response.status)
		}
		exec1(t, copied.database, `UPDATE users SET oidc_provider = NULL, oidc_uid = NULL WHERE username = 'browser_account'`)
		parked.instance.stop()

		for name, change := range map[string]string{
			"revoked session": `DELETE FROM sessions WHERE user_id = (SELECT id FROM users WHERE username = 'browser_account') AND id = (SELECT MAX(id) FROM sessions)`,
			"deleted account": `UPDATE users SET deleted_at = '2026-11-15 12:00:00' WHERE username = 'browser_account'`,
		} {
			parked = parkPasswordChange(t, f, copied, "password.checked", "Parked-Passw0rd-1")
			exec1(t, copied.database, change)
			if response := parked.release(t, "password.checked"); response.status != http.StatusUnauthorized || response.code(t) != "signed_out" {
				t.Fatalf("%s: %d %s", name, response.status, response.body)
			}
			if userValue(t, copied.database, "password_digest", "browser_account") != digest {
				t.Fatalf("%s: the digest changed", name)
			}
			parked.instance.stop()
			exec1(t, copied.database, `UPDATE users SET deleted_at = NULL WHERE username = 'browser_account'`)
		}

		clock := filepath.Join(t.TempDir(), "clock")
		setClock(t, clock, "2026-11-15T12:00:00Z")
		parked = parkPasswordChange(t, f, copied, "password.checked", "Parked-Passw0rd-1", clock)
		setClock(t, clock, "2026-12-15T12:00:00.000001Z")
		if response := parked.release(t, "password.checked"); response.status != http.StatusUnauthorized || response.code(t) != "signed_out" {
			t.Fatalf("a session that expired during the check changed the password: %d %s", response.status, response.body)
		}
		if userValue(t, copied.database, "password_digest", "browser_account") != digest {
			t.Fatal("an expired session changed the digest")
		}
		parked.instance.stop()

		for _, point := range []string{"password.locked", "password.before-commit"} {
			sessions := rows(t, copied.database, `SELECT id FROM sessions ORDER BY id`)
			failing := accountServer(t, f, copied, serverOptions{seam: true, faults: point + "=error", faultDir: t.TempDir()})
			client := failing.browser()
			id, token := client.signIn("browser_account", original)
			if response := client.changePassword(id, token, original, "Failing-Passw0rd-1", "Failing-Passw0rd-1"); response.status < 500 {
				t.Fatalf("%s: %d", point, response.status)
			}
			if userValue(t, copied.database, "password_digest", "browser_account") != digest {
				t.Fatalf("%s: the digest changed without its session revocations", point)
			}
			if after := rows(t, copied.database, `SELECT id FROM sessions ORDER BY id`); len(after) != len(sessions)+1 {
				t.Fatalf("%s: sessions were revoked without the password change", point)
			}
			failing.stop()
		}

		killed := accountServer(t, f, copied, serverOptions{seam: true, faults: "password.before-commit=kill", faultDir: t.TempDir()})
		client := killed.browser()
		id, token := client.signIn("browser_account", original)
		sessions := count(t, copied.database, `SELECT COUNT(*) FROM sessions`)
		if response, err := client.client.Do(mustRequest(t, killed, id, token, original)); err == nil {
			response.Body.Close()
			t.Fatal("the killed server answered")
		}
		killed.kill()
		if userValue(t, copied.database, "password_digest", "browser_account") != digest || count(t, copied.database, `SELECT COUNT(*) FROM sessions`) != sessions {
			t.Fatal("a crash before commit left a partial change")
		}
		restarted := accountServer(t, f, copied, serverOptions{})
		restarted.browser().signIn("browser_account", original)
		restarted.stop()

		failingName := accountServer(t, f, copied, serverOptions{seam: true, faults: "profile.before-commit=error", faultDir: t.TempDir()})
		client = failingName.browser()
		id, token = client.signIn("browser_account", original)
		name := userValue(t, copied.database, "name", "browser_account")
		if response := client.rename(id, token, "Rolled Back"); response.status < 500 || userValue(t, copied.database, "name", "browser_account") != name {
			t.Fatalf("a failed rename was kept: %d", response.status)
		}
		failingName.stop()
	})
}

func mustRequest(t *testing.T, instance *server, id, token, current string) *http.Request {
	t.Helper()
	payload, _ := json.Marshal(map[string]string{"current_password": current, "password": "Killed-Passw0rd-1", "password_confirmation": "Killed-Passw0rd-1"})
	request, err := http.NewRequest(http.MethodPost, instance.base+passwordPath, strings.NewReader(string(payload)))
	if err != nil {
		t.Fatal(err)
	}
	for name, value := range map[string]string{"Content-Type": "application/json", "Origin": instance.origin, "X-CSRF-Token": token, "X-Shelfarr-Account": id} {
		request.Header.Set(name, value)
	}
	return request
}

func TestConcurrentAccountChangesNeverLoseOrMixAWrite(t *testing.T) {
	eachFixture(t, func(t *testing.T, f fixture, copied runtimeCopy) {
		original := f.personas.Passwords["browser_account"]
		instance := accountServer(t, f, copied, serverOptions{})
		first, second := instance.browser(), instance.browser()
		firstID, firstToken := first.signIn("browser_account", original)
		secondID, secondToken := second.signIn("browser_account", original)
		candidates := []string{"Racing-Passw0rd-A1", "Racing-Passw0rd-B2"}
		answers := make([]result, 2)
		var group sync.WaitGroup
		for index, client := range []*browser{first, second} {
			group.Add(1)
			go func() {
				defer group.Done()
				id, token := firstID, firstToken
				if index == 1 {
					id, token = secondID, secondToken
				}
				answers[index] = client.changePassword(id, token, original, candidates[index], candidates[index])
			}()
		}
		group.Wait()
		winners := 0
		var winner string
		for index, answer := range answers {
			switch answer.status {
			case http.StatusOK:
				winners++
				winner = candidates[index]
			case http.StatusUnauthorized, http.StatusConflict:
			default:
				t.Fatalf("answer %d: %d %s", index, answer.status, answer.body)
			}
		}
		stored := userValue(t, copied.database, "password_digest", "browser_account")
		if winners != 1 || bcrypt.CompareHashAndPassword([]byte(stored), []byte(winner)) != nil {
			t.Fatalf("%d changes won; the stored digest does not match the winner", winners)
		}
		if own := count(t, copied.database, `SELECT COUNT(*) FROM sessions WHERE user_id = ?`, f.doc.Users["browser_account"]); own != 1 {
			t.Fatalf("%d sessions of the account remain", own)
		}

		client := instance.browser()
		id, token := client.signIn("browser_account", winner)
		group = sync.WaitGroup{}
		var renamed, changed result
		group.Add(2)
		go func() { defer group.Done(); renamed = client.rename(id, token, "Concurrent Name") }()
		go func() {
			defer group.Done()
			changed = client.changePassword(id, token, winner, "Racing-Passw0rd-C3", "Racing-Passw0rd-C3")
		}()
		group.Wait()
		if renamed.status != http.StatusOK || changed.status != http.StatusOK {
			t.Fatalf("rename %d, change %d", renamed.status, changed.status)
		}
		stored = userValue(t, copied.database, "password_digest", "browser_account")
		if userValue(t, copied.database, "name", "browser_account") != "Concurrent Name" || bcrypt.CompareHashAndPassword([]byte(stored), []byte("Racing-Passw0rd-C3")) != nil {
			t.Fatal("one of two concurrent changes to the same account was lost")
		}
	})
}

//go:build e2e

package pairing

import (
	"bytes"
	"context"
	"database/sql"
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
)

var epoch = time.Date(2026, 11, 15, 12, 0, 0, 123456000, time.UTC)

func stamp(moment time.Time) string {
	text := moment.UTC().Format("2006-01-02 15:04:05")
	if micro := moment.UTC().Nanosecond() / 1000; micro > 0 {
		text += fmt.Sprintf(".%06d", micro)
	}
	return text
}

func eachFixture(t *testing.T, run func(t *testing.T, f fixture, copied runtimeCopy)) {
	t.Helper()
	for _, f := range fixtures(t) {
		t.Run(f.name, func(t *testing.T) { run(t, f, newRuntimeCopy(t, f)) })
	}
}

func seamServer(t *testing.T, f fixture, copied runtimeCopy, options serverOptions) (*server, api) {
	t.Helper()
	clock := filepath.Join(t.TempDir(), "clock")
	setClock(t, clock, epoch.Format(time.RFC3339Nano))
	options.seam, options.clockFile = true, clock
	instance := startServer(t, f, copied, options)
	return instance, api{t: t, instance: instance, f: f, clock: clock}
}

type grantSeed struct {
	device   string
	user     int64
	approved bool
	denied   bool
	expires  time.Time
	replaces int64
	scopes   string
	client   string
}

func seedGrant(t *testing.T, database string, seed grantSeed) {
	t.Helper()
	if seed.client == "" {
		seed.client = "Seeded app"
	}
	var user, replaces, scopes, approved, denied any
	if seed.user != 0 {
		user = seed.user
	}
	if seed.replaces != 0 {
		replaces = seed.replaces
	}
	if seed.scopes != "" {
		scopes = seed.scopes
	}
	if seed.approved {
		approved = stamp(epoch.Add(-time.Second))
	}
	if seed.denied {
		denied = stamp(epoch.Add(-time.Second))
	}
	if seed.expires.IsZero() {
		seed.expires = epoch.Add(10 * time.Minute)
	}
	exec1(t, database, `INSERT INTO consumer_device_grants (user_id, client_name, device_code_digest, user_code_digest, expires_at, approved_at, denied_at, scopes, replaces_api_token_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		user, seed.client, digestOf(seed.device), digestOf("user-"+seed.device), stamp(seed.expires), approved, denied, scopes, replaces, stamp(epoch), stamp(epoch))
}

func seedToken(t *testing.T, database, raw string, userID int64, key string, replaces int64) int64 {
	t.Helper()
	var replacesValue, keyValue any
	if replaces != 0 {
		replacesValue = replaces
	}
	if key != "" {
		keyValue = key
	}
	exec1(t, database, `INSERT INTO api_tokens (user_id, name, scopes, token_digest, token_prefix, issued_via, replaces_api_token_id, connection_key, created_at, updated_at) VALUES (?, 'seeded', '["library:read","progress:write"]', ?, ?, 'consumer_device', ?, ?, ?, ?)`,
		userID, digestOf(raw), raw[:12], replacesValue, keyValue, stamp(epoch.Add(-time.Hour)), stamp(epoch.Add(-time.Hour)))
	return count(t, database, `SELECT id FROM api_tokens WHERE token_digest = ?`, digestOf(raw))
}

func freshCode(label string) string {
	return digestOf(label + time.Now().String())
}

func freshRaw(label string) string {
	return "shf_" + digestOf(label + time.Now().String())[:40]
}

func holdWriteLock(t *testing.T, path string) func() {
	t.Helper()
	database, err := sql.Open("sqlite", "file:"+path+"?_pragma=busy_timeout(10000)")
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
		conn.ExecContext(context.Background(), `COMMIT`)
		conn.Close()
		database.Close()
	}
}

func fileHolds(t *testing.T, directory string, secrets ...string) string {
	t.Helper()
	entries, _ := filepath.Glob(filepath.Join(directory, "primary.sqlite3*"))
	for _, path := range entries {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		for _, secret := range secrets {
			if secret != "" && bytes.Contains(data, []byte(secret)) {
				return filepath.Base(path)
			}
		}
	}
	return ""
}

func noSecrets(t *testing.T, text string, secrets ...string) {
	t.Helper()
	for _, secret := range secrets {
		if secret != "" && strings.Contains(text, secret) {
			t.Fatalf("a synthetic secret appears in the output: %.12s…", secret)
		}
	}
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

func release(t *testing.T, directory, point string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(directory, point+".release"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestTheProductionBinaryPairsOnRealTimeAndHasNoSeams(t *testing.T) {
	eachFixture(t, func(t *testing.T, f fixture, copied runtimeCopy) {
		directory := t.TempDir()
		stale := filepath.Join(directory, "clock")
		setClock(t, stale, "2001-01-01T00:00:00Z")
		instance := startServer(t, f, copied, serverOptions{env: []string{"SHELFARR_E2E_CLOCK_FILE=" + stale, "SHELFARR_FAULT_POINTS=device.locked=kill,exchange.before-commit=kill,decide.locked=kill", "SHELFARR_FAULT_DIR=" + directory}})
		a := api{t: t, instance: instance, f: f, clock: stale}
		one := a.consenter("pair_one")
		got, device := a.device(`{"client_name":"Real Clock App","scope":"library:read progress:write search:read requests:read requests:write"}`, "")
		mustStatus(t, "device", got, 200)
		before := time.Now().UTC()
		mustStatus(t, "allow", one.decide(str(device["user_code"]), "allow"), 200)
		got, issued := a.poll(str(device["device_code"]))
		mustStatus(t, "exchange", got, 200)
		raw := str(issued["access_token"])
		if a.me(raw) != 200 {
			t.Fatal("the issued token does not work")
		}
		rowsFound := rows(t, copied.database, `SELECT CAST(expires_at AS TEXT) AS expires_at, scopes FROM api_tokens WHERE token_digest = ?`, digestOf(raw))
		expires, err := time.Parse("2006-01-02 15:04:05.999999", str(rowsFound[0]["expires_at"]))
		if err != nil || expires.Before(before.Add(30*24*time.Hour-time.Minute)) || expires.After(time.Now().UTC().Add(30*24*time.Hour+time.Minute)) {
			t.Fatalf("expiry %v is not thirty days from now", rowsFound[0]["expires_at"])
		}
		if got, replay := a.poll(str(device["device_code"])); got.status != 400 || replay["error"] != "expired_token" {
			t.Fatalf("replay %d %v", got.status, replay)
		}
		if a.revoke(raw) != 204 || a.me(raw) != 401 {
			t.Fatal("revoke did not end the connection")
		}
		instance.stop()
		noSecrets(t, instance.log.String(), raw, str(device["device_code"]), str(device["user_code"]), strings.ReplaceAll(str(device["user_code"]), "-", ""), f.secrets.Passwords["pair_one"])
		if found := fileHolds(t, filepath.Dir(copied.database), raw, str(device["device_code"]), strings.ReplaceAll(str(device["user_code"]), "-", "")); found != "" {
			t.Fatalf("a plaintext secret was persisted in %s", found)
		}
	})
}

func TestExactlyOneExchangeSucceedsUnderConcurrencyAndEveryOtherPollIsExpired(t *testing.T) {
	eachFixture(t, func(t *testing.T, f fixture, copied runtimeCopy) {
		_, a := seamServer(t, f, copied, serverOptions{})
		owner := f.doc.Users["pair_one"]
		device := freshCode("concurrent exchange")
		seedGrant(t, copied.database, grantSeed{device: device, user: owner, approved: true})
		var wait sync.WaitGroup
		outcomes := make([]int, 40)
		answers := make([]string, 40)
		for index := range outcomes {
			wait.Add(1)
			go func(index int) {
				defer wait.Done()
				got, body := a.poll(device)
				outcomes[index] = got.status
				answers[index] = str(body["error"])
			}(index)
		}
		wait.Wait()
		successes, expired := 0, 0
		for index, status := range outcomes {
			switch {
			case status == 200:
				successes++
			case status == 400 && answers[index] == "expired_token":
				expired++
			default:
				t.Errorf("poll %d answered %d %s", index, status, answers[index])
			}
		}
		if successes != 1 || expired != 39 {
			t.Fatalf("%d successes and %d expired answers", successes, expired)
		}
		if issued := count(t, copied.database, `SELECT COUNT(*) FROM api_tokens WHERE name = 'Seeded app'`); issued != 1 {
			t.Fatalf("%d tokens were issued for one grant", issued)
		}
	})
}

func TestConcurrentDecisionsOnOneCodeApplyExactlyOne(t *testing.T) {
	eachFixture(t, func(t *testing.T, f fixture, copied runtimeCopy) {
		_, a := seamServer(t, f, copied, serverOptions{})
		one := a.consenter("pair_one")
		_, device := a.device(`{"client_name":"Contended"}`, "")
		token, _ := one.client.bootstrap()
		var wait sync.WaitGroup
		statuses := make([]int, 24)
		for index := range statuses {
			wait.Add(1)
			go func(index int) {
				defer wait.Done()
				decision := "allow"
				if index%2 == 1 {
					decision = "deny"
				}
				payload := fmt.Sprintf(`{"user_code":%q,"decision":%q}`, str(device["user_code"]), decision)
				got := one.client.do("POST", "/preview/api/v1/connect", map[string]string{"X-Shelfarr-Account": one.account, "Origin": one.origin, "X-CSRF-Token": token}, []byte(payload))
				statuses[index] = got.status
			}(index)
		}
		wait.Wait()
		applied := 0
		for _, status := range statuses {
			switch status {
			case 200:
				applied++
			case 422:
			default:
				t.Fatalf("a decision answered %d", status)
			}
		}
		row := rows(t, copied.database, `SELECT approved_at IS NOT NULL AS approved, denied_at IS NOT NULL AS denied FROM consumer_device_grants WHERE client_name = 'Contended'`)[0]
		if applied != 1 || fmt.Sprint(row["approved"]) == fmt.Sprint(row["denied"]) {
			t.Fatalf("%d decisions applied, row %v", applied, row)
		}
	})
}

func TestConcurrentCreationAndAdoptionKeepEveryInvariant(t *testing.T) {
	eachFixture(t, func(t *testing.T, f fixture, copied runtimeCopy) {
		_, a := seamServer(t, f, copied, serverOptions{})
		owner := f.doc.Users["pair_one"]
		var wait sync.WaitGroup
		codes := make([]string, 15)
		for index := range codes {
			wait.Add(1)
			go func(index int) {
				defer wait.Done()
				got, body := a.device(fmt.Sprintf(`{"client_name":"Parallel %d"}`, index), "")
				if got.status == 200 {
					codes[index] = str(body["device_code"])
				}
			}(index)
		}
		wait.Wait()
		seen := map[string]bool{}
		for _, code := range codes {
			if code == "" || seen[code] {
				t.Fatalf("a parallel creation failed or repeated a code: %q", code)
			}
			seen[code] = true
		}
		if stored := count(t, copied.database, `SELECT COUNT(DISTINCT device_code_digest) FROM consumer_device_grants WHERE client_name LIKE 'Parallel %'`); stored != 15 {
			t.Fatalf("%d distinct grants", stored)
		}
		origin, replacement := freshRaw("origin"), freshRaw("replacement")
		originID := seedToken(t, copied.database, origin, owner, "adoption-key", 0)
		seedToken(t, copied.database, replacement, owner, "adoption-key", originID)
		statuses := make([]int, 20)
		for index := range statuses {
			wait.Add(1)
			go func(index int) {
				defer wait.Done()
				statuses[index] = a.me(replacement)
			}(index)
		}
		wait.Wait()
		for index, status := range statuses {
			if status != 200 {
				t.Fatalf("concurrent first use %d answered %d", index, status)
			}
		}
		row := rows(t, copied.database, `SELECT (SELECT revoked_at IS NOT NULL FROM api_tokens WHERE id = ?) AS origin_revoked, (SELECT replaces_api_token_id IS NULL FROM api_tokens WHERE token_digest = ?) AS adopted, (SELECT revoked_at IS NULL FROM api_tokens WHERE token_digest = ?) AS replacement_active`, originID, digestOf(replacement), digestOf(replacement))[0]
		if fmt.Sprint(row["origin_revoked"]) != "1" || fmt.Sprint(row["adopted"]) != "1" || fmt.Sprint(row["replacement_active"]) != "1" {
			t.Fatalf("adoption state %v", row)
		}
	})
}

func TestAnExplicitRevokeWinsAgainstAnAdoptionInEitherOrder(t *testing.T) {
	eachFixture(t, func(t *testing.T, f fixture, copied runtimeCopy) {
		owner := f.doc.Users["pair_one"]
		other := f.doc.Users["pair_two"]
		bystander := freshRaw("bystander")
		seedToken(t, copied.database, bystander, other, "shared-key", 0)
		for _, order := range []struct{ park, first, second string }{{"adopt.locked", "adopt", "revoke"}, {"revoke.locked", "revoke", "adopt"}} {
			t.Run(order.first+" then "+order.second, func(t *testing.T) {
				directory := t.TempDir()
				_, a := seamServer(t, f, copied, serverOptions{faults: order.park + "=park", faultDir: directory})
				origin, replacement := freshRaw("origin"+order.park), freshRaw("replacement"+order.park)
				originID := seedToken(t, copied.database, origin, owner, "shared-key", 0)
				seedToken(t, copied.database, replacement, owner, "shared-key", originID)
				run := map[string]func() int{"adopt": func() int { return a.me(replacement) }, "revoke": func() int { return a.revoke(origin) }}
				first := make(chan int, 1)
				go func() { first <- run[order.first]() }()
				waitFor(t, filepath.Join(directory, order.park+".reached"))
				second := make(chan int, 1)
				go func() { second <- run[order.second]() }()
				time.Sleep(300 * time.Millisecond)
				release(t, directory, order.park)
				got := map[string]int{order.first: <-first, order.second: <-second}
				if got["revoke"] != 204 {
					t.Fatalf("the explicit revoke answered %d", got["revoke"])
				}
				if order.first == "adopt" && got["adopt"] != 200 || order.first == "revoke" && got["adopt"] != 401 {
					t.Fatalf("adoption answered %d in order %s", got["adopt"], order.first)
				}
				for _, raw := range []string{origin, replacement} {
					if revoked := count(t, copied.database, `SELECT revoked_at IS NOT NULL FROM api_tokens WHERE token_digest = ?`, digestOf(raw)); revoked != 1 {
						t.Fatalf("the explicit revoke left a credential of the connection usable (order %s)", order.first)
					}
				}
				if a.me(bystander) != 200 {
					t.Fatal("a revoke crossed into another account")
				}
				exec1(t, copied.database, `UPDATE api_tokens SET revoked_at = NULL WHERE token_digest = ?`, digestOf(bystander))
			})
		}
	})
}

func TestKilledProcessesLeaveAllOrNothingAndNoPlaintext(t *testing.T) {
	eachFixture(t, func(t *testing.T, f fixture, copied runtimeCopy) {
		owner := f.doc.Users["pair_one"]
		directory := t.TempDir()
		restart := func() (*server, api) { return seamServer(t, f, copied, serverOptions{}) }
		killOn := func(point string) (*server, api) {
			return seamServer(t, f, copied, serverOptions{faults: point + "=kill", faultDir: directory})
		}
		grants := func() int64 { return count(t, copied.database, `SELECT COUNT(*) FROM consumer_device_grants`) }

		for _, point := range []string{"device.before-commit", "device.committed"} {
			before := grants()
			victim, a := killOn(point)
			a.fire("/api/consumer/v1/auth/device", nil, `{"client_name":"Lost response"}`)
			victim.kill()
			want := before
			if point == "device.committed" {
				want = before + 1
			}
			if grants() != want {
				t.Fatalf("%s left %d grants, want %d", point, grants(), want)
			}
			survivor, again := restart()
			if got, _ := again.device(`{"client_name":"Retry"}`, ""); got.status != 200 {
				t.Fatalf("%s: the retry answered %d", point, got.status)
			}
			survivor.stop()
		}

		for _, point := range []string{"exchange.before-commit", "exchange.committed"} {
			device := freshCode(point)
			seedGrant(t, copied.database, grantSeed{device: device, user: owner, approved: true, client: point})
			victim, a := killOn(point)
			a.fire("/api/consumer/v1/auth/token", nil, `{"device_code":"`+device+`"}`)
			victim.kill()
			tokens := count(t, copied.database, `SELECT COUNT(*) FROM api_tokens WHERE name = ?`, point)
			consumed := count(t, copied.database, `SELECT consumed_at IS NOT NULL FROM consumer_device_grants WHERE device_code_digest = ?`, digestOf(device))
			survivor, b := restart()
			got, body := b.poll(device)
			if point == "exchange.before-commit" {
				if tokens != 0 || consumed != 0 || got.status != 200 {
					t.Fatalf("%s: tokens=%d consumed=%d retry=%d", point, tokens, consumed, got.status)
				}
				if found := fileHolds(t, filepath.Dir(copied.database), str(body["access_token"])); found != "" {
					t.Fatalf("a plaintext token was persisted in %s", found)
				}
			} else if tokens != 1 || consumed != 1 || got.status != 400 || body["error"] != "expired_token" {
				t.Fatalf("%s: tokens=%d consumed=%d retry=%d %v", point, tokens, consumed, got.status, body)
			}
			survivor.stop()
		}

		for _, point := range []string{"decide.before-commit", "decide.committed"} {
			victim, a := killOn(point)
			one := a.consenter("pair_one")
			_, device := a.device(`{"client_name":"Decided"}`, "")
			one.fireDecision(str(device["user_code"]), "allow")
			victim.kill()
			approved := count(t, copied.database, `SELECT approved_at IS NOT NULL FROM consumer_device_grants WHERE device_code_digest = ?`, digestOf(str(device["device_code"])))
			want := int64(0)
			if point == "decide.committed" {
				want = 1
			}
			if approved != want {
				t.Fatalf("%s left approved=%d", point, approved)
			}
			survivor, after := restart()
			again := after.consenter("pair_one").decide(str(device["user_code"]), "allow")
			survivor.stop()
			expected := 200
			if want == 1 {
				expected = 422
			}
			if again.status != expected {
				t.Fatalf("%s: retrying the decision answered %d, want %d", point, again.status, expected)
			}
		}

		for _, point := range []string{"revoke.before-commit", "revoke.committed"} {
			first, second := freshRaw(point+"a"), freshRaw(point+"b")
			seedToken(t, copied.database, first, owner, point, 0)
			seedToken(t, copied.database, second, owner, point, 0)
			victim, a := killOn(point)
			a.fire("/api/consumer/v1/auth/revoke", map[string]string{"Authorization": "Bearer " + first}, "{}")
			victim.kill()
			revoked := count(t, copied.database, `SELECT COUNT(*) FROM api_tokens WHERE connection_key = ? AND revoked_at IS NOT NULL`, point)
			want := int64(0)
			if point == "revoke.committed" {
				want = 2
			}
			if revoked != want {
				t.Fatalf("%s left %d revoked tokens, want all or none (%d)", point, revoked, want)
			}
			survivor, b := restart()
			if point == "revoke.before-commit" && (b.revoke(first) != 204 || b.me(second) != 401) {
				t.Fatalf("%s: the retried revoke did not end the connection", point)
			}
			survivor.stop()
		}

		origin := freshRaw("lost origin")
		originID := seedToken(t, copied.database, origin, owner, "lost-upgrade", 0)
		device := freshCode("lost upgrade")
		seedGrant(t, copied.database, grantSeed{device: device, user: owner, approved: true, replaces: originID, scopes: `["library:read","progress:write","search:read","requests:read","requests:write"]`, client: "Lost upgrade"})
		victim, a := killOn("exchange.committed")
		a.fire("/api/consumer/v1/auth/token", nil, `{"device_code":"`+device+`"}`)
		victim.kill()
		_, b := restart()
		if b.me(origin) != 200 {
			t.Fatal("a lost upgrade response stranded the connection: the old credential no longer works")
		}
		got, body := b.poll(device)
		if got.status != 400 || body["error"] != "expired_token" {
			t.Fatalf("a retried upgrade exchange answered %d %v", got.status, body)
		}
		got, again := b.device(`{"client_name":"Lost upgrade","scope":"library:read progress:write search:read requests:read requests:write"}`, origin)
		if got.status != 200 || again["device_code"] == "" {
			t.Fatalf("a new upgrade could not be started from the surviving credential: %d", got.status)
		}
	})
}

func TestLockContentionIsABoundedBusyAnswerNotAnAuthenticationFailure(t *testing.T) {
	eachFixture(t, func(t *testing.T, f fixture, copied runtimeCopy) {
		owner := f.doc.Users["pair_one"]
		origin := freshRaw("busy")
		seedToken(t, copied.database, origin, owner, "busy-key", 0)
		device := freshCode("busy exchange")
		seedGrant(t, copied.database, grantSeed{device: device, user: owner, approved: true, client: "Busy"})
		instance, a := seamServer(t, f, copied, serverOptions{arguments: []string{"-busy-timeout", "300ms"}})
		one := a.consenter("pair_one")
		_, pending := a.device(`{"client_name":"Busy decision"}`, "")
		before := count(t, copied.database, `SELECT COUNT(*) FROM consumer_device_grants`)
		unlock := holdWriteLock(t, copied.database)
		started := time.Now()
		for name, got := range map[string]result{
			"device":  a.post("/api/consumer/v1/auth/device", nil, `{"client_name":"Busy device"}`),
			"token":   a.post("/api/consumer/v1/auth/token", nil, `{"device_code":"`+device+`"}`),
			"revoke":  a.post("/api/consumer/v1/auth/revoke", map[string]string{"Authorization": "Bearer " + origin}, "{}"),
			"consent": one.decide(str(pending["user_code"]), "allow"),
		} {
			if got.status != http.StatusServiceUnavailable || got.code(t) != "database_busy" || got.headers.Get("Retry-After") == "" {
				t.Errorf("%s answered %d %s", name, got.status, got.body)
			}
		}
		if time.Since(started) > 8*time.Second {
			t.Fatalf("contention took %v to refuse", time.Since(started))
		}
		unlock()
		if count(t, copied.database, `SELECT COUNT(*) FROM consumer_device_grants`) != before || count(t, copied.database, `SELECT consumed_at IS NULL FROM consumer_device_grants WHERE device_code_digest = ?`, digestOf(device)) != 1 {
			t.Fatal("a refused request left a trace")
		}
		if got, _ := a.poll(device); got.status != 200 {
			t.Fatalf("the grant could not be exchanged after the lock was released: %d", got.status)
		}
		noSecrets(t, instance.log.String(), origin, device)
	})
}

func TestARequestThatOutlivesItsDeadlineOrItsClientStoresNothing(t *testing.T) {
	eachFixture(t, func(t *testing.T, f fixture, copied runtimeCopy) {
		owner := f.doc.Users["pair_one"]
		directory := t.TempDir()
		device := freshCode("deadline")
		seedGrant(t, copied.database, grantSeed{device: device, user: owner, approved: true, client: "Deadline"})
		_, a := seamServer(t, f, copied, serverOptions{faults: "exchange.locked=park,device.locked=park", faultDir: directory, arguments: []string{"-request-timeout", "700ms"}})
		got, body := a.poll(device)
		if got.status != http.StatusServiceUnavailable || body["error"] != "request_timeout" {
			t.Fatalf("a parked exchange answered %d %s", got.status, got.body)
		}
		got = a.post("/api/consumer/v1/auth/device", nil, `{"client_name":"Deadline create"}`)
		if got.status != http.StatusServiceUnavailable {
			t.Fatalf("a parked creation answered %d", got.status)
		}
		release(t, directory, "exchange.locked")
		release(t, directory, "device.locked")
		time.Sleep(300 * time.Millisecond)
		if count(t, copied.database, `SELECT COUNT(*) FROM api_tokens WHERE name = 'Deadline'`) != 0 || count(t, copied.database, `SELECT COUNT(*) FROM consumer_device_grants WHERE client_name = 'Deadline create'`) != 0 {
			t.Fatal("a timed-out request left state behind")
		}
		if got, _ := a.poll(device); got.status != 200 {
			t.Fatalf("the grant was lost by the timeout: %d", got.status)
		}
	})
}

func TestStateChangedWhileAWriteWaitedIsRecheckedUnderTheLock(t *testing.T) {
	eachFixture(t, func(t *testing.T, f fixture, copied runtimeCopy) {
		owner := f.doc.Users["pair_one"]
		_, a := seamServer(t, f, copied, serverOptions{})
		one := a.consenter("pair_one")

		origin := freshRaw("stale origin")
		originID := seedToken(t, copied.database, origin, owner, "stale-key", 0)
		unlock := holdWriteLock(t, copied.database)
		answer := make(chan result, 1)
		go func() {
			answer <- a.post("/api/consumer/v1/auth/device", map[string]string{"Authorization": "Bearer " + origin}, `{"client_name":"Stale upgrade","scope":"library:read progress:write search:read requests:read requests:write"}`)
		}()
		time.Sleep(200 * time.Millisecond)
		exec1Locked(t, copied.database, unlock, `UPDATE api_tokens SET revoked_at = '2026-11-15 11:00:00' WHERE id = ?`, originID)
		if got := <-answer; got.status != http.StatusUnauthorized {
			t.Fatalf("an upgrade of a credential revoked while the request waited answered %d", got.status)
		}
		if count(t, copied.database, `SELECT COUNT(*) FROM consumer_device_grants WHERE client_name = 'Stale upgrade'`) != 0 {
			t.Fatal("a stale upgrade stored a grant")
		}

		_, pending := a.device(`{"client_name":"Deleted decider"}`, "")
		unlock = holdWriteLock(t, copied.database)
		decision := make(chan result, 1)
		go func() { decision <- one.decide(str(pending["user_code"]), "allow") }()
		time.Sleep(300 * time.Millisecond)
		exec1Locked(t, copied.database, unlock, `UPDATE users SET deleted_at = '2026-11-15 11:00:00' WHERE id = ?`, owner)
		if got := <-decision; got.status != http.StatusForbidden && got.status != http.StatusUnauthorized {
			t.Fatalf("a decision by an account deleted while the request waited answered %d", got.status)
		}
		if count(t, copied.database, `SELECT approved_at IS NULL FROM consumer_device_grants WHERE client_name = 'Deleted decider'`) != 1 {
			t.Fatal("a deleted account approved a grant")
		}
		exec1(t, copied.database, `UPDATE users SET deleted_at = NULL WHERE id = ?`, owner)

		device := freshCode("deleted approver")
		seedGrant(t, copied.database, grantSeed{device: device, user: owner, approved: true, client: "Deleted approver"})
		unlock = holdWriteLock(t, copied.database)
		exchange := make(chan map[string]any, 1)
		go func() { _, body := a.poll(device); exchange <- body }()
		time.Sleep(300 * time.Millisecond)
		exec1Locked(t, copied.database, unlock, `UPDATE users SET deleted_at = '2026-11-15 11:00:00' WHERE id = ?`, owner)
		if body := <-exchange; body["error"] != "access_denied" {
			t.Fatalf("an exchange for an approver deleted while it waited answered %v", body)
		}
		if count(t, copied.database, `SELECT COUNT(*) FROM api_tokens WHERE name = 'Deleted approver'`) != 0 {
			t.Fatal("a token was issued for a deleted approver")
		}
	})
}

func exec1Locked(t *testing.T, path string, unlock func(), statement string, arguments ...any) {
	t.Helper()
	unlock()
	exec1(t, path, statement, arguments...)
}

func TestConsentOverRealHTTPNeedsSessionCSRFOriginAndAccount(t *testing.T) {
	eachFixture(t, func(t *testing.T, f fixture, copied runtimeCopy) {
		instance, a := seamServer(t, f, copied, serverOptions{})
		one, two := a.consenter("pair_one"), a.consenter("pair_two")
		_, device := a.device(`{"client_name":"Guarded"}`, "")
		user := str(device["user_code"])
		pendingState := func() int64 {
			return count(t, copied.database, `SELECT approved_at IS NULL AND denied_at IS NULL FROM consumer_device_grants WHERE client_name = 'Guarded'`)
		}
		tokenOne, _ := one.client.bootstrap()
		tokenTwo, _ := two.client.bootstrap()
		payload := fmt.Sprintf(`{"user_code":%q,"decision":"allow"}`, user)
		headers := func(token, origin, account string, extra map[string]string) map[string]string {
			merged := map[string]string{"X-Shelfarr-Account": account, "Origin": origin, "X-CSRF-Token": token}
			for name, value := range extra {
				merged[name] = value
			}
			return merged
		}
		for name, test := range map[string]struct {
			client  *browser
			headers map[string]string
			status  int
			code    string
		}{
			"missing token":           {one.client, headers("", instance.origin, one.account, nil), 422, "invalid_csrf"},
			"another sessions token":  {one.client, headers(tokenTwo, instance.origin, one.account, nil), 422, "invalid_csrf"},
			"another origin":          {one.client, headers(tokenOne, "http://evil.example", one.account, nil), 422, "invalid_csrf"},
			"null origin":             {one.client, headers(tokenOne, "null", one.account, nil), 422, "invalid_csrf"},
			"cross site fetch":        {one.client, headers(tokenOne, instance.origin, one.account, map[string]string{"Sec-Fetch-Site": "cross-site"}), 422, "invalid_csrf"},
			"another accounts header": {one.client, headers(tokenOne, instance.origin, two.account, nil), 401, "account_changed"},
			"no session":              {instance.bare(), headers(tokenOne, instance.origin, one.account, nil), 401, "signed_out"},
		} {
			got := test.client.do("POST", "/preview/api/v1/connect", test.headers, []byte(payload))
			if got.status != test.status || got.code(t) != test.code {
				t.Errorf("%s answered %d %s", name, got.status, got.body)
			}
		}
		if got := one.client.do("GET", "/preview/api/v1/connect?user_code="+user+"&decision=allow", map[string]string{"X-Shelfarr-Account": one.account}, nil); got.status != 200 {
			t.Fatalf("inspect %d", got.status)
		}
		if got := one.client.do("HEAD", "/preview/api/v1/connect?user_code="+user, map[string]string{"X-Shelfarr-Account": one.account}, nil); got.status != 200 {
			t.Fatalf("head %d", got.status)
		}
		if pendingState() != 1 {
			t.Fatal("a refused or read-only request decided the grant")
		}
		bearerOnly := instance.bare().do("POST", "/preview/api/v1/connect", map[string]string{"Authorization": "Bearer " + f.secrets.Tokens["tok:one-fresh"], "Origin": instance.origin, "X-Shelfarr-Account": one.account, "X-CSRF-Token": tokenOne}, []byte(payload))
		if bearerOnly.status != 401 || pendingState() != 1 {
			t.Fatalf("a bearer authenticated a browser decision: %d", bearerOnly.status)
		}
		sessionOnly := one.client.do("GET", "/api/consumer/v1/me", map[string]string{"Accept": "application/json"}, nil)
		if sessionOnly.status != 401 {
			t.Fatalf("a session cookie authenticated the native API: %d", sessionOnly.status)
		}
		replay := two.client.do("POST", "/preview/api/v1/connect", headers(tokenTwo, instance.origin, two.account, nil), []byte(payload))
		if replay.status != 200 || pendingState() != 0 {
			t.Fatalf("a valid decision answered %d", replay.status)
		}
		one.client.do("POST", "/preview/api/v1/auth/logout", headers(tokenOne, instance.origin, one.account, nil), nil)
		after := one.client.do("POST", "/preview/api/v1/connect", headers(tokenOne, instance.origin, one.account, nil), []byte(payload))
		if after.status != 401 || after.code(t) != "signed_out" {
			t.Fatalf("a token of a signed-out session answered %d", after.status)
		}
	})
}

func TestTheConsentEndpointsAreOffForAccountsOutsideTheAllowlistOrWithoutAnOrigin(t *testing.T) {
	eachFixture(t, func(t *testing.T, f fixture, copied runtimeCopy) {
		only := fmt.Sprint(f.doc.Users["pair_one"])
		instance := startServer(t, f, copied, serverOptions{users: only})
		client := instance.browser()
		token, _ := client.bootstrap()
		got := client.login("pair_two", f.secrets.Passwords["pair_two"], token, nil)
		if got.status != 401 || got.code(t) != "invalid_credentials" {
			t.Fatalf("an account outside the list signed in: %d", got.status)
		}
		instance.stop()
		off := startServer(t, f, copied, serverOptions{noUsers: true})
		if got := off.bare().do("GET", "/preview/api/v1/connect?user_code=BCDF-GHJK", map[string]string{"X-Shelfarr-Account": "1"}, nil); got.status != 404 {
			t.Fatalf("a disabled preview answered %d", got.status)
		}
		if got := off.bare().do("POST", "/api/consumer/v1/auth/device", map[string]string{"Accept": "application/json"}, []byte(`{"client_name":"Still pairs"}`)); got.status != 200 {
			t.Fatalf("native pairing must not depend on the preview allowlist: %d", got.status)
		}
		off.stop()
		noOrigin := startServer(t, f, copied, serverOptions{noOrigin: true})
		got = noOrigin.bare().do("POST", "/api/consumer/v1/auth/device", map[string]string{"Accept": "application/json", "Host": "attacker.example"}, []byte(`{"client_name":"No origin"}`))
		if got.status != 501 || got.code(t) != "browser_origin_not_configured" || strings.Contains(string(got.body), "attacker") {
			t.Fatalf("a missing origin answered %d %s", got.status, got.body)
		}
	})
}

func TestRequestsAreBoundedInSizeTimeAndConcurrency(t *testing.T) {
	eachFixture(t, func(t *testing.T, f fixture, copied runtimeCopy) {
		directory := t.TempDir()
		instance, a := seamServer(t, f, copied, serverOptions{faults: "exchange.locked=park", faultDir: directory, arguments: []string{"-body-timeout", "400ms", "-max-metadata-requests", "2", "-request-timeout", "6s"}})
		huge := a.post("/api/consumer/v1/auth/device", nil, `{"client_name":"x","pad":"`+strings.Repeat("a", 70000)+`"}`)
		if huge.status != 413 {
			t.Fatalf("an oversized body answered %d", huge.status)
		}
		connection, err := net.Dial("tcp", strings.TrimPrefix(instance.base, "http://"))
		if err != nil {
			t.Fatal(err)
		}
		fmt.Fprintf(connection, "POST /api/consumer/v1/auth/token HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: 500\r\n\r\n{\"device_code\":")
		connection.SetReadDeadline(time.Now().Add(5 * time.Second))
		buffer := make([]byte, 4096)
		length, _ := connection.Read(buffer)
		connection.Close()
		if !strings.Contains(string(buffer[:length]), "408") {
			t.Fatalf("a stalled body answered %q", buffer[:length])
		}
		device := freshCode("busy slots")
		owner := f.doc.Users["pair_one"]
		seedGrant(t, copied.database, grantSeed{device: device, user: owner, approved: true, client: "Slots"})
		done := make(chan struct{}, 2)
		for index := 0; index < 2; index++ {
			go func() { a.poll(device); done <- struct{}{} }()
		}
		waitFor(t, filepath.Join(directory, "exchange.locked.reached"))
		time.Sleep(200 * time.Millisecond)
		got := a.post("/api/consumer/v1/auth/token", nil, `{}`)
		if got.status != http.StatusServiceUnavailable || got.code(t) != "server_busy" {
			t.Fatalf("beyond the concurrency bound %d %s", got.status, got.body)
		}
		release(t, directory, "exchange.locked")
		<-done
		<-done
	})
}

func TestARuntimeWithoutTheGrantSchemaRefusesToStart(t *testing.T) {
	eachFixture(t, func(t *testing.T, f fixture, copied runtimeCopy) {
		for name, statement := range map[string]string{
			"missing table":  `ALTER TABLE consumer_device_grants RENAME TO consumer_device_grants_moved`,
			"missing column": `ALTER TABLE consumer_device_grants DROP COLUMN last_polled_at`,
		} {
			exec1(t, copied.database, statement)
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			command := exec.CommandContext(ctx, binaryPath, "-experimental", "-database", copied.database, "-lock-file", copied.lock, "-library-root", f.doc.BundleMediaRoot, "-listen", "127.0.0.1:0")
			command.Env = []string{"SECRET_KEY_BASE_FILE=" + f.secretFile()}
			output, err := command.CombinedOutput()
			cancel()
			if err == nil || !strings.Contains(string(output), "refused: database-schema") {
				t.Fatalf("%s: the runtime started or failed another way: %v %s", name, err, output)
			}
			exec1(t, copied.database, map[string]string{"missing table": `ALTER TABLE consumer_device_grants_moved RENAME TO consumer_device_grants`, "missing column": `ALTER TABLE consumer_device_grants ADD COLUMN last_polled_at datetime`}[name])
		}
	})
}

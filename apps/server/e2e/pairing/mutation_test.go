//go:build e2e

package pairing

import (
	"bytes"
	"context"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type edit struct {
	old string
	new string
}

type mutant struct {
	name     string
	file     string
	edits    []edit
	unit     string
	scenario string
}

const (
	differential = "TestPairingDifferentialAgainstRails"
	handoff      = "TestGoContinues"
	production   = "TestTheProductionBinary"
	concurrency  = "TestExactlyOneExchange|TestConcurrentDecisions|TestConcurrentCreation"
	revokeRace   = "TestAnExplicitRevokeWins"
	kills        = "TestKilledProcesses"
	contention   = "TestLockContention"
	deadline     = "TestARequestThatOutlives"
	stale        = "TestStateChangedWhile"
	consent      = "TestConsentOverRealHTTP"
	offSwitch    = "TestTheConsentEndpointsAreOff"
	bounds       = "TestRequestsAreBounded"
	schema       = "TestARuntimeWithoutTheGrantSchema"
)

func one(old, replacement string) []edit { return []edit{{old, replacement}} }

var mutants = []mutant{
	{name: "codes: the user alphabet admits ambiguous characters", file: "internal/devicegrant/devicegrant.go", edits: one(`CodeAlphabet       = "BCDFGHJKLMNPQRSTVWXYZ23456789"`, `CodeAlphabet       = "ABCDFGHJKLMNPQRSTVWXYZ23456789"`), unit: "./internal/devicegrant/"},
	{name: "codes: the device code has too little entropy", file: "internal/devicegrant/devicegrant.go", edits: one("deviceCodeBytes    = 32", "deviceCodeBytes    = 8"), unit: "./internal/devicegrant/"},
	{name: "codes: the access token has too little entropy", file: "internal/devicegrant/devicegrant.go", edits: one("tokenRandomLength  = 40", "tokenRandomLength  = 10"), unit: "./internal/devicegrant/"},
	{name: "codes: the token alphabet admits look-alikes", file: "internal/devicegrant/devicegrant.go", edits: one(`base58Alphabet     = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"`, `base58Alphabet     = "0123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"`), unit: "./internal/devicegrant/"},
	{name: "codes: random bytes are reduced without rejection sampling", file: "internal/devicegrant/devicegrant.go", edits: one("if value >= limit {\n\t\t\t\tcontinue\n\t\t\t}", "if value >= limit && false {\n\t\t\t\tcontinue\n\t\t\t}"), unit: "./internal/devicegrant/"},
	{name: "scopes: a partial requesting bundle is accepted", file: "internal/devicegrant/devicegrant.go", edits: one("\tcase len(RequestScopes):\n\t\treturn append", "\tdefault:\n\t\treturn append"), unit: "./internal/devicegrant/", scenario: differential},
	{name: "scopes: an unknown or privileged scope is accepted", file: "internal/devicegrant/devicegrant.go", edits: one("\t	default:\n\t\t\treturn nil, ErrInvalidScope\n\t\t}\n\t}\n\tswitch", "\t\tdefault:\n\t\t}\n\t}\n\tswitch"), unit: "./internal/devicegrant/", scenario: differential},
	{name: "scopes: an over-long scope text is accepted", file: "internal/devicegrant/devicegrant.go", edits: one("len(scope.Text) > MaxScopeBytes", "len(scope.Text) > 1<<20"), unit: "./internal/devicegrant/", scenario: differential},
	{name: "name: a blank client name is accepted", file: "internal/devicegrant/devicegrant.go", edits: one("return !unicode.IsSpace(r) }) < 0 {", "return !unicode.IsSpace(r) }) < -1 {"), unit: "./internal/devicegrant/", scenario: differential},
	{name: "name: the byte limit is ignored", file: "internal/devicegrant/devicegrant.go", edits: one("if len(raw) > MaxClientNameBytes ||", "if len(raw) > 1<<20 ||"), unit: "./internal/devicegrant/", scenario: differential},
	{name: "code: the displayed hyphen is not removed before lookup", file: "internal/devicegrant/devicegrant.go", edits: one("\t\tcase '-', ' ':\n\t\t\tcontinue", "\t\tcase ' ':\n\t\t\tcontinue"), unit: "./internal/devicegrant/", scenario: differential},
	{name: "code: lookup is case sensitive", file: "internal/devicegrant/devicegrant.go", edits: one("return string(unicode.ToUpper(character))", "return string(character)"), unit: "./internal/devicegrant/", scenario: differential},
	{name: "exchange: the exact expiry instant is still valid", file: "internal/live/grants.go", edits: one("if row.consumed.Valid || !expiry.After(now) {", "if row.consumed.Valid || expiry.Before(now) {"), unit: "./internal/gohttp/", scenario: differential},
	{name: "decide: the exact expiry instant is still decidable", file: "internal/live/grants.go", edits: one("return expiry.After(now) && !g.approved.Valid", "return !expiry.Before(now) && !g.approved.Valid"), unit: "./internal/gohttp/", scenario: differential},
	{name: "exchange: a consumed grant is exchanged again", file: "internal/live/grants.go", edits: one("if row.consumed.Valid || !expiry.After(now) {", "if !expiry.After(now) {"), unit: "./internal/gohttp/", scenario: differential + "|" + concurrency},
	{name: "exchange: a denied grant is not refused", file: "internal/live/grants.go", edits: one("if row.denied.Valid || ownerGone {", "if ownerGone {"), unit: "./internal/gohttp/", scenario: differential},
	{name: "exchange: a deleted approver still receives a token", file: "internal/live/grants.go", edits: one("if row.denied.Valid || ownerGone {", "if row.denied.Valid || ownerGone && false {"), unit: "./internal/gohttp/", scenario: differential + "|" + stale},
	{name: "exchange: polling faster than the interval is not slowed", file: "internal/live/grants.go", edits: one("if polled.After(now.Add(-time.Duration(row.interval) * time.Second)) {", "if polled.After(now.Add(-time.Duration(row.interval)*time.Second)) && false {"), unit: "./internal/gohttp/", scenario: differential},
	{name: "exchange: the interval does not grow", file: "internal/live/grants.go", edits: one("next := min(row.interval+devicegrant.IntervalStep, devicegrant.MaxInterval)", "next := row.interval"), unit: "./internal/gohttp/", scenario: differential},
	{name: "exchange: the interval has no ceiling", file: "internal/devicegrant/devicegrant.go", edits: one("MaxInterval        = 60", "MaxInterval        = 6000"), unit: "./internal/gohttp/", scenario: differential},
	{name: "exchange: a pending poll is not committed", file: "internal/live/grants.go", edits: one("`UPDATE consumer_device_grants SET last_polled_at = ?, updated_at = ? WHERE id = ?`, stamp, stamp, row.id)\n\t\treturn ExchangePending", "`UPDATE consumer_device_grants SET updated_at = updated_at WHERE id = ? AND ? = ? AND 0`, row.id, stamp, stamp)\n\t\treturn ExchangePending"), unit: "./internal/gohttp/", scenario: differential},
	{name: "exchange: a slow_down poll is not committed", file: "internal/live/grants.go", edits: one("`UPDATE consumer_device_grants SET last_polled_at = ?, poll_interval = ?, updated_at = ? WHERE id = ?`, stamp, next, stamp, row.id)", "`UPDATE consumer_device_grants SET updated_at = updated_at WHERE ? = ? AND ? = ? AND 0`, stamp, next, stamp, row.id)"), unit: "./internal/gohttp/", scenario: differential},
	{name: "exchange: the grant is not consumed when a token is issued", file: "internal/live/grants.go", edits: one("\tif _, err := tx.ExecContext(ctx, `UPDATE consumer_device_grants SET consumed_at = ?, updated_at = ? WHERE id = ?`, stamp, stamp, row.id); err != nil {\n\t\treturn 0, ExchangeResult{}, err\n\t}\n\treturn ExchangeIssued", "\treturn ExchangeIssued"), unit: "./internal/gohttp/", scenario: differential + "|" + concurrency},
	{name: "exchange: an upgrade is issued although its origin is unusable or foreign", file: "internal/live/grants.go", edits: one("if origin.userID != row.userID || !origin.userID.Valid || !usable {", "if (origin.userID != row.userID || !origin.userID.Valid || !usable) && false {"), unit: "./internal/gohttp/", scenario: differential + "|" + stale},
	{name: "exchange: an upgrade is issued although its origin was revoked", file: "internal/live/grants.go", edits: one("if origin.userID != row.userID || !origin.userID.Valid || !usable {", "if origin.userID != row.userID || !origin.userID.Valid || !usable && false {"), unit: "./internal/gohttp/", scenario: differential},
	{name: "exchange: an upgrade does not join its origin's connection", file: "internal/live/grants.go", edits: one("if row.replaces.Valid && origin.connectionKey.Valid && !blank(origin.connectionKey.String) {", "if false {"), unit: "./internal/gohttp/", scenario: differential},
	{name: "exchange: a legacy origin is not given a connection key", file: "internal/live/grants.go", edits: one("\t\tif row.replaces.Valid {\n\t\t\tif _, err := tx.ExecContext(ctx, `UPDATE api_tokens SET connection_key", "\t\tif false {\n\t\t\tif _, err := tx.ExecContext(ctx, `UPDATE api_tokens SET connection_key"), unit: "./internal/gohttp/", scenario: differential + "|" + handoff},
	{name: "exchange: tokens live less than thirty days", file: "internal/devicegrant/devicegrant.go", edits: one("TokenLifetimeSecs  = TokenLifetimeDays * 24 * 60 * 60", "TokenLifetimeSecs  = (TokenLifetimeDays - 1) * 24 * 60 * 60"), unit: "./internal/gohttp/", scenario: differential},
	{name: "exchange: the credential is not marked as issued by device approval", file: "internal/live/grants.go", edits: one("account.TokenDigest(raw), devicegrant.TokenPrefixOf(raw), expires, devicegrant.Consumer,", "account.TokenDigest(raw), devicegrant.TokenPrefixOf(raw), expires, \"\","), unit: "./internal/gohttp/", scenario: differential},
	{name: "storage: the access token is stored in plaintext", file: "internal/live/grants.go", edits: one("account.TokenDigest(raw), devicegrant.TokenPrefixOf(raw), expires,", "raw, devicegrant.TokenPrefixOf(raw), expires,"), unit: "./internal/gohttp/", scenario: differential + "|" + production},
	{name: "storage: the device code is stored in plaintext", file: "internal/live/grants.go", edits: one("request.ClientName, codes.DeviceDigest(), codes.UserDigest(),", "request.ClientName, codes.Device, codes.UserDigest(),"), unit: "./internal/gohttp/", scenario: differential + "|" + production},
	{name: "decide: a different account may decide an upgrade", file: "internal/live/grants.go", edits: one("return owner.Valid && owner.Int64 == actorID, nil", "return true, nil"), unit: "./internal/gohttp/", scenario: differential + "|" + consent},
	{name: "decide: an account deleted while waiting may decide", file: "internal/live/grants.go", edits: one("\tif deleted.Valid {\n\t\treturn false, nil\n\t}\n\tif !row.replaces.Valid {", "\tif !row.replaces.Valid {"), unit: "./internal/gohttp/", scenario: stale},
	{name: "decide: an expired or used grant is decided", file: "internal/live/grants.go", edits: one("\tif !pending {\n\t\treturn DecideResult{Outcome: DecideNotPending}, nil\n\t}", "\t_ = pending"), unit: "./internal/gohttp/", scenario: differential},
	{name: "decide: a refused decision still writes", file: "internal/live/grants.go", edits: one("\tif !decidable {\n\t\treturn DecideResult{Outcome: DecideWrongAccount}, nil\n\t}", "\t_ = decidable"), unit: "./internal/gohttp/", scenario: differential},
	{name: "create: a credential revoked while the request waited can still upgrade", file: "internal/live/grants.go", edits: one("if request.Upgrade != nil {\n\t\tif err := recheckUpgrade", "if false {\n\t\tif err := recheckUpgrade"), unit: "./internal/gohttp/", scenario: stale},
	{name: "create: cleanup removes grants younger than a day", file: "internal/live/grants.go", edits: one("expiredGrantRetains = 24 * time.Hour", "expiredGrantRetains = time.Hour"), unit: "./internal/gohttp/", scenario: differential},
	{name: "create: cleanup includes the boundary instant", file: "internal/live/grants.go", edits: one("`DELETE FROM consumer_device_grants WHERE expires_at < ?`", "`DELETE FROM consumer_device_grants WHERE expires_at <= ?`"), unit: "./internal/gohttp/", scenario: differential},
	{name: "revoke: the connection spans other accounts", file: "internal/live/grants.go", edits: one("family = `user_id IS ? AND connection_key = ?`", "family = `(user_id IS ? OR 1) AND connection_key = ?`"), unit: "./internal/gohttp/", scenario: differential},
	{name: "revoke: a blank connection key revokes every blank-key token", file: "internal/live/grants.go", edits: one("if key.Valid && !blank(key.String) {", "if key.Valid {"), unit: "./internal/gohttp/", scenario: differential},
	{name: "revoke: pending upgrades of the connection survive", file: "internal/live/grants.go", edits: one("WHERE consumed_at IS NULL AND replaces_api_token_id IN", "WHERE 0 AND consumed_at IS NULL AND replaces_api_token_id IN"), unit: "./internal/gohttp/", scenario: differential + "|" + handoff},
	{name: "revoke: only the presented token is revoked", file: "internal/live/grants.go", edits: one("if key.Valid && !blank(key.String) {", "if false {"), unit: "./internal/gohttp/", scenario: differential + "|" + revokeRace},
	{name: "revoke: a token without library:read cannot revoke", file: "internal/gohttp/app.go", edits: one("\tif found.kind == routeAuthRevoke {\n\t\treturn \"\"\n\t}\n", ""), unit: "./internal/gohttp/", scenario: differential},
	{name: "http: the verification address comes from the Host header", file: "internal/gohttp/pairing.go", edits: one("VerificationURI: a.config.BrowserOrigin + verificationURI, VerificationURIComplete: a.config.BrowserOrigin + verificationURI", "VerificationURI: \"http://\" + r.Host + verificationURI, VerificationURIComplete: \"http://\" + r.Host + verificationURI"), unit: "./internal/gohttp/"},
	{name: "http: an Authorization header is ignored instead of requesting an upgrade", file: "internal/gohttp/pairing.go", edits: one("!blankText(authorization) {", "false {"), unit: "./internal/gohttp/", scenario: differential},
	{name: "http: a stale bearer falls back to a fresh connection", file: "internal/gohttp/pairing.go", edits: one("if principal == nil || !principal.HasScope(\"library:read\") {", "if principal == nil && false {"), unit: "./internal/gohttp/", scenario: differential},
	{name: "http: the private response headers are dropped", file: "internal/gohttp/pairing.go", edits: one("header.Set(\"Referrer-Policy\", \"no-referrer\")", "_ = header"), unit: "./internal/gohttp/", scenario: differential},
	{name: "http: device creation is not rate limited", file: "internal/gohttp/pairing.go", edits: one("deviceAttempts  = 20", "deviceAttempts  = 20000"), unit: "./internal/gohttp/", scenario: differential},
	{name: "http: token polling is not rate limited", file: "internal/gohttp/pairing.go", edits: one("tokenAttempts   = 120", "tokenAttempts   = 120000"), unit: "./internal/gohttp/", scenario: differential},
	{name: "http: the body is not bounded", file: "internal/gohttp/pairing.go", edits: one("a.readObject(w, r, result, checkpoint.MaxBodyBytes)\n\tif !ok {\n\t\treturn\n\t}\n\tname", "a.readObject(w, r, result, 1<<30)\n\tif !ok {\n\t\treturn\n\t}\n\tname"), unit: "./internal/gohttp/", scenario: bounds},
	{name: "http: a missing browser origin still pairs", file: "internal/gohttp/pairing.go", edits: one("if a.config.BrowserOrigin == \"\" {\n\t\tproblem(w, result, http.StatusNotImplemented, \"browser_origin_not_configured\")", "if false {\n\t\tproblem(w, result, http.StatusNotImplemented, \"browser_origin_not_configured\")"), unit: "./internal/gohttp/", scenario: offSwitch},
	{name: "http: a random failure is reported as an authentication failure", file: "internal/gohttp/pairing.go", edits: one("problem(w, result, http.StatusInternalServerError, \"internal_error\")\n\treturn true", "a.unauthorized(w, result)\n\treturn true"), unit: "./internal/gohttp/"},
	{name: "http: response writing stops at the request deadline", file: "internal/gohttp/run.go", edits: one("WriteTimeout:      config.RequestTimeout + responseGrace,", "WriteTimeout:      config.RequestTimeout,"), scenario: deadline},
	{name: "consent: the decision does not need a CSRF token", file: "internal/gohttp/browser_data.go", edits: one("(found.kind == routeBrowserStatus || found.kind == routeBrowserDecide) &&", "found.kind == routeBrowserStatus &&"), unit: "./internal/gohttp/", scenario: consent},
	{name: "consent: another account's pending grant is described", file: "internal/gohttp/pairing.go", edits: one("\tif !view.Decidable {\n\t\treturn &connectGrant{Pending: true}\n\t}\n", ""), unit: "./internal/gohttp/"},
	{name: "consent: a refused decision is reported as applied", file: "internal/gohttp/pairing.go", edits: one("case live.DecideNotPending:\n\t\tproblem(w, result, http.StatusUnprocessableEntity, \"invalid_grant\")", "case live.DecideNotPending:\n\t\tresult.set(http.StatusOK, \"\")\n\t\twriteJSON(w, http.StatusOK, map[string]string{})"), unit: "./internal/gohttp/", scenario: differential},
	{name: "schema: the grant table is not required", file: "internal/live/live.go", edits: one("\t\"consumer_device_grants\":  {\"id\", \"user_id\", \"client_name\", \"device_code_digest\", \"user_code_digest\", \"expires_at\", \"approved_at\", \"denied_at\", \"consumed_at\", \"last_polled_at\", \"poll_interval\", \"scopes\", \"replaces_api_token_id\", \"created_at\", \"updated_at\"},\n", ""), unit: "./internal/live/", scenario: schema},
	{name: "schema: the connection key column is not required", file: "internal/live/live.go", edits: one("\"issued_via\", \"replaces_api_token_id\", \"connection_key\"},", "\"issued_via\", \"replaces_api_token_id\"},"), unit: "./internal/live/"},
}

func copyModule(t *testing.T, destination string) {
	t.Helper()
	source, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range []string{"go.mod", "go.sum", "cmd", "internal", "e2e/pairing"} {
		root := filepath.Join(source, entry)
		walk := func(path string, directory fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			relative, _ := filepath.Rel(source, path)
			target := filepath.Join(destination, relative)
			if directory.IsDir() {
				return os.MkdirAll(target, 0o700)
			}
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			return os.WriteFile(target, data, 0o600)
		}
		if info, err := os.Stat(root); err == nil && !info.IsDir() {
			data, _ := os.ReadFile(root)
			if err := os.WriteFile(filepath.Join(destination, entry), data, 0o600); err != nil {
				t.Fatal(err)
			}
			continue
		}
		if err := filepath.WalkDir(root, walk); err != nil {
			t.Fatal(err)
		}
	}
}

func TestMutantsAreDetected(t *testing.T) {
	for _, candidate := range mutants {
		t.Run(candidate.name, func(t *testing.T) {
			t.Parallel()
			directory := t.TempDir()
			copyModule(t, directory)
			path := filepath.Join(directory, candidate.file)
			text, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			mutated := string(text)
			for _, change := range candidate.edits {
				if strings.Count(mutated, change.old) != 1 {
					t.Fatalf("the mutation target occurs %d times: %.60q", strings.Count(mutated, change.old), change.old)
				}
				mutated = strings.Replace(mutated, change.old, change.new, 1)
			}
			if err := os.WriteFile(path, []byte(mutated), 0o600); err != nil {
				t.Fatal(err)
			}
			build := exec.Command("go", "build", "./...")
			build.Dir = directory
			if output, err := build.CombinedOutput(); err != nil {
				t.Fatalf("the mutant does not compile, which proves nothing: %s", output)
			}
			var detections []string
			if candidate.unit != "" {
				detections = append(detections, runMutantTests(t, directory, candidate.unit, "", false))
			}
			if candidate.scenario != "" {
				detections = append(detections, runMutantTests(t, directory, "./e2e/pairing/", candidate.scenario, true))
			}
			for _, detected := range detections {
				if detected != "" {
					return
				}
			}
			t.Fatal("no assertion failed for this mutant")
		})
	}
}

func runMutantTests(t *testing.T, directory, packagePath, scenario string, tagged bool) string {
	t.Helper()
	arguments := []string{"test", "-count=1"}
	if tagged {
		arguments = append(arguments, "-tags", "e2e", "-run", scenario)
	}
	arguments = append(arguments, packagePath)
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Minute)
	defer cancel()
	command := exec.CommandContext(ctx, "go", arguments...)
	command.Dir = directory
	var output bytes.Buffer
	command.Stdout, command.Stderr = &output, &output
	err := command.Run()
	text := output.String()
	if err == nil {
		return ""
	}
	if strings.Contains(text, "build failed") || strings.Contains(text, "[setup failed]") || !strings.Contains(text, "--- FAIL") && !strings.Contains(text, "panic:") {
		t.Fatalf("the run failed without an assertion failing:\n%s", tail(text))
	}
	return "detected"
}

func tail(text string) string {
	if len(text) > 2000 {
		return text[len(text)-2000:]
	}
	return text
}

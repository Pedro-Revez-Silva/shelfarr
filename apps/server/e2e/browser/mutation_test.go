//go:build e2e

package browser

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
	differential = "TestBrowserDifferentialAgainstRails"
	lifecycle    = "TestBrowserSessionLifecycleOverRealHTTP"
	refusals     = "TestBrowserRefusesUnportedSignInModes"
	lockout      = "TestBrowserLockoutIsAtomic"
	faults       = "TestBrowserLoginFaults"
	bounds       = "TestBrowserPasswordCostAndRateAreBounded"
	unported     = "TestBrowserDataRefuses"
	allowlist    = "TestBrowserEndpointsAreOff"
	restart      = "TestBrowserSessionsSurviveARestart"
	cookies      = "TestBrowserBodiesAndCookies"
	markup       = "TestBrowserDescriptionMarkup"
)

func one(old, replacement string) []edit { return []edit{{old, replacement}} }

var mutants = []mutant{
	{name: "login: an unusable session lifetime is not refused before commit", file: "internal/live/browser.go", edits: one("if err != nil || days < 0 || days > MaxSessionAgeDays {", "if false {"), unit: "./internal/gohttp/"},
	{name: "session cookie: the signature is not verified", file: "internal/railsmsg/railsmsg.go", edits: one("if !hmac.Equal([]byte(digest), []byte(v.sign(text))) {", "if false && !hmac.Equal([]byte(digest), []byte(v.sign(text))) {"), unit: "./internal/railsmsg/", scenario: restart},
	{name: "session cookie: the purpose is not checked", file: "internal/railsmsg/railsmsg.go", edits: one("if message.Rails.Message == nil || message.Rails.Purpose != purpose {", "if message.Rails.Message == nil {"), scenario: restart + "|" + differential},
	{name: "session cookie: the envelope expiry is ignored", file: "internal/railsmsg/railsmsg.go", edits: one("if err != nil || !now.Before(expires) {", "if err != nil || !now.Before(expires) && false {"), unit: "./internal/gohttp/", scenario: differential},
	{name: "session cookie: any JSON type names a session", file: "internal/gohttp/browser.go", edits: one("if !sessionIDPattern.MatchString(text) {", "if false && !sessionIDPattern.MatchString(text) {"), unit: "./internal/gohttp/"},
	{name: "session: the maximum age is ignored", file: "internal/gohttp/browser.go", edits: one("if row.CreatedAt.Before(a.now().Add(-time.Duration(days) * 24 * time.Hour)) {", "if false {"), unit: "./internal/gohttp/", scenario: differential},
	{name: "session: the boundary instant expires", file: "internal/gohttp/browser.go", edits: one("if row.CreatedAt.Before(a.now().Add(", "if !row.CreatedAt.After(a.now().Add("), unit: "./internal/gohttp/", scenario: differential},
	{name: "session: an expired row is kept", file: "internal/gohttp/browser.go", edits: one("\t\ta.db.DeleteSession(ctx, row.ID, row.UserID)\n\t\ta.clearSession(w)\n\t\treturn nil, nil\n\t}\n\tuser, err", "\t\ta.clearSession(w)\n\t\treturn nil, nil\n\t}\n\tuser, err"), unit: "./internal/gohttp/", scenario: "TestBrowserExpiryUsesTheProductionClock"},
	{name: "session: a deleted account stays signed in", file: "internal/gohttp/browser.go", edits: one("if user.Deleted {", "if false {"), unit: "./internal/gohttp/", scenario: differential},
	{name: "session: the cookie is not cleared when the session is refused", file: "internal/gohttp/browser.go", edits: one("\t\ta.db.DeleteSession(ctx, row.ID, row.UserID)\n\t\ta.clearSession(w)\n\t\treturn nil, nil\n\t}\n\tuser, err", "\t\ta.db.DeleteSession(ctx, row.ID, row.UserID)\n\t\treturn nil, nil\n\t}\n\tuser, err"), unit: "./internal/gohttp/", scenario: differential},
	{name: "preview: a user outside the list is allowed", file: "internal/gohttp/browser.go", edits: one("func (a *App) previewAllows(userID int64) bool { return a.previewIDs[strconv.FormatInt(userID, 10)] }", "func (a *App) previewAllows(userID int64) bool { return true }"), unit: "./internal/gohttp/", scenario: differential},
	{name: "preview: an empty list is on for everyone", file: "internal/gohttp/browser.go", edits: one("func (a *App) previewConfigured() bool { return len(a.previewIDs) > 0 }", "func (a *App) previewConfigured() bool { return true }"), unit: "./internal/gohttp/", scenario: allowlist},
	{name: "preview: a malformed list is read as far as it parses", file: "internal/gohttp/config.go", edits: one("\t\tif !previewUserID.MatchString(entry) {\n\t\t\treturn nil, false\n\t\t}", "\t\tif !previewUserID.MatchString(entry) {\n\t\t\tcontinue\n\t\t}"), unit: "./internal/gohttp/", scenario: allowlist},
	{name: "account: the account header is not enforced", file: "internal/gohttp/browser.go", edits: one("if len(values) != 1 || values[0] != session.account() {", "if len(values) < 0 && values[0] != session.account() {"), unit: "./internal/gohttp/", scenario: differential},
	{name: "csrf: the token is not verified", file: "internal/gohttp/browser.go", edits: one("if len(values) != 1 || !a.tokens.VerifySession(values[0], session.row.ID, session.user.ID, session.row.CreatedAt, a.now()) {", "if len(values) < 0 && !a.tokens.VerifySession(values[0], session.row.ID, session.user.ID, session.row.CreatedAt, a.now()) {"), unit: "./internal/gohttp/", scenario: lifecycle},
	{name: "csrf: the status write skips the check", file: "internal/gohttp/browser_data.go", edits: one("if (found.kind == routeBrowserStatus || found.kind == routeBrowserDecide) && !a.mutationAllowed(w, r, *session, result) {", "if (false || found.kind == routeBrowserDecide) && !a.mutationAllowed(w, r, *session, result) {"), unit: "./internal/gohttp/", scenario: lifecycle},
	{name: "csrf: the origin is not compared", file: "internal/gohttp/browser.go", edits: one("if len(origins) != 1 || origins[0] != a.config.BrowserOrigin || len(sites) > 0 &&", "if len(origins) < 0 && origins[0] != a.config.BrowserOrigin || len(sites) > 0 &&"), unit: "./internal/gohttp/", scenario: lifecycle},
	{name: "csrf: Sec-Fetch-Site is not consulted", file: "internal/gohttp/browser.go", edits: one("|| len(sites) > 0 && (len(sites) != 1 || sites[0] != \"same-origin\") {", "|| len(sites) < 0 && (len(sites) != 1 || sites[0] != \"same-origin\") {"), unit: "./internal/gohttp/", scenario: lifecycle},
	{name: "csrf: logout skips the token", file: "internal/gohttp/browser.go", edits: one("if !ok || !a.mutationAllowed(w, r, *session, result) {", "if !ok {"), unit: "./internal/gohttp/", scenario: lifecycle},
	{name: "csrf: the session token is not bound to the session", file: "internal/csrf/csrf.go", edits: one("return strconv.FormatInt(sessionID, 10) + \"|\" + strconv.FormatInt(userID, 10) + \"|\" + strconv.FormatInt(created.UnixMicro(), 10)", "return \"shared\""), unit: "./internal/gohttp/", scenario: lifecycle},
	{name: "csrf: tokens never expire", file: "internal/csrf/csrf.go", edits: one("if err != nil || expires <= now.Unix() {", "if err != nil {"), unit: "./internal/gohttp/"},
	{name: "csrf: the login token is not bound to the browser's nonce", file: "internal/csrf/csrf.go", edits: []edit{{"return t.issue(kindLogin, nonce, now, LoginTTL)", "return t.issue(kindLogin, \"\", now, LoginTTL)"}, {"return ValidNonce(nonce) && t.verify(token, kindLogin, nonce, now)", "return t.verify(token, kindLogin, \"\", now)"}}, unit: "./internal/gohttp/"},
	{name: "login: the nonce survives the login", file: "internal/gohttp/browser.go", edits: one("\ta.clearNonce(w)\n\tuser := browserSession", "\tuser := browserSession"), unit: "./internal/gohttp/", scenario: lifecycle},
	{name: "login: a signed-in browser may sign in again", file: "internal/gohttp/browser.go", edits: one("if existing != nil {", "if existing != nil && false {"), unit: "./internal/gohttp/"},
	{name: "login: a wrong password signs in", file: "internal/gohttp/browser.go", edits: one("\tif !matches {\n\t\ta.failedLogin(", "\tif !matches && false {\n\t\ta.failedLogin("), unit: "./internal/gohttp/", scenario: differential},
	{name: "login: a user outside the allowlist signs in", file: "internal/gohttp/browser.go", edits: one("known := credentials != nil && a.previewAllows(credentials.ID)", "known := credentials != nil"), unit: "./internal/gohttp/", scenario: refusals},
	{name: "login: a second factor is bypassed", file: "internal/live/browser.go", edits: one("case state.otpRequired && state.otpSecret:", "case false:"), unit: "./internal/gohttp/", scenario: refusals + "|" + differential},
	{name: "login: an OIDC account signs in with a password", file: "internal/live/browser.go", edits: one("case state.oidcLinked:", "case false:"), unit: "./internal/gohttp/", scenario: refusals + "|" + differential},
	{name: "login: a passwordless deployment signs in", file: "internal/gohttp/browser.go", edits: one("\tif reason != \"\" {\n\t\ta.loginRefused(", "\tif false {\n\t\ta.loginRefused("), unit: "./internal/gohttp/", scenario: refusals},
	{name: "login: a deployment that became passwordless during the check signs in", file: "internal/live/browser.go", edits: one("\tif passwordless {\n\t\treturn LoginResult{Outcome: LoginPasswordless}, nil", "\tif passwordless && false {\n\t\treturn LoginResult{Outcome: LoginPasswordless}, nil"), unit: "./internal/gohttp/", scenario: faults},
	{name: "login: a credential changed during the check still signs in", file: "internal/live/browser.go", edits: one("case !found || state.deleted || locked || state.digest != digest:", "case !found || state.deleted || locked || state.digest != digest && false:"), unit: "./internal/gohttp/", scenario: faults},
	{name: "login: an account deleted while waiting for the lock signs in", file: "internal/live/browser.go", edits: one("case !found || state.deleted || locked || state.digest != digest:", "case !found || state.deleted && false || locked || state.digest != digest:"), unit: "./internal/gohttp/", scenario: faults},
	{name: "login: an account locked while waiting for the lock signs in", file: "internal/live/browser.go", edits: one("case !found || state.deleted || locked || state.digest != digest:", "case !found || state.deleted || locked && false || state.digest != digest:"), unit: "./internal/gohttp/", scenario: differential},
	{name: "login: a locked account is not refused before the password counts", file: "internal/live/browser.go", edits: one("if !found || state.deleted || locked {\n\t\treturn nil\n\t}", "if !found || state.deleted || locked && false {\n\t\treturn nil\n\t}"), unit: "./internal/gohttp/", scenario: lockout + "|" + differential},
	{name: "login: the failure counter restarts at one", file: "internal/live/browser.go", edits: one("count := state.failures + 1", "count := int64(1)"), unit: "./internal/gohttp/", scenario: lockout + "|" + differential},
	{name: "login: the lockout is never applied", file: "internal/live/browser.go", edits: one("if count >= int64(threshold) {", "if false {"), unit: "./internal/gohttp/", scenario: lockout + "|" + differential},
	{name: "login: success keeps the failure counters", file: "internal/live/browser.go", edits: one("\tif state.dirty() {\n\t\tif _, err := tx.ExecContext(ctx, `UPDATE users SET failed_login_count = 0", "\tif false {\n\t\tif _, err := tx.ExecContext(ctx, `UPDATE users SET failed_login_count = 0"), unit: "./internal/gohttp/", scenario: differential},
	{name: "login: the session row loses its client address", file: "internal/live/browser.go", edits: one("userID, truncated(client.UserAgent, 1024), truncated(client.IP, 64), stamp, stamp)", "userID, truncated(client.UserAgent, 1024), nil, stamp, stamp)"), unit: "./internal/gohttp/", scenario: differential},
	{name: "login: password cost is not bounded", file: "internal/account/account.go", edits: one("if cost > MaxBcryptCost {", "if cost > MaxBcryptCost && false {"), scenario: bounds},
	{name: "login: attempts are not rate limited", file: "internal/loginlimit/loginlimit.go", edits: one("if slot.count >= l.limit {", "if false {"), unit: "./internal/gohttp/", scenario: bounds},
	{name: "login: concurrent password checks are not bounded", file: "internal/loginlimit/loginlimit.go", edits: one("workers: make(chan struct{}, workers)", "workers: make(chan struct{}, workers*1000)"), unit: "./internal/gohttp/"},
	{name: "login: the body is not bounded", file: "internal/gohttp/browser.go", edits: one("a.readLimitedBody(w, r, maxLoginBody)", "a.readLimitedBody(w, r, 1<<30)"), unit: "./internal/gohttp/", scenario: cookies},
	{name: "logout: the session is not revoked", file: "internal/gohttp/browser.go", edits: one("if err := a.db.DeleteSession(r.Context(), session.row.ID, session.user.ID); err != nil {", "if err := error(nil); err != nil {"), unit: "./internal/gohttp/", scenario: lifecycle + "|" + differential},
	{name: "cookie: the session cookie is readable by scripts", file: "internal/gohttp/browser.go", edits: one("Expires: expires.Truncate(time.Second), HttpOnly: true,", "Expires: expires.Truncate(time.Second), HttpOnly: false,"), unit: "./internal/gohttp/", scenario: lifecycle},
	{name: "cookie: the secure flag is never set", file: "internal/gohttp/browser.go", edits: one("func (a *App) secureCookies() bool { return strings.HasPrefix(a.config.BrowserOrigin, \"https://\") }", "func (a *App) secureCookies() bool { return false }"), unit: "./internal/gohttp/"},
	{name: "cookie: the session cookie is not Rails-escaped", file: "internal/gohttp/browser.go", edits: one("Value: url.QueryEscape(cookie), Path: \"/\"", "Value: cookie, Path: \"/\""), unit: "./internal/gohttp/", scenario: lifecycle},
	{name: "formats: PDF and CBZ assets are listed as if they were absent", file: "internal/gohttp/browser_data.go", edits: one("if asset.Format == \"pdf\" || asset.Format == \"cbz\" {\n\t\t\t\treturn nil, errUnsupportedAsset", "if asset.Format == \"never\" {\n\t\t\t\treturn nil, errUnsupportedAsset"), unit: "./internal/gohttp/", scenario: unported},
	{name: "formats: comic records are listed as if they were absent", file: "internal/gohttp/browser_data.go", edits: one("if book.BookType == store.BookTypeComicbook {\n\t\t\treturn nil, errUnsupportedKind", "if false {\n\t\t\treturn nil, errUnsupportedKind"), unit: "./internal/gohttp/", scenario: unported},
	{name: "description: markup reaches the browser as raw HTML", file: "internal/webpreview/plaintext.go", edits: one("text, err := visibleText(lineBreaks(withoutRawTextElements(value)))", "text, err := value, error(nil)"), unit: "./internal/webpreview/", scenario: markup},
	{name: "description: script and style bodies are kept", file: "internal/webpreview/plaintext.go", edits: one("lineBreaks(withoutRawTextElements(value))", "lineBreaks(value)"), unit: "./internal/webpreview/", scenario: markup},
	{name: "description: block tags do not break lines", file: "internal/webpreview/plaintext.go", edits: one("lineBreaks(withoutRawTextElements(value))", "withoutRawTextElements(value)"), unit: "./internal/webpreview/", scenario: markup},
	{name: "description: a non-breaking space is shown as a space", file: "internal/webpreview/plaintext.go", edits: one("text = strings.ReplaceAll(text, \"\\u00a0\", \"&nbsp;\")", ""), unit: "./internal/webpreview/"},
	{name: "description: markup nesting is not bounded", file: "internal/webpreview/plaintext.go", edits: one("if current.depth > maxMarkupDepth {", "if false {"), unit: "./internal/webpreview/"},
	{name: "web: the screens ignore the allowlist", file: "internal/gohttp/web.go", edits: one("if !a.previewConfigured() || found.kind == routeWebAsset && !a.web.bundle.Has(found.id) {", "if found.kind == routeWebAsset && !a.web.bundle.Has(found.id) {"), unit: "./internal/gohttp/"},
	{name: "web: a screen accepts other methods", file: "internal/gohttp/web.go", edits: one("if method != http.MethodGet && method != http.MethodHead {", "if false {"), unit: "./internal/gohttp/"},
	{name: "web: the screens answer when the option is off", file: "internal/gohttp/app.go", edits: one("if found.web && a.web == nil {", "if false {"), unit: "./internal/gohttp/"},
	{name: "web: the policy allows inline script", file: "internal/gohttp/web.go", edits: one("script-src 'self';", "script-src 'self' 'unsafe-inline';"), unit: "./internal/gohttp/"},
	{name: "web: the shell is cacheable", file: "internal/gohttp/web.go", edits: one("\tcase routeWebShell:\n\t\tw.Header().Set(\"Cache-Control\", \"private, no-store\")", "\tcase routeWebShell:"), unit: "./internal/gohttp/"},
	{name: "web: the connection page leaks the code in a referrer", file: "internal/gohttp/web.go", edits: one("if view == viewConnect {", "if false {"), unit: "./internal/gohttp/"},
	{name: "web: a bad assets folder starts the server anyway", file: "internal/gohttp/run.go", edits: one("\t	if _, err := webassets.Load(config.WebAssetsDir); err != nil {\n\t\t\treturn start(\"web-assets\")\n\t\t}", "\t\tif _, err := webassets.Load(config.WebAssetsDir); err != nil && false {\n\t\t\treturn start(\"web-assets\")\n\t\t}"), unit: "./internal/gohttp/"},
	{name: "web: a relative assets folder is accepted", file: "internal/gohttp/config.go", edits: one("if c.WebAssetsDir != \"\" && (!filepath.IsAbs(c.WebAssetsDir) ||", "if c.WebAssetsDir != \"\" && (false ||"), unit: "./internal/gohttp/"},
	{name: "assets: a changed file is trusted", file: "internal/webassets/webassets.go", edits: one("if encoded != expected.SHA256 || encoded[:digestPrefix] != parts[1] {", "if false {"), unit: "./internal/webassets/"},
	{name: "assets: a name that does not carry its digest is trusted", file: "internal/webassets/webassets.go", edits: one("if encoded != expected.SHA256 || encoded[:digestPrefix] != parts[1] {", "if encoded != expected.SHA256 {"), unit: "./internal/webassets/"},
	{name: "assets: an oversized file is read", file: "internal/webassets/webassets.go", edits: one("if err != nil || int64(len(body)) > limit {", "if err != nil {"), unit: "./internal/webassets/"},
	{name: "assets: an entry that is not listed is accepted", file: "internal/webassets/webassets.go", edits: one("if _, present := bundle.files[bundle.script]; !present {", "if _, present := bundle.files[bundle.script]; !present && false {"), unit: "./internal/webassets/"},
	{name: "assets: the total size is unbounded", file: "internal/webassets/webassets.go", edits: one("if total > totalLimit {", "if total > totalLimit && false {"), unit: "./internal/webassets/"},
	{name: "projection: the account is not part of the status isolation", file: "internal/live/queries.go", edits: one("func (d *DB) StatesFor(ctx context.Context, userID int64, bookIDs []int64) (map[int64]int, error) {", "func (d *DB) StatesFor(ctx context.Context, userID int64, bookIDs []int64) (map[int64]int, error) {\n\tuserID = 0"), unit: "./internal/gohttp/", scenario: differential},
}

func copyModule(t *testing.T, destination string) {
	t.Helper()
	source, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range []string{"go.mod", "go.sum", "cmd", "internal", "e2e/browser"} {
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
				detections = append(detections, runMutantTests(t, directory, "./e2e/browser/", candidate.scenario, true))
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

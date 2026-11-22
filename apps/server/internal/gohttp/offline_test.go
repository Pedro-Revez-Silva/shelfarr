//go:build linux

package gohttp

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/livetest"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/webassets/webassetstest"
)

func offlineHarness(t *testing.T, offline bool) (*browserHarness, webassetstest.Manifest) {
	t.Helper()
	directory := t.TempDir()
	listed := webassetstest.WriteWithReaderEngine(t, directory)
	h := newBrowserHarness(t, func(config *Config) {
		config.WebAssetsDir = directory
		config.WebOffline = offline
	})
	return h, listed
}

var bootBlock = regexp.MustCompile(`<script type="application/json" id="shelfarr-boot">(.*)</script>`)

func shellBoot(t *testing.T, body string) webBoot {
	t.Helper()
	found := bootBlock.FindStringSubmatch(body)
	var decoded webBoot
	if found == nil || json.Unmarshal([]byte(found[1]), &decoded) != nil {
		t.Fatalf("no boot block in %q", body)
	}
	return decoded
}

func workerConfigOf(t *testing.T, script string) workerConfig {
	t.Helper()
	const prefix = "self.SHELFARR_GO_OFFLINE = "
	end := strings.Index(script, ";\n")
	if !strings.HasPrefix(script, prefix) || end < 0 || script[end+2:] != offlineWorkerSource {
		t.Fatalf("the worker is not the configuration followed by the embedded source: %.120q", script)
	}
	var config workerConfig
	decoder := json.NewDecoder(strings.NewReader(script[len(prefix):end]))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&config); err != nil {
		t.Fatal(err)
	}
	return config
}

func TestWithoutTheOfflineOptionNothingOfflineIsServedOrAnnounced(t *testing.T) {
	h, _ := offlineHarness(t, false)
	client := h.client()
	for _, path := range []string{"/preview/offline-worker.js", "/preview/library/downloads"} {
		recorder := client.send(http.MethodGet, path, "", nil)
		if recorder.Code != http.StatusNotFound || errorCode(t, recorder) != "not_found" || recorder.Header().Get("Content-Security-Policy") != "" {
			t.Errorf("%s: %d %s", path, recorder.Code, recorder.Body.String())
		}
	}
	for _, path := range []string{"/preview/library", "/preview/library/7/read"} {
		if boot := shellBoot(t, client.send(http.MethodGet, path, "", nil).Body.String()); boot.Offline != nil {
			t.Errorf("%s announces offline: %+v", path, boot.Offline)
		}
	}
	_, signedOut := client.bootstrap()
	client.signIn("alice", alicePassword)
	_, signedIn := client.bootstrap()
	for name, body := range map[string]map[string]any{"signed out": signedOut, "signed in": signedIn} {
		if _, present := body["offline_expires_in"]; present {
			t.Errorf("%s bootstrap names an offline window: %v", name, body)
		}
	}
}

func TestEveryScreenAnnouncesTheWorkerAndTheDownloadsShellIsServedOnlyWithTheOption(t *testing.T) {
	h, listed := offlineHarness(t, true)
	client := h.client()
	paths := map[string]string{"/preview/library/downloads": "downloads", "/preview/library/7/read": "reader"}
	for path, view := range shellPaths {
		paths[path] = view
	}
	want := &offlineBoot{Worker: "/preview/offline-worker.js", Scope: "/preview/library/", Downloads: "/preview/library/downloads"}
	for path, view := range paths {
		recorder := client.send(http.MethodGet, path, "", nil)
		boot := shellBoot(t, recorder.Body.String())
		if recorder.Code != http.StatusOK || boot.View != view || !reflect.DeepEqual(boot.Offline, want) {
			t.Errorf("%s: %d %+v", path, recorder.Code, boot)
		}
	}
	downloads := client.send(http.MethodGet, "/preview/library/downloads", "", nil)
	if downloads.Header().Get("Content-Security-Policy") != webContentPolicy || downloads.Header().Get("Cache-Control") != "private, no-store" || !strings.Contains(downloads.Body.String(), "<title>Downloads · Shelfarr</title>") || !strings.Contains(downloads.Body.String(), listed.Entry.Script) {
		t.Errorf("downloads shell: %v", downloads.Header())
	}
	if refused := client.send(http.MethodPost, "/preview/library/downloads", "", nil); refused.Code != http.StatusMethodNotAllowed || refused.Header().Get("Allow") != "GET, HEAD" {
		t.Errorf("POST downloads: %d", refused.Code)
	}
}

func TestTheWorkerPrecachesOnlyTheListedAssetsAndCarriesTheStaticShellsWithTheirHeaders(t *testing.T) {
	h, listed := offlineHarness(t, true)
	client := h.client()
	recorder := client.send(http.MethodGet, "/preview/offline-worker.js", "", nil)
	header := recorder.Header()
	if recorder.Code != http.StatusOK || header.Get("Content-Type") != "text/javascript; charset=utf-8" || header.Get("Cache-Control") != "no-cache" || header.Get("Content-Security-Policy") != "default-src 'none'; connect-src 'self'" || header.Get("X-Content-Type-Options") != "nosniff" || header.Get("Cross-Origin-Resource-Policy") != "same-origin" || len(recorder.Result().Cookies()) != 0 {
		t.Fatalf("%d %v", recorder.Code, header)
	}
	config := workerConfigOf(t, recorder.Body.String())
	if !regexp.MustCompile(`^[0-9a-f]{24}$`).MatchString(config.Version) || config.Library != "/preview/library" || config.Downloads != "/preview/library/downloads" {
		t.Errorf("config: %+v", config)
	}
	want := map[string]string{}
	for name, entry := range listed.Files {
		want["/preview/assets/"+name] = entry.SHA256
	}
	got := map[string]string{}
	for _, asset := range config.Assets {
		got[asset.Path] = asset.SHA256
	}
	if !reflect.DeepEqual(got, want) || len(config.Assets) != len(want) {
		t.Errorf("assets %v, want %v", got, want)
	}
	for name, path := range map[string]string{"downloads": "/preview/library/downloads", "reader": "/preview/library/12/read"} {
		served := client.send(http.MethodGet, path, "", nil)
		shell := config.Shells[name]
		if shell.Body != served.Body.String() {
			t.Errorf("%s: the cached shell differs from the served one", name)
		}
		for key, value := range shell.Headers {
			if served.Header().Get(key) != value {
				t.Errorf("%s: %s is %q in the worker and %q when served", name, key, value, served.Header().Get(key))
			}
		}
		for _, key := range []string{"Content-Type", "Content-Security-Policy", "Cache-Control", "X-Content-Type-Options", "X-Frame-Options", "Cross-Origin-Opener-Policy", "Permissions-Policy", "Referrer-Policy"} {
			if shell.Headers[key] == "" {
				t.Errorf("%s: the worker's shell lacks %s", name, key)
			}
		}
	}
	if len(config.Shells) != 2 || config.Shells["reader"].Headers["Content-Security-Policy"] != readerPolicy {
		t.Errorf("shells: %v", config.Shells)
	}
	if head := client.send(http.MethodHead, "/preview/offline-worker.js", "", nil); head.Code != http.StatusOK || head.Body.Len() != 0 || head.Header().Get("Content-Length") != header.Get("Content-Length") {
		t.Errorf("HEAD: %d %d", head.Code, head.Body.Len())
	}
	if refused := client.send(http.MethodPost, "/preview/offline-worker.js", "", nil); refused.Code != http.StatusMethodNotAllowed || refused.Header().Get("Allow") != "GET, HEAD" {
		t.Errorf("POST: %d", refused.Code)
	}
}

func TestTheWorkerIsIdenticalForEveryVisitorAndHoldsNoAccountState(t *testing.T) {
	h, _ := offlineHarness(t, true)
	signedOut := h.client().send(http.MethodGet, "/preview/offline-worker.js", "", nil).Body.String()
	client := h.client()
	token := client.signIn("alice", alicePassword)
	signedIn := client.send(http.MethodGet, "/preview/offline-worker.js", "", map[string]string{"X-Shelfarr-Account": client.account})
	if signedIn.Body.String() != signedOut {
		t.Fatal("the worker differs once a session cookie is present")
	}
	for _, secret := range []string{alicePassword, token, client.cookies[sessionCookieName], `"account"`, "csrf"} {
		if strings.Contains(signedOut, secret) {
			t.Errorf("the worker contains %q", secret)
		}
	}
}

func TestTheWorkerVersionFollowsTheAssetBuild(t *testing.T) {
	first, _ := offlineHarness(t, true)
	second, _ := offlineHarness(t, true)
	versionOf := func(h *browserHarness) string {
		return workerConfigOf(t, h.client().send(http.MethodGet, "/preview/offline-worker.js", "", nil).Body.String()).Version
	}
	if versionOf(first) != versionOf(second) {
		t.Fatal("the same build must produce the same worker version")
	}
	directory := t.TempDir()
	listed := webassetstest.WriteWithReaderEngine(t, directory)
	other := []byte("console.log('another build');\n")
	name := webassetstest.Name("preview", other, ".js")
	os.WriteFile(filepath.Join(directory, name), other, 0o600)
	delete(listed.Files, listed.Entry.Script)
	listed.Entry.Script = name
	listed.Files[name] = webassetstest.Describe(other)
	webassetstest.WriteManifest(t, directory, listed)
	changed := newBrowserHarness(t, func(config *Config) {
		config.WebAssetsDir = directory
		config.WebOffline = true
	})
	if versionOf(changed) == versionOf(first) {
		t.Fatal("a different build must produce a different worker version")
	}
}

func TestSignInAndBootstrapNameTheOfflineWindowOfTheSessionCappedAtThirtyDays(t *testing.T) {
	for _, test := range []struct {
		days    string
		elapsed time.Duration
		want    int
	}{
		{"", 0, 30 * 86400},
		{"7", 0, 7 * 86400},
		{"7", 6*24*time.Hour + time.Hour, 23 * 3600},
		{"90", 0, 30 * 86400},
		{"90", 75 * 24 * time.Hour, 15 * 86400},
	} {
		h, _ := offlineHarness(t, true)
		if test.days != "" {
			livetest.Exec(t, h.path, `INSERT INTO settings (key, value, value_type) VALUES ('session_max_age_days', ?, 'integer')`, test.days)
		}
		client := h.client()
		token, _ := client.bootstrap()
		login := decoded(t, client.login("alice", alicePassword, token))
		h.clock.Advance(test.elapsed)
		_, resumed := client.bootstrap()
		if test.elapsed == 0 && login["offline_expires_in"] != float64(test.want) {
			t.Errorf("%s days: login window %v, want %d", test.days, login["offline_expires_in"], test.want)
		}
		window, _ := resumed["offline_expires_in"].(float64)
		if resumed["authenticated"] != true || window < float64(test.want-1) || window > float64(test.want) {
			t.Errorf("%s days after %s: bootstrap %v, want %d", test.days, test.elapsed, resumed, test.want)
		}
	}
}

func TestTheOfflineWindowNeverOutlivesTheSignedSessionCookie(t *testing.T) {
	h, _ := offlineHarness(t, true)
	livetest.Exec(t, h.path, `INSERT INTO settings (key, value, value_type) VALUES ('session_max_age_days', '1', 'integer')`)
	client := h.client()
	client.signIn("alice", alicePassword)
	livetest.Exec(t, h.path, `UPDATE settings SET value = '30' WHERE key = 'session_max_age_days'`)
	h.clock.Advance(20 * time.Hour)
	_, resumed := client.bootstrap()
	window, _ := resumed["offline_expires_in"].(float64)
	if resumed["authenticated"] != true || window < 4*3600-1 || window > 4*3600 {
		t.Fatalf("the window must end with the cookie signed at sign-in, got %v", resumed)
	}
}

func TestTheOfflineOptionNeedsTheAssetsAndTheirReaderEngine(t *testing.T) {
	config := Config{DatabasePath: "/x/db", LockPath: "/x/lock", LibraryRoots: []string{"/x/lib"}, SecretKeyBase: testSecret, Listen: "127.0.0.1:0", WebOffline: true}
	if err := config.Validate(); !errors.Is(err, ErrConfig) {
		t.Errorf("without assets: %v", err)
	}
	directory := t.TempDir()
	webassetstest.Write(t, directory)
	path := livetest.Create(t)
	base := t.TempDir()
	root := filepath.Join(base, "library")
	os.MkdirAll(root, 0o700)
	config = Config{DatabasePath: path, LockPath: filepath.Join(base, "lock"), LibraryRoots: []string{root}, SecretKeyBase: testSecret, Listen: "127.0.0.1:0", PreviewUserIDs: []string{"1"}, WebAssetsDir: directory, WebOffline: true}
	announced := false
	err := Run(context.Background(), config, slog.New(slog.NewJSONHandler(&buffer{}, nil)), func(net.Addr) { announced = true })
	var started StartError
	if !errors.As(err, &started) || started.Code != "web-offline" || announced {
		t.Errorf("without the reader engine: %v announced=%v", err, announced)
	}
}

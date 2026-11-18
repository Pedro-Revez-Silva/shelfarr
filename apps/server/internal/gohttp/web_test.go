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

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/livetest"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/webassets/webassetstest"
)

func webHarness(t *testing.T, adjust func(*Config)) (*browserHarness, webassetstest.Manifest) {
	t.Helper()
	directory := t.TempDir()
	listed := webassetstest.Write(t, directory)
	h := newBrowserHarness(t, func(config *Config) {
		config.WebAssetsDir = directory
		if adjust != nil {
			adjust(config)
		}
	})
	return h, listed
}

var shellPaths = map[string]string{"/preview/library": "library", "/preview/library/7": "details", "/preview/account": "account", "/consumer/connect": "connect", "/consumer/connect?user_code=ABCD-EFGH": "connect"}

func TestTheShellRoutesServeOneStaticDocumentPerViewWithAStrictPolicy(t *testing.T) {
	h, listed := webHarness(t, nil)
	client := h.client()
	for path, view := range shellPaths {
		recorder := client.send(http.MethodGet, path, "", nil)
		header := recorder.Header()
		if recorder.Code != http.StatusOK || header.Get("Content-Type") != "text/html; charset=utf-8" || header.Get("Cache-Control") != "private, no-store" {
			t.Fatalf("%s: %d %v", path, recorder.Code, header)
		}
		if header.Get("Content-Security-Policy") != "default-src 'none'; script-src 'self'; style-src 'self'; font-src 'self'; img-src 'self' https:; connect-src 'self'; manifest-src 'none'; form-action 'none'; base-uri 'none'; frame-ancestors 'self'; object-src 'none'" || header.Get("X-Content-Type-Options") != "nosniff" || header.Get("X-Frame-Options") != "SAMEORIGIN" {
			t.Errorf("%s: headers %v", path, header)
		}
		if (view == "connect") != (header.Get("Referrer-Policy") == "no-referrer") {
			t.Errorf("%s: the connection page alone must send no referrer, got %q", path, header.Get("Referrer-Policy"))
		}
		body := recorder.Body.String()
		boot := regexp.MustCompile(`<script type="application/json" id="shelfarr-boot">(.*)</script>`).FindStringSubmatch(body)
		var decoded webBoot
		if boot == nil || json.Unmarshal([]byte(boot[1]), &decoded) != nil || !reflect.DeepEqual(decoded, webBoot{Version: 1, Runtime: "go", View: view, Mount: "/preview", API: "/preview/api/v1"}) {
			t.Errorf("%s: boot %v", path, boot)
		}
		for _, required := range []string{`href="/preview/assets/` + listed.Entry.Style + `"`, `src="/preview/assets/` + listed.Entry.Script + `"`, `<html lang="en">`, "<noscript>"} {
			if !strings.Contains(body, required) {
				t.Errorf("%s lacks %s", path, required)
			}
		}
		for _, forbidden := range []string{" onclick=", " onload=", " onerror=", " style=", "javascript:", "<form", "<input"} {
			if strings.Contains(strings.ToLower(body), forbidden) {
				t.Errorf("%s contains %s", path, forbidden)
			}
		}
	}
}

func TestTheShellCarriesNoAccountStateAndIsIdenticalSignedInAndOut(t *testing.T) {
	h, _ := webHarness(t, nil)
	signedOut := h.client().send(http.MethodGet, "/preview/library", "", nil).Body.String()
	client := h.client()
	account, token := signIn(t, client)
	signedIn := client.send(http.MethodGet, "/preview/library", "", map[string]string{"X-Shelfarr-Account": account})
	if signedIn.Body.String() != signedOut {
		t.Fatal("the shell differs once a session cookie is present")
	}
	for _, secret := range []string{alicePassword, token, client.cookies[sessionCookieName]} {
		if strings.Contains(signedIn.Body.String(), secret) {
			t.Errorf("the shell contains %q", secret)
		}
	}
	if len(signedIn.Result().Cookies()) != 0 {
		t.Fatal("the shell must not set cookies")
	}
}

func signIn(t *testing.T, client *browserClient) (string, string) {
	t.Helper()
	token := client.signIn("alice", alicePassword)
	return client.account, token
}

func TestHeadReturnsTheHeadersOfTheShellWithoutABody(t *testing.T) {
	h, _ := webHarness(t, nil)
	for path := range shellPaths {
		get := h.client().send(http.MethodGet, path, "", nil)
		head := h.client().send(http.MethodHead, path, "", nil)
		if head.Code != http.StatusOK || head.Body.Len() != 0 || head.Header().Get("Content-Length") != get.Header().Get("Content-Length") || head.Header().Get("Content-Security-Policy") != get.Header().Get("Content-Security-Policy") {
			t.Errorf("%s: %d %d", path, head.Code, head.Body.Len())
		}
	}
}

func TestEveryOtherMethodOnAScreenIsRefusedAndNothingIsApproved(t *testing.T) {
	h, _ := webHarness(t, nil)
	client := h.client()
	account, token := signIn(t, client)
	for path := range shellPaths {
		for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch, http.MethodOptions} {
			recorder := client.send(method, path, `{"decision":"allow","user_code":"AAAA-BBBB"}`, map[string]string{"Origin": browserOrigin, "X-CSRF-Token": token, "X-Shelfarr-Account": account})
			if recorder.Code != http.StatusMethodNotAllowed || recorder.Header().Get("Allow") != "GET, HEAD" || errorCode(t, recorder) != "method_not_allowed" {
				t.Errorf("%s %s: %d %q", method, path, recorder.Code, recorder.Header().Get("Allow"))
			}
		}
	}
	if rows := livetest.Query(t, h.path, `SELECT COUNT(*) FROM consumer_device_grants`); rows[0][0].(int64) != 0 {
		t.Fatal("a refused request changed a grant")
	}
}

func TestPathsOutsideTheScreensKeepAnsweringJSONNotTheShell(t *testing.T) {
	h, _ := webHarness(t, nil)
	client := h.client()
	for _, path := range []string{
		"/", "/read", "/admin", "/admin/users", "/login", "/session", "/preview/", "/preview/library/", "/preview/library/0", "/preview/library/01", "/preview/library/abc", "/preview/library/1/extra",
		"/preview/library/99999999999999999999", "/preview/account/", "/preview/account/password", "/preview/profile", "/preview/admin", "/preview/signin", "/preview/api", "/preview/api/", "/preview/api/v1", "/preview/api/v1/", "/preview/api/v1/unknown", "/preview/api/v2/session",
		"/preview/assets", "/preview/assets/", "/preview/assets/missing.0000000000000000.js", "/preview/assets/a/b.js", "/preview/assets/manifest.json", "/preview/assets/%2e%2e/manifest.json", "/preview/assets/preview.js.map",
		"/consumer", "/consumer/connect/", "/consumer/connect/extra", "/consumer/connection", "/api/v1/requests", "/api/consumer/v1/unknown",
	} {
		recorder := client.send(http.MethodGet, path, "", nil)
		if recorder.Code != http.StatusNotFound || !strings.HasPrefix(recorder.Header().Get("Content-Type"), "application/json") || errorCode(t, recorder) != "not_found" {
			t.Errorf("%s: %d %s %q", path, recorder.Code, recorder.Header().Get("Content-Type"), recorder.Body.String())
		}
	}
}

func TestIndexRedirectsToTheLibraryWithAnExplicitStatus(t *testing.T) {
	h, _ := webHarness(t, nil)
	for _, method := range []string{http.MethodGet, http.MethodHead} {
		recorder := h.client().send(method, "/preview", "", nil)
		if recorder.Code != http.StatusSeeOther || recorder.Header().Get("Location") != "/preview/library" || recorder.Header().Get("Cache-Control") != "private, no-store" || recorder.Body.Len() != 0 {
			t.Errorf("%s: %d %v", method, recorder.Code, recorder.Header())
		}
	}
	if recorder := h.client().send(http.MethodPost, "/preview", "", nil); recorder.Code != http.StatusMethodNotAllowed {
		t.Errorf("POST: %d", recorder.Code)
	}
}

func TestStaticAssetsAreServedPubliclyWithTheirDigestAndCarryNoAccountState(t *testing.T) {
	h, listed := webHarness(t, nil)
	for name, entry := range listed.Files {
		client := h.client()
		recorder := client.send(http.MethodGet, "/preview/assets/"+name, "", map[string]string{"Cookie": "session_id=abc", "X-Shelfarr-Account": "1"})
		header := recorder.Header()
		if recorder.Code != http.StatusOK || header.Get("ETag") != `"`+entry.SHA256+`"` || header.Get("Cache-Control") != "public, max-age=31536000, immutable" || header.Get("X-Content-Type-Options") != "nosniff" {
			t.Errorf("%s: %d %v", name, recorder.Code, header)
		}
		if len(recorder.Result().Cookies()) != 0 || header.Get("Vary") != "" && strings.Contains(strings.ToLower(header.Get("Vary")), "cookie") {
			t.Errorf("%s: asset responses must not depend on or set cookies", name)
		}
		if recorder.Header().Get("Content-Security-Policy") != "" {
			t.Errorf("%s: only documents carry the policy", name)
		}
		if recorder.Body.Len() != int(entry.Size) {
			t.Errorf("%s: %d bytes, manifest says %d", name, recorder.Body.Len(), entry.Size)
		}
		if refused := client.send(http.MethodPost, "/preview/assets/"+name, "", nil); refused.Code != http.StatusMethodNotAllowed || refused.Header().Get("Allow") != "GET, HEAD" {
			t.Errorf("%s: POST %d", name, refused.Code)
		}
	}
}

func TestWithoutTheAllowlistTheScreensAreNotFoundEvenSignedOut(t *testing.T) {
	for name, users := range map[string][]string{"unset": nil, "empty": {}} {
		h, listed := webHarness(t, func(config *Config) { config.PreviewUserIDs = users })
		for _, path := range []string{"/preview", "/preview/library", "/preview/library/1", "/preview/account", "/consumer/connect", "/consumer/connect?user_code=ABCD-EFGH", "/preview/assets/" + listed.Entry.Script} {
			for _, method := range []string{http.MethodGet, http.MethodHead, http.MethodPost, http.MethodPut, http.MethodDelete} {
				recorder := h.client().send(method, path, "", nil)
				if recorder.Code != http.StatusNotFound || recorder.Header().Get("Allow") != "" || recorder.Header().Get("Content-Security-Policy") != "" || method != http.MethodHead && errorCode(t, recorder) != "not_found" {
					t.Errorf("%s %s %s: %d %s", name, method, path, recorder.Code, recorder.Body.String())
				}
			}
		}
	}
}

func TestWithoutTheUIOptionEveryScreenPathStaysExactlyAsItWasBefore(t *testing.T) {
	h := newBrowserHarness(t, nil)
	for path := range shellPaths {
		for _, method := range []string{http.MethodGet, http.MethodHead, http.MethodPost} {
			recorder := h.client().send(method, path, "", nil)
			if recorder.Code != http.StatusNotFound || recorder.Header().Get("Allow") != "" || recorder.Header().Get("Content-Security-Policy") != "" {
				t.Errorf("%s %s: %d", method, path, recorder.Code)
			}
		}
	}
	for _, path := range []string{"/preview", "/preview/assets/x.0000000000000000.js"} {
		if recorder := h.client().send(http.MethodGet, path, "", nil); recorder.Code != http.StatusNotFound {
			t.Errorf("%s: %d", path, recorder.Code)
		}
	}
	if recorder := h.client().send(http.MethodGet, "/preview/api/v1/auth/bootstrap", "", nil); recorder.Code != http.StatusOK {
		t.Fatalf("the JSON API must be unchanged: %d", recorder.Code)
	}
}

func TestTheAssetsOptionMustBeAnAbsoluteCleanFolderBeforeTheFilesystemIsTouched(t *testing.T) {
	for _, directory := range []string{"relative", ".", "dist/", "/tmp/../tmp", "/"} {
		config := Config{DatabasePath: "/x/db", LockPath: "/x/lock", LibraryRoots: []string{"/x/lib"}, SecretKeyBase: testSecret, Listen: "127.0.0.1:0", WebAssetsDir: directory}
		if err := config.Validate(); !errors.Is(err, ErrConfig) {
			t.Errorf("%q: %v", directory, err)
		}
	}
}

func TestAMissingAssetsFolderIsRefusedBeforeTheDatabaseIsOpened(t *testing.T) {
	base := t.TempDir()
	root := filepath.Join(base, "library")
	os.MkdirAll(root, 0o700)
	config := Config{DatabasePath: filepath.Join(base, "missing.sqlite3"), LockPath: filepath.Join(base, "lock"), LibraryRoots: []string{root}, SecretKeyBase: testSecret, Listen: "127.0.0.1:0", PreviewUserIDs: []string{"1"}, WebAssetsDir: filepath.Join(base, "nope")}
	err := Run(context.Background(), config, slog.New(slog.NewJSONHandler(&buffer{}, nil)), nil)
	var started StartError
	if !errors.As(err, &started) || started.Code != "web-assets" {
		t.Fatalf("%v", err)
	}
}

func TestRunRefusesToStartWithABadAssetsFolderInsteadOfServingACatchAll(t *testing.T) {
	bad := t.TempDir()
	webassetstest.Write(t, bad)
	for _, entry := range []string{"manifest.json"} {
		if err := os.Truncate(filepath.Join(bad, entry), 0); err != nil {
			t.Fatal(err)
		}
	}
	for name, directory := range map[string]string{"corrupt": bad, "missing": filepath.Join(t.TempDir(), "nope")} {
		path := livetest.Create(t)
		base := t.TempDir()
		root := filepath.Join(base, "library")
		os.MkdirAll(root, 0o700)
		config := Config{DatabasePath: path, LockPath: filepath.Join(base, "lock"), LibraryRoots: []string{root}, SecretKeyBase: testSecret, Listen: "127.0.0.1:0", PreviewUserIDs: []string{"1"}, WebAssetsDir: directory}
		announced := false
		err := Run(context.Background(), config, slog.New(slog.NewJSONHandler(&buffer{}, nil)), func(net.Addr) { announced = true })
		var started StartError
		if !errors.As(err, &started) || started.Code != "web-assets" || announced {
			t.Errorf("%s: %v announced=%v", name, err, announced)
		}
	}
}

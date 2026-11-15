package gohttp

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func environment(values map[string]string) Environment {
	return func(name string) string { return values[name] }
}

func writeSecret(t *testing.T, content string, mode os.FileMode) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "secret")
	if err := os.WriteFile(path, []byte(content), mode); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestSecretKeyBaseFollowsTheKeyModesRailsAlreadySupports(t *testing.T) {
	file := writeSecret(t, "from-the-file\n", 0o600)
	persisted := writeSecret(t, "from-the-persisted-file\n\n", 0o600)
	cases := []struct {
		name        string
		values      map[string]string
		persistedAt string
		want        string
		err         error
	}{
		{"inline", map[string]string{"SECRET_KEY_BASE": "inline-value"}, "", "inline-value", nil},
		{"docker secret file", map[string]string{"SECRET_KEY_BASE_FILE": file}, "", "from-the-file", nil},
		{"persisted volume file", nil, persisted, "from-the-persisted-file", nil},
		{"nothing configured", nil, "", "", ErrSecretMissing},
		{"inline and file", map[string]string{"SECRET_KEY_BASE": "a", "SECRET_KEY_BASE_FILE": file}, "", "", ErrSecretAmbiguous},
		{"inline and persisted", map[string]string{"SECRET_KEY_BASE": "a"}, persisted, "", ErrSecretAmbiguous},
		{"credentials master key only", map[string]string{"RAILS_MASTER_KEY": "k"}, "", "", ErrMasterKeyMode},
		{"credentials master key file only", map[string]string{"RAILS_MASTER_KEY_FILE": file}, "", "", ErrMasterKeyMode},
		{"explicit secret wins over the master key being present", map[string]string{"SECRET_KEY_BASE": "x", "RAILS_MASTER_KEY": "k"}, "", "x", nil},
		{"missing file", map[string]string{"SECRET_KEY_BASE_FILE": "/nonexistent/secret"}, "", "", ErrSecretUnreadable},
	}
	for _, c := range cases {
		got, err := ResolveSecretKeyBase(environment(c.values), c.persistedAt)
		if !errors.Is(err, c.err) || got != c.want {
			t.Errorf("%s: got %q %v want %q %v", c.name, got, err, c.want, c.err)
		}
	}
}

func TestSecretFilesMustBeSmallRegularUtf8Files(t *testing.T) {
	directory := t.TempDir()
	link := filepath.Join(directory, "link")
	if err := os.Symlink(writeSecret(t, "value", 0o600), link); err != nil {
		t.Fatal(err)
	}
	for name, path := range map[string]string{
		"symbolic link": link, "directory": directory, "oversized": writeSecret(t, strings.Repeat("a", 5000), 0o600), "not utf-8": writeSecret(t, "\xff\xfe", 0o600),
	} {
		if _, err := ResolveSecretKeyBase(environment(map[string]string{"SECRET_KEY_BASE_FILE": path}), ""); !errors.Is(err, ErrSecretUnreadable) {
			t.Errorf("%s: %v", name, err)
		}
	}
}

func validConfig(t *testing.T) Config {
	t.Helper()
	directory := t.TempDir()
	return Config{DatabasePath: filepath.Join(directory, "db.sqlite3"), LockPath: filepath.Join(directory, "lock"), LibraryRoots: []string{directory}, SecretKeyBase: "secret", Listen: "127.0.0.1:0"}
}

func TestConfigurationRefusesWhatCouldExposeOrMisplaceTheRuntime(t *testing.T) {
	good := validConfig(t)
	if err := good.Validate(); err != nil {
		t.Fatal(err)
	}
	mutations := map[string]func(*Config){
		"relative database":  func(c *Config) { c.DatabasePath = "db.sqlite3" },
		"empty database":     func(c *Config) { c.DatabasePath = "" },
		"relative lock":      func(c *Config) { c.LockPath = "lock" },
		"no library roots":   func(c *Config) { c.LibraryRoots = nil },
		"relative root":      func(c *Config) { c.LibraryRoots = []string{"library"} },
		"filesystem root":    func(c *Config) { c.LibraryRoots = []string{"/"} },
		"blank secret":       func(c *Config) { c.SecretKeyBase = "  " },
		"public listen":      func(c *Config) { c.Listen = "0.0.0.0:3000" },
		"hostname listen":    func(c *Config) { c.Listen = "localhost:3000" },
		"missing port":       func(c *Config) { c.Listen = "127.0.0.1" },
		"bad server version": func(c *Config) { c.ServerVersion = "not a version!" },
	}
	for name, mutate := range mutations {
		config := validConfig(t)
		mutate(&config)
		if err := config.Validate(); !errors.Is(err, ErrConfig) {
			t.Errorf("%s: %v", name, err)
		}
	}
	public := validConfig(t)
	public.Listen, public.AllowPublicBind = "0.0.0.0:3000", true
	if err := public.Validate(); err != nil {
		t.Fatalf("an explicit non-loopback bind must be possible: %v", err)
	}
	for _, loopback := range []string{"127.0.0.1:1", "[::1]:1", "127.5.5.5:9"} {
		config := validConfig(t)
		config.Listen = loopback
		if err := config.Validate(); err != nil {
			t.Errorf("%s: %v", loopback, err)
		}
	}
}

func TestLibraryRootsAreCanonicalisedAndMustExist(t *testing.T) {
	base, _ := filepath.EvalSymlinks(t.TempDir())
	real := filepath.Join(base, "real")
	if err := os.Mkdir(real, 0o700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(base, "link")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(base, "file")
	os.WriteFile(file, nil, 0o600)
	got, err := ResolveRoots([]string{link})
	if err != nil || !reflect.DeepEqual(got, []string{real}) {
		t.Fatalf("%v %v", got, err)
	}
	for _, bad := range [][]string{{filepath.Join(base, "absent")}, {file}, {"/"}} {
		if _, err := ResolveRoots(bad); !errors.Is(err, ErrConfig) {
			t.Errorf("%v: %v", bad, err)
		}
	}
}

func TestAndroidChannelsFollowTheRailsParser(t *testing.T) {
	cases := map[string][]string{
		"release": {"release"}, "development": {"development"}, "development,release": {"release", "development"}, " Release , release ": {"release"},
		"": nil, "none": nil, "OFF": nil, "0": nil, "beta": nil, "release,beta": nil, "none,release": nil,
	}
	for input, want := range cases {
		if got := ParseAndroidChannels(input); !reflect.DeepEqual(got, want) {
			t.Errorf("%q: got %v want %v", input, got, want)
		}
	}
}

func TestClassifyRoutesMatchTheRailsRouteTable(t *testing.T) {
	cases := []struct {
		method, path string
		kind         routeKind
	}{
		{"GET", "/api/consumer/v1/server.json", routeServer},
		{"HEAD", "/api/consumer/v1/me", routeMe},
		{"GET", "/api/consumer/v1/continue", routeContinue},
		{"GET", "/api/consumer/v1/library", routeLibrary},
		{"GET", "/api/consumer/v1/library/12", routePublication},
		{"GET", "/api/consumer/v1/library/12/assets/abc", routeAsset},
		{"GET", "/api/consumer/v1/library/12/assets/abc/reading_order", routeReadingOrder},
		{"HEAD", "/api/consumer/v1/library/12/assets/abc/reading_order", routeReadingOrder},
		{"POST", "/api/consumer/v1/library/12/assets/abc/reading_order", routeWrongMethod},
		{"GET", "/api/consumer/v1/library/12/assets/a.b/reading_order", routeNone},
		{"GET", "/api/consumer/v1/library/12/assets/abc/reading_order.json", routeNone},
		{"GET", "/api/consumer/v1/library/12/assets/abc/reading_order/extra", routeNone},
		{"GET", "/api/consumer/v1/library/12/assets/abc/read_along/resources/a/b.xhtml", routeExcluded},
		{"GET", "/api/consumer/v1/library/12/progress", routeProgress},
		{"HEAD", "/api/consumer/v1/library/12/progress", routeProgress},
		{"PUT", "/api/consumer/v1/library/12/progress", routeProgress},
		{"POST", "/api/consumer/v1/library/12/progress", routeWrongMethod},
		{"DELETE", "/api/consumer/v1/library/12/progress", routeWrongMethod},
		{"PUT", "/api/consumer/v1/library/12/reading_status", routeReadingStatus},
		{"GET", "/api/consumer/v1/library/12/reading_status", routeWrongMethod},
		{"PUT", "/api/consumer/v1/library/1.json/progress", routeNone},
		{"PUT", "/api/consumer/v1/library//progress", routeNone},
		{"PUT", "/api/consumer/v1/library/12/progress/extra", routeNone},
		{"POST", "/api/consumer/v1/auth/token", routeAuthToken},
		{"POST", "/api/consumer/v1/auth/device", routeAuthDevice},
		{"POST", "/api/consumer/v1/auth/revoke", routeAuthRevoke},
		{"GET", "/api/consumer/v1/auth/device", routeNone},
		{"GET", "/api/consumer/v1/auth/revoke", routeNone},
		{"GET", "/preview/api/v1/connect", routeBrowserConnect},
		{"HEAD", "/preview/api/v1/connect", routeBrowserConnect},
		{"POST", "/preview/api/v1/connect", routeBrowserDecide},
		{"PUT", "/preview/api/v1/connect", routeWrongMethod},
		{"GET", "/api/consumer/v1/auth/token", routeNone},
		{"POST", "/api/consumer/v1/library", routeWrongMethod},
		{"GET", "/api/consumer/v1/library/12/assets/a.b", routeNone},
		{"GET", "/api/consumer/v1/library//assets/a", routeNone},
		{"GET", "/api/consumer/v1/library/1/assets/a/extra", routeNone},
		{"GET", "/up", routeUp},
		{"GET", "/readyz", routeReady},
		{"GET", "/read", routeNone},
	}
	for _, c := range cases {
		if got := classify(c.method, c.path).kind; got != c.kind {
			t.Errorf("%s %s: got %d want %d", c.method, c.path, got, c.kind)
		}
	}
}

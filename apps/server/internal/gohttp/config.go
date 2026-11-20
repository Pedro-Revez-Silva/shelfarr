package gohttp

import (
	"errors"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"
)

var (
	ErrConfig = errors.New("configuration is invalid")
)

type Config struct {
	DatabasePath    string
	LockPath        string
	LibraryRoots    []string
	SecretKeyBase   string
	ServerVersion   string
	AndroidChannels []string
	Listen          string
	AllowPublicBind bool
	WebAssetsDir    string
	WebOffline      bool

	OpenLibrarySearch bool

	AcquisitionWorkdir string
	OpenLibraryFixture string

	PreviewUserIDs  []string
	BrowserOrigin   string
	PasswordlessEnv bool

	MaxLoginWorkers int
	LoginAttempts   int
	LoginWindow     time.Duration
	LoginWait       time.Duration

	MaxMetadataRequests int
	MaxMediaStreams     int
	RequestTimeout      time.Duration
	StreamWriteStall    time.Duration
	ReadHeaderTimeout   time.Duration
	ReadTimeout         time.Duration
	IdleTimeout         time.Duration
	ShutdownTimeout     time.Duration
	BusyTimeout         time.Duration
	BodyTimeout         time.Duration
	MaxHeaderBytes      int
	Clock               func() time.Time
}

func (c *Config) applyDefaults() {
	set := func(value *time.Duration, fallback time.Duration) {
		if *value <= 0 {
			*value = fallback
		}
	}
	set(&c.RequestTimeout, 20*time.Second)
	set(&c.StreamWriteStall, 30*time.Second)
	set(&c.ReadHeaderTimeout, 5*time.Second)
	set(&c.ReadTimeout, 15*time.Second)
	set(&c.IdleTimeout, 60*time.Second)
	set(&c.ShutdownTimeout, 20*time.Second)
	set(&c.BusyTimeout, 5*time.Second)
	set(&c.BodyTimeout, 5*time.Second)
	set(&c.LoginWindow, 3*time.Minute)
	set(&c.LoginWait, 2*time.Second)
	if c.MaxLoginWorkers <= 0 {
		c.MaxLoginWorkers = 4
	}
	if c.LoginAttempts <= 0 {
		c.LoginAttempts = 10
	}
	if c.MaxMetadataRequests <= 0 {
		c.MaxMetadataRequests = 64
	}
	if c.MaxMediaStreams <= 0 {
		c.MaxMediaStreams = 8
	}
	if c.MaxHeaderBytes <= 0 {
		c.MaxHeaderBytes = 32 << 10
	}
	if c.ServerVersion == "" {
		c.ServerVersion = "unknown"
	}
}

func (c *Config) Validate() error {
	c.applyDefaults()
	if !filepath.IsAbs(c.DatabasePath) || !filepath.IsAbs(c.LockPath) || len(c.LibraryRoots) == 0 {
		return ErrConfig
	}
	for _, root := range c.LibraryRoots {
		if !filepath.IsAbs(root) || filepath.Clean(root) == "/" {
			return ErrConfig
		}
	}
	if strings.TrimSpace(c.SecretKeyBase) == "" {
		return ErrConfig
	}
	if !validServerVersion(c.ServerVersion) {
		return ErrConfig
	}
	if c.WebAssetsDir != "" && (!filepath.IsAbs(c.WebAssetsDir) || filepath.Clean(c.WebAssetsDir) != c.WebAssetsDir || c.WebAssetsDir == "/") {
		return ErrConfig
	}
	if c.WebOffline && c.WebAssetsDir == "" {
		return ErrConfig
	}
	if c.OpenLibraryFixture != "" && (c.AcquisitionWorkdir == "" || !c.OpenLibrarySearch) {
		return ErrConfig
	}
	if c.BrowserOrigin != "" {
		origin, err := CanonicalOrigin(c.BrowserOrigin)
		if err != nil {
			return err
		}
		c.BrowserOrigin = origin
	}
	return validateListen(c.Listen, c.AllowPublicBind)
}

func CanonicalOrigin(value string) (string, error) {
	parsed, err := url.Parse(value)
	if err != nil || parsed.Host == "" || parsed.User != nil || parsed.Path != "" || parsed.RawQuery != "" || parsed.Fragment != "" || parsed.Opaque != "" || strings.HasSuffix(value, "/") {
		return "", ErrConfig
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return "", ErrConfig
	}
	host := strings.ToLower(parsed.Hostname())
	port := parsed.Port()
	if host == "" || port == "" && strings.HasSuffix(parsed.Host, ":") || port == "80" && parsed.Scheme == "http" || port == "443" && parsed.Scheme == "https" {
		port = ""
	}
	if strings.Contains(host, ":") {
		host = "[" + host + "]"
	}
	if port != "" {
		host += ":" + port
	}
	return parsed.Scheme + "://" + host, nil
}

var previewUserID = regexp.MustCompile(`^[1-9][0-9]{0,18}$`)

const maxPreviewUsers = 100

func ParsePreviewUsers(raw string) ([]string, bool) {
	if strings.TrimSpace(raw) == "" {
		return nil, true
	}
	entries := strings.Split(raw, ",")
	if len(entries) > maxPreviewUsers {
		return nil, false
	}
	var ids []string
	for _, entry := range entries {
		entry = strings.TrimSpace(entry)
		if !previewUserID.MatchString(entry) {
			return nil, false
		}
		if !slices.Contains(ids, entry) {
			ids = append(ids, entry)
		}
	}
	return ids, true
}

func validServerVersion(value string) bool {
	if value == "unknown" {
		return true
	}
	if len(value) == 0 || len(value) > 64 || !alphanumeric(value[0]) {
		return false
	}
	for index := 1; index < len(value); index++ {
		if !alphanumeric(value[index]) && !strings.ContainsRune("._+-", rune(value[index])) {
			return false
		}
	}
	return true
}

func alphanumeric(value byte) bool {
	return value >= '0' && value <= '9' || value >= 'a' && value <= 'z' || value >= 'A' && value <= 'Z'
}

func validateListen(address string, allowPublic bool) error {
	host, port, err := net.SplitHostPort(address)
	if err != nil || port == "" {
		return ErrConfig
	}
	if allowPublic {
		return nil
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return ErrConfig
	}
	return nil
}

func ResolveRoots(roots []string) ([]string, error) {
	resolved := make([]string, 0, len(roots))
	for _, root := range roots {
		canonical, err := filepath.EvalSymlinks(root)
		if err != nil || canonical == "/" {
			return nil, ErrConfig
		}
		info, err := os.Stat(canonical)
		if err != nil || !info.IsDir() {
			return nil, ErrConfig
		}
		resolved = append(resolved, canonical)
	}
	return resolved, nil
}

func ParseAndroidChannels(raw string) []string {
	var names []string
	for _, name := range strings.Split(raw, ",") {
		name = strings.ToLower(strings.TrimSpace(name))
		if name != "" {
			names = append(names, name)
		}
	}
	if len(names) == 0 {
		return nil
	}
	if len(names) == 1 {
		switch names[0] {
		case "none", "off", "false", "0":
			return nil
		}
	}
	for _, name := range names {
		if name != "release" && name != "development" {
			return nil
		}
	}
	var channels []string
	for _, channel := range []string{"release", "development"} {
		if slices.Contains(names, channel) {
			channels = append(channels, channel)
		}
	}
	return channels
}

package gohttp

import (
	"errors"
	"net"
	"os"
	"path/filepath"
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
	return validateListen(c.Listen, c.AllowPublicBind)
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

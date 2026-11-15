package inventory

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/wfstore"
)

const (
	PlatformAudiobookshelf = "audiobookshelf"
	minimumInterval        = time.Minute
	defaultInterval        = time.Hour
)

var libraryPlatforms = map[string]bool{"audiobookshelf": true, "bookorbit": true, "grimmory": true}

var libraryIDSettings = []string{
	"audiobookshelf_audiobook_library_id",
	"audiobookshelf_ebook_library_id",
	"audiobookshelf_comicbook_library_id",
	"audiobookshelf_audiobook_scan_library_ids",
	"audiobookshelf_ebook_scan_library_ids",
	"audiobookshelf_comicbook_scan_library_ids",
}

type Config struct {
	Platform    string
	URL         string
	APIKey      string
	ExplicitIDs []string
	Interval    time.Duration
}

func LoadConfig(ctx context.Context, q wfstore.Querier) (Config, error) {
	var config Config
	platform, err := wfstore.Setting(ctx, q, "library_platform")
	if err != nil {
		return config, err
	}
	platform = strings.ToLower(strings.TrimSpace(platform))
	if !libraryPlatforms[platform] {
		platform = PlatformAudiobookshelf
	}
	config.Platform = platform
	if config.URL, err = wfstore.Setting(ctx, q, "audiobookshelf_url"); err != nil {
		return config, err
	}
	config.URL = strings.TrimSpace(config.URL)
	if config.APIKey, err = wfstore.Setting(ctx, q, "audiobookshelf_api_key"); err != nil {
		return config, err
	}
	config.APIKey = strings.TrimSpace(config.APIKey)
	seen := map[string]bool{}
	for _, key := range libraryIDSettings {
		value, err := wfstore.Setting(ctx, q, key)
		if err != nil {
			return config, err
		}
		for _, id := range strings.Split(value, ",") {
			if id = strings.TrimSpace(id); id != "" && !seen[id] {
				seen[id] = true
				config.ExplicitIDs = append(config.ExplicitIDs, id)
			}
		}
	}
	interval, err := wfstore.Setting(ctx, q, "audiobookshelf_library_sync_interval")
	if err != nil {
		return config, err
	}
	config.Interval = parseInterval(interval)
	return config, nil
}

func parseInterval(text string) time.Duration {
	if strings.TrimSpace(text) == "" {
		return defaultInterval
	}
	seconds, err := strconv.ParseInt(strings.TrimSpace(text), 10, 64)
	if err != nil {
		return 0
	}
	if seconds <= 0 {
		return 0
	}
	return max(time.Duration(seconds)*time.Second, minimumInterval)
}

func (c Config) Configured() bool { return c.URL != "" && c.APIKey != "" }

func (c Config) Fingerprint() string {
	scope := "auto"
	if len(c.ExplicitIDs) > 0 {
		sorted := append([]string(nil), c.ExplicitIDs...)
		sort.Strings(sorted)
		scope = "explicit:" + strings.Join(sorted, ",")
	}
	sum := sha256.Sum256([]byte("v2\x00" + c.Platform + "\x00" + strings.TrimRight(c.URL, "/") + "\x00" + c.APIKey + "\x00" + scope))
	return hex.EncodeToString(sum[:])
}

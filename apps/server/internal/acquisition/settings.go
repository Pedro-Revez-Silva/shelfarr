package acquisition

import (
	"context"
	"database/sql"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/gutenberg"
)

const (
	defaultGutenbergURL    = "https://www.gutenberg.org"
	zlibraryDefaultMirrors = "the default mirror list"
	defaultSearchLimit     = 10
	defaultMaxRetries      = 10
	defaultRetryBaseHours  = 24
	defaultRetryMaxDays    = 7
	defaultLanguage        = "en"
	maxRetryDelayDays      = 100_000
)

var (
	storedInteger = regexp.MustCompile(`\A[\t\n\v\f\r ]*([+-]?)0*([0-9]+(?:_[0-9]+)*)[\t\n\v\f\r ]*\z`)
	countryCode   = regexp.MustCompile(`\A[A-Za-z]{2}\z`)
	rubyFalse     = map[string]bool{"0": true, "f": true, "F": true, "false": true, "FALSE": true, "off": true, "OFF": true}
)

type setting struct {
	value     sql.NullString
	valueType string
	stored    bool
}

type settings map[string]setting

func readSettings(ctx context.Context, tx *sql.Tx) (settings, error) {
	rows, err := tx.QueryContext(ctx, `SELECT key, value, value_type FROM settings`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	found := settings{}
	for rows.Next() {
		var key string
		var entry setting
		if err := rows.Scan(&key, &entry.value, &entry.valueType); err != nil {
			return nil, ErrStoredValue
		}
		if !utf8.ValidString(key) || !utf8.ValidString(entry.value.String) {
			return nil, ErrStoredValue
		}
		if _, duplicate := found[key]; duplicate {
			return nil, ErrStoredValue
		}
		entry.stored = true
		found[key] = entry
	}
	return found, rows.Err()
}

func (s settings) truthy(key string) bool {
	entry := s[key]
	if !entry.stored || !entry.value.Valid {
		return false
	}
	switch entry.valueType {
	case "boolean":
		return entry.value.String != "" && !rubyFalse[entry.value.String]
	case "json":
		trimmed := strings.TrimSpace(entry.value.String)
		return trimmed != "false" && trimmed != "null"
	}
	return true
}

func (s settings) text(key, fallback string) (string, bool) {
	entry := s[key]
	if !entry.stored || !entry.value.Valid {
		return fallback, true
	}
	return entry.value.String, entry.valueType == "string"
}

func (s settings) present(key, fallback string) bool {
	entry := s[key]
	if !entry.stored || !entry.value.Valid {
		return !gutenberg.RubyBlank(fallback)
	}
	if entry.valueType != "string" {
		return true
	}
	return !gutenberg.RubyBlank(entry.value.String)
}

func (s settings) integer(key string, fallback int64) (int64, error) {
	entry := s[key]
	if !entry.stored || !entry.value.Valid {
		return fallback, nil
	}
	match := storedInteger.FindStringSubmatch(entry.value.String)
	if (entry.valueType != "integer" && entry.valueType != "string") || match == nil {
		return 0, ErrStoredValue
	}
	value, err := strconv.ParseInt(match[1]+strings.ReplaceAll(match[2], "_", ""), 10, 64)
	if err != nil {
		return 0, ErrStoredValue
	}
	return value, nil
}

type Config struct {
	Origin         gutenberg.Origin
	Limit          int
	MaxRetries     int64
	RetryBaseHours int64
	RetryMaxDays   int64
	defaultLang    string
}

func loadConfig(ctx context.Context, tx *sql.Tx) (Config, error) {
	stored, err := readSettings(ctx, tx)
	if err != nil {
		return Config{}, err
	}
	if !stored.truthy("gutenberg_enabled") || !stored.present("gutenberg_url", defaultGutenbergURL) {
		return Config{}, ErrProviderDisabled
	}
	if reason := otherSource(stored); reason != nil {
		return Config{}, reason
	}
	address, isText := stored.text("gutenberg_url", defaultGutenbergURL)
	if !isText {
		return Config{}, ErrStoredValue
	}
	origin, err := gutenberg.ParseOrigin(address)
	if err != nil {
		return Config{}, ErrProviderInvalid
	}
	if !origin.Loopback() {
		return Config{}, ErrProviderNotLoopback
	}
	config := Config{Origin: origin}
	limit, err := stored.integer("gutenberg_search_limit", defaultSearchLimit)
	if err != nil {
		return Config{}, err
	}
	config.Limit = int(min(max(limit, gutenberg.MinLimit), gutenberg.MaxLimit))
	if config.MaxRetries, err = stored.integer("max_retries", defaultMaxRetries); err != nil {
		return Config{}, err
	}
	if config.RetryBaseHours, err = stored.integer("retry_base_delay_hours", defaultRetryBaseHours); err != nil {
		return Config{}, err
	}
	if config.RetryMaxDays, err = stored.integer("retry_max_delay_days", defaultRetryMaxDays); err != nil {
		return Config{}, err
	}
	if config.RetryBaseHours < 0 || config.RetryMaxDays < 0 || config.RetryMaxDays > maxRetryDelayDays {
		return Config{}, ErrStoredValue
	}
	language, isText := stored.text("default_language", defaultLanguage)
	if !isText {
		return Config{}, ErrStoredValue
	}
	config.defaultLang = language
	return config, nil
}

func otherSource(stored settings) error {
	switch {
	case indexerConfigured(stored),
		stored.truthy("anna_archive_enabled") && stored.present("anna_archive_api_key", ""),
		zlibraryConfigured(stored),
		stored.truthy("ebooks_com_enabled") && storedCountry(stored):
		return ErrOtherSources
	case stored.truthy("auto_select_enabled"):
		return ErrAutoSelect
	case stored.truthy("webhook_enabled") && stored.present("webhook_url", ""),
		stored.truthy("discord_enabled") && stored.present("discord_webhook_url", ""),
		stored.truthy("telegram_enabled") && stored.present("telegram_bot_token", ""):
		return ErrOutbound
	}
	return nil
}

func indexerConfigured(stored settings) bool {
	configured := func(name string) bool {
		return stored.present(name+"_url", "") && stored.present(name+"_api_key", "")
	}
	provider, _ := stored.text("indexer_provider", "")
	switch provider = gutenberg.RubyStrip(provider); provider {
	case "none":
		return false
	case "prowlarr", "jackett", "newznab":
		return configured(provider)
	}
	return configured("prowlarr")
}

func zlibraryConfigured(stored settings) bool {
	if !stored.truthy("zlibrary_enabled") || !stored.present("zlibrary_url", zlibraryDefaultMirrors) {
		return false
	}
	passwordLogin := stored.present("zlibrary_email", "") && stored.present("zlibrary_password", "")
	savedSession := stored.present("zlibrary_remix_userid", "") && stored.present("zlibrary_remix_userkey", "")
	return passwordLogin || savedSession
}

func storedCountry(stored settings) bool {
	code, isText := stored.text("ebooks_com_country_code", "")
	return !isText || countryCode.MatchString(gutenberg.RubyStrip(code))
}

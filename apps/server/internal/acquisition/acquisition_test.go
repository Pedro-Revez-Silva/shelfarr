package acquisition

import (
	"database/sql"
	"errors"
	"reflect"
	"testing"
	"time"
)

func TestTitleVariantsMatchSearchTitleVariantService(t *testing.T) {
	for title, want := range map[string][]string{
		"  Pride   and\tPrejudice ":           {"Pride and Prejudice"},
		"Le Petit Prince / The Little Prince": {"Le Petit Prince", "The Little Prince", "Le Petit Prince / The Little Prince"},
		"Le Petit Prince / The Little Prince": {"Le Petit Prince", "The Little Prince", "Le Petit Prince / The Little Prince"},
		"A / B / C":                           {"A", "B / C", "A / B / C"},
		"AC/DC":                               {"AC/DC"},
		"Same / Same":                         {"Same", "Same / Same"},
		" \t ":                                nil,
	} {
		if got := TitleVariants(title); !reflect.DeepEqual(got, want) {
			t.Errorf("%q: %q, want %q", title, got, want)
		}
	}
}

func TestRetryDelayMatchesScheduleRetry(t *testing.T) {
	now := time.Date(2026, 11, 19, 12, 0, 0, 0, time.UTC)
	config := Config{RetryBaseHours: 24, RetryMaxDays: 7}
	for retries, hours := range map[int64]int{0: 24, 1: 48, 2: 96, 3: 168, 9: 168, 70: 168} {
		if got := retryAt(now, retries, config); !got.Equal(now.Add(time.Duration(hours) * time.Hour)) {
			t.Errorf("retry %d: %v, want +%dh", retries, got, hours)
		}
	}
	if got := retryAt(now, 80, Config{RetryBaseHours: 0, RetryMaxDays: 7}); !got.Equal(now) {
		t.Errorf("a zero base delay retries now, got %v", got)
	}
	if got := retryAt(now, 1, Config{RetryBaseHours: 5, RetryMaxDays: 100_000}); !got.Equal(now.Add(10 * time.Hour)) {
		t.Errorf("got %v", got)
	}
}

func stored(valueType string, value any) setting {
	entry := setting{valueType: valueType, stored: true}
	if text, ok := value.(string); ok {
		entry.value = sql.NullString{String: text, Valid: true}
	}
	return entry
}

func TestSettingsReadLikeSettingsService(t *testing.T) {
	values := settings{
		"on":          stored("boolean", "true"),
		"yes":         stored("boolean", "yes"),
		"off":         stored("boolean", "off"),
		"zero":        stored("boolean", "0"),
		"blank":       stored("boolean", ""),
		"null":        stored("boolean", nil),
		"text false":  stored("string", "false"),
		"json false":  stored("json", " false "),
		"json list":   stored("json", "[]"),
		"spaces":      stored("string", "  "),
		"number":      stored("integer", "12"),
		"negative":    stored("integer", "-3"),
		"words":       stored("integer", "twelve"),
		"text number": stored("string", "7"),
		"json number": stored("json", "7"),
		"padded":      stored("integer", " 7"),
	}
	truthy := map[string]bool{"on": true, "yes": true, "off": false, "zero": false, "blank": false, "null": false, "missing": false,
		"text false": true, "json false": false, "json list": true}
	for key, want := range truthy {
		if got := values.truthy(key); got != want {
			t.Errorf("truthy %s = %v", key, got)
		}
	}
	present := map[string]bool{"spaces": false, "missing": false, "null": false, "number": true, "text false": true}
	for key, want := range present {
		if got := values.present(key, ""); got != want {
			t.Errorf("present %s = %v", key, got)
		}
	}
	if !values.present("missing", "https://www.gutenberg.org") {
		t.Error("a missing setting with a default is present")
	}
	for key, want := range map[string]int64{"number": 12, "negative": -3, "text number": 7, "missing": 10, "null": 10} {
		if got, err := values.integer(key, 10); err != nil || got != want {
			t.Errorf("integer %s = %d %v", key, got, err)
		}
	}
	for _, key := range []string{"words", "json number", "padded"} {
		if _, err := values.integer(key, 10); !errors.Is(err, ErrStoredValue) {
			t.Errorf("integer %s accepted", key)
		}
	}
}

func TestOtherSourcesFollowTheirConfiguredChecks(t *testing.T) {
	for name, test := range map[string]struct {
		values settings
		want   error
	}{
		"nothing":                 {settings{}, nil},
		"prowlarr key only":       {settings{"prowlarr_api_key": stored("string", "k")}, nil},
		"prowlarr":                {settings{"prowlarr_url": stored("string", "http://p"), "prowlarr_api_key": stored("string", "k")}, ErrOtherSources},
		"prowlarr with none":      {settings{"indexer_provider": stored("string", " none "), "prowlarr_url": stored("string", "http://p"), "prowlarr_api_key": stored("string", "k")}, nil},
		"jackett selected":        {settings{"indexer_provider": stored("string", "jackett"), "jackett_url": stored("string", "http://j"), "jackett_api_key": stored("string", "k")}, ErrOtherSources},
		"jackett unconfigured":    {settings{"indexer_provider": stored("string", "jackett"), "prowlarr_url": stored("string", "http://p"), "prowlarr_api_key": stored("string", "k")}, nil},
		"anna":                    {settings{"anna_archive_enabled": stored("boolean", "t"), "anna_archive_api_key": stored("string", "k")}, ErrOtherSources},
		"anna disabled":           {settings{"anna_archive_enabled": stored("boolean", "f"), "anna_archive_api_key": stored("string", "k")}, nil},
		"zlibrary without login":  {settings{"zlibrary_enabled": stored("boolean", "1"), "zlibrary_url": stored("string", "http://z")}, nil},
		"zlibrary saved session":  {settings{"zlibrary_enabled": stored("boolean", "1"), "zlibrary_url": stored("string", "http://z"), "zlibrary_remix_userid": stored("string", "1"), "zlibrary_remix_userkey": stored("string", "k")}, ErrOtherSources},
		"ebooks.com":              {settings{"ebooks_com_enabled": stored("boolean", "true"), "ebooks_com_country_code": stored("string", " gb ")}, ErrOtherSources},
		"ebooks.com without code": {settings{"ebooks_com_enabled": stored("boolean", "true")}, nil},
		"auto select":             {settings{"auto_select_enabled": stored("boolean", "true")}, ErrAutoSelect},
		"webhook":                 {settings{"webhook_enabled": stored("boolean", "true"), "webhook_url": stored("string", "http://hook")}, ErrOutbound},
		"telegram token only":     {settings{"telegram_bot_token": stored("string", "t")}, nil},
		"telegram":                {settings{"telegram_enabled": stored("boolean", "true"), "telegram_bot_token": stored("string", "t")}, ErrOutbound},
	} {
		if got := otherSource(test.values); !errors.Is(got, test.want) || (got == nil) != (test.want == nil) {
			t.Errorf("%s: %v, want %v", name, got, test.want)
		}
	}
}

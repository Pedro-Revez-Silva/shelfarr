package gohttp

import (
	"errors"
	"math"
	"net/http"
	"regexp"
	"strconv"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/live"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/openlibrary"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/strictjson"
)

const (
	maxSettingsBody          = 1024
	discoverSettingsUnusable = "settings_unreadable"
	messageTrueOrFalse       = "must be true or false"
)

var (
	settingsRevision    = regexp.MustCompile(`^[0-9a-f]{32}$`)
	settingsBodyMembers = map[string]bool{"revision": true, "open_library": true}
	openLibraryMembers  = map[string]bool{"enabled": true, "search_limit": true}
	messageSearchLimit  = "must be a whole number from " + strconv.Itoa(live.MinSavedSearchLimit) + " to " + strconv.Itoa(live.MaxSavedSearchLimit)
)

type openLibraryValues struct {
	Enabled     *bool  `json:"enabled"`
	SearchLimit *int64 `json:"search_limit"`
}

type limitRange struct {
	Min int `json:"min"`
	Max int `json:"max"`
}

type discoverReach struct {
	Search      string `json:"search"`
	ResultLimit *int   `json:"result_limit"`
	MaxResults  int    `json:"max_results"`
	RetryAfter  *int   `json:"retry_after,omitempty"`
}

type metadataSettingsBody struct {
	Account     string            `json:"account"`
	Error       string            `json:"error,omitempty"`
	Revision    string            `json:"revision"`
	OpenLibrary openLibraryValues `json:"open_library"`
	Defaults    openLibraryValues `json:"defaults"`
	SearchRange limitRange        `json:"search_limit_range"`
	Discover    discoverReach     `json:"discover"`
}

type settingsRefusal struct {
	Account string              `json:"account"`
	Error   string              `json:"error"`
	Errors  map[string][]string `json:"errors"`
}

func (a *App) webMetadataSettings(w http.ResponseWriter, r *http.Request, session browserSession, result *outcome) {
	if !session.user.Admin {
		problem(w, result, http.StatusNotFound, "not_found")
		return
	}
	if r.Method == http.MethodPut {
		a.saveMetadataSettings(w, r, session, result)
		return
	}
	settings, err := a.db.ReadMetadataSettings(r.Context(), a.now(), a.adminIn(session))
	if err != nil {
		adminFailure(w, result, err)
		return
	}
	result.set(http.StatusOK, "")
	writeJSON(w, http.StatusOK, a.settingsBody(session, settings))
}

func (a *App) saveMetadataSettings(w http.ResponseWriter, r *http.Request, session browserSession, result *outcome) {
	body, failure := a.readLimitedBody(w, r, maxSettingsBody)
	if failure != nil {
		a.writeBodyFailure(w, result, failure)
		return
	}
	revision, change, invalid, ok := parseMetadataChange(body)
	if !ok {
		problem(w, result, http.StatusBadRequest, "invalid_request")
		return
	}
	if len(invalid) > 0 {
		result.set(http.StatusUnprocessableEntity, "invalid_settings")
		writeJSON(w, http.StatusUnprocessableEntity, settingsRefusal{Account: session.account(), Error: "invalid_settings", Errors: invalid})
		return
	}
	settings, err := a.db.SaveMetadataSettings(r.Context(), a.now, revision, change, a.adminIn(session))
	if errors.Is(err, live.ErrSettingsChanged) {
		answer := a.settingsBody(session, settings)
		answer.Error = "settings_conflict"
		result.set(http.StatusConflict, "settings_conflict")
		writeJSON(w, http.StatusConflict, answer)
		return
	}
	if err != nil {
		adminFailure(w, result, err)
		return
	}
	a.security("settings.metadata_saved", session.user.ID)
	result.set(http.StatusOK, "")
	writeJSON(w, http.StatusOK, a.settingsBody(session, settings))
}

func parseMetadataChange(body []byte) (string, live.MetadataChange, map[string][]string, bool) {
	var change live.MetadataChange
	parsed, err := strictjson.Parse(body)
	if err != nil || parsed.Kind != strictjson.Object || !onlyMembers(parsed, settingsBodyMembers) {
		return "", change, nil, false
	}
	revision, present := parsed.Member("revision")
	values, hasValues := parsed.Member("open_library")
	if !present || revision.Kind != strictjson.String || !settingsRevision.MatchString(revision.Text) ||
		!hasValues || values.Kind != strictjson.Object || len(values.Keys) == 0 || !onlyMembers(values, openLibraryMembers) {
		return "", change, nil, false
	}
	invalid := map[string][]string{}
	if enabled, present := values.Member("enabled"); present {
		if enabled.Kind == strictjson.Bool {
			change.Enabled = &enabled.Flag
		} else {
			invalid["enabled"] = []string{messageTrueOrFalse}
		}
	}
	if limit, present := values.Member("search_limit"); present {
		number, err := strconv.ParseInt(limit.Text, 10, 64)
		if limit.Kind == strictjson.Integer && err == nil && number >= live.MinSavedSearchLimit && number <= live.MaxSavedSearchLimit {
			change.SearchLimit = &number
		} else {
			invalid["search_limit"] = []string{messageSearchLimit}
		}
	}
	return revision.Text, change, invalid, true
}

func onlyMembers(value strictjson.Value, allowed map[string]bool) bool {
	for _, key := range value.Keys {
		if !allowed[key] {
			return false
		}
	}
	return true
}

func (a *App) settingsBody(session browserSession, settings live.MetadataSettings) metadataSettingsBody {
	enabled, limit := live.DefaultOpenLibraryEnabled, int64(live.DefaultOpenLibrarySearchLimit)
	return metadataSettingsBody{
		Account:     session.account(),
		Revision:    settings.Revision,
		OpenLibrary: openLibraryValues{Enabled: settings.Enabled, SearchLimit: settings.SearchLimit},
		Defaults:    openLibraryValues{Enabled: &enabled, SearchLimit: &limit},
		SearchRange: limitRange{Min: live.MinSavedSearchLimit, Max: live.MaxSavedSearchLimit},
		Discover:    a.discoverReach(settings),
	}
}

func (a *App) discoverReach(settings live.MetadataSettings) discoverReach {
	reach := discoverReach{MaxResults: openlibrary.MaxResults}
	switch {
	case a.openLibrary == nil:
		reach.Search = discoverServerOff
	case settings.DiscoverErr != nil:
		reach.Search = discoverSettingsUnusable
	default:
		reach.Search = string(settings.Discover.State)
		pausedUntil := settings.Discover.PausedUntil
		if upstream := a.openLibrary.PausedUntil(); settings.Discover.State == live.OpenLibraryAvailable && upstream.After(a.now()) {
			reach.Search, pausedUntil = string(live.OpenLibraryPaused), upstream
		}
		if reach.Search == string(live.OpenLibraryAvailable) || reach.Search == string(live.OpenLibraryPaused) {
			limit := settings.Discover.Limit
			reach.ResultLimit = &limit
		}
		if !pausedUntil.IsZero() {
			seconds := int(math.Ceil(pausedUntil.Sub(a.now()).Seconds()))
			reach.RetryAfter = &seconds
		}
	}
	return reach
}

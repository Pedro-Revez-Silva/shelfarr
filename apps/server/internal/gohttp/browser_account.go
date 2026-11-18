package gohttp

import (
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/account"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/fault"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/live"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/strictjson"
)

const maxAccountBody = maxLoginBody

type passwordChange struct {
	current      string
	password     string
	confirmation string
}

func profileJSON(profile live.Profile) map[string]string {
	return map[string]string{"id": strconv.FormatInt(profile.ID, 10), "username": profile.Username, "name": profile.Name}
}

func (a *App) respondProfile(w http.ResponseWriter, session browserSession, profile live.Profile, result *outcome) {
	result.set(http.StatusOK, "")
	writeJSON(w, http.StatusOK, map[string]any{"account": session.account(), "profile": profileJSON(profile)})
}

func (a *App) respondInvalid(w http.ResponseWriter, session browserSession, code string, found account.FieldErrors, result *outcome) {
	result.set(http.StatusUnprocessableEntity, code)
	writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"account": session.account(), "error": code, "errors": found})
}

func (a *App) webAccount(w http.ResponseWriter, session browserSession, result *outcome) {
	a.respondProfile(w, session, live.Profile{ID: session.user.ID, Username: session.user.Username, Name: session.user.Name}, result)
}

func stringMembers(body []byte, names ...string) ([]string, bool) {
	parsed, err := strictjson.Parse(body)
	if err != nil || parsed.Kind != strictjson.Object {
		return nil, false
	}
	values := make([]string, len(names))
	for index, name := range names {
		member, present := parsed.Member(name)
		if !present || member.Kind != strictjson.String {
			return nil, false
		}
		values[index] = member.Text
	}
	return values, true
}

func (a *App) accountBody(w http.ResponseWriter, r *http.Request, result *outcome, names ...string) ([]string, bool) {
	body, failure := a.readLimitedBody(w, r, maxAccountBody)
	if failure != nil {
		a.writeBodyFailure(w, result, failure)
		return nil, false
	}
	values, ok := stringMembers(body, names...)
	if !ok {
		problem(w, result, http.StatusBadRequest, "invalid_json")
		return nil, false
	}
	return values, true
}

func (a *App) accountFailure(w http.ResponseWriter, result *outcome, err error) {
	switch {
	case errors.Is(err, live.ErrSessionEnded):
		problem(w, result, http.StatusUnauthorized, "signed_out")
	case errors.Is(err, live.ErrAccountChanged):
		problem(w, result, http.StatusConflict, "account_conflict")
	default:
		mapFailure(w, result, err)
	}
}

func (a *App) webProfile(w http.ResponseWriter, r *http.Request, session browserSession, result *outcome) {
	values, ok := a.accountBody(w, r, result, "name")
	if !ok {
		return
	}
	saved, err := a.db.UpdateName(r.Context(), session.row, values[0], a.now)
	if err != nil {
		a.accountFailure(w, result, err)
		return
	}
	if len(saved.Errors) > 0 {
		a.respondInvalid(w, session, "invalid_profile", saved.Errors, result)
		return
	}
	a.security("profile.updated", session.user.ID)
	a.respondProfile(w, session, saved.Profile, result)
}

func (a *App) webPassword(w http.ResponseWriter, r *http.Request, session browserSession, result *outcome) {
	if allowed, wait := a.limiter.Allow(clientIP(r), a.now()); !allowed {
		a.security("password.rate_limited", session.user.ID)
		w.Header().Set("Retry-After", strconv.Itoa(int(wait/time.Second)+1))
		problem(w, result, http.StatusTooManyRequests, "rate_limited")
		return
	}
	values, ok := a.accountBody(w, r, result, "current_password", "password", "password_confirmation")
	if !ok {
		return
	}
	change := passwordChange{current: values[0], password: values[1], confirmation: values[2]}
	snapshot, err := a.db.PasswordSnapshot(r.Context(), session.user.ID)
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	if snapshot == nil {
		problem(w, result, http.StatusUnauthorized, "signed_out")
		return
	}
	digest, verified := a.checkedDigest(w, r, session, *snapshot, change, result)
	if !verified {
		return
	}
	if err := fault.Hit(r.Context(), "password.checked"); err != nil {
		mapFailure(w, result, err)
		return
	}
	changed, err := a.db.ChangePassword(r.Context(), session.row, *snapshot, digest, a.now)
	if err != nil {
		a.accountFailure(w, result, err)
		return
	}
	if len(changed.Errors) > 0 {
		a.respondInvalid(w, session, "invalid_password", changed.Errors, result)
		return
	}
	a.logger.Info("security", slog.String("event", "password.changed"), slog.Int64("user_id", session.user.ID), slog.Int64("ended_sessions", changed.EndedSessions))
	a.respondProfile(w, session, changed.Profile, result)
}

func (a *App) checkedDigest(w http.ResponseWriter, r *http.Request, session browserSession, snapshot live.PasswordSnapshot, change passwordChange, result *outcome) (string, bool) {
	if !a.limiter.Acquire(r.Context(), a.config.LoginWait) {
		w.Header().Set("Retry-After", "1")
		problem(w, result, http.StatusServiceUnavailable, "server_busy")
		return "", false
	}
	defer a.limiter.Release()
	matches, err := account.PasswordMatches(snapshot.Digest, change.current)
	if err != nil {
		problem(w, result, http.StatusNotImplemented, "unsupported_stored_value")
		return "", false
	}
	if err := r.Context().Err(); err != nil {
		mapFailure(w, result, err)
		return "", false
	}
	if !matches || len(change.current) > maxPassword {
		a.security("password.incorrect", session.user.ID)
		a.respondInvalid(w, session, "invalid_password", account.FieldErrors{"current_password": {account.MessageIncorrect}}, result)
		return "", false
	}
	invalid := account.NewPasswordErrors(change.password, change.confirmation, snapshot.OIDCLinked)
	invalid.Merge(snapshot.RecordErrors)
	if len(invalid) > 0 {
		a.respondInvalid(w, session, "invalid_password", invalid, result)
		return "", false
	}
	digest, err := account.HashPassword(change.password)
	if err != nil {
		problem(w, result, http.StatusInternalServerError, "internal_error")
		return "", false
	}
	if err := r.Context().Err(); err != nil {
		mapFailure(w, result, err)
		return "", false
	}
	return digest, true
}

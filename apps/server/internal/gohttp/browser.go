package gohttp

import (
	"context"
	"encoding/json"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/account"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/csrf"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/fault"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/live"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/strictjson"
)

const (
	signedCookieSalt  = "signed cookie"
	sessionPurpose    = "cookie.session_id"
	sessionCookieName = "session_id"
	nonceCookieName   = "shelfarr_login"
	noncePath         = "/preview/api/v1/auth"
	maxCookieValue    = 1024
	maxLoginBody      = 4096
	maxPassword       = 72
	maxSessionAgeDays = live.MaxSessionAgeDays
	accountHeader     = "X-Shelfarr-Account"
	csrfHeader        = "X-CSRF-Token"
	dummyPasswordHash = "$2a$12$VM0I4YpCNVTn7yfNpwdUQOcI.FRtKt8l2Ml.EkAarbDyC.EUWmAWa"
)

var sessionIDPattern = regexp.MustCompile(`^[1-9][0-9]{0,18}$`)

type browserSession struct {
	row     live.SessionRow
	user    live.BrowserUser
	expires time.Time
}

func (s browserSession) account() string { return strconv.FormatInt(s.user.ID, 10) }

func (a *App) previewConfigured() bool { return len(a.previewIDs) > 0 }

func (a *App) previewAllows(userID int64) bool { return a.previewIDs[strconv.FormatInt(userID, 10)] }

func (a *App) secureCookies() bool { return strings.HasPrefix(a.config.BrowserOrigin, "https://") }

func firstCookie(r *http.Request, name string) (string, bool) {
	for _, cookie := range r.Cookies() {
		if cookie.Name == name {
			return cookie.Value, true
		}
	}
	return "", false
}

func decodeSessionID(raw []byte) (int64, bool) {
	text := strings.TrimSpace(string(raw))
	if strings.HasPrefix(text, `"`) {
		var quoted string
		if json.Unmarshal(raw, &quoted) != nil {
			return 0, false
		}
		text = quoted
	}
	if !sessionIDPattern.MatchString(text) {
		return 0, false
	}
	id, err := strconv.ParseInt(text, 10, 64)
	return id, err == nil
}

func (a *App) clearSession(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{Name: sessionCookieName, Value: "", Path: "/", MaxAge: -1, Expires: time.Unix(0, 0), HttpOnly: true, SameSite: http.SameSiteLaxMode, Secure: a.secureCookies()})
}

func (a *App) clearNonce(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{Name: nonceCookieName, Value: "", Path: noncePath, MaxAge: -1, HttpOnly: true, SameSite: http.SameSiteStrictMode, Secure: a.secureCookies()})
}

func (a *App) setNonce(w http.ResponseWriter, nonce string) {
	http.SetCookie(w, &http.Cookie{Name: nonceCookieName, Value: nonce, Path: noncePath, MaxAge: int(csrf.LoginTTL / time.Second), HttpOnly: true, SameSite: http.SameSiteStrictMode, Secure: a.secureCookies()})
}

func (a *App) resume(ctx context.Context, w http.ResponseWriter, r *http.Request) (*browserSession, error) {
	value, present := firstCookie(r, sessionCookieName)
	if !present || len(value) > maxCookieValue {
		return nil, nil
	}
	token, err := url.QueryUnescape(value)
	if err != nil {
		return nil, nil
	}
	payload, cookieExpires, ok := a.cookies.VerifiedMessageUntil(token, sessionPurpose, a.now())
	if !ok {
		return nil, nil
	}
	id, ok := decodeSessionID(payload)
	if !ok {
		return nil, nil
	}
	row, err := a.db.SessionByID(ctx, id)
	if err != nil || row == nil {
		return nil, err
	}
	days, err := a.db.IntegerSetting(ctx, "session_max_age_days", 30)
	if err != nil {
		return nil, err
	}
	if days < 0 || days > maxSessionAgeDays {
		return nil, store.ErrUnsupported
	}
	if row.CreatedAt.Before(a.now().Add(-time.Duration(days) * 24 * time.Hour)) {
		a.db.DeleteSession(ctx, row.ID, row.UserID)
		a.clearSession(w)
		return nil, nil
	}
	user, err := a.db.BrowserUserByID(ctx, row.UserID)
	if err != nil || user == nil {
		return nil, err
	}
	if user.Deleted {
		a.db.DeleteSession(ctx, row.ID, row.UserID)
		a.clearSession(w)
		return nil, nil
	}
	expires := row.CreatedAt.Add(time.Duration(days) * 24 * time.Hour)
	if !cookieExpires.IsZero() && cookieExpires.Before(expires) {
		expires = cookieExpires
	}
	return &browserSession{row: *row, user: *user, expires: expires}, nil
}

func (a *App) security(event string, userID int64) {
	attributes := []any{slog.String("event", event)}
	if userID != 0 {
		attributes = append(attributes, slog.Int64("user_id", userID))
	}
	a.logger.Info("security", attributes...)
}

func (a *App) guard(w http.ResponseWriter, r *http.Request, result *outcome, accountBound bool) (*browserSession, bool) {
	w.Header().Set("Cache-Control", "private, no-store")
	if !a.previewConfigured() {
		problem(w, result, http.StatusNotFound, "not_found")
		return nil, false
	}
	session, err := a.resume(r.Context(), w, r)
	if err != nil {
		mapFailure(w, result, err)
		return nil, false
	}
	if session == nil {
		problem(w, result, http.StatusUnauthorized, "signed_out")
		return nil, false
	}
	if !a.previewAllows(session.user.ID) {
		problem(w, result, http.StatusNotFound, "not_found")
		return nil, false
	}
	if accountBound {
		values := r.Header.Values(accountHeader)
		if len(values) != 1 || values[0] != session.account() {
			problem(w, result, http.StatusUnauthorized, "account_changed")
			return nil, false
		}
	}
	return session, true
}

func (a *App) sameOrigin(w http.ResponseWriter, r *http.Request, result *outcome) bool {
	if a.config.BrowserOrigin == "" {
		problem(w, result, http.StatusNotImplemented, "browser_origin_not_configured")
		return false
	}
	origins := r.Header.Values("Origin")
	sites := r.Header.Values("Sec-Fetch-Site")
	if len(origins) != 1 || origins[0] != a.config.BrowserOrigin || len(sites) > 0 && (len(sites) != 1 || sites[0] != "same-origin") {
		a.security("csrf.origin_refused", 0)
		problem(w, result, http.StatusUnprocessableEntity, "invalid_csrf")
		return false
	}
	return true
}

func (a *App) sessionToken(session browserSession) (string, time.Time) {
	return a.tokens.ForSession(session.row.ID, session.user.ID, session.row.CreatedAt, a.now())
}

func (a *App) mutationAllowed(w http.ResponseWriter, r *http.Request, session browserSession, result *outcome) bool {
	if !a.sameOrigin(w, r, result) {
		return false
	}
	values := r.Header.Values(csrfHeader)
	if len(values) != 1 || !a.tokens.VerifySession(values[0], session.row.ID, session.user.ID, session.row.CreatedAt, a.now()) {
		a.security("csrf.token_refused", session.user.ID)
		problem(w, result, http.StatusUnprocessableEntity, "invalid_csrf")
		return false
	}
	return true
}

func hostName(r *http.Request, fallback string) string {
	host := r.Host
	if name, _, err := net.SplitHostPort(host); err == nil {
		host = name
	}
	host = strings.Trim(host, "[]")
	if host == "" || len(host) > 253 || strings.ContainsAny(host, " /\\@?#\"'<>") {
		return fallback
	}
	return strings.ToLower(host)
}

func (a *App) bootstrap(w http.ResponseWriter, r *http.Request, result *outcome) {
	w.Header().Set("Cache-Control", "private, no-store")
	if !a.previewConfigured() {
		problem(w, result, http.StatusNotFound, "not_found")
		return
	}
	session, err := a.resume(r.Context(), w, r)
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	now := a.now()
	if session != nil {
		if !a.previewAllows(session.user.ID) {
			problem(w, result, http.StatusNotFound, "not_found")
			return
		}
		token, expires := a.sessionToken(*session)
		answer := map[string]any{"authenticated": true, "account": session.account(), "csrf_token": token, "expires_in": int(expires.Sub(now).Seconds())}
		if a.offlineEnabled() {
			answer["offline_expires_in"] = offlineWindow(session.expires, now)
		}
		result.set(http.StatusOK, "")
		writeJSON(w, http.StatusOK, answer)
		return
	}
	reason, err := a.signInRefusal(r.Context())
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	nonce, present := firstCookie(r, nonceCookieName)
	if !present || !csrf.ValidNonce(nonce) {
		if nonce, err = csrf.NewNonce(); err != nil {
			problem(w, result, http.StatusInternalServerError, "internal_error")
			return
		}
	}
	a.setNonce(w, nonce)
	token, expires := a.tokens.ForLogin(nonce, now)
	signIn := map[string]any{"available": reason == "", "reason": nil}
	if reason != "" {
		signIn["reason"] = reason
	}
	result.set(http.StatusOK, "")
	writeJSON(w, http.StatusOK, map[string]any{"authenticated": false, "csrf_token": token, "expires_in": int(expires.Sub(now).Seconds()), "sign_in": signIn})
}

func (a *App) signInRefusal(ctx context.Context) (string, error) {
	if a.config.BrowserOrigin == "" {
		return "browser_origin_not_configured", nil
	}
	if a.config.PasswordlessEnv {
		return "auth_disabled", nil
	}
	disabled, err := a.db.BooleanSetting(ctx, "auth_disabled", false)
	if err != nil {
		return "", err
	}
	if disabled {
		return "auth_disabled", nil
	}
	return "", nil
}

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

type credentialsBody struct {
	username string
	password string
}

func parseCredentials(body []byte) (credentialsBody, bool) {
	parsed, err := strictjson.Parse(body)
	if err != nil || parsed.Kind != strictjson.Object {
		return credentialsBody{}, false
	}
	username, userOK := parsed.Member("username")
	password, passOK := parsed.Member("password")
	if !userOK || !passOK || username.Kind != strictjson.String || password.Kind != strictjson.String {
		return credentialsBody{}, false
	}
	return credentialsBody{username: username.Text, password: password.Text}, true
}

func normalisedUsername(value string) (string, bool) {
	name := strings.ToLower(strings.Trim(value, " \t\n\v\f\r\x00"))
	if name == "" || len(name) > maxLoginBody {
		return name, false
	}
	for index := 0; index < len(name); index++ {
		character := name[index]
		if !(character >= 'a' && character <= 'z' || character >= '0' && character <= '9' || character == '_') {
			return name, false
		}
	}
	return name, true
}

func (a *App) loginRefused(w http.ResponseWriter, result *outcome, status int, code, reason string) {
	result.set(status, code)
	body := map[string]string{"error": code}
	if reason != "" {
		body["reason"] = reason
	}
	writeJSON(w, status, body)
}

func (a *App) login(w http.ResponseWriter, r *http.Request, result *outcome) {
	w.Header().Set("Cache-Control", "private, no-store")
	if !a.previewConfigured() {
		problem(w, result, http.StatusNotFound, "not_found")
		return
	}
	if !a.sameOrigin(w, r, result) {
		return
	}
	nonce, _ := firstCookie(r, nonceCookieName)
	tokens := r.Header.Values(csrfHeader)
	if len(tokens) != 1 || !a.tokens.VerifyLogin(tokens[0], nonce, a.now()) {
		a.security("csrf.token_refused", 0)
		problem(w, result, http.StatusUnprocessableEntity, "invalid_csrf")
		return
	}
	existing, err := a.resume(r.Context(), w, r)
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	if existing != nil {
		problem(w, result, http.StatusConflict, "already_signed_in")
		return
	}
	reason, err := a.signInRefusal(r.Context())
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	if reason != "" {
		a.loginRefused(w, result, http.StatusNotImplemented, "sign_in_unsupported", reason)
		return
	}
	if allowed, wait := a.limiter.Allow(clientIP(r), a.now()); !allowed {
		a.security("login.rate_limited", 0)
		w.Header().Set("Retry-After", strconv.Itoa(int(wait/time.Second)+1))
		problem(w, result, http.StatusTooManyRequests, "rate_limited")
		return
	}
	body, failure := a.readLimitedBody(w, r, maxLoginBody)
	if failure != nil {
		a.writeBodyFailure(w, result, failure)
		return
	}
	submitted, ok := parseCredentials(body)
	if !ok {
		problem(w, result, http.StatusBadRequest, "invalid_json")
		return
	}
	a.authenticate(w, r, submitted, result)
}

func (a *App) authenticate(w http.ResponseWriter, r *http.Request, submitted credentialsBody, result *outcome) {
	username, valid := normalisedUsername(submitted.username)
	var credentials *live.Credentials
	if valid {
		var err error
		if credentials, err = a.db.ActiveCredentials(r.Context(), username); err != nil {
			mapFailure(w, result, err)
			return
		}
	}
	known := credentials != nil && a.previewAllows(credentials.ID)
	digest := dummyPasswordHash
	if known {
		digest = credentials.PasswordDigest
	}
	if !a.limiter.Acquire(r.Context(), a.config.LoginWait) {
		w.Header().Set("Retry-After", "1")
		problem(w, result, http.StatusServiceUnavailable, "server_busy")
		return
	}
	matches, err := account.PasswordMatches(digest, submitted.password)
	a.limiter.Release()
	if err != nil {
		problem(w, result, http.StatusNotImplemented, "unsupported_stored_value")
		return
	}
	if err := r.Context().Err(); err != nil {
		mapFailure(w, result, err)
		return
	}
	if !known || len(submitted.password) > maxPassword {
		a.security("login.unknown_user", 0)
		a.invalidCredentials(w, result)
		return
	}
	if !matches {
		a.failedLogin(w, r, credentials.ID, result)
		return
	}
	a.complete(w, r, *credentials, result)
}

func (a *App) invalidCredentials(w http.ResponseWriter, result *outcome) {
	problem(w, result, http.StatusUnauthorized, "invalid_credentials")
}

func (a *App) failedLogin(w http.ResponseWriter, r *http.Request, userID int64, result *outcome) {
	threshold, err := a.db.IntegerSetting(r.Context(), "login_lockout_threshold", 5)
	if err == nil {
		var minutes int
		if minutes, err = a.db.IntegerSetting(r.Context(), "login_lockout_duration_minutes", 15); err == nil {
			if threshold < 1 || minutes < 0 || minutes > maxSessionAgeDays*24*60 {
				err = store.ErrUnsupported
			} else {
				err = a.db.RecordFailedLogin(r.Context(), userID, clientIP(r), threshold, time.Duration(minutes)*time.Minute, a.now)
			}
		}
	}
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	a.security("login.failed", userID)
	a.invalidCredentials(w, result)
}

func (a *App) complete(w http.ResponseWriter, r *http.Request, credentials live.Credentials, result *outcome) {
	if err := fault.Hit(r.Context(), "login.checked"); err != nil {
		mapFailure(w, result, err)
		return
	}
	created, err := a.db.CompleteLogin(r.Context(), credentials.ID, credentials.PasswordDigest, live.Client{UserAgent: r.UserAgent(), IP: clientIP(r)}, a.config.PasswordlessEnv, a.now)
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	switch created.Outcome {
	case live.LoginRefused:
		a.security("login.refused", credentials.ID)
		a.invalidCredentials(w, result)
		return
	case live.LoginPasswordless:
		a.security("login.passwordless_unsupported", credentials.ID)
		a.loginRefused(w, result, http.StatusNotImplemented, "sign_in_unsupported", "auth_disabled")
		return
	case live.LoginNeedsSecondFactor:
		a.security("login.second_factor_unsupported", credentials.ID)
		a.loginRefused(w, result, http.StatusNotImplemented, "mfa_not_supported", "")
		return
	case live.LoginNeedsOIDC:
		a.security("login.oidc_account_unsupported", credentials.ID)
		a.loginRefused(w, result, http.StatusNotImplemented, "oidc_account_not_supported", "")
		return
	}
	expires := created.ExpiresAt
	cookie, err := a.cookies.GenerateMessage(json.RawMessage(strconv.FormatInt(created.Session.ID, 10)), sessionPurpose, expires)
	if err != nil {
		problem(w, result, http.StatusInternalServerError, "internal_error")
		return
	}
	http.SetCookie(w, &http.Cookie{Name: sessionCookieName, Value: url.QueryEscape(cookie), Path: "/", Expires: expires.Truncate(time.Second), HttpOnly: true, SameSite: http.SameSiteLaxMode, Secure: a.secureCookies()})
	a.clearNonce(w)
	user := browserSession{row: created.Session, user: live.BrowserUser{ID: credentials.ID}}
	token, until := a.sessionToken(user)
	a.security("login.success", credentials.ID)
	answer := map[string]any{"authenticated": true, "account": user.account(), "csrf_token": token, "expires_in": int(until.Sub(a.now()).Seconds())}
	if a.offlineEnabled() {
		answer["offline_expires_in"] = offlineWindow(expires, a.now())
	}
	result.set(http.StatusOK, "")
	writeJSON(w, http.StatusOK, answer)
}

func (a *App) logout(w http.ResponseWriter, r *http.Request, result *outcome) {
	session, ok := a.guard(w, r, result, true)
	if !ok || !a.mutationAllowed(w, r, *session, result) {
		return
	}
	if err := a.db.DeleteSession(r.Context(), session.row.ID, session.user.ID); err != nil {
		mapFailure(w, result, err)
		return
	}
	a.clearSession(w)
	a.security("logout", session.user.ID)
	result.set(http.StatusOK, "")
	writeJSON(w, http.StatusOK, map[string]any{"authenticated": false})
}

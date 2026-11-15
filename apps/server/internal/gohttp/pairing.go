package gohttp

import (
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/account"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/checkpoint"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/devicegrant"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/fault"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/live"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/loginlimit"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/strictjson"
)

const (
	deviceAttempts  = 20
	deviceWindow    = 3 * time.Minute
	tokenAttempts   = 120
	tokenWindow     = time.Minute
	maxConsentBody  = 4096
	verificationURI = "/consumer/connect"
)

func newGrantSource() live.GrantSource {
	source := devicegrant.RandomSource()
	return live.GrantSource{
		Codes:         func() (devicegrant.Codes, error) { return devicegrant.NewCodes(source) },
		AccessToken:   func() (string, error) { return devicegrant.NewAccessToken(source) },
		ConnectionKey: func() (string, error) { return devicegrant.NewConnectionKey(source) },
	}
}

func pairingHeaders(w http.ResponseWriter) {
	header := w.Header()
	header.Set("Cache-Control", "private, no-store")
	header.Set("Referrer-Policy", "no-referrer")
}

func (a *App) throttled(w http.ResponseWriter, r *http.Request, result *outcome, limiter *loginlimit.Limiter) bool {
	allowed, wait := limiter.Allow(clientIP(r), a.now())
	if allowed {
		return false
	}
	w.Header().Set("Retry-After", strconv.Itoa(int(wait/time.Second)+1))
	result.set(http.StatusTooManyRequests, "slow_down")
	writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": "slow_down"})
	return true
}

func (a *App) readObject(w http.ResponseWriter, r *http.Request, result *outcome, limit int64) (strictjson.Value, bool) {
	body, failure := a.readLimitedBody(w, r, limit)
	if failure != nil {
		a.writeBodyFailure(w, result, failure)
		return strictjson.Value{}, false
	}
	if len(body) == 0 {
		return strictjson.Value{Kind: strictjson.Object}, true
	}
	parsed, err := strictjson.Parse(body)
	if err != nil {
		problem(w, result, http.StatusBadRequest, "invalid_json")
		return strictjson.Value{}, false
	}
	if parsed.Kind != strictjson.Object {
		return strictjson.Value{Kind: strictjson.Object}, true
	}
	return parsed, true
}

func (a *App) entropyFailed(w http.ResponseWriter, result *outcome, err error) bool {
	if !errors.Is(err, devicegrant.ErrRandom) && !errors.Is(err, live.ErrCodeCollision) {
		return false
	}
	a.security("pairing.entropy_failed", 0)
	problem(w, result, http.StatusInternalServerError, "internal_error")
	return true
}

func blankText(text string) bool {
	return strings.IndexFunc(text, func(r rune) bool { return !unicode.IsSpace(r) }) < 0
}

func (a *App) device(w http.ResponseWriter, r *http.Request, result *outcome) {
	pairingHeaders(w)
	if a.throttled(w, r, result, a.deviceLimiter) {
		return
	}
	if a.config.BrowserOrigin == "" {
		problem(w, result, http.StatusNotImplemented, "browser_origin_not_configured")
		return
	}
	object, ok := a.readObject(w, r, result, checkpoint.MaxBodyBytes)
	if !ok {
		return
	}
	name := ""
	if value, present := object.Member("client_name"); present && value.Kind == strictjson.String {
		name, ok = devicegrant.ClientName(value.Text)
	} else {
		ok = false
	}
	if !ok {
		problem(w, result, http.StatusBadRequest, "invalid_request")
		return
	}
	var upgrade *live.Upgrade
	if authorization := strings.Join(r.Header.Values("Authorization"), ", "); !blankText(authorization) {
		principal, err := a.auth.Authenticate(r.Context(), authorization)
		if err != nil {
			mapFailure(w, result, err)
			return
		}
		if principal == nil || !principal.HasScope("library:read") {
			a.unauthorized(w, result)
			return
		}
		upgrade = &live.Upgrade{TokenID: principal.TokenID, UserID: principal.UserID}
		if err := fault.Hit(r.Context(), "device.authenticated"); err != nil {
			mapFailure(w, result, err)
			return
		}
	}
	requested, present := object.Member("scope")
	scopes, err := devicegrant.RequestedScopes(present, requested)
	if err != nil {
		problem(w, result, http.StatusBadRequest, "invalid_scope")
		return
	}
	created, err := a.db.CreateGrant(r.Context(), live.GrantRequest{ClientName: name, Scopes: scopes, Upgrade: upgrade}, a.grants, a.now)
	switch {
	case errors.Is(err, live.ErrStaleCredential):
		a.unauthorized(w, result)
		return
	case a.entropyFailed(w, result, err):
		return
	case err != nil:
		mapFailure(w, result, err)
		return
	}
	display := created.Codes.Display()
	result.set(http.StatusOK, "")
	writeJSON(w, http.StatusOK, deviceResponse{
		DeviceCode: created.Codes.Device, UserCode: display,
		VerificationURI: a.config.BrowserOrigin + verificationURI, VerificationURIComplete: a.config.BrowserOrigin + verificationURI + "?user_code=" + display,
		ExpiresIn: devicegrant.LifetimeSeconds, Interval: created.Interval,
	})
}

type deviceResponse struct {
	DeviceCode              string `json:"device_code"`
	UserCode                string `json:"user_code"`
	VerificationURI         string `json:"verification_uri"`
	VerificationURIComplete string `json:"verification_uri_complete"`
	ExpiresIn               int    `json:"expires_in"`
	Interval                int    `json:"interval"`
}

func (a *App) unauthorized(w http.ResponseWriter, result *outcome) {
	result.set(http.StatusUnauthorized, "unauthorized")
	writeEmpty(w, http.StatusUnauthorized)
}

var exchangeErrors = map[live.ExchangeOutcome]string{
	live.ExchangeExpired:  "expired_token",
	live.ExchangeDenied:   "access_denied",
	live.ExchangeSlowDown: "slow_down",
	live.ExchangePending:  "authorization_pending",
}

func validDeviceCode(text string) bool {
	if len(text) != 64 {
		return false
	}
	for index := 0; index < len(text); index++ {
		character := text[index]
		if !(character >= '0' && character <= '9' || character >= 'a' && character <= 'f') {
			return false
		}
	}
	return true
}

func (a *App) exchange(w http.ResponseWriter, r *http.Request, result *outcome) {
	pairingHeaders(w)
	if a.throttled(w, r, result, a.tokenLimiter) {
		return
	}
	object, ok := a.readObject(w, r, result, checkpoint.MaxBodyBytes)
	if !ok {
		return
	}
	code := ""
	if value, present := object.Member("device_code"); present && value.Kind == strictjson.String {
		code = value.Text
	}
	if !validDeviceCode(code) {
		a.exchangeRefused(w, result, "expired_token")
		return
	}
	exchanged, err := a.db.ExchangeGrant(r.Context(), devicegrant.Digest(code), a.grants, a.now)
	switch {
	case a.entropyFailed(w, result, err):
		return
	case err != nil:
		mapFailure(w, result, err)
		return
	}
	if exchanged.Outcome != live.ExchangeIssued {
		a.exchangeRefused(w, result, exchangeErrors[exchanged.Outcome])
		return
	}
	result.set(http.StatusOK, "")
	writeJSON(w, http.StatusOK, tokenResponse{AccessToken: exchanged.AccessToken, TokenType: "Bearer", Scope: strings.Join(exchanged.Scopes, " "), ExpiresIn: devicegrant.TokenLifetimeSecs})
}

type tokenResponse struct {
	AccessToken string `json:"access_token"`
	TokenType   string `json:"token_type"`
	Scope       string `json:"scope"`
	ExpiresIn   int    `json:"expires_in"`
}

func (a *App) exchangeRefused(w http.ResponseWriter, result *outcome, code string) {
	problem(w, result, http.StatusBadRequest, code)
}

func (a *App) revoke(w http.ResponseWriter, r *http.Request, principal *account.Principal, result *outcome) {
	revoked, err := a.db.RevokeConnection(r.Context(), principal.TokenID, a.now)
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	if !revoked {
		a.unauthorized(w, result)
		return
	}
	a.security("connection.revoked", principal.UserID)
	result.set(http.StatusNoContent, "")
	w.WriteHeader(http.StatusNoContent)
}

func (a *App) connectCode(raw string) (string, bool) {
	if blankText(raw) {
		return "", false
	}
	normalized, ok := devicegrant.NormalizeUserCode(devicegrant.FirstCharacters(raw, devicegrant.MaxUserCodeChars))
	if !ok {
		return "", false
	}
	return devicegrant.Digest(normalized), true
}

type connectGrant struct {
	Pending    bool     `json:"pending"`
	Decidable  bool     `json:"decidable"`
	ClientName string   `json:"client_name,omitempty"`
	Upgrade    *bool    `json:"upgrade,omitempty"`
	Requesting *bool    `json:"requesting,omitempty"`
	Scopes     []string `json:"scopes,omitempty"`
	ExpiresAt  string   `json:"expires_at,omitempty"`
}

func (a *App) connectInspect(w http.ResponseWriter, r *http.Request, session browserSession, result *outcome) {
	w.Header().Set("Referrer-Policy", "no-referrer")
	var grant *connectGrant
	values := r.URL.Query()["user_code"]
	if len(values) > 0 {
		if digest, ok := a.connectCode(values[len(values)-1]); ok {
			view, err := a.db.InspectGrant(r.Context(), digest, session.user.ID, a.now())
			if err != nil {
				mapFailure(w, result, err)
				return
			}
			grant = describeGrant(view)
		}
	}
	result.set(http.StatusOK, "")
	writeJSON(w, http.StatusOK, map[string]any{"account": session.account(), "account_name": session.user.Name, "grant": grant})
}

func describeGrant(view live.GrantView) *connectGrant {
	if !view.Found || !view.Pending {
		return nil
	}
	if !view.Decidable {
		return &connectGrant{Pending: true}
	}
	upgrade, requesting := view.Upgrade, view.Requesting
	return &connectGrant{Pending: true, Decidable: true, ClientName: view.ClientName, Upgrade: &upgrade, Requesting: &requesting, Scopes: view.Scopes, ExpiresAt: store.FormatISO8601Millis(view.ExpiresAt)}
}

func (a *App) connectDecide(w http.ResponseWriter, r *http.Request, session browserSession, result *outcome) {
	w.Header().Set("Referrer-Policy", "no-referrer")
	object, ok := a.readObject(w, r, result, maxConsentBody)
	if !ok {
		return
	}
	decision, _ := object.Member("decision")
	if decision.Kind != strictjson.String || decision.Text != "allow" && decision.Text != "deny" {
		problem(w, result, http.StatusBadRequest, "invalid_request")
		return
	}
	digest, valid := "", false
	if value, present := object.Member("user_code"); present && value.Kind == strictjson.String {
		digest, valid = a.connectCode(value.Text)
	}
	if !valid {
		problem(w, result, http.StatusUnprocessableEntity, "invalid_grant")
		return
	}
	allow := decision.Text == "allow"
	decided, err := a.db.DecideGrant(r.Context(), digest, session.user.ID, allow, a.now)
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	switch decided.Outcome {
	case live.DecideWrongAccount:
		a.security("grant.wrong_account", session.user.ID)
		problem(w, result, http.StatusForbidden, "different_account")
	case live.DecideNotPending:
		problem(w, result, http.StatusUnprocessableEntity, "invalid_grant")
	default:
		verdict := "denied"
		if allow {
			verdict = "allowed"
		}
		a.security("grant."+verdict, session.user.ID)
		result.set(http.StatusOK, "")
		writeJSON(w, http.StatusOK, map[string]any{"account": session.account(), "decision": verdict, "upgrade": decided.Upgrade, "requesting": decided.Requesting})
	}
}

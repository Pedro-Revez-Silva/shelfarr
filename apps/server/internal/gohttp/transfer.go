package gohttp

import (
	"encoding/json"
	"mime"
	"net/http"
	"strconv"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/account"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/fault"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/transfergrant"
)

type grantBody struct {
	URL       string `json:"url"`
	ExpiresAt string `json:"expires_at"`
}

const grantBodyLimit = 64 << 10

func (a *App) transferGrant(w http.ResponseWriter, r *http.Request, principal *account.Principal, found route, result *outcome) {
	body, failure := a.readBounded(w, r, grantBodyLimit)
	if failure != nil {
		a.writeBodyFailure(w, result, failure)
		return
	}
	if mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type")); err == nil && mediaType == "application/json" && len(body) > 0 && !json.Valid(body) {
		declareVary(w, "Accept", "X-Requested-With")
		problem(w, result, http.StatusBadRequest, "invalid_json")
		return
	}
	book, chosen, ok := a.findAsset(w, r, found, allReadingFormats, result)
	if !ok {
		return
	}
	if err := fault.Hit(r.Context(), "transfer.listed"); err != nil {
		mapFailure(w, result, err)
		return
	}
	file, ok := a.openAsset(w, result, *book, *chosen)
	if !ok {
		return
	}
	file.Close()
	var tokenExpiry *time.Time
	if principal.TokenExpiresAt.Valid {
		parsed, err := store.ParseTimestamp(principal.TokenExpiresAt.String)
		if err != nil {
			mapFailure(w, result, err)
			return
		}
		tokenExpiry = &parsed
	}
	expires := transfergrant.ExpiresAt(a.now(), tokenExpiry)
	grant, err := a.transfers.Issue(transfergrant.Claims{TokenID: principal.TokenID, UserID: principal.UserID, BookID: strconv.FormatInt(book.ID, 10), AssetID: chosen.ID}, expires)
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	result.set(http.StatusCreated, "")
	writeJSON(w, http.StatusCreated, grantBody{
		URL:       apiPrefix + "library/" + strconv.FormatInt(book.ID, 10) + "/assets/" + chosen.ID + "/transfer?grant=" + grant,
		ExpiresAt: expires.UTC().Format("2006-01-02T15:04:05Z"),
	})
}

func setTransferPrivacy(header http.Header) {
	header.Set("Cache-Control", "private, no-store")
	header.Set("Referrer-Policy", "no-referrer")
}

func (a *App) transfer(w http.ResponseWriter, r *http.Request, found route, result *outcome) {
	claims, ok := a.openGrant(r, found)
	if ok {
		var err error
		if ok, err = a.auth.AuthorizeGrant(r.Context(), claims); err != nil {
			mapFailure(w, result, err)
			return
		}
	}
	if !ok {
		problem(w, result, http.StatusUnauthorized, "invalid_grant")
		return
	}
	if err := fault.Hit(r.Context(), "transfer.authorized"); err != nil {
		mapFailure(w, result, err)
		return
	}
	a.serveAsset(w, r, found, result)
}

func (a *App) openGrant(r *http.Request, found route) (transfergrant.Claims, bool) {
	value, ok := transfergrant.GrantFromQuery(r.URL.RawQuery)
	if !ok {
		return transfergrant.Claims{}, false
	}
	claims, ok := a.transfers.Open(value, a.now())
	if !ok || claims.BookID != found.id || claims.AssetID != found.assetID {
		return transfergrant.Claims{}, false
	}
	return claims, true
}

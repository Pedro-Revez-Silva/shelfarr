package gohttp

import (
	"context"
	"database/sql"
	"errors"
	"net/http"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/acquire"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/live"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
)

const unknownHealthStatus = "unknown"

var errNotAdmin = errors.New("the account is not an administrator")

type overviewCounts struct {
	Users             int `json:"users"`
	Books             int `json:"books"`
	ActiveRequests    int `json:"active_requests"`
	AttentionRequests int `json:"attention_requests"`
}

type serviceHealth struct {
	Service   string  `json:"service"`
	Status    *string `json:"status"`
	CheckedAt *string `json:"checked_at"`
}

type overviewBody struct {
	Account  string          `json:"account"`
	Counts   overviewCounts  `json:"counts"`
	Services []serviceHealth `json:"services"`
}

func (a *App) webAdminOverview(w http.ResponseWriter, r *http.Request, session browserSession, result *outcome) {
	if !session.user.Admin {
		problem(w, result, http.StatusNotFound, "not_found")
		return
	}
	overview, err := a.db.ServerOverview(r.Context(), func(ctx context.Context, tx *sql.Tx) error {
		if err := a.authorityIn(ctx, tx, authority{sessionID: session.row.ID, userID: session.user.ID}); err != nil {
			return err
		}
		admin, err := live.UserIsAdminIn(ctx, tx, session.user.ID)
		if err == nil && !admin {
			err = errNotAdmin
		}
		return err
	})
	switch {
	case errors.Is(err, acquire.ErrRevoked):
		problem(w, result, http.StatusUnauthorized, "signed_out")
		return
	case errors.Is(err, errNotAdmin):
		problem(w, result, http.StatusNotFound, "not_found")
		return
	case err != nil:
		mapFailure(w, result, err)
		return
	}
	body := overviewBody{
		Account: session.account(),
		Counts: overviewCounts{Users: overview.Counts.Users, Books: overview.Counts.Books, ActiveRequests: overview.Counts.ActiveRequests,
			AttentionRequests: overview.Counts.AttentionRequests},
		Services: make([]serviceHealth, 0, len(overview.Health)),
	}
	for _, row := range overview.Health {
		body.Services = append(body.Services, projectHealth(row))
	}
	result.set(http.StatusOK, "")
	writeJSON(w, http.StatusOK, body)
}

func projectHealth(row live.HealthRow) serviceHealth {
	projected := serviceHealth{Service: row.Service}
	if !row.Saved {
		return projected
	}
	status, known := live.HealthStatuses[row.Status]
	if !known {
		status = unknownHealthStatus
	}
	if moment, err := store.ParseTimestamp(row.CheckedAt.String); row.CheckedAt.Valid && err == nil {
		checked := store.FormatISO8601Millis(moment)
		projected.CheckedAt = &checked
	}
	projected.Status = &status
	return projected
}

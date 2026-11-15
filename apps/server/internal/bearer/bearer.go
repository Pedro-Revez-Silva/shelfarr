package bearer

import (
	"context"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/account"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/live"
)

type Authenticator struct {
	DB  *live.DB
	Now func() time.Time
}

func (a Authenticator) Authenticate(ctx context.Context, authorization string) (*account.Principal, error) {
	raw, ok := account.BearerToken(authorization)
	if !ok {
		return nil, nil
	}
	now := a.Now()
	token, err := a.DB.ActiveTokenByDigest(ctx, account.TokenDigest(raw), live.TimestampText(now))
	if err != nil || token == nil {
		return nil, err
	}
	var user *live.User
	if token.UserID.Valid {
		if user, err = a.DB.UserByID(ctx, token.UserID.Int64); err != nil {
			return nil, err
		}
		if user != nil && user.Deleted {
			return nil, nil
		}
	}
	adopted, err := a.DB.RetireReplaced(ctx, *token, now)
	if err != nil || !adopted {
		return nil, err
	}
	if err := a.DB.TouchToken(ctx, token.ID, now); err != nil {
		return nil, err
	}
	if user == nil {
		return nil, nil
	}
	scopes, err := account.ScopeList(token.Scopes)
	if err != nil {
		return nil, err
	}
	return &account.Principal{UserID: user.ID, Username: user.Username, Name: user.Name, Admin: user.Role == 1, Scopes: scopes}, nil
}

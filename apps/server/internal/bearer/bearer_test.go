package bearer

import (
	"context"
	"database/sql"
	"errors"
	"testing"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/account"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/live"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/livetest"
)

var now = time.Date(2026, 11, 15, 9, 30, 15, 250_000_000, time.UTC)

type fixture struct {
	path          string
	authenticator Authenticator
}

func newFixture(t *testing.T) fixture {
	t.Helper()
	path := livetest.Create(t)
	database, err := live.Open(context.Background(), path, live.Options{BusyTimeout: 150 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { database.Close() })
	livetest.Exec(t, path, `INSERT INTO users (id, username, name, role, deleted_at) VALUES (1, 'alice', 'Alice', 0, NULL), (2, 'root', 'Root', 1, NULL), (3, 'gone', 'Gone', 0, '2026-11-01 00:00:00')`)
	return fixture{path: path, authenticator: Authenticator{DB: database, Now: func() time.Time { return now }}}
}

func (f fixture) add(t *testing.T, id int64, raw string, user any, scopes string, extra string) {
	t.Helper()
	livetest.Exec(t, f.path, `INSERT INTO api_tokens (id, user_id, token_digest, scopes) VALUES (?, ?, ?, ?)`, id, user, account.TokenDigest(raw), scopes)
	if extra != "" {
		livetest.Exec(t, f.path, `UPDATE api_tokens SET `+extra+` WHERE id = ?`, id)
	}
}

func (f fixture) used(t *testing.T, id int64) bool {
	t.Helper()
	return livetest.Query(t, f.path, `SELECT last_used_at IS NOT NULL FROM api_tokens WHERE id = ?`, id)[0][0].(int64) == 1
}

func TestAuthenticationYieldsTheAccountAndRecordsUseOnce(t *testing.T) {
	f := newFixture(t)
	f.add(t, 1, "plain-token-without-issuance-prefix", 1, `["library:read","progress:write"]`, "")
	principal, err := f.authenticator.Authenticate(context.Background(), "Bearer plain-token-without-issuance-prefix")
	if err != nil || principal == nil || principal.UserID != 1 || principal.Username != "alice" || principal.Admin || len(principal.Scopes) != 2 {
		t.Fatalf("%+v %v", principal, err)
	}
	if !f.used(t, 1) {
		t.Fatal("last_used_at was not recorded")
	}
	stamp := livetest.Query(t, f.path, `SELECT CAST(last_used_at AS TEXT), CAST(updated_at AS TEXT) FROM api_tokens WHERE id = 1`)[0]
	if stamp[0] != "2026-11-15 09:30:15.250000" || stamp[1] != "2026-11-15 09:30:15.250000" {
		t.Fatalf("unexpected stamps %v", stamp)
	}
}

func TestInactiveCredentialsAreRejectedWithoutAnyWrite(t *testing.T) {
	f := newFixture(t)
	f.add(t, 1, "revoked", 1, `["library:read"]`, "revoked_at = '2026-11-01 00:00:00'")
	f.add(t, 2, "expired", 1, `["library:read"]`, "expires_at = '2026-11-15 09:30:15.250000'")
	f.add(t, 3, "deleted-owner", 3, `["library:read"]`, "")
	for _, raw := range []string{"revoked", "expired", "deleted-owner", "unknown"} {
		principal, err := f.authenticator.Authenticate(context.Background(), "Bearer "+raw)
		if err != nil || principal != nil {
			t.Fatalf("%s: %+v %v", raw, principal, err)
		}
	}
	for _, id := range []int64{1, 2, 3} {
		if f.used(t, id) {
			t.Fatalf("token %d was touched", id)
		}
	}
}

func TestMalformedAuthorizationNeverReachesTheDatabase(t *testing.T) {
	f := newFixture(t)
	f.add(t, 1, "secret", 1, `["library:read"]`, "")
	for _, header := range []string{"", "Bearer", "Bearer    ", "Basic secret", "secret", "Token secret"} {
		if principal, err := f.authenticator.Authenticate(context.Background(), header); err != nil || principal != nil {
			t.Fatalf("%q: %+v %v", header, principal, err)
		}
	}
	if f.used(t, 1) {
		t.Fatal("a malformed header touched a token")
	}
	for _, header := range []string{"bearer secret", "BEARER   secret", "Bearer\tsecret"} {
		if principal, err := f.authenticator.Authenticate(context.Background(), header); err != nil || principal == nil {
			t.Fatalf("%q: %+v %v", header, principal, err)
		}
	}
}

func TestOwnerlessTokensAreTouchedLikeRailsButNeverAuthenticate(t *testing.T) {
	f := newFixture(t)
	f.add(t, 1, "ownerless", nil, `["library:read"]`, "")
	f.add(t, 2, "dangling", 99, `["library:read"]`, "")
	for _, raw := range []string{"ownerless", "dangling"} {
		if principal, err := f.authenticator.Authenticate(context.Background(), "Bearer "+raw); err != nil || principal != nil {
			t.Fatalf("%s: %+v %v", raw, principal, err)
		}
	}
	if !f.used(t, 1) || !f.used(t, 2) {
		t.Fatal("Rails touches a token whose owner is missing before it refuses the request")
	}
}

func TestPrivilegedScopesRequireAnAdministrator(t *testing.T) {
	f := newFixture(t)
	f.add(t, 1, "member", 1, `["library:read","requests:admin"]`, "")
	f.add(t, 2, "admin", 2, `["library:read","requests:admin"]`, "")
	member, _ := f.authenticator.Authenticate(context.Background(), "Bearer member")
	admin, _ := f.authenticator.Authenticate(context.Background(), "Bearer admin")
	if got := member.VisibleScopes(); len(got) != 1 || got[0] != "library:read" {
		t.Fatalf("member scopes %v", got)
	}
	if got := admin.VisibleScopes(); len(got) != 2 || !admin.Admin {
		t.Fatalf("admin scopes %v", got)
	}
}

func TestAdoptionHappensOnFirstUseAndRetiresThePreviousCredential(t *testing.T) {
	f := newFixture(t)
	f.add(t, 1, "previous", 1, `["library:read"]`, "")
	f.add(t, 2, "adopting", 1, `["library:read"]`, "replaces_api_token_id = 1")
	if principal, err := f.authenticator.Authenticate(context.Background(), "Bearer adopting"); err != nil || principal == nil {
		t.Fatalf("%+v %v", principal, err)
	}
	if principal, err := f.authenticator.Authenticate(context.Background(), "Bearer previous"); err != nil || principal != nil {
		t.Fatalf("the retired credential still authenticates: %+v %v", principal, err)
	}
	pointer := livetest.Query(t, f.path, `SELECT replaces_api_token_id FROM api_tokens WHERE id = 2`)[0][0]
	if pointer != nil {
		t.Fatalf("pointer still set: %v", pointer)
	}
	if principal, err := f.authenticator.Authenticate(context.Background(), "Bearer adopting"); err != nil || principal == nil {
		t.Fatalf("the adopted credential stopped working: %+v %v", principal, err)
	}
}

func TestRefusedAdoptionDoesNotDiscardAnythingNorAuthenticate(t *testing.T) {
	f := newFixture(t)
	f.add(t, 1, "previous", 1, `["library:read"]`, "revoked_at = '2026-11-01 00:00:00'")
	f.add(t, 2, "orphaned", 1, `["library:read"]`, "replaces_api_token_id = 1")
	if principal, err := f.authenticator.Authenticate(context.Background(), "Bearer orphaned"); err != nil || principal != nil {
		t.Fatalf("%+v %v", principal, err)
	}
	if f.used(t, 2) {
		t.Fatal("a refused adoption touched the token")
	}
	pointer := livetest.Query(t, f.path, `SELECT replaces_api_token_id FROM api_tokens WHERE id = 2`)[0][0]
	if pointer != int64(1) {
		t.Fatalf("pointer was discarded: %v", pointer)
	}
}

func TestContentionIsAnErrorNeverAnAnonymousRequest(t *testing.T) {
	f := newFixture(t)
	f.add(t, 1, "valid", 1, `["library:read"]`, "")
	holder, err := sql.Open("sqlite", "file:"+f.path+"?_txlock=immediate")
	if err != nil {
		t.Fatal(err)
	}
	defer holder.Close()
	transaction, err := holder.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer transaction.Rollback()
	if _, err := transaction.Exec(`UPDATE api_tokens SET name = 'held' WHERE id = 1`); err != nil {
		t.Fatal(err)
	}
	principal, err := f.authenticator.Authenticate(context.Background(), "Bearer valid")
	if !errors.Is(err, live.ErrBusy) || principal != nil {
		t.Fatalf("%+v %v", principal, err)
	}
}

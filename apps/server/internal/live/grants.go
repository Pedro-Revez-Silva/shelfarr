package live

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"
	"unicode"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/account"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/devicegrant"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/fault"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
)

const (
	collisionRetries    = 5
	expiredGrantRetains = 24 * time.Hour
)

var (
	ErrStaleCredential = errors.New("the credential being upgraded is no longer usable")
	ErrCodeCollision   = errors.New("no unused code could be generated")
)

type Upgrade struct {
	TokenID int64
	UserID  int64
}

type GrantRequest struct {
	ClientName string
	Scopes     []string
	Upgrade    *Upgrade
}

type GrantSource struct {
	Codes         func() (devicegrant.Codes, error)
	AccessToken   func() (string, error)
	ConnectionKey func() (string, error)
}

type CreatedGrant struct {
	Codes    devicegrant.Codes
	Interval int
}

type grantRow struct {
	id         int64
	userID     sql.NullInt64
	clientName string
	expires    string
	approved   sql.NullString
	denied     sql.NullString
	consumed   sql.NullString
	polled     sql.NullString
	interval   int
	scopes     sql.NullString
	replaces   sql.NullInt64
}

const grantColumns = `id, user_id, client_name, CAST(expires_at AS TEXT), CAST(approved_at AS TEXT), CAST(denied_at AS TEXT), CAST(consumed_at AS TEXT), CAST(last_polled_at AS TEXT), poll_interval, scopes, replaces_api_token_id`

type rowQuerier interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

func readGrant(ctx context.Context, q rowQuerier, where string, argument any) (grantRow, bool, error) {
	var row grantRow
	err := q.QueryRowContext(ctx, `SELECT `+grantColumns+` FROM consumer_device_grants WHERE `+where, argument).
		Scan(&row.id, &row.userID, &row.clientName, &row.expires, &row.approved, &row.denied, &row.consumed, &row.polled, &row.interval, &row.scopes, &row.replaces)
	if errors.Is(err, sql.ErrNoRows) {
		return grantRow{}, false, nil
	}
	return row, err == nil, err
}

func (g grantRow) scopeList() []string {
	return devicegrant.StoredScopes(g.scopes.String, g.scopes.Valid)
}

func (g grantRow) expiry() (time.Time, error) { return store.ParseTimestamp(g.expires) }

func (g grantRow) pending(now time.Time) (bool, error) {
	expiry, err := g.expiry()
	if err != nil {
		return false, err
	}
	return expiry.After(now) && !g.approved.Valid && !g.denied.Valid && !g.consumed.Valid, nil
}

func classifyGrant(err error) error {
	if errors.Is(err, devicegrant.ErrRandom) || errors.Is(err, ErrCodeCollision) || errors.Is(err, ErrStaleCredential) {
		return err
	}
	return classifyWrite(err)
}

func blank(text string) bool {
	return strings.IndexFunc(text, func(r rune) bool { return !unicode.IsSpace(r) }) < 0
}

func isUnique(err error) bool {
	if err == nil {
		return false
	}
	text := err.Error()
	return strings.Contains(text, "UNIQUE constraint failed") || strings.Contains(text, "(2067)") || strings.Contains(text, "(1555)")
}

type originState struct {
	userID   sql.NullInt64
	revoked  sql.NullString
	expires  sql.NullString
	scopes   string
	deleted  sql.NullString
	userSeen sql.NullInt64
}

func (d *DB) CreateGrant(ctx context.Context, request GrantRequest, source GrantSource, clock func() time.Time) (CreatedGrant, error) {
	tx, err := d.write.BeginTx(ctx, nil)
	if err != nil {
		return CreatedGrant{}, Classify(err)
	}
	defer tx.Rollback()
	if err := fault.Hit(ctx, "device.locked"); err != nil {
		return CreatedGrant{}, err
	}
	now := clock()
	if request.Upgrade != nil {
		if err := recheckUpgrade(ctx, tx, *request.Upgrade, now); err != nil {
			return CreatedGrant{}, classifyGrant(err)
		}
	}
	stamp := TimestampText(now)
	if _, err := tx.ExecContext(ctx, `DELETE FROM consumer_device_grants WHERE expires_at < ?`, TimestampText(now.Add(-expiredGrantRetains))); err != nil {
		return CreatedGrant{}, Classify(err)
	}
	var scopes any
	if encoded, stored := devicegrant.EncodeScopes(request.Scopes); stored {
		scopes = encoded
	}
	var replaces any
	if request.Upgrade != nil {
		replaces = request.Upgrade.TokenID
	}
	expires := TimestampText(now.Add(devicegrant.LifetimeSeconds * time.Second))
	for attempt := 0; attempt < collisionRetries; attempt++ {
		codes, err := source.Codes()
		if err != nil {
			return CreatedGrant{}, err
		}
		_, err = tx.ExecContext(ctx,
			`INSERT INTO consumer_device_grants (user_id, client_name, device_code_digest, user_code_digest, expires_at, poll_interval, scopes, replaces_api_token_id, created_at, updated_at) VALUES (NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			request.ClientName, codes.DeviceDigest(), codes.UserDigest(), expires, devicegrant.InitialInterval, scopes, replaces, stamp, stamp)
		if isUnique(err) {
			continue
		}
		if err != nil {
			return CreatedGrant{}, Classify(err)
		}
		if err := fault.Hit(ctx, "device.before-commit"); err != nil {
			return CreatedGrant{}, err
		}
		if err := tx.Commit(); err != nil {
			return CreatedGrant{}, Classify(err)
		}
		if err := fault.Hit(ctx, "device.committed"); err != nil {
			return CreatedGrant{}, err
		}
		return CreatedGrant{Codes: codes, Interval: devicegrant.InitialInterval}, nil
	}
	return CreatedGrant{}, ErrCodeCollision
}

func recheckUpgrade(ctx context.Context, tx *sql.Tx, origin Upgrade, now time.Time) error {
	var state originState
	err := tx.QueryRowContext(ctx,
		`SELECT t.user_id, CAST(t.revoked_at AS TEXT), CAST(t.expires_at AS TEXT), t.scopes, CAST(u.deleted_at AS TEXT), u.id FROM api_tokens t LEFT JOIN users u ON u.id = t.user_id WHERE t.id = ?`,
		origin.TokenID).Scan(&state.userID, &state.revoked, &state.expires, &state.scopes, &state.deleted, &state.userSeen)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrStaleCredential
	}
	if err != nil {
		return err
	}
	if !state.userID.Valid || state.userID.Int64 != origin.UserID || !state.userSeen.Valid || state.deleted.Valid || state.revoked.Valid {
		return ErrStaleCredential
	}
	if state.expires.Valid {
		expiry, err := store.ParseTimestamp(state.expires.String)
		if err != nil {
			return err
		}
		if !expiry.After(now) {
			return ErrStaleCredential
		}
	}
	scopes, err := account.ScopeList(state.scopes)
	if err != nil {
		return err
	}
	for _, scope := range scopes {
		if scope == "library:read" {
			return nil
		}
	}
	return ErrStaleCredential
}

type GrantView struct {
	Found      bool
	Pending    bool
	Decidable  bool
	ClientName string
	Upgrade    bool
	Requesting bool
	Scopes     []string
	ExpiresAt  time.Time
}

func (d *DB) InspectGrant(ctx context.Context, userCodeDigest string, actorID int64, now time.Time) (GrantView, error) {
	row, found, err := readGrant(ctx, d.read, `user_code_digest = ?`, userCodeDigest)
	if err != nil {
		return GrantView{}, classifyWrite(err)
	}
	if !found {
		return GrantView{}, nil
	}
	pending, err := row.pending(now)
	if err != nil {
		return GrantView{}, err
	}
	view := GrantView{Found: true, Pending: pending}
	if !pending {
		return view, nil
	}
	decidable, err := decidableBy(ctx, d.read, row, actorID)
	if err != nil {
		return GrantView{}, classifyWrite(err)
	}
	view.Decidable = decidable
	if !decidable {
		return view, nil
	}
	expiry, err := row.expiry()
	if err != nil {
		return GrantView{}, err
	}
	view.ClientName = row.clientName
	view.Upgrade = row.replaces.Valid
	view.Scopes = row.scopeList()
	view.Requesting = devicegrant.Requesting(view.Scopes)
	view.ExpiresAt = expiry
	return view, nil
}

func decidableBy(ctx context.Context, q rowQuerier, row grantRow, actorID int64) (bool, error) {
	var deleted sql.NullString
	var seen int64
	err := q.QueryRowContext(ctx, `SELECT id, CAST(deleted_at AS TEXT) FROM users WHERE id = ?`, actorID).Scan(&seen, &deleted)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if deleted.Valid {
		return false, nil
	}
	if !row.replaces.Valid {
		return true, nil
	}
	var owner sql.NullInt64
	err = q.QueryRowContext(ctx, `SELECT user_id FROM api_tokens WHERE id = ?`, row.replaces.Int64).Scan(&owner)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return owner.Valid && owner.Int64 == actorID, nil
}

type DecideOutcome int

const (
	DecideApplied DecideOutcome = iota
	DecideWrongAccount
	DecideNotPending
)

type DecideResult struct {
	Outcome    DecideOutcome
	Upgrade    bool
	Requesting bool
}

func (d *DB) DecideGrant(ctx context.Context, userCodeDigest string, actorID int64, allow bool, clock func() time.Time) (DecideResult, error) {
	tx, err := d.write.BeginTx(ctx, nil)
	if err != nil {
		return DecideResult{}, Classify(err)
	}
	defer tx.Rollback()
	if err := fault.Hit(ctx, "decide.locked"); err != nil {
		return DecideResult{}, err
	}
	row, found, err := readGrant(ctx, tx, `user_code_digest = ?`, userCodeDigest)
	if err != nil {
		return DecideResult{}, classifyWrite(err)
	}
	if !found {
		return DecideResult{Outcome: DecideNotPending}, nil
	}
	now := clock()
	pending, err := row.pending(now)
	if err != nil {
		return DecideResult{}, err
	}
	if !pending {
		return DecideResult{Outcome: DecideNotPending}, nil
	}
	decidable, err := decidableBy(ctx, tx, row, actorID)
	if err != nil {
		return DecideResult{}, classifyWrite(err)
	}
	if !decidable {
		return DecideResult{Outcome: DecideWrongAccount}, nil
	}
	column := "denied_at"
	if allow {
		column = "approved_at"
	}
	stamp := TimestampText(now)
	updated, err := tx.ExecContext(ctx, `UPDATE consumer_device_grants SET user_id = ?, `+column+` = ?, updated_at = ? WHERE id = ? AND approved_at IS NULL AND denied_at IS NULL AND consumed_at IS NULL`, actorID, stamp, stamp, row.id)
	if err != nil {
		return DecideResult{}, Classify(err)
	}
	if count, _ := updated.RowsAffected(); count != 1 {
		return DecideResult{Outcome: DecideNotPending}, nil
	}
	if err := fault.Hit(ctx, "decide.before-commit"); err != nil {
		return DecideResult{}, err
	}
	if err := tx.Commit(); err != nil {
		return DecideResult{}, Classify(err)
	}
	if err := fault.Hit(ctx, "decide.committed"); err != nil {
		return DecideResult{}, err
	}
	return DecideResult{Outcome: DecideApplied, Upgrade: row.replaces.Valid, Requesting: devicegrant.Requesting(row.scopeList())}, nil
}

type ExchangeOutcome int

const (
	ExchangeIssued ExchangeOutcome = iota
	ExchangeExpired
	ExchangeDenied
	ExchangeSlowDown
	ExchangePending
)

type ExchangeResult struct {
	Outcome     ExchangeOutcome
	AccessToken string
	Scopes      []string
}

type replacedToken struct {
	userID        sql.NullInt64
	revoked       sql.NullString
	expires       sql.NullString
	connectionKey sql.NullString
}

func (r replacedToken) usable(now time.Time) (bool, error) {
	if r.revoked.Valid {
		return false, nil
	}
	if !r.expires.Valid {
		return true, nil
	}
	expiry, err := store.ParseTimestamp(r.expires.String)
	if err != nil {
		return false, err
	}
	return expiry.After(now), nil
}

func (d *DB) ExchangeGrant(ctx context.Context, deviceCodeDigest string, source GrantSource, clock func() time.Time) (ExchangeResult, error) {
	tx, err := d.write.BeginTx(ctx, nil)
	if err != nil {
		return ExchangeResult{}, Classify(err)
	}
	defer tx.Rollback()
	if err := fault.Hit(ctx, "exchange.locked"); err != nil {
		return ExchangeResult{}, err
	}
	row, found, err := readGrant(ctx, tx, `device_code_digest = ?`, deviceCodeDigest)
	if err != nil {
		return ExchangeResult{}, classifyWrite(err)
	}
	if !found {
		return ExchangeResult{Outcome: ExchangeExpired}, nil
	}
	now := clock()
	stamp := TimestampText(now)
	outcome, issued, err := exchangeIn(ctx, tx, row, source, now, stamp)
	if err != nil {
		return ExchangeResult{}, classifyGrant(err)
	}
	if err := fault.Hit(ctx, "exchange.before-commit"); err != nil {
		return ExchangeResult{}, err
	}
	if err := tx.Commit(); err != nil {
		return ExchangeResult{}, Classify(err)
	}
	if err := fault.Hit(ctx, "exchange.committed"); err != nil {
		return ExchangeResult{}, err
	}
	issued.Outcome = outcome
	return issued, nil
}

func exchangeIn(ctx context.Context, tx *sql.Tx, row grantRow, source GrantSource, now time.Time, stamp string) (ExchangeOutcome, ExchangeResult, error) {
	expiry, err := row.expiry()
	if err != nil {
		return 0, ExchangeResult{}, err
	}
	if row.consumed.Valid || !expiry.After(now) {
		return ExchangeExpired, ExchangeResult{}, nil
	}
	ownerGone, err := ownerDeleted(ctx, tx, row)
	if err != nil {
		return 0, ExchangeResult{}, err
	}
	if row.denied.Valid || ownerGone {
		return ExchangeDenied, ExchangeResult{}, nil
	}
	if row.polled.Valid {
		polled, err := store.ParseTimestamp(row.polled.String)
		if err != nil {
			return 0, ExchangeResult{}, err
		}
		if polled.After(now.Add(-time.Duration(row.interval) * time.Second)) {
			next := min(row.interval+devicegrant.IntervalStep, devicegrant.MaxInterval)
			_, err := tx.ExecContext(ctx, `UPDATE consumer_device_grants SET last_polled_at = ?, poll_interval = ?, updated_at = ? WHERE id = ?`, stamp, next, stamp, row.id)
			return ExchangeSlowDown, ExchangeResult{}, err
		}
	}
	if !row.approved.Valid {
		_, err := tx.ExecContext(ctx, `UPDATE consumer_device_grants SET last_polled_at = ?, updated_at = ? WHERE id = ?`, stamp, stamp, row.id)
		return ExchangePending, ExchangeResult{}, err
	}
	var origin replacedToken
	if row.replaces.Valid {
		origin, err = readReplaced(ctx, tx, row.replaces.Int64)
		if err != nil {
			return 0, ExchangeResult{}, err
		}
		usable, err := origin.usable(now)
		if err != nil {
			return 0, ExchangeResult{}, err
		}
		if origin.userID != row.userID || !origin.userID.Valid || !usable {
			return consumeDenied(ctx, tx, row.id, stamp)
		}
	}
	scopes := row.scopeList()
	raw, err := issueToken(ctx, tx, row, origin, scopes, source, now, stamp)
	if err != nil {
		return 0, ExchangeResult{}, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE consumer_device_grants SET consumed_at = ?, updated_at = ? WHERE id = ?`, stamp, stamp, row.id); err != nil {
		return 0, ExchangeResult{}, err
	}
	return ExchangeIssued, ExchangeResult{AccessToken: raw, Scopes: scopes}, nil
}

func consumeDenied(ctx context.Context, tx *sql.Tx, id int64, stamp string) (ExchangeOutcome, ExchangeResult, error) {
	_, err := tx.ExecContext(ctx, `UPDATE consumer_device_grants SET consumed_at = ?, updated_at = ? WHERE id = ?`, stamp, stamp, id)
	return ExchangeDenied, ExchangeResult{}, err
}

func ownerDeleted(ctx context.Context, tx *sql.Tx, row grantRow) (bool, error) {
	if !row.userID.Valid {
		return false, nil
	}
	var deleted sql.NullString
	err := tx.QueryRowContext(ctx, `SELECT CAST(deleted_at AS TEXT) FROM users WHERE id = ?`, row.userID.Int64).Scan(&deleted)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return deleted.Valid, err
}

func readReplaced(ctx context.Context, tx *sql.Tx, id int64) (replacedToken, error) {
	var token replacedToken
	err := tx.QueryRowContext(ctx, `SELECT user_id, CAST(revoked_at AS TEXT), CAST(expires_at AS TEXT), connection_key FROM api_tokens WHERE id = ?`, id).Scan(&token.userID, &token.revoked, &token.expires, &token.connectionKey)
	if errors.Is(err, sql.ErrNoRows) {
		return replacedToken{}, nil
	}
	return token, err
}

func issueToken(ctx context.Context, tx *sql.Tx, row grantRow, origin replacedToken, scopes []string, source GrantSource, now time.Time, stamp string) (string, error) {
	key := ""
	if row.replaces.Valid && origin.connectionKey.Valid && !blank(origin.connectionKey.String) {
		key = origin.connectionKey.String
	} else {
		generated, err := source.ConnectionKey()
		if err != nil {
			return "", err
		}
		key = generated
		if row.replaces.Valid {
			if _, err := tx.ExecContext(ctx, `UPDATE api_tokens SET connection_key = ?, updated_at = ? WHERE id = ?`, key, stamp, row.replaces.Int64); err != nil {
				return "", err
			}
		}
	}
	encoded, _ := devicegrant.EncodeScopes(scopes)
	if encoded == "" {
		encoded = `["library:read","progress:write"]`
	}
	expires := TimestampText(now.Add(devicegrant.TokenLifetimeSecs * time.Second))
	for attempt := 0; attempt < collisionRetries; attempt++ {
		raw, err := source.AccessToken()
		if err != nil {
			return "", err
		}
		var replaces any
		if row.replaces.Valid {
			replaces = row.replaces.Int64
		}
		_, err = tx.ExecContext(ctx,
			`INSERT INTO api_tokens (user_id, name, scopes, token_digest, token_prefix, expires_at, issued_via, replaces_api_token_id, connection_key, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			row.userID, row.clientName, encoded, account.TokenDigest(raw), devicegrant.TokenPrefixOf(raw), expires, devicegrant.Consumer, replaces, key, stamp, stamp)
		if isUnique(err) {
			continue
		}
		if err != nil {
			return "", err
		}
		return raw, nil
	}
	return "", ErrCodeCollision
}

func (d *DB) RevokeConnection(ctx context.Context, tokenID int64, clock func() time.Time) (bool, error) {
	tx, err := d.write.BeginTx(ctx, nil)
	if err != nil {
		return false, Classify(err)
	}
	defer tx.Rollback()
	if err := fault.Hit(ctx, "revoke.locked"); err != nil {
		return false, err
	}
	var owner sql.NullInt64
	var key sql.NullString
	err = tx.QueryRowContext(ctx, `SELECT user_id, connection_key FROM api_tokens WHERE id = ?`, tokenID).Scan(&owner, &key)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, Classify(err)
	}
	stamp := TimestampText(clock())
	family, argument := `id = ?`, any(tokenID)
	arguments := []any{stamp, stamp}
	if key.Valid && !blank(key.String) {
		family = `user_id IS ? AND connection_key = ?`
		arguments = append(arguments, owner, key.String)
	} else {
		arguments = append(arguments, argument)
	}
	if _, err := tx.ExecContext(ctx, `UPDATE api_tokens SET revoked_at = ?, updated_at = ? WHERE `+family, arguments...); err != nil {
		return false, Classify(err)
	}
	if _, err := tx.ExecContext(ctx, `UPDATE consumer_device_grants SET denied_at = ?, updated_at = ? WHERE consumed_at IS NULL AND replaces_api_token_id IN (SELECT id FROM api_tokens WHERE `+family+`)`, arguments...); err != nil {
		return false, Classify(err)
	}
	if err := fault.Hit(ctx, "revoke.before-commit"); err != nil {
		return false, err
	}
	if err := tx.Commit(); err != nil {
		return false, Classify(err)
	}
	if err := fault.Hit(ctx, "revoke.committed"); err != nil {
		return false, err
	}
	return true, nil
}

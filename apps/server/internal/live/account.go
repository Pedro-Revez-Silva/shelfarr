package live

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/account"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/fault"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
)

var (
	ErrSessionEnded   = errors.New("the browser session ended")
	ErrAccountChanged = errors.New("the account's sign-in details changed")
)

type Profile struct {
	ID       int64
	Username string
	Name     string
}

type PasswordSnapshot struct {
	Digest       string
	OIDCLinked   bool
	RecordErrors account.FieldErrors
}

type ProfileResult struct {
	Errors  account.FieldErrors
	Profile Profile
}

type PasswordResult struct {
	Errors        account.FieldErrors
	Profile       Profile
	EndedSessions int64
}

type accountRecord struct {
	username string
	name     string
	digest   string
	deleted  bool
	provider sql.NullString
	uid      sql.NullString
}

func (r accountRecord) oidcLinked() bool {
	return r.provider.Valid && !account.Blank(r.provider.String) && r.uid.Valid && !account.Blank(r.uid.String)
}

func readAccount(ctx context.Context, q rowQuerier, userID int64) (accountRecord, bool, error) {
	var record accountRecord
	var deleted sql.NullString
	err := q.QueryRowContext(ctx, `SELECT username, name, password_digest, CAST(deleted_at AS TEXT), oidc_provider, oidc_uid FROM users WHERE id = ?`, userID).
		Scan(&record.username, &record.name, &record.digest, &deleted, &record.provider, &record.uid)
	if errors.Is(err, sql.ErrNoRows) {
		return accountRecord{}, false, nil
	}
	if err != nil {
		return accountRecord{}, false, Classify(err)
	}
	record.deleted = deleted.Valid
	return record, true, nil
}

func taken(ctx context.Context, q rowQuerier, statement string, arguments ...any) (bool, error) {
	var one int
	err := q.QueryRowContext(ctx, statement, arguments...).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, Classify(err)
}

func recordErrors(ctx context.Context, q rowQuerier, userID int64, record accountRecord, name string) (account.FieldErrors, error) {
	found := account.UsernameErrors(record.username)
	duplicate, err := taken(ctx, q, `SELECT 1 FROM users WHERE username = ? AND deleted_at IS NULL AND id != ? LIMIT 1`, record.username, userID)
	if err != nil {
		return nil, err
	}
	if duplicate {
		found.Add("username", account.MessageTaken)
	}
	found.Merge(account.NameErrors(name))
	providerPresent := record.provider.Valid && !account.Blank(record.provider.String)
	uidPresent := record.uid.Valid && !account.Blank(record.uid.String)
	if uidPresent && !providerPresent {
		found.Add("oidc_provider", account.MessageBlank)
	}
	if providerPresent && !uidPresent {
		found.Add("oidc_uid", account.MessageBlank)
	}
	if record.uid.Valid {
		duplicate, err := taken(ctx, q, `SELECT 1 FROM users WHERE oidc_uid = ? AND oidc_provider IS ? AND deleted_at IS NULL AND id != ? LIMIT 1`, record.uid.String, record.provider, userID)
		if err != nil {
			return nil, err
		}
		if duplicate {
			found.Add("oidc_uid", account.MessageTaken)
		}
	}
	if account.Blank(record.digest) {
		found.Add("password", account.MessageBlank)
	}
	return found, nil
}

func (d *DB) PasswordSnapshot(ctx context.Context, userID int64) (*PasswordSnapshot, error) {
	record, found, err := readAccount(ctx, d.read, userID)
	if err != nil || !found || record.deleted {
		return nil, err
	}
	invalid, err := recordErrors(ctx, d.read, userID, record, record.name)
	if err != nil {
		return nil, err
	}
	return &PasswordSnapshot{Digest: record.digest, OIDCLinked: record.oidcLinked(), RecordErrors: invalid}, nil
}

func sessionHolds(ctx context.Context, tx *sql.Tx, session SessionRow) (bool, error) {
	var userID int64
	var created string
	err := tx.QueryRowContext(ctx, `SELECT user_id, CAST(created_at AS TEXT) FROM sessions WHERE id = ?`, session.ID).Scan(&userID, &created)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, Classify(err)
	}
	moment, err := store.ParseTimestamp(created)
	if err != nil {
		return false, err
	}
	return userID == session.UserID && moment.Equal(session.CreatedAt), nil
}

func lockedAccount(ctx context.Context, tx *sql.Tx, session SessionRow, now time.Time) (accountRecord, error) {
	holds, err := sessionHolds(ctx, tx, session)
	if err != nil {
		return accountRecord{}, err
	}
	if !holds {
		return accountRecord{}, ErrSessionEnded
	}
	lifetime, err := sessionLifetime(ctx, tx)
	if err != nil {
		return accountRecord{}, err
	}
	if session.CreatedAt.Before(now.Add(-lifetime)) {
		return accountRecord{}, ErrSessionEnded
	}
	record, found, err := readAccount(ctx, tx, session.UserID)
	if err != nil {
		return accountRecord{}, err
	}
	if !found || record.deleted {
		return accountRecord{}, ErrSessionEnded
	}
	return record, nil
}

func (d *DB) UpdateName(ctx context.Context, session SessionRow, name string, clock func() time.Time) (ProfileResult, error) {
	tx, err := d.write.BeginTx(ctx, nil)
	if err != nil {
		return ProfileResult{}, Classify(err)
	}
	defer tx.Rollback()
	if err := fault.Hit(ctx, "profile.locked"); err != nil {
		return ProfileResult{}, err
	}
	now := clock()
	record, err := lockedAccount(ctx, tx, session, now)
	if err != nil {
		return ProfileResult{}, err
	}
	invalid, err := recordErrors(ctx, tx, session.UserID, record, name)
	if err != nil {
		return ProfileResult{}, err
	}
	if len(invalid) > 0 {
		return ProfileResult{Errors: invalid}, nil
	}
	if name != record.name {
		if _, err := tx.ExecContext(ctx, `UPDATE users SET name = ?, updated_at = ? WHERE id = ?`, name, TimestampText(now), session.UserID); err != nil {
			return ProfileResult{}, Classify(err)
		}
	}
	if err := fault.Hit(ctx, "profile.before-commit"); err != nil {
		return ProfileResult{}, err
	}
	if err := tx.Commit(); err != nil {
		return ProfileResult{}, Classify(err)
	}
	return ProfileResult{Profile: Profile{ID: session.UserID, Username: record.username, Name: name}}, nil
}

func (d *DB) ChangePassword(ctx context.Context, session SessionRow, checked PasswordSnapshot, digest string, clock func() time.Time) (PasswordResult, error) {
	tx, err := d.write.BeginTx(ctx, nil)
	if err != nil {
		return PasswordResult{}, Classify(err)
	}
	defer tx.Rollback()
	if err := fault.Hit(ctx, "password.locked"); err != nil {
		return PasswordResult{}, err
	}
	now := clock()
	record, err := lockedAccount(ctx, tx, session, now)
	if err != nil {
		return PasswordResult{}, err
	}
	if record.digest != checked.Digest || record.oidcLinked() != checked.OIDCLinked {
		return PasswordResult{}, ErrAccountChanged
	}
	invalid, err := recordErrors(ctx, tx, session.UserID, record, record.name)
	if err != nil {
		return PasswordResult{}, err
	}
	if len(invalid) > 0 {
		return PasswordResult{Errors: invalid}, nil
	}
	if _, err := tx.ExecContext(ctx, `UPDATE users SET password_digest = ?, updated_at = ? WHERE id = ?`, digest, TimestampText(now), session.UserID); err != nil {
		return PasswordResult{}, Classify(err)
	}
	ended, err := tx.ExecContext(ctx, `DELETE FROM sessions WHERE user_id = ? AND id != ?`, session.UserID, session.ID)
	if err != nil {
		return PasswordResult{}, Classify(err)
	}
	count, err := ended.RowsAffected()
	if err != nil {
		return PasswordResult{}, Classify(err)
	}
	if err := fault.Hit(ctx, "password.before-commit"); err != nil {
		return PasswordResult{}, err
	}
	if err := tx.Commit(); err != nil {
		return PasswordResult{}, Classify(err)
	}
	return PasswordResult{Profile: Profile{ID: session.UserID, Username: record.username, Name: record.name}, EndedSessions: count}, nil
}

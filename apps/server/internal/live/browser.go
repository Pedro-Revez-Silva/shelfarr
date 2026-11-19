package live

import (
	"context"
	"database/sql"
	"errors"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/fault"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
)

type SessionRow struct {
	ID        int64
	UserID    int64
	CreatedAt time.Time
}

type BrowserUser struct {
	ID       int64
	Username string
	Name     string
	Admin    bool
	Deleted  bool
}

type Credentials struct {
	ID               int64
	PasswordDigest   string
	OTPRequired      bool
	OTPSecretPresent bool
	OIDCLinked       bool
}

type Client struct {
	UserAgent string
	IP        string
}

type LoginOutcome int

const (
	LoginCreated LoginOutcome = iota
	LoginRefused
	LoginNeedsSecondFactor
	LoginNeedsOIDC
	LoginPasswordless
)

type LoginResult struct {
	Outcome   LoginOutcome
	Session   SessionRow
	ExpiresAt time.Time
}

const MaxSessionAgeDays = 36500

func (d *DB) SessionByID(ctx context.Context, id int64) (*SessionRow, error) {
	var row SessionRow
	var created string
	err := d.read.QueryRowContext(ctx, `SELECT id, user_id, CAST(created_at AS TEXT) FROM sessions WHERE id = ?`, id).Scan(&row.ID, &row.UserID, &created)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, Classify(err)
	}
	moment, err := store.ParseTimestamp(created)
	if err != nil {
		return nil, err
	}
	row.CreatedAt = moment
	return &row, nil
}

func (d *DB) BrowserUserByID(ctx context.Context, id int64) (*BrowserUser, error) {
	user, err := d.UserByID(ctx, id)
	if err != nil || user == nil {
		return nil, err
	}
	return &BrowserUser{ID: user.ID, Username: user.Username, Name: user.Name, Admin: user.Role == 1, Deleted: user.Deleted}, nil
}

func (d *DB) ActiveCredentials(ctx context.Context, username string) (*Credentials, error) {
	var found Credentials
	var otpRequired sql.NullInt64
	var secret, provider, uid sql.NullString
	err := d.read.QueryRowContext(ctx,
		`SELECT id, password_digest, otp_required, otp_secret, oidc_provider, oidc_uid FROM users WHERE username = ? AND deleted_at IS NULL ORDER BY id LIMIT 1`,
		username).Scan(&found.ID, &found.PasswordDigest, &otpRequired, &secret, &provider, &uid)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, Classify(err)
	}
	found.OTPRequired = otpRequired.Valid && otpRequired.Int64 != 0
	found.OTPSecretPresent = strings.TrimSpace(secret.String) != ""
	found.OIDCLinked = strings.TrimSpace(provider.String) != "" && strings.TrimSpace(uid.String) != ""
	return &found, nil
}

type lockState struct {
	digest      string
	deleted     bool
	lockedUntil sql.NullString
	failures    int64
	lastAt      sql.NullString
	lastIP      sql.NullString
	otpRequired bool
	otpSecret   bool
	oidcLinked  bool
}

func readLockState(ctx context.Context, tx *sql.Tx, userID int64) (lockState, bool, error) {
	var state lockState
	var deleted, secret, provider, uid sql.NullString
	var otpRequired, failures sql.NullInt64
	err := tx.QueryRowContext(ctx,
		`SELECT password_digest, CAST(deleted_at AS TEXT), CAST(locked_until AS TEXT), failed_login_count, CAST(last_failed_login_at AS TEXT), last_failed_login_ip, otp_required, otp_secret, oidc_provider, oidc_uid FROM users WHERE id = ?`,
		userID).Scan(&state.digest, &deleted, &state.lockedUntil, &failures, &state.lastAt, &state.lastIP, &otpRequired, &secret, &provider, &uid)
	if errors.Is(err, sql.ErrNoRows) {
		return lockState{}, false, nil
	}
	if err != nil {
		return lockState{}, false, err
	}
	state.deleted = deleted.Valid
	state.failures = failures.Int64
	state.otpRequired = otpRequired.Valid && otpRequired.Int64 != 0
	state.otpSecret = strings.TrimSpace(secret.String) != ""
	state.oidcLinked = strings.TrimSpace(provider.String) != "" && strings.TrimSpace(uid.String) != ""
	return state, true, nil
}

func (s lockState) locked(now time.Time) (bool, error) {
	if !s.lockedUntil.Valid || s.lockedUntil.String == "" {
		return false, nil
	}
	until, err := store.ParseTimestamp(s.lockedUntil.String)
	if err != nil {
		return false, err
	}
	return until.After(now), nil
}

func (s lockState) dirty() bool {
	return s.failures != 0 || s.lockedUntil.Valid || s.lastAt.Valid || s.lastIP.Valid
}

func truncated(value string, limit int) any {
	if value == "" || len(value) > limit {
		return nil
	}
	return value
}

func (d *DB) CompleteLogin(ctx context.Context, userID int64, digest string, client Client, passwordlessEnv bool, clock func() time.Time) (LoginResult, error) {
	tx, err := d.write.BeginTx(ctx, nil)
	if err != nil {
		return LoginResult{}, Classify(err)
	}
	defer tx.Rollback()
	if err := fault.Hit(ctx, "login.locked"); err != nil {
		return LoginResult{}, err
	}
	now := clock()
	passwordless, err := passwordlessIn(ctx, tx, passwordlessEnv)
	if err != nil {
		return LoginResult{}, err
	}
	if passwordless {
		return LoginResult{Outcome: LoginPasswordless}, nil
	}
	state, found, err := readLockState(ctx, tx, userID)
	if err != nil {
		return LoginResult{}, Classify(err)
	}
	locked, err := state.locked(now)
	if err != nil {
		return LoginResult{}, err
	}
	switch {
	case !found || state.deleted || locked || state.digest != digest:
		return LoginResult{Outcome: LoginRefused}, nil
	case state.otpRequired && state.otpSecret:
		return LoginResult{Outcome: LoginNeedsSecondFactor}, nil
	case state.oidcLinked:
		return LoginResult{Outcome: LoginNeedsOIDC}, nil
	}
	lifetime, err := sessionLifetime(ctx, tx)
	if err != nil {
		return LoginResult{}, err
	}
	stamp := TimestampText(now)
	moment, err := store.ParseTimestamp(stamp)
	if err != nil {
		return LoginResult{}, err
	}
	if state.dirty() {
		if _, err := tx.ExecContext(ctx, `UPDATE users SET failed_login_count = 0, locked_until = NULL, last_failed_login_at = NULL, last_failed_login_ip = NULL, updated_at = ? WHERE id = ?`, stamp, userID); err != nil {
			return LoginResult{}, Classify(err)
		}
	}
	created, err := tx.ExecContext(ctx, `INSERT INTO sessions (user_id, user_agent, ip_address, created_at, updated_at) VALUES (?, ?, ?, ?, ?)`, userID, truncated(client.UserAgent, 1024), truncated(client.IP, 64), stamp, stamp)
	if err != nil {
		return LoginResult{}, Classify(err)
	}
	id, err := created.LastInsertId()
	if err != nil {
		return LoginResult{}, Classify(err)
	}
	if err := fault.Hit(ctx, "login.before-commit"); err != nil {
		return LoginResult{}, err
	}
	if err := tx.Commit(); err != nil {
		return LoginResult{}, Classify(err)
	}
	if err := fault.Hit(ctx, "login.committed"); err != nil {
		return LoginResult{}, err
	}
	return LoginResult{Outcome: LoginCreated, Session: SessionRow{ID: id, UserID: userID, CreatedAt: moment}, ExpiresAt: moment.Add(lifetime)}, nil
}

func sessionLifetime(ctx context.Context, tx *sql.Tx) (time.Duration, error) {
	var row SettingRow
	err := tx.QueryRowContext(ctx, `SELECT value, value_type FROM settings WHERE key = 'session_max_age_days'`).Scan(&row.Value, &row.Type)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return 0, Classify(err)
	}
	row.Found = err == nil
	days, err := integerSetting(row, 30)
	if err != nil || days < 0 || days > MaxSessionAgeDays {
		return 0, errors.Join(err, store.ErrUnsupported)
	}
	return time.Duration(days) * 24 * time.Hour, nil
}

func passwordlessIn(ctx context.Context, tx *sql.Tx, environment bool) (bool, error) {
	if environment {
		return true, nil
	}
	var value sql.NullString
	var valueType string
	err := tx.QueryRowContext(ctx, `SELECT value, value_type FROM settings WHERE key = 'auth_disabled'`).Scan(&value, &valueType)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, Classify(err)
	}
	if !value.Valid || value.String == "" {
		return false, nil
	}
	if valueType != "boolean" {
		return false, store.ErrUnsupported
	}
	return !falseValues[value.String], nil
}

func (d *DB) RecordFailedLogin(ctx context.Context, userID int64, ip string, threshold int, lockout time.Duration, clock func() time.Time) error {
	tx, err := d.write.BeginTx(ctx, nil)
	if err != nil {
		return Classify(err)
	}
	defer tx.Rollback()
	if err := fault.Hit(ctx, "failure.locked"); err != nil {
		return err
	}
	now := clock()
	state, found, err := readLockState(ctx, tx, userID)
	if err != nil {
		return Classify(err)
	}
	locked, err := state.locked(now)
	if err != nil {
		return err
	}
	if !found || state.deleted || locked {
		return nil
	}
	stamp := TimestampText(now)
	count := state.failures + 1
	if count >= int64(threshold) {
		_, err = tx.ExecContext(ctx, `UPDATE users SET failed_login_count = ?, last_failed_login_at = ?, last_failed_login_ip = ?, locked_until = ?, updated_at = ? WHERE id = ?`,
			count, stamp, truncated(ip, 64), TimestampText(now.Add(lockout)), stamp, userID)
	} else {
		_, err = tx.ExecContext(ctx, `UPDATE users SET failed_login_count = ?, last_failed_login_at = ?, last_failed_login_ip = ?, updated_at = ? WHERE id = ?`,
			count, stamp, truncated(ip, 64), stamp, userID)
	}
	if err != nil {
		return Classify(err)
	}
	return Classify(tx.Commit())
}

func (d *DB) DeleteSession(ctx context.Context, id, userID int64) error {
	_, err := d.write.ExecContext(ctx, `DELETE FROM sessions WHERE id = ? AND user_id = ?`, id, userID)
	return Classify(err)
}

type SettingRow struct {
	Value sql.NullString
	Type  string
	Found bool
}

func (d *DB) Setting(ctx context.Context, key string) (SettingRow, error) {
	var row SettingRow
	err := d.read.QueryRowContext(ctx, `SELECT value, value_type FROM settings WHERE key = ?`, key).Scan(&row.Value, &row.Type)
	if errors.Is(err, sql.ErrNoRows) {
		return SettingRow{}, nil
	}
	if err != nil {
		return SettingRow{}, Classify(err)
	}
	row.Found = true
	return row, nil
}

var integerText = regexp.MustCompile(`^[+-]?[0-9]{1,9}$`)

func (d *DB) IntegerSetting(ctx context.Context, key string, fallback int) (int, error) {
	row, err := d.Setting(ctx, key)
	if err != nil {
		return 0, err
	}
	return integerSetting(row, fallback)
}

func IntegerSettingValue(row SettingRow, fallback int) (int, error) {
	return integerSetting(row, fallback)
}

func integerSetting(row SettingRow, fallback int) (int, error) {
	if !row.Found || !row.Value.Valid {
		return fallback, nil
	}
	text := strings.TrimSpace(row.Value.String)
	if row.Type != "integer" || !integerText.MatchString(text) {
		return 0, store.ErrUnsupported
	}
	number, err := strconv.Atoi(text)
	if err != nil {
		return 0, store.ErrUnsupported
	}
	return number, nil
}

var falseValues = map[string]bool{"0": true, "f": true, "F": true, "false": true, "FALSE": true, "off": true, "OFF": true}

func (d *DB) BooleanSetting(ctx context.Context, key string, fallback bool) (bool, error) {
	row, err := d.Setting(ctx, key)
	if err != nil {
		return false, err
	}
	if !row.Found || !row.Value.Valid || row.Value.String == "" {
		return fallback, nil
	}
	if row.Type != "boolean" {
		return false, store.ErrUnsupported
	}
	return !falseValues[row.Value.String], nil
}

func (d *DB) HardcoverCatalogAvailable(ctx context.Context, userID int64) (bool, error) {
	enabled, err := d.BooleanSetting(ctx, "hardcover_enabled", true)
	if err != nil || !enabled {
		return false, err
	}
	row, err := d.Setting(ctx, "hardcover_api_token")
	if err != nil {
		return false, err
	}
	if row.Found && row.Value.Valid && row.Type != "string" {
		return false, store.ErrUnsupported
	}
	var configured bool
	err = d.read.QueryRowContext(ctx, `SELECT COALESCE(LENGTH(TRIM(value, ' ' || char(9, 10, 11, 12, 13))) > 0, 0) FROM settings WHERE key = 'hardcover_api_token'`).Scan(&configured)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return false, Classify(err)
	}
	if configured {
		return true, nil
	}
	var status string
	err = d.read.QueryRowContext(ctx, `SELECT status FROM hardcover_connections WHERE user_id = ? LIMIT 1`, userID).Scan(&status)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, Classify(err)
	}
	return status == "active", nil
}

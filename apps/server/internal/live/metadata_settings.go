package live

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"strconv"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/fault"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
)

const (
	OpenLibraryEnabledKey         = "open_library_enabled"
	OpenLibrarySearchLimitKey     = "open_library_search_limit"
	DefaultOpenLibraryEnabled     = true
	DefaultOpenLibrarySearchLimit = 20
	MinSavedSearchLimit           = 1
	MaxSavedSearchLimit           = 1000
	openLibraryCategory           = "open_library"
	longestShownLimitDigits       = 15
)

var (
	ErrSettingsChanged  = errors.New("the settings changed since they were read")
	settingDescriptions = map[string]string{
		OpenLibraryEnabledKey:     "Enable Open Library as a metadata provider",
		OpenLibrarySearchLimitKey: "Maximum number of search results to return",
	}
)

type MetadataSettings struct {
	Enabled     *bool
	SearchLimit *int64
	Revision    string
	Discover    OpenLibrarySettings
	DiscoverErr error
}

type MetadataChange struct {
	Enabled     *bool
	SearchLimit *int64
}

type metadataRows struct {
	enabled SettingRow
	limit   SettingRow
}

func readMetadataRows(ctx context.Context, q rowQuerier) (metadataRows, error) {
	enabled, err := settingIn(ctx, q, OpenLibraryEnabledKey)
	if err != nil {
		return metadataRows{}, err
	}
	limit, err := settingIn(ctx, q, OpenLibrarySearchLimitKey)
	if err != nil {
		return metadataRows{}, err
	}
	return metadataRows{enabled: enabled, limit: limit}, nil
}

func (rows metadataRows) revision() string {
	digest := sha256.New()
	for _, row := range []SettingRow{rows.enabled, rows.limit} {
		digest.Write([]byte(strconv.FormatBool(row.Found) + strconv.FormatBool(row.Value.Valid) + strconv.Quote(row.Type) + strconv.Quote(row.Value.String)))
	}
	return hex.EncodeToString(digest.Sum(nil)[:16])
}

func savedEnabled(row SettingRow) *bool {
	value, err := booleanSettingValue(row, DefaultOpenLibraryEnabled)
	if err != nil {
		return nil
	}
	return &value
}

func savedSearchLimit(row SettingRow) *int64 {
	if !row.Found || !row.Value.Valid {
		value := int64(DefaultOpenLibrarySearchLimit)
		return &value
	}
	parsed, err := parseRailsInteger(row)
	if err != nil || len(parsed.digits) > longestShownLimitDigits {
		return nil
	}
	value, _ := strconv.ParseInt("0"+parsed.digits, 10, 64)
	if parsed.negative {
		value = -value
	}
	return &value
}

func project(ctx context.Context, q rowQuerier, rows metadataRows, now time.Time) MetadataSettings {
	settings := MetadataSettings{Enabled: savedEnabled(rows.enabled), SearchLimit: savedSearchLimit(rows.limit), Revision: rows.revision()}
	settings.Discover, settings.DiscoverErr = openLibrarySettingsIn(ctx, q, now)
	return settings
}

func (d *DB) ReadMetadataSettings(ctx context.Context, now time.Time, authorise func(context.Context, *sql.Tx) error) (MetadataSettings, error) {
	tx, err := d.read.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return MetadataSettings{}, Classify(err)
	}
	defer tx.Rollback()
	if err := authorise(ctx, tx); err != nil {
		return MetadataSettings{}, err
	}
	rows, err := readMetadataRows(ctx, tx)
	if err != nil {
		return MetadataSettings{}, err
	}
	settings := project(ctx, tx, rows, now)
	if failedRead(settings.DiscoverErr) {
		return MetadataSettings{}, settings.DiscoverErr
	}
	return settings, nil
}

func (d *DB) SaveMetadataSettings(ctx context.Context, clock func() time.Time, revision string, change MetadataChange, authorise func(context.Context, *sql.Tx) error) (MetadataSettings, error) {
	tx, err := d.write.BeginTx(ctx, nil)
	if err != nil {
		return MetadataSettings{}, Classify(err)
	}
	defer tx.Rollback()
	if err := fault.Hit(ctx, "metadata_settings.locked"); err != nil {
		return MetadataSettings{}, err
	}
	if err := authorise(ctx, tx); err != nil {
		return MetadataSettings{}, err
	}
	now := clock()
	rows, err := readMetadataRows(ctx, tx)
	if err != nil {
		return MetadataSettings{}, err
	}
	if rows.revision() != revision {
		current := project(ctx, tx, rows, now)
		if failedRead(current.DiscoverErr) {
			return MetadataSettings{}, current.DiscoverErr
		}
		return current, ErrSettingsChanged
	}
	stamp := TimestampText(now)
	if wanted := change.Enabled; wanted != nil {
		if saved := savedEnabled(rows.enabled); saved == nil || *saved != *wanted {
			if err := writeSetting(ctx, tx, rows.enabled, OpenLibraryEnabledKey, "boolean", strconv.FormatBool(*wanted), stamp); err != nil {
				return MetadataSettings{}, err
			}
		}
	}
	if wanted := change.SearchLimit; wanted != nil {
		if saved := savedSearchLimit(rows.limit); saved == nil || *saved != *wanted {
			if err := writeSetting(ctx, tx, rows.limit, OpenLibrarySearchLimitKey, "integer", strconv.FormatInt(*wanted, 10), stamp); err != nil {
				return MetadataSettings{}, err
			}
		}
	}
	if rows, err = readMetadataRows(ctx, tx); err != nil {
		return MetadataSettings{}, err
	}
	saved := project(ctx, tx, rows, now)
	if failedRead(saved.DiscoverErr) {
		return MetadataSettings{}, saved.DiscoverErr
	}
	if err := fault.Hit(ctx, "metadata_settings.before-commit"); err != nil {
		return MetadataSettings{}, err
	}
	if err := tx.Commit(); err != nil {
		return MetadataSettings{}, Classify(err)
	}
	return saved, nil
}

func writeSetting(ctx context.Context, tx *sql.Tx, row SettingRow, key, valueType, value, stamp string) error {
	var err error
	if row.Found {
		_, err = tx.ExecContext(ctx, `UPDATE settings SET value = ?, value_type = ?, category = ?, description = ?, updated_at = ? WHERE key = ?`,
			value, valueType, openLibraryCategory, settingDescriptions[key], stamp, key)
	} else {
		_, err = tx.ExecContext(ctx, `INSERT INTO settings (key, value, value_type, category, description, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)`,
			key, value, valueType, openLibraryCategory, settingDescriptions[key], stamp, stamp)
	}
	return Classify(err)
}

func failedRead(err error) bool {
	return err != nil && !errors.Is(err, store.ErrUnsupported) && !errors.Is(err, store.ErrTimestamp)
}

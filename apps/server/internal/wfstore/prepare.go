package wfstore

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/bundle"
	_ "modernc.org/sqlite"
)

func Prepare(ctx context.Context, bundleDir, workdir string) (err error) {
	absolute, err := filepath.Abs(workdir)
	if err != nil {
		return Fail(CodeUsage, err)
	}
	opened, err := bundle.Open(ctx, bundleDir)
	if err != nil {
		return Fail("bundle-refused", err)
	}
	if err := os.Mkdir(absolute, 0o700); err != nil {
		return Fail(CodeUsage, err)
	}
	defer func() {
		if err != nil {
			os.RemoveAll(absolute)
		}
	}()
	if err := os.Chmod(absolute, 0o700); err != nil {
		return Fail(CodeDatabase, err)
	}
	if err := os.Mkdir(filepath.Join(absolute, LocksDir), 0o700); err != nil {
		return Fail(CodeDatabase, err)
	}
	destination := filepath.Join(absolute, DatabaseName)
	if err := copyDatabase(ctx, opened.DatabasePath(), destination); err != nil {
		return err
	}
	token := make([]byte, 16)
	if _, err := rand.Read(token); err != nil {
		return Fail(CodeDatabase, err)
	}
	tokenText := hex.EncodeToString(token)
	if err := installWorkerTables(ctx, destination, tokenText); err != nil {
		return err
	}
	keys := Keys{PrimaryKey: opened.Credentials.Encryption.PrimaryKey, KeyDerivationSalt: opened.Credentials.Encryption.KeyDerivationSalt, LegacySHA1: true}
	if err := writePrivateJSON(filepath.Join(absolute, KeysName), keys); err != nil {
		return err
	}
	return writePrivateJSON(filepath.Join(absolute, MarkerName), Marker{Format: markerFormat, Token: tokenText})
}

func writePrivateJSON(path string, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return Fail(CodeDatabase, err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return Fail(CodeDatabase, err)
	}
	return nil
}

func copyDatabase(ctx context.Context, source, destination string) error {
	query := url.Values{}
	query.Set("mode", "ro")
	query.Set("immutable", "1")
	handle, err := sql.Open("sqlite", (&url.URL{Scheme: "file", Path: source, RawQuery: query.Encode()}).String())
	if err != nil {
		return Fail(CodeDatabase, err)
	}
	defer handle.Close()
	handle.SetMaxOpenConns(1)
	if _, err := handle.ExecContext(ctx, `VACUUM INTO ?`, destination); err != nil {
		return Fail(CodeDatabase, err)
	}
	if err := os.Chmod(destination, 0o600); err != nil {
		return Fail(CodeDatabase, err)
	}
	return nil
}

func installWorkerTables(ctx context.Context, path, token string) error {
	handle, err := sql.Open("sqlite", dataSourceName(path, 5000))
	if err != nil {
		return Fail(CodeDatabase, err)
	}
	defer handle.Close()
	handle.SetMaxOpenConns(1)
	var mode string
	if err := handle.QueryRowContext(ctx, `PRAGMA journal_mode = WAL`).Scan(&mode); err != nil || mode != "wal" {
		return Fail(CodeDatabase, fmt.Errorf("wal not enabled"))
	}
	now := FormatTimestamp(time.Now())
	err = (&Store{db: handle}).transact(ctx, func(tx *sql.Tx) error {
		if _, err := tx.ExecContext(ctx, workerSchema); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO wf_meta (key, value) VALUES ('disposable_token', ?), ('worker_schema', '1')`, token); err != nil {
			return err
		}
		for _, domain := range Domains {
			if _, err := tx.ExecContext(ctx, `INSERT INTO wf_owner (domain) VALUES (?)`, domain); err != nil {
				return err
			}
			if _, err := tx.ExecContext(ctx, `INSERT INTO wf_schedule (workflow, next_due_at) VALUES (?, ?)`, domain, now); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return err
	}
	var verdict string
	if err := handle.QueryRowContext(ctx, `PRAGMA integrity_check`).Scan(&verdict); err != nil || verdict != "ok" {
		return Fail(CodeDatabase, fmt.Errorf("integrity check failed"))
	}
	if _, err := handle.ExecContext(ctx, `PRAGMA wal_checkpoint(TRUNCATE)`); err != nil {
		return Fail(CodeDatabase, err)
	}
	return nil
}

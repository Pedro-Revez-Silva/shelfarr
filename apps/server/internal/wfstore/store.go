package wfstore

import (
	"context"
	"crypto/subtle"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/safeopen"
	_ "modernc.org/sqlite"
)

const (
	DatabaseName = "workflows.sqlite3"
	MarkerName   = "WORKDIR.json"
	KeysName     = "encryption.json"
	LocksDir     = "locks"
	markerFormat = 1
	maxMarker    = 4096
)

type Marker struct {
	Format int    `json:"format"`
	Token  string `json:"token"`
}

type Keys struct {
	PrimaryKey        string `json:"primary_key"`
	KeyDerivationSalt string `json:"key_derivation_salt"`
	LegacySHA1        bool   `json:"legacy_sha1"`
}

type Options struct {
	BusyTimeoutMillis int
}

type Store struct {
	Dir  string
	db   *sql.DB
	keys Keys
}

func dataSourceName(path string, busyMillis int) string {
	query := url.Values{}
	query.Add("_pragma", "foreign_keys(1)")
	query.Add("_pragma", "busy_timeout("+strconv.Itoa(busyMillis)+")")
	query.Add("_pragma", "synchronous(2)")
	query.Set("_txlock", "immediate")
	return (&url.URL{Scheme: "file", Path: path, RawQuery: query.Encode()}).String()
}

func Open(ctx context.Context, dir string, options Options) (*Store, error) {
	absolute, err := filepath.Abs(dir)
	if err != nil {
		return nil, Fail(CodeNotDisposable, err)
	}
	if err := requirePrivateDirectory(absolute); err != nil {
		return nil, err
	}
	var marker Marker
	if err := readSmallJSON(filepath.Join(absolute, MarkerName), &marker); err != nil || marker.Format != markerFormat || marker.Token == "" {
		return nil, ErrNotDisposable
	}
	database := filepath.Join(absolute, DatabaseName)
	if err := checkSQLite(database); err != nil {
		return nil, ErrNotDisposable
	}
	busy := options.BusyTimeoutMillis
	if busy <= 0 {
		busy = 5000
	}
	handle, err := sql.Open("sqlite", dataSourceName(database, busy))
	if err != nil {
		return nil, Fail(CodeDatabase, err)
	}
	handle.SetMaxOpenConns(1)
	opened := &Store{Dir: absolute, db: handle}
	var stored string
	if err := handle.QueryRowContext(ctx, `SELECT value FROM wf_meta WHERE key = 'disposable_token'`).Scan(&stored); err != nil {
		handle.Close()
		if errors.Is(err, sql.ErrNoRows) || isMissingTable(err) {
			return nil, ErrNotDisposable
		}
		return nil, classify(err)
	}
	if subtle.ConstantTimeCompare([]byte(stored), []byte(marker.Token)) != 1 {
		handle.Close()
		return nil, ErrNotDisposable
	}
	if err := readSmallJSON(filepath.Join(absolute, KeysName), &opened.keys); err != nil {
		handle.Close()
		return nil, ErrNotDisposable
	}
	return opened, nil
}

func isMissingTable(err error) bool {
	return err != nil && strings.Contains(err.Error(), "no such table")
}

func requirePrivateDirectory(path string) error {
	info, err := os.Lstat(path)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0o077 != 0 {
		return ErrNotDisposable
	}
	return nil
}

func checkSQLite(path string) error {
	file, err := safeopen.Regular(path)
	if err != nil {
		return err
	}
	defer file.Close()
	header := make([]byte, 16)
	if _, err := io.ReadFull(file, header); err != nil || string(header) != "SQLite format 3\x00" {
		return fmt.Errorf("not sqlite")
	}
	return nil
}

func readSmallJSON(path string, target any) error {
	file, err := safeopen.Regular(path)
	if err != nil {
		return err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maxMarker+1))
	if err != nil || len(data) > maxMarker {
		return fmt.Errorf("unreadable")
	}
	return json.Unmarshal(data, target)
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) DB() *sql.DB { return s.db }

func (s *Store) Keys() Keys { return s.keys }

func (s *Store) transact(ctx context.Context, fn func(tx *sql.Tx) error) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return classify(err)
	}
	defer tx.Rollback()
	if err := fn(tx); err != nil {
		return classify(err)
	}
	if err := tx.Commit(); err != nil {
		return classify(err)
	}
	return nil
}

func (s *Store) Transact(ctx context.Context, fn func(tx *sql.Tx) error) error {
	return s.transact(ctx, fn)
}

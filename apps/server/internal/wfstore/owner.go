package wfstore

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

type Owner struct {
	Domain     string
	Generation int64
	store      *Store
	lock       *os.File
}

func validDomain(domain string) bool {
	for _, known := range Domains {
		if known == domain {
			return true
		}
	}
	return false
}

func (s *Store) Acquire(ctx context.Context, domain string) (*Owner, error) {
	if !validDomain(domain) {
		return nil, Fail(CodeUsage, nil)
	}
	lock, err := s.Hold(domain)
	if err != nil {
		return nil, err
	}
	identity := make([]byte, 8)
	if _, err := rand.Read(identity); err != nil {
		lock.Close()
		return nil, Fail(CodeDatabase, err)
	}
	owner := &Owner{Domain: domain, store: s, lock: lock}
	err = s.transact(ctx, func(tx *sql.Tx) error {
		result, err := tx.ExecContext(ctx, `UPDATE wf_owner SET generation = generation + 1, owner_id = ?, started_at = ? WHERE domain = ?`, hex.EncodeToString(identity), FormatTimestamp(time.Now()), domain)
		if err != nil {
			return err
		}
		if changed, _ := result.RowsAffected(); changed != 1 {
			return fmt.Errorf("owner row missing")
		}
		return tx.QueryRowContext(ctx, `SELECT generation FROM wf_owner WHERE domain = ?`, domain).Scan(&owner.Generation)
	})
	if err != nil {
		lock.Close()
		return nil, err
	}
	return owner, nil
}

func (s *Store) Hold(name string) (*os.File, error) {
	lock, err := os.OpenFile(filepath.Join(s.Dir, LocksDir, name+".lock"), os.O_RDWR|os.O_CREATE|noFollow, 0o600)
	if err != nil {
		return nil, Fail(CodeDatabase, err)
	}
	if err := lockExclusive(lock); err != nil {
		lock.Close()
		if errors.Is(err, errLockHeld) {
			return nil, ErrAlreadyOwned
		}
		return nil, Fail(CodeDatabase, err)
	}
	return lock, nil
}

func (o *Owner) Release() {
	if o.lock != nil {
		o.lock.Close()
		o.lock = nil
	}
}

func (o *Owner) Store() *Store { return o.store }

func (o *Owner) Write(ctx context.Context, fn func(tx *sql.Tx) error) error {
	return o.store.transact(ctx, func(tx *sql.Tx) error {
		var current int64
		if err := tx.QueryRowContext(ctx, `SELECT generation FROM wf_owner WHERE domain = ?`, o.Domain).Scan(&current); err != nil {
			return err
		}
		if current != o.Generation {
			return ErrFenced
		}
		return fn(tx)
	})
}

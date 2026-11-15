package live

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/livetest"
)

func open(t *testing.T, path string) *DB {
	t.Helper()
	database, err := Open(context.Background(), path, Options{BusyTimeout: 200 * time.Millisecond})
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { database.Close() })
	return database
}

func TestOpenRefusesAMissingPathWithoutCreatingIt(t *testing.T) {
	path := filepath.Join(t.TempDir(), "typo.sqlite3")
	if _, err := Open(context.Background(), path, Options{}); !errors.Is(err, ErrNotSQLite) {
		t.Fatalf("got %v", err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("a missing database path was created")
	}
	for _, relative := range []string{"relative.sqlite3", ""} {
		if _, err := Open(context.Background(), relative, Options{}); !errors.Is(err, ErrNotSQLite) {
			t.Fatalf("%q: %v", relative, err)
		}
	}
}

func TestOpenRefusesFilesThatAreNotSQLite(t *testing.T) {
	path := filepath.Join(t.TempDir(), "other.sqlite3")
	if err := os.WriteFile(path, []byte("not a database at all"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(context.Background(), path, Options{}); !errors.Is(err, ErrNotSQLite) {
		t.Fatalf("got %v", err)
	}
	link := filepath.Join(t.TempDir(), "link.sqlite3")
	good := livetest.Create(t)
	if err := os.Symlink(good, link); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(context.Background(), link, Options{}); !errors.Is(err, ErrNotSQLite) {
		t.Fatalf("symbolic link: %v", err)
	}
}

func TestOpenRefusesUnknownSchemas(t *testing.T) {
	newer := livetest.Create(t)
	livetest.Exec(t, newer, `INSERT INTO schema_migrations (version) VALUES ('20991231000000')`)
	if _, err := Open(context.Background(), newer, Options{}); !errors.Is(err, ErrSchemaUnsupported) {
		t.Fatalf("newer revision: %v", err)
	}
	older := livetest.Create(t)
	livetest.Exec(t, older, `DELETE FROM schema_migrations`)
	livetest.Exec(t, older, `INSERT INTO schema_migrations (version) VALUES ('20260101000000')`)
	if _, err := Open(context.Background(), older, Options{}); !errors.Is(err, ErrSchemaUnsupported) {
		t.Fatalf("older revision: %v", err)
	}
	missing := livetest.Create(t)
	livetest.Exec(t, missing, `ALTER TABLE api_tokens DROP COLUMN replaces_api_token_id`)
	if _, err := Open(context.Background(), missing, Options{}); !errors.Is(err, ErrSchemaUnsupported) {
		t.Fatalf("missing column: %v", err)
	}
	empty := filepath.Join(t.TempDir(), "empty.sqlite3")
	livetest.Exec(t, empty, `CREATE TABLE unrelated (id integer)`)
	if _, err := Open(context.Background(), empty, Options{}); !errors.Is(err, ErrSchemaUnsupported) {
		t.Fatalf("unrelated database: %v", err)
	}
}

func TestReadsHonourAnActiveWalThatIsNotCheckpointed(t *testing.T) {
	path := livetest.Create(t)
	writer, err := sql.Open("sqlite", "file:"+path)
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Close()
	writer.SetMaxOpenConns(1)
	for _, statement := range []string{`PRAGMA journal_mode=WAL`, `PRAGMA wal_autocheckpoint=0`, `INSERT INTO settings (key, value) VALUES ('ebook_output_path', '/library')`} {
		if _, err := writer.Exec(statement); err != nil {
			t.Fatal(err)
		}
	}
	if info, err := os.Stat(path + "-wal"); err != nil || info.Size() == 0 {
		t.Fatalf("the test needs live WAL content: %v", err)
	}
	database := open(t, path)
	value, present, err := database.StringSetting(context.Background(), "ebook_output_path")
	if err != nil || !present || value != "/library" {
		t.Fatalf("a committed WAL row was not read: %q %v %v", value, present, err)
	}
	if _, err := writer.Exec(`UPDATE settings SET value = '/changed' WHERE key = 'ebook_output_path'`); err != nil {
		t.Fatal(err)
	}
	if value, _, _ := database.StringSetting(context.Background(), "ebook_output_path"); value != "/changed" {
		t.Fatalf("a later commit was not visible: %q", value)
	}
}

func TestSettingsOfAnotherTypeAreRefusedNotGuessed(t *testing.T) {
	path := livetest.Create(t)
	livetest.Exec(t, path, `INSERT INTO settings (key, value, value_type) VALUES ('ebook_output_path', '1', 'integer')`)
	database := open(t, path)
	if _, _, err := database.StringSetting(context.Background(), "ebook_output_path"); err == nil {
		t.Fatal("an integer setting was read as a string")
	}
}

func TestReadsAreCancellable(t *testing.T) {
	path := livetest.Create(t)
	database := open(t, path)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := database.UserByID(ctx, 1); !errors.Is(err, context.Canceled) {
		t.Fatalf("got %v", err)
	}
}

func TestBusyWritersAreReportedAsBusyNotAsMissing(t *testing.T) {
	path := livetest.Create(t)
	livetest.Exec(t, path, `INSERT INTO api_tokens (id, token_digest) VALUES (1, 'digest')`)
	database := open(t, path)
	holder, err := sql.Open("sqlite", "file:"+path+"?_txlock=immediate")
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
	if err := database.TouchToken(context.Background(), 1, time.Now()); !errors.Is(err, ErrBusy) {
		t.Fatalf("got %v", err)
	}
}

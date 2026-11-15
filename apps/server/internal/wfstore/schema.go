package wfstore

const workerSchema = `
CREATE TABLE wf_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
) STRICT;

CREATE TABLE wf_owner (
  domain TEXT PRIMARY KEY CHECK (domain IN ('inventory', 'downloads')),
  generation INTEGER NOT NULL DEFAULT 0,
  owner_id TEXT,
  started_at TEXT
) STRICT;

CREATE TABLE wf_schedule (
  workflow TEXT PRIMARY KEY CHECK (workflow IN ('inventory', 'downloads')),
  state TEXT NOT NULL DEFAULT 'enabled' CHECK (state IN ('enabled', 'cancelled')),
  next_due_at TEXT NOT NULL,
  control_seq INTEGER NOT NULL DEFAULT 0,
  cancel_epoch INTEGER NOT NULL DEFAULT 0,
  last_outcome TEXT
) STRICT;

CREATE TABLE wf_inventory_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL DEFAULT 'library' CHECK (kind = 'library'),
  generation INTEGER NOT NULL,
  cancel_epoch INTEGER NOT NULL,
  platform TEXT NOT NULL,
  scope_fingerprint TEXT NOT NULL,
  snapshot_at TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('fetching', 'published', 'cancelled', 'abandoned')),
  outcome TEXT,
  admitted_at TEXT NOT NULL,
  finished_at TEXT
) STRICT;
CREATE UNIQUE INDEX wf_inventory_one_active ON wf_inventory_runs (kind) WHERE state = 'fetching';

CREATE TABLE wf_inventory_libraries (
  run_id INTEGER NOT NULL REFERENCES wf_inventory_runs (id) ON DELETE CASCADE,
  library_id TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('pending', 'staged', 'empty', 'failed')),
  item_count INTEGER NOT NULL DEFAULT 0,
  error_code TEXT,
  PRIMARY KEY (run_id, library_id)
) STRICT, WITHOUT ROWID;

CREATE TABLE wf_inventory_stage (
  run_id INTEGER NOT NULL,
  library_id TEXT NOT NULL,
  audiobookshelf_id TEXT NOT NULL,
  title TEXT,
  subtitle TEXT,
  author TEXT,
  narrator TEXT,
  series TEXT,
  series_position TEXT,
  publisher TEXT,
  language TEXT,
  description TEXT,
  isbn TEXT,
  asin TEXT,
  published_year INTEGER,
  missing INTEGER NOT NULL,
  PRIMARY KEY (run_id, library_id, audiobookshelf_id),
  FOREIGN KEY (run_id, library_id) REFERENCES wf_inventory_libraries (run_id, library_id) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;

CREATE TABLE wf_download_state (
  download_id INTEGER PRIMARY KEY,
  token TEXT NOT NULL,
  observed_at TEXT,
  error_code TEXT,
  blocked_code TEXT
) STRICT;

CREATE TABLE wf_postprocess_handoffs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  download_id INTEGER NOT NULL UNIQUE,
  request_id INTEGER NOT NULL,
  idempotency_key TEXT NOT NULL UNIQUE,
  download_path TEXT,
  state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'delivered')),
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TEXT NOT NULL,
  last_error_code TEXT,
  created_at TEXT NOT NULL,
  delivered_at TEXT
) STRICT;
CREATE INDEX wf_handoffs_pending ON wf_postprocess_handoffs (next_attempt_at) WHERE state = 'pending';
`

var Domains = []string{"inventory", "downloads"}

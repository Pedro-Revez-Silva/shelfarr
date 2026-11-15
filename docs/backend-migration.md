# Go backend migration

Status: **M0 and M1, experimental and unreachable proofs.** Rails remains the only implementation that
serves Shelfarr. Nothing in these slices is routed, packaged, started by the container, or reachable
from the running application. M1 (see `M1: durable workflows`) adds a runnable Go executable for library
inventory sync and download monitoring that works only on a disposable copy of a fixture database. It adds a command-line checker that reads isolated fixture bundles
and a producer that creates those bundles from the real Rails code. The producer has two modes:
`current-schema` (the default) and `stable-upgrade`, which proves that a synthetic primary database
with the schema of the released `v2026.11.05.1` survives the shipped migrations and is readable by
the Go checker (see `Stable primary-database upgrade proof`). That proof is not a volume upgrade.

## Purpose

Before production ownership of any write domain moves to Go, prove that a Go program can read what
Rails wrote and give the answers Rails gives, for the contracts that cannot be re-derived later:

| Area | Why it is identity-sensitive |
| --- | --- |
| Account passwords | Existing bcrypt digests must keep verifying. |
| Encrypted fields | Existing Active Record Encryption envelopes must stay readable with the same keys. |
| Library asset identity | Asset IDs are stored in saved places, offline downloads and native apps. |
| Consumer read shapes | Publications, progress and `/me` are what installed clients render. |
| Account isolation | One account must never see another account's progress or status. |

Later waves (see `Out of scope`) cover durable work, packaging, upgrade and rollback, and the
TypeScript client.

## Out of scope for M0

M0 does **not** claim HTTP, authentication or consumer-API parity. These stay Rails-only and are
listed as explicit gaps in every report:

- catalogue pagination and cursors (a library larger than one page is refused, not guessed);
- token adoption (`replaces_api_token_id`) and `last_used_at` side effects (such tokens are refused);
- Kobo, transfer grants, read-along, comic and PDF assets, reference-import symbolic links;
- every write path, queue, scheduler and the full stable-volume upgrade and rollback: queue, cable
  and cache databases, queued Ruby jobs, key files, packaging (see `Gaps`).

## Tool and dependency choices

| Choice | Version | Reason |
| --- | --- | --- |
| Go toolchain | 1.27.4 (released 2026-11-10, security fixes to the `go` command, compiler, linker and `net/http`) | The newest patched release at the time of writing; `go.mod` pins `go 1.27.4`. |
| SQLite driver | `modernc.org/sqlite` v1.62.0 | Pure Go, so `CGO_ENABLED=0` cross-builds for `linux/amd64` and `linux/arm64` need no C toolchain. It is actively maintained and supports URI filenames, which the read-only open relies on. |
| bcrypt | `golang.org/x/crypto` v0.59.0 `bcrypt` | The maintained Go implementation; accepts `$2a$` digests produced by Ruby's `bcrypt` gem. |
| Key derivation and AEAD | standard library `crypto/pbkdf2`, `crypto/aes`, `crypto/cipher` | No dependency needed; `crypto/pbkdf2` is in the standard library since Go 1.24. |

The driver is a reversible choice. If a measured limit appears (read throughput under contention,
memory), `mattn/go-sqlite3`-style cgo drivers can replace it behind `internal/store` without touching
the other packages.

## Layout

```
apps/server/                Go module (not built, shipped or referenced by the Rails image)
  cmd/shelfarr-compat/      the compat-check command
  internal/bundle/          fixture bundle loading, size limits, integrity, snapshots
  internal/store/           read-only SQLite access and the stored timestamp format
  internal/assetid/         exact Consumer::LibraryAssets identity
  internal/arcrypt/         Active Record Encryption envelope reader
  internal/account/         bcrypt, bearer tokens, scopes
  internal/library/         library roots, directory walking and asset listing
  internal/consumer/        read projection of /me, the library list and one publication
  internal/compat/          the checks and the report
  cmd/shelfarr-workflows/   the experimental durable workflow executable (M1)
  internal/wfstore/         disposable-copy preparation, fenced writes, owner lock, schedule (M1)
  internal/abs/             Audiobookshelf HTTP adapter and metadata extraction (M1)
  internal/inventory/       library inventory workflow (M1)
  internal/qbit/            qBittorrent HTTP adapter (M1)
  internal/monitor/         download monitor and completion handoff (M1)
  internal/netguard/        loopback-only HTTP client and bounded reads (M1)
  internal/fault/           failpoints, compiled only with -tags faultinject (M1)
  e2e/                      executable tests, corrupted-bundle controls and mutants (build tag e2e)
  e2e/workflows/            executable fault suite and mutants for the M1 workflows (build tag e2e)
tools/migration/            independent Rails fixture producer and the verify scripts
  verify-workflows            the single entry point for the M1 slice
  abs_extraction_oracle.rb    runs the real Rails Audiobookshelf extraction over a corpus
  lib/release_source.rb       pinned release objects read from local Git history
  lib/released_records.rb     synthetic records written into the released schema
  lib/database_snapshot.rb    type-exact snapshot of any SQLite file, read immutably
  lib/upgrade_verification.rb the preservation and schema assertions
  lib/stable_upgrade.rb       build, seal, migrate and verify the released database
  lib/stable_upgrade_builder.rb  the stable-upgrade bundle, built on the current-schema builder
docs/backend-migration.md   this document
```

## Fixture bundle contract, format 1

A bundle is a private directory created by `tools/migration/produce_fixture.rb`. It never lives in
the repository and holds only synthetic accounts, books, media, progress and keys.

```
<bundle>/
  manifest.json
  db/primary.sqlite3                fully checkpointed, no -wal, -shm or -journal
  expected/identity-vectors.json    Rails identity for synthetic stat tuples
  expected/library-assets.json      Rails asset listing and recorded stat for every book
  expected/accounts.json            Rails password verdicts per candidate label
  expected/encryption.json          Rails plaintext digest per encrypted column, tampered envelopes
  expected/responses.json           real Rails responses for /me, /library and /library/:id
  secrets/credentials.json          0600 in a 0700 directory: keys, passwords, bearer tokens
  media/ and media-outside/         library trees (declared by absolute path, see below)
```

`manifest.json` records `fixture_format`, `origin`, the producer's Ruby, Rails and repository head,
the schema revision (the highest `schema_migrations.version`), the database path, the absolute
`media_root`, `coverage` (case names, their digest, and `gaps`), a SHA-256 and size for every file
under `db/`, `expected/` and `secrets/`, and `external_trees`.

`external_trees` declares the media directories by **absolute path**, with the hash and size of
every regular file and the target of every symbolic link. Asset identity embeds absolute paths and
change times, so media cannot be copied: a variant bundle may copy `db/`, `expected/` and
`secrets/` and rewrite hashes while still pointing at the original media.

### What the checker enforces on a bundle

- every file is a regular file listed in the manifest with the right size and SHA-256, and no other
  file (including any `-wal`, `-shm` or `-journal` sidecar) exists in the bundle or its media trees;
- no symbolic link exists inside the bundle, and each media symbolic link has its recorded target;
- `secrets/` is not accessible to group or others;
- every file is opened without following symbolic links and without blocking, then required to be a
  regular file, so a FIFO, device or symbolic link where a file belongs is refused immediately;
- limits while reading: manifest 1 MiB, expected documents 16 MiB, credentials 64 KiB, database
  256 MiB, any hashed file 512 MiB, 4096 entries per tree, an encrypted envelope 1 MiB, a decrypted
  or inflated value 1 MiB, a cooperative deadline of 60 seconds by default (10 minutes at most);
- JSON documents reject unknown fields and any data after the first value (including a stray closing
  bracket);
- bcrypt digests with a cost above 14 are refused before any work (`bcrypt-cost-unsupported`).
  The cooperative deadline is checked between password, asset and response cases. Synchronous
  bcrypt, cryptographic work and regular-file I/O are not forcibly interrupted, so a deadline
  is not a hard wall-clock guarantee.

## Producer isolation

Dotenv loads only the private bundle's temporary `.env` path. Checkout `.env`, `.env.test`
and `.env.test.local` files are never loaded. The isolation probe blocks protected file reads
outside the bundle before they can return any bytes.

`tools/migration/produce_fixture.rb --out ABSOLUTE_NEW_DIRECTORY` boots the real Rails application
in the existing `test` environment, with everything redirected before boot:

- `--out` must be absolute, not exist, and its parent must resolve outside the repository;
- it refuses to run when `RAILS_ENV` is not `test`, or when the environment carries `DATABASE_URL`,
  any `*_DATABASE_URL`, `SECRET_KEY_BASE*`, `RAILS_MASTER_KEY`, `ACTIVE_RECORD_ENCRYPTION_*`,
  `SHELFARR_*`, any `*_FILE`, `KOBO_KEPUB_CACHE_PATH` or `RAILS_RELATIVE_URL_ROOT`; messages name the
  variable, never its value;
- the primary, queue and cable databases, the Rails log, `TMPDIR`, the Bootsnap cache and
  `XDG_CACHE_HOME` all point inside `--out`; after boot the resolved database paths are checked
  against that list;
- `SECRET_KEY_BASE` is a random synthetic value, so Rails does not write `tmp/local_secret.txt`;
- `config.credentials.content_path` and `key_path` are redirected to files that do not exist under
  `--out` before the application initialises (Active Record's railtie evaluates
  `Rails.application.credentials` during boot), and the producer refuses to continue unless both
  resolve inside `--out`; a test boots the real producer with every file read of credentials, key
  files, `storage/` and SQLite databases trapped and requires none;
- it never reads `storage/`, existing databases, key files or credentials, and never runs
  migrations or dumps `db/schema.rb`; it loads `db/schema.rb` into the isolated database;
- Active Record Encryption keys are generated per bundle and exist only in
  `secrets/credentials.json`; the same generated keys configure the real encryption layer, SHA-256
  derivation as production, plus the SHA-1 previous scheme Rails supports for legacy values;
- bcrypt digests use the production cost (12) rather than the test-environment minimum;
- responses are captured by sending real HTTP requests through the Rails stack, so the serializers,
  authentication and scope checks are the oracle, not a second implementation.

`tools/migration/verify` runs the whole proof and fails if any repository file changed while it ran.

## The checker

```
shelfarr-compat compat-check --bundle DIRECTORY [--timeout 60s] [--legacy-sha1]
```

Exit codes: `0` every check passed, `1` a check failed (the JSON report is printed), `2` the
bundle or arguments were refused (nothing but a one-line reason on stderr). The report lists check
names, case counts and index labels such as `column[2]:decryption` or `response[17]:body-mismatch`
(the index is the position in the corresponding `expected/*.json` list). Nothing taken from a bundle
(file names, tree names, case names) is echoed, so a hostile bundle cannot smuggle text into the
output. It never prints plaintext, keys, passwords, tokens, credential digests, bundle paths or media paths.

The unpublished development report previously copied `origin`, `schema_revision`,
`coverage_digest` and gap descriptions from the manifest. The public report now omits those
three provenance fields and supplies its own fixed gap identifiers, statuses and descriptions.
Only `fixture_format`, `passed`, `checks` and checker-owned `gaps` are serialized. Provenance
and coverage metadata remain in the private manifest. Existing repository callers consume
the result and check list; the fixture bundle format is unchanged.

`--legacy-sha1` is explicit. Active Record derives keys with SHA-256 under the application's
`load_defaults 8.1`; legacy SHA-1 derivation is only readable where an instance still has that
previous scheme. Without the flag a SHA-1 envelope fails with `decryption`.

The database opens with `mode=ro&immutable=1` and `query_only`, so SQLite creates no journal or
lock file. `immutable` ignores a WAL, so the bundle must be fully checkpointed; the producer
guarantees that and the checker refuses a bundle with sidecars. The run snapshots every bundle and
media entry (kind, mode, size, mtime, ctime, inode and SHA-256) before and after and fails on any
difference or sidecar.

## Compatibility contract: Rails before, Go after

### Asset identity

Rails `Consumer::LibraryAssets#identity`:

```
SHA256 hex of [book.id, book.file_path, canonical_path, stat.dev, stat.ino, stat.size,
               stat.mtime.to_r, stat.ctime.to_r].join("\0")
```

Go `assetid.ID` is byte-for-byte the same:

| Field | Rule |
| --- | --- |
| `book.id`, `size` | decimal |
| `book.file_path` | the stored string, unchanged (it may differ from the canonical path) |
| canonical path | `Pathname#expand_path.realpath` of the stored path |
| `dev`, `ino` | **unsigned** 64-bit decimal; values at or above 2^63 stay unsigned, never wrapped |
| `mtime`, `ctime` | exact `Rational#to_s`: reduced `numerator/denominator`, always with a denominator (`5/1`, `-3/2`, `1/3`), built from seconds and nanoseconds with floor semantics before 1970 |
| separator | NUL (`\0`) |

The checker verifies 13 vectors produced by calling the real private Rails method with synthetic stat
values (whole seconds, nanosecond fractions, pre-epoch, thirds, zero, device/inode at 2^63 and
2^64-1, zero and large sizes, maximum book id, differing stored/canonical paths, Unicode, spaces and
newlines), and the ID of every real file in the bundle against the live `stat` of that file.

Asset listing follows `Consumer::LibraryAssets` for the default `epub` reader format: audio
extensions (`mp3 m4b m4a aac ogg opus flac wav`) for audiobooks and `epub`/`kepub` (reported as
`epub`, `application/epub+zip`) for ebooks, extension matching without case; a directory is walked
with the same limits (depth 8, 2000 entries, hidden names skipped); natural ordering compares the
lower-cased full path split into text and unsigned integer parts; a missing file, a file outside
every configured output root, a book that is the library root, an EPUB over 250 MiB or a non-regular
entry makes the publication list no assets; configured roots are `audiobook_output_path`,
`ebook_output_path` and `comicbook_output_path`, canonicalised, `/` excluded, longest containing root
wins, and containment never matches a sibling that merely shares a prefix.

Not modelled and **refused** (never silently approximated): symbolic-link library entries, relative
or `~` or leading-`//` stored paths, roots that are not explicit string settings, and non-UTF-8 names
in cover or description columns.

### Passwords

Rails `has_secure_password` stores `bcrypt` digests. Go `account.PasswordMatches` calls
`bcrypt.CompareHashAndPassword` with the candidate bytes unchanged. The bundle carries candidates
for the correct value, another random value, the empty string, a trailing space, swapped case and
the Unicode NFD form of a password containing combining characters; each verdict must equal Rails'
`authenticate`.

### Encrypted fields

Rails `ActiveRecord::Encryption` envelope: JSON `{"p": base64 payload, "h": headers}`; headers `iv`
(12 bytes), `at` (16 byte tag), optional `c` (payload is a zlib stream), optional `e` (encoding label
of the original Ruby string), optional `i`/`k` (key references). Keys are
`PBKDF2-HMAC(digest, primary_key, key_derivation_salt, 65536 iterations, 32 bytes)` with SHA-256, plus
SHA-1 when `--legacy-sha1` is given; AES-256-GCM with empty associated data.

Go `arcrypt.Decryptor` matches that, and additionally:

- decodes base64 strictly (no line breaks), as `Base64.strict_decode64` does;
- accepts `e` only for labels that leave the bytes unchanged (`UTF-8`, `US-ASCII`, `ASCII-8BIT`,
  `BINARY`), because Rails really writes `US-ASCII` for strings such as `SecureRandom.alphanumeric`;
  other labels and any `k` header are refused as `unsupported`;
- bounds the envelope (1 MiB) and the decrypted or inflated value (1 MiB) while reading, so a
  decompression bomb fails as `limit` rather than allocating;
- returns coarse error kinds only (`decryption`, `decompression`, `limit`, `unsupported`,
  `configuration`) carrying no input, key or plaintext.

The bundle covers `users.otp_secret`, `users.backup_codes`, `download_clients.password` and
`download_clients.api_key`: short and long (compressed) values, Unicode, an empty string, a `NULL`
column, current-scheme and legacy-scheme rows, and fourteen tampered envelopes whose Rails outcome was
recorded (bit flips in payload, nonce and tag, missing and short tags, truncation, forced and removed
compression flags, invalid and newline-bearing base64, truncated JSON, plain text, missing payload and
an empty string).

### Consumer read projection

`consumer.Service.Respond` answers `GET /api/consumer/v1/me`, `GET /api/consumer/v1/library` (one
page, default reader formats) and `GET /api/consumer/v1/library/:id` from the database and media, as
a pure function. It is not an HTTP server and is not exposed.

Behaviours reproduced and compared with real Rails responses (JSON semantics: key order and number
notation are ignored; strings, `null` versus absent versus empty, ordering, nesting are compared):

- bearer parsing (`Bearer`, case-insensitive scheme, remainder after the whitespace run), SHA-256
  token digest lookup, revoked, expired (`expires_at > now`), deleted-user and orphan tokens as
  `401` with an empty body, `private, no-store` cache control on every answer;
- scope normalisation (`[,\s]+` split, de-duplicated), privileged scopes visible only to
  administrators, `library:read` required (`403` with `error` and `required_scope`);
- `/me`: `id` as a string, `name`, `username`, visible scopes;
- publications: `id` as a string, `book_type` (`audiobook` or `ebook`), description cut to 20,000 code
  points (not bytes), `cover_url` only for an `https` URL without credentials, assets with
  `content_url`, `progress` with `observed_at` and `updated_at` formatted `YYYY-MM-DDTHH:MM:SS.mmmZ`
  by **truncating** to milliseconds (including before 1970), unknown observation time as `null`,
  `position_seconds` `null` versus `0`, the stored locator JSON, and `reading_status` precedence
  (explicit state, else `in_progress` when a place exists, else `unread`);
- acquired-book scope (`file_path` present and non-blank), default formats (comic records excluded and
  `404` by id), unknown and malformed ids as `404` (status only; the framework error page is not
  compared);
- per-account scoping of progress and reading state, checked with two accounts reading the same books.

## Stable primary-database upgrade proof

`tools/migration/produce_fixture.rb --out ABSOLUTE_NEW_DIRECTORY --mode stable-upgrade` proves one
thing: **synthetic records written into the released `v2026.11.05.1` primary schema are preserved by the
actual current Rails migrations, and the upgraded database is readable by the Go checker.** It does
not prove a stable-volume upgrade or rollback, and no report may describe it as one. The default
`current-schema` mode is unchanged and independent.

### Release identity

The release is pinned by Git object identity in `tools/migration/lib/release_source.rb`, not by a tag
name: commit `96333c6674a21701f7229c1a51038dc3b117c1a0` (tag `v2026.11.05.1`), tree
`c9a17fcfa4591898ac47a299e8fab09ecd2c15c1`, `db/schema.rb` blob
`ac0c524fecaf0552a2721d1817c792448fd338f8`, `db/migrate` tree
`65596153c4eb018fcc57fa563302af6ce94c52f4` (100 migrations, schema revision `20261102120000`). The
objects are read from the repository's own history with `git` under a scrubbed environment with `GIT_NO_LAZY_FETCH` and
`GIT_NO_REPLACE_OBJECTS`, and the schema bytes are re-hashed to the pinned blob before they are loaded. The tool never fetches; a missing object is a refusal. No release code is
executed except its `db/schema.rb`, whose blob identity is verified first. The tool also requires every
shipped release migration in the checkout to be byte-identical (Git blob identity) to the release and
every other migration to be newer than the release schema.

### Flow

1. The released `db/schema.rb` is loaded into the isolated primary database. It must dump back to the
   released text, `schema_migrations` must equal the release's 100 versions, and no consumer table may
   exist. Today's schema is never loaded.
2. `ReleasedRecords` writes synthetic rows into the released tables by explicit original IDs: five users
   (two roles, soft deletion, bcrypt cost-12 digests, one-time-password secrets in the current and the
   legacy SHA-1 Active Record Encryption scheme, OIDC identity, lockout), legacy API tokens (revoked,
   expired, ownerless, minimal), settings (paths and synthetic sensitive values, with `NULL` and empty
   values), twelve books (file paths, symbolic-link path, blank and missing paths, Unicode), requests,
   downloads (filesystem identities above 2^63 stored as text, 5 GB and 2^62 sizes), uploads, download
   clients, acquisition providers, Hardcover and owned-library connections with encrypted fields, and one
   full and one sparse record in every other released table. Identifiers 99 (books) and 50 (requests)
   are created and deleted so the autoincrement counters are ahead of the highest row.
3. The database is checkpointed and closed, a type-exact snapshot is taken, and a **sealed source copy**
   (`db/released-source.sqlite3`, mode 0440) is made with the SQLite backup API. Its snapshot must equal
   the working database's.
4. The shipped migrations run one at a time with `MigrationContext#up` inside the private database, under
   an enforced wall-clock deadline (120 seconds by default), and never dump `db/schema.rb`.
5. The upgraded database is dumped and must equal the checkout's `db/schema.rb`, then compared with the
   source (below), then probed for required defaults, then migrated a second time, which must change
   nothing.
6. The same builder that serves the default mode records Rails' own answers for the preserved and the new
   records, and the Go checker reads the upgraded database.

### Assertions on the data

`UpgradeVerification` compares the source snapshot with the upgraded database using SQLite's own types
(`typeof`), not Ruby's: integers, floats by IEEE bit pattern, text, blobs by bytes and `NULL`.

| Invariant | Detail |
| --- | --- |
| Rows | Every released row is present with every released column identical (ID, digest, ciphertext, timestamps, integer enums, paths, identity text, settings); no row is added to a released table. |
| Definitions | A released table's definition, columns, indexes and foreign keys are unchanged, except the intentional additions below. |
| Schema | The tables are exactly the released tables plus the 13 tables added by the migrations; the dump equals the checkout's `db/schema.rb`. |
| Versions | `schema_migrations` is the 100 released versions plus the 17 new ones, nothing lost. |
| Counters | `sqlite_sequence` is unchanged, so a new row never reuses a released identifier. |
| New tables | Empty after the migrations. |
| Defaults | New rows get the migrations' defaults (`api_tokens.scopes`, `kobo_devices.store_coexistence`, `consumer_progresses.version`, `consumer_reading_states.status`). |
| Database | `integrity_check` is `ok` and `user_version` is unchanged. |

**Intentional changes to released tables, each asserted:**

- `api_tokens` gains `issued_via`, `replaces_api_token_id` and `connection_key` (migrations
  `20261109002000`, `20261109003000`) with no default; every released token must hold `NULL` in all three.
- `api_tokens` gains `index_api_tokens_on_user_id_and_connection_key` and `books` gains
  `index_books_on_consumer_title` (`20261107141000`); no row changes.

The data statements inside three shipped migrations (`20261109001200`, `20261109030000`,
`20261109220000`) act on tables that do not exist in the release, so they run over empty tables here;
their row transformations are **not** exercised by released data.

### Preserved records and post-upgrade cases

Evidence keeps them apart. Records written before the upgrade are the preserved prior records. After the
verification, the builder adds new consumer cases through the real Rails models: device-approved tokens,
reading progress and reading states for the preserved users and books. The private
`expected/stable-upgrade.json` lists the rows added after verification and every preserved row that
real Rails changed afterwards. The only such change is `last_used_at` and `updated_at` on legacy tokens that
Rails authenticated while recording responses; nothing else may change.

### Failure and interruption

A migration failure, an exhausted deadline or a verification failure ends the producer with one line
naming the stage (`release`, `source`, `migration`, `verification`, `repeat`), the failing version and the
exception class, and no manifest (so the checker refuses the directory), and no values. Failures the producer
detects exit with code 3. The deadline is enforced from outside the Ruby process: a watchdog shell, started
before the first migration and stopped after the last, measures the budget at full precision on the
monotonic `/proc/uptime` clock (Linux; polled every 0.1 second, so it fires within about 0.15 second of the
budget), prints `upgrade failed: migration: deadline of N
seconds exceeded` and sends `SIGKILL` to the producer, so a migration that never returns is bounded and the
exit status is the signal. It exits by itself when the producer disappears. SQLite DDL is transactional, so
the database is left for SQLite to recover and the interrupted migration rolls back; the tests prove it for
a real conflict (an existing `kobo_account_shares` table makes `20261109020000` fail: the 12 earlier
versions stay, the failing migration leaves no column behind, released rows are untouched, and removing the
conflict lets the remaining 5 apply), for a process killed with `SIGKILL` at the `CREATE TABLE "kobo_tags"`
statement of the last migration, and for the same statement blocking forever until the watchdog fires (in
both, 16 of the 17 new versions are recorded and the last is applied on resume). The deadline is also
checked in process before every migration and after the last one, so a migration that returns just late
is a failure and not a success; a budget that is not a finite number is refused.

### Evidence kept in the bundle

`expected/stable-upgrade.json` (private, never printed) records the release identity, the schema
revisions and dump digests, the migrations applied, the sealed source digest, per-table preserved counts
and the post-upgrade differences. The CLI's public report is unchanged: it still carries only checker-owned
fields and the fixed gap list.

## Coverage

`manifest.coverage.cases` lists every case and its digest stays in the private manifest. The current bundle
has 13 identity vectors, 12 library books (including indirect path, Unicode NFD names, hidden and
non-media files, natural ordering, outside-root, missing, library-root, blank and comic cases), 18
password verdicts, 8 encrypted columns, 15 tampered envelopes and 44 consumer responses plus one
refusal (111 cases).

## M1: durable workflows

`shelfarr-workflows` is a bounded experimental executable in the existing `apps/server` module. It runs two
crash-recoverable workflows over SQLite state: **library inventory synchronisation** against an
Audiobookshelf-compatible HTTP API and **download monitoring** against qBittorrent. It is not routed,
packaged, started by the container or reachable from Rails, and it never touches a Rails queue. It replaces
nothing: Rails still performs both jobs in production.

### Disposable copies only

```
shelfarr-workflows prepare --bundle DIR --workdir NEW_DIR
shelfarr-workflows run --workdir DIR [--workflows inventory,downloads] [--once] [options]
shelfarr-workflows trigger|cancel|resume --workdir DIR --workflow inventory|downloads
shelfarr-workflows status --workdir DIR
```

There is no database-path flag and no default path. `prepare` opens an M0 fixture bundle with the M0 verifier,
copies `db/primary.sqlite3` with `VACUUM INTO` from an immutable read-only handle, switches the copy to WAL, adds
the worker tables, and writes a private marker (`WORKDIR.json`, random token, also stored in `wf_meta`) and the
bundle's synthetic key material (`encryption.json`, mode 0600). Every other command refuses a directory whose
mode, marker or database token does not match, without creating a sidecar file. No environment variable, dotenv
file or credential file is read; configuration comes from the copy's own `settings` and `download_clients` rows,
decrypted with the copied synthetic keys. All HTTP goes through one client that refuses non-loopback addresses,
ignores proxy variables and refuses redirects. Output is structured JSON lines of fixed codes: fixture-controlled
text, URLs, paths, credentials and response bodies are never printed.

Exit codes: `0` completed, `1` a recoverable failure was reported, `2` usage, `3` the domain already has an owner,
`4` this process was superseded (fenced), `5` the directory is not a prepared disposable copy, `6` `prepare` refused.

### Ownership and persisted authority

Two write domains, `inventory` and `downloads`, each have exactly one owning process, enforced twice: a kernel
`flock` on `locks/<domain>.lock` (released by the kernel on any exit, SIGKILL included) and a fencing generation in
`wf_owner`, incremented at start and checked inside every domain write transaction. A superseded owner's next write
fails and writes nothing; no lease expires, so no owner can publish after losing ownership. `trigger`, `cancel` and
`resume` write only `wf_schedule`, the single persisted clock: one row per workflow with its state
(`enabled`/`cancelled`), next due time and a control counter. A restart or a settings change cannot create a second
chain, a cancelled workflow stays cancelled until `resume`, and a cycle that races a control change does not consume
the new slot.

### Schema (before and after)

Rails tables are unchanged. The copy gains only these worker-owned tables (never shipped as Rails migrations):

| Table | Written by | Purpose |
| --- | --- | --- |
| `wf_meta`, `wf_owner`, `wf_schedule` | prepare, owner, control commands | disposable token, generation per domain, persisted schedule |
| `wf_inventory_runs` | inventory owner | one active run (partial unique index), configuration fingerprint, snapshot time |
| `wf_inventory_libraries`, `wf_inventory_stage` | inventory owner | per-library outcome (`pending`, `staged`, `empty`, `failed`) and validated staged items |
| `wf_download_state` | downloads owner | last error code and durable `blocked` reason per ownership token |
| `wf_postprocess_handoffs` | downloads owner | unique, idempotency-keyed completion handoff (`pending`/`delivered`) |

Existing Rails tables written, and only these columns: `library_items` (inventory; the existing unique key, enum
platform value, `missing` boolean, Rails text timestamps with `synced_at` set to the snapshot time and `created_at`
preserved on update), `downloads` (`progress`, `not_found_count`, `status` to completed, `download_path`,
`updated_at`) and `request_events` (insert on completion). Nothing else in any table changes; the suite compares a
digest of every other table before and after.

### Inventory rules

A run is admitted in one transaction with its schedule slot and configuration fingerprint (platform, server URL,
library-id set or `auto`). Each library is fetched with bounded pagination (`limit`/`page`, a required numeric
`total` that must stay constant, unique ids, no more than `total`, short or empty pages before `total` are
`truncated`, 8 MiB per response, 100,000 items, per-request and per-library deadlines, no redirects). Only a
validated complete snapshot is staged; `empty` is accepted only for page 0 with an explicit `total` of 0.
Publication is one fenced transaction that re-reads the schedule and settings: cancelled or changed configuration
abandons the run and deletes nothing. Otherwise it upserts with Rails' `synced_at` guard, prunes unseen rows of
staged or empty libraries (same guard), and prunes libraries no longer configured only when no library of the run
failed. A failed library is left untouched. A restart continues the same run: staged libraries are not fetched
again, a crash before the publication commit leaves live inventory unchanged and one after it is final.
Metadata extraction (14 fields) is checked against the real Rails extraction over a corpus.

### Download monitoring rules

Per active download (`queued`/`downloading`) and enabled qBittorrent client, bounded by `--concurrency`: only
`200 []` is "not found" (counted up to 3, then durably `blocked`); every other status, transport error, bad JSON,
wrong hash or out-of-range value is a coded error with no change to `downloads`. Every write carries the ownership
token `(id, request, external id, client, selected release)`, so an observation of a cancelled, failed, re-dispatched,
moved or replaced attempt cannot act on it. Completion is one transaction: the status claim, the `request_events`
row and the unique handoff row; the request is not advanced. A separate loop delivers pending handoffs to an optional
loopback `--handoff-url` with an `Idempotency-Key`: delivery is at-least-once (a crash after the consumer replies sends
it again), the local completion is idempotent, and nothing claims exactly-once network effects.

### Practical differences from the Ruby equivalent

No semaphore lease patch, supervisor, cache reservation or successor job chain: ownership is a kernel lock plus a
fencing generation, the clock is one row. Durable intent and the data effect share one SQLite transaction (Solid
Queue's queue database is a separate file). A remote failure is a typed code that cannot flow into code that expects
a list. Not solved by Go: idempotent steps, retry policy and backoff, external at-least-once delivery, the single
SQLite writer, and everything listed below.

### Not ported (explicit gaps)

Real `PostProcessingJob` and media work; the failure branches of `DownloadMonitorJob` (`handle_download_failure!`,
blocklisting and next-candidate selection, stale-dispatch and direct-download timeouts): client-reported failure and
the not-found threshold are recorded as `blocked`, not acted on; download clients other than qBittorrent; library
platforms other than Audiobookshelf (BookOrbit and Grimmory are `platform-unsupported`); post-scan refresh jobs;
settings or client edits through Go; a resumed stale run can re-add an item a newer sync removed (the same behaviour as
the Ruby guard); more than 2000 active downloads per cycle. This is not a production handover, not all-provider parity
and not M2 packaging or volume rollback.

### Verification

```
tools/migration/verify-workflows
```

produces a current-schema and a stable-upgrade bundle with the real Rails code, checks the extraction oracle, runs
`gofmt`, `go vet` (shipped, e2e and fault-injection builds) and `go test -race`, the workflow fault suite against both
bundles with race-instrumented binaries (SIGKILL at every inventory commit boundary and around completion and handoff,
incomplete, empty and erroring inventories, configuration change and cancellation during a fetch, duplicate start,
superseded owner, writer contention, hung peers, shutdown and restart, panics, credential and loopback isolation),
26 mutants of the critical invariants (each must fail an assertion), the unchanged read-only checker on both bundles,
reproducible cross-builds and an untouched-repository check.

## Gaps (recorded in every report)

| Gap | Status |
| --- | --- |
| `stable-volume-upgrade` | **partial.** `--mode stable-upgrade` proves the primary database of `v2026.11.05.1` survives the shipped migrations. The queue, cable and cache databases, queued Ruby jobs, key files, packaging and activity-preserving rollback are M2. The checker's public report still lists this gap as missing, because a volume has not been migrated. |
| `catalogue-pagination` | missing; a list larger than 30 publications is refused. |
| `token-adoption` | missing; replacement tokens are refused. |
| `reference-imports` | missing; symbolic-link library entries are refused. |
| `pdf-cbz-assets` | missing; only the default EPUB and audio listing is covered. |

## Verification

```
tools/migration/verify
```

runs, in order: the Ruby isolation tests, the release resolver and verifier tests, the stable-upgrade
scenarios and RuboCop; two independent fixture productions and two independent stable-upgrade productions
with a check that the repository is untouched; a shape comparison of each pair; `gofmt`, `go vet`, and
`go test -race ./...`; the executable tests in `apps/server/e2e` against the first current-schema bundle and the first upgraded
bundle; the race-instrumented executable against all four bundles; byte-identical `linux/amd64` and `linux/arm64`
cross-builds with `CGO_ENABLED=0`; and a final check that nothing in the repository changed.

Scratch lives under `$TMPDIR` (or `~/.cache/agent-tmp`), never in the repository, and never in a
RAM-backed `/tmp` or `/dev/shm`; the script refuses those and removes its own directory.

### Negative controls

`e2e` proves the checks reject wrong implementations, not only that the right one passes:

- **Corrupted bundles** (24 sealed cases, 8 unsealed or structural cases, plus controls for FIFO and
  symbolic-link manifests, bcrypt cost 31, a 300 ms deadline, hostile labels, and bounds and leakage): wrong key or salt, tampered ciphertext, swapped password digests,
  a revived deleted account, changed progress, progress moved to another account, unknown observation
  time turned into `null`, malformed timestamps, reading status, titles, revoked/expired/widened
  tokens, a cleared adoption pointer, removed or redirected output roots, altered expectations, a
  disagreeing schema revision, truncated, emptied and garbage-header databases; each must fail
  exactly the intended checks (or be refused before any check), and unsealed tampering, sidecars,
  extra files and loose permissions must be refused with no report;
- **Mutants** (44): source mutations of the Go implementation (a different identity separator,
  dropped fractions, signed inode or device, omitted change time, decimal timestamps, stored path
  replaced by the canonical one, SHA-1 primary derivation, ignored compression, unbounded inflation,
  unbounded envelopes, always-on legacy derivation, newline-tolerant base64, any password accepted,
  trimmed passwords, ignored revocation, expiry or deleted accounts, silently ignored adoption,
  skipped scope check, comics listed, byte-truncated descriptions, insecure or credentialed covers,
  lost status precedence, null-to-empty and null-to-zero, unscoped progress or status, a writable
  journal-mode database, a checker that writes a journal, a removed bcrypt cost ceiling, a manifest opened without refusing
  non-regular files, trailing JSON accepted, blank paths counted as acquired, rounded
  timestamps, plain string ordering, prefix-sibling containment, unresolved symbolic links, hidden
  files, case-sensitive extensions and a book at the library root). Each mutant is compiled and run
  against the same bundle as the real build and must produce a different report;
- **Stable-upgrade controls.** In Ruby, against the real migrations and database: loading today's schema over
  the released data, skipping the migrations, an exhausted deadline, a failing migration, a killed process, and
  fifteen tamperings of the upgraded database (changed value, changed SQLite type, swapped password digest,
  truncated ciphertext, changed setting, lost or extra row, reset counter, dropped column or index, a value in
  a new column or table, a lost new table, missing or lost versions) each fail the verifier with the named
  finding. In Go, the same executable and mutants as above run, plus eleven tamperings of the upgraded bundle
  (a released password digest, one-time-password secret, download-client key, book path, output root, deleted
  flag, token digest, token scope or revocation, an unrecorded last migration, or the released database
  presented as upgraded) that must fail exactly the intended checks, and an independent Go comparison of every
  released row in the sealed source with the upgraded database that is itself shown to reject six kinds of loss
  or change.
- **No leakage**: the output of passing, failing and refused runs never contains any secret in
  `credentials.json`, the bundle path, the media path or a decrypted value.

## Rollback

M0 adds files only: `apps/server/`, `tools/migration/`, and this document; the stable-upgrade proof adds
only files under `tools/migration/`, `apps/server/e2e/` and this document. It changes no route,
schema, image, workflow, Docker default or application behaviour. To roll back, revert the commits
that add those paths; nothing else depends on them.

## What the next waves need from this

- M1 (done for the two workflows above) reused `internal/bundle` and the producer for crash, hang, cancellation,
  retry, duplicate-instance and SQLite contention proofs;
- M2 adds the stable and beta volume upgrade and activity-preserving rollback (the `stable-volume-upgrade` gap)
  and the packaged multi-architecture application;
- M3 onward reuse the projection contract, adding the session and CSRF API for the TypeScript client.

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
  internal/admission/       admission of one Open Library ebook request (M1, see Request admission)
  internal/gutenberg/       Project Gutenberg OPDS adapter: bounded fetch, strict parse, same-origin links (M1)
  internal/acquisition/     claim, search and publication of one pending ebook request (M1, see Gutenberg search)
  internal/bookfile/        confined library root, anonymous staging, no-replace publication, EPUB container check (M1)
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
shelfarr-workflows request --workdir DIR --account ID < request.json
shelfarr-workflows search --workdir DIR --request ID [--request-timeout 15s] [--deadline 5m]
shelfarr-workflows download --workdir DIR --request ID --result ID [--request-timeout 15s] [--deadline 10m]
```

There is no database-path flag and no default path. `prepare` opens an M0 fixture bundle with the M0 verifier,
copies `db/primary.sqlite3` with `VACUUM INTO` from an immutable read-only handle, switches the copy to WAL, adds
the worker tables, and writes a private marker (`WORKDIR.json`, random token, also stored in `wf_meta`) and the
bundle's synthetic key material (`encryption.json`, mode 0600). Every other command refuses a directory whose
mode, marker or database token does not match, without creating a sidecar file. No environment variable, dotenv
file or credential file is read; configuration comes from the copy's own `settings` and `download_clients` rows,
decrypted with the copied synthetic keys. All HTTP goes through one client that refuses non-loopback addresses,
ignores proxy variables and refuses redirects. Output is structured JSON lines of fixed codes: fixture-controlled
text (including library identifiers, which are reported as ordinals), URLs, paths, credentials and response bodies are never printed.

Exit codes: `0` completed, `1` a recoverable failure was reported, `2` usage, `3` the domain already has an owner,
`4` this process was superseded (fenced), `5` the directory is not a prepared disposable copy, `6` `prepare` refused,
`7` `request` rejected the submission (see Request admission), `search` refused the request without claiming it
(see Gutenberg search) or `download` refused the selection before any effect (see Gutenberg EPUB download).

### Ownership and persisted authority

Two write domains, `inventory` and `downloads`, each have exactly one owning process, enforced twice: a kernel
`flock` on `locks/<domain>.lock` (released by the kernel on any exit, SIGKILL included) and a fencing generation in
`wf_owner`, incremented at start and checked inside every domain write transaction. A superseded owner's next write
fails and writes nothing; no lease expires, so no owner can publish after losing ownership. `trigger`, `cancel` and
`resume` write only `wf_schedule`, the single persisted clock: one row per workflow with its state
(`enabled`/`cancelled`), next due time and a control counter. A restart or a settings change cannot create a second
chain, a cancelled workflow stays cancelled until `resume` (each cancel also bumps an epoch that an admitted run is fenced against, so a resume cannot revive it), and a cycle that races a control change does not consume
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
credential, library-id set or `auto`) and the schedule's cancellation epoch. Each library is fetched with bounded pagination (`limit`/`page`, a required numeric
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
32 mutants of the critical invariants (each must fail an assertion), the unchanged read-only checker on both bundles,
reproducible cross-builds and an untouched-repository check.

### Request admission (one Open Library ebook)

`shelfarr-workflows request --workdir DIR --account ID < request.json` admits one request on a prepared disposable
copy. It is the first Go write of `books` and `requests`, for exactly one shape: an Open Library work requested as an
ebook. The caller is trusted: it names the account by id, and nothing in the body can choose or change the account.
No HTTP route, browser screen or native API accepts it, and the Go HTTP runtime still answers `requests` with `501`.

The body is the native app's `POST /api/consumer/v1/requests` body, read from standard input (64 KiB at most) and
checked with the same rules as `API::Consumer::V1::RequestsController#create_input`: `work_id` (`source:id`, 160
characters), `book_type`, a `title` of at most 500 characters that is not blank after stripping, optional `author`,
`cover_url` and `language` (500, 500 and 16 characters, stripped, blank becomes absent), an integer `year` from 1 to
3000, at most 20 well-formed `source_work_ids`. `user_id`, `username` and every other field are ignored. A malformed
body is `invalid_request`. A well-formed body this slice does not admit is `unsupported_request` and writes nothing:
a source other than `openlibrary:OL<digits>W`, `audiobook`, or any `source_work_ids`.

One `BEGIN IMMEDIATE` transaction on the copy, which SQLite serialises against every other writer, checks the schema
revision (`20261112150000`) and the columns it and the Rails claim below use, re-reads the account, decides and
writes. The decision is `DuplicateDetectionService.check` and `RequestCreationService` for this shape, over every ebook
`Book` carrying this `open_library_work_id`, in this order:

| Stored state | Answer (stdout, one JSON line) | Rails consumer API | Exit |
| --- | --- | --- | --- |
| One of them has a file path that is not blank (the newest such book is named) | `already_in_library`, `publication_id` | `409 already_in_library` | 0 |
| The caller has an open request (pending, searching, downloading, processing, awaiting purchase; lowest id) on one of them | `existing`, `request_id` | `200 existing: true` | 0 |
| Another account has one | `already_requested`, nothing else | `409 already_requested` | 0 |
| Otherwise, on the newest of them or a new book | `created`, `request_id`, `warnings` (Rails' texts: another format of the work, else a failed or not-found request on the book) | `201` | 0 |
| Missing or soft-deleted account, including one deleted after the caller authorised it | rejected `account_unavailable` | `401` | 7 |
| A malformed or unsupported body | rejected `invalid_request` / `unsupported_request` | `422 invalid_request` / Rails admits it | 7 |
| A schema revision or column Go does not know, or a stored value it does not model (invalid UTF-8 in any copy's file path; once no copy is acquired, an unknown request `status` on any copy; an unknown `content_kind` or invalid UTF-8 in the book that would be written; an acquisition reservation without its owner on a book that would change) | rejected `unsupported_schema` / `unsupported_stored_value` | the last one is Rails' `422` validation failure | 7 |
| A busy or failing database, an interruption (also while it waits for the body), unreadable input | `error` with `db-busy`, `db-error`, `cancelled` or `input-unreadable`; nothing written | | 1 |

Rows written (the whole list), all in that one transaction:

* `books`: reuse of the matched ebook (also one found through another provider whose row carries this Open Library id),
  filling only blank `title`, `author`, `cover_url`, `year` and `metadata_source` the way `BookMetadataBackfillService`
  does, and moving `updated_at` only when something changed; or an insert with `open_library_work_id`, `book_type`
  ebook, the caller's metadata, `content_kind` book, `metadata_source` `openlibrary` and the column defaults.
* `requests`: one insert, `status` pending, `created_via` `api`, `external_source` `consumer_app`, `request_scope`
  `single`, `language` from the body or else the `default_language` setting (else `en`), the defaults for every other
  column (`search_generation` 0, `search_claimed_at` and `next_retry_at` empty), Rails timestamps.
* `activity_logs`: the `request.created` row `ActivityTracker` writes for a bearer request (no IP address).

No `wf_` table, setting or queue row is written. A crash or an error before the commit leaves nothing: no book without
its request, and a retry of the same body is then `created` once and `existing` after that.

**Handoff.** The pending `requests` row is the durable queue entry; there is no second enqueue state and Go never
writes a Solid Queue row. An acquisition owner takes it by Rails' own claim, the one `SearchJob#claim_search!` runs:
`UPDATE requests SET status = 1, search_generation = search_generation + 1, search_claimed_at = now, attention_needed = 0,
issue_description = NULL, updated_at = now WHERE id = ? AND status = 0`, in `created_at` order (`Request.processable`;
the next worker breaks ties by `id`). Exactly one claimant can win a pending row. Today that owner is Rails: after the
Go process has exited and Rails runs on the database, each `RequestQueueJob` run dispatches the oldest pending requests
(`queue_batch_size`, 5 by default) and `SearchJob` claims each pending attempt once; a later retry makes the request
pending again and is a new attempt. Go and Rails are never owners at the same time: the command holds no lease after it exits,
and Rails never runs on a disposable copy. A future Go acquisition worker takes over by being the only process that runs
this claim while Rails' `RequestQueueJob` is not scheduled.

**Rollback.** The rows are ordinary Rails rows. Reverting this slice removes the command and leaves admitted rows to
Rails, which dispatches, shows and cancels them like its own (`Request#cancel!`). There is no Go state to clean up.

**Deferred parity (not implemented here).** Rails' metadata lookup from the provider when a request is created
(Go stores only the caller's metadata); `NotificationService.request_created` outbound notifications; the immediate
`SearchJob` Rails enqueues when `immediate_search_enabled` (default on) or auto-approval applies, so a Go-admitted
request waits for `RequestQueueJob` (every 5 minutes, oldest first, a batch per run) after Rails runs again;
audiobooks, comics, collections, other providers and source-id aliases. **Deliberate differences:** admission is
serialised for all accounts, not only per account in one Puma process, so two accounts racing for the same work create
one request, not two; where several ebook books share the work (data an older version or a race left behind), Rails
looks only at the newest and its lowest open request, while Go decides over every copy with no limit. So Rails requests
an already acquired work again when an older copy holds the file, creates a second request when an open request (the
caller's or another account's) is on an older copy, and answers `already_requested` to an account whose own request is
behind another's; Go answers `already_in_library`, `existing` or `already_requested` there, so an acquired book or an
open request is never duplicated or hidden; a text with NUL is `invalid_request`; a cover is kept only as a plain `https` URL that Rails stores unchanged,
anything else (an uppercase scheme, a default port, a fragment) is dropped where Rails would keep a normalised copy;
stored values Rails would coerce or skip are refused instead (an unknown request status only when the work is not
already in the library, which writes nothing either way).

**Verification.** `go test ./internal/admission/` checks every input rule and the cover grammar. The e2e suite
(`e2e/workflows/requests_test.go`, run by `verify-workflows`) seeds Rails-shaped rows on both bundles (acquired, active,
failed and not-found history, another format, a completed request whose file is gone, an alias book with blank metadata,
two books for one work with and without a file, two accounts' requests on one book, another account's and the caller's
request on an older copy, an unknown status, a whitespace path, a graphic kind, awaiting purchase, a comic, two existing fixture
books given an Open Library id, an ownerless reservation, a deleted account, a default language) and submits 35 cases through the
real binary, with assertions on every answer and row. It also runs eight concurrent attempts of one account (one
`created`, seven `existing`), eight attempts from two accounts (one request, the other account told only
`already_requested`), a SIGKILL after the book insert and an injected failure before commit (nothing written, then
one request on retry), an account deleted while the command waits before its transaction, 150 copies of one work with the caller's request on
the oldest and a file on the second oldest, an acquired book with id 0, an unreadable path on an older copy, a newer schema or a dropped column the claim needs, and SIGTERM while it
waits for its body.
`verify_request_admission.rb` then runs the same cases through the real `POST /api/consumer/v1/requests` on an
identical copy (the provider lookup replaced by an empty answer, network blocked), requires the same answers, ids,
warnings and rows (the four precedence cases above run alone on a fresh copy and must each give Rails' different answer) in `books`, `requests` and `activity_logs` and no difference elsewhere, opens the Go-written
database in Rails, requires valid models and `Consumer::RequestView` equal to Rails' own, recognised repeats, and one
`SearchJob` per pending request from `RequestQueueJob` (its batch raised to 100 in that copy), whose serialized payload,
executed through `ActiveJob::Base.execute`, claims each Go request once and does nothing when run again, and no second dispatch. It refuses evidence with no
created or compared case, without exactly the documented differences (each pinned to its work and both answers), or
with a captured `SearchJob` that does not serialize as one. Eighteen mutants of these rules must each fail an assertion.

### Gutenberg search (one claimed ebook request)

`shelfarr-workflows search --workdir DIR --request ID` takes one pending ebook request, for example one admitted by
`request`, searches the one configured Project Gutenberg OPDS catalogue and publishes what it found in the state Rails
already uses for manual selection. It is the first Go write of `search_results`. It never selects, downloads or
publishes bytes, has no scheduler, route, screen or native action, and runs only on a prepared disposable copy.

**What it accepts (the explicit subset).** Before claiming anything, one transaction checks the schema revision and
columns, the request and the copy's settings the way `SettingsService` reads them. The request must exist, be pending
(or searching with an abandoned claim, below), belong to an account that is not deleted, and be for an ebook.
`gutenberg_enabled` must be on and `gutenberg_url` must pass `GutenbergClient`'s origin rules and be a loopback IP
literal: the public catalogue, a host name or any other address is refused before a claim and before any network
use (`provider_not_loopback`), and the HTTP client additionally refuses to dial anything else. Every other source
`SearchJob` would also ask for an ebook must be off (an active indexer, Anna's Archive, Z-Library, an enabled custom
provider for ebooks, eBooks.com), because Go searches one provider and must not decide a multi-source search from it.
Z-Library counts as configured on its default mirror list when no URL is stored, as in Rails; eBooks.com counts as
configured whenever it is enabled with any two-letter country, a conservative superset of Rails' check against the
real country list. Integer settings accept surrounding white space, a sign, leading zeros and single underscores
between digits; any other spelling Rails would accept (such as a `0d` prefix), or a value beyond 64 bits, is refused.
`auto_select_enabled` must be off (Go never selects) and the webhook, Discord and Telegram notification channels off
(Go cannot enqueue them). A refusal writes nothing and leaves the request pending for Rails: answer `rejected` with
`unsupported_schema`, `unsupported_stored_value`, `request_not_found`, `request_not_pending`, `not_an_ebook`,
`account_unavailable`, `provider_disabled`, `provider_invalid`, `provider_not_loopback`, `other_sources_configured`,
`auto_select_enabled` or `outbound_notifications_configured`, exit 7; a live claim of another worker is `refused`
`request_claimed`, exit 3. Settings Rails reads from `SHELFARR_SETTING_*` variables are not visible to Go; none of
the settings above is environment-managed except the webhook ones, so a host that sets those must not run this command.

**Claim.** Rails' own claim, in one `BEGIN IMMEDIATE` transaction that also rechecks everything above:
`UPDATE requests SET status = 1, search_generation = search_generation + 1, search_claimed_at = now,
attention_needed = 0, issue_description = NULL, updated_at = now WHERE id = ? AND book_id IS NOT NULL AND (status = 0
OR (status = 1 AND search_claimed_at IS NOT NULL AND search_claimed_at <= now - 30 minutes))`. The second branch is
`RequestQueueJob`'s stale-search lease (30 minutes), so Go may take over a claim abandoned by a killed worker exactly
when Rails would recover it, in one step instead of Rails' recover-then-claim (one generation bump, not two). The
request row is the only durable state: there is no `wf_` row, lease file or second queue. No transaction is open while
the network is used.

**Search.** The same queries `SearchJob#search_gutenberg` makes: each `SearchTitleVariantService` title (the first
part of `A / B`, then the second, then the whole) joined with the book's author, stopping at the first title with any
result; `GET /ebooks/search.opds/?query=…` on the configured origin; the first `gutenberg_search_limit` (1 to 25)
distinct book ids from `subsection` links or entry ids; `GET /ebooks/<id>.opds` for each, one at a time; per book the
entry and acquisition link `GutenbergClient` would choose, filtered by the request's effective language (its own,
else `default_language`). The detail path is built from the numeric id, never taken from the provider's link, and
`next` pages are never followed. Every response is read through a 1 MiB limit with a per-request timeout
(`--request-timeout`, at most 1 minute) inside an overall `--deadline` (at most 20 minutes, below the lease), no
proxy, no redirects, the Rails user agent, and parsed by a strict XML decoder that loads no DTD or external entity,
with at most 100 entries, 20,000 elements and depth 32; after an optional UTF-8 byte order mark, the root must be a
`feed` in the Atom namespace and only literal XML white space may stand outside it (no character reference or CDATA),
Atom elements are recognised only in the Atom namespace and the language only as Dublin Core `dcterms:language`, and
only unqualified attributes are read (a repeated attribute or an empty prefix binding is malformed), so an HTML maintenance page, another
format or a truncated or trailing answer is malformed, never empty. When no title gives a result and a search page or
book page it used linked a `next` page, or a search page listed more books than the limit, the answer was not fully
read and is reported as `provider-pagination`, not as no results. After every response the claim is renewed with Rails'
heartbeat compare-and-swap on `(status, search_generation)`; a lost claim stops the search before the next request.
A candidate is stored only when Rails' choice for that book is an EPUB whose link is on the configured origin (a
`/`-rooted path or the origin itself, no `..`, query or fragment); any other choice (MOBI, PDF, another host) is
withheld. The decision log carries codes and counts only: no title, author, URL or response text.

**Publication.** One transaction re-reads the request under Rails' transition lock statement, requires the same
`status` searching and `search_generation` with the claim timestamp still set (Rails clears it when a search finishes),
and rechecks the account, eligibility and everything the search depended on: origin, limit, title variants, author and
effective language;
anything else is either `superseded` (exit 4, nothing written) or a release (below). Then, as `SearchJob#complete_search`
and `#fail_search_without_results` do:

| Answer | Rows written | Outcome | Exit |
| --- | --- | --- | --- |
| At least one stored candidate | the request's store offers and its `store_offers_found` event deleted; its non-manual, non-blocklisted results not tied to a queued, downloading or paused download deleted (their downloads' `search_result_id` cleared); one `search_results` row per new `gutenberg:<id>` guid with Rails' title (`Title - Author [EPUB] [Language]`), `Project Gutenberg`, the authorised download URL, the configured origin's `/ebooks/<id>` page, the OPDS language, status pending, `{}` payload; an existing row with that guid kept (made rejected when blocklisted); `attention_needed`, "Search results found. Please review and select a result to download.", claim cleared, status still searching; the `attention_flagged` request event and the `request_attention` notification `mark_for_attention!` writes | `candidates` | 0 |
| A valid empty answer (an empty feed, a `404`, nothing matching) | store offers cleared; `schedule_retry!`: status not found, `retry_count + 1`, `next_retry_at` = now + min(`retry_base_delay_hours` × 2^retries, `retry_max_delay_days` × 24) hours | `no_results` | 0 |
| ... with `retry_count` already at `max_retries` | store offers cleared; not found, `retry_count + 1`, attention "Maximum retry attempts (N) exceeded. Manual intervention required.", event and notification | `retries_exhausted` | 0 |
| Malformed, oversized or non-feed XML (also halfway through the books), a non-`404` client error, a redirect, an answer that was not fully read and gave nothing | attention "Search failed before any source returned results.", event and notification, claim cleared, status searching, results untouched | `failed` with `provider-malformed`, `provider-too-large`, `provider-refused` or `provider-pagination` | 1 |
| Unreachable, timeout, `408`/`425`/`429`/`5xx` (also halfway through the books), the overall deadline, SIGINT or SIGTERM, a configuration change, or only withheld candidates | release: status pending, `search_generation + 1`, claim, attention and description cleared; nothing else | `released` with `provider-unreachable`, `provider-timeout`, `provider-busy`, `search-deadline`, `cancelled`, `configuration-changed` or `unsupported-candidates` | 1 |

A transport failure is never read as an empty answer and never ends a request: the released request is pending again,
so this command or Rails' `RequestQueueJob` runs it again, and a request whose only candidates Go withholds is handed
back to Rails, which stores them as it always has. A SIGKILL before or inside the publication leaves the claim
(SQLite rolls the transaction back): the command then answers `request_claimed` until the 30-minute lease passes,
after which this command or `RequestQueueJob#recover_stale_searches` takes it over. A late answer from a superseded
worker writes nothing.

**Ownership and rollback.** The claim is durable: it lives in the request row from the claim until the command
settles it (publication or release) or, after a crash, until the 30-minute lease passes and this command or Rails
recovers it. Every settled state is one Rails reads as its own: it shows and selects the candidates, retries `not_found`,
dispatches a released request and recovers an abandoned claim. Reverting this slice removes the command and leaves
the rows to Rails; there is no Go state to clean up. A copy where Go published results and Rails then runs is the
supported rollback; Rails and this command must not run on the same database at once, which the disposable copy
guarantees today. The adapter (`internal/gutenberg`: origin rules, bounded client, strict parser, same-origin
download authorisation) is the boundary `download` reuses to fetch the stored URL; `search` itself transfers no media.

**Deliberate differences.** Go does not run `ReleaseScorer`: new rows have no `confidence_score` or `score_breakdown`
(Rails shows no score and `confidence_level` is unknown), and a kept row is not rescored (its score and detected
language stay as they were). Go refuses malformed XML where Nokogiri recovers what it can (Rails then searches the
fragment). Go withholds MOBI, PDF and off-origin EPUB links and hands such a request back instead of storing them.
Go refuses instead of searching when another source, auto-selection or an outbound notification channel is configured.
Go stores the configured catalogue's own book page as `info_url` (identical to Rails' value for the public catalogue,
which Rails hard-codes) so no link this command writes leaves the configured origin; a kept row written earlier keeps
its links unchanged. Go reports an incompletely read answer with no
valid result as `provider-pagination` where Rails schedules a retry, and reads elements by namespace where Rails
removes namespaces first.
Go builds the detail path from the id and requires a loopback origin in this harness.

**Verification.** `go test ./internal/gutenberg/ ./internal/acquisition/` checks the Rails selection rules (format
scores and ties, language filter, ids, titles), the origin and link rules, XML that tries entities or exceeds the
bounds, every transport answer class, the limit, title variants and the heartbeat stop, and the settings readers.
The e2e suite (`e2e/workflows/search_test.go`) runs the built binary against a loopback catalogue serving synthetic
OPDS shaped like Gutenberg's, on both bundles, with Go-admitted requests: exact rows, catalogue requests and
untouched rows of every other request and table for candidates (with manual, blocklisted, stale, active-download and
store-offer rows seeded), no results, retries exhausted and title variants; seventeen failure answers (including a balanced HTML page, text
after the feed, a feed in another namespace, an HTML detail after a valid one and unread search and book pages with
only another language), a feed with a byte order mark; every refusal with
no catalogue contact (Z-Library on its default mirrors among them); six concurrent runs on one request (one claim);
SIGKILL after the claim and inside the publication with takeover after the lease; heartbeats that move the lease; a
newer claim, a claim finished elsewhere and a changed effective language while parked before publication, another
claim between two responses, a configuration change and SIGTERM. `verify_gutenberg_search.rb` (run by `verify-workflows`) installs the
same pre-search copies in real Rails, serves the same catalogue through WebMock with all other network blocked, runs
`SearchJob`, and requires the same outcome, the same catalogue requests and the same rows in every table except the
documented score and info link columns; requires every scenario of its bundle; requires Rails' documented different outcome for the malformed and withheld answers and
that Rails searches the handed-back request once; reads the Go candidates as valid direct downloadable results,
renders their result row and selects one (`Request#select_result!`, a queued `Download`, one `DownloadJob` enqueued
and not performed); and recovers the killed Go claim through `RequestQueueJob` only after the lease, then finishes
that search. Nineteen mutants of these rules must each fail an assertion.

### Gutenberg EPUB download (one selected candidate)

`shelfarr-workflows download --workdir DIR --request ID --result ID` selects one Project Gutenberg candidate that
`search` stored, downloads its EPUB from the same loopback catalogue and publishes it as the request's completed
library ebook. It is the first Go write of a library file, `downloads`, `books.file_path` and a completed request. It
runs only on a prepared disposable copy, explicitly, once; there is no scheduler, route, screen, retry or automatic choice.

**Contract before and after.** Before: Rails alone turns a selection into a book, through `Request#select_result!`
(manual selection), `DownloadJob` (direct HTTP download) and `DirectDownloadFileService` (staging, Book reservation,
publication, `finalize_database!`). After: on a disposable copy, this command produces the same end state for one
shape, in one transaction, and Rails keeps reading, listing, delivering and recovering it as its own. Nothing Rails or
a client calls changes: no route, schema, job, setting or stored format is added.

**What it accepts.** Everything `search` requires (schema revision and columns, account, ebook, Gutenberg enabled on a
loopback origin, no other ebook source, no auto-selection, no outbound notification channel), and, checked in one
transaction before any network or file effect:

* the request is searching with no live claim (results published, awaiting selection) and has no download other than
  failed ones without direct-download recovery state; its book has a `file_path` that is empty or only spaces (the
  test Rails' `reserve_book!` makes with SQLite `TRIM`, so a tab is refused) and no acquisition reservation;
* the result belongs to that request, is a pending, non-blocklisted `gutenberg:<digits>` row with no custom provider,
  and its stored `download_url` is exactly what the configured origin authorises (a `/`-rooted path, no `..`, query or
  fragment) and names an EPUB by Rails' own extension rule (`1342.epub3.images` is EPUB; `kf8`, `kindle`, `mobi`, `pdf`
  and `azw3` are not);
* `ebook_output_path` is a stored string setting naming a directory **strictly inside the disposable directory**, given
  in canonical form (absolute, clean, no symbolic link), owned by the caller and not writable by group or others, reached
  by `openat2` with `RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS | RESOLVE_NO_XDEV` (so neither a link
  nor a mount point leads out of it);
* no library platform scan is configured (Audiobookshelf URL and key, BookOrbit or Grimmory URL, user and password, a
  conservative superset of Rails' `LibraryPlatformClient.configured?`) and no `library_import_file_mode` or
  `library_import_folder_mode` is set, because Go triggers no scan and applies no import permissions.

A refusal writes nothing (other than the lock file below) and contacts nothing: answer `rejected` with `request_not_selectable`, `result_not_found`,
`result_not_selectable`, `result_off_origin`, `result_not_epub`, `book_acquired`, `downloads_active`,
`library_root_not_disposable`, `library_scan_configured`, `import_permissions_configured` or any `search` refusal, exit 7.
A second `download` while one runs on the same disposable copy is `refused` `acquisition_busy`, exit 3 (a kernel `flock`
on `locks/acquisition.lock`, released on any exit, SIGKILL included). Asking again for the result that completed the
request answers `already_completed` with its download id (exit 0, no network); any other result of a completed request
is `request_not_selectable`.

**Download.** `GET` of the stored link on the configured origin only, through the loopback-only client (no proxy, no
redirect), with the Rails user agent, a header timeout (`--request-timeout`, at most 1 minute) and an overall deadline
(`--deadline`, default 10 minutes, at most 30, Rails' own limit). `200` only; `404`, a redirect or another client error
is `provider-refused`, `408`/`425`/`429`/`5xx` `provider-busy`. A text, HTML, JSON or XML content type is
`download-not-a-book` (Rails' header rule). The body is streamed through a 250 MiB bound applied while reading (the
largest EPUB the consumer listing serves; Rails allows 512 MiB) into an anonymous `O_TMPFILE` inside the library root
while its SHA-256 is computed; an announced or actual size over the bound is `provider-too-large`, a connection that
ends before its `Content-Length` is `download-truncated`. The file is then fsynced and checked as an EPUB container with
the existing strict ZIP directory reader (no extraction, no inflation, no rendering): a well-formed directory with no
ZIP64, encryption, links or unsafe names, `mimetype` first at offset 0, stored, exactly `application/epub+zip` with a
matching CRC, and a non-empty `META-INF/container.xml` entry (its compressed content is not inflated or parsed).
Anything else is `download-invalid`. Until it is linked the file has no
name, so an interruption, a refusal or a kill leaves nothing on disk.

**Publication protocol.** Validated bytes are persisted before metadata, with no Go state between runs:

1. the folders `shelfarr-gutenberg/book-<book id>/` are created or opened, each parent fsynced, and the anonymous file
   is linked as `gutenberg-<Gutenberg id>.epub` with `linkat`, which never replaces an existing name; then the folder
   is fsynced. When the name is already taken, the existing entry is adopted only if it opens through the same confined
   `openat2` (no link, no mount crossing, including a file bind mount) as a regular file with the same size and SHA-256
   as the bytes just validated, the comparison Rails' `publish_file_and_finalize!` makes when its destination exists,
   narrowed here to a single-link file of the caller; the adopted file is then fsynced. Anything else is
   `library-file-exists` and is left untouched. A link or unsafe folder is `library-path-unsafe`;
2. one `BEGIN IMMEDIATE` transaction re-reads everything the eligibility check read and requires it unchanged (request
   status, generation, claim and `updated_at`, the result's status and row, the book's `updated_at`, path and
   reservation, the account, the eligibility settings, origin and library root path; settings only `search` uses, such
   as the default language or retry delays, are re-checked for validity but not compared), writes the rows below and,
   last before `COMMIT`, requires the name to still be the linked or adopted inode.

Each filesystem step (staging, folder creation and link, identification, removal) reopens the library root by its path
from the disposable directory with the confined `openat2` above and requires it to be the directory first checked
(device and inode), so a root moved or replaced before that step is `library-root-changed` before publication or
`superseded` after it, and nothing is created through the old directory.

SIGINT and SIGTERM stop the command until the bytes are validated; from step 1 it finishes or rolls back the
publication (its database work bounded by 10 seconds; a filesystem call in progress is not interrupted). Anything changed is `superseded` (exit 4). On that, or on a failure after the link (a
folder fsync, a failpoint, a database error inside the completion transaction, after checking that no book references
the path, exit 1), the command removes the file only if it linked it in this run and the name still holds that inode,
which it keeps open, so the inode cannot have been reused; an adopted file is never removed. When the root or folder
can no longer be reached, the file stays. Folders are never removed, so an empty `book-<id>` folder may remain; the
next attempt reuses it.

**Rows written (the whole list, in that one transaction).** The end state of Rails' manual selection plus
`DownloadJob#handle_direct_http_download`, compared row by row with real Rails below:

* `search_results`: every other result of the request `rejected` without moving `updated_at` (Rails' `update_all`), the
  chosen one `selected`;
* `downloads`: one row, `completed`, `download_type` `direct`, `download_path` the library file, `name` the result's
  title, its `size_bytes` (empty for Gutenberg), `search_result_id`, column defaults elsewhere and no direct-download
  recovery column (the state Rails leaves after `cleanup_after_run!`);
* `books`: `file_path` the library file, `reference_target_roots` cleared;
* `requests`: `completed`, `completed_at`, attention, issue, `next_retry_at` and claim cleared;
* `request_events`: `download_queued` (source `request`, details `search_result_id`, `title`, `trigger` `manual_select`),
  `dispatch_started` (`DownloadJob`, `request_status` `downloading`) and `completed` (`DownloadJob`, "Direct download
  completed"), each tied to the download;
* `activity_logs`: `request.completed` for the request's account; `notifications`: the in-app `request_completed`
  "Book Ready" notification.

Nothing else changes: no queue row, no scan, no outbound notification, no other request's rows (the suite compares a
digest of every other table).

**When the user sees what.** Go skips Rails' visible in-flight states (`downloading` request, `queued`, `downloading`
and `dispatching` download, Book reservation). Until the completion transaction commits, the request reads exactly as
`search` left it, awaiting selection; at the commit it reads completed with its book acquired, the file already
durable at its final name. Nothing in between is visible to Rails or a client.

**Interrupted states and rollback.** There is no Go state outside the transaction: an interruption leaves at most a
complete, validated, unreferenced EPUB at its final name, which the next download of the same result adopts.

| Interrupted | On disk | In the database | Next `download` on the copy | Rails on the copy (rollback) |
| --- | --- | --- | --- | --- |
| During the download or check, or SIGINT/SIGTERM then (`cancelled`) | nothing (anonymous file freed) | nothing | downloads again | sees the request awaiting selection; selects and downloads it itself |
| After the link, before or inside the commit (SIGKILL included), or a rollback that could not reach the file | the linked EPUB, unreferenced | nothing | downloads again and adopts the file at the name when the bytes are the same (`adopted` true); different bytes stop with `library-file-exists` | same; the unreferenced Go file stays (Rails publishes under its own template path, so it never collides) |
| After the commit | the library file | the completed rows | `already_completed` | reads, lists and delivers it; `DirectDownloadRecoveryJob` leaves it untouched |

Nothing is ever deleted on a later run, so no proof of ownership across runs is needed: a file this command did not
link in the current run is either adopted unchanged or left in place. Reverting this slice removes the command;
completed rows are ordinary Rails rows and the files are ordinary library files.

**Assumption.** The disposable directory is private (mode 0700) and nothing else changes it while a command runs. The
checks above are made from fresh descriptors immediately before each step, but a concurrent process of the same user
could still rename entries between a check and the step that relies on it (for example between the identity check and
`unlinkat` during a rollback, which has no inode-conditional form, or between reopening the root and the operation on
it); the protocol does not defend against that, as Rails' `DirectDownloadFileService` does not either.

**Deliberate differences.** The library path is a narrow owned layout under the configured root,
`shelfarr-gutenberg/book-<book id>/gutenberg-<Gutenberg id>.epub`, and `books.file_path` names that file, where Rails
builds `PathTemplateService` folders and stores the folder (`<root>/<author>/<title>`); both are valid Rails book paths
and both list and deliver the same EPUB. A failed download writes nothing and leaves the request awaiting selection,
where Rails marks the download failed, records `dispatch_failed`, blocklists or picks another candidate, or flags the
request; Go ports no failure handling, retry or next-candidate selection. Go requires the result to be pending, not
blocklisted and an EPUB, where Rails also re-selects rejected or blocklisted results and downloads MOBI or PDF. Go requires
a loopback catalogue, which Rails' `OutboundUrlGuard` refuses for Gutenberg (the Rails oracle below allows loopback for
this proof only). Go refuses a configured library scan or import permissions instead of running them, and checks the
EPUB container where Rails checks only the `PK` signature. After an interruption the EPUB is fetched again to
prove the file left at the name before it is adopted. Replacing an existing library file, audiobooks, other
providers, `size_bytes` from the response and concurrent Rails and Go owners are not supported.

**Verification.** `go test ./internal/bookfile/ ./internal/gutenberg/` checks the EPUB container rule, the confined root
(outside, the workdir itself, links, trailing slash, open modes), every operation refusing a replaced root, no-replace
publication, adoption only of the same bytes in a single-link file, removal only of the inode linked in the same run, linked and open folders, and every download answer class with the bound and a local write failure. The e2e suite
(`e2e/workflows/acquire_test.go`) admits and searches through the real binary on both bundles, then downloads a minimal
readable synthetic EPUB from the loopback catalogue: exact bytes and SHA-256, every written row, untouched tables and
library, no provider data in the log; the built `shelfarr-http` lists the book with the asset id of the final file's
stat and delivers the exact bytes; a repeat is `already_completed` and another result is refused, both without network.
It also covers 29 refusals with no catalogue contact, 14 download failures (statuses, redirect, content types, garbage,
truncation, a ZIP that is not an EPUB, both size bounds, the deadline and SIGTERM) that write nothing, SIGKILL at three
boundaries (no worker state written) and an external SIGKILL while publishing, each followed by a rerun that completes,
adopting the killed attempt's file after a kill once it was linked,
a killed attempt's file kept through a failed rerun and adopted by the next, a foreign file left at the name, the same
EPUB already at the name (adopted), six concurrent attempts (one completes, the others are `acquisition_busy`), six
changes while parked before the commit and a root moved while parked inside the completion transaction (all
`superseded`; the file removed, or for a moved root left there and adopted once the root is restored), a root moved
out of the disposable directory and replaced before publication (`library-root-changed`, nothing created in either),
failures after the link and inside the completion transaction, an existing different file and a linked folder.
`verify_gutenberg_download.rb` (run by `verify-workflows`) installs the same pre-download copies, and the
database of the copy interrupted after the link (whose orphan stays in the Go library), in real Rails with its own
library root, serves the same EPUB through WebMock, runs
`select_result!` and the enqueued `DownloadJob`, and requires the same rows in every table except the library path;
then it installs the Go result, requires valid completed models, Rails' consumer API to list the same asset id and
deliver the same bytes, and `DirectDownloadRecoveryJob` to change nothing. Ten mutants of these rules must each fail
an assertion.

## Gaps (recorded in every report)

| Gap | Status |
| --- | --- |
| `stable-volume-upgrade` | **partial; M2 adds an executable volume proof (see [backend-volume-upgrade.md](backend-volume-upgrade.md)).** `--mode stable-upgrade` proves the primary database of `v2026.11.05.1` survives the shipped migrations. The queue, cable and cache databases, queued Ruby jobs, key files, packaging and activity-preserving rollback are M2. The checker's public report still lists this gap as missing, because a volume has not been migrated. |
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
- M2 adds the stable and beta volume upgrade and activity-preserving rollback (the `stable-volume-upgrade` gap); its experimental, Rails-plus-tools proof is documented in [backend-volume-upgrade.md](backend-volume-upgrade.md) and still claims no Go write-domain handover
  and the packaged multi-architecture application;
- M3 onward reuse the projection contract, adding the session and CSRF API for the TypeScript client.

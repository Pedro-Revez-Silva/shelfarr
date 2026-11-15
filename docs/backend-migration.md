# Go backend migration

Status: **M0, an experimental and unreachable proof.** Rails remains the only implementation that
serves Shelfarr. Nothing in this slice is routed, packaged, started by the container, or reachable
from the running application. It adds a command-line checker that reads isolated fixture bundles
and a producer that creates those bundles from the real Rails code.

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
- every write path, queue, scheduler and the stable-volume upgrade (see `Gaps`).

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
  e2e/                      executable tests, corrupted-bundle controls and mutants (build tag e2e)
tools/migration/            independent Rails fixture producer and the verify script
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

## Coverage

`manifest.coverage.cases` lists every case and its digest stays in the private manifest. The current bundle
has 13 identity vectors, 12 library books (including indirect path, Unicode NFD names, hidden and
non-media files, natural ordering, outside-root, missing, library-root, blank and comic cases), 18
password verdicts, 8 encrypted columns, 15 tampered envelopes and 44 consumer responses plus one
refusal (111 cases).

## Gaps (recorded in every report)

| Gap | Status |
| --- | --- |
| `stable-volume-upgrade` | **missing.** The fixture is built from the current `db/schema.rb`, not by migrating a released stable volume. The consumer tables do not exist in the stable tag `v2026.11.05.1`, so this needs its own producer mode. |
| `catalogue-pagination` | missing; a list larger than 30 publications is refused. |
| `token-adoption` | missing; replacement tokens are refused. |
| `reference-imports` | missing; symbolic-link library entries are refused. |
| `pdf-cbz-assets` | missing; only the default EPUB and audio listing is covered. |

## Verification

```
tools/migration/verify
```

runs, in order: the Ruby isolation tests and RuboCop; two independent fixture productions with a
check that the repository is untouched; a shape comparison of the two; `gofmt`, `go vet`, and
`go test -race ./...`; the executable tests in `apps/server/e2e` against the first bundle; the
race-instrumented executable against both bundles; byte-identical `linux/amd64` and `linux/arm64`
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
- **No leakage**: the output of passing, failing and refused runs never contains any secret in
  `credentials.json`, the bundle path, the media path or a decrypted value.

## Rollback

M0 adds files only: `apps/server/`, `tools/migration/`, and this document. It changes no route,
schema, image, workflow, Docker default or application behaviour. To roll back, revert the commits
that add those paths; nothing else depends on them.

## What the next waves need from this

- M1 reuses `internal/store`, `internal/bundle` and the producer for crash, hang, cancellation,
  retry, duplicate-instance and SQLite contention proofs;
- M2 adds the stable and beta volume upgrade and activity-preserving rollback (the `stable-volume-upgrade` gap)
  and the packaged multi-architecture application;
- M3 onward reuse the projection contract, adding the session and CSRF API for the TypeScript client.

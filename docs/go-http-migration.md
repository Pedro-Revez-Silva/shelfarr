# Go HTTP runtime: the native consumer read lane

Status: **experimental, default-off, unreachable from production.** Rails remains the only server that
runs. `shelfarr-http` is not started by the container, not routed, not packaged and not part of the
Dockerfile. It reads a compatible Shelfarr SQLite database and library roots that an operator names
explicitly, and serves the part of the native consumer API that installed readers use to browse and
open EPUBs and audiobooks. It is the next backend foundation after M0 (compatibility checker), M1
(durable workflows) and M3 (static TypeScript Library); it is not a handover.

## What it serves

All routes answer `GET` and `HEAD`. Authentication is the native bearer credential only.

| Route | Authentication | Notes |
| --- | --- | --- |
| `/api/consumer/v1/server.json` | none | Public. Reports what *this runtime* implements (see Deliberate differences). |
| `/api/consumer/v1/me` | bearer, `library:read` | `id`, `name`, `username`, visible scopes. |
| `/api/consumer/v1/library` | bearer, `library:read` | Catalogue with Rails-compatible cursors, `q`, `type`, `status`, `sort`, `limit`. |
| `/api/consumer/v1/continue` | bearer, `library:read` | In-progress publications. |
| `/api/consumer/v1/library/:id` | bearer, `library:read` | One publication. |
| `/api/consumer/v1/library/:id/assets/:asset_id` | bearer, `library:read` | EPUB and audiobook bytes: `Range`, `If-Range`, `If-None-Match`, `HEAD`. |
| `/up`, `/readyz` | none | Liveness, and readiness (database readable, library roots present). |

### Explicitly refused (HTTP 501, `not_implemented_in_go_runtime`, before authentication, no side effects)

Pairing and token creation (`POST auth/device`, `auth/token`), token revocation (`POST auth/revoke`),
`discover`, `requests` (list, show, create, delete), `library/:id/progress` (read and write),
`library/:id/reading_status`, `assets/:id/reading_order`, `read_along` (manifest, resources, audio),
`transfer_grant` and `transfer`. Kobo, browser sessions, CSRF and the browser `/preview` API stay with
Rails. Anything else is `404`. A wrong verb on a served route is `405` with `Allow: GET, HEAD`.

### Refused when a request asks for something this runtime cannot do

| Request | Answer |
| --- | --- |
| `X-Shelfarr-Reader-Formats` naming `pdf` or `cbz` | `501 unsupported_reader_format` |
| `X-Shelfarr-Reader-Features: read-along` on a publication | `501 unsupported_reader_feature` |
| an asset id that resolves to a PDF or CBZ | `501 unsupported_asset_format` |
| an asset of a comic record | `501 unsupported_publication_kind` |
| a symbolic-link (reference import) library entry or a relative, `~` or `//` stored path | `501 unsupported_library_layout` |
| a stored value Rails accepts but this runtime does not model (scope JSON that is not a string or list, a non-JSON locator, a malformed timestamp, a non-string path setting) | `501 unsupported_stored_value` |
| a database library root outside every `-library-root` | `503 library_root_not_allowed` |

None of these ever becomes an empty `200`. A metadata read that fails is `503 database_unavailable`
or `503 database_busy` (with `Retry-After`), never an empty list and never `401`.

## Authentication and who writes what

Bearer credentials follow `APIToken.authenticate` exactly: SHA-256 digest lookup (the issued `shf_`
prefix is **not** required, as in Rails), `revoked_at IS NULL`, `expires_at IS NULL OR expires_at > now`
compared with the same quoted timestamp Active Record sends, a soft-deleted owner is refused, and an
ownerless or dangling-owner token is refused after being touched (Rails touches it first). Scopes are
normalised as Rails does; privileged scopes (`requests:admin`, `users:write`) are visible only to an
administrator, so a broad token never grants administrator scopes. Cookies, CSRF tokens and the legacy
admin `/api/v1` are never consulted.

Two writes happen on `GET`, as in Rails, both on `api_tokens` only:

1. `last_used_at` and `updated_at` are set for every authenticated lookup.
2. **Permission-upgrade adoption.** A token that carries `replaces_api_token_id` retires its parent on
   first use: in one immediate transaction the parent must exist for the same owner, both tokens must be
   usable, the parent gets `revoked_at` and `updated_at`, and the new token's pointer is cleared. Any
   refusal (parent revoked, expired, other owner, missing) leaves both rows untouched and answers `401`.
   If the second write fails the revocation rolls back. A concurrent adoption by another request is
   recognised (`replaces_api_token_id` already `NULL`) and revokes nothing twice.

Ownership: the process takes an exclusive `flock` on the explicit `-lock-file` before it opens the
database. A second Go instance exits `3`. **That lock does not fence Rails.** Running Rails and this
runtime against the same database at the same time means two writers of `api_tokens`; the guarded
updates above keep each transition atomic, but one owning backend per write domain remains a handover
prerequisite and this slice does not claim it. No other table is written, ever: no migration, no
schema creation, no key generation.

## Database access

`internal/live` opens the database read-write only for the two statements above and `query_only` for
everything else. It does not use the immutable handle of the M0 checker (valid only for a sealed
fixture); a normal connection reads the live write-ahead log, so rows committed by Rails a moment ago
are visible and an external revocation takes effect on the next request. It refuses a path that does
not exist (it never creates a database at a typo path), is not a regular SQLite file, or is a symbolic
link; and a schema whose `schema_migrations` maximum is not one of `live.SupportedRevisions`
(currently `20261112150000`) or that lacks a column the runtime reads. Every read is bound to the
request context, so a disconnect cancels it, and no transaction is held while a file is streamed.

## Keys and configuration

Nothing is discovered. There is no default database path, no `.env` loading and no network access.

```
shelfarr-http -experimental \
  -database /abs/primary.sqlite3 -lock-file /abs/auth-domain.lock \
  -library-root /abs/library [-library-root ...] \
  [-listen 127.0.0.1:3100] [-allow-non-loopback] [-server-version V] [-android-channels release]
```

Cursors are signed by Rails with a key derived from `secret_key_base`, so the runtime needs it, in
the modes Rails supports: `SECRET_KEY_BASE`, `SECRET_KEY_BASE_FILE` (Docker secrets), or
`-secret-key-base-file` (the persisted `storage/.secret_key_base`). Setting more than one is refused.
`RAILS_MASTER_KEY` credentials mode is refused (`master-key-mode-unsupported`); a missing key is
refused; a key is never generated. Diagnostics are fixed codes (`config`, `library-roots`,
`database-not-sqlite`, `database-schema`, `secret-key-base-missing`, `lock-held`, ...) and never echo a
path, a value or a credential. Exit codes: `0` stopped, `1` failed, `2` refused, `3` already owned.

`-library-root` is an allow-list in addition to the roots stored in the database: the database roots
decide what is a library (as in Rails) and the flags decide what this process may ever open. Asset
bytes are opened with `openat2(RESOLVE_BENEATH|RESOLVE_NO_SYMLINKS|RESOLVE_NO_MAGICLINKS)` relative to
the canonical root, and the opened file's `fstat` is turned back into the asset id (Rails'
`Consumer::LibraryAssets#identity`, rational Linux timestamps) and must equal the requested one. A file
replaced, rewritten, deleted or swapped for a link between listing and open is `410 asset_unavailable`
or `501`, never served under the old identity.

## HTTP behaviour

* Read-header 5s, read 15s, idle 60s, 32 KiB headers, a body on a `GET` is never read beyond 1 KiB.
* Metadata requests and media streams have separate bounded capacity (`-max-metadata-requests`, default
  64; `-max-media-streams`, default 8). A full pool answers `503 server_busy` with `Retry-After`; a
  stalled audiobook client therefore cannot starve the catalogue.
* A stream write that makes no progress for `-stream-write-stall` (30s) ends the connection and returns
  the slot. Files are copied in 64 KiB chunks, never buffered whole.
* Shutdown (`SIGINT`/`SIGTERM`) stops accepting, lets running transfers finish for `-shutdown-timeout`
  (20s), then closes what is left; it exits `0`.
* Logs are JSON lines with `method`, route *name*, status, bytes, duration and a fixed `code`. They
  never contain `Authorization`, a path, a query, an asset id, a cursor, a title or a database error.

## Deliberate differences from Rails

1. **`server.json` states what this runtime does.** `consumer_features` is `[]` (no requests),
   `reader_formats` is `["epub"]`, `reader_features` and `read_along_manifest_versions` are `[]`.
   Rails advertises `requests`, `cbz,epub,pdf` and `read-along`; copying that would invite clients to
   use routes this runtime refuses. `android` is derived from `-android-channels` (default `release`)
   with the Rails paths, which Rails still serves; `server_version` comes from `-server-version`.
2. Error bodies of `404`, `405`, `5xx` are small JSON documents (`{"error": "..."}`); Rails renders its
   exception page. Status codes are the compared contract.
3. JSON responses carry no weak `ETag`, so a client `If-None-Match` on JSON is not answered `304`.
   Assets keep the strong `ETag` and conditional behaviour.
4. Canonical paths only: `/me.json`, `/library/1.json`, a trailing slash and `/assets/<id>.mp3` are
   `404` here (Rails accepts format suffixes).
5. `Authorization` with trailing whitespace is trimmed by Go's HTTP parser before the token digest is
   computed; M0's function-level parser keeps it.
6. An unsupported layout fails the whole listing that contains it (`501`), instead of skipping one book.

## Contract before and after

Before this change no Go program accepted an HTTP request: the native consumer API was served by
Rails only, and M0 exposed `consumer.Service.Respond`, a pure function with no listener, no
pagination, no adoption and no writes. After it, one new executable, `shelfarr-http`, serves the
routes above. Nothing a consumer outside this diff observes changes: no route, schema, stored format,
configuration key, image or workflow of the Rails application is touched, and M0's report and
`shelfarr-compat` are unchanged. Go-internal additions: `library.Lister.Formats` (default EPUB, same
listing), `consumer.NewView`/`Publication` exports and an optional `content_kind` field that only a
declared format selection emits, and `store.ContentKind*`.

## Verification

`tools/migration/http/verify-http` is the single entry point. It produces the M0 current-schema and
stable-upgrade bundles with the real Rails code, records real Rails responses over private copies of
both with `tools/migration/http/capture_http_cases.rb`, and then runs, against the race-instrumented
executable:

* a differential replay of ~480 requests per fixture in recorded order (status, headers, JSON, asset
  bytes by hash and length, `HEAD`, ranges, conditional and `If-Range` requests, cursors issued by
  Rails and compared with the ones Go issues, bearer matrix, all four adoption refusals, a successful
  adoption and the final `api_tokens` rows);
* faults: generated EPUB fetched intact and generated audio seeked, replaced, rewritten, deleted and
  symbolic-link-swapped assets, traversal attempts, client disconnect, stalled clients with a live
  catalogue, busy SQLite, live WAL commits and external revocation, shutdown during a transfer,
  startup refusals, single ownership, cursor and secret mismatch, 24 concurrent adoptions, request
  limits, absence of sensitive values from every output;
* 25 mutants of the critical invariants (revoked, expired, deleted-owner credentials, adoption, scope
  check, cursor binding and signature, symbolic links, identity re-check, root allow-list, ranges,
  `HEAD`, conditional requests, stream capacity, unknown schema, missing key, WAL, logging), each of
  which must fail an assertion, and each must compile.

It also checks that the source bundles keep their digests, that the unchanged M0 checker still
accepts both, that the `linux/amd64` and `linux/arm64` builds are byte-reproducible and that the
repository is untouched. All runs use private generated copies and loopback fixtures.

## Not proven

This is synthetic protocol testing against Rails, not a handover. Not covered: a real client or device,
production data or keys, TLS and proxy headers, Kobo, the browser, progress and status writes,
requests, PDF and CBZ, read-along, reference imports, other schema revisions, non-Linux hosts, and
Rails and Go running concurrently against one database. `RAILS_MASTER_KEY` credentials mode and
rotated legacy cursor keys are not supported.

## Rollback

The slice adds `apps/server/cmd/shelfarr-http`, the packages named in this change,
`apps/server/e2e/httpruntime`, `tools/migration/http` and this document. Revert those commits; the
executable is not referenced by anything else.

# Go HTTP runtime: the native consumer read lane

Status: **experimental, default-off, unreachable from production.** Rails remains the only server that
runs. The experimental migration image includes `shelfarr-http`, but its unchanged Rails entrypoint
does not start or route it. The production Dockerfile does not include it. It reads a compatible
Shelfarr SQLite database and library roots that an operator names
explicitly, and serves the part of the native consumer API that installed readers use to browse and
open EPUBs and audiobooks, and to save and read their place and manual reading status. It is the next
backend foundation after M0 (compatibility checker), M1 (durable workflows) and M3 (static TypeScript
Library); it is not a handover.

## What it serves

Authentication is the native bearer credential only. Every route answers `GET` and `HEAD` except the two
progress writes, which answer `PUT`.

| Route | Authentication | Notes |
| --- | --- | --- |
| `/api/consumer/v1/server.json` | none | Public. Reports what *this runtime* implements (see Deliberate differences). |
| `/api/consumer/v1/me` | bearer, `library:read` | `id`, `name`, `username`, visible scopes. |
| `/api/consumer/v1/library` | bearer, `library:read` | Catalogue with Rails-compatible cursors, `q`, `type`, `status`, `sort`, `limit`. |
| `/api/consumer/v1/continue` | bearer, `library:read` | In-progress publications. |
| `/api/consumer/v1/library/:id` | bearer, `library:read` | One publication. |
| `/api/consumer/v1/library/:id/assets/:asset_id` | bearer, `library:read` | EPUB and audiobook bytes: `Range`, `If-Range`, `If-None-Match`, `HEAD`. |
| `GET`, `HEAD` `/api/consumer/v1/library/:id/progress` | bearer, `library:read` | `{"progress": null \| progress}` for the caller's own saved place. |
| `PUT /api/consumer/v1/library/:id/progress` | bearer, `progress:write` | Compare-and-set save of a place (see Progress and reading status). `200` the stored progress, `409` the current one, `422` a refused checkpoint. |
| `PUT /api/consumer/v1/library/:id/reading_status` | bearer, `progress:write` | `{"status": "unread" \| "in_progress" \| "finished"}`; answers the publication representation. |
| `/up`, `/readyz` | none | Liveness, and readiness (database readable, library roots present). |

### Explicitly refused (HTTP 501, `not_implemented_in_go_runtime`, before authentication, no side effects)

Pairing and token creation (`POST auth/device`, `auth/token`), token revocation (`POST auth/revoke`),
`discover`, `requests` (list, show, create, delete), `assets/:id/reading_order`, `read_along`
(manifest, resources, audio), `transfer_grant` and `transfer`. Kobo, browser sessions, CSRF and the browser `/preview` API stay with
Rails. Anything else is `404`. A wrong verb on a served route is `405` with that route's own `Allow` list
(`GET, HEAD`; `GET, HEAD, PUT` for progress; `PUT` for reading status), before authentication and without
touching the credential.

### Refused when a request asks for something this runtime cannot do

| Request | Answer |
| --- | --- |
| `X-Shelfarr-Reader-Formats` naming `pdf` or `cbz` | `501 unsupported_reader_format` |
| `X-Shelfarr-Reader-Features: read-along` on a publication | `501 unsupported_reader_feature` |
| an asset id that resolves to a PDF or CBZ | `501 unsupported_asset_format` |
| an asset, a progress read or write, or a status write of a comic record | `501 unsupported_publication_kind` |
| a progress write whose asset resolves to a PDF or CBZ (a page place Go cannot validate) | `501 unsupported_asset_format`, nothing stored |
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

Two writes happen on every authenticated request, as in Rails, both on `api_tokens` only:

1. `last_used_at` and `updated_at` are set for every authenticated lookup.
2. **Permission-upgrade adoption.** A token that carries `replaces_api_token_id` retires its parent on
   first use: in one immediate transaction the parent must exist for the same owner, both tokens must be
   usable at the moment the transaction holds the write lock (the clock is read after any wait), the parent gets `revoked_at` and `updated_at`, and the new token's pointer is cleared. Any
   refusal (parent revoked, expired, other owner, missing) leaves both rows untouched and answers `401`.
   If the second write fails the revocation rolls back. A concurrent adoption by another request is
   recognised (`replaces_api_token_id` already `NULL`) and revokes nothing twice.

Ownership: the process takes an exclusive `flock` on the explicit `-lock-file` before it opens the
database. A second Go instance exits `3`. **That lock does not fence Rails.** Running Rails and this
runtime against the same database at the same time means two writers of `api_tokens`,
`consumer_progresses` and `consumer_reading_states`; the guarded updates keep each transition atomic
under SQLite's single writer, but one owning backend per write domain remains a handover prerequisite
and this slice does not claim it. No other table is written, ever: no migration, no schema creation,
no key generation. Rails and Go writing the same account's place at the same time is unsupported and
is not covered by any test; sequential use (Rails writes, then Go reads and continues, or the reverse) is
what the verifier proves.

## Progress and reading status

The write domain added by this slice is exactly `consumer_progresses` and `consumer_reading_states`
(plus the existing `api_tokens` touch). Everything below follows `Consumer::ProgressWriter` and
`Consumer::ReadingStatus`; the Rails answers are the oracle, recorded and replayed (see Verification).

* **Compare-and-set per (account, book).** One `BEGIN IMMEDIATE` transaction on the single write
  connection reads the row, decides, writes and commits. The write time is read after the lock is held.
  A first write needs `expected_version` `0`; an update needs the exact current version and stores
  `version + 1`. `expected_version` is an integer literal from `0` to `2^63-2`, parsed exactly (no
  float); a stored version of `2^63-1` can therefore never be matched again.
* **Idempotent retry.** The same `client_mutation_id` with the same asset, locator (compared by value:
  key order and `1` against `1.0` do not matter), position and activity time returns the stored row
  with its original `version`, `updated_at` and `observed_at`, whatever `expected_version` the retry
  carries, and changes nothing. The same id with any different datum is `409`. UUIDs are matched
  case-insensitively by shape but compared byte for byte.
* **Activity time.** `observed_at` is an ISO-8601 time with an explicit zone and a real calendar date,
  at most five minutes ahead of the server, normalised to UTC milliseconds and kept apart from the
  server's `updated_at`. An absent or `null` time stays unknown (`null`), never the upload time. A known
  stored time is replaced only by a later one or an equal one at the same place; unknown on either
  side keeps the version-only rule. `resolve_conflict: true` bypasses only that chronological rule: the
  exact version and the mutation guard still apply.
* **Locators.** An EPUB checkpoint carries `locator` and no seconds. The locator is stored in full
  (key order, numbers as sent) up to 16 KiB; `href` is a relative path of at most 2048 bytes that,
  after percent-decoding, has no leading `/`, `:`, `\`, control character or `..` segment;
  `locations.progression` and `totalProgression` are finite numbers in `[0, 1]`, `position` a positive
  integer and `readAlong` exactly `generation` (64 hex), `audio` (0-1999) and `offset_ms`
  (0-172800000). Every other field is kept. An audiobook checkpoint carries `position_seconds`
  (finite, `0` to 31 days) and no locator. The asset must be one the book currently lists, found with
  the existing identity rules, with filesystem access done before the write transaction opens.
* **Reading status** is a separate row: choosing `unread` or `finished` keeps a saved place, a later
  checkpoint never undoes the choice, and repeating a status does not move its `updated_at` (which
  orders the continue list). The response is the ordinary publication representation, built before
  the write so a failing listing never leaves a changed status behind.
* **Failures.** Contention is `503 database_busy` with `Retry-After`, a deadline `503 request_timeout`,
  an unsupported stored value `501`; never `401`, never an empty success, never a half write.
  A write whose client left (or whose process was killed) before the commit stores nothing; one killed
  after the commit is stored and a retry of the same body returns it unchanged. This is SIGKILL
  testing, not power-loss testing.

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
  [-listen 127.0.0.1:3100] [-allow-non-loopback] [-server-version V] [-android-channels release] \
  [-body-timeout 5s]
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

* Read-header 5s, read 15s, idle 60s, a write deadline equal to the request timeout (20s) for every non-streamed response, 32 KiB headers. Only the two `PUT` routes read a body, and only after authentication and the scope check: at most 64 KiB (`413 request_too_large`, declared or chunked, enforced while reading), within `-body-timeout` (5s, `408 request_body_timeout`, connection closed), as `application/json` (`415 unsupported_media_type`, except an empty body). A refused or unread body is drained or the connection closed by `net/http` (threshold 256 KiB).
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
7. **Request bodies.** Only `application/json` is read (`415` otherwise, where Rails would parse a
   form body and answer `422`, or accept `status=finished`), at most 64 KiB (`413`) and within the body
   timeout (`408`). A malformed body is `400 invalid_json` after authentication and the scope check;
   Rails answers `400` before authentication for bytes that are not UTF-8. A body that is a JSON array,
   string or `null` is an empty object, as in Rails. Comments, a byte-order mark, lone surrogate
   escapes and nesting beyond 100 levels are malformed.
8. **No silent dropping.** Rails' strong parameters drop a nested value sent where a scalar belongs;
   Go refuses it with `422` (`position_seconds` as an object next to an EPUB locator, a non-null
   `locator` next to an audiobook position). Rails removes `null` elements from arrays inside a
   locator; Go stores them. A number outside the finite `float64` range anywhere in a locator is
   `422` (Rails would store `null`). A `href` that decodes to invalid UTF-8 is `422` (Rails raises).
9. **Dates.** `observed_at` must be a proleptic-Gregorian date from 1583 to 9999 in local time and in
   UTC; Rails' calendar-reform handling before 1582 is not reproduced. A locator whose size sits within
   the escaping overhead of the 16 KiB limit may be judged differently.
10. **Media messages.** Every unavailable listing (missing file, EPUB over 250 MiB, folder limits) is
    `422 invalid_progress` with the message `Media is missing or outside the authorized library`;
    Rails words some of these differently.
11. **Wrong verbs.** `POST`, `DELETE` and `PATCH` on a progress route and anything but `PUT` on a status
    route are `405` with an `Allow` list; Rails answers `404`.
12. A `400 invalid_json` carries `Vary: Accept, X-Requested-With` because the Rails answer does.

## Contract before and after

Before the HTTP runtime no Go program accepted an HTTP request: the native consumer API was served by
Rails only. The runtime added `shelfarr-http` with the read routes. Nothing a consumer outside this
repository observes changes with this slice: no route, schema, stored format, configuration key, image
or workflow of the Rails application is touched, and M0's report and `shelfarr-compat` are unchanged.

Experimental Go runtime, before and after this slice (the Rails wire and storage contract is the same
before and after):

```
PUT /api/consumer/v1/library/9001/progress        Authorization: Bearer <progress:write token>
{"asset_id":"<64 hex>","expected_version":0,"client_mutation_id":"<uuid>",
 "locator":{"href":"OEBPS/c1.xhtml","locations":{"progression":0.3,"position":4}},
 "observed_at":"2026-11-07T10:15:30.123+01:00"}

before   501 {"error":"not_implemented_in_go_runtime"}      before authentication, no effect
after    200 {"progress":{"asset_id":"...","locator":{...},"position_seconds":null,"version":1,
                          "observed_at":"2026-11-07T09:15:30.123Z","updated_at":"2026-11-14T12:00:00.250Z",
                          "client_mutation_id":"<uuid>"}}
         409 {"error":"progress_conflict","progress":<current or null>}
         422 {"error":"invalid_progress","message":"..."}   403 {"error":"insufficient_scope","required_scope":"progress:write"}

GET|HEAD /api/consumer/v1/library/9001/progress    before 501    after 200 {"progress":null | {...}}
PUT /api/consumer/v1/library/9001/reading_status   before 501    after 200 <publication> | 422 invalid_reading_status
```

New request shapes are refused explicitly (`405`, `413`, `408`, `415`, `501` as listed above), never with
an empty success. Rows written to `consumer_progresses` and `consumer_reading_states` have exactly the
Rails column forms (`datetime` text with up to microseconds, JSON locator text, `float` seconds), so
the previous Rails code reads them unchanged: rolling back to Rails loses nothing and needs no
migration. Go-internal additions: `library.Lister.Formats` (default EPUB, same listing),
`consumer.NewView`/`Publication`/`NewProgress` exports and an optional `content_kind` field that only a
declared format selection emits, `store.ContentKind*`, `internal/strictjson`, `internal/checkpoint`,
`live.SaveProgress`/`SetReadingStatus`, `Config.BodyTimeout` (`-body-timeout`) and an optional clock.

## Verification

`tools/migration/http/verify-http` is the single entry point. It produces the M0 current-schema and
stable-upgrade bundles with the real Rails code, records real Rails responses over private copies of
both with `tools/migration/http/capture_http_cases.rb`, and then runs, against the race-instrumented
executable:

* a differential replay of ~920 requests per fixture in recorded order (status, headers, JSON, asset
  bytes by hash and length, `HEAD`, ranges, conditional and `If-Range` requests, cursors issued by
  Rails and compared with the ones Go issues, bearer matrix, all four adoption refusals, a successful
  adoption and the final `api_tokens` rows). The ~340 progress and status requests carry their real
  `PUT` bodies and a frozen Rails clock that the replay sets on the Go process (a seam compiled only
  with `-tags e2eclock`, absent from the shipped binary), so `updated_at` and every stored time must be
  identical. After each of them the rows of that book and the `api_tokens` rows that changed must equal
  what Rails left (a refused write must leave the rows as they were, while the credential is still
  touched), and at the end the whole `consumer_progresses` and `consumer_reading_states` tables must
  equal Rails'. Locators are compared as JSON values; `go` overrides name every deliberate difference
  and require the rows to be unchanged;
* faults: generated EPUB fetched intact and generated audio seeked, replaced, rewritten, deleted and
  symbolic-link-swapped assets, traversal attempts, client disconnect, stalled clients with a live
  catalogue, busy SQLite, live WAL commits and external revocation, shutdown during a transfer,
  startup refusals, single ownership, cursor and secret mismatch, 24 concurrent adoptions, request
  limits, absence of sensitive values from every output;
* the real Rails models and controllers reading, projecting, isolating per account and continuing every
  row Go wrote (`verify_go_rows.rb`, 264 checks per fixture);
* progress faults over real sockets and processes: generated EPUB and synthetic audio round trips and
  a restart, 24 concurrent first writes (one wins) and 12 concurrent updaters (none lost), a SIGKILL
  before and after the commit followed by a retry, a client that leaves while holding the write
  lock, an externally held write lock, declared, chunked, stalled and abandoned bodies;
* 53 mutants of the critical invariants (revoked, expired, deleted-owner credentials, adoption, scope
  check, cursor binding and signature, symbolic links, identity re-check, root allow-list, ranges,
  `HEAD`, conditional requests, stream capacity, unknown schema, missing key, WAL, logging, and for
  progress: scope, version, mutation id, retry data, chronological and resolution rules, unknown
  times, isolation, locator comparison, status independence, future tolerance, traversal, version
  range, asset identity, body size, body deadline, content type, comics, PDF pages, conflict and
  malformed-body answers), each of which must fail an assertion, and each must compile.

It also checks that the source bundles keep their digests, that the unchanged M0 checker still
accepts both, that the `linux/amd64` and `linux/arm64` builds are byte-reproducible and that the
repository is untouched. All runs use private generated copies and loopback fixtures.

The `go-http` CI job runs this verifier with full Git history so the pinned stable-schema producer
can read its release object. The experimental packaging checks also cross-build and execute the
binary on amd64 and arm64, assert that it refuses to start without `-experimental`, and verify that
the image keeps the production Rails entrypoint and command.

## Not proven

This is synthetic protocol testing against Rails, not a handover. Not covered: a real client or device,
production data or keys, TLS and proxy headers, Kobo, the browser, progress and status writes,
requests, PDF and CBZ pages, read-along manifests (the `readAlong` locator keys are stored and
validated, nothing more), reference imports, other schema revisions, non-Linux hosts, power-loss
durability (SIGKILL only), and Rails and Go running concurrently against one database. `RAILS_MASTER_KEY` credentials mode and
rotated legacy cursor keys are not supported.

## Rollback

The slice adds `apps/server/cmd/shelfarr-http`, the packages named in this change,
`apps/server/e2e/httpruntime`, `tools/migration/http` and this document. The progress slice adds
`internal/strictjson`, `internal/checkpoint`, `internal/live/progress.go`, `internal/gohttp/progress.go`
and extends the verifier; reverting it restores the `501` answers and leaves every row it wrote
readable by Rails. Revert those commits; the
HTTP executable is also listed in the experimental packaging Dockerfile, package inventory and CI
job; remove those references when reverting the runtime. No production route or entrypoint changes.

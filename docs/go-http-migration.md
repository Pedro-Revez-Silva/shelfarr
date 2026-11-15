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

`discover`, `requests` (list, show, create, delete), `assets/:id/reading_order`, `read_along`
(manifest, resources, audio), `transfer_grant` and `transfer`. Kobo and the browser HTML shell stay with Rails; the browser session and `/preview/api/v1` JSON are described in
[Browser sessions and the preview JSON](#browser-sessions-and-the-preview-json). Anything else is `404`. A wrong verb on a served route is `405` with that route's own `Allow` list
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
and this slice does not claim it. No other table than those listed in each section is written: no migration, no schema creation,
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

## Browser sessions and the preview JSON

Status: experimental, default-off, backend only. No page, script or style is served, no UI changed, Rails stays
the production server. This slice lets the runtime resume the browser session Rails issued, sign a local
account in and out, and answer the session-authenticated JSON the static TypeScript preview already calls. It is
not a login handover: only local password sign-in for accounts that need nothing else is ported.

### What is served

| Route | Authentication | Notes |
| --- | --- | --- |
| `GET`, `HEAD /preview/api/v1/session` | `session_id` cookie, `X-Shelfarr-Account` | `{account, server, links, admin?}`; `links.discover` is `/discover` when Hardcover is enabled and a token or the account's active connection exists (the Rails rule), else `/search`; every other link is the root-mount path. |
| `GET`, `HEAD /preview/api/v1/library`, `/continue`, `/library/:id` | same | The account-bound envelope `{account, items, next_cursor}` / `{account, items}` / `{account, publication}` of `WebPreview::LibraryController`, projected from the Go catalogue and publication services with the browser reader selection (`epub,pdf,cbz`, so Rails-issued cursors keep their identity). |
| `PUT /preview/api/v1/library/:id/reading_status` | same, plus CSRF | `{"status": "unread" \| "in_progress" \| "finished"}`; answers `{account, publication}`. |
| `GET /preview/api/v1/auth/bootstrap` | none or cookie | New. Signed out: `{authenticated:false, csrf_token, expires_in, sign_in:{available, reason}}` and a login nonce cookie. Signed in: `{authenticated:true, account, csrf_token, expires_in}`. It never discloses personal data to a signed-out caller. |
| `POST /preview/api/v1/auth/login` | login CSRF token | New. `{"username","password"}`; answers `{authenticated:true, account, csrf_token, expires_in}` and sets `session_id`. |
| `POST /preview/api/v1/auth/logout` | session CSRF token, `X-Shelfarr-Account` | New. Deletes the caller's `sessions` row and clears the cookie. |

The native `/api/consumer/v1` routes still authenticate bearer credentials only and never read a cookie. The
browser routes never read `Authorization`. No response ever carries a CORS header and `OPTIONS` is `405`.

Guard order is the Rails `WebPreviewAccess` order, evaluated before any personal data is read: allowlist not
configured `404 not_found`; no valid session `401 signed_out`; account not on the allowlist `404 not_found`;
`X-Shelfarr-Account` missing, repeated or not the exact decimal user id `401 account_changed`; then, for a
write, CSRF `422 invalid_csrf`. Guard errors always carry `Cache-Control: private, no-store` (Rails sends
`no-cache` on those four).

### Per-user allowlist

Off unless `-preview-user-ids` or the existing nonsecret `SHELFARR_WEB_PREVIEW_USER_IDS` (not both: `preview-user-ids-ambiguous`)
lists up to 100 comma-separated ids matching `[1-9][0-9]{0,18}`. Unset, blank, malformed (any bad entry), too long:
the preview stays off for everybody (`404`), a warning code is printed, and there is no all-users fallback. It is
read once at start; restart to change it, where Rails re-reads the variable per request. Sign-in for an account off the list is
refused as `401 invalid_credentials` (after a dummy password check) and writes nothing.

### Session cookie and rows, both ways

Verified against the installed Rails 8.1.4.1 and a real login. `session_id` is a signed cookie:
`<base64 {"_rails":{"message":base64(JSON integer id),"exp":"…Z","pur":"cookie.session_id"}}>--<hex HMAC-SHA1>`,
key = PBKDF2-HMAC-SHA256(`secret_key_base`, `signed cookie`, 1000, 64 bytes), `Set-Cookie` value CGI-escaped,
`Path=/; HttpOnly; SameSite=Lax; Expires`, `Secure` only when `-browser-origin` is `https`. Go verifies and issues exactly
that, so a cookie works against both servers and rollback to Rails loses no session.

* Authenticated when the signature, purpose and `exp` hold, a `sessions` row exists, the user row exists and
  is not deleted, and `created_at` is not older than `session_max_age_days` (default 30; the boundary
  instant is still valid). An expired row, or a row of a deleted user, is deleted and the cookie cleared, as in Rails. A
  session whose user row is missing is signed out and kept (Rails raises). A non-integer setting, or one outside
  0-36500, is `501 unsupported_stored_value`, never a guess.
* Cookies longer than 1024 bytes are refused; the first `session_id` cookie wins, as in Rack.
* Day arithmetic is UTC. A Rails deployment with a DST time zone may differ by up to an hour at the exact boundary.
* The encrypted `_shelfarr_session` cookie (Rails CSRF, OIDC, pending OTP) is never read or written.

### CSRF

Go owns it; nothing depends on the Rails cookie session. Tokens are `v1.<s|l>.<expiry>.<HMAC-SHA256>` under a key derived
from `secret_key_base` with its own salt.

* Session token (2 h): bound to session id, user id and the row's creation time, so it dies with logout, expiry and
  re-login. Returned by `bootstrap` and `login`; sent as `X-CSRF-Token`.
* Login token (10 min): bound to a random `shelfarr_login` nonce cookie (`HttpOnly; SameSite=Strict; Path=/preview/api/v1/auth`),
  so a token minted in another browser cannot sign this one in (login CSRF). The nonce is cleared by a successful sign-in.
* Every mutation also needs `Origin` equal to the configured canonical origin (exactly one header; `null` and
  absence are refused) and, when sent, `Sec-Fetch-Site: same-origin`. A refusal is `422 invalid_csrf`.
* Sign-in while a valid session cookie is present is `409 already_signed_in`; an unknown or forged session id is ignored,
  and the new session always gets a fresh id.

`-browser-origin scheme://host[:port]` is required for any write or sign-in (`501 browser_origin_not_configured`
otherwise; reading still works). It must be the origin the browser shows, with no path. **Unsupported:** serving
under a sub-path, TLS or host rewriting that changes the browser's origin, and any use of `Forwarded` or `X-Forwarded-*`
(never read; the client address is the TCP peer, so behind a proxy the sign-in rate limit is shared).

### Sign-in

`POST /preview/api/v1/auth/login` runs in this order, cheapest first, and creates nothing until the end: preview
configured, origin, CSRF, not already signed in, deployment not passwordless, per-address rate limit (10 per 3 min, `-login-attempts`,
`-login-window`; `429` with `Retry-After`; fixed 1024 buckets, bounded memory), body (4 KiB, `application/json`, 5 s), a bounded pool of
password checks (`-max-login-workers`, default 4, 2 s wait, `503 server_busy`), then bcrypt outside any database lock
(cost above 14 is `501 unsupported_stored_value`; passwords above 72 bytes are not accepted). One `BEGIN IMMEDIATE` then
re-reads the user and refuses if the account was deleted, locked, got a different password digest, or gained a second factor
while the check ran or the lock was awaited; otherwise it resets the failure counters (only if dirty) and inserts the
`sessions` row (`user_agent`, `ip_address`, microsecond `created_at`/`updated_at`).

Every credential failure (unknown, wrong, locked, deleted, off the allowlist, stale) is the same
`401 {"error":"invalid_credentials"}`. A wrong password for a real account increments `failed_login_count`, sets
`last_failed_login_at`/`ip`, and at `login_lockout_threshold` (5) sets `locked_until` (`login_lockout_duration_minutes`, 15), in one
transaction, so concurrent failures lock after exactly the threshold. Locked accounts are not counted further.

**Refused explicitly, never bypassed, no session created:** an account with an enabled second factor
(`501 mfa_not_supported`, after a correct password), an account linked to OIDC (`501 oidc_account_not_supported`), and a
passwordless deployment (`auth_disabled` setting or `DISABLE_AUTH=true` in the Go process's own environment, which must match Rails':
`501 sign_in_unsupported`). Signup, recovery and administration are not ported. A valid session that already exists is resumed whatever the
account's later configuration.

Security logs are `{"msg":"security","event":…,"user_id":…}` with fixed events; no username, password, cookie,
token, address or user agent is logged.

### Rows written (the whole list)

`sessions` (insert on sign-in; delete on logout, expiry and deleted user), `users` (`failed_login_count`,
`last_failed_login_at`, `last_failed_login_ip`, `locked_until`, `updated_at`), plus the progress-slice
`consumer_reading_states`. Not written, deliberately: `activity_logs` (Rails records `user.login` and `user.logout`),
queue, cable, cache. One owning backend per table remains a handover prerequisite; Rails and Go writing `sessions` or
`users` at the same moment is unsupported and untested. Required columns now also include the `users` login and
OIDC columns, `sessions` and `hardcover_connections(user_id, status)`; the supported schema revision is unchanged.

### Refused instead of emptied

PDF or CBZ assets, comic records and a description needing an HTML sanitizer are `501` (`unsupported_asset_format`,
`unsupported_publication_kind`, `unsupported_stored_value`) for the whole response, never a missing book and never an empty
success; reader and asset hand-offs stay on Rails. A library that contains one of those cannot be listed by Go yet.
Plain-text descriptions are normalised as `WebPreview::PublicationJson` does; any `<`, `>`, `&`, carriage return or control
character is refused rather than guessed.

### Contract before and after

```
GET /preview/api/v1/auth/bootstrap                                 before 404   after 200 {"authenticated":false,"csrf_token":"v1.l.…","expires_in":600,"sign_in":{"available":true,"reason":null}}
POST /preview/api/v1/auth/login   Origin, X-CSRF-Token, JSON body   before 404   after 200 {"authenticated":true,"account":"5","csrf_token":"v1.s.…","expires_in":7200} + Set-Cookie session_id
                                                                            401 invalid_credentials · 409 already_signed_in · 422 invalid_csrf · 429 rate_limited
                                                                            501 mfa_not_supported | oidc_account_not_supported | sign_in_unsupported | browser_origin_not_configured
POST /preview/api/v1/auth/logout  Origin, X-CSRF-Token, X-Shelfarr-Account   before 404   after 200 {"authenticated":false} + cleared cookie
GET /preview/api/v1/session | library | continue | library/:id        before 404   after the Rails envelopes above (session cookie)
PUT /preview/api/v1/library/:id/reading_status                         before 404   after 200 {account, publication} | 422 invalid_csrf | 422 invalid_reading_status
```

Nothing a consumer outside this repository observes changes in Rails, the schema, the stored formats or the existing Go routes.
New Go-only routes and flags: `-preview-user-ids`, `-browser-origin`, `-login-attempts`, `-login-window`, `-max-login-workers`.
Rollback: stop the Go runtime. Every cookie and row Go wrote is a valid Rails cookie or row, every row Rails wrote works in Go,
and reverting the commits removes the routes without a migration.

### Verification

`tools/migration/browser/verify-browser` (CI job `go-browser`) produces the current and the stable-upgrade bundles with the real
Rails code, records with the real application: Rails-issued sessions (a real `POST /session`, rows built with the real cookie jar),
tampered, wrong-purpose, unknown-row and short-lived cookies, ages at the exact expiry boundary and under a changed `session_max_age_days`, a deleted
user, an account off the allowlist, the preview answers of every route, status writes, lockout and sign-in effects at a frozen clock, and
Rails logout. The race-instrumented executable replays all of it and must match Rails status, headers, JSON, and the resulting `sessions`,
`users` and `consumer_reading_states` rows byte for byte. The real Rails application then loads the cookies and rows Go issued, rejects the revoked
one, reads the lock state Go wrote and accepts a password after Go reset the counters. Real-HTTP tests with a cookie jar cover CSRF
(missing, wrong, replayed across sessions, other origin, `null`, cross-site, stale account, expired), login CSRF, restart durability, the
production clock, 40 concurrent wrong passwords, concurrent sessions, over-cost and rate-limited sign-in, oversized, stalled and duplicated
inputs, the unported modes, SIGKILL before and after the session commit, a client that leaves while holding the lock, and a credential or
account that changes during the password check or the lock wait. Every output is scanned for the synthetic secrets. 48 mutants of
these invariants must each fail an assertion.

Not proven: a real browser, TLS or proxy behaviour, any production data, OIDC, second factors, signup and recovery, PDF and CBZ pages,
read-along, power loss, Rails and Go writing the same rows at once, and clock zones other than UTC.

## Native pairing, token exchange and revoke

Status: experimental, default-off, backend only. This slice lets the runtime run the native connection lifecycle
that installed Android and iOS apps use, with the Rails wire and storage contract. **The browser part is JSON
only.** The consent page the verification address names (`/consumer/connect`, an HTML view) is **not ported**: Rails
keeps serving it, and the TypeScript consent UI is a later slice. Nothing here is a whole native pairing
acceptance claim: no real browser, app or device took part.

### What is served

| Route | Authentication | Notes |
| --- | --- | --- |
| `POST /api/consumer/v1/auth/device` | public, per-address limit 20 per 3 min | `{client_name, scope?}` (JSON). An `Authorization` header asks to **upgrade** that connection. |
| `POST /api/consumer/v1/auth/token` | public, per-address limit 120 per 1 min | `{device_code}` (JSON). |
| `POST /api/consumer/v1/auth/revoke` | bearer, **no scope required** | Ends the whole connection. `204`. |
| `GET`, `HEAD /preview/api/v1/connect?user_code=` | browser session, `X-Shelfarr-Account` | New. Describes a displayed code. Never decides. |
| `POST /preview/api/v1/connect` | browser session, `X-Shelfarr-Account`, CSRF and `Origin` | New. `{user_code, decision: "allow" \| "deny"}`. |

The three native routes answer `Cache-Control: private, no-store` and `Referrer-Policy: no-referrer`; they never read a
cookie. Bodies are JSON objects of at most 64 KiB within `-body-timeout` (an empty body, or a JSON array, string or
`null`, is an empty object, as in Rails). A `GET` on any of the three native routes is `404`, as in Rails.

* **device** returns `{device_code, user_code, verification_uri, verification_uri_complete, expires_in: 600, interval: 5}`
  exactly as Rails does. `device_code` is 32 random bytes as 64 lowercase hex characters; `user_code` is 8 characters of
  `BCDFGHJKLMNPQRSTVWXYZ23456789` shown `XXXX-XXXX`; only their SHA-256 digests are stored. The verification addresses are
  built **only** from `-browser-origin` (`501 browser_origin_not_configured` without it); `Host`, `Forwarded` and `X-Forwarded-*`
  are never read, and only `user_code` appears in `verification_uri_complete`. Root mount only: a deployment under a sub-path is
  unsupported, as for the browser foundation. Order, as in Rails: name (`400 invalid_request`: a string, not blank after Ruby
  `strip` and `[[:space:]]`, at most 80 bytes), then the Authorization header (`401`, empty body, for any bearer that is invalid,
  expired, revoked, ownerless, orphaned, of a deleted owner or without `library:read`; never a fallback to a fresh connection; a
  blank header is no header), then `scope` (`400 invalid_scope`: absent, `null` or whitespace is `library:read progress:write`; the only extras
  are the whole bundle `search:read requests:read requests:write`; anything else, privileged scopes included, is refused). The security
  state of an upgrade (usable origin, same owner, owner not deleted, `library:read`) is **re-read inside the write transaction**.
  Grants expired for more than a day are removed in the same transaction (`expires_at < now - 1 day`), nothing else.
* **token** exchanges once, in one transaction on the grant row: expired or consumed `expired_token`, denied or deleted approver
  `access_denied`, polling faster than the interval `slow_down` (`interval + 5`, at most 60), not yet approved
  `authorization_pending`, then issue. Pending and `slow_down` bookkeeping commits although the answer is `400`. Exactly the same
  precedence and the exact boundary instants as Rails (`expires_at <= now` is expired; a poll exactly `interval` seconds after the
  last one is on time). Issuing inserts the `api_tokens` row (`issued_via consumer_device`, `shf_` plus 40 base58 characters
  chosen by rejection sampling, SHA-256 digest, first-12 prefix, scopes JSON, 30-day expiry, owner, the connection key) and marks the
  grant consumed **in the same commit**. The access token is returned once and never stored; a response lost after the commit
  is **not recoverable**: the retry is `expired_token` (as in Rails) and the app starts again. For an upgrade the previous credential keeps working until the new one is
  first used, so a lost response never strands the connection. A grant never grants administrator scopes, even for an administrator.
* **revoke** revokes every token of the caller's `(user_id, connection_key)` (only the presented token when the key is blank, even for
  whitespace keys) and denies every unconsumed grant that replaces any of them. Rails' `update_all` also rewrites `revoked_at` of
  family members that were already revoked; Go does the same so the rows match. Automatic retirement of an adopted origin never
  revokes the replacement.
* **connect (browser JSON)**, session, allowlist, exact `X-Shelfarr-Account` and the Go CSRF/`Origin` guard from the browser slice apply.
  `GET`/`HEAD` never decide. The answer is `{"account", "account_name", "grant": null | {"pending": true, "decidable": false} | {"pending": true, "decidable": true, "client_name", "upgrade", "requesting", "scopes", "expires_at"}}`:
  an unknown, malformed, expired, decided or used code is `null`; a pending code of another account's connection discloses no
  client name. `POST` answers `200 {"account", "decision": "allowed" \| "denied", "upgrade", "requesting"}`, `400 invalid_request`
  (decision), `403 different_account` (nothing changes), `422 invalid_grant` (unknown, expired, used), plus the guard errors of the
  browser slice. A valid session does not authorize anything by itself: only an explicit decision with CSRF does.

### Rows written (the whole list)

`consumer_device_grants` (insert, poll bookkeeping, decision, consumption, cleanup, denial by revoke) and `api_tokens` (insert on exchange, `connection_key`
assignment on a legacy origin, `revoked_at`/`updated_at` by revoke, plus the adoption and `last_used_at` writes of the bearer lane).
No migration, no new table, no queue, cable or cache. Required columns of `api_tokens` and `consumer_device_grants` are now checked at start
(`database-schema`). One owning backend per table remains a handover prerequisite: Rails and Go writing these tables at the same time is
unsupported and untested; sequential use in either direction is what the verifier proves.

### Deliberate differences from Rails

1. JSON object bodies only. Rails also accepts form or query parameters, which no installed client sends; Go answers `415` for another content
   type and `400 invalid_json` (JSON) where Rails renders its HTML `400` for malformed JSON. An oversized body is `413 request_too_large` (Rails `413` too).
2. Separate rate-limit buckets. Rails' two `rate_limit` rules share one cache key per address, so device creation and polling count against each other;
   Go counts device creations (20 per 3 minutes) and polls (120 per minute) separately, per TCP peer address (no forwarded headers), in fixed windows. The
   verifier replays the Rails limits with a frozen-clock counter that mirrors the documented windows.
3. The verification address needs `-browser-origin`; Rails derives it from the request.
4. A `GET`, `HEAD` or other verb on the three native routes is `404`, as in Rails.
5. `401` for an upgrade whose origin credential became unusable while the request waited (Rails would create the grant and refuse at exchange).
6. After a write timeout the runtime still has two seconds to write its `503 request_timeout` (the write deadline was the request deadline, so the client saw a closed connection instead).

### Contract before and after

```
POST /api/consumer/v1/auth/device   {"client_name":"Pixel","scope":"library:read progress:write search:read requests:read requests:write"}   [Authorization: Bearer <current token>]
  before  501 {"error":"not_implemented_in_go_runtime"}
  after   200 {"device_code":"<64 hex>","user_code":"ABCD-EFGH","verification_uri":"<origin>/consumer/connect","verification_uri_complete":"<origin>/consumer/connect?user_code=ABCD-EFGH","expires_in":600,"interval":5}
          400 invalid_request | invalid_scope   401 (empty)   429 slow_down   501 browser_origin_not_configured
POST /api/consumer/v1/auth/token    {"device_code":"<64 hex>"}
  before  501      after  200 {"access_token":"shf_...","token_type":"Bearer","scope":"...","expires_in":2592000}
                          400 authorization_pending | slow_down | access_denied | expired_token   429 slow_down
POST /api/consumer/v1/auth/revoke   Authorization: Bearer <token>
  before  501      after  204   401
GET  /preview/api/v1/connect?user_code=ABCD-EFGH      before 404   after 200 {"account","account_name","grant":...}
POST /preview/api/v1/connect {"user_code","decision"}   before 404   after 200 | 400 | 403 different_account | 422 invalid_grant | guard errors
```

Rails behaviour, storage formats and the schema are unchanged. Go writes exactly the Rails forms (microsecond datetime text, `scopes` JSON
or `NULL` for the base pair, SHA-256 digests, a UUID v4 connection key), so Rails reads, exchanges, authenticates, adopts and revokes everything Go
wrote, and Go continues everything Rails wrote. Rolling back is stopping the Go runtime; reverting the commits removes the routes and the two
bounded-grace and column checks without a migration.

### Verification

`tools/migration/pairing/verify-pairing` (CI job `go-pairing`) produces both bundles with the real Rails code, records 216 steps per fixture with the
real application at a frozen clock (Rails device creation, polling, the real `/consumer/connect` consent through real sessions, exchange, upgrade,
adoption, revoke, legacy scope storage, cleanup, deleted approvers and owners, the rate limit) together with **the per-step effect on the
`consumer_device_grants` and `api_tokens` rows** (random values are validated structurally and against their persisted digests and connection lineage, never erased), and the race-instrumented executable
must match status, headers, JSON and every row change at every step, and the final tables. It then runs Go against Rails-created pending, approved,
denied, upgrade and family state and leaves Go-created state for the **real Rails models**, which exchange, decide, authenticate, adopt and revoke it
(`verify_go_pairing.rb`). Real sockets and processes cover one exchange under 40 concurrent polls, 24 concurrent decisions, 15 concurrent creations, 20 concurrent adoptions, an
explicit revoke against an adoption in both orders (parked inside the write lock), SIGKILL before and after the commit of creation, exchange, decision and revoke,
a lost upgrade response, an externally held write lock, request deadlines, state changed while a write waited, CSRF, origin and account guards over cookie jars, the
off switches, bounded bodies and concurrency, schema refusal, the production binary on real time with the seams' environment set, and a scan of every output and of the database files for
plaintext secrets. Mutants of the critical invariants must each fail an assertion.

Not proven: a real browser, the HTML consent page, a real app or device, TLS or proxy behaviour, production data, requests and acquisition, transfer grants, the legacy
global-admin API, Rails and Go writing the same rows at once, power loss, clock zones other than UTC, and a deployment under a sub-path.

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
  adoption and the final `api_tokens` rows). The ~350 progress and status requests carry their real
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

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
| `/api/consumer/v1/library/:id/assets/:asset_id` | bearer, `library:read` | EPUB, audiobook, PDF and CBZ bytes: `Range`, `If-Range`, `If-None-Match`, `HEAD`. PDF and CBZ are `attachment` under a restrictive document policy. |
| `POST /api/consumer/v1/library/:id/assets/:asset_id/transfer_grant` | bearer, `library:read` | `201 {"url","expires_at"}`: a relative path that fetches this exact asset generation without the bearer (see [Background transfer grants](#background-transfer-grants)). |
| `GET`, `HEAD /api/consumer/v1/library/:id/assets/:asset_id/transfer?grant=<opaque>` | the grant only | The bytes of `assets/:asset_id` with the same range, validator and fixed-layout behaviour; no `Authorization`, no cookie. |
| `GET`, `HEAD /api/consumer/v1/library/:id/assets/:asset_id/reading_order` | bearer, `library:read` | The page list of one CBZ generation (see [Fixed-layout publications](#fixed-layout-publications-pdf-cbz-comics)). |
| `GET`, `HEAD` `/api/consumer/v1/library/:id/progress` | bearer, `library:read` | `{"progress": null \| progress}` for the caller's own saved place. |
| `PUT /api/consumer/v1/library/:id/progress` | bearer, `progress:write` | Compare-and-set save of a place (see Progress and reading status). `200` the stored progress, `409` the current one, `422` a refused checkpoint. |
| `PUT /api/consumer/v1/library/:id/reading_status` | bearer, `progress:write` | `{"status": "unread" \| "in_progress" \| "finished"}`; answers the publication representation. |
| `/up`, `/readyz` | none | Liveness, and readiness (database readable, library roots present). |

### Explicitly refused (HTTP 501, `not_implemented_in_go_runtime`, before authentication, no side effects)

`discover`, `requests` (list, show, create, delete) and `read_along`
(manifest, resources, audio). Kobo stays with Rails; the browser session and `/preview/api/v1` JSON are described in
[Browser sessions and the preview JSON](#browser-sessions-and-the-preview-json). Anything else is `404`. A wrong verb on a served route is `405` with that route's own `Allow` list
(`GET, HEAD`; `GET, HEAD, PUT` for progress; `PUT` for reading status), before authentication and without
touching the credential. The two transfer routes answer every other verb `404`, as Rails does.

### Refused when a request asks for something this runtime cannot do

| Request | Answer |
| --- | --- |
| `X-Shelfarr-Reader-Features: read-along` on a publication | `501 unsupported_reader_feature` |
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

## Background transfer grants

Status: experimental, default-off, no handover; the grant format is Rails' own, so Rails and this runtime accept each
other's grants under the same `secret_key_base`. System download managers persist their requests and follow redirects
unattended, so they must not hold the account bearer. The app asks for a grant with its bearer and hands the manager
a URL that names one exact asset generation. This slice ports `Consumer::TransferGrant`, `LibraryController#transfer_grant`
and `TransfersController#show`; it adds no schema, no table, no route Rails lacks and no `server.json` capability
(`consumer_features` still lists no grants: Rails advertises none either).

### The envelope, byte for byte

```
grant      = base64url(ciphertext) "--" base64url(nonce, 12 bytes) "--" base64url(tag, 16 bytes)      no padding
key        = PBKDF2-HMAC-SHA256(secret_key_base, "shelfarr consumer transfer grant v1", 1000 iterations, 32 bytes)
cipher     = AES-256-GCM, empty additional data, a fresh random 96-bit nonce per grant
plaintext  = {"_rails":{"data":{"t":<token id>,"u":<user id>,"b":"<book id>","a":"<asset id>"},
              "exp":"2026-11-16T10:00:00.987Z","pur":"consumer_transfer_grant"}}
```

This is `ActiveSupport::MessageEncryptor` (8.1.4.1) with `cipher: "aes-256-gcm"`, `serializer: :json`, `url_safe: true`, the
Rails key generator (SHA-256, 1000 iterations) and JSON metadata, read back from real Rails output; it is not the
signed-cookie or encrypted-column key. A grant minted by Go has the same plaintext as the grant Rails mints for the same
claims at the same instant (the verifier compares them byte for byte) and the same length. Lifetime is `min(now + 24 h,
issuing token expiry)`; `exp` is that instant truncated to milliseconds, the mint answer's `expires_at` truncated to seconds,
and a grant is dead from `exp` itself (`now >= exp`), as in Rails. Rotating `secret_key_base` kills every grant; a missing or
unusable key already refuses to start and no key is generated.

Reading refuses, without saying why: a value outside `[A-Za-z0-9_-]{32,2048}`; a part missing, mis-sized or not canonical
base64url; a failed tag; a purpose other than `consumer_transfer_grant`; no or a malformed `exp`, or `exp` reached;
claims that are not exactly the four keys with `t` and `u` plain positive integers and `b` and `a` strings. Nothing is
allocated from a declared size; the input is bounded before it is decoded.

### Who may use a grant

Every use re-reads `api_tokens` and `users`: the token `t` must exist, be unrevoked and unexpired at the moment of use, belong
to user `u`, whose row must exist and not be soft-deleted, and still carry `library:read`, read exactly as for the bearer: a JSON string or an array of strings, split on commas and whitespace; a column this runtime cannot parse (malformed JSON, a lone surrogate escape, nesting beyond 100 levels; Rails also rejects most of these, see the deliberate differences) carries no scope, so the grant is `401`, and any other stored form (`null`, a number, an object, an array holding something other than strings) is `501 unsupported_stored_value`, never a delivery (see the deliberate differences below). Nothing is cached, so a revocation,
an expiry, a lost scope, a changed or deleted owner or a deleted token takes effect on the next request and restoring the row
revives the grant. The grant must name the same book and asset as the path. It opens only that book's exact asset
generation, with `GET` or `HEAD`; it is not a credential anywhere else (every other route, including the mint, ignores a
`grant` parameter, and a grant sent as a bearer is `401`). The mint is the only request that authenticates the bearer and
therefore the only one that records `api_tokens.last_used_at`/`updated_at` and the adoption of a replacement credential; a
transfer writes nothing, so it also cannot move saved places or reading status. A grant minted by a token that has not yet
adopted its parent keeps working, a grant of the retired parent dies with the parent's `revoked_at`.

### Query grammar

The transfer route reads `request.query_string` against `\Agrant=([^&;=]+)\z` and then the alphabet and length above. Anything
else is `401 invalid_grant`: no query, `grant=`, a repeated, extra, leading, trailing or `;`-separated parameter, an encoded
(`gr%61nt`), upper-case, array (`grant[]`) or nested (`x[grant]`) key, a padded, percent-encoded, `+`, over- or under-long value.
`Authorization`, cookies and `X-Shelfarr-Reader-Formats` are never read: a valid grant with garbage credentials is `200`, a
bad grant with a perfect bearer is `401`.

### Answers

| Request | Answer |
| --- | --- |
| mint, no or bad bearer | `401` (empty), as every bearer route |
| mint, token without `library:read` | `403 {"error":"insufficient_scope","required_scope":"library:read"}` |
| mint, unknown or non-acquired book | `404 {"error":"not_found"}` |
| mint, asset that is not a current supported asset of that book, or whose file changed | `410 {"error":"asset_unavailable"}` |
| mint, body over 64 KiB / not read within `-body-timeout` | `413 request_too_large` / `408 request_body_timeout` (after authentication) |
| mint, `application/json` body that is not valid JSON | `400 {"error":"invalid_json"}`; any other body or none is ignored |
| mint | `201 {"url":"/api/consumer/v1/library/:id/assets/:asset_id/transfer?grant=...","expires_at":"2026-11-16T10:00:00Z"}`; `Cache-Control: private, no-store`, `Referrer-Policy: no-referrer`, no `Location` |
| transfer, any invalid, expired, mis-bound or no-longer-authorised grant | `401 {"error":"invalid_grant"}`, private, `no-referrer`; the same for `HEAD` without a body |
| transfer, book no longer acquired / unknown | `404 {"error":"not_found"}` |
| transfer, asset replaced, removed or malformed | `410 {"error":"asset_unavailable"}` |
| transfer, valid | exactly the bearer asset answer: `200`/`206`/`304`/`416`, `ETag`, `Accept-Ranges`, `Content-Length`, `Content-Range`, `If-Range`, attachment and document policy for PDF and CBZ, no redirect |
| transfer or mint, any other verb or a `.json` suffix | `404` |
| transfer, all media slots busy | `503 server_busy` with `Retry-After` |

A transfer takes a media-stream slot (`-max-media-streams`) like the bearer asset route and answers a full pool `503 server_busy` with the same private headers; the mint takes a metadata slot. The file
is the descriptor-pinned, root-confined, identity-checked open of the bearer route, and a client that leaves or stalls returns its
slot exactly as there. A request already authorised when its token is revoked finishes; the next one is refused.

### Rows written

Mint: `api_tokens.last_used_at` and `updated_at` of the issuing token (and the documented adoption when it replaces a credential),
nothing else. Transfer: nothing. No migration, no table, no file.

### Contract before and after

```
POST /api/consumer/v1/library/9001/assets/<asset>/transfer_grant      Authorization: Bearer <library:read token>
before  501 {"error":"not_implemented_in_go_runtime"}                  before authentication, no effect
after   201 {"url":"/api/consumer/v1/library/9001/assets/<asset>/transfer?grant=<280 characters>","expires_at":"2026-11-16T10:00:00Z"}

GET|HEAD /api/consumer/v1/library/9001/assets/<asset>/transfer?grant=<opaque>
before  501 {"error":"not_implemented_in_go_runtime"}
after   200/206/304/416 as the bearer asset route | 401 {"error":"invalid_grant"} | 404 {"error":"not_found"} | 410 {"error":"asset_unavailable"}

grant minted by Rails  ->  accepted by Go, same secret, also after a Go restart        (rollforward)
grant minted by Go     ->  accepted by Rails, same secret                                (rollback)
```

Rolling back to Rails needs no migration: grants in flight keep working, and the ones Go minted decrypt under Rails.

### Deliberate differences from Rails

1. **Transfer queries.** A percent-encoding error in an *unrelated* parameter (`?x%FF=1`) is `400` in Rails, which parses the query
   before the controller runs; here the route is `401 invalid_grant`. A malformed query that carries a grant-like key is `401` in both
   (Rails' `ConsumerGrantQueryGuard` answers before the application, with different headers: here the ordinary private answer). Rails'
   guard and log filter also protect *other* routes (`/me?gr%61nt=%` is `400 invalid_request` in Rails); Go does not parse queries it
   does not read, never logs a query, and answers those routes as before.
2. **Mint bodies.** Rails answers an oversized mint body `413` before authentication; here it is read after authentication and the scope
   check, like every other body in this runtime (documented difference 7). Only `application/json` is validated (`json.Valid`, which
   accepts and rejects the same documents as Rails' parser for ordinary input); other media types are ignored.
3. **Paths.** The URL is root-relative with no `SCRIPT_NAME` prefix, as `content_url` in this runtime; format suffixes (`.json`) are `404`.
4. **Unmodelled scope columns.** Rails normalises any JSON in `api_tokens.scopes` (`[null, "library:read"]` and `{"library:read,x":1}` carry `library:read` there); this runtime models only strings and arrays of strings, for grants exactly as for the bearer, and answers anything else `501 unsupported_stored_value` instead of approximating Rails' normalisation. Its parser is also stricter than Rails' (no comments, at most 100 nested levels, NUL padding is not stripped, any lone surrogate escape is malformed), so a few hand-written columns Rails reads as carrying `library:read` carry nothing here; every such difference refuses, it never serves a grant Rails would refuse. No scope list Rails or this runtime writes takes any of these forms.
5. **Strict claims.** Rails would accept a claim `"t":"5"` or `5.0` (ActiveRecord casts it) or extra claims; only a holder of the key can
   write one, neither Rails nor Go ever does, and Go refuses them.
6. **Error bodies and headers.** Rails renders an exception page for its `404`s and answers a grant-like malformed query from a
   middleware with fewer headers; the status code and the JSON `error` code are the compared contract, as in difference 2 of the
   general list below.

## Browser sessions and the preview JSON

Status: experimental, default-off, JSON only unless the browser screens below are also switched on. Rails stays
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

A description that cannot be rendered safely as plain text is `501 unsupported_stored_value` for the whole response, never a
missing book and never an empty success. PDF, CBZ and comic publications are listed, projected and given a status like any
other (see [Fixed-layout publications](#fixed-layout-publications-pdf-cbz-comics)); reading them in the browser, the
reader and its asset hand-offs stay on Rails, and the Go preview offers no reader link for them.
Plain-text descriptions are normalised as `WebPreview::PublicationJson` does; any `<`, `>`, `&`, carriage return or control
character is refused rather than guessed.

### Fixed-layout publications (PDF, CBZ, comics)

Status: experimental, default-off, no handover. This slice closes the `501` answers for PDF, CBZ and
comic records on the consumer v1 routes and in the Go preview JSON. It adds no schema, no route a Rails
client does not already call (the Rails routes `reading_order` and `assets/:id` exist), no stored format
and no capability: the Rails answers recorded by the verifier are the oracle.

### Capability negotiation

`X-Shelfarr-Reader-Formats` selects what a response lists, exactly as in Rails (`Consumer::ReaderFormats`):

| Header | Selection | Records listed | Assets listed | `content_kind` | Cursor identity |
| --- | --- | --- | --- | --- | --- |
| absent | legacy | ebook and audiobook | EPUB and audio | absent | the pre-negotiation identity |
| `epub` (or `epub,epub`) | `epub` | ebook and audiobook | EPUB and audio | `book` / `graphic` | the same identity as absent |
| names containing `pdf` or `cbz` | normalised (sorted, de-duplicated, padded names trimmed) | the above and comic records, presented as `ebook` | only the named formats (audio always) | `book` / `graphic` | bound to the normalised list |
| empty, unknown, upper-case, trailing comma, over 64 bytes | refused | | | | `400 invalid_request` on library, continue, publication and status |

`Vary: X-Shelfarr-Reader-Formats` is declared on every response that reads the header, as Rails does (including its
repeated value on the library). A comic record is reachable by id for assets, progress, reading order and status
without any header, and by id on the publication route only for a client that named a graphic format. An EPUB stored in a
comic record is listed as an EPUB. `server.json` advertises `["cbz","epub","pdf"]`.

### Asset bytes

`GET`/`HEAD /api/consumer/v1/library/:id/assets/:asset_id` serves PDF (`application/pdf`, at most 500 MiB, `%PDF-d.d` within
the first 1024 bytes) and CBZ (`application/vnd.comicbook+zip`, at most 2 GiB, a valid page list) through the existing bounded
streaming machinery: the file is opened through a descriptor confined to its library root, its identity (device, inode, size,
change and modification times) is recomputed from that descriptor and compared with the asset id, and the same descriptor is
streamed. A file that is replaced, truncated or deleted after the listing is `410 asset_unavailable`; it is never
reopened by name. A PDF or CBZ differs from an EPUB only by `Content-Disposition: attachment` and
`Content-Security-Policy: default-src 'none'; sandbox; frame-ancestors 'none'; form-action 'none'; base-uri 'none'`.

```
GET /api/consumer/v1/library/12/assets/<asset>        Authorization: Bearer <library:read token>
before  501 {"error":"unsupported_asset_format"}
after   200 Content-Type: application/vnd.comicbook+zip   Content-Disposition: attachment; filename="Comic.cbz"; filename*=UTF-8''Comic.cbz
        Content-Security-Policy: default-src 'none'; sandbox; ...   ETag: "<asset>"   Accept-Ranges: bytes   Cache-Control: private, no-store
        206 / 304 / 416 / HEAD exactly as for an EPUB
```

### Reading order

`GET`/`HEAD /api/consumer/v1/library/:id/assets/:asset_id/reading_order` (scope `library:read`) answers for the exact CBZ
generation the id names, read from ZIP metadata alone on the pinned descriptor. Nothing is inflated, extracted or decoded.

```
before  501 {"error":"not_implemented_in_go_runtime"}
after   200 {"asset_id":"<asset>","format":"cbz","items":[
          {"position":1,"href":"page%201.png","media_type":"image/png","size_bytes":60,"compressed_size":41,
           "compression_method":8,"local_header_offset":0,"crc32":"c17b226a"}, ...]}
        410 {"error":"asset_unavailable"}   an id that is not a listed CBZ of this book, a replaced or malformed archive
        404 / 403 / 401 as for every library route
```

The publication's CBZ asset gains `page_count` and `reading_order_url` (also Rails'); other formats gain nothing. The list is
the archive's central directory validated by `internal/zipdirectory`, then `internal/comic`:

* **Structure** (Rails `Consumer::ZipDirectory`, refused wholesale, never an empty list): one unambiguous end record whose
  comment reaches the end of the file, one disk, a directory that ends exactly where that record begins, 1 to 10 000 entries,
  a directory of at most 2 MiB, names of 1 to 1024 bytes, no ZIP64 locator or sentinel, only stored or deflated entries, no
  encryption, masked-header or reserved flag, no ZIP64, Unicode-path or AES extra field, no symbolic link, device or pipe, no
  absolute, drive, backslash, control, `.`, `..` or empty path part, names that are UTF-8 (or ASCII without the flag), no two
  names equal after Unicode NFC, no folder with data, local headers that repeat the directory (name, flags, method, and sizes
  and CRC unless a data descriptor defers them), entries that stay in front of the directory and never overlap. The standard
  library's `archive/zip` is not used for this: it accepts ZIP64, ambiguity and the other forms above.
* **Pages** (Rails `Consumer::ComicArchive`): visible `jpg`, `jpeg`, `png` and `webp` entries (extension compared
  case-insensitively); `.`-prefixed parts and `__MACOSX` are hidden; a page is 1 byte to 32 MiB decoded and at most
  32 MiB + 64 KiB compressed, all pages total at most 2 GiB, the page list at most 8 MiB, and at least one page is required.
  Pages are ordered naturally (digit runs numerically, text case-insensitively, the exact name breaking ties) and numbered
  from 1. `href` percent-escapes every byte outside `A-Za-z0-9-._~/`.
* **Cost.** Metadata only, bounded before allocation, read with positioned reads on the pinned file, and the request context
  is checked between reads, so a deadline or a departed client stops a scan. A validated page count is remembered per asset id
  (512 entries; the id changes with the file's size, inode and times).
* **Unicode.** NFC and lower-casing use `golang.org/x/text` (a new dependency). Compared with Ruby 3.3.13 (Unicode 15.0) over
  every scalar value, normalisation is identical; lower-casing differs for the code points that Unicode 16 and 17 assigned
  (55 of them), which Go leaves unchanged exactly as Ruby does, and for Greek final sigma, which Go does not apply and Ruby does not
  apply either. If the Ruby runtime moves to a newer Unicode version, `internal/naturalorder` must follow it.
  The same ordering now sorts the files of a folder publication (audio tracks and fixed-layout files); before this slice it
  used `strings.ToLower`, which differs from Ruby for `İ`, final sigma and the same 55 code points.

### Page places

`PUT /api/consumer/v1/library/:id/progress` accepts a place for a PDF or CBZ asset through the existing compare-and-set; the row
is the same `consumer_progresses` row an EPUB writes, with the locator stored as sent. After the generic locator checks:

| Asset | Required |
| --- | --- |
| both | only the keys `href`, `type`, `title` (string of at most 1024 bytes), `locations`, `text` (object) in the locator; only `position`, `progression`, `totalProgression`, `fragments` in `locations`; `locations.position` an integer (not `1.0`) from 1 to 100 000 |
| PDF | `href` `document.pdf`, `type` `application/pdf`, `fragments` absent, `null` or exactly `["page=N"]` for position N; the server does not parse PDF pages |
| CBZ | no `fragments` key at all; `href` and `type` equal item N of the reading order of that exact generation (re-read from the pinned file, outside the write transaction) |

An EPUB asset, whatever the record type, keeps its EPUB rules. The filesystem is read before the write transaction; a refused,
stale or replaced asset leaves every progress, status and time row unchanged. Status (`PUT .../reading_status`) works for every
record Rails accepts, including comic records and with any valid `X-Shelfarr-Reader-Formats`.

```
PUT /api/consumer/v1/library/12/progress   {"asset_id":"<cbz>","expected_version":0,"client_mutation_id":"<uuid>",
  "locator":{"href":"p2.png","type":"image/png","locations":{"position":2,"totalProgression":0.5}}}
before  501 {"error":"unsupported_publication_kind"}      (a comic record)   or   501 unsupported_asset_format
after   200 {"progress":{...,"version":1,"locator":{...as sent...}}}
        409 progress_conflict   422 {"error":"invalid_progress","message":"This page is not page 2 of the comic's reading order; refresh the publication"}
```

### Go preview JSON

`/preview/api/v1/library`, `/continue`, `/library/:id` and `PUT .../reading_status` project fixed-layout books exactly like
`WebPreview::PublicationJson`: `format_label` `PDF` or `Comic`, `files[].page_count` (the CBZ page count, `null` otherwise),
`progress.page` (an integer position of a fixed-layout locator type) and the `Page N` progress label. The reader link of such a
book is still the Rails reader path; the Go screens add none.

### Rows and files written

None beyond the existing `consumer_progresses` and `consumer_reading_states` rows and the `api_tokens` touch. Nothing is
written to the library. The fixtures are synthetic; no real book is read.

### Rollback and limits

Revert the commits of this slice: the `501` answers return and every row it wrote stays readable by Rails (it is the Rails row
format). Not covered: a rendering or page-decoding client, ZIP resource extraction, EPUB read-along, reference-import
symbolic links (still `501 unsupported_library_layout`), a comic archive other than the synthetic and fuzzed ones, and archives whose
names use code points assigned after Unicode 15.0 (see above).

## Contract before and after

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

`tools/migration/pairing/verify-pairing` (CI job `go-pairing`) produces both bundles with the real Rails code, records 217 steps per fixture with the
real application at a frozen clock (Rails device creation, polling, the real `/consumer/connect` consent through real sessions, exchange, upgrade,
adoption, revoke, legacy scope storage, cleanup, deleted approvers and owners, the rate limit) together with **the per-step effect on the
`consumer_device_grants` and `api_tokens` rows** (random values are validated structurally and against their persisted digests and connection lineage, never erased), and the race-instrumented executable
must match status, headers, JSON and every row change at every step, and the final tables. It then runs Go against Rails-created pending, approved,
denied, upgrade and family state and leaves Go-created state for the **real Rails models**, which exchange, decide, authenticate, adopt and revoke it
(`verify_go_pairing.rb`). Real sockets and processes cover one exchange under 40 concurrent polls, 24 concurrent decisions, 15 concurrent creations, 20 concurrent adoptions, an
explicit revoke against an adoption in both orders (parked inside the write lock), SIGKILL before and after the commit of creation, exchange, decision and revoke,
a lost upgrade response, an externally held write lock, request deadlines, state changed while a write waited, CSRF, origin and account guards over cookie jars, the
off switches, bounded bodies and concurrency, schema refusal, the production binary on real time with the seams' environment set, and a scan of every output and of the database files for
plaintext secrets. 58 mutants of the critical invariants (codes, scopes, boundaries, precedence, bookkeeping, consumption, lineage, storage, decisions, revoke, headers, limits, guards, schema) must each compile and fail an assertion.

Not proven: a real browser, the HTML consent page, a real app or device, TLS or proxy behaviour, production data, requests and acquisition, a physical download manager or real device, the legacy
global-admin API, Rails and Go writing the same rows at once, power loss, clock zones other than UTC, and a deployment under a sub-path.

## Browser screens: sign-in, native connection consent and Library (opt-in)

Status: **experimental, default-off.** With one extra explicit option the Go runtime also serves the static
TypeScript/React screens the pilot needs, so a browser can sign in, deliberately approve or decline a native app
connection and browse the existing Library and details without Rails. Reading EPUBs and listening to audiobooks online
were added later (see [Online EPUB reader and audiobook player](#online-epub-reader-and-audiobook-player-opt-in)).
Downloads, offline, PWA, PDF and comic rendering, Discover, requests and administration stay with Rails and are shown as
unavailable (Open Library search was added later, see [Discover](#discover-open-library-search-opt-in), and reading
requests later still, see [Requests](#requests-read-only-list-and-detail-opt-in)), never as dead links. No JavaScript runtime is involved at serving time.

### Switching it on

All four must hold, otherwise every route below answers the same JSON `404 not_found` as before and nothing
about the existing commands changes: `-experimental`, a well-formed per-user allowlist (`-preview-user-ids` or
`SHELFARR_WEB_PREVIEW_USER_IDS`; unset or malformed stays off even for a signed-out visitor), the canonical
`-browser-origin` (sign-in and every write need it; without it the sign-in screen says so) and
`-web-assets-dir ABSOLUTE_DIRECTORY`, the output of `bun run build:go --out DIRECTORY` in `apps/web`. A relative or
unclean path is refused before the file system is touched, a missing directory, or one with a symbolic-linked, FIFO, oversized, tampered or
inconsistent file, is `refused: web-assets` (exit `2`) and nothing listens; the working directory is never read and
no catch-all is ever served. Packaging: the experimental overlay image carries the same build in
`/usr/local/share/shelfarr/web`; the Rails `ENTRYPOINT` and `CMD` are unchanged.

### What is served (root mount only)

| Route | Answer |
| --- | --- |
| `GET`, `HEAD /preview` | `303` to `/preview/library`. |
| `GET`, `HEAD /preview/library`, `/preview/library/{id}` | The HTML shell (`id` is `[1-9][0-9]{0,18}`). One static document per view, identical signed in or out; direct loads, reloads and Back/Forward work. |
| `GET`, `HEAD /preview/library/{id}/read` | The reader shell, with its own policy (see the reader section). `404` when the asset build has no reader engine. |
| `GET`, `HEAD /consumer/connect` | The shell for the consent screen. The path is exactly the native `verification_uri`, and `?user_code=` the `verification_uri_complete`. |
| `GET`, `HEAD /preview/assets/{name}` | A file listed in the verified manifest. |
| any other method on those paths | `405`, `Allow: GET, HEAD`, no side effect (a `POST /consumer/connect` approves nothing). |
| everything else, including `/preview/api/*`, `/admin` and unknown paths | JSON `404`; never the shell. |

The shell is `private, no-store`, `lang="en"`, carries no account, token or cookie and sets the policy
`default-src 'none'; script-src 'self'; style-src 'self'; font-src 'self'; img-src 'self' https:; connect-src 'self';
manifest-src 'none'; form-action 'none'; base-uri 'none'; frame-ancestors 'self'; object-src 'none'` (stricter than the
Rails preview: no `data:` images, no manifest, no form action). The consent shell also sends `Referrer-Policy:
no-referrer`. The only inline element is the non-executable `application/json` boot block. Assets are public,
content-addressed (`name.<first 16 hex of sha256>.ext`), served from memory with a strong `ETag`,
`Cache-Control: public, max-age=31536000, immutable`, `X-Content-Type-Options: nosniff`, the right type and
`Cross-Origin-Resource-Policy: same-origin`; `HEAD`, conditional and range requests are answered. At most 32 files,
2 MiB each and 8 MiB in total are accepted; extensions are limited to `js`, `css`, `ttf`, `woff2` and `png`; no source
maps, no listing, no manifest download.

### Sign-in, consent and Library behaviour

* The browser calls the existing JSON (`auth/bootstrap`, `auth/login`, `auth/logout`, `connect`, `session`,
  `library`, `continue`, `reading_status`) with the Go CSRF mechanism and `X-Shelfarr-Account`. Native bearer
  credentials are never minted into the page, and the session token lives only in memory; nothing is stored in
  `localStorage`, `sessionStorage` or a URL. A rejected or expired token is refreshed with a safe `GET`, the page says
  so, and the mutation is never resent by itself.
* Sign-in happens in place at the requested address, so the return to the intended screen cannot be an open redirect.
  Invalid credentials, lockouts (indistinguishable from invalid credentials, as in Rails), rate limits, a busy
  server, a second factor, an OIDC account and a passwordless deployment each have an explicit message; none has a
  bypass or a recovery link.
* Consent shows the signed-in account, the bounded app name, the displayed code and exactly the scopes the server
  returned, with fresh-base, requesting-bundle and upgrade wording. Loading or reloading never approves. One click or
  Enter sends one decision; after an uncertain answer nothing is resent and only the read-only status check is offered.
  A code that belongs to another account reveals nothing (the JSON already redacts it) and offers a safe sign-out and
  switch. Expired, used and invalid codes and both outcomes have terminal states.
* Library, details and manual reading status reuse the existing screens and the generation-based account trust,
  request cancellation, query-cache clearing and per-request `X-Shelfarr-Account`. A sign-out, an account change
  elsewhere or a late response can neither show nor change another account's data.
* Markup in a book description is converted to plain text with the HTML5 tokenizer and parser from
  `golang.org/x/net`, following the Rails `PublicationJson#plain_text` steps (closed `script`/`style` removal, block
  tags to line breaks, all remaining tags removed, entities decoded, `U+00A0` shown as the literal `&nbsp;` exactly as
  Rails does, whitespace normalised) and rendered as text only. 800 inputs, including XSS payloads, are replayed
  against the real Rails conversion (`tools/migration/plain_text_oracle.rb`); input Rails cannot convert (nesting
  deeper than its parser accepts) and CDATA inside `svg`/`math` are refused with `501 unsupported_stored_value`, and
  Go refuses nesting beyond 256 levels. Read-along refusals are unchanged and are explained on screen.

### Deliberate limits of this pilot

* JavaScript is required. There is no native form fallback: the JSON API keeps its CSRF and origin rules and
  `form-action 'none'` blocks a native submission, so the pages show a plain `noscript` message instead.
* Root mount only: no sub-path, proxy-prefix or Safari support is claimed or tested; only headless Chromium and a
  real SQLite file were exercised.
* Downloads, offline use, the PWA and its `/read` worker, PDF and comic rendering, read-along, Discover, requests and
  administration are later slices and appear as unavailable.

### Contract before and after

* New (all additive): the option `-web-assets-dir`; the exit-`2` code `refused: web-assets`; the routes in the table
  above; the manifest format `{version:1, entry:{script,style,reader_engine?}, files:{name:{sha256,size}}}`; the boot block
  `{"version":1,"runtime":"go","view":"library|details|connect","mount":"/preview","api":"/preview/api/v1"}`.
* Unchanged: every native `/api/consumer/v1` route and answer, every `/preview/api/v1` JSON shape, the cookies, the
  CSRF tokens, the Rails preview shell and its boot block `{version, account, mount, api, classic_library}` (the
  client reads either; a boot block without `runtime` is Rails'), and `verification_uri`/`verification_uri_complete`.
  A description with markup no longer answers `501 unsupported_stored_value`; it answers `200` with plain text.
* Sessions and consent rows created by the Go screens are the same rows Rails writes, so Rails reads them.

### Verification

`tools/migration/web/verify-web` (CI job `go-web`) installs from the lockfile, type-checks, runs the Bun unit tests
and `bun audit`, builds the Rails and the Go-served assets (the latter twice, byte-compared), runs the Go tests with
the race detector, builds the production binary twice and compares it, replays the plain-text corpus through real
Rails, produces the synthetic fixture with real Rails and then drives a real headless Chromium (muted, with an owned
null audio sink) against the production binary, the production static build and a real SQLite copy: sign-in and
failures, revocation, a Rails-issued session, stale accounts across tabs, CSRF failures, the whole native workflow
(request, open `verification_uri_complete`, sign in, inspect, Allow or Not now, poll, authenticate, save and read a
checkpoint, upgrade, wrong account, expiry, duplicate click, uncertain answer), Library, details, manual status,
account isolation, plain-text descriptions, static serving, the opt-in and failure cases, zero CSP violations, axe,
keyboard, light/dark, phone/desktop and 200% text. `tools/migration/packaging/verify-packages` additionally checks the
assets inside the overlay image against their manifest.

### Rollback

Stop passing `-web-assets-dir` (or the allowlist): every route above returns to a JSON `404` and no state needs
migrating. Reverting the commits removes `internal/webassets`, `internal/gohttp/web.go`, `apps/web/src/go`, the
Go-mode components and the verifier; the `golang.org/x/net` dependency goes with them. Existing Go sessions stay valid
for Rails and for the previous Go build.

## Online EPUB reader and audiobook player (opt-in)

Status: **experimental, default-off, online only.** Behind the same four switches as the browser screens, a signed-in,
allowlisted account can open an EPUB or an audiobook from Library or Details, read or listen in the browser and keep its
place in the existing `consumer_progresses` row. Nothing here is offline: no worker, cache, outbox, download or install
claim, and the Rails `/read` PWA identity, worker scope, outbox keys and downloads are untouched.

### What is served

| Route | Authentication | Answer |
| --- | --- | --- |
| `GET`, `HEAD /preview/library/{id}/read` | none (static shell) | The reader shell. Policy: `default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline' blob:; font-src 'self' blob: data:; img-src 'self' https: blob: data:; media-src 'self'; connect-src 'self'; frame-src 'self'; manifest-src 'none'; form-action 'none'; base-uri 'self'; frame-ancestors 'self'; object-src 'none'`. Boot block adds `reader_engine`. |
| `GET`, `HEAD /preview/api/v1/library/{id}/reader` | session, `X-Shelfarr-Account` | `{account, publication:{id, title, author, book_type, content_kind, reading_status, assets:[{id, filename, format, media_type, size_bytes, position, url}], other_formats:[...], progress: null \| progress}}`. Assets are the EPUB and audio files only; PDF and CBZ appear in `other_formats`. `progress` is the full native representation (locator, `position_seconds`, `version`, `observed_at`, `updated_at`, `client_mutation_id`). Writes nothing. |
| `GET`, `HEAD /preview/api/v1/library/{id}/progress` | session, `X-Shelfarr-Account` | `{account, progress: null \| progress}`. |
| `PUT /preview/api/v1/library/{id}/progress` | session, `X-Shelfarr-Account`, exact `Origin`, Go CSRF | The native compare-and-set body and rules, unchanged (same code path as `PUT /api/consumer/v1/library/{id}/progress`). `200 {account, progress}`, `409 {account, error:"progress_conflict", progress}`, `422 invalid_progress`. |
| `GET`, `HEAD /preview/api/v1/accounts/{account}/library/{id}/assets/{asset}` | session; the path account must equal the session's | EPUB or audio bytes of that exact generation through the existing confined, pinned, identity-checked streaming: `Range`, `If-Range`, `If-None-Match`, `HEAD`, strong `ETag`, `Cache-Control: private, no-store`, `Cross-Origin-Resource-Policy: same-origin`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `Content-Disposition: inline` and the document policy `default-src 'none'; sandbox; ...`. |

The three API rows answer `404 not_found` unless the installed asset build has a reader engine (so stopping
`-web-assets-dir` switches the reader off even for a signed-in, allowlisted session); the existing preview JSON does not
depend on it. An audio element cannot send `X-Shelfarr-Account`, so media addresses carry the account id in the path. It is an
identity guard, not a secret: every request (each range included) re-reads the session and is refused
`401 account_changed` when the path account is not the signed-in one, so a tab left open after another tab signed in as
someone else cannot fetch the new account's media, and its own old addresses stop working. Refusals are always JSON with
the same privacy headers and never a redirect. `Sec-Fetch-Site` other than `same-origin` or `none` is
`403 cross_site_refused` before the session is read. The browser routes never read `Authorization`; the native routes
never read cookies. Without the page engine (below), PDF and CBZ asset ids are `410 asset_unavailable` here; their native delivery is unchanged.

### Reader and player behaviour

* The reader is the static TypeScript app. EPUBs are rendered by the same pinned EPUB.js and DOMPurify bundle the Rails
  reader ships (`vendor/javascript/consumer_reader_engine.js`, copied byte for byte into the asset build as
  `reader-engine.<digest>.js` and loaded only by the reader view). The page-naming, picture-page, fraction-restore,
  sanitising and frame-settling logic moved from the Rails controller into `app/javascript/consumer_epub_places.js`,
  which both readers import; the listening rules are the existing `ListeningCheckpoints`.
* Book sections stay sanitised strings rendered by EPUB.js into a sandboxed frame (`allow-same-origin` only) with the
  section policy `script-src 'none'`; scripts, forms, frames, inline handlers and outside addresses are removed or
  blocked, and only the book's own `blob:` pictures are kept. The relaxed style, font and image sources exist only on
  the reader document; the Library policy is unchanged.
* Visible controls on desktop and phone: Back, chapter list, smaller/larger text, previous/next page and the location.
  Arrow and Page keys turn pages from the page or the book, never from inputs, selects, sliders or editable text. The
  player has Play/Pause, back 15 s, forward 30 s, a position slider, track list and previous/next track, and speed;
  Space plays or pauses outside other controls. System media controls are out of scope.
* Opening, restoring, reflowing, resizing, text size and focus never save. A page turn, chapter choice, pause, seek or
  track change saves at the time of that action (`observed_at`), sent a moment later with the version the page knows.
  Play after a pause rewinds five seconds once and does not save or re-date the place until playback passes it again;
  playing on across a track change saves the next track.
* Answers: a success updates the known version; a conflict with a plausibly later place elsewhere is offered ("Go to
  that place") and never overwritten; an earlier one is rebased automatically (at most five times) with the original
  activity time; an undated or unmappable one waits for an explicit choice (keeping this device sends
  `resolve_conflict: true` with the choice time). A network failure or `5xx` keeps the exact request and is resent only
  by Retry, unchanged (same mutation id, activity time and expected version); a refused token is refreshed and also
  waits for Retry. `signed_out`/`account_changed` lock the page, stop the player and nothing more is sent.
* A saved place in another file or an earlier edition opens the EPUB at its beginning, says so, and is kept until a
  turn. Manual reading status is a separate row and is never changed by reading.
* Back returns to where the reader was opened: the Library entry (with its filters and scroll) from "Keep going", the
  details otherwise. Back first waits (up to four seconds) for pending saves to finish in order; closing or reloading
  the tab while a place is unsaved shows the browser's leave warning. No write is ever sent with a guessed version, so a
  place made after the last confirmed save can be lost only if the tab is closed through that warning.
* Deliberate moves (page turns, chapter choices, links inside the book) run one after another; each one records the
  place the book actually shows once it has finished, dated by its own input. A move that changes nothing records
  nothing, and a chapter-list entry inside a chapter is recorded once, at its anchor. Relocation reports from the
  engine only update the location shown.
* "Keep going" links a publication to the reader only when its label says Ebook or Audiobook; a graphic EPUB (labelled
  Comic) opens from its details page, where the real files decide.

### Contract before and after

```
GET /preview/library/77/read                                        before 404 JSON   after 200 reader shell (reader policy)
GET /preview/api/v1/library/77/reader        X-Shelfarr-Account: 5  before 404        after 200 {"account":"5","publication":{...,"assets":[{"id":"<asset>",...,"url":"/preview/api/v1/accounts/5/library/77/assets/<asset>"}],"other_formats":[],"progress":null}}
GET /preview/api/v1/library/77/progress      X-Shelfarr-Account: 5  before 404        after 200 {"account":"5","progress":null}
PUT /preview/api/v1/library/77/progress      + Origin, X-CSRF-Token before 404        after 200 {"account":"5","progress":{...,"version":1}} | 409 {"account":"5","error":"progress_conflict","progress":{...}} | 422
GET /preview/api/v1/accounts/5/library/77/assets/<asset>            before 404        after 200/206/304 bytes | 401 account_changed | 401 signed_out | 403 cross_site_refused | 410 asset_unavailable
manifest.json entry                                                 before {script, style}                   after {script, style, reader_engine}   (optional; a build without it serves no reader)
Go boot block (reader view only)                                    after adds "reader_engine":"/preview/assets/reader-engine.<digest>.js"
```

Unchanged: every native route and answer, the existing preview JSON (`reader_url` keeps its Rails `/read/:id`
meaning; Go reader links are derived in the client as `/preview/library/{id}/read`), cookies, CSRF tokens, schema and
stored formats. Rows written: only `consumer_progresses`, through the native compare-and-set; Rails reads, replays and
continues them (verified with the real application).

### Rollback

Stop passing `-web-assets-dir` (or the allowlist): the reader shell and every route above answer the JSON `404` again.
Roll the binary and the asset build back as a matched pair: a previous binary refuses a manifest that names
`reader_engine` (its manifest reader rejects unknown fields), while this binary still accepts older asset builds and
then serves no reader.
Places saved by the reader are ordinary Rails rows with their activity times and mutation ids; Rails' reader, the
native apps and the previous Go build read and continue them. Reverting the commits removes the reader routes, the
reader view and `consumer_epub_places.js` (the Rails controller would need its previous inline code back, which the
revert restores). No migration either way.

### Verification and limits

`tools/migration/web/verify-web` adds: Go tests for the reader, progress and media routes (account path, signed out,
bearer, cross-site, PDF, other book, ranges, headers, CSRF/origin/account on writes, native routes still refusing
cookies); unit tests and mutants for the save rules, keys, links and player; the asset build check that the shipped
engine equals the vendored one; real headless Chromium (muted, owned null sink) against the production binary with
synthetic EPUB, image-only manga, mixed text/picture and silent multi-track WAV fixtures produced by real Rails: opening
without writing, turns by button, key, frame key and chapter with action times, reload/resize/text size silence,
Back to details and Library with filters and scroll, manga pictures checked by screen pixels with a distinct place per
page and another app's fraction restored, a text place beside a picture, a stale edition, status independence, refused
token, lost answers before and after commit, later/earlier/undated conflicts, another tab switching account, an ended
session, the hostile chapter (no script, no outside fetch), the player's pause, seek, resume rewind, replay, track
change, speed and natural track transition, axe and screenshots on desktop and phone, light and dark, 100% and 200%
text, and keyboard order; then `tools/migration/web/verify_reader_rows.rb` boots the real Rails application on the rows
Go wrote and reads, replays and continues them.

Not proven: Safari, Firefox, real devices, screen readers, audible output (the test audio is silent and the browser
muted), offline use, very large books (the reader refuses EPUBs over 32 MiB like Rails), and Rails and Go writing the
same place at the same moment.

### PDF and comic pages (opt-in)

Status: **experimental, default-off, online only**, behind the same switches as the EPUB reader plus one more: the asset
build must carry the page engine. With it, the reader view opens PDFs and CBZ comics (comic records may hold EPUB, PDF or
CBZ files; the real file types decide) and saves page places through the same compare-and-set.

| Route or file | Change |
| --- | --- |
| `page-engine.json` beside `manifest.json` | New, optional: `{version:1, script, engine, worker, resources:{cMapUrl, standardFontDataUrl, wasmUrl:{name: asset}}, files:{name:{sha256,size}}}`; `script` must name the main manifest's entry script, so a page engine left beside another frontend build is refused. It lists the pinned, vendored PDF.js engine (`vendor/javascript/consumer_pdf_engine.js`), its worker (`vendor/javascript/pdfjs/pdf.worker.js`) and their CMaps, standard fonts and WebAssembly decoders byte for byte, each digest-addressed. At most 256 files and 8 MiB; only `.js`, `.bcmap`, `.pfb`, `.ttf` and `.wasm`, each resource under the kind its extension allows, every listed file referenced exactly once and none shared with the main manifest; a page engine without a reader engine, or any invalid entry, refuses the whole build. Absent: nothing changes. |
| Go boot block | Every view adds `reader_formats` (`["epub"]`, or `["cbz","epub","pdf"]` with the page engine); the reader view adds `page_engine:{engine, worker, files}` (same-origin asset paths). |
| `GET /preview/api/v1/library/{id}/reader` | With the page engine, PDF and CBZ files are listed in `assets`; a CBZ also carries `page_count` and `reading_order_url`. Without it, unchanged. |
| `GET`, `HEAD /preview/api/v1/library/{id}/assets/{asset}/reading_order` | New. `Sec-Fetch-Site` other than `same-origin` or `none` is `403 cross_site_refused` before the session is read; then session and `X-Shelfarr-Account`. `{account, asset_id, format:"cbz", items}` with exactly the native items; `410 asset_unavailable` for anything that is not a listed CBZ of this book, a replaced or malformed archive; `404` without the page engine. Same privacy headers as media. |
| `GET`, `HEAD /preview/api/v1/accounts/{account}/library/{id}/assets/{asset}` | With the page engine also serves PDF and CBZ, as `Content-Disposition: attachment` under the document policy, with the same per-request session and path-account checks, cross-site refusal before the session, ranges, `If-Range` and no redirect. |

The reader uses the Rails page reader itself (`app/javascript/consumer_page_reader.js`), which gained two optional
constructor options, `fetch` and `loadEngine`, defaulting to what Rails always used. PDF pages are canvases with a
selectable text layer, drawn without scripting, forms, XFA or an annotation layer; PDF.js loads its worker and resources
only from the listed same-origin assets. CBZ pages are read one page at a time with byte ranges, following the server's
reading order for that exact generation: each local header is checked against the order, data is inflated within its
announced size, length and CRC-32 are verified, and image type and dimensions (JPEG, PNG or WebP; at most 16 384 px a side
and 40 Mpx) are read from the header before the browser decodes anything. Nothing extracts a whole archive, and the server's
strict archive checks are unchanged. Every page read carries `X-Shelfarr-Account`, stays on this server and locks the page on
`signed_out`/`account_changed`. The reader policy and the Library policy are unchanged.

Controls: Back, a page number box with Go to page, Zoom out, Fit page, Zoom in, previous/next page and the location; arrow
and Page keys turn pages except in editing controls, and a zoomed page becomes a labelled, focusable region whose arrows pan.
Taps on the outer thirds and swipes turn pages at fit. Opening, restoring, resizing, zooming and re-drawing never save; a
turn is recorded once its page shows, dated by its own input, rapid turns record only the page they reach, a page that
cannot be shown (damaged, oversized, changed edition) is never recorded, and the ends do nothing. Places are the native
fixed-layout locators: `{href:"document.pdf", type:"application/pdf", locations:{position, totalProgression, fragments:["page=N"]}}`
and `{href: item N's href, type: its media type, locations:{position, totalProgression}}`. A saved page of another file or
edition opens page 1 and says so; a saved page that is no longer in the file opens the nearest page and keeps the saved
place until a turn. Without a saved place a comic opens CBZ, then PDF, then EPUB, and a book EPUB, then PDF, then CBZ.

```
GET /preview/api/v1/library/77/reader     before {...,"assets":[epub],"other_formats":["cbz","pdf"]}
                                          after  {...,"assets":[epub, {"format":"pdf",...}, {"format":"cbz",...,"page_count":5,"reading_order_url":"/preview/api/v1/library/77/assets/<cbz>/reading_order"}],"other_formats":[]}
GET /preview/api/v1/library/77/assets/<cbz>/reading_order   before 404   after 200 {"account":"5","asset_id":"<cbz>","format":"cbz","items":[{"position":1,"href":"p%C3%A1gina%201.png",...}]}
GET /preview/api/v1/accounts/5/library/77/assets/<pdf>      before 410 asset_unavailable   after 200/206 attachment
Go boot block                                               after adds "reader_formats" (all views) and "page_engine" (reader view)
```

Rollback: remove `page-engine.json` from the asset build (or deploy a build without it) and the browser refuses PDF and CBZ
again exactly as before; stopping `-web-assets-dir` or the allowlist switches the reader off. A previous binary ignores
`page-engine.json` and keeps refusing them, so either half can be rolled back alone. Page places are the ordinary rows the
native apps and Rails already write; Rails reads, replays and continues Go-written PDF and CBZ rows (verified with the real
application). No migration either way.

`tools/migration/web/verify-web` adds the page engine build check (engine and worker equal to the vendored files), Go tests
for the reading order, page media, gating and boot, unit tests and mutants for the page session, guarded page reads and
links, and real headless Chromium tests on a synthetic six-page PDF and compressed CBZ fixtures (natural Unicode order,
a damaged CRC, an oversized image): page pixels, text layer, buttons, keys, the page box, zoom, resizing, reopening,
boundaries, rapid turns, uncertain, later and undated saves, a replaced edition, an earlier edition, Back from Keep going,
another tab switching account, an ended session, axe in both schemes, both viewports and 200% text, and keyboard order;
then the real Rails verifier on the PDF and CBZ rows Go wrote.

Not proven: Safari, Firefox, real devices, screen readers, password-protected or very large PDFs, PDFs that need JPX or
JBIG2 decoders or CMaps (shipped, but no fixture uses them), comic archives larger than the synthetic ones, and offline use.

## Account: display name and password (opt-in)

Status: **experimental, default-off**, behind the same switches as the browser screens. A signed-in account on the
allowlist gets an Account screen in the Go navigation that shows its display name and username and changes the display
name and its local password, with the Rails rules, rows and session effects. Two-step verification, OIDC linking, API
tokens, Kobo, notifications, account creation and administration are later slices and are not shown at all; the Rails
`/profile` screens and the Rails preview's Account handoff are unchanged.

### What is served

| Route | Authentication | Answer |
| --- | --- | --- |
| `GET`, `HEAD /preview/account` | none (shell) | The HTML shell, boot view `account`, title `Account · Shelfarr`, the Library policy. Signed out, it shows sign-in and returns to Account. |
| `GET`, `HEAD /preview/api/v1/account` | session, `X-Shelfarr-Account` | `{account, profile:{id, username, name}}` from the session's own user row; never writes. |
| `PUT /preview/api/v1/account/profile` | session, `X-Shelfarr-Account`, Origin, session CSRF token | `{"name": string}` (other members are ignored, as Rails' `permit(:name)` does). `200 {account, profile}` or `422 {account, error:"invalid_profile", errors:{field:[message]}}`. |
| `POST /preview/api/v1/account/password` | same | `{"current_password", "password", "password_confirmation"}`, all strings. `200 {account, profile}` or `422 {account, error:"invalid_password", errors}`; `409 account_conflict`; `429 rate_limited`. The answer never carries a password or digest. |

Guard order is the one of every browser write: allowlist, session, account header, Origin and `Sec-Fetch-Site`, CSRF token.
The user being changed is always the session's user; no request member names a user, role, username or column. Both
bodies are strict JSON of at most 4 KiB (`400 invalid_json`, `413 request_too_large`, `415`). Other methods are `405`.

### Rules, matched to the Rails model

Messages are the attribute messages of `User#errors` (for example `"name": ["can't be blank"]`,
`"password": ["is too short (minimum is 12 characters)", "must include at least one lowercase letter, one uppercase letter, and one number"]`,
`"password_confirmation": ["doesn't match Password"]`, `"current_password": ["is incorrect"]`).

* Display name: saved exactly as typed (no trimming or normalisation, as Rails); blank means empty or only Unicode
  `White_Space`, which is ActiveSupport's `blank?`. An unchanged name is not written and keeps `updated_at`, as an update
  without changes in Rails.
* Password: the current password is checked first and, when wrong, is the only error, as in `ProfilesController#update_password`.
  Then the Rails validations: at most 72 bytes; unless the account is linked to OIDC, at least 12 characters (code points)
  and at least one ASCII lowercase letter, uppercase letter and digit with no line feed (the Ruby regular expression);
  confirmation equal. The new digest is bcrypt `$2a$`, cost 12 (`BCrypt::Engine::DEFAULT_COST`, what Rails writes in
  production); existing `$2a$` and `$2y$` digests (both tested, including a `$2y$10$` one) of any cost up to 14 are verified.
* The stored record must still pass the Rails record validations Rails runs on every save (username present, lowercase
  ASCII and unique among active users, OIDC provider and uid present together and unique, a password digest present);
  otherwise the change is refused with those messages, as Rails refuses it.
* After a change: the current browser session stays, every other `sessions` row of the same account is deleted, and
  nothing else: API tokens, device grants, other accounts, failed-login counters and reading state are untouched. This is
  exactly what Rails does (captured by running the real Rails controller), except that Go deletes the sessions in the same
  transaction as the digest, where Rails does it afterwards.

### Atomicity and stale state

The current password is checked and the new digest computed from a read snapshot, outside any write lock, in the same
bounded pool as sign-in (`-max-login-workers`, `503 server_busy`) and under the sign-in per-address limit (`-login-attempts`
per `-login-window`, shared with sign-in). Then one `BEGIN IMMEDIATE` re-reads the session row (same id, user and
creation time) and checks it against `session_max_age_days` at the transaction's own clock, the user (present, not
deleted), the stored digest and the OIDC link; a session ended, expired or account deleted meanwhile is `401 signed_out`, a digest or OIDC link changed meanwhile is `409 account_conflict` and nothing is written.
The digest and `updated_at` (microseconds, as Rails) change and the other sessions are deleted in that transaction, so a
failure or crash leaves either both or neither. The name change runs in one such transaction too. The session cookie and
its CSRF token stay valid, because the session row is unchanged.

### Deliberate differences from Rails

* An empty new password is refused (`can't be blank`). Rails' form requires the field, but the controller treats an empty
  password as "no change", still ends the other sessions and reports success.
* A new password made only of whitespace is held to the strength rules (Rails skips them because `"   ".present?` is false)
  and so refused; for OIDC-linked accounts both skip them.
* A new password containing U+0000 is refused (`is invalid`); Rails raises an exception from the bcrypt extension (500).
* A current password over 72 bytes is refused, as Go sign-in already does; Rails' bcrypt compares only its first 72 bytes.
* A display name or request over 4 KiB is `413`; Rails has no limit.
* Password changes are rate limited per address and bounded in concurrency; Rails' profile controller is not.
* Security log lines are `profile.updated`, `password.changed` (with the number of sessions ended), `password.incorrect`
  and `password.rate_limited`, with the user id only. `activity_logs` is not written; Rails writes none for these actions either.

### Browser screen

Account sits beside Library in the Go navigation (`/preview/account`); reloads, Back and Forward keep it. It shows the
display name and `@username`, a display-name form and a password form, each a native labelled form with its own heading.
The password form carries a hidden `autocomplete="username"` field and `current-password`/`new-password` fields, so
password managers can update the saved credential. Errors appear only after a submit, on their fields (`aria-invalid`,
`aria-describedby`), and focus moves to the first refused field; outcomes are announced in a status region. A submit while
one is in flight sends nothing. A saved name updates the header and the identity without touching an unsaved password
form, cancels any older read of the profile and re-reads it; text typed while a save is in flight is kept. A password
answer never changes the shown identity. An answer that arrives after leaving the screen still refreshes the header, an
answer for another account locks the page. Session checks (on focus, visibility and page show) decide in one place and
only the latest one counts: if it answers signed out, another account, or `404` (the cookie now belongs to an account
outside the preview), the page locks and the forms unmount; a superseded check never locks, on Account or any other
preview page. An uncertain answer (network or server error, or a
success whose body cannot be read) says it may have been saved and never resends by itself; a conflict clears and focuses
the current password. Focus moves to the first refused field after its error is attached, and each refusal, repeated ones
included, is also announced in the form's status region; a refusal that names both a field and a stored-record problem
shows both. Password values live only in the form: they are never in React state,
the query or mutation cache, storage, the URL, history or a log, and the fields are cleared after a change.

### Contract before and after

```
GET  /preview/account                          before 404 not_found          after 200 shell, boot {"version":1,"runtime":"go","view":"account","mount":"/preview","api":"/preview/api/v1"}
GET  /preview/api/v1/account                   before 404 not_found          after 200 {"account":"12","profile":{"id":"12","username":"ada","name":"Ada Reader"}}
PUT  /preview/api/v1/account/profile           before 404 not_found          after 200 {"account":"12","profile":{...,"name":"Zoë 📚"}}
                                                                             or 422 {"account":"12","error":"invalid_profile","errors":{"name":["can't be blank"]}}
POST /preview/api/v1/account/password          before 404 not_found          after 200 {"account":"12","profile":{...}}
                                                                             or 422 {"account":"12","error":"invalid_password","errors":{"current_password":["is incorrect"]}}
                                                                             or 409 {"error":"account_conflict"} / 429 {"error":"rate_limited"}
Go boot block "view"                           before library|details|connect|reader     after adds account
```

Unchanged: `/preview/api/v1/session` (still `links.account: "/profile"` for the Rails preview), every other preview and
native route, cookies, CSRF tokens, the Rails preview and its boot block, and the schema. A frontend build from before this
change ignores the new routes; a new frontend served by an older binary shows the Account link, and the screen reports
that account settings are not available (the JSON `404`) and changes nothing. Serve a binary and an asset build from the same
commit.

### Rows written and rollback

`users.name`, `users.password_digest`, `users.updated_at`, and deletions of `sessions` rows of the changing account. Rails
signs in with a Go-set password, refuses the replaced one, keeps the Go session, treats the ended sessions as signed out,
loads the rows as valid and continues editing the profile and password (verified with the real application). Rollback: stop
`-web-assets-dir` or the allowlist (the routes answer `404`), or deploy the previous binary; the rows are ordinary Rails rows
and need no migration.

### Verification

* Go unit tests (`internal/account`, `internal/gohttp`): every rule above, guard and CSRF refusals, body limits, ignored
  members, unchanged names, record validity, session scope, tokens untouched, cost-14 ceiling, OIDC rules, rate limit and
  that no password or digest reaches the answer or the log.
* `tools/migration/browser/verify-browser`: the Rails capture records `User` validation verdicts over a corpus of 16 names
  and 52 password cases (both for a password account and an OIDC account) and the effects of a real Rails password change;
  the real Go executable must give the same verdicts (8 documented differences above) over HTTP, the same session and
  token effects, a `$2y$10$` digest upgrade, recheck and conflict handling (password checked with no write lock held, a
  digest, OIDC link, session or account changed while parked, an injected failure before and inside the transaction, a
  kill before commit, concurrent changes); then the real Rails application verifies the rows Go wrote; 21 mutants of these
  invariants must each fail an assertion.
* `tools/migration/web/verify-web`: unit tests and 15 mutants for the screen (double submit, cleared fields, autocomplete,
  focus and description of refused fields, uncertain answers, header refresh, field rejection parsing, profile/account
  binding, classic preview), and real headless Chromium against the production binary, build and SQLite: direct load after
  sign-in, reload, Back, a Unicode name stored exactly with the header refreshed, refusals, a password change that keeps this
  browser and ends only the account's other browsers, the old password refused and the new one accepted, another tab
  switching account, keyboard order, and axe with no overflow or small targets in light and dark, desktop, phone and 320 px,
  at 100% and 200% text.

Not proven: Safari, Firefox, real password managers and screen readers.

## Discover: Open Library search (opt-in)

Status: **experimental, default-off, read-only.** Behind the same switches as the browser screens, plus one more that
only the server operator can set, an allowlisted account gets a Discover screen in the Go navigation. It searches
[Open Library](https://openlibrary.org) by title or author and, for each work found, links the copies of that work
already acquired in the Shelfarr Library. Nothing can be requested, acquired or saved from it. Hardcover, Google Books,
Comic Vine, aggregation across sources, requests and the native `/api/consumer/v1/discover` (still `501`) are later
slices. The Rails Search and Discover screens, the Rails preview and its Discover handoff are unchanged.

### Switching it on, and off again

Pass `-open-library-search` to `shelfarr-http`. It is the only outbound network use of this runtime: without it the
process opens no outbound connection, the Discover screen says search is switched off, and the JSON answers
`"search": "server_off"` without contacting anyone. With it, what a signed-in, allowlisted person types into Discover
and submits is sent to `https://openlibrary.org` from the server's address. Rollback: restart without the flag (the
screen goes back to "switched off"), or deploy the previous binary. Nothing is stored, so nothing needs migrating.

The request is fixed: `GET https://openlibrary.org/search.json?q=<query>&limit=<n>&fields=key,title,author_name,first_publish_year,cover_i,edition_count`
with `Accept: application/json` and `User-Agent: Shelfarr/<-server-version>`. No cookie, credential, account or session
value is ever sent. The proxy variables `HTTPS_PROXY`/`NO_PROXY` are honoured, as Rails' HTTP client does; the
destination host is not configurable. Every search uses a new connection, so the HTTP client can never resend a search
on a reused connection the server dropped. The answer must arrive within 8 s (5 s to connect, 5 s for TLS), be `200`
with `application/json`, at most 1 MiB and an object with a `docs` list, or the search fails; no redirect is followed and
nothing is retried. The process
sends at most one search a second to Open Library across every account and at most two at once (Open Library's
published limit for clients that do not identify themselves with a contact address); a search above that budget is
refused with `429 search_rate_limited` and `Retry-After`. A `429` from Open Library pauses every search for its
`Retry-After` (60 s when absent or not a number of seconds; a number is held to at least 1 s and at most 15 minutes) in
this process only. A browser that leaves or replaces a search cancels the outbound request. Discover
requests have their own pool of 8 (`503 server_busy` beyond it), so a slow Open Library cannot take the Library's
`-max-metadata-requests` capacity.

### Which Shelfarr settings apply

The same settings Rails' `MetadataService` reads, read-only and on every request:

| Setting or row | Effect |
| --- | --- |
| `open_library_enabled` false | `"search": "provider_disabled"`, nothing sent |
| `metadata_source` set to `hardcover`, `google_books` or `comic_vine` (surrounding whitespace ignored, as Rails strips it) | `"search": "provider_not_selected"`, nothing sent; `auto`, `openlibrary` and any other value keep Open Library |
| `open_library_search_limit` | the `limit` sent, at most 20 (Rails sends any value); 0 or a negative value returns no results without contacting Open Library or reading the Library (Rails sends it). Every form Rails' settings form accepts and `to_i` reads is read: surrounding ASCII white space, a sign, a `0d` prefix, `_` between digits and any number of digits; anything else is `501` |
| `metadata_provider_statuses` row for `openlibrary` with `rate_limited_until` in the future, or `status = auth_failed` | `"search": "provider_paused"` with `retry_after` seconds when known, nothing sent (Rails skips the provider then) |

A setting stored with a type Rails would not write (`open_library_enabled` that is not `boolean`, a limit that is not
an integer, a `metadata_source` that is not a string, an unreadable `rate_limited_until`) answers `501
unsupported_stored_value` instead of guessing. Go never writes `metadata_provider_statuses` or any other row; Rails'
health tracking stays Rails' own. When Rails also has Hardcover, Google Books or Comic Vine enabled, this screen still
searches only Open Library and says so.

### What is served

| Route | Authentication | Answer |
| --- | --- | --- |
| `GET`, `HEAD /preview/discover` | none (shell) | The HTML shell, boot view `discover`, title `Discover · Shelfarr`, the Library policy. `?q=` is read by the page, not the server. |
| `GET /preview/api/v1/discover` | session, `X-Shelfarr-Account` | Without `q`: availability only, never contacts Open Library. With `q`: the search. Other methods `405`, `Allow: GET`. |

```
{"account":"12","provider":{"name":"Open Library","url":"https://openlibrary.org"},
 "search":"available"|"server_off"|"provider_disabled"|"provider_not_selected"|"provider_paused",
 "retry_after":91,                     (only when paused until a known time)
 "query":"dune"|null,
 "items":[{"id":"OL893415W","title":"Dune","author":"Frank Herbert"|null,"first_publish_year":1965|null,
           "edition_count":120|null,"cover_url":"https://covers.openlibrary.org/b/id/12345-M.jpg"|null,
           "source_url":"https://openlibrary.org/works/OL893415W",
           "library":[{"book_type":"ebook"|"audiobook"|"comicbook","publication_id":"5"}]}]}
```

`q` is trimmed of Unicode white space and must be 1–200 characters of valid UTF-8 with no control characters; a blank,
over-long, repeated or malformed `q` is `422 invalid_query` and nothing is sent. Failures: Open Library unreachable or
too slow `503 search_unavailable`; an error status, redirect, non-JSON, oversized or malformed answer `502
search_failed`; rate limits `429 search_rate_limited` with `Retry-After`. The guard order and the
`Cache-Control: private, no-store` of every preview route apply, including the `405` and `503 server_busy` answers of
this route. The route itself writes nothing; like every preview route, and like Rails' `resume_session`, the shared
session guard removes a session row that has outlived `session_max_age_days` or belongs to a deleted account before it
answers `401 signed_out`. The access log keeps the route name only; one extra
line `open_library` records the outcome, the result count and the duration, never the query, a title or Open Library's
answer.

### Projection and library links

Each Open Library document becomes an item only if its `key` is a work key (`/works/OL<digits>W`) and its `title` is a
non-blank string; the first occurrence of a work wins and at most `limit` are kept, in Open Library's order. The first
`author_name` entry, an integer `first_publish_year` in 1–9999, a positive integer `cover_i` and a non-negative integer
`edition_count` are kept; anything else of another type becomes `null`. Text has control characters removed and white
space collapsed, and titles over 500 and names over 300 characters are shortened. The cover address is built from the
number, never taken from the answer, and the browser accepts only `https://covers.openlibrary.org/b/id/<n>-M.jpg`;
without one it draws the generated cover. Covers are loaded lazily by the browser from Open Library with no referrer,
as the Rails screens load them, within the existing `img-src 'self' https:` policy.

`library` lists, in the order ebook, audiobook, comic, one copy per format that the Go details page would open now:
acquired (non-blank `file_path`, a type the Go Library serves), with `open_library_work_id` exactly the work's id, and
projected for this account exactly as `GET /preview/api/v1/library/:id` projects it (the same file listing, stored-value
checks and plain-text description), with at least one file available. The newest such copy wins; a newer copy whose files
are missing, or that the details page would refuse, is skipped for an older one. The newest copy of every work and
format in the answer is always checked (at most 60); older fallbacks are limited to the next 2 copies of each work and
format and to 30 per answer, so one work with many copies cannot hide another's. The library roots are checked before Open
Library is contacted. A row holding the
same work under another source (for example `hardcover_id` as well) still matches through its Open Library column; ids
stored in another form, other case or with a `/works/` prefix do not, exactly as in Rails' `Book.preload_by_work_ids`.
No title or author guess is ever used. These are the same shared Library books every allowlisted account already sees
in the Go Library, so a link reveals nothing new; requests, their owners and pending books are never read or shown.

### Deliberate differences from Rails Search

* Only Open Library; results are not merged with other sources, not clustered by title and author, not classified as
  comics, and keep Open Library's relevance order (Rails sorts merged candidates by source priority, confidence and title).
* `subject` is not requested (it only feeds Rails' comics classification), and edition keys (`/books/...M`), repeated
  works and `cover_i: -1` are dropped (Rails keeps them and builds a broken `-1` cover address). An answer without a
  `docs` list is a failure; Rails reads it as no results.
* A string `first_publish_year` is dropped; Rails keeps it.
* The link per format is the newest copy the Library can open. Rails' result card looks at the newest row of that format with the
  work id, acquired or not, so a newer pending request for the same work and format makes Rails show that format as
  requested while Go links the copy already in the Library (the verifier's fixture holds that case).
* No snapshots, pagination, streaming, request buttons or details handoff; no provider-health writes; a stricter
  limit, deadline, size bound and request budget; the native Discover API stays `501`.

### Browser screen

Discover sits between Library and Account in the Go navigation (`/preview/discover`); a direct load, reload, Back and
Forward keep the query in the address (`?q=`). Opening the screen only asks the server whether search is available. A
labelled search field (with a note that what is typed goes to Open Library when Search is pressed) sends one search per
submit, never per keystroke; a blank submit explains itself and sends nothing, and an over-long query in the address is
explained and never sent. A status region announces "Searching…", the result count, no results, or that the search did
not finish. Each result shows its cover, title, author, first publication year, number of editions,
"No copy to open in your library" or one "Open the ebook/audiobook/comic" link per copy, and a "View on Open Library" link that opens a new tab with no
opener or referrer. The screen states that only Open Library is searched and that requesting is not part of the
preview. Each unavailable state has its own explanation and no form; all but "switched off" (which only a restart
changes) offer Check again, and such answers are not cached, so a later visit asks again. The field keeps focus
through a search. A query repeated in the address is rewritten to the last one, which is the one searched, as the
Library's address is. Rate limits, an unreachable or unusable Open
Library, a refused query and an older server (`404`) each have a message and a Try again button where it can help;
nothing is retried by itself. Each query has its own cache entry for the account (five minutes, no refetch on focus),
so Back reuses the answer; a failed search or check is sent again only by Try again, never by coming back to it or
by Back from another search; a newer search
or leaving the page cancels the older request and a late answer cannot appear. The account guard, session checks and locking work as on every other page.

### Contract before and after

```
GET /preview/discover                 before 404 not_found   after 200 shell, boot {"version":1,"runtime":"go","view":"discover","mount":"/preview","api":"/preview/api/v1"}
GET /preview/api/v1/discover          before 404 not_found   after 200 {"account","provider","search","query":null,"items":[]}
GET /preview/api/v1/discover?q=dune   before 404 not_found   after 200 {..., "query":"dune","items":[...]}
                                                             or 422 invalid_query / 429 search_rate_limited / 502 search_failed / 503 search_unavailable
shelfarr-http -open-library-search    before unknown flag    after opt-in outbound search (default off)
Go boot block "view"                  before library|details|connect|reader|account   after adds discover
```

Unchanged: `/api/consumer/v1/discover` (`501`), `server.json` (no capability is advertised), `/preview/api/v1/session`
(`links.discover` keeps the Rails rule for the Rails preview), cookies, CSRF tokens, the Rails preview, the schema and
every setting's meaning. The runtime now also requires `books.open_library_work_id` and
`metadata_provider_statuses(provider, status, rate_limited_until)`, both present in the supported revision. A new
frontend served by an older binary shows Discover and reports that it is not available (the JSON `404`); serve a binary
and an asset build from the same commit.

### Verification

* Go unit tests (`internal/openlibrary`, `internal/gohttp`): the exact request URL and headers, the projection of a
  recorded answer with every odd type, size, status, content type, redirect, stalled body, deadline, cancellation,
  `429` pause and the per-second and concurrency budget; the route's guards, every settings case with provider health
  unchanged, refused stored values and limits, refused queries, exact library links (newest openable, a newer
  copy with a missing file skipped, pending, blank, case, prefix, odd type), named failures without leaks in answers or
  logs, a disconnect cancelling the upstream request, a stalled search leaving the Library's capacity free, a search
  the server dropped on a connection never being sent twice, a newest copy the details page refuses skipped for an older
  one while forty copies of one work leave another work's link intact, twenty works with three formats each all
  linked, Rails' integer forms of the limit, and uncached
  refusals.
* `tools/migration/web/verify-web`: the Rails fixture gives reader books Open Library work ids (one also with a
  Hardcover id), adds a newer pending request for one and a pending-only book requested by another account, and records
  what the real Rails `OpenLibraryClient.search` and `Book.preload_by_work_ids`/`find_in_lookup` make of a recorded
  answer. A loopback fake Open Library (an HTTPS `CONNECT` proxy with its own test certificate authority, reached by
  the unmodified production binary through `HTTPS_PROXY` and `SSL_CERT_FILE`) serves that answer and the failure
  cases; no real Open Library request is made. Real headless Chromium checks off-by-default with no connection, search
  on submit only, the exact JSON against the Rails capture and the differences above, the exact outbound request,
  the library links and details, Back without a new request, reload, no rows changed, no query in the logs, every
  failure state without retry or redirect, the per-second limit and Open Library's pause, cancellation on leaving and
  on a newer search, the settings and Rails backoff, an over-long query, another tab switching account, keyboard order,
  and axe with no overflow or small targets in light and dark, desktop, phone and 320 px, at 100% and 200% text. Unit
  tests and eleven mutants cover the screen.

Not proven: real Open Library traffic, Safari, Firefox and screen readers.

## Requests: read-only list and detail (opt-in)

Status: **experimental, default-off, read-only.** Behind the same switches as the browser screens, an allowlisted
account gets a Requests screen between Discover and Account in the Go navigation. It lists the requests Rails created,
with Rails' tabs, title and author search and pages of 25, and opens one request to show where it has got to. Nothing
can be requested, queued, cancelled, retried, selected or downloaded from it: there are no such buttons. The native
`/api/consumer/v1/requests` routes stay `501`, `server.json` advertises nothing new, and the Rails `/requests` screens,
the Rails preview and its Requests handoff (`links.requests`) are unchanged.

### Who sees what

The same rule as Rails' `RequestsController`: an admin (`users.role = 1`, read on every request through the session
guard) sees every request; anyone else sees only rows with `requests.user_id` equal to the session's user. A request of
another account is `404 {"error":"not_found"}`, byte for byte the answer for an id that does not exist or is malformed,
so an id reveals nothing. Admin answers carry `requested_by: {name, self}` (only `users.name`, the public display name,
as the Rails pages show it, and whether it is the admin's own request); member answers never carry the field and the
browser refuses a member answer that does. No username, user id, email, session or other profile value is returned.
There is no household or sharing rule beyond this.

### What is served

| Route | Authentication | Answer |
| --- | --- | --- |
| `GET`, `HEAD /preview/requests`, `/preview/requests/:id` | none (shells) | The HTML shell, boot view `requests` or `request`, titles `Requests · Shelfarr` and `Request · Shelfarr`, the Library policy. Signed out, sign-in returns to the same address. |
| `GET /preview/api/v1/requests?status=&attention=&q=&page=` | session, `X-Shelfarr-Account` | The list. Other methods `405`, `Allow: GET`. |
| `GET /preview/api/v1/requests/:id` | session, `X-Shelfarr-Account` | One request. `:id` must be `[1-9][0-9]{0,18}`, else `404`. Other methods `405`, `Allow: GET`. |

```
{"account":"12","scope":"own"|"all",
 "filter":{"status":null|"active"|"<rails status>","attention":false,"q":null|"harbor"},
 "counts":{"attention":2,"active":4},
 "page":1,"per_page":25,"total":35,"total_pages":2,
 "items":[{"id":"3","status":"pending"|"searching"|"not_found"|"downloading"|"processing"|"completed"|"failed"|"awaiting_purchase"|"unknown",
           "attention_needed":false,"title":"…","author":"…"|null,"book_type":"ebook"|"audiobook"|"comicbook"|"unknown",
           "cover":{"url":"https://…"|null,"style":"moss"},"download_percent":37|null,
           "created_at":"2026-11-15T11:00:00.000Z","updated_at":"…","completed_at":"…"|null,"next_retry_at":"…"|null,
           "library":{"state":"available","publication_id":"7"}|{"state":"unavailable"}|null,
           "requested_by":{"name":"Alice Reader","self":false}}]}        (requested_by: admin answers only)

{"account":"12","request":{…the same fields…,
  "attention_reason":"Search results found. Please review and select a result to download."|null,
  "downloads":[{"status":"queued"|"downloading"|"paused"|"completed"|"failed"|"unknown","progress":42|null}]}}
```

Like every preview route: `Cache-Control: private, no-store` (also on `405` and `503 server_busy`), the shared metadata
pool, the request deadline, `503 database_busy`/`database_unavailable` instead of an empty list. The route writes
nothing; like every preview route, the shared session guard removes a session row that has outlived
`session_max_age_days` or belongs to a deleted account before it answers `401 signed_out`.

### Filters, search and pages, matched to Rails

* `status=active` is Rails' Active tab: `pending`, `searching`, `downloading` or `processing` with `attention_needed = 0`
  (a `NULL` flag is in neither Active nor Need Attention, as in Rails). Any Rails status name filters on that status.
  `attention=true` adds `attention_needed = 1`; any other `attention` value is ignored, as Rails ignores it. A blank
  `status` is no filter. An unknown status, a repeated `status`, `attention`, `q` or `page`, or a malformed query is
  `422 invalid_query` (Rails filters an unknown status to an empty list).
* `q` is stripped of Ruby's `strip` characters, cut to 200 characters and matched, case-insensitively after Unicode NFC
  and Ruby's full lower-casing (without Greek final-sigma context, as Ruby's `downcase`; letters added to Unicode after
  the version of the Ruby that runs Rails, such as U+1C89, may fold in Go and not in Rails), as a substring of the book's title or author with `%`, `_` and `\` taken literally: Rails'
  `shelfarr_request_search_lower` function, registered under another name in Go. Invalid UTF-8 is `422`.
* `page` is read as Ruby's `to_i` (`"abc"` is 1, `"+0_0_7x"` is 7, a negative is 1), clamped to 1–1,000,000 and then to
  the last page; an empty result is page 1 of 1.
* Counts are Rails' tab badges: Need Attention and Active over the account's (or, for an admin, every) request, ignoring
  the search and the current tab.
* Order is `created_at` newest first, then `id` newest first, so equal times keep one stable order across pages (Rails
  orders by `created_at` only).
* Reads are bounded: one read-only transaction per answer with two counts, one `LIMIT 25 OFFSET` page joined to its
  book and requester, one grouped download query for the page's downloading requests, and, for a detail, at most the 10
  newest downloads. Library checks run only for acquired books on the page, at most 25: the library roots are resolved
  once, reading places and statuses are read in one batch for the page, and each book gets the Go details projection.
  A library root setting the runtime refuses (outside every `-library-root`, relative or otherwise unsupported) makes
  every acquired copy on the page `unavailable` instead of failing the list; a configured root directory that merely
  cannot be entered is skipped, as the Library skips it, and copies under the other roots keep their state.

### Projection

* `status` is the Rails enum name; an integer Rails does not define becomes `"unknown"` instead of a failure. A book
  type outside ebook, audiobook and comic becomes `"unknown"`.
* `download_percent` is `Consumer::RequestView`'s: only for a `downloading` request, the highest `progress` of its
  queued, downloading or paused downloads, held to 0–100, else `null`.
* `downloads` (detail only, newest first, at most 10) carry the download status and, for queued or downloading ones (the
  Rails show page's `active?`), the progress. Release names, sizes, clients, external ids and paths are never read.
* `library` is `null` for a book without a stored file, `available` with the publication id when the Go details page
  would open the book for this account now (the same check Discover uses, with at least one file present), and
  `unavailable` when a copy is recorded (`file_path` is set) that the Library here cannot open (missing, unsupported or
  refused); the screens say exactly that and never claim the files are present. Only
  `available` is linked ("Open in Library", `/preview/library/:id`).
* `attention_reason` is shown only when `attention_needed` is set and the stored `issue_description` is one of the fixed
  Rails sentences that name no provider, address or error text (no search source returned results; results to review;
  none matched auto-select; no result selected; client authentication failed; maximum retries exceeded). Anything else,
  which may hold a client error, address or credential, is never returned; the screen then says Rails' own fallback,
  "This request needs your attention."
* The cover is the book's `cover_url` only when it is a plain `https` address with a host and no user information (Rails'
  `Consumer::SafeLink`) and none of its query parameter names, split on `&` and `;` and percent-decoded, looks like a
  credential (token, key, secret, signature, auth, pass, credential, session, jwt, bearer, policy, `X-Amz-*`,
  `X-Goog-*`); a name that cannot be decoded also drops it. Otherwise the generated cover. Times are UTC ISO 8601 with milliseconds.
* A stored timestamp the runtime cannot read is `501 unsupported_stored_value`, as elsewhere.

### Deliberate differences from Rails

* No actions: no Cancel, Delete, Retry, View Results, manual magnet or NZB, upload, store offers, search results,
  diagnostics (`request_events`), notes, retry count, file location or download button. Requesting stays in Rails.
* The issue description is shown only when it is one of the fixed sentences above; Rails shows any stored text, to
  members too (and to admins in the list). The list never shows it.
* Download attempts show their status and progress only, newest first and at most 10; Rails lists every attempt with its
  release name and size.
* "Open in Library" appears only when the Go details page opens the copy. Rails shows a file location and download link
  whenever `file_path` is present, and the native `Consumer::RequestView` reports a completed request with a missing file
  as `available` with a publication id; Go says the copy cannot be opened here and does not link it.
* Rails' "In Library" and "Possibly in Library" badges from Audiobookshelf matching are not shown.
* Relative and absolute times are rendered in the browser's time zone and English formats ("3 days ago", "November 15,
  2026 at 11:00 AM"); Rails uses the server's time zone and `time_ago_in_words`.
* Ties on `created_at` are ordered by id; an unknown status name is `422`; an unknown stored status or type is shown as
  unknown where Rails' page fails.
* Pages refresh by themselves every 15 seconds while a shown request is pending, searching, downloading or processing,
  or not found with a next search scheduled (only while the tab is visible); Rails pushes changes over Turbo Streams.
* A cover whose address carries a credential-like query parameter is replaced by the generated cover; Rails shows it.

### Browser screen

Requests (`/preview/requests`) shows "My Requests" or, for an admin, "All Requests", a sentence that making, cancelling
or retrying requests is not part of the preview, Rails' tabs as links (All, Need Attention and Active with their counts,
Store Offers, Completed, Not Found, Cancelled; the current one marked `aria-current="page"`, not by colour alone), a
labelled search that keeps the current tab, a status line ("35 requests · Page 1 of 2"), and a card per request: cover,
title linking to the request, author, format, status and attention badges, a labelled progress bar with its percentage
while downloading, who asked (admins, other people's requests), when it was requested and completed, and "Open in
Library" for an openable copy. Previous and Next keep the tab and search. Rails' empty states are kept ("No requests yet",
"No requests need attention", "No matching requests"), with Discover offered for an empty list. The address holds
`status`, `attention`, `q` and `page`, so a direct load, reload, Back and Forward return to the same list; an unknown
tab value in the address is ignored and `page` (up to 64 characters; a longer value is dropped and page 1 is shown) is
passed to the server as written, which reads it as Rails does. Each filter has its own cache entry, so a late answer for an earlier filter never
replaces the current one.

A request (`/preview/requests/:id`) shows the format, title, author, badges, Rails' "Attention Required" box, a
sentence for its stage (announced politely when it changes) with a progress bar while downloading, who asked (admins),
when it was requested and completed, the next search time for a not-found request, "Open in Library" or the honest
"cannot open" sentence, and its download attempts. In the same tab "Back to Requests" returns to the list it came from,
filters included; opened in a new tab it goes to the unfiltered list. A missing or foreign request says "This request
is not available". The account guard, session checks and
locking work as on every other page. Both screens wait for the session before asking for requests. A role change
locks the page, as an account change does: once a Go page has a session answer, any later one (a refresh, or a check on
focus, visibility or after an uncertain answer) that finds the account became or stopped being an admin locks it (the
reader and connect pages have no session answer until their first check, so that check sets their starting role; the
classic Rails preview keeps its page as before), or when a request answer's reach differs from
the verified role (an admin's list or a detail naming its requester for a member, or the reverse), the guard clears every
cached answer and the page shows "This account's access changed" with "Continue as the current account", which loads the screens again for the
role the account has now. Nothing from the earlier role is shown or kept. A request that answers `404` has the session
checked again, so a lost admin role is noticed there too. A session check that ends the session (`401`) or finds another
account locks the page as before. A check that is inconclusive (for example `503`) does not prove a role change, so it
does not lock; it drops every cached Requests list and request once, so no earlier view returns from another tab,
filter or Back, and the page settles on its retryable error or "not available" without asking again by itself. The next
successful check asks again for a shown list or request that failed meanwhile (a retry still in flight at that moment
can leave Try again showing); other filters and requests fetch when they are opened again.

### Contract before and after

```
GET /preview/requests, /preview/requests/:id    before 404 not_found   after 200 shell, boot {"version":1,"runtime":"go","view":"requests"|"request","mount":"/preview","api":"/preview/api/v1"}
GET /preview/api/v1/requests                    before 404 not_found   after 200 {"account","scope","filter","counts","page","per_page","total","total_pages","items"}
                                                                       or 422 invalid_query
GET /preview/api/v1/requests/:id                before 404 not_found   after 200 {"account","request"} or 404 not_found
other methods on both                           before 404 not_found   after 405, Allow: GET
Go boot block "view"                            before …|account|discover   after adds requests, request
```

Unchanged: `/api/consumer/v1/requests` and `/api/consumer/v1/requests/:id` (`501`), `server.json`,
`/preview/api/v1/session` (`links.requests` keeps the Rails path for the Rails preview), cookies, CSRF tokens, the Rails
preview and every Rails screen, the schema and every setting. The runtime now also requires
`requests(id, book_id, user_id, status, attention_needed, issue_description, created_at, updated_at, completed_at,
next_retry_at)` and `downloads(id, request_id, status, progress)`, present in the supported revision. A new frontend
served by an older binary shows Requests and reports that it is not available (the JSON `404`); serve a binary and an
asset build from the same commit. Rollback: deploy the previous binary and asset build; nothing is stored.

### Verification

* Go unit tests (`internal/gohttp`, `internal/live`): a member's exact list and detail with nobody else's data, an
  admin's list with only display names, a foreign, missing and malformed id with one identical `404`, every tab, the
  Unicode search with `%` and `_`, the counts, Rails' `to_i` pages and clamping, 60 requests over three pages in a stable
  order, progress from active downloads only, unknown statuses, types and download statuses, unsafe covers, the
  allowlisted and free-text attention texts with no address, credential, release name or path in any answer, the guards,
  `405` with `no-store`, the native routes still `501`, no request or download row changed, and the schema check.
* `tools/migration/web/verify-web`: the Rails fixture creates requests with the real models for a member (every status,
  attention with a listed and a free-text description, a future retry, two downloads, a completed audiobook the Library
  opens and a completed book whose file is gone), an admin, another allowlisted account, an account outside the
  allowlist and 22 queued ones, and records what the real Rails `/requests` page shows a member and an admin for twelve
  tab, search and page combinations (titles, ids, labels, "Requested by", tab counts, current tab, pagination), what
  `/requests/:id` answers each of them for every request, and `Consumer::RequestView` for the member. Real headless
  Chromium against the production binary and asset build checks the same lists, tabs, counts and pages against those
  Rails captures, the same `404`s, no secret in any answer, no row written, stages, progress, the attention texts, the
  honest unavailable copy, "Open in Library" opening the real details page, the address through direct loads, reload,
  Back and Forward, another tab switching account, keyboard order, and axe with no overflow or small targets in light
  and dark, desktop, phone and 320 px, at 100% and 200% text. Unit tests and eleven mutants cover the screens.

Not proven: Safari, Firefox and screen readers; a library with thousands of requests (the reads are the bounded
queries above, and Rails' own page runs the same `COUNT` and `OFFSET`).

## Requesting one ebook on a prepared disposable volume (opt-in)

Status: **experimental, default-off, test volumes only.** With `-acquisition-workdir DIR`, an allowlisted account can
request an Open Library ebook from Discover, follow it on Requests, and read the EPUB in the Go Library once an admin has
chosen a Project Gutenberg copy. Everything runs on a directory made by `shelfarr-workflows prepare` (see
[backend-migration.md](backend-migration.md)), against the loopback catalogue its own settings name. It is not a
production mode: no other provider, format, scheduler or Rails job is involved, and Rails never runs on such a volume.

### Switching it on, and the startup check

`shelfarr-http -acquisition-workdir DIR` refuses to start (exit 2) unless all of these hold:

| Refusal | Condition |
| --- | --- |
| `acquisition-volume` | `DIR` is absolute and clean; `-database` is exactly `DIR/workflows.sqlite3` and `-lock-file` exactly `DIR/locks/http.lock`; `-allow-non-loopback` is off and `-browser-origin` is a loopback IP literal; `DIR` passes the disposable-copy check (private mode, `WORKDIR.json` token equal to the database's `wf_meta` token) |
| `acquisition-network` | with `-open-library-search`, the proxy the Open Library client would use is an `http://` loopback IP literal (so Discover reaches only a local fixture) |
| `acquisition-settings` | the copy's settings pass the Gutenberg search and download checks before any request exists: schema revision and columns, Gutenberg on with a loopback IP origin, no other ebook source, no auto-selection or outbound notification channel, no library scan or import permissions, and `ebook_output_path` a canonical private directory strictly inside `DIR` that is also under a `-library-root` |

Without the flag nothing changes: `POST /preview/api/v1/requests` is `405 Allow: GET`, the two new routes are `404`, the
Discover answer has no `requesting` member and no worker runs. Rollback is a restart without the flag or the previous
binary; every row written is an ordinary Rails row (below), so nothing needs undoing.

### What is served (only with the flag)

| Route | Who | Answer |
| --- | --- | --- |
| `GET /preview/api/v1/discover?q=` | session | adds `"requesting": true`; the works it returns are remembered for that account for 30 minutes (at most 200 per account, 128 accounts, in memory) |
| `POST /preview/api/v1/requests` `{"work_id":"OL…W","book_type":"ebook"}` | session, Origin, CSRF, `X-Shelfarr-Account` | admits the work through the existing admission code (below) |
| `GET /preview/api/v1/requests/:id/acquisition` | admin | the copies an admin can choose and the worker's state for that request |
| `POST /preview/api/v1/requests/:id/selection` `{"result_id":"…"}` | admin, Origin, CSRF, `X-Shelfarr-Account` | starts the download of one chosen copy |

All four are `Cache-Control: private, no-store`, use the metadata pool and go through the shared session guard. A member
asking for either admin route gets the same `404 not_found` as a missing request.

```
POST /preview/api/v1/requests
  201 {"account":"2","outcome":"created","request":{"id":"41"},"warnings":[]}
  200 {"account":"2","outcome":"existing","request":{"id":"41"}}           (the caller's own open request)
  200 {"account":"2","outcome":"already_requested"}                         (another account's; no id, no name)
  200 {"account":"2","outcome":"already_in_library","library":{"publication_id":"13"}|null}   (null: a copy is recorded the Library cannot open)
  422 invalid_request | work_not_offered     401 signed_out     422 invalid_csrf     503 database_busy|database_unavailable

GET /preview/api/v1/requests/:id/acquisition
  200 {"account":"1","request":{"id":"41","status":"searching"},
       "candidates":[{"id":"9","title":"Pride and Prejudice - Austen, Jane [EPUB] [English]"}],
       "selection":null|{"state":"queued"|"downloading"|"failed"|"completed","result_id":"9","code":null|"provider-busy"},
       "search":null|{"state":"retry_scheduled"|"waiting"|"refused","code":"provider-busy","retry_at":"2026-11-19T10:01:00.000Z"}}

POST /preview/api/v1/requests/:id/selection
  202 {"account":"1","selection":{"state":"queued","result_id":"9","code":null}}
  200 {"account":"1","selection":{"state":"completed","result_id":"9","code":null}}   (the copy that completed it)
  409 {"error":"acquisition_busy"}   409 {"error":"not_selectable","reason":"result_not_selectable"|…}   422 invalid_request
```

The body names only the work; title, author, year and cover come from the Discover answer this server gave the same
account, and the native consumer body is then built and checked by `admission.ParseSubmission`, so a client cannot choose
the metadata, the account or the format. Candidates are listed only when `PlanSelection` would accept them now
(pending, not blocklisted, an EPUB on the configured origin); download, info and GUID links, provider details and paths
are never returned. Codes are fixed strings.

### Admission, worker and download

* **Admission** is `admission.Submit` in one `BEGIN IMMEDIATE` transaction on the volume, which first requires the
  session row to still exist for that account (`401 signed_out` otherwise) and then makes the same decision and writes the
  same `books`, `requests` and `activity_logs` rows as `shelfarr-workflows request`. It runs to completion even if the
  browser disconnects (bounded by `-request-timeout`); a retry, a double press, a reload or a second account then gets
  `existing`, `already_requested` or `already_in_library`, never a second request. The pending row is the queue entry.
* **One serial worker** per process takes the oldest pending ebook request (or a searching one whose claim is older than the
  30-minute lease) with Rails' claim and runs the extracted `acquire.Search`, the same code as `shelfarr-workflows search`.
  It wakes on an admission or every 2 seconds. A released search (unreachable, busy, timeout, withheld candidates) waits 1,
  2, 4, 8 then 15 minutes before the next attempt; a refusal (settings changed) waits 15 minutes; a live claim of another
  worker 1 minute. These waits are in memory only and are shown to admins; a failed or provider-disabled request is never
  marked as searched.
* **The admin's choice** is checked with `PlanSelection`, queued in memory (one at a time across the process; the same
  choice again is the same job, any other is `acquisition_busy`), and run by the same worker with `acquire.Download`, the
  same code as `shelfarr-workflows download`, under the same `locks/acquisition.lock`. Before it starts, the worker checks
  again that the admin's session exists and the account is still an allowlisted, undeleted admin
  (`failed`, `authority_changed` otherwise). The result is `completed` or `failed` with the download's code; nothing is
  retried by itself.

### What is durable, and interrupted states

| Interrupted | Durable state | After a restart |
| --- | --- | --- |
| Browser disconnects during admission | the admission either committed or did not | pressing again answers `existing` or creates it once |
| Process stops during a search | SIGTERM: the claim is released (pending again); SIGKILL: the claim stays | the next worker reclaims it after the 30-minute lease, as Rails' `RequestQueueJob` would |
| Process stops while a choice is queued or downloading | nothing (the download writes only in its completion transaction; an unlinked file is anonymous) | the request still awaits a choice; the admin sees no selection and chooses again |
| Process stops after the download linked its file, before commit | an unreferenced, validated EPUB at its final name | the next download of that copy adopts it |
| After the completion commit | the completed Rails rows and the library file | `already_completed`; the request reads as completed and the book opens in the Library and reader |

The in-memory state (offers, waits, the queued choice) is lost on restart by design; the browser shows only what the server
reports and never claims success it has not seen.

### Browser screens

Discover shows "Request ebook" on a result without an ebook in the Library, and only when the server answers
`requesting: true`; the note under the results says the server is a test setup that looks only in its own copy of the
Project Gutenberg catalogue. One press sends one request: the button is marked busy while it waits, the result is
announced in the card's status region and receives focus, with "Track it in Requests" for the caller's own request, an
"Open the ebook" link for a copy already in the Library, and no link for another account's request. An unconfirmed answer
says it may or may not have been received and asks to check Requests before trying again; nothing is resent by itself.
On a request awaiting a choice, members read "An administrator chooses which copy to download."; an admin gets a
"Choose a copy" fieldset of radio buttons and "Download this copy", then the queued, downloading (with an indeterminate
progress bar), failed (with a plain reason and the choice offered again) or downloaded state, refreshed every 2 seconds
while it runs. When the request completes the usual "Open in Library" link appears.

### Contract before and after

```
POST /preview/api/v1/requests                    before 405 Allow: GET     after (flag) 201/200 admission answers above; (no flag) unchanged
GET  /preview/api/v1/requests/:id/acquisition    before 404                after (flag) 200 admin / 404 member; (no flag) unchanged
POST /preview/api/v1/requests/:id/selection      before 404                after (flag) 202/200/409/422 admin / 404 member; (no flag) unchanged
GET  /preview/api/v1/discover                    before {…}                after (flag) adds "requesting": true; (no flag) unchanged
shelfarr-http -acquisition-workdir DIR           before unknown flag       after opt-in, refused unless the startup check passes
```

Unchanged: the native `/api/consumer/v1/requests` and `discover` routes (`501`), `server.json`, the Rails screens and jobs,
the schema, every setting, and `shelfarr-workflows` (its `search` and `download` now call the extracted
`internal/acquire` entry points; their output is unchanged and pinned by the existing workflow suite).

### Verification

* `go test ./internal/gohttp/` checks the route gating with and without the volume, the request and choice bodies, the
  offer memory (per account, expiry, bounds), the search back-off and the one-choice-at-a-time queue.
* `e2e/workflows/web_test.go` runs the built `shelfarr-http` (with the test clock) and the built web assets on prepared
  copies of both bundles, with two synthetic accounts, the fake Open Library behind a loopback proxy and the captured
  Gutenberg OPDS replies: nine startup refusals with no row, catalogue or Open Library contact; the flag off; the whole
  journey (CSRF, Origin, cross-site, other account's token and header, malformed and unoffered bodies with no row written;
  five disconnected and eight concurrent presses giving one request; another account told only `already_requested`; the
  worker's candidates; members refused the admin routes; no link, GUID or provider detail in the admin answer; refused
  choices; a double choice giving one download; the exact library bytes; the request, Library, reader and media bytes for
  the member; `already_in_library` afterwards; no title, path or catalogue address in the log); and a restart suite (a
  SIGKILL during a stalled search reclaimed only after the lease, a busy catalogue backed off and never read as no results,
  `acquisition_busy` during a download, a SIGKILL during the download leaving no row and a later choice completing).
* Web unit tests (`test/go-acquisition.test.tsx`) and a run in Chrome against the built binary and assets.

Not proven: real Open Library or Gutenberg traffic, more than one worker process, and Safari, Firefox or screen readers.

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

Nothing is discovered. There is no default database path, no `.env` loading and no network access, except the opt-in
Open Library search of [Discover](#discover-open-library-search-opt-in) (`-open-library-search`).

```
shelfarr-http -experimental \
  -database /abs/primary.sqlite3 -lock-file /abs/auth-domain.lock \
  -library-root /abs/library [-library-root ...] \
  [-listen 127.0.0.1:3100] [-allow-non-loopback] [-server-version V] [-android-channels release] \
  [-body-timeout 5s] [-open-library-search]
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
   `reader_formats` is `["cbz","epub","pdf"]` (the Rails list: this runtime now serves all three),
   `reader_features` and `read_along_manifest_versions` are `[]`.
   Rails advertises `requests` and `read-along` too; copying that would invite clients to
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
    Rails words some of these differently. The messages of a comic archive that fails its check between
    the listing and the page comparison are Rails' own.
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

* a differential replay of ~1 940 requests per fixture in recorded order (status, headers, JSON, asset
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
* transfer grants (`TransferCases`, ~530 recorded requests per fixture on top of the above): a real Rails mints a grant for every listed
  asset of every acquired book (EPUB, audio, PDF, CBZ, comic records) at a frozen instant; Go replays the mint and must return the same
  status, headers, `expires_at` and a grant of the same length whose decrypted plaintext is byte for byte the one Rails minted, then
  consumes every Rails-minted URL (GET, HEAD, ranges, `If-Range`, `If-None-Match`, empty files) with the same status, headers and bytes.
  The same replay covers the expiry boundary to the microsecond, tokens expiring sooner than a day, revocation through the API and
  through direct row changes (scope, expiry, owner, deleted owner, deleted token, a removed book), adoption lineage, binding to the
  wrong book or asset, about 50 query spellings and malformed queries, credential and cookie precedence, the other endpoints that must
  ignore a grant, and every mint refusal; token rows and reading state must equal Rails' after every request. The
  Rails models then read what Go minted (`verify_go_rows.rb`): each Go grant is opened by Rails with the same secret, serves the same
  bytes, carries the same claims and dies at the same moment, and a private library whose file Go saw replaced and whose book Go saw
  removed gives Rails the same `410` and `404`;
* transfer grants against the untagged shipped executable at real time: a Rails-minted grant served and served again after a restart,
  Go grants surviving a restart and refused under another secret, live revocation and restoration, stalled clients bounded and
  concurrent transfers during a revocation; and against the build with the clock and fault seams: the expiry boundary to the
  microsecond, an in-flight transfer finishing after a revocation while the next one is refused, an aborted client returning its slot,
  an injected panic and hostile queries leaving no grant in the log, and a mint whose file is replaced between listing and opening;
* faults: generated EPUB fetched intact and generated audio seeked, replaced, rewritten, deleted and
  symbolic-link-swapped assets, traversal attempts, client disconnect, stalled clients with a live
  catalogue, busy SQLite, live WAL commits and external revocation, shutdown during a transfer,
  startup refusals, single ownership, cursor and secret mismatch, 24 concurrent adoptions, request
  limits, absence of sensitive values from every output;
* the real Rails models and controllers reading, projecting, isolating per account and continuing every
  row Go wrote (`verify_go_rows.rb`, 454 checks per fixture, including Rails writing a PDF and a CBZ page on top of Go-written fixed-layout places, which fails when either is never exercised);
* progress faults over real sockets and processes: generated EPUB and synthetic audio round trips and
  a restart, 24 concurrent first writes (one wins) and 12 concurrent updaters (none lost), a SIGKILL
  before and after the commit followed by a retry, a client that leaves while holding the write
  lock, an externally held write lock, declared, chunked, stalled and abandoned bodies;
* fixed-layout: the library, continue, publication, asset and `reading_order` routes under every capability subset
  (about 1 000 of those requests), the CBZ metadata of synthetic archives built with a raw ZIP writer (natural
  order and Unicode names, hidden entries, a 10 000 page archive and about 90 malformed archives, each refused for the same
  reason by Rails and Go), ranges and conditional requests on a PDF and a CBZ, page writes for PDF and CBZ with their
  rejected variants, status on comic records, and the Go preview JSON for the same books; `go test -fuzz` targets
  `zipdirectory.Entries`;
* 147 mutants of the critical invariants (revoked, expired, deleted-owner credentials, adoption, scope
  check, cursor binding and signature, symbolic links, identity re-check, root allow-list, ranges,
  `HEAD`, conditional requests, stream capacity, unknown schema, missing key, WAL, logging, and for
  progress: scope, version, mutation id, retry data, chronological and resolution rules, unknown
  times, isolation, locator comparison, status independence, future tolerance, traversal, version
  range, asset identity, body size, body deadline, content type, conflict and malformed-body answers, and for fixed-layout
  files: format negotiation and cursor identity, attachment and document policy, PDF header and size boundaries, identity
  re-checks, every ZIP refusal, page limits, natural order and Unicode folding, reading-order guards and page-place validation, and for transfer grants: expiry boundary and millisecond truncation, purpose, salt, random nonce, claim types, lifetime, grammar, book and asset binding, live revocation, scope, owner and deleted-user rechecks, no touch and no adoption on use, verb routing, stream admission, privacy headers, mint body bounds and the asset recheck when the mint opens the file), each of which must fail an assertion, and each must compile. Each mutant run compiles its test binary (`go test -c -p 2`) and runs it directly; it counts as a kill only when that binary exits with status 1 after `testing` itself reported a failed test and its final `FAIL` line, or exits with status 2 because a started test crashed (its own `--- FAIL` frame followed by the panic): every command was first proven to pass unmutated, so that crash is the mutation's. A run that hits the Go test alarm, panics outside a test, is killed, exits otherwise, fails to build, exhausts its own budget or has too little of the stage left never counts, and every distinct test command a mutant uses must first pass on the unmutated module, so a broken fixture or setup stops the stage before any mutant can be counted. Every run is bounded (`GOMAXPROCS=4` for the commands, their tests and the servers those start), runs in its own session and carries a unique run marker in its environment (test servers included); a run that exceeds its budget is cancelled through `os.Process.Kill` of its own leader (a pidfd on Linux), and afterwards every process that carries exactly that marker and descends from the harness (which adopts orphans as a subreaper) is stopped through a pidfd until two consecutive readable scans find none (a run whose processes cannot all be stopped, or whose process table cannot be read, proves nothing and fails the stage), so a recycled process or session id or a parallel run is never touched; the verdict is taken when the run ends, before that clean-up; each run ends before the stage alarm, which is counted from the start of the test process. A test that is skipped makes a run prove nothing, and under a mutant run a fixture or private-copy setup error skips instead of failing, so an environmental failure can never read as a kill. The fixtures and every media file (its bytes and the device, inode, size, modification and change times that make an asset id) are digested before and after the stage and must not change. Only the terminal `FAIL` frame finishes a kill and only `PASS` a survivor; the mutated files are production code only, so test output cannot forge those frames. A unit assertion that kills a mutant ends it before its scenario runs. The CI job records a deadline two minutes inside its 60 minute timeout before checkout (`SHELFARR_VERIFY_DEADLINE_EPOCH`; locally 58 minutes from the start of the script); the mutant test binary is compiled under a 3 minute bound and runs under an outer `timeout` (its own alarm a minute earlier) that also covers the server builds of its `TestMain`, and the stage gets what is left of that deadline after reserving the bounded checks that follow it (16 minutes), or fails at once when fewer than 10 minutes remain.

It also checks that the source bundles keep their digests, that the unchanged M0 checker still
accepts both, that the `linux/amd64` and `linux/arm64` builds are byte-reproducible and that the
repository is untouched. All runs use private generated copies and loopback fixtures.

The `go-http` CI job runs this verifier with full Git history so the pinned stable-schema producer
can read its release object. The experimental packaging checks also cross-build and execute the
binary on amd64 and arm64, assert that it refuses to start without `-experimental`, and verify that
the image keeps the production Rails entrypoint and command.

## Not proven

This is synthetic protocol testing against Rails, not a handover. The mutant harness assumes it owns its private scratch exclusively: it does not guard against another process deleting or rewriting that scratch during a run, against kernel I/O that never returns, or against storage too slow for the CI job, whose hard timeout stays authoritative; outside that assumption a verdict is not guaranteed (a private file deleted mid-run could make a scenario crash), and the stage's correctness rests on it. Not covered: a real client, device or download manager,
production data or keys, TLS and proxy headers, Kobo, the browser, progress and status writes,
requests, rendering of PDF or CBZ pages, any comic archive larger than the synthetic ones, read-along manifests (the `readAlong` locator keys are stored and
validated, nothing more), reference imports, other schema revisions, non-Linux hosts, power-loss
durability (SIGKILL only), and Rails and Go running concurrently against one database. `RAILS_MASTER_KEY` credentials mode and
rotated legacy cursor keys are not supported; a rotated `secret_key_base` invalidates every transfer grant, as in Rails.

## Rollback

The slice adds `apps/server/cmd/shelfarr-http`, the packages named in this change,
`apps/server/e2e/httpruntime`, `tools/migration/http` and this document. The progress slice adds
`internal/strictjson`, `internal/checkpoint`, `internal/live/progress.go`, `internal/gohttp/progress.go`
and extends the verifier; reverting it restores the `501` answers and leaves every row it wrote
readable by Rails. Revert those commits; the
HTTP executable is also listed in the experimental packaging Dockerfile, package inventory and CI
job; remove those references when reverting the runtime. No production route or entrypoint changes. The transfer-grant slice adds
`internal/transfergrant`, `internal/railsmsg/encryptor.go`, `internal/gohttp/transfer.go` and `live.ActiveTokenByID`; reverting it restores
the `501` answers, writes nothing that Rails cannot read, and grants minted by either server keep working on Rails.

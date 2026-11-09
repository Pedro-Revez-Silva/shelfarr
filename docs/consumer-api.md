# Consumer reader and listener preview

The consumer preview adds a mobile web library at `/read` and a versioned API for
the native Android and iOS apps. It reuses Shelfarr's acquired library and normal
account sign-in. Discovery, requests, acquisition, uploads, and administration
remain in their existing flows, except that native apps may opt in to
[finding and requesting](#requesting-from-native-apps) through the same request
service as the web. **Read & listen** in the main navigation or **My Profile → Reader preview** opens the web
experience; acquired book details also link to its reader or player.

This first slice reads DRM-free EPUBs, plays supported local audio files, and
saves personal progress. It does not implement read-along, edition alignment,
PDF/comic reading, or a new acquisition engine. The API is a migration boundary:
clients depend on publications, file-generation assets, and locators rather than
Rails models, paths, or downloader details. A later backend can preserve this
contract while the acquisition engine is replaced incrementally.

## Connect a native app

The app asks for the server address, including any deployment subpath. It then
opens `/consumer/connect` in the system browser, where the user signs in through
Shelfarr's existing password, SSO, and MFA flow and approves the displayed code.
The page names the requesting app and current account. GET and HEAD never approve
a connection; the approval POST requires the normal session and CSRF protection.

By default the app receives only `library:read progress:write`, with a 30-day
expiry. It cannot create requests, manage users, or administer the server unless
the person separately allows requesting, described below; nothing ever grants it
user management or administration. Revoke it from the API
token list in My Profile or disconnect in the app. Soft-deleted accounts lose
access. The existing legacy global API token is **not** accepted by this API.
The web reader uses the current browser session and does not create a bearer
credential or put one in browser storage.

This is a first-party browser-approved pairing flow with short-lived device
grants, not a general-purpose OAuth server or an external-client registration
service. Clients must show the confirmation code, open only a verification URI
inside the configured server boundary, respect polling backoff, and never put
the device code or bearer token in a URL. Codes, locator text and listening
coordinates are filtered from Rails request logs. POST/PUT/PATCH consumer API
bodies are bounded to 64 KiB before Rails JSON parsing.

Use trusted HTTPS for real accounts. Native release builds require it; native
debug builds can explicitly opt into named local development hosts. If the
server uses username-only sign-in, that server policy also applies to browser
approval. Reverse proxies must preserve the configured deployment subpath and
allow media byte-range requests.

## API contract

All paths below start with `/api/consumer/v1`, after any deployment subpath.
JSON uses snake_case except standard Readium locator keys. IDs are opaque strings.
All authenticated endpoints require `Authorization: Bearer <user-scoped-token>`.
Personal responses use `Cache-Control: private, no-store`.

| Method and path | Result |
|---|---|
| `POST /auth/device` with `{client_name, scope?}` | `{device_code,user_code,verification_uri,verification_uri_complete,expires_in:600,interval:5}` |
| `POST /auth/token` with `{device_code}` | `{access_token,token_type:"Bearer",scope,expires_in:2592000}` |
| `POST /auth/revoke` | Revoke the current credential; 204 |
| `GET /me` | `{id,name,username,scopes}` |
| `GET /library?type=ebook\|audiobook&q=...&status=...&sort=...&limit=30&cursor=...` | `{items:[publication],next_cursor}` |
| `GET /continue?limit=10` | `{items:[publication]}` across the library, most recent activity first |
| `GET /library/:id` | One publication |
| `PUT /library/:id/reading_status` with `{status}` | Updated publication; requires `progress:write` |
| `GET /library/:id/assets/:asset_id` | Original media bytes; GET, HEAD, single byte ranges, strong ETag, If-Range |
| `POST /library/:id/assets/:asset_id/transfer_grant` with `{}` | 201 `{url,expires_at}`: a bearer-free URL for that asset, described below |
| `GET /library/:id/assets/:asset_id/transfer?grant=...` | The same media bytes, authorized only by the grant in the URL |
| `GET /library/:id/progress` | `{progress:null\|progress}` |
| `PUT /library/:id/progress` | Compare-and-set progress, described below |
| `GET /discover?q=...&limit=12` | `{items:[candidate]}`; requires `search:read` |
| `GET /requests?limit=30` | `{items:[request]}` for this account, most recently changed first; requires `requests:read` |
| `GET /requests/:id` | `{request}`; this account's only, otherwise 404 |
| `POST /requests` | Request one format, described below; requires `requests:write` |
| `DELETE /requests/:id` | Cancel this account's unfinished request; requires `requests:write` |

Token polling returns 400 with `error: authorization_pending`, `slow_down`,
`access_denied`, or `expired_token`. Grants expire after ten minutes and exchange
once. Polling faster than the current interval increases it by five seconds,
up to sixty; the client must back off. Public grant creation and polling also
have per-IP rate limits. An expired or revoked bearer receives 401; missing
scope receives 403 with `error: insufficient_scope`.

Library pages default to 30 items and cap at 50. Signed keyset cursors are bound
to the account, query, type, reading status and sort. Changing any of them starts a new page chain.
`sort=recent` (default) orders by acquisition record ID descending; `sort=title`
orders by SQLite lowercase title then ID, with stable keyset pagination. An
acquired-book expression index and cursor range avoid sorting or walking the
preceding catalog on each title page. Omit
`status` for all titles or choose `unread`, `in_progress`, or `finished`.
Only acquired ebook/audiobook Book records are projected. Remote-only owned
inventory and pending requests are not fabricated as playable media. A missing
or unsupported source has an empty assets array, while its metadata remains
visible. Search matches title and author; it does not call metadata providers.

```json
{
  "id": "publication-id",
  "title": "A story",
  "author": "An author",
  "description": "...",
  "book_type": "ebook",
  "cover_url": null,
  "assets": [{
    "id": "opaque-file-generation-id",
    "filename": "Story.epub",
    "format": "epub",
    "media_type": "application/epub+zip",
    "size_bytes": 12345,
    "position": 0,
    "content_url": "/api/consumer/v1/library/publication-id/assets/opaque-file-generation-id"
  }],
  "reading_status": "unread",
  "progress": null
}
```

Clients must restrict credentials to the configured origin and subpath. Asset
URLs include the subpath when supplied by the deployment. A metadata cover can
be an external HTTPS URL: fetch it **without** credentials or use a generated
fallback. Covers are not fetched by the Shelfarr backend.

## Requesting from native apps

Requesting is opt-in per app connection and approved in the browser, like the
connection itself. `GET /server.json` lists `"requests"` in `consumer_features`
on servers that offer it; clients explain older servers instead of opening an
approval they cannot complete.

### Permission

An app asks for the bundle with `scope` set to exactly
`library:read progress:write search:read requests:read requests:write` on
`POST /auth/device`. Any other combination, or naming a privileged scope such as
`requests:admin` or `users:write`, returns 400 `invalid_scope`. Omitting `scope`
keeps the read-and-listen pair. Existing tokens never change scope.

- **Adding requesting to a connected app** sends that app's current bearer with
  the device request. A missing, expired or revoked bearer returns 401. The
  approval page then says the app is already connected and asks to *Allow
  requesting* or *Not now*, lists what the app will be able to do, and states that
  it cannot see other people's requests, manage users or change server settings.
  Only the account that owns the bearer can decide; another signed-in account sees
  a "Different account" page and its POST returns 403 without touching the grant.
- **Not now** or expiry leaves the old token and its scopes untouched.
- On approval the token endpoint issues a new 30-day token with the bundle. The old
  token keeps working until the new one is first used, then it is revoked, so a lost
  token response never strands the app. Clients replace the credential in place and
  keep the server, account files, downloads, settings and saved places.
- A fresh connection may ask for the bundle too; the page then offers *Connect and
  allow requesting*.
- Tokens from device approval are marked as such and never act as admin tokens on
  this API or on `/api/v1`, even for an admin account: they only see and create
  that account's own requests. `GET /me` reports the token's `scopes`, so a client
  notices when requesting was revoked.

### Finding titles

`GET /discover` searches the same enabled metadata providers as web search, for
books (comics are not offered to these clients). Queries are 1–200 characters;
invalid queries return 422 `invalid_query`. Provider connection failures return
503 `search_unavailable` and other provider errors 502 `search_failed`. Covers
are HTTPS only or `null`.

```json
{
  "id": "openlibrary:OL1W",
  "work_id": "openlibrary:OL1W",
  "source_work_ids": ["google_books:abc"],
  "title": "A story", "author": "An author", "year": 2019,
  "description": "...", "cover_url": null,
  "series_name": null, "series_position": null, "source_name": "Open Library",
  "formats": [
    {"book_type": "ebook", "state": "in_library", "publication_id": "42", "request": null},
    {"book_type": "audiobook", "state": "requested", "publication_id": null, "request": {"...": "request"}}
  ]
}
```

Each format's `state` is `requestable`, `in_library` (open `publication_id`),
`requested` (this account's own `request`) or `requested_by_someone` (no details
about the other account). Clients treat unknown states as not requestable.

### Requests

`POST /requests` takes `{work_id, book_type, title, author?, cover_url?, year?,
source_work_ids?, language?}`. `book_type` is `ebook` or `audiobook`; `user_id`,
`username` and other on-behalf fields are ignored. Creation goes through
`RequestCreationService` with `created_via: api` and `external_source:
consumer_app`, so duplicate checks, notifications, queueing, automatic search
policy and enabled providers are exactly as for the web.

| Status | Meaning |
|---|---|
| 201 `{request, warnings}` | Created |
| 200 `{request, existing: true}` | This account already has it open; nothing new was created (repeated taps are safe) |
| 409 `already_in_library` with `publication_id` | Already acquired |
| 409 `already_requested` | Another account has it open |
| 422 `invalid_request` / `request_rejected` with `message` | Malformed input / refused by the request service |
| 403 `insufficient_scope` | Read-only connection |

Concurrent submissions from one account are serialized in the server process, so a
double tap creates one request. A request is:

```json
{
  "id": "17", "status": "downloading", "stage": "downloading",
  "attention_needed": false, "title": "A story", "author": "An author",
  "book_type": "audiobook", "cover_url": null, "download_percent": 42,
  "can_cancel": true, "next_retry_at": null, "publication_id": null,
  "created_at": "2026-11-09T10:00:00Z", "updated_at": "2026-11-09T10:05:00Z"
}
```

`stage` is `queued`, `searching`, `not_found`, `awaiting_purchase`,
`downloading`, `processing`, `available` (open `publication_id` through
`/library/:id`), `completed` (finished but no longer readable here) or `failed`
(also what a cancelled request shows). Clients treat unknown stages as in
progress. Indexers, download clients, paths and internal error text are never
included. `DELETE` uses the same cancellation as `/api/v1`; finished or
finalizing requests return 422 `cannot_cancel` with a `message`.

## Media and file safety

The API and browser player open validated regular-file descriptors under the
same configured roots and recorded reference-import provenance as existing web
downloads. They do not hand pathnames to Rack::Sendfile. Source path changes,
replaced inodes, or file-generation changes invalidate old asset URLs with 410.
No filesystem path is exposed in the publication or error response. Asset IDs
are generation identities derived from file stat information, not content hashes
or an archival promise that replaced editions remain available.

Single files and book-specific directories work. Audio files are naturally
ordered so Chapter2 precedes Chapter10. Scans stop at 2,000 entries and eight
nested levels, skip hidden directories, and refuse an item pointing at the whole
shared library root. EPUB files are capped at 250 MiB for the API and 32 MiB for
the current web renderer. Audio types are MP3, M4B/M4A, AAC, Ogg/Opus, FLAC and WAV;
actual codec playback depends on the platform. No conversion or transcoding runs.

Range responses support one `bytes=start-end`, open-ended or suffix range. Invalid,
multiple, or unsatisfiable ranges receive 416 and `Content-Range: bytes */size`.
A non-matching If-Range returns the complete file. HEAD reports full-file headers
without streaming or changing progress. A matching If-None-Match returns 304 so
native clients can revalidate cached ebooks without downloading them again.

## Background transfer grants

System background downloads (an iOS background `URLSession`) persist their
requests and follow redirects without asking the app, so they must not carry the
account bearer. Instead the app asks for a grant with the bearer (`library:read`):

```
POST /api/consumer/v1/library/:id/assets/:asset_id/transfer_grant
201 {"url": "/api/consumer/v1/library/:id/assets/:asset_id/transfer?grant=<opaque>",
     "expires_at": "2026-11-08T14:20:00Z"}
```

- `url` is a path under the deployment subpath, like `content_url`. It fetches only
  that publication's exact asset generation, with GET or HEAD, and the same ETag,
  If-Range, single Range, If-None-Match/304, 416 and 410 behaviour as the bearer
  asset URL. Other methods get 404. The bearer asset URL is unchanged.
- The transfer route reads only one literal `grant` query parameter. It ignores the
  `Authorization` header and cookies, and no other endpoint accepts a grant.
  Encoded, repeated or nested spellings, or extra parameters, are refused.
- A grant is opaque: AES-256-GCM encrypted and authenticated, with a purpose and a
  key derived from `secret_key_base`, so nothing is stored and no bearer is ever
  stored or embedded. It names the issuing token, its user, the publication and the
  asset generation.
- It lasts 24 hours, or until the issuing token expires if that's sooner. Every
  request re-checks that the token is live (not revoked, expired or deleted), still
  has `library:read`, and belongs to the same non-deleted user.
- An invalid, expired or refused grant gets 401 `{"error":"invalid_grant"}`; the
  client mints another one with the bearer. A replaced file gets 410 and a removed
  publication 404, as on the bearer asset URL. Minting for a changed asset gets 410
  `asset_unavailable`, an unknown publication 404, and a server without this
  feature 404, which clients treat as "no grants".
- Responses are `Cache-Control: private, no-store` and never redirect. Request logs
  filter `grant`, including encoded or nested keys and unknown routes. Rotating
  `secret_key_base` invalidates outstanding grants.

## Reading status and Continue

Reading status is personal and independent of the saved place. Without an
explicit choice, a publication with progress is `in_progress`; otherwise it is
`unread`. An explicit Unread, Reading, or Finished choice overrides that default
and later position writes preserve it. Status writes use the last explicit
choice and do not reset the locator or listening position.

Continue considers progress and explicitly Reading titles across the whole
library, rather than just the first catalog page. It skips unavailable files,
Finished/Unread titles, and saved positions whose file generation no longer
matches. It defaults to ten items, capped at twenty, and inspects at most the
200 most recently active candidates. There is no Continue cursor.

## Saved progress

Positions belong to a user and publication and name the exact `asset_id`. Ebook
positions carry a Readium-style locator with ZIP-root-relative `href` and bounded
`locations`; audio positions are seconds within the named file. The server stores
the locator rather than converting it to a percentage-only position. Reflowable
text has no universal page count: cross-engine resume uses resource/progression
and can be approximate. The web reader also saves its EPUB CFI for exact resume
within that renderer. Read-along and alignment remain separate future work.

```json
{
  "asset_id": "current-file-generation-id",
  "expected_version": 0,
  "client_mutation_id": "e4519931-dfe8-4ada-b75c-6d7ecfe11ae9",
  "locator": {
    "href": "OEBPS/chapter.xhtml",
    "type": "application/xhtml+xml",
    "locations": {"progression": 0.3, "totalProgression": 0.2}
  }
}
```

For audio, send `position_seconds` instead of `locator`. Version 0 means no saved
position. A successful write returns `{progress:{asset_id,locator,position_seconds,
version,observed_at,updated_at,client_mutation_id}}`. Invalid, out-of-bounds, or
no-longer-available assets return 422. Never apply an old locator to a replaced file.

### Activity time and conflicts

Two optional fields make offline and multi-device reconciliation follow when the
reading or listening actually happened, not when it reached the server:

- `observed_at` is when the device reached this place: ISO-8601 with an explicit
  time zone, such as `2026-11-07T09:15:30.123Z`. The server stores it as UTC
  milliseconds and returns it, or `null` when the time is unknown. `updated_at`
  stays the server's acceptance time. Times more than five minutes ahead of the
  server, local times without a zone, impossible dates, and non-strings return
  422. Rows saved before this field, and writes from clients that omit it, have
  an unknown activity time; the server never fills it from the upload time.
- `resolve_conflict` is `true` only when the user explicitly chose to keep this
  device's place over the one shown. It defaults to `false`; strings, numbers and
  other values return 422. It still requires the exact current
  `expected_version`, a current asset and a UUID. Automatic rebasing never sets it.

The server applies a write when, in order:

1. The stored mutation has the same UUID and identical asset, place and
   `observed_at`: the retry is idempotent and returns the stored progress
   unchanged. The same UUID with any different value is a 409.
2. `expected_version` matches the stored version (0 when nothing is stored);
   otherwise 409.
3. Unless `resolve_conflict` is true, the write is not older than the stored
   activity. When both times are known, an earlier `observed_at` is a 409 even
   with a matching version, and an equal time is accepted only for the same
   place. When either time is unknown, the version check alone decides, as before.
   A later time wins wherever it is in the book, so seeking backward is a valid
   new observation.

A 409 has `error: progress_conflict` and the canonical `progress` (or `null`).
Clients reconcile it like this:

- Retry an uncertain request (lost response, timeout, 5xx) with exactly the same
  body: position, `observed_at`, UUID and `resolve_conflict`.
- After a definite 409, compare the canonical `observed_at` with the newest local
  observation, including places queued behind the rejected write. If local is
  later, send it again with the returned version, a **new** UUID and its original
  `observed_at`. If the server copy is later, adopt it and drop the older local
  writes. Do not move an actively playing or reading session for that; apply it
  at the next safe resume point.
- Ask the user when the times are equal with different places, either time is
  unknown, or the server copy names an asset this client can't map. Keeping this
  device's place is a new choice: record a fresh `observed_at` and
  `resolve_conflict: true`, persist that before sending, and use the returned
  version and a new UUID. Choosing the other device's place discards the local
  writes.
- Opening a book, restoring a saved place, an automatic resume rewind, metadata
  refreshes and sync acknowledgements are not new activity and must not create a
  checkpoint or a new `observed_at`.
- A 422 keeps the local saved place; it is never silently discarded.

Continue orders saved places by `observed_at` when known and otherwise by the
server time, so a late upload of older offline activity does not jump ahead of
titles read since. A server without these fields ignores them and leaves
`observed_at` absent; clients then keep the explicit-choice flow for every 409.

## Web reader build and validation

EPUB.js renders the ebook, after final section serialization is sanitized with
DOMPurify and a restrictive content policy. Reader frames have no script, popup,
form, or top-navigation permission. The web player uses normal HTML audio and
optional Media Session controls; background behavior remains browser-dependent.
Text size and listening speed persist on this browser. Changing tracks while
paused keeps playback paused; reaching a track end continues automatically.
The web reader needs a connection to open a book and does not offer offline
downloads.

Reading an EPUB shows only the book text across the whole viewport: no header,
cover, description, status form, chapter or font toolbar, or page buttons.
Arrow and Page keys, swipes, and taps on the left or right third turn pages.
Escape, a tap in the middle, or the **Show reading controls** button (the first
keyboard stop, visible when focused) reveals an overlay with the library link,
title, page buttons, chapters, text size, sync state and reading status. The
overlay floats above the text, so opening it never resizes the pages or moves
the saved place. **Done**, Escape or another tap hides it and returns focus to
the text; hidden controls cannot be focused. Selecting text never turns a page.
Problems stay visible without the overlay: a small notice when a place is only
on this device, and alerts for conflicts and errors.

A restored EPUB place (from the account, this browser's outbox, or another
device's place the reader chooses) opens on the page that contains its saved
CFI, at the current viewport and text size. EPUB.js 0.3.93 positions a newly
rendered section before the frame grows to fit the themed text, which clamped
deep places to an earlier page. The reader therefore positions once more after
the frame fits the laid-out text and fonts have loaded, and does so again after a
window or orientation change. Restoring a place, resizing the window and
changing text size are not activity: they never create a checkpoint or change
`observed_at`, the version or the mutation ID. Deliberate page turns, links and
chapter choices wait for a layout correction to finish before navigating.

### Browser progress outbox

The web reader keeps a durable outbox in `localStorage`, keyed by account,
origin, deployment subpath and publication, so accounts and servers never share
it. Journal and mutation IDs remain cryptographically random on local HTTP
connections, where the browser does not expose `crypto.randomUUID()`. Each genuine checkpoint (a page turn, followed link or chapter choice; while
listening, at most five seconds apart, and immediately on pause, seek, track
change, hiding or leaving the page) is stored with its `observed_at` before any
request. Tabs share the outbox without a lock: `localStorage` makes only single
operations atomic, so every observation, request, server answer, conflict and
rejection is its own entry, written once under a new key and never rewritten.
The outbox state is derived from all entries, and an entry is removed only after
a stored entry that supersedes it exists, so a place another tab saves while
this tab handles a response is always kept. A version 1 single-record outbox is
converted into entries, keeping its pending request, queued place, rejection
and open conflict, before the old record is removed.
Sync then follows the rules above: identical retries after uncertain
failures, retry on reconnect, page focus and reload, automatic rebasing or
adoption when both activity times are plausible (not before 2000 and at most
five minutes ahead of this browser), and an explicit choice otherwise.
A persisted choice survives a reload. Rejected writes and expired sessions keep
the local place and its activity time and say so. Observations retain which local
entries preceded them, so a large clock correction cannot make an older upload
erase a later checkpoint; uncertain times still require a choice. Responses to
requests already superseded by a persisted choice do not reopen the conflict.
Opening a book shows the newer of the waiting local
checkpoint and the server copy. A later place from another device moves the page
only when this visit has not moved yet; otherwise **Go there** offers it, and a
paused audiobook takes it on the next Play.

Pressing Play to resume a paused or reopened audiobook rewinds five seconds within
the track, clamped to zero, once per resume. Choosing a track, seeking while
paused, and a natural move to the next track do not rewind. Restoring a place,
the rewind itself and sync acknowledgements are not activity: the saved place is
kept until playback passes it again. If the browser refuses storage, the page
says so and syncs only while it stays open. Browsers may suspend background tabs;
reliable background progress needs the native apps. Unsent places for an account
remain in that browser's storage after sign-out until that account syncs them.

The browser engine is checked in at `vendor/javascript/consumer_reader_engine.js`.
Production does not install JavaScript packages or fetch reader code from a CDN.
To reproduce it with Bun 1.4.4:

```sh
cd apps/web-reader
bun install --frozen-lockfile
bun test   # includes the progress outbox and listening checkpoint rules
bun audit
bun run build
git diff --exit-code -- ../../vendor/javascript/consumer_reader_engine.js
```

The web-reader CI job repeats these checks, including bundle drift. Package
versions, patched XML-parser override, third-party notices and licenses are kept
beside the build source. Shared fonts and design colors live under `apps/design`.
The Ruby quality gate includes actual browser tests for EPUB rendering/safety,
text-only reading with overlay controls, page navigation, real audio playback,
the resume rewind, offline reload recovery, cross-device progress and mobile overflow, plus API
authorization, generation-bound media, byte ranges and competing SQLite writes.
Native build and physical-device validation are documented with the native apps.

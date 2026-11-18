# Frontend migration: the static library preview

This is the first working slice of the TypeScript frontend described in
[`backend-migration.md`](backend-migration.md). It is a pilot: **off by default,
enabled per user by an operator, served by the existing Rails app**. It does not replace
`/read`, the offline worker, the installable app or any native client.

## What it is

A static TypeScript/React app (TanStack Router and Query, strict TypeScript, runtime-validated
JSON) with two pages:

- **Library** — the books and audiobooks on this server: search, type/status/sort filters,
  load more, "Keep going" (continue reading), real covers and availability.
- **Publication details** — metadata, files, a Read/Listen action that opens the existing web
  reader or player, and a reading-status control.

Discover, Requests, Account and Admin stay in the classic app. The shared navigation labels
them as such ("opens the classic Shelfarr app"); nothing here pretends to implement them.

## Enabling it

```
SHELFARR_WEB_PREVIEW_USER_IDS=3,12
```

A comma-separated list of positive user ids (at most 100). Whitespace around entries is
ignored. Unset or empty means the preview is off for everyone. **Any malformed entry turns it
off for everyone** and logs `SHELFARR_WEB_PREVIEW_USER_IDS is malformed ...`, so a typo can
never enable a different set of people. There is no database change, and removing the variable
restores the previous behaviour for everybody immediately; saved places, reading statuses and
downloads are untouched because the preview never owns them.

Nothing links to the preview. An enabled user opens `<your server>/preview`. The classic
library, header and `/read` are unchanged for everyone, enabled or not.

Enforcement is server-side, in one concern (`WebPreviewAccess`), on the shell and on every JSON
action:

| Situation | Shell (HTML) | JSON |
| --- | --- | --- |
| feature off (no valid list) | 404, even signed out | 404 `{"error":"not_found"}` |
| signed out | redirect to sign-in, returning to the preview | 401 `{"error":"signed_out"}` |
| signed in, not on the list | 404 | 404 `{"error":"not_found"}` |
| on the list | shell | JSON |

## Where it lives

| Purpose | Path (under the deployment subpath, if any) |
| --- | --- |
| shell | `/preview` (redirects), `/preview/library`, `/preview/library/:id` |
| JSON | `/preview/api/v1/...` |
| static assets | `/assets/web/preview-<digest>.js` and `.css` |

It is deliberately **outside `/read`**: the offline worker's scope, the installed app's id and
start URL, offline downloads and outbox, and every reader URL are unchanged. The preview
registers no service worker and stores no API data in the browser (no `localStorage`,
IndexedDB or Cache Storage); scroll positions live in the browser's history entry.
`RAILS_RELATIVE_URL_ROOT` is supported: the server builds the mount, API base and every
handoff link, and the browser tests run the full flow under `/shelf`.

## Authentication, CSRF and account binding

The browser keeps using the Rails cookie session. No bearer token is minted into JavaScript and
`/api/consumer/v1` (native, Kobo, consumer apps) is untouched.

- Mutations (`PUT`) need Rails' `X-CSRF-Token` (from the shell's `csrf-meta-tags`).
- **Every** request, reads included, must send `X-Shelfarr-Account: <id of the account the page
  was built for>`. A missing or different value is `401 {"error":"account_changed"}` before any
  data is read or written. (The older `PUT /read/:id/reading_status` has no such guard; the new
  endpoint does.) A custom request header also makes a cross-site page need a CORS preflight.
- Every success body repeats `account`. The client refuses a body for another account and
  locks the tab.
- A locked tab (signed out, or account changed in another tab) cancels in-flight queries,
  empties the query cache and renders only an explanation with a way back; it never renders
  data from before.
- The page keeps one trust state: `trusted`, `checking` or `unverified`. Every window `focus`,
  `pageshow` or visible-document event starts a new generation and a fresh `GET session` (events
  in the same burst share one request); only the check of the latest generation can change the
  state, so an older answer can never confirm a newer event. While `checking`, every personal
  response is held. It is delivered only once the check confirms the same account. A failed or
  timed-out (8 s) check leaves the page `unverified`: held and later responses are refused with a
  retryable error that triggers a new check, so recovery is always a fresh positive answer.
  Authoritative `signed_out` / `account_changed` answers are processed immediately, never
  queued behind a check, and held requests honour cancellation.
- Query keys start with `["account", <id>]`. The checks above run without any user action, so a
  switch in another tab is noticed on return.
  A response the server generated for the old account before the first check started cannot be
  told apart from a normal one; it was the old account's data at request time.

## Contract (v1)

Before this change there was no session-authenticated catalogue read for the browser (the
consumer API is bearer-only) and only one account-race-prone status write. Now (all `private,
no-store`, JSON, errors `{"error": code, "message"?: text}`):

| Request | Success body | Notes |
| --- | --- | --- |
| `GET session` | `{account:{id,name}, server:{name,version}, links:{legacy_library,discover,requests,account}, admin?:{url}}` | `admin` exists only for admins. Links are server-built paths. |
| `GET library?q&type&status&sort&cursor&limit` | `{account, items:[summary], next_cursor}` | `Consumer::Catalog` with the web reader formats; the same cursors as `/read`. 400 `invalid_request` for bad filters. |
| `GET continue?type` | `{account, items:[summary]}` | `Consumer::ContinueReading`, up to 3. |
| `GET library/:id` | `{account, publication:{summary + description, files[]}}` | 404 `not_found` for unknown, unacquired or deleted books. Writes nothing. |
| `PUT library/:id/reading_status` `{status}` | as `GET library/:id` | `Consumer::ReadingStatus.set`; keeps the saved place. 422 `invalid_reading_status` / `invalid_csrf`. |

`summary` is `{id, title, author|null, book_type, content_kind, format_label, availability,
action, cover:{url|null, style}, reading_status, progress|null, progress_label, reader_url}`.
`progress` is `{asset_id, position_seconds|null, fraction|null, page|null, version,
observed_at|null, updated_at}`: exact asset identity, the device activity time and the server
receipt time are passed through unchanged. `description` is plain text (markup stripped by the
server, and rendered as text, never HTML, by the client). `cover.url` is a plain `https` address
(no credentials) fetched by the browser directly, exactly as in the classic UI; the generated
cover is the fallback for a missing or failing image. `reader_url` is the existing `/read/:id`
(reader or player), including the deployment subpath.

Progress writes are not part of this contract: they stay in the existing reader, with its
outbox, conflict and `observed_at` rules.

The shapes are defined once, in `apps/web/src/contract.ts` (zod schemas, types inferred). The
client validates every response and boot payload against them instead of casting.

### Temporary ownership and the Go-compatible target

Rails owns these endpoints for now (`app/controllers/web_preview/*`), reusing the domain
services (`Consumer::Catalog`, `Consumer::Publication`, `Consumer::ContinueReading`,
`Consumer::ReadingStatus`). A Go replacement must keep the same paths, JSON shapes, error codes,
`private, no-store`, account-header rule and the cookie-session plus CSRF contract (or an explicit,
tested session handover that preserves account and offline-outbox ownership). Routes for the
SPA itself can move to `/` or `/read` only with the transition described in
`backend-migration.md` (worker scope, app id and start URL, outbox keys).

## Build and delivery

- Source: `apps/web` (Bun, `bun.lock` pinned, exact dependency versions).
- `cd apps/web && bun install --frozen-lockfile && bun run verify` runs the strict typecheck,
  the component and contract tests and the build.
- The build writes `app/assets/builds/web/preview.{js,css}` (git-ignored). Propshaft digests
  them at `assets:precompile`, which also rewrites the font URLs; the shell uses the normal
  asset helpers, so the files are served like every other asset: `Cache-Control: public,
  max-age=31556952`, gzip by Thruster, unversioned names are 404.
- The production `Dockerfile` has a `web-build` stage on a pinned `oven/bun` image that runs
  the typecheck and build and copies the output in before `assets:precompile`. The final image
  contains no JavaScript runtime and serving needs none.
- CI: a `web-preview` job (typecheck, tests, `bun audit`, build) and a Bun build step before the
  Rails quality gate, whose shell tests need the built files. The Rails test helper builds them
  if they are missing.
- Single bundle, no code splitting: Propshaft digests file names but does not rewrite chunk
  imports.
- The shell sends a strict CSP: scripts, styles and fonts from this server only, no inline
  script or style, `https:` images for remote covers. zod runs in `jitless` mode because its
  default fast path uses `eval`, which that policy forbids. The browser tests fail on any
  `securitypolicyviolation`.

## Behaviour worth knowing

- **Back** restores the filters (they are in the URL), the loaded pages and the scroll position.
  Within the app the query cache makes this immediate; after leaving the app (the reader) and
  coming back, up to 20 pages are replayed from the history entry and the scroll position is
  restored.
- Opening details never writes. Only the reading-status control does.
- A deleted book, a book whose files vanished, a broken cover, a lost session, a network
  failure and an account switch each have a distinct, recoverable state.
- Network mode is `always`: a request is attempted even if the browser believes it is offline
  and failures are reported, instead of waiting silently.

## Verification

- `bun test`: contract, client, account-guard, library, details and restoration behaviour.
- Rails: access/flag, CSRF, account binding, catalogue/continue/details/status contracts, plain
  text sanitising, subpath.
- Real Chromium (`test/system/web_preview_test.rb`, root and `/shelf`): the flows above through
  the real API and database, including the hand-off to the existing EPUB reader and audiobook
  player and the saved place that comes back to the preview.

## Go-served reader (later slice)

When the experimental Go runtime serves these screens, Details and "Keep going" link EPUBs and audiobooks to an online
reader and player at `/preview/library/:id/read` instead of the Rails `/read/:id` (the JSON `reader_url` keeps its Rails
meaning; the Go link is derived in the client). PDFs and comics stay honestly unavailable there. See
[`go-http-migration.md`](go-http-migration.md#online-epub-reader-and-audiobook-player-opt-in). Under Rails nothing changes.

## Not in this slice

Full frontend parity, Go authentication or write ownership, moving `/read` or the PWA identity,
rewriting Discover/Requests/Admin, a service worker or offline use for the preview, progress
writes from the preview, production rollout. Safari and real devices have not been exercised:
only Chromium ran. The patterns used (popover-free navigation, native form controls, CSS
`:has`, grid, `dvh`) are Baseline, but that is not an acceptance claim.

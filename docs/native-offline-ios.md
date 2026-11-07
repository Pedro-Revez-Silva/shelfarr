# iOS: background downloads, offline library and runtime smoke

How the native iOS app keeps downloads moving when it isn't in front, what it can
show without a connection, and how its simulator smoke test exercises both. The
shared contract and Android behaviour are in [native-consumer.md](native-consumer.md)
and [consumer-api.md](consumer-api.md).

## Background downloads

### What runs where

`DownloadManager` (in `ShelfarrCore`) is the only code that writes an account's
download files or manifest. It no longer moves bytes itself. Each transfer is a
**ticket**: one byte range of one pinned file, written to the manifest before
the transfer exists. Tickets go to one of two executors:

| | Background executor | Foreground executor |
|---|---|---|
| Runs in | the app's one system background `URLSession` (`org.shelfarr.app.downloads`) | the app process, via `URLSessionTransport` |
| Credential | an asset-scoped **transfer grant** in the URL, and no bearer | the account's bearer |
| Redirects | followed by the system; bytes from outside the server are discarded | refused before they're followed if they leave the origin and subpath |
| Survives suspension or the system ending the app | yes | no; resumes when the app runs |
| Used when | the server issues grants | the server answers 404 to the grant endpoint |

The split comes from Apple's documented behaviour. Background sessions follow
redirects without calling `urlSession(_:task:willPerformHTTPRedirection:...)`, which
is only called for default and ephemeral sessions. The system daemon also keeps their
requests outside the Keychain. If the general bearer went on a background request, a
redirect could carry it outside the configured origin and subpath, including to a
different path on the same host. The background executor therefore refuses any request
that has an `Authorization` header, and the manager never gives it one. It's
best-effort: iOS schedules background transfers at its own discretion, slows down
tasks created while the app is in the background, and cancels them all when the user
force-quits the app. None of those can be worked around.

### A transfer, step by step

1. **Re-pin.** Fetch the publication with the bearer. If its asset ids changed, cancel
   and forget the old edition's tickets and bytes first.
2. **Preflight.** `HEAD` the asset with the bearer through the foreground transport.
   The transport refuses redirects that leave the server, a 401 marks this session
   expired, and the response gives the strong `ETag` and length. A changed `ETag`
   for a file that already has bytes is a changed file, and nothing gets stitched.
3. **Grant.** `POST …/transfer_grant` with the bearer. The returned URL must resolve
   inside the server's origin and subpath, or the download fails as unexpected. A 404
   means the server has no grants; that manager's later transfers stay in the
   foreground.
4. **Plan.** Split what isn't already on disk or requested into 32 MiB ranges, each
   with `Range` and `If-Range: <strong ETag>`. A small file with no bytes yet is one
   plain `GET`. Without a strong `ETag` or a known length, the request is the whole
   file. A lane holds at most 64 tickets and plans more as they drain.
5. **Persist, then submit.** The tickets and the file's validator reach the manifest
   before any task is created. A task description is
   `shelfarr-download/1/<account key>/<ticket id>`, with no credential in it.
6. **Receive.** In `didFinishDownloadingTo`, the `TransferRouter` synchronously moves
   the body into that account's `downloads/staging/`. It does so only if that account
   is registered and the ticket hasn't been revoked. Otherwise the system deletes the
   file.
7. **Accept.** A 206 must carry the requested `Content-Range`, a matching `ETag` if
   it sends one, and exactly that many bytes. Ranges arrive in any order and are
   appended strictly in order, so the `.part` file is always a verified prefix. A 200
   replaces the partial file. 410, 412 and 416 mean the file changed. A final URL
   outside the server is a redirect failure, and its bytes are discarded.
8. **Ready.** A file is complete when its length matches and an EPUB starts with `PK`.
   The download is `ready` only once every pinned file, including every audiobook
   track, is complete.

At most two publications transfer at once. The background session also caps
connections per host at two.

### Launch, relaunch and completion

`AppModel.shared` is created in `application(_:didFinishLaunchingWithOptions:)`, so it
also exists during a background relaunch with no UI. It connects the signed-in
account's manager to the router before the background session is created, so even the
first callback after a relaunch has an owner. `start()` then reconciles the manifest
with `allTasks`:

- A ticket with no running or suspended task, and no body staged or being delivered,
  was lost. It is dropped, and its range is planned again.
- A task that no ticket owns, or that was minted with a token this account no longer
  uses, is cancelled.
- A staged body that no ticket waits for is deleted.
- Tasks that are still running are adopted, with no network and no duplicate requests.

`application(_:handleEventsForBackgroundURLSession:completionHandler:)` stores the
handler. When the session reports `urlSessionDidFinishEvents`, the router waits until
every delivered event has been processed and written to the manifest, then calls the
handler on the main queue.

### Boundaries

- **Accounts.** Routing uses the account key in the task description. A callback for
  an account that isn't registered, such as one that signed out, writes nothing, and
  it never reaches another account.
- **Cancel, remove, sign-out.** Tickets are revoked in the router first, so no later
  body is written. Then the tasks are cancelled, and only then are files deleted.
  `close()` unregisters the account and cancels its tasks in both executors before
  disconnecting deletes the account folder.
- **Token expiry.** Only a 401 to this session's own bearer marks it expired: from
  the preflight, the grant endpoint, or a foreground transfer. A 401 to a grant means
  the grant expired or was refused. It is planned again with a fresh grant, never
  signs out, and fails as a server problem after three refusals in a row. A late 401
  for a ticket sent with an older token can't expire the current session.
- **Keychain and backups.** These are unchanged: the session stays in the Keychain
  (`AfterFirstUnlockThisDeviceOnly`), and `downloads/` stays excluded from backup. No
  bearer is written to disk outside the Keychain. A grant does sit in the system's
  task store until its task ends; it is short-lived and only opens that one asset.
- **Manifest.** Version 2 holds records and tickets. A version 1 manifest (records
  only) loads as before. Its `.part` files resume, validated by their `.etag` sidecar
  and a fresh preflight.

New download state: `interrupted` ("Paused"). It's used when iOS stops a task, for
example after a force-quit (the error carries
`NSURLErrorBackgroundTaskCancelledReasonKey`). It retries when the app returns to the
foreground, like `offline` and `server`.

### Transfer grant contract (backend)

The consumer API and the smoke fixture implement this contract.
It's additive: a server without it keeps working, with foreground-only transfers.

```
POST /api/consumer/v1/library/:publication_id/assets/:asset_id/transfer_grant
Authorization: Bearer <consumer token>      (scope library:read)
Content-Type: application/json
{}

201 {"url": "<path or absolute URL>", "expires_at": "2026-11-08T14:20:00Z"}
```

- `url` fetches exactly this asset generation. It must sit under the configured origin
  and subpath, and it carries the grant in a query parameter,
  e.g. `/api/consumer/v1/library/:id/assets/:asset_id/transfer?grant=<opaque>`. The client
  refuses a URL outside the server.
- The grant authorizes only `GET` and `HEAD` of that one path, with the same
  `ETag`, `If-Range`, single-`Range`, `If-None-Match`/304, 416 and 410 behaviour as a
  bearer request. Every other endpoint rejects it. The client never sends a grant and
  a bearer together.
- It is opaque, at least 128 bits, and stored hashed or signed. It is bound to the
  issuing access token, the user, the publication and the asset generation. Revoking
  or expiring the token, or replacing the file, invalidates it.
- Lifetime: the client tolerates anything from 15 minutes. Around 24 hours suits a
  system scheduler that may start a task late.
- An invalid or expired grant gets 401 `{"error":"invalid_grant"}`. The client mints
  another one with the bearer and never signs out because of it.
- Never redirect a grant request: serve it or answer 4xx. Send
  `Cache-Control: private, no-store`, and filter `grant` from request logs.
- 401 or 403 for the bearer, and 404 or 410 for the asset, behave like the asset
  endpoint. A 404 for the endpoint itself means "no grants". The client mints one grant
  per file each time it plans, so a per-token rate limit should allow bursts of a few
  dozen.

Because the grant travels in the URL, a redirect target gets a new URL without it.
The general bearer never enters the system's task store.

## Offline library

`LibraryCache` (in `ShelfarrCore`, `accounts/<key>/library-cache.json`) holds the
canonical metadata of every title this account has seen. Sources are library pages,
Continue, details, status changes, and the download records, which are merged in at
query time.

- **Bounded.** 600 titles. The least recently seen go first, except downloaded titles,
  which are pinned. A downloaded title's metadata also survives in the downloads
  manifest.
- **Stale protection.** Each copy is stamped with the time its request *started*, and
  an older response never replaces a newer copy. So a library page that was in flight
  during a status change can't undo it. The status response is recorded when it
  arrives.
- **Fallback rule.** The Library falls back to saved titles only when the request
  fails with no connection (`APIError.allowsOfflineFallback`). Sign-in, certificate,
  redirect, permission and server errors stay on screen. A later page that fails
  offline keeps the online list and offers a retry. It doesn't switch sources part way
  through.
- **Queries.** Offline queries support type, status (as last seen), and case- and
  accent-insensitive title or author search. Sort is by title, or for Recent by the
  server's last-seen order: only the unfiltered recently-added listing records
  positions, and titles it never listed come after, newest first. Pages are local,
  30 at a time.
- **Copy.** A banner reads "Offline. Showing saved titles". It gives the count saved
  on this device, how many are downloaded and when they were last updated, and says
  the full library on the server may have more and that statuses are as last seen. It
  never claims the whole server library is cached. Empty results say only saved titles
  can be searched.
- **Details.** Details use the newest offline copy: the saved details file or the
  listed title. Status changes still need the server, and there is no offline status
  queue. Progress stays disk-first and compare-and-set aware, unchanged.
- **Sign-out.** Disconnecting closes the cache before the account folder is deleted.
  A write after that never recreates the folder.

## Runtime smoke test

```sh
apps/scripts/ios-runtime-smoke.sh                       # whole test
apps/scripts/ios-runtime-smoke.sh -only-testing:ShelfarrUITests/RuntimeSmokeTests
```

It needs macOS, Xcode 16.4, XcodeGen and `python3`. The script works like this:

1. Regenerates the project (`ShelfarrUITests` target, `ShelfarrRuntimeSmoke` scheme).
2. Picks the newest available iPhone simulator at or below the selected Xcode's
   simulator SDK version. Set `IOS_SIMULATOR_UDID` to override.
3. Starts `apps/ios/RuntimeSmoke/smoke_server.py` on `127.0.0.1:8765`, with control on
   `8766`. Set `SHELFARR_SMOKE_PORT` and `SHELFARR_SMOKE_CONTROL_PORT` to change them.
   The fixture server runs `mock_consumer_server.py` unchanged and adds transfer grants,
   an offline switch that also drops kept-alive connections, and counters.
4. Runs `xcodebuild test` with local ad-hoc signing (`CODE_SIGN_IDENTITY=-`), which
   needs no developer account. The system download daemon rejects an unsigned
   simulator app as having no bundle ID. The ports reach the test runner as
   `TEST_RUNNER_*` variables.
5. Fails unless at least one test ran and every test passed.

The test gets a real device-flow token from the fixture; there are no real credentials.
It launches the Debug app with `-shelfarr-ui-test`, which holds that session in memory
instead of the Keychain. Release builds don't compile that code. From then on, it uses
ordinary UI interactions:

- Home and Library are shown, the second library page loads, and server search
  narrows the list.
- The book's details are shown and the book is downloaded. The fixture's counters must
  show grant requests and none with a bearer, which proves the background-session path
  ran.
- Readium must render the chapter text "…rain had stopped…" in its web view. Two page
  turns must move the position away from 0%.
- The audiobook is downloaded while the app is sent to the Home screen and then brought
  back. The player must say it is playing the download, and the local track's duration
  (0:45) must load.
- With the server offline, the app is relaunched. Home shows downloads. The Library
  shows the saved-titles banner, and offline search finds a title from the second page.
  Offline details say status changes need the server. The EPUB reopens and renders at
  the same place (within 1%).

Audio output isn't needed or checked.

### Artifacts

| Path | Contents |
|---|---|
| `apps/ios/build/runtime-smoke/RuntimeSmoke.xcresult` | result bundle (also matched by `apps/ios/build/**/*.xcresult`) |
| `apps/ios/build/runtime-smoke/attachments/` | exported screenshots `01-home` … `12-reader-offline`, with `manifest.json` |
| `apps/ios/build/runtime-smoke/xcodebuild.log`, `server.log`, `server-stats.json`, `device.log` | build and test output, fixture requests and counters, and the simulator's log for Shelfarr and `nsurlsessiond` |
| `apps/ios/test-results/runtime-smoke-summary.json` | `xcresulttool get test-results summary` |

The CI step runs `apps/scripts/ios-runtime-smoke.sh` after `ios-check.sh`, on
`macos-15` with Xcode 16.4 selected and XcodeGen on `PATH`, as for the existing iOS
job. It needs no secrets, and it should upload the paths above `if: always()`. Allow
about 15 minutes more than `ios-check.sh`.

## Verification status and limits

- **Verified on Linux.** The `ShelfarrCore` tests pass on Linux (Swift 6.4.2): 110
  tests, repeated runs stable. They cover tickets persisted before submission,
  adoption after relaunch without duplicates, lost tasks planned again, orphan and
  old-token cancellation, out-of-order ranges and staged ranges across a relaunch,
  short or misplaced ranges, redirect discard, force-quit, storage failures, grant
  minting, refusal and fallback, the account boundary after sign-out, cancel-before-
  delete, version 1 manifest migration, and every offline-library rule above.
- **Simulator build verified.** macOS CI compiled the app and UI test and reached
  the download flow. Its first runtime run found an unsigned simulator build rejected
  by the system download daemon. The corrected smoke configuration still needs a
  passing run before background transfers and the full offline flow are verified.
- **Grants.** The consumer API implements the grant endpoint. Older servers without
  it keep using foreground transfers; the smoke fixture exercises the background path.
- **Scheduling.** Background transfers are at iOS's discretion. A force-quit stops
  them until the app is opened again. A relaunch after the system ended the app, and
  delays set by the rate limiter, can't be forced in CI. The smoke test covers
  suspension, not a system relaunch.
- **Coverage.** Offline browsing covers only titles this device saw or downloaded.
  The recent order is the last order the server showed.

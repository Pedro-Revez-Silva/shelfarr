# Native consumer apps

Shelfarr's reading and listening clients: a native Android app and a companion
native iOS app, both talking to the consumer API. Neither wraps the web UI.

| Path | Contents |
| --- | --- |
| `apps/android` | Kotlin and Jetpack Compose, Readium, Media3 |
| `apps/ios` | SwiftUI app (`Shelfarr`), Foundation-only `ShelfarrCore` package, XcodeGen project |
| `apps/design` | Brand tokens, design direction and shared fonts |
| `apps/scripts` | Build checks, token check and a development mock API |

The flow on both platforms is: server address, device authorization in the system
browser, library and continue, publication details, EPUB reader or audio player,
resume from the saved place. Books and audiobooks can be downloaded for offline use,
and each has a reading status. Both clients browse downloaded and previously seen
titles offline, with saved coverage and freshness shown. With the person's explicit
approval, a **Find** tab also searches beyond the library and requests books; see
[Finding and requesting](#finding-and-requesting). See the platform details for
[Android](native-offline-android.md) and [iOS](native-offline-ios.md). The Android
app can also [update itself](native-updates-android.md) from a publisher feed.

## Build

### Android

Needs JDK 17 or later (CI uses Temurin 21) and an Android SDK with platform 37.
Gradle arrives through the wrapper, whose distribution is pinned by SHA-256.

```sh
export ANDROID_HOME=/path/to/android-sdk
apps/scripts/android-check.sh
```

That runs the unit and screen-rendering tests, Android lint and the debug build. The
APK lands at `apps/android/app/build/outputs/apk/debug/app-debug.apk` and rendered
screens at `apps/android/app/build/screenshots`. Those renders use test fixtures only;
the app contains no demo content.

CI also runs `:app:connectedDebugAndroidTest` on an accelerated API 35 emulator.
This opens a fixture EPUB in the real Activity/WebView, navigates to chapter two,
saves through HTTP and reopens at that chapter. A second test downloads a fixture
book and a two-track audiobook, stops the fixture server, then reopens the book from
its download in the real reader (`offline-download.png`) and checks that the player
selected and prepared both downloaded tracks. CI's emulator runs without audio
output, so audible playback is not asserted. Screenshots and logcat are uploaded
alongside the APK; a renderer crash fails the check.
The background-transfer test also drives Library → details → Download, notification
Cancel and Downloads navigation, system interruption/resume, and offline Library
search. It exercises the real app on the emulator; process death and denied
notification permission still need device validation. To run it locally,
start an accelerated emulator or connect a test device, then run
`apps/scripts/android-reader-smoke.sh`. The smoke test uses an in-process fixture API and a synthetic
account, so a connected personal library is not needed.

Versions live in `apps/android/gradle/libs.versions.toml`, pinned to the Kotlin, AGP
and compile SDK combination that Readium 3.4.0 builds with. Bump them together.

No release signing is configured.

The version comes from `-PshelfarrVersionCode` (default `2`, 1 to 2100000000) and
`-PshelfarrVersionName` (default `0.1.1`; debug builds append `-debug`). Each build
published for in-app updates needs a larger version code than the last. In-app updates
are described in [Android in-app updates](native-updates-android.md).

### iOS

Needs macOS, Xcode 16.4 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
apps/scripts/ios-check.sh                  # core tests and a simulator build
cd apps/ios && xcodegen generate && open Shelfarr.xcodeproj
```

The Xcode project is generated from `apps/ios/project.yml` and is not committed. Set a
development team in Xcode to run on a device.

`ShelfarrCore` has no Apple-only dependencies, so it also tests on Linux:

```sh
cd apps/ios/ShelfarrCore && swift test --build-system native
```

### Design tokens

`python3 apps/scripts/check-design-tokens.py` fails if a platform drifts from
`apps/design/tokens.json` or a text pairing falls below WCAG AA.

## Try it without a server

`apps/scripts/mock_consumer_server.py` is a development stand-in for the API with
in-memory state and no real security. Keep it on your own machine.

```sh
python3 apps/scripts/mock_consumer_server.py --base /shelfarr --auto-approve
```

In a debug build, enter `http://10.0.2.2:8099/shelfarr` on the Android emulator or
`http://localhost:8099/shelfarr` on the iOS simulator, and turn on **Allow local HTTP**.
`--conflict-after N` answers the Nth progress write with a conflict, `--slow-down`
exercises polling backoff, and `--extra-books N` adds N small mock books so the
library pages and Continue can find a book beyond the first page. The mock also
serves `reading_status`, `/continue`, status changes and the `status` and `sort`
library parameters.

The actual Android reader passes rendering, chapter navigation, HTTP progress and
reopening tests on an accelerated API 35 emulator. Earlier software-only API 33
and API 35 runs crashed the WebView renderer. Use an accelerated emulator for
validation; physical-device compatibility is still unverified.

## Finding and requesting

Find is a separate tab, so Library stays "what I have" and Find is "ask for
something new". It works in four steps, each a full screen with large targets and
text that wraps at every font size:

1. **Allow requesting.** A read-only connection explains what requesting means and
   that the library, downloads and saved places stay as they are, then opens the
   browser approval described in [consumer-api.md](consumer-api.md#requesting-from-native-apps).
   The code and countdown stay on screen; the attempt survives the app being killed.
   The new credential replaces the old one in place for the same account; an
   approval by another account is refused and dropped. Older servers get an
   explanation and a link to the website instead.
2. **Find.** Search runs when the person submits, not per keystroke, to spare the
   server's metadata providers. Each result says which formats can be requested,
   are already in the library or are already requested.
3. **Choose and request.** A title page shows ebook and audiobook as large choices,
   the first requestable one preselected, and one *Request ebook/audiobook* button
   that ignores repeated taps while it is in flight. Formats already in the library
   open their details; formats already requested open their tracker.
4. **Follow and open.** The request page polls while visible and shows plain stages
   (requested, finding a copy, downloading with percentage, adding to the library,
   ready). When ready, *Read now* or *Listen now* opens the reader or player
   directly. Unfinished requests can be cancelled after a confirmation.

Offline, Find says that searching and requesting need a connection and keeps the
last request list. A 403 refreshes the connection's scopes and returns to step 1.
On Android, adding requesting keeps playback and downloads running. On iOS the
account's progress and download services restart with the new credential (files
and places kept), which stops current playback once.

The mock server grants requesting when asked: `--grant-requesting` gives it to every
new token, `--old-server` behaves like a server without it and
`--request-outcome not_found|failed` ends requests there.

## Security model

- **Credential boundary.** The configured address is an origin plus an optional
  subpath. A bearer token is attached only to URLs inside it, compared on scheme, host,
  port and path after dot segments are resolved. `/shelfarr-evil` is not inside `/shelfarr`.
- **Redirects.** Interactive API and media requests follow a redirect only if both
  ends are inside the boundary. iOS system background sessions follow redirects
  automatically, so they carry only asset-scoped grants; results outside the server
  boundary are discarded.
- **Media credentials.** Interactive API calls, EPUB copies, covers and audio use
  the scoped credential logic. iOS system background tasks instead use short-lived,
  asset-scoped grant URLs and never receive the account bearer. Android uses the same scoped interceptor for shared and account-bound clients. iOS streams audio through an
  `AVAssetResourceLoader` that fetches byte ranges with the API client, because
  AVPlayer has no supported way to set a bearer header. Account bearer tokens never
  appear in URLs.
- **Storage.** Android encrypts the session with a non-exportable AES-256-GCM Android
  Keystore key, in `noBackupFilesDir`, with backups disabled. iOS uses the Keychain with
  `AfterFirstUnlockThisDeviceOnly`. Unfinished device grants are stored the same way, so
  the app can be killed while the browser is open. Plain preferences hold display
  settings only.
- **Local HTTP.** Release builds are HTTPS only. Debug builds show an **Allow local HTTP**
  switch that accepts loopback, private and `.local` hosts. Android permits cleartext
  per named host through a generated network security config; add one for a physical
  device with `-PshelfarrDevHttpHosts=192.168.1.10`. iOS debug builds use
  `NSAllowsLocalNetworking`.
- **Sign-out.** Disconnect flushes progress, calls revoke, stops every download, then
  removes the token, stored progress, downloads, EPUB copies and cached covers, whether
  or not the server was reachable. A 401 clears the token but keeps the address, any
  unsent progress and the downloads, for signing in to the same account again;
  downloads stopped by it resume after that.
- **Separation.** Local files live under a hash of the server and user id, so accounts
  never share progress, downloads or book copies. Path case is preserved. Progress
  retries and downloads use the account's captured credential, and session
  transitions stop its sync and transfers before another account's start.

## Progress

Each position and its activity time are written to disk first. Audio saves locally
every four seconds while playing; page turns, seeks, pause, stop, track changes and
backgrounding save promptly. Network sends are debounced by 5 seconds and never
wait longer than 20. They also flush on pause, stop, backgrounding and foregrounding.

A write keeps its `client_mutation_id` until the server gives a definite answer, and
newer positions wait behind it. Retries back off from 5 seconds to 5 minutes and stop
after 8 attempts until the next trigger, so nothing loops in the background. A 409
naming our own mutation id counts as success, because only the response was lost.
On other conflicts, the latest actual activity wins when both times and positions
are usable. Unknown, equal or implausible times still ask the reader to choose.
A 422 retains the unsynced place and asks on the next open; it does not erase it.
Upload and acknowledgement times never become reading or listening times.

On opening, `ResumeDecision` compares the server position with this device's:

- Unsent local reading continues if the server hasn't moved past the version it was
  based on. Otherwise usable activity times decide; uncertain cases ask the reader.
- A position whose `asset_id` is not in the publication is treated as an earlier
  edition: the reader is told and starts at the beginning.

Ebook positions are Readium locators, passed through unchanged. Audio positions are
seconds within the named asset.

Resuming a saved audiobook or playing after a pause rewinds five seconds within the
current track, once. Deliberate seeks and track choices do not rewind. Reopening a
book or replaying those seconds does not invent new progress. See the detailed
activity-time, durability and rewind rules for [Android](native-progress-android.md)
and [iOS/iPad](native-progress-ios.md).

## Implementation notes for the API

- A server-relative `content_url` or `cover_url` is resolved against the configured
  address. A path that already starts with the configured subpath is used as is;
  otherwise the subpath is added. Both `/api/...` and `/shelfarr/api/...` work.
- Covers from another origin are fetched without credentials. Redirects from them are
  not followed, and any failure shows the generated cover.
- Last known publication metadata is stored per account so an existing EPUB can
  reopen when the network is unavailable. Authentication and TLS errors are surfaced.
- EPUB copies are revalidated with `If-None-Match` on every open and resumed with
  `Range` and `If-Range`, so `content_url` needs a stable strong `ETag`. A 304 and a
  200 repeating the stored `ETag` both keep the copy. Android stops reading such a
  response at once; iOS discards the body, so a 304 saves iOS the transfer.
- iOS audio relies on single byte ranges and `Content-Range` with a known total length.
- Home builds "Continue" from `GET /continue?limit=10`, across the whole library, and
  shows only items whose status is `in_progress`. A server without that endpoint
  (404) falls back to the first page of `/library`.
- `reading_status` may be absent on older servers; clients then derive `in_progress`
  from a usable saved place, else `unread`. Unknown values are treated as absent.
- Status changes use `PUT /library/:id/reading_status` and need a connection; nothing
  changes on screen until the server accepts it. The saved place is kept. Opening an
  unread publication with an explicit Read or Listen sets `in_progress` best effort,
  without waiting; nothing else sends a status, so progress never undoes "finished".
- Library `status` and `sort` (`recent` default, or `title`) are sent with `type` and
  `q`. Any change starts again from the first page and ignores pages still loading
  for the old query, since a cursor belongs to the query that produced it.

## Downloads

A download is the user's choice and lives in app storage (Android `filesDir`, iOS
Application Support, excluded from backup), separate from the EPUB working copy in
the cache directory, which the OS may still clear.

- It pins one edition: the exact asset ids of the EPUB, or of every audio file in
  `position` order. Before transferring, it fetches the publication again and re-pins
  if the ids changed. Online, the reader and player use a download only while its ids
  still match the server's; otherwise they use the server's current edition and the
  page offers to update the download. Offline, they use the download.
- Android downloads files one at a time; iOS uses bounded range tickets. Both allow
  at most two publications at once. A transfer
  resumes with `Range` and `If-Range` only against a strong `ETag` recorded before
  the body; a full 200 with a different tag, a 412 or a 416 is a changed file, and the
  partial bytes are discarded rather than stitched together.
- It is ready only when every file is complete, its size matches `size_bytes` and an
  EPUB starts with `PK`. Missing or short files found at launch mark it failed, never
  ready. Audio plays from local files only when every track is on the device.
- States are queued, downloading, ready, failed and cancelled, with sizes. Failures
  keep their kind: no connection, untrusted certificate, signed out, not allowed, not
  found, server error, redirect, changed on the server, unexpected file, not enough
  space, files missing. Android's transfer hosts retry connection and server failures
  with bounded backoff. iOS retries failed transfers when the app returns to the
  foreground. Other failures wait for the user; an interrupted iOS transfer is paused.
- Cancel stops the transfer and deletes its bytes. Remove deletes the files and the
  entry; the saved place and status stay.
- The queue is stored with the account. Android runs it through user-initiated jobs
  on Android 14+, and foreground services/network jobs on older versions. Android
  controls interruptions and retries; an explicit user stop requires Resume. See the
  [platform limits](native-offline-android.md). iOS hands persisted range tasks to a
  background URLSession and reconciles them after relaunch. It requires the server's
  asset-scoped transfer-grant endpoint; older servers retain foreground transfers.
  See [iOS behavior and the grant contract](native-offline-ios.md).

## Current limits

- Offline: downloaded books and audiobooks open, and Home shows them. Other books that
  were opened before can reopen from their cached copy, which the OS may clear, and
  other audio needs a connection. Android's Library searches and filters downloaded
  and previously loaded titles, with coverage/freshness shown; iOS offers the same
  saved-title browsing. Status edits on both platforms need a connection.
- Background execution is controlled by the OS and cannot bypass force stop,
  battery or network limits. iOS background transfers need transfer grants from the
  server and stop after an explicit force-quit until the app is reopened.
- EPUB only for reading. Other ebook formats show "can't be opened in the app yet", and
  DRM-protected files can't be opened.
- Chapters come from the audio file's own metadata (ID3 `CHAP`, MP4 chapter tracks) as
  each file loads; otherwise navigation is by file.
- Readium does not handle a WebView renderer crash, so on Android such a crash ends the
  app process. The last saved position survives.
- No release signing, store metadata or crash reporting yet.

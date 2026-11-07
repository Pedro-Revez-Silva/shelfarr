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
resume from the saved place.

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
saves through HTTP and reopens at that chapter. Its screenshots and logcat are
uploaded alongside the APK; a renderer crash fails the check. To run it locally,
start an accelerated emulator or connect a test device, then run
`apps/scripts/android-reader-smoke.sh`. The smoke test uses an in-process fixture API and a synthetic
account, so a connected personal library is not needed.

Versions live in `apps/android/gradle/libs.versions.toml`, pinned to the Kotlin, AGP
and compile SDK combination that Readium 3.4.0 builds with. Bump them together.

No release signing is configured.

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
`--conflict-after N` answers the Nth progress write with a conflict, and `--slow-down`
exercises polling backoff.

The actual Android reader passes rendering, chapter navigation, HTTP progress and
reopening tests on an accelerated API 35 emulator. Earlier software-only API 33
and API 35 runs crashed the WebView renderer. Use an accelerated emulator for
validation; physical-device compatibility is still unverified.

## Security model

- **Credential boundary.** The configured address is an origin plus an optional
  subpath. A bearer token is attached only to URLs inside it, compared on scheme, host,
  port and path after dot segments are resolved. `/shelfarr-evil` is not inside `/shelfarr`.
- **Redirects.** Automatic redirect handling is off. A redirect is followed only if both
  ends are inside the boundary. Anything else fails, and nothing is sent to the new host.
- **One HTTP path.** API calls, EPUB downloads, covers and audio all use the same
  credential logic. Android uses the same scoped interceptor for shared and account-bound clients. iOS streams audio through an
  `AVAssetResourceLoader` that fetches byte ranges with the API client, because
  AVPlayer has no supported way to set a bearer header. Tokens never appear in URLs.
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
- **Sign-out.** Disconnect flushes progress, calls revoke, then removes the token, stored
  progress, EPUB copies and cached covers, whether or not the server was reachable. A
  401 clears the token but keeps the address, and any unsent progress, for signing in again.
- **Separation.** Local files live under a hash of the server and user id, so accounts
  never share progress or book copies. Path case is preserved. Progress retries use
  the account's captured credential, and session transitions stop its sync work.

## Progress

Each position is written to disk first. Sends are debounced by 5 seconds and never
wait longer than 20. They also flush on pause, stop, backgrounding and foregrounding.

A write keeps its `client_mutation_id` until the server gives a definite answer, and
newer positions wait behind it. Retries back off from 5 seconds to 5 minutes and stop
after 8 attempts until the next trigger, so nothing loops in the background. A 409
naming our own mutation id counts as success, because only the response was lost. Any
other 409 stops sending and asks the reader to choose. A 422 drops that write.

On opening, `ResumeDecision` compares the server position with this device's:

- Unsent local reading continues if the server hasn't moved past the version it was
  based on. If it has, and the places differ, the reader chooses.
- A position whose `asset_id` is not in the publication is treated as an earlier
  edition: the reader is told and starts at the beginning.

Ebook positions are Readium locators, passed through unchanged. Audio positions are
seconds within the named asset.

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
- Home builds "Continue" from the first page of `/library`. A publication in progress
  that falls beyond page one won't appear there until a recent-progress sort or
  endpoint exists.

## Current limits

- Offline: audio always streams. A book that was opened before can reopen offline from
  its cached copy, which the OS may clear, and the app says so. There are no downloads.
  The library itself needs a connection.
- EPUB only for reading. Other ebook formats show "can't be opened in the app yet", and
  DRM-protected files can't be opened.
- Chapters come from the audio file's own metadata (ID3 `CHAP`, MP4 chapter tracks) as
  each file loads; otherwise navigation is by file.
- Readium does not handle a WebView renderer crash, so on Android such a crash ends the
  app process. The last saved position survives.
- No release signing, store metadata or crash reporting yet.

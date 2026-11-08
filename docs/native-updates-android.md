# Android in-app updates

A directly distributed Android build can find, download and install its own newer
versions from a publisher feed, using Android's normal installer. It is off unless a
feed is given at build time, and has nothing to do with the Shelfarr server the app
signs in to.

## Building with a feed

| Property | Default | Meaning |
| --- | --- | --- |
| `shelfarrUpdateFeedUrl` | empty (off) | Feed for **debug** builds, channel `development` |
| `shelfarrReleaseUpdateFeedUrl` | empty (off) | Feed for **release** builds, channel `release` |
| `shelfarrVersionCode` | `2` | Version code, 1 to 2100000000. Must grow with every published build |
| `shelfarrVersionName` | `0.1.1` | Version name; debug builds append `-debug` |

```sh
cd apps/android
./gradlew :app:assembleDebug \
  -PshelfarrUpdateFeedUrl=https://example.org/downloads/android-development.json \
  -PshelfarrVersionCode=3 -PshelfarrVersionName=0.1.2
```

The feed URL must be `https://`, end in `.json`, sit inside a directory and carry no
credentials, query or fragment; the build fails otherwise. Only a build with a feed
declares `REQUEST_INSTALL_PACKAGES` and the installer status receiver. Debug and
release read separate properties, so a development feed never reaches a release build.

Every build that should update an existing install must be signed with the same key
as that install, and the package (`org.shelfarr.app.debug` for debug builds) must not
change. Android keeps the app's data across such an update.

## Feed format (schema 1)

```json
{
  "schema_version": 1,
  "channel": "development",
  "package_name": "org.shelfarr.app.debug",
  "version_code": 3,
  "version_name": "0.1.2-debug",
  "apk_url": "https://example.org/downloads/shelfarr-android-development-3.apk",
  "size_bytes": 23484238,
  "sha256": "64 lowercase hex characters",
  "release_notes": "Optional plain text, at most 4000 characters.",
  "min_sdk": 26
}
```

- `schema_version` must be 1; `channel` must match the build (`development` or
  `release`); `package_name` must be the installed app's.
- `version_code` is an unquoted integer from 1 to 2100000000; only a version code
  larger than the installed one is offered. `version_name` is 1–64 letters, digits,
  `.`, `_`, `+` or `-`, and must equal the APK's.
- `apk_url` must be `https://` on the feed's exact host and port, inside the feed's
  directory (`/downloads/` above), end in `.apk`, and have no credentials, query,
  fragment, empty, dot or encoded dot/slash segments.
- `size_bytes` is 1 to 268435456 and `sha256` the whole APK's lowercase SHA-256.
- `release_notes` and `min_sdk` are optional; unknown fields are ignored. The feed
  itself may be at most 64 KiB.

`apps/scripts/android-update-manifest.py` writes this file from a built APK after
checking it with `apksigner` and `aapt2`, and can insist on the signing certificate
and on a larger version code than the one already published. It uploads nothing.
Publish the APK first, then the feed.

## Behaviour

- **Checks.** On launch and foreground at most every 6 hours after a successful
  check, retrying a failed one after 30 minutes; and on demand from Settings. An
  automatic check that fails says nothing.
- **Offer.** A newer release shows in Settings with its notes and size, and the
  Settings tab gets a small badge. Nothing downloads or installs on its own, and
  nothing blocks the library, reader or player.
- **Download.** Only when asked, into the app's private no-backup storage, over a
  separate HTTP client with no interceptors, cookies or cache that is never given the
  account's token. Every redirect must stay on the feed's origin and directory over
  HTTPS; anything else is refused before a request is sent. The file must not exceed
  the announced size and must match its length and SHA-256. It must then read, through
  PackageManager, as the installed package at exactly the announced, strictly newer
  version, signed by exactly the installed app's current certificates. A download can
  be cancelled, and is never started twice.
- **Install.** Only when asked. With audio playing, the app asks to pause first and
  never pauses on its own. Listening and reading places are saved, the file's hash and
  identity are checked again, and it goes to `PackageInstaller` with user action
  required, so Android always shows its own confirmation. Android verifies the APK
  signature itself; the app's checks are in addition to that. The first time, Android
  asks the person to allow installs from Shelfarr; declining leaves the update ready.
- **Outcomes.** Cancelled, blocked or out-of-space installs keep the verified file for
  another try. A file Android calls invalid, conflicting or incompatible is deleted.
  After a successful update the next launch says so and removes the file. A session
  Android dropped silently is noticed when the app returns.
- **Relaunch.** The verified file, the release and any open installer session survive
  the process; a reopened app shows Ready or "Installing" (with Cancel) accordingly,
  and re-checks everything before installing. Partial downloads are discarded.

## Limits

- Signing-key rotation is not supported: an update must be signed with exactly the
  installed app's current certificate set.
- Partial downloads do not resume; a cancelled or interrupted download starts again.
- Downloads run while the app is alive; they are not handed to a background job.
- After installing, Android closes the app; reopening it is up to the person (Android's
  installer usually offers "Open").
- The flow has unit, rendering and lint coverage; installation on a real device or
  emulator is not exercised by CI.

# Android builds served by your Shelfarr server

A Shelfarr server can hand out the Shelfarr Android app itself: a public install
page, an update feed per channel and the APK bytes, all from a verified copy the
server keeps under `storage/app_updates`. Phones connected to the server then
check it for updates instead of a fixed publisher address, and a first install
can be connected to the server without typing its address.

The server never builds, signs or changes an APK. It offers exactly the bytes the
publisher released, after checking their size and SHA-256.

## Configuration

Set these in the server's environment (for Docker, the container environment).
They are not user settings and are never shown to non-administrators.

| Variable | Default | Meaning |
| --- | --- | --- |
| `ANDROID_UPDATE_CHANNELS` | `release` | Comma list of `release` and `development`. Empty or `none` turns the feature off. Any other name is a configuration error and turns it off too. |
| `ANDROID_UPDATE_CATALOG_URL` | `https://github.com/Pedro-Revez-Silva/shelfarr/releases/download/android-catalog-v1/android-catalog.json` | Publisher catalog. Must be `https://`, end in `.json`, and carry no credentials, query, fragment, dot or encoded separator segments. |

- **Release** is the `org.shelfarr.app` app. **Development** is the separate
  `org.shelfarr.app.debug` app (its launcher name is also "Shelfarr"); it installs
  alongside the release app with its own sign-in and downloads, and is offered only when listed.
- **The official catalog** may only point at release assets of the
  `Pedro-Revez-Silva/shelfarr` GitHub repository, and downloads may only be
  redirected to GitHub's release-asset hosts (`objects.githubusercontent.com`,
  `release-assets.githubusercontent.com`). It never resolves to a private address.
- **A custom catalog** keeps every request, including redirects, on its exact
  HTTPS origin (scheme, host and port), and may be on the operator's own network.
  Cloud metadata and other always-blocked ranges stay blocked.
- Certificates are verified normally. No account data, cookie or credential is
  ever sent upstream, and logs name only hosts and short error categories, never
  URLs (signed redirect URLs carry tokens).

## What phones and browsers see

Paths are relative to the server's base address, including any deployment subpath
(`RAILS_RELATIVE_URL_ROOT`). None of them need an account, read a session or a
bearer, or fetch anything upstream; HEAD never writes.

| Method and path | Result |
| --- | --- |
| `GET /api/consumer/v1/server.json` | Server discovery, below |
| `GET /apps/android` | Install page for the release app |
| `GET /apps/android?channel=development` | Install page for the development app, labelled as such |
| `GET /apps/android/<channel>.json` | Feed for the cached build; 404 `channel_disabled`, 503 `not_ready` (with `Retry-After`) |
| `GET /apps/android/<channel>/<version_code>-<sha256>.apk` | The cached bytes |

### Discovery

```json
{
  "schema_version": 1,
  "server_version": "0.1.0",
  "consumer_api_versions": [1],
  "android": {
    "release": {
      "feed_url": "/shelfarr/apps/android/release.json",
      "download_page_url": "/shelfarr/apps/android"
    },
    "development": {
      "feed_url": "/shelfarr/apps/android/development.json",
      "download_page_url": "/shelfarr/apps/android?channel=development"
    }
  }
}
```

- `consumer_api_versions` lists the consumer API generations the server
  implements. They are independent of the server's and the apps' release labels.
- `android` lists only enabled channels, whether or not a build is cached yet. It
  is `{}` when Android builds are off or misconfigured. URLs are paths on this
  server, inside its subpath; clients must accept a relative URL or an absolute one
  inside the same origin and subpath, and nothing else.

### Feed

The feed is the schema 1 document the app already understands
([native-updates-android.md](native-updates-android.md)), plus the build's
`consumer_api_versions`:

```json
{
  "schema_version": 1,
  "channel": "release",
  "package_name": "org.shelfarr.app",
  "version_code": 12,
  "version_name": "2026.11.2",
  "apk_url": "https://books.example.org/shelfarr/apps/android/release/12-<sha256>.apk",
  "size_bytes": 23484238,
  "sha256": "<64 lowercase hex characters>",
  "min_sdk": 26,
  "release_notes": "Optional plain text",
  "consumer_api_versions": [1]
}
```

`apk_url` is absolute, on the origin the feed was requested from, inside the
feed's directory. The feed is `Cache-Control: no-store`; it is only built from the
promoted cache entry and never redirects.

### APK bytes

Served from an already-open, verified regular file (symlinks are not followed);
only the channel's current build and the one it replaced are available, chosen by
the promoted entry rather than by the requested name. Responses are
`application/vnd.android.package-archive` attachments with
`Cache-Control: public, max-age=31536000, immutable` and the SHA-256 as a strong
ETag. GET supports one byte range (`bytes=a-b`, `a-`, `-n`) and `If-Range`;
`If-None-Match` returns 304; HEAD reports the complete file without a body. Partial
downloads by the app still restart from the beginning (see its limits).

## The install page and connecting a first install

Signed in or not, `/apps/android` shows the version, size and notes, then:

1. **Download and install.** Android asks to keep the file and, the first time, to
   allow installs from the browser ("Install unknown apps").
2. **Come back and open Shelfarr.** After installing, tap **Done**, return to the
   page and tap **Open Shelfarr**. That opens
   `shelfarr://connect?server=<percent-encoded base address>`, for example
   `shelfarr://connect?server=https%3A%2F%2Fbooks.example.org%2Fshelfarr`. The app
   fills in that address and starts the usual browser sign-in at
   `/consumer/connect`; nothing about signing in changes.

A generic APK cannot learn which server it was downloaded from, so the second
step is needed once. The link carries only the public HTTPS base address,
including its subpath, never a credential, query or fragment. It is offered only
when the page itself was reached over HTTPS (behind a proxy, forward
`X-Forwarded-Proto`); otherwise the page says so. The app is expected to accept
exactly one `server` parameter that is a clean HTTPS address, and never to replace
an existing connection, its settings or downloads because of such a link.

**My Profile → Get the Android app** and the reader library link to the page
whenever a channel is offered. Administrators also see why a build is missing.

## Keeping the cache current

- A background job, `AndroidUpdateRefreshJob`, runs every 6 hours
  (`config/recurring.yml`). A server that boots with an enabled channel but nothing
  cached queues one refresh straight away. Scheduled runs within 5 minutes of the
  previous check are skipped.
- `bin/rails android_updates:refresh` refreshes now and prints the outcome
  (non-zero exit on any problem). `bin/rails android_updates:status` shows what is
  served and the last problem. `bin/rails "android_updates:forget[development]"`
  drops a channel's cache, the only way to accept a lower version code.
- A refresh reads the catalog (at most 1 MiB, 60 s), picks for each enabled
  channel the highest `version_code` whose package matches the channel exactly and
  whose `consumer_api_versions` overlaps the server's, and downloads it (at most
  the announced size and 256 MiB, 30 minutes) into `staging/`. Only a file of
  exactly the announced length and SHA-256 is made read-only and renamed into
  `apks/`, after which the channel document is replaced atomically. Readers in any
  process see the old build or the new one, never a partial one.
- One process refreshes at a time (an exclusive lock on `storage/app_updates/lock`);
  another refresh meanwhile reports that it is busy.
- **Nothing replaces a good build except a newer verified one.** An unreachable or
  malformed catalog, a failed or mismatched download, or a full disk keeps serving
  the promoted build, across restarts. A catalog that lists only lower version
  codes is ignored, and a version code reused with different bytes is a conflict.
  While the catalog still offers the cached build, each refresh re-hashes it and
  downloads it again if it was damaged.
- Keep `storage/` on a persistent volume, as for the database. Expect up to two
  APKs per channel on disk, plus one download in progress.

## Publisher catalog (schema 1)

```json
{
  "schema_version": 1,
  "releases": [
    {
      "channel": "release",
      "package_name": "org.shelfarr.app",
      "version_code": 12,
      "version_name": "2026.11.2",
      "apk_url": "https://github.com/Pedro-Revez-Silva/shelfarr/releases/download/android-v2026.11.2/shelfarr-release.apk",
      "size_bytes": 23484238,
      "sha256": "<64 lowercase hex characters>",
      "min_sdk": 26,
      "release_notes": "Optional plain text, at most 4000 characters.",
      "consumer_api_versions": [1]
    }
  ]
}
```

- Fields are the app feed's, checked the same way, plus a mandatory
  `consumer_api_versions` array (1–16 distinct integers).
- `version_name` is a calendar version, `YEAR.MONTH.NUMBER` with an optional
  suffix such as `-debug` (for example `2026.11.2` or `2026.11.3-debug`).
- `channel` and `package_name` must pair exactly: `release` with
  `org.shelfarr.app`, `development` with `org.shelfarr.app.debug`. Version codes
  must increase within each package.
- At most 500 entries. A document that is not a schema 1 catalog is refused whole;
  an entry with an unknown channel or an invalid field is skipped and counted in
  the log, so a catalog can carry entries for newer servers.

## What updating preserves

The server only relays the publisher's signed APK. Android installs it as an
update only when the package name and signing certificate match the installed app,
and keeps all of the app's data: its connection and account, server address,
downloads, reading and listening positions and preferences. The app additionally
checks the downloaded file's identity and signer itself, and installs only when
asked. Never uninstall the app to get past an install error: uninstalling deletes
its downloads and progress. Switching channels means installing the other app, not
replacing one with the other.

## Limits

- The server serves only what the publisher released; it cannot re-sign, patch or
  roll back a build for a phone.
- Downloads from the publisher do not resume; an interrupted one starts again on
  the next refresh.
- The install page relies on the browser and Android's installer. A phone cannot
  be connected automatically on first install without the **Open Shelfarr** step.
- The modern-browser requirement of the web app also applies to the install page.

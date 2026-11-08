# Publishing Android builds

Shelfarr servers offer the Android app from their own cache
([android-server-updates.md](android-server-updates.md)). They fill that cache from
a **publisher catalog**, by default

```
https://github.com/Pedro-Revez-Silva/shelfarr/releases/download/android-catalog-v1/android-catalog.json
```

This page is for whoever publishes Android builds into that catalog. The
**Android release** workflow (`.github/workflows/android-release.yml`) does it; it
is started by hand and runs separately from the server's weekly Docker release.

## Versions and API generations

Three independent numbers describe a build:

| | Example | Rule |
| --- | --- | --- |
| Version name | `2026.11.8.1` | A calendar label chosen at publication: `YEAR.MONTH.NUMBER`, optionally `.NUMBER` again. Development builds show it with `-debug`. It is only a label; the server's own version (`v2026.11.08.1` Docker releases) is unrelated. |
| Version code | `12` | What Android compares. Must be larger than **every** build of that package ever listed in the catalog, whatever its API generation. Release (`org.shelfarr.app`) and development (`org.shelfarr.app.debug`) count separately. |
| Consumer API generations | `[1]` | Which consumer API generations the build speaks. A server picks, per channel, the **highest version code** sharing a generation with it. Servers speak generation 1 today. |

When a future server speaks generation 2 and the app moves to `[2]`, servers that
only speak 1 keep finding the newest `[1]` build, because the catalog keeps the
newest two builds of every exact generation set. A later fix for those servers must
still use a higher version code than the newest `[2]` build, and servers speaking
both generations will then pick it, so prefer builds that list every generation
they can speak (`[1, 2]`).

## The catalog

```json
{
  "schema_version": 1,
  "releases": [
    {
      "channel": "release",
      "package_name": "org.shelfarr.app",
      "version_code": 12,
      "version_name": "2026.11.8.1",
      "apk_url": "https://github.com/Pedro-Revez-Silva/shelfarr/releases/download/android-release-v2026.11.8.1/shelfarr-android-release-2026.11.8.1-12.apk",
      "size_bytes": 23484238,
      "sha256": "<64 lowercase hex characters>",
      "min_sdk": 26,
      "release_notes": "Optional plain text",
      "consumer_api_versions": [1]
    }
  ]
}
```

- The fields are the app's update feed fields; `consumer_api_versions` is required.
- Channel and package always pair as `release` / `org.shelfarr.app` and
  `development` / `org.shelfarr.app.debug`.
- `apk_url` is an asset of an **APK release** of the same repository, never of the
  `android-catalog-v1` release, which is rewritten on every publication.
- Within the retained catalog, each version code, version name, APK URL and
  SHA-256 appears once. A listed version never changes: publishing the same
  version again is accepted only with identical content, and then changes nothing.
  Pruning removes labels from this local check; their GitHub releases remain.
  The hosted publisher refuses a second APK in an existing release, so a pruned
  calendar label cannot be reused there, even from the same source commit.
- At most 100 releases and 1 MiB, below the server's own limits.

`apps/scripts/android-update-catalog.py` enforces all of this and refuses to
build on a published catalog it cannot fully validate.

The app's **direct feed** (a phone reading a fixed publisher directory, for servers
without discovery) is unchanged: `apps/scripts/android-update-manifest.py` without
`--catalog-entry` still requires the APK on the feed's origin, inside its directory.

## One-time setup

Nothing below has been configured yet; no keys or secrets are in the repository.

### Signing keys

Every published build of a package must be signed by the same certificate, or
phones refuse the update. Use one long-lived key per channel:

- **release**: a new key, kept offline and backed up. Losing it means release
  users must uninstall to move to a differently signed build.
- **development**: the key that signed the development builds already installed
  (`org.shelfarr.app.debug`), so those phones keep updating. Check a published
  APK's certificate with `apksigner verify --print-certs <apk>`. If that key was a
  CI runner's throwaway debug key, it cannot be recovered and those installs need
  one reinstall; choose a new stable key.

To create a key (keytool prompts for the passwords, which stay out of your shell
history):

```sh
keytool -genkeypair -v -keystore shelfarr-release.keystore -storetype PKCS12 \
  -alias shelfarr -keyalg RSA -keysize 4096 -validity 10000 \
  -dname "CN=Shelfarr"
keytool -list -v -keystore shelfarr-release.keystore -alias shelfarr
```

The certificate's `SHA256:` fingerprint, without colons and in lowercase, is the
signer digest below.

### GitHub environments

Create two environments under **Settings → Environments**:

| Environment | Protection |
| --- | --- |
| `android-release` | Deployment branches: the default branch only. Required reviewers recommended. |
| `android-development` | Optional reviewers; any branch may publish a development build. |

Give each environment these entries (same names in both, different values):

| Kind | Name | Value |
| --- | --- | --- |
| Secret | `ANDROID_KEYSTORE_BASE64` | The keystore file, base64 encoded on one line |
| Secret | `ANDROID_KEYSTORE_PASSWORD` | Keystore password |
| Secret | `ANDROID_KEY_PASSWORD` | Key password; leave unset when it equals the keystore password |
| Variable | `ANDROID_KEY_ALIAS` | Key alias, such as `shelfarr` |
| Variable | `ANDROID_SIGNER_SHA256` | The certificate's SHA-256, 64 hex characters |

With the GitHub CLI, from the directory holding the keystore (values are read from
stdin or prompted, never put on the command line):

```sh
base64 -w0 shelfarr-release.keystore | gh secret set ANDROID_KEYSTORE_BASE64 --env android-release
gh secret set ANDROID_KEYSTORE_PASSWORD --env android-release
gh variable set ANDROID_KEY_ALIAS --env android-release --body shelfarr
gh variable set ANDROID_SIGNER_SHA256 --env android-release --body <64 hex>
```

Repeat with `android-development` and the development key. Because each
environment holds only its own channel's key, a development run never has the
release key.

## Publishing a build

**Actions → Android release → Run workflow**, on the branch to build (the default
branch for `release`):

| Input | Meaning |
| --- | --- |
| `channel` | `release` or `development` |
| `version_name` | Calendar label, such as `2026.11.8.1` |
| `version_code` | The next version code for that package |
| `consumer_api_versions` | Generations the build speaks, comma separated (default `1`) |
| `release_notes` | Optional, plain text, at most 4000 characters |
| `fallback_feed_url` | Optional built-in direct feed, only to keep phones from before server discovery updating from a fixed directory. Usually empty: new builds ask their server (`shelfarrServerUpdates` stays on). |
| `create_catalog` | Only for the very first publication, when no catalog exists |

What happens, in order:

1. **Checks the request**: version name, code and generations; `release` only from
   the default branch; the environment's signing configuration is present.
2. **Reads the published catalog** with the workflow's token. A catalog that is
   absent (no `android-catalog-v1` release, or no catalog asset) stops the run unless
   `create_catalog` is set. Any other failure to read it (network, permission, rate
   limit, malformed content) stops the run. If exactly this version is already
   listed, the run ends successfully without building.
3. **Tests and builds** at the dispatched commit: the publishing scripts' tests,
   then `apps/scripts/android-check.sh` (unit tests, lint, debug build), then the
   channel's APK with `shelfarrVersionCode` and `shelfarrVersionName`. Release builds
   come out of Gradle unsigned; development builds come out with a throwaway debug
   key. The emulator and PackageManager checks remain in the per-change Native
   consumer apps workflow.
4. **Signs** with the environment's key: the keystore is written to a private
   directory under `RUNNER_TEMP` (mode 700, removed when the step ends), passwords
   reach `apksigner` through the environment (`--ks-pass env:…`), the APK is aligned
   and signed. Development builds are re-signed this way, replacing the debug key.
5. **Checks the signed APK**: with `apksigner` (exactly the configured certificate,
   an APK Signature Scheme v2/v3 signature) and `aapt2` (package, version code and
   name exactly as requested, minimum SDK present, release builds not debuggable,
   not test-only), then writes its catalog entry with size and SHA-256 and checks
   the catalog would accept it.
6. **Publishes the APK** in its own release, `android-<channel>-v<version_name>`,
   tagged at exactly the tested commit and never marked as the repository's latest
   release (development releases are pre-releases). An existing release must be at
   that commit; an existing APK asset must be byte-identical, and is never
   replaced. The uploaded asset is downloaded back, through the API and then
   anonymously the way servers fetch it, and checked against the entry.
7. **Promotes the catalog**, last: it is read again and the new catalog built from
   it; uploaded as `android-catalog.next.json` and checked; the current catalog is
   renamed `android-catalog.previous.json`; the new one is renamed into place, and
   read back anonymously. The previous catalog stays available as a backup.

Only one Android publication runs at a time (the `android-publication` group);
a running one is never cancelled. GitHub keeps only one more run waiting: starting
a third replaces the waiting one, so start publications one at a time.

Servers notice the new catalog on their next refresh (every 6 hours, or
`bin/rails android_updates:refresh` on the server).

## When a run fails

Nothing is listed in the catalog until its APK has been uploaded and verified, so a
failure never points servers at a missing or wrong file.

| Failed at | State | What to do |
| --- | --- | --- |
| Checks, build, signing, describing | Nothing published | Fix and run again with the same inputs. |
| Publishing the APK, checking it, or promoting | The APK release may exist; the catalog is unchanged | **Re-run failed jobs**. That reuses the tested, signed APK kept by the build job (30 days) and continues. Do not start a new run with the same version: a new build may not be byte-identical, and the published APK is never replaced. To abandon the version instead, use a new version name and code. |
| Between the two renames of a promotion | `android-catalog.json` is missing; `android-catalog.previous.json` and `android-catalog.next.json` exist | Servers keep their cached builds. Every later run stops until it is resolved. Finish the promotion by renaming the checked new catalog: `gh api --method PATCH repos/<owner>/<repo>/releases/assets/<id of android-catalog.next.json> -f name=android-catalog.json` (asset ids: `gh api repos/<owner>/<repo>/releases/tags/android-catalog-v1 --jq '.assets[] \| [.id, .name]'`). |

To withdraw a build, publish a newer one. Servers never step back to a lower
version code, and Android does not install one over a higher one.

## Running the tools locally

```sh
python3 -m unittest discover -s apps/scripts/tests

# A catalog entry for a signed APK (needs ANDROID_HOME with build-tools, and java)
apps/scripts/android-update-manifest.py --catalog-entry --apk shelfarr.apk \
  --apk-url https://github.com/Pedro-Revez-Silva/shelfarr/releases/download/android-release-v2026.11.8.1/shelfarr-android-release-2026.11.8.1-12.apk \
  --channel release --package org.shelfarr.app --signer-sha256 <64 hex> \
  --expect-version-code 12 --expect-version-name 2026.11.8.1 --output entry.json

# Validate a catalog, and add the entry to it without publishing anything
apps/scripts/android-update-catalog.py check android-catalog.json
apps/scripts/android-update-catalog.py add --previous android-catalog.json --entry entry.json --output new.json
```

A custom catalog for a self-hosted publisher (`ANDROID_UPDATE_CATALOG_URL` on the
server) can be built the same way with `--catalog-url https://…/catalog.json`; its
APKs must then be on that catalog's origin. The GitHub commands
(`github-fetch`, `github-publish-apk`, `github-promote`) act only on the GitHub
release the catalog URL names.

## Limits

- The workflow has not run on GitHub yet; its first real run is also the first test
  of the signing secrets, the in-run artifact download (`gh run download` on the
  running workflow) and GitHub's asset rename.
- The scripts' tests use stand-ins for `apksigner`, `aapt2` and `gh`; the real tools'
  output formats are matched from their documented output, not exercised here.
- Signing-key rotation is not supported, by the app or here.
- A promotion has a moment (between two renames) without a catalog asset; servers
  then keep what they have and try again later.

# Releases and the beta channel

Shelfarr publishes two release channels from `main`. Which one a build belongs to is
decided by the source being released, in `config/release_channel.yml`:

```yaml
channel: beta
series: "1.0"
```

The weekly (or manually started) release workflow reads that file at the commit it
releases. A missing file, an unknown channel or a malformed series stops the workflow
before anything is built, tagged or published.

## What each channel publishes

| | Stable (`channel: stable`) | Beta (`channel: beta`) |
|---|---|---|
| Build number | `YYYY.MM.DD.N` | `YYYY.MM.DD.N-beta` |
| Git tag | `vYYYY.MM.DD.N` | `vYYYY.MM.DD.N-beta` |
| Shelfarr image tags | `YYYY.MM.DD.N` and `latest` | `YYYY.MM.DD.N-beta` and `beta` |
| Audible companion image tags | `YYYY.MM.DD.N` and `latest` | `YYYY.MM.DD.N-beta` and `beta` |
| GitHub release | normal release, marked latest | prerelease, never marked latest |
| Shown in Shelfarr as | Shelfarr 1.0 | Shelfarr 1.0 Beta |

Build numbers are shared by both channels on one date, so a stable and a beta build of
the same day never get the same number. A beta build never moves `latest`, and GitHub
never reports a prerelease as the latest release, so stable servers keep being offered
stable releases only. A beta server is offered the newest beta or stable build. Release
numbers for the Android app, its catalog and its consumer API versions are unchanged
and separate from these.

## Trying the beta

1. Back up first. Stop Shelfarr and copy its `/rails/storage` volume (the database and
   settings), and keep the image tag you are running now. Beta builds may add database
   changes that the stable build you came from cannot undo.
2. Set `SHELFARR_VERSION=beta` (or a fixed `YYYY.MM.DD.N-beta` build) so that Shelfarr
   and its Audible companion move together, then `docker compose pull && docker compose up -d`.
3. Admin → Overview shows the release you are on and offers newer beta or stable builds.

## Going back to stable

Changing the image tag back is not enough after a beta has run, because its database
changes stay. To roll back:

1. Stop Shelfarr.
2. Restore the `/rails/storage` backup you made before installing the beta.
3. Set `SHELFARR_VERSION` to the stable build you were running (or `latest`) and start
   Shelfarr again.

Anything changed while the beta was running (requests, reading places, settings) is lost
with the restore.

## Promoting a release to stable

Promotion is a reviewed change to `config/release_channel.yml` on `main`, setting
`channel: stable`. The next release run publishes `vYYYY.MM.DD.N`, moves `latest` for both
images and creates a normal GitHub release. Changing it back to `beta` returns later
releases to the beta channel without touching what was already published.

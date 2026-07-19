# Audible Backup, powered by Libation (Beta)

Shelfarr's Audible Backup integration helps you preserve and manage audiobooks already present in your Audible library. It is powered by [Libation](https://github.com/rmcrackan/Libation), which runs as a separate companion service while Shelfarr provides a Settings-style setup, live status, main-Library browsing, and import experience.

This is an owned-library backup feature. Shelfarr does not search the Audible store, advertise Audible titles for purchase, sell books, or treat Audible as a DRM-free seller.

> **Beta:** Audible Backup depends on an unofficial Libation integration with Audible. Audible authentication and internal interfaces can change without notice. Keep the original purchases in your Audible account and do not treat Shelfarr or Libation as the only copy of important files.

## What is packaged

The standard Docker Compose deployment includes an optional Shelfarr Libation companion. The companion contains an unmodified, version-pinned Libation CLI plus a small Shelfarr control bridge. It is a separate process and image; Libation source code is not copied into the Shelfarr Rails application.

```text
Shelfarr web application
       | private companion API
       v
Shelfarr Libation companion
       | completed personal backup
       v
Shared import directory -> Shelfarr output path -> configured library platform
```

The companion:

- owns the Audible authentication state and Libation database;
- synchronizes the user's owned Audible library when explicitly requested or when the administrator enables a schedule;
- asks Libation to back up selected owned titles or titles admitted by a confirmed existing-library batch;
- writes completed files to a dedicated shared import directory;
- exposes status to Shelfarr over the private Compose network.

The companion does not expose a public port. Shelfarr does not receive the Audible password, and neither container needs the Docker socket.

### Current beta scope

The first beta supports:

- a Settings-style Audible Backup page with Overview, Connection, Automation, and diagnostic Catalog tabs;
- external-browser Audible authentication;
- account and authorization status;
- on-demand or scheduled owned-library sync with durable queued, syncing, succeeded, and failed feedback;
- browsing purchased, not-yet-imported titles in the administrator's main Shelfarr Library;
- queuing backups for one or more individually selected purchased titles;
- an explicit prompt after the first sync to queue a conservative one-time backup of eligible existing purchased audiobooks;
- a durable, bounded existing-library batch that advances in the background while Libation processes one title at a time, with progress and retries managed from the main Library;
- an additional opt-in that refreshes a no-download baseline, then queues future purchased audiobooks when a later successful manual or scheduled sync first discovers them; and
- live card status while Libation backs up and Shelfarr imports each title.

An unfiltered **Back up all**, retroactive automatic backup, pause/resume, and cancellation are not part of the first beta. The existing-library action is deliberately narrower: it requires confirmation and excludes subscription access, local matches, identity conflicts, and prior backup/import attempts. Administrators can also select several distinct titles individually. The companion processes all admitted backups one at a time so Libation operations cannot overlap. Validate authentication, storage permissions, and final import behavior with one title before starting a large batch or enabling automatic backup.

## New installations

Use the current Shelfarr Compose file rather than copying only the `shelfarr` service from an older example:

```bash
mkdir shelfarr && cd shelfarr
curl -O https://raw.githubusercontent.com/Pedro-Revez-Silva/shelfarr/main/docker-compose.example.yml
mv docker-compose.example.yml docker-compose.yml

# Edit the host-side media and data paths, then start the stack.
docker compose up -d
```

The companion starts idle and does not contact Audible until an administrator explicitly enables and connects Audible Backup. Users who leave the feature disabled do not need an Audible account and do not need to configure Libation manually.

For a reproducible deployment, put the exact published Shelfarr **OCI image version** in `.env`; the same value selects the matching companion. Use the numeric version without the GitHub release tag's leading `v`:

```dotenv
SHELFARR_VERSION=X.Y.Z
```

For example, GitHub release `vX.Y.Z` is published as container image tag `X.Y.Z`; setting `SHELFARR_VERSION=vX.Y.Z` will not select that image. Replace `X.Y.Z` with the release number you are deploying.

Normal installations should use a published release. Shelfarr publishes the application and matching companion images for releases, but pull-request builds are not published as installable image tags. Building both images from source is a contributor or release-candidate test workflow, not part of a normal update.

After Shelfarr starts, continue with [Connect an Audible account](#connect-an-audible-account).

## Existing installations

An existing Shelfarr container cannot safely create a sibling container. Doing that would require the Docker socket, which would give the web application control over the host. Existing installations therefore need a one-time Compose update before Audible Backup can be enabled in the UI.

1. Wait for active downloads, uploads, imports, and request processing to finish.
2. Record the Compose project that owns the running container and its active mounts. The storage source shown for `/rails/storage` is the installation you must preserve:

   ```bash
   docker inspect shelfarr \
     --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}'
   docker inspect shelfarr \
     --format '{{ range .Mounts }}{{ println .Source "->" .Destination }}{{ end }}'
   ```

3. Stop Shelfarr and back up the **complete** `/rails/storage` source plus the current Compose files and `.env`. Keep the primary, queue, cache, and cable SQLite databases together with `.encryption_keys`, `.secret_key_base`, and Active Storage data. Do not copy only `production.sqlite3`. For a Linux host, replace the example source with the absolute path reported above:

   ```bash
   docker compose stop shelfarr
   mkdir -p backups/pre-audible-upgrade
   cp -p docker-compose*.yml backups/pre-audible-upgrade/
   if [ -f .env ]; then cp -p .env backups/pre-audible-upgrade/; fi
   tar --xattrs --acls --numeric-owner \
     -C /absolute/current/storage/source \
     -czf backups/pre-audible-upgrade/storage.tar.gz .
   sha256sum backups/pre-audible-upgrade/storage.tar.gz \
     > backups/pre-audible-upgrade/storage.tar.gz.sha256
   sha256sum -c backups/pre-audible-upgrade/storage.tar.gz.sha256
   ```
4. Download the Compose example from the same published Shelfarr release you are installing. Use the numeric image version without a leading `v` for both Shelfarr images.
5. Merge its `shelfarr-libation` service, the `libation_config`, `libation_books`, and `libation_control` volumes, and the Shelfarr-side mounts and environment variables into your Compose file, or use the separate override shown below. Preserve the existing source of `/rails/storage`, media paths, ports, environment, and reverse-proxy configuration. In particular, do not replace an older `./data/storage:/rails/storage` mount with `./data:/rails/storage`; that would start Shelfarr against a different directory and make the installation appear empty. If you keep `docker-compose.audible.yml` separate, add `-f docker-compose.yml -f docker-compose.audible.yml` to every Compose command in the remaining steps.
6. Validate the Compose merge without printing resolved environment values, then pull and recreate the stack:

   ```bash
   docker compose config -q
   docker compose pull
   docker compose up -d
   docker compose ps
   ```

7. Confirm both services are healthy, `/up` returns HTTP 200, and the active `/rails/storage`, `/audiobooks`, `/ebooks`, and `/downloads` mounts still point to the intended host paths.
8. Run the [audiobook filesystem preflight](#preflight-the-audiobook-filesystem).
9. Open **Admin > Audible Backup** (or `/admin/owned_library_connections`) and verify that the companion test succeeds.
10. Enable the integration and connect the account as described below.

This update is additive. Audible Backup is disabled by default and does not change existing acquisition sources, download clients, stored provider credentials, Active Record encryption keys, or media paths. Once the companion is part of the deployment, future enable/disable, account, sync-schedule, and backup actions are managed from Shelfarr.

Instead of editing a heavily customized base file, you can put the additions in `docker-compose.audible.yml`:

```yaml
services:
  shelfarr:
    volumes:
      - ${LIBATION_BOOKS_PATH:-libation_books}:/imports/libation:ro
      - libation_control:/run/shelfarr-libation:ro
    environment:
      SHELFARR_LIBATION_URL: http://shelfarr-libation:8080
      SHELFARR_LIBATION_TOKEN_FILE: /run/shelfarr-libation/token
      SHELFARR_LIBATION_IMPORT_ROOT: /imports/libation
      PUID: ${PUID:-1000}
      PGID: ${PGID:-1000}
      CHOWN_ON_START: ${CHOWN_ON_START:-auto}

  shelfarr-libation:
    image: ghcr.io/pedro-revez-silva/shelfarr-libation:${SHELFARR_VERSION:-latest}
    container_name: shelfarr-libation
    restart: unless-stopped
    expose:
      - "8080"
    volumes:
      - libation_config:/config
      - ${LIBATION_BOOKS_PATH:-libation_books}:/data
      - libation_control:/control
    environment:
      PUID: ${PUID:-1000}
      PGID: ${PGID:-1000}
      CHOWN_ON_START: ${CHOWN_ON_START:-auto}
      LIBATION_FILES_DIR: /config
      LIBATION_BOOKS_DIR: /data
      LIBATION_IN_PROGRESS_DIR: /config/in-progress
      COMPANION_STATE_DIR: /config/shelfarr-companion
      COMPANION_TOKEN_FILE: /control/token
      ASPNETCORE_URLS: http://0.0.0.0:8080

volumes:
  libation_config:
  libation_books:
  libation_control:
```

Start future upgrades with both files:

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.audible.yml \
  pull

docker compose \
  -f docker-compose.yml \
  -f docker-compose.audible.yml \
  up -d
```

Use the full Compose example from your installed Shelfarr release as the source of truth if it differs from this beta example.

Set `PUID` and `PGID` once in `.env`; both services must run with the same IDs because the bridge token is intentionally mode `0600` and the completed-backup volume is shared. For a large library, also place Libation's retained copies on storage you size and monitor explicitly instead of Docker's default volume location:

```dotenv
PUID=1000
PGID=1000
CHOWN_ON_START=auto
LIBATION_BOOKS_PATH=/mnt/media/libation-backups
```

Create the bind directory with matching ownership before starting Compose. Leave `LIBATION_BOOKS_PATH` unset to use the named `libation_books` volume.
The default `CHOWN_ON_START=auto` initializes fresh named volumes but avoids a root ownership change when a bind mount is already owned by `PUID`/`PGID`. For NFS or another root-squashed filesystem, pre-create and pre-permission all mounted directories, then set `CHOWN_ON_START=never`; startup will validate configured-user access and fail without changing ownership if the paths are not usable. Private `/control`, `/config`, companion-state, in-progress, and home directories must have no group/world permissions (normally mode `0700`), while the Libation accounts, settings, database, and existing bridge-token files must be owner-only (normally `0600`). In `never` mode the companion entrypoint validates these permissions and fails closed instead of silently repairing an unsafe `0644` credential or token. `always` is the strict alternative for local storage where any failed ownership adjustment should stop startup.

If you later change `PUID` or `PGID`, keep `CHOWN_ON_START=auto` for the first restart. The companion performs a one-time ownership migration of nested Libation state, cached jobs, partial downloads, completed books, and the bridge token without following symbolic links, then records the new IDs so ordinary restarts do not rescan the volumes. With `CHOWN_ON_START=never`, an ID change deliberately fails closed; pre-permission the complete mounted trees to the new IDs before restarting. Compose also monitors the companion's internal `/health` endpoint, so `docker compose ps` should report it as healthy before you enable or test the integration in Shelfarr.

Audible imports also require the configured Shelfarr audiobook output filesystem to support advisory file locks, same-filesystem hard links, and Unix permission changes. Shelfarr probes all three before enabling or starting a backup and finalizes imported files as group-readable mode `0640`. Its private `.shelfarr-staging` directory is created inside the audiobook output root deliberately; do not mount that nested directory from a different filesystem or volume, because the atomic handoff would cross devices. Some NFS/SMB appliances disable hard links or reliable `flock` even when ordinary reads and writes work. In that case the capability test fails before Libation downloads anything; use a compatible local or network filesystem rather than bypassing the check.

### Preflight the audiobook filesystem

Run the same capability check Shelfarr uses before connecting Audible or starting a large backup. Run it as Shelfarr's unprivileged user; running it as root can hide a real permission problem. If you use the separate Audible override, include both Compose files as shown:

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.audible.yml \
  exec -T --user rails shelfarr sh -lc '
    set -a
    if [ -f /rails/storage/.encryption_keys ]; then
      . /rails/storage/.encryption_keys
    fi
    set +a
    bin/rails runner '\''
      raise "filesystem capability check failed" unless
        OwnedMediaImportFileService.verify_filesystem_capabilities!
      puts "audiobook filesystem: ok"
    '\''
  '
```

The command briefly creates and removes probe files. It leaves only Shelfarr's intended private staging and lock directories. Do not start an existing-library batch until this command succeeds.

### mergerfs and FUSE mode overrides

Some mergerfs installations include a libfuse mount option such as `umask=0002`. In this context `umask` is a **reported-mode override**, not the normal process file-creation mask: the [FUSE mount documentation](https://man7.org/linux/man-pages/man8/fuse.8.html) describes it as overriding the permission bits reported in `st_mode`. `umask=0002` therefore makes files appear as mode `0775` even after Shelfarr successfully requests `0640`. Shelfarr cannot verify the backing inode's group/other permissions through that view, so the capability check fails closed. Setting `umask=0000` is not a fix; it reports `0777`.

Check the filesystem and its persistent mount configuration before enabling Audible Backup:

```bash
findmnt -T /path/to/audiobooks -o TARGET,SOURCE,FSTYPE,OPTIONS
grep -E '[[:space:]]/path/to/mergerfs-mount[[:space:]]' /etc/fstab
```

Do not bypass the Shelfarr check. Use one of these resolutions:

1. **Maintenance-window fix:** audit ownership and modes on every mergerfs branch, remove the libfuse `umask=` override from the persistent mount configuration, stop every service using the pool, fully unmount and mount it again, then test all consumers and rerun the Shelfarr preflight. FUSE cannot change this option safely in place. Restore the original mount configuration and repeat the coordinated remount if another consumer loses access.
2. **Container-only direct bind:** if one underlying POSIX filesystem contains every audiobook path Shelfarr needs and has sufficient free space, replace only Shelfarr's `/audiobooks` source with that underlying directory. For example, add the repeated target to the Audible override:

   ```yaml
   services:
     shelfarr:
       volumes:
         - /mnt/drive-containing-the-complete-library/audiobooks:/audiobooks
   ```

   Compose replaces the original `/audiobooks` mount by container target. Verify the complete file and directory set before switching. This bypasses mergerfs balancing for future Shelfarr writes and can hide titles stored only on another branch; other applications may continue using the pooled path. Revert the override to return Shelfarr to the pool.

After either resolution, recreate Shelfarr, inspect the active mount, and rerun the preflight:

```bash
docker inspect shelfarr \
  --format '{{ range .Mounts }}{{ if eq .Destination "/audiobooks" }}{{ println .Source "->" .Destination }}{{ end }}{{ end }}'
```

Treat every process that shares Shelfarr's `PUID` as trusted. Descriptor pinning, atomic publication, and inode checks prevent accidental and cross-process pathname races, but POSIX does not let an application revoke another same-UID process's ability to rename or replace writable library entries. Run untrusted download or automation tools under a separate UID and expose only the specific exchange directories they require.

If you already use Libation independently, keep that installation until the first Shelfarr-managed sync and backup have been verified. Do not point two running Libation processes at the same database or config directory.

## Connect an Audible account

1. Sign in to Shelfarr as an administrator.
2. Open **Admin > Audible Backup** (or `/admin/owned_library_connections`).
3. Check **Enable Audible Backup beta**, keep **Allow local/private companion address** enabled for the bundled service, and select **Save connection**.
4. Enter the Audible account email address and choose its marketplace or region.
5. Select **Start sign-in**. Shelfarr asks the companion to start Libation's external login flow and displays **Open secure Audible sign-in**.
6. Complete the password, MFA, CAPTCHA, or account confirmation directly on Amazon/Audible.
7. Copy the final redirected browser URL and paste it into Shelfarr when prompted.
8. Select **Complete sign-in**, then run the initial library sync. After it completes, the Overview tab asks whether to queue a one-time backup of eligible existing purchases. That first snapshot is also required before automatic future-purchase backup can be enabled safely.

The Audible Backup page follows the same visual structure as Shelfarr Settings and separates the workflow into four tabs:

1. **Overview** shows setup readiness, sync and Library status, and the first existing-library backup decision.
2. **Connection** contains both the Libation companion configuration and Audible account sign-in/status cards.
3. **Automation** contains scheduled sync, the separate future-purchase automatic-backup option, and the reusable, explicitly confirmed existing-library backup action.
4. **Catalog** is a diagnostic view of the cached Audible records, including ineligible subscription titles and failures. Normal backup management remains in the main **Library**, where Audible titles carry an **Audible** card tag.

Selecting **Sync library** immediately records a queued state before the background worker starts. The page then refreshes itself as the sync moves through queued, syncing, succeeded, or failed states, so it is safe to leave the page and return later. While a sync is running, Shelfarr shows elapsed time and an indeterminate activity indicator. Libation does not provide a trustworthy percentage or ETA, so Shelfarr does not invent either one. If a queued acknowledgement or startup handoff becomes stale, the page exposes a safe **Recover sync** action; old job deliveries cannot start a second scan. A failed refresh keeps the previous cached snapshot available and provides **Retry sync** with the recorded error.

### One-time backup of existing purchases

After the first successful sync, **Overview** asks whether to start backing up the eligible existing Audible library. Nothing is queued until an administrator confirms the action. Choosing **Not now** creates no work; individual **Back up** controls remain available in the main Library, and the existing-library action remains available under **Automation** for a later explicit run.

Shelfarr recalculates eligibility whenever an administrator opens or confirms this action. The safe batch includes only active, purchased audiobooks and excludes:

- subscription-access and inactive titles;
- titles already available in Shelfarr through a confirmed local match;
- titles with an ambiguous local-library identity conflict; and
- titles with any prior Shelfarr backup/import attempt, including failed work that should be reviewed or retried individually.

This filtering prevents an existing-library run from silently duplicating files, claiming uncertain matches, or repeating historical failures. A completed copy that Libation already has can still follow the normal validation and import path when it otherwise meets the rules.

Once confirmed, Shelfarr records a durable background batch and releases work to the existing queue in bounded steps. Libation runs only one title backup at a time. The main **Library** shows queued, backing-up, importing, succeeded, and failed states, so leaving the setup page or restarting the web process does not turn the batch into an untracked foreground operation. Use the Library to inspect and manually retry individual failures.

The existing-library action is not a schedule and does not enable automatic future-purchase backups. Running it again is always an explicit administrator decision and re-applies the same conservative exclusions.

### Optional automation

Automation is off by default. Manual sync and per-title **Back up** actions remain available whether or not automation is enabled.

After one successful manual sync has established the existing-library snapshot:

1. Check **Sync the Audible library automatically**.
2. Choose a fixed interval: every hour, 6 hours, 12 hours, 24 hours, 3 days, or weekly. The default remains every 24 hours.
3. Optionally check **Automatically back up new purchases**, then select **Save automation**.

Scheduled sync uses the same serialized operation path and durable status as **Sync library**. If Libation is already syncing, backing up, or waiting for account attention, Shelfarr does not start an overlapping operation. The setup page shows the next scheduled time, and an administrator can still request a manual sync.

Automatic backup is a separate opt-in and requires scheduled sync. When enabled, the next successful manual or scheduled sync refreshes the safety baseline without queuing downloads. Only purchased audiobooks first discovered by later successful syncs are queued automatically, and Shelfarr attributes those imports to the administrator who enabled the option. Titles present in either the old or refreshed snapshot, subscription-access titles, and existing failed/manual entries are not queued by future-purchase automation. Existing purchases are handled only through the separately confirmed existing-library action or individual Library controls. This prevents a stale cached snapshot from turning recent pre-opt-in purchases into an unexpected large download.

Turning off scheduled sync also turns off automatic backup. Turning automatic backup off clears its baseline; enabling it again requires another no-download baseline refresh and does not backfill titles that Shelfarr discovered while it was off. Neither setting starts the existing-library batch. If the attributed administrator account is removed or demoted, automatic backup pauses until another administrator saves the automation settings; ordinary interval changes preserve the existing eligible owner. Automatic jobs use the same visible Library cards, serial queue, output paths, validation, and import flow as a manual backup.

The pasted final URL is required because Libation's current external-login flow must start and finish in the same companion process. Shelfarr does not ask for or store the Audible password, and the one-time response URL is neither persisted nor written to logs. Libation's tokens and device information remain in the companion's private persistent state.

Shelfarr keeps the already validated **Open secure Audible sign-in** link only in encrypted, short-lived Shelfarr state until authentication completes or the session expires, so reloading the page does not lose an active sign-in link. That state is cleared on completion or expiry. If the page reports that the session expired, start sign-in again; do not reuse an old final redirect URL.

The first beta accepts these marketplace choices: United States, United Kingdom, Australia, Canada, France, Germany, India, Italy, Japan, and Spain. Choose the marketplace where the account's Audible library is registered; it is not a display-language preference.

An account may need to be reconnected if Audible expires its authorization or requires a new challenge. Shelfarr stops automatic authentication retries in that state so it does not repeatedly trigger account security controls.

## Sync and back up the library

After connecting an account:

1. Select **Sync library** to refresh Shelfarr's local view of titles attached to the account.
2. When **Overview** presents the existing-library decision, either confirm the displayed eligible count to start the background batch or choose **Not now**. If storage and imports have not been validated yet, choose **Not now** and test one title first; the action remains available under **Automation**.
3. Open the main **Library**. Administrators see purchased Audible audiobooks in the normal Library grid, identified by an **Audible** card tag and their local-availability status. Select the **Audible** filter beside **Audiobooks** and **Ebooks** to show only cards carrying that tag; title/author search and pagination keep the filter active. Other users do not see the unimported personal Audible catalog.
4. Select **Back up** for an individual purchased title when it is not part of the batch, or follow batch items as Shelfarr queues them, Libation creates each personal backup, and Shelfarr imports it. The companion serializes Libation operations even when several titles are queued.
5. After import, Shelfarr replaces the remote, not-on-server representation with the canonical acquired book card in the same grid. It does not show duplicate remote and local entries for the same linked title. The acquired card keeps both **On server** and **Audible** tags. The configured audiobook output path and filename templates still apply, and Shelfarr triggers the configured library-platform scan.

Subscription-access titles remain visible in the collapsed **Audible catalog details** diagnostic view on the setup page, but they are not eligible for backup in this beta. They do not appear in the main Library grid.

The unified Library grid combines acquired Shelfarr books with Shelfarr's cached Audible-owned records for browsing, filtering, and pagination; it does not query Audible on each page load or metadata search. Run a manual sync after purchasing a new title, or enable scheduled sync after the initial snapshot. Automatic backup remains separately opt-in and future-purchases-only; the confirmed existing-library batch is a different, manual action.

### Library card states

| Card message or action | Meaning |
|---|---|
| **Audible** tag + **Not on this server** / **Back up** | The purchased title is eligible and has not been backed up through Shelfarr yet. |
| **Ready to import** / **Import into Shelfarr** | Libation already has a completed copy that Shelfarr can validate and import. |
| **Possible local-library match** / **Back up separately** | A local audiobook has similar title and creator metadata, but Shelfarr cannot prove it is the same edition. The new backup gets its own canonical book and does not overwrite the existing file. Only a stable ASIN-to-ISBN bridge is linked automatically. |
| **Queued…** | Shelfarr accepted the request and it is waiting behind any earlier Libation operation. |
| **Backing up…** | Libation is currently creating the backup. |
| **Importing…** | Shelfarr is validating, organizing, and delivering the completed artifact. |
| **Automatically queued** / **Automatic backup running** / **Importing automatic backup** | The same queue and import flow was started by the future-purchase automation rather than a manual click. |
| **No recent update** / **Check status** | Shelfarr has not received a recent worker heartbeat. The action safely resumes status polling without starting a second title backup. |
| **Backup failed** or **Automatic backup failed** / **Retry backup** | The last attempt failed; inspect the recorded error and retry manually when it has been addressed. Automatic failures are not retried indefinitely. |

Active card states update automatically, and a queue summary above the unified Library grid reports how many Audible titles are waiting, backing up, or importing. A queued title does not start its download timeout until Libation reports that the title is actually running, so time spent waiting behind another queued backup is represented honestly. A temporary companion network outage keeps an already attached backup active and schedules another status check instead of forcing the administrator to create a conflicting retry.

Because Libation operations are serialized, the account-status area can temporarily report **Busy** while a sync or backup owns the companion lock. This is an in-progress state, not a lost connection: cached titles and recorded job progress remain available. Wait for the operation to finish, then refresh if the account status has not updated yet.

Audible Backup is separate from request acquisition and third-party store offers:

- it never adds an Audible purchase link;
- it does not search Audible's complete catalog;
- it cannot back up an ASIN that is not present in the connected account's imported library;
- it does not make Audible results eligible for normal request auto-selection.

After a backup is imported, it becomes an ordinary item in Shelfarr's shared Library. Depending on the deployment's existing access rules, other Shelfarr users may be able to view or download that file. Only grant Shelfarr access to people authorized to use the connected account holder's purchases; Audible Backup does not add per-title ownership isolation to a multi-user server.

### Traffic and rate limits

Shelfarr does not call Audible while a user types a metadata search or opens the cached library. Only external sign-in, an explicit or scheduled library sync, or a queued title backup asks Libation to communicate upstream. The companion serializes Libation operations, and Shelfarr stops repeated authentication attempts when a challenge or expired authorization needs attention. An hourly schedule is available, but use the longest interval that meets your needs; no numeric upstream limit is assumed or promised.

## Storage and backups

Keep these storage concerns separate:

- **Shelfarr data:** the existing Shelfarr database, encryption material, connection configuration, cached Audible title/status metadata, backup-import history and artifact paths, plus any encrypted manual bridge token;
- **Libation private state:** account tokens, device information, settings, and Libation's database; mounted only in the companion;
- **Shared import directory:** completed backup artifacts that Shelfarr is allowed to import;
- **Library output:** the final audiobook directory already configured in Shelfarr.

Back up the Libation private state along with Shelfarr's data, but protect it as a secret. Never publish it, mount it into unrelated containers, or include it in diagnostic archives. Use matching container user/group permissions for the shared import directory so the companion can write and Shelfarr can read completed files.

Shelfarr copies a validated audio artifact through its normal import pipeline; it does not delete Libation's completed copy from `libation_books`. Plan storage for both the retained Libation copy and the organized library copy. This also lets Libation keep its own backup state intact. Cleanup and storage deduplication are not automated in the first beta.

The Shelfarr migration is additive: it creates owned-library connection, item, and import tables. It does not rewrite existing setting values or encrypted records and does not rotate the Active Record encryption key tuple. The standard Compose deployment reads the generated bridge token from the read-only token-file mount. A manually entered bridge token for a custom companion is stored only in the dedicated encrypted connection attribute, never in plaintext `SettingsService` values.

### Companion deployment contract

The official Compose package wires these values automatically. They are documented here for administrators maintaining a customized deployment:

| Component | Setting | Value or purpose |
|---|---|---|
| Shelfarr | `SHELFARR_LIBATION_URL` | `http://shelfarr-libation:8080` on the private Compose network |
| Shelfarr | `SHELFARR_LIBATION_TOKEN_FILE` | `/run/shelfarr-libation/token` |
| Shelfarr | `SHELFARR_LIBATION_IMPORT_ROOT` | `/imports/libation`, the Shelfarr side of the completed-backup volume |
| Companion | `ASPNETCORE_URLS` | `http://0.0.0.0:8080`; do not publish this port to the host |
| Companion | `LIBATION_FILES_DIR` | `/config`, a private persistent volume |
| Companion | `LIBATION_BOOKS_DIR` | `/data`, the shared completed-backup volume |
| Companion | `LIBATION_IN_PROGRESS_DIR` | `/config/in-progress` |
| Companion | `COMPANION_STATE_DIR` | `/config/shelfarr-companion` |
| Companion | `COMPANION_TOKEN_FILE` | `/control/token`, shared read-only with Shelfarr at its token-file path |
| Companion | `COMPANION_MAX_ACTIVE_JOBS` | `500`; bounds queued plus running work |
| Companion | `COMPANION_MAX_TERMINAL_JOBS` | `5000`; bounds retained completed/failed job records |
| Companion | `COMPANION_TERMINAL_JOB_RETENTION_DAYS` | `30`; maximum completed/failed record age |

The companion creates the bearer token file when it is missing. Only its health endpoint is unauthenticated; version, account, authentication, sync, library, backup, and job operations require that token. Do not replace the token-file mount with a token embedded directly in a public Compose file.

Shelfarr uses the mounted token only when the saved companion URL exactly matches `SHELFARR_LIBATION_URL`. If an administrator changes the URL to a separately hosted companion, Shelfarr requires the matching bridge token in the form and stores it in the dedicated encrypted connection attribute. This prevents the bundled companion's token from being sent to an unrelated host.

Plain HTTP is accepted only when the resolved companion endpoint is on a private or loopback network. A companion reached across a public network must use HTTPS; otherwise its bearer token would be exposed in transit.

The standard service image is `ghcr.io/pedro-revez-silva/shelfarr-libation:${SHELFARR_VERSION:-latest}`. Named volumes map as follows:

| Volume | Shelfarr mount | Companion mount | Contents |
|---|---|---|---|
| `libation_config` | not mounted | `/config` | Private Libation authorization, database, settings, and bridge state |
| `libation_books` or `LIBATION_BOOKS_PATH` | `/imports/libation` read-only | `/data` | Completed backup artifacts available for import |
| `libation_control` | `/run/shelfarr-libation` read-only | `/control` | Generated companion bearer token only |

### Companion control interface

The bridge is an internal implementation detail and can change during beta. It is documented for transparency and diagnostics, not as a host-facing public API:

| Method and path | Purpose |
|---|---|
| `GET /health` | Unauthenticated process health check |
| `GET /version` | Companion and pinned Libation version |
| `GET /v1/accounts` | Configured account and authorization status |
| `POST /v1/auth/start` | Start external login with an account email and locale |
| `POST /v1/auth/complete` | Complete the held login session with the final response URL |
| `POST /v1/sync` | Queue an explicit library scan and export; returns `202 Accepted` |
| `GET /v1/library` | Return the normalized cached owned library |
| `POST /v1/backups/{asin}` | Queue a backup for one owned ASIN; returns `202 Accepted` |
| `GET /v1/jobs/{id}` | Read a sync or backup job's status |

Backup admission uses the latest normalized library cache before a job is
created: the ASIN must be present, active, and explicitly purchased. A missing
sync or ineligible title returns `422` without consuming queue capacity. When
the configured active-job limit is full, sync and backup requests return `429`
and can be retried after existing work finishes. Succeeded and failed records
remain available for Shelfarr polling until the terminal age/count retention
policy prunes the oldest records; queued and running jobs are never pruned.

Every endpoint except `/health` requires the generated bearer token. The companion permits only one Libation CLI operation at a time; an authentication session holds that operation lock until it completes or expires.

## Version pinning and upgrades

The first companion beta pins Libation `13.5.1` using the immutable image reference:

```text
rmcrackan/libation:13.5.1@sha256:71b9db4bbda7d7e14bb9f5efcdcfe980915c90867599bc0d512d958069fb3da0
```

The upstream Libation base never follows `latest`; its exact tag and digest are part of the companion build. The Compose example uses the same Shelfarr release selector for both application images:

```text
${SHELFARR_VERSION:-latest}
```

For reproducible production deployments, set `SHELFARR_VERSION` to a concrete Shelfarr OCI image version without a leading `v` instead of accepting the example's `latest` fallback. This pins Shelfarr and its matching companion together. The installed Libation version is available through the integration status and documented in the companion release.

When Shelfarr adopts a newer Libation release, the update is reviewed and tested for:

- existing-state migration;
- external authentication;
- account scan and machine-readable library export;
- one-title backup and import;
- interrupted-job recovery;
- supported CPU architectures;
- rollback to the previously supported companion.

Upgrade the Shelfarr and companion images together with the Compose file from the same Shelfarr release. Back up both persistent state areas first. Libation documents that its CLI cannot perform every possible post-upgrade migration, so Shelfarr must not silently move users to an untested upstream version.

## Attribution and licensing

> Audible Backup is powered by Libation, an independent GPL-3.0 open-source project created by rmcrackan and contributors. Shelfarr invokes an unmodified, pinned Libation CLI through a separate companion service. Shelfarr does not claim authorship of or affiliation with Libation or Audible.

Shelfarr's integration pages and companion releases include:

- the exact Libation version and source release;
- links to the [Libation project](https://github.com/rmcrackan/Libation) and [documentation](https://getlibation.com/docs);
- Libation's [GPL-3.0 license](https://github.com/rmcrackan/Libation/blob/v13.5.1/LICENSE);
- the Shelfarr bridge source and a description of what Shelfarr adds;
- preserved upstream notices and source-availability information.

The exact image, digest, source commit, license, and source locations are recorded in the companion's [third-party notices](../services/libation_companion/THIRD_PARTY_NOTICES.md). Every distributed companion image also contains a machine-readable snapshot at `/companion/SOURCES/Libation-13.5.1-source.tar.gz`, so recipients do not depend solely on the continued availability of an upstream tag.

Report Shelfarr UI, packaging, or bridge problems to Shelfarr. Reproduce a problem against Libation itself before reporting it upstream, so Shelfarr-specific issues do not create support work for Libation's maintainers.

## Beta limitations

- The integration is unofficial and is not affiliated with or endorsed by Audible, Amazon, or Libation.
- The first login requires copying the final redirected URL back into Shelfarr because Libation does not currently provide a callback API.
- CAPTCHA, MFA, marketplace differences, expired authorization, and upstream interface changes can require manual attention.
- The integration backs up titles visible to Libation for the connected account. Availability of a title, supplement, codec, or edition is controlled upstream.
- Subscription titles are not equivalent to permanently purchased titles. They are labeled separately and are not eligible for backup in the first beta.
- Large libraries can take significant time and disk space. Start with a single-title backup and verify the import/output paths before confirming a large existing-library batch.
- The confirmed existing-library batch is conservative rather than an unfiltered **Back up all**: subscription titles, local matches, identity conflicts, and prior attempts are excluded. Retroactive automatic backup, pause/resume, and job cancellation are not yet available. Scheduled sync and future-purchase automatic backup are separate opt-ins.
- Automatic import accepts one primary `.m4b`, `.m4a`, or `.mp3` artifact per title. Ambiguous multi-file outputs and non-audio supplements require manual handling in the first beta.
- Files remain subject to the applicable purchase terms and copyright law. Backups are for the connected account holder's personal library; do not redistribute them.

## Disable or remove the integration

Disable Audible Backup in Shelfarr to stop new manual or scheduled sync and backup jobs. Disabling hides the account and owned-library actions, but it does **not** delete completed library files, the companion's private state, or Shelfarr's connection record, cached title/status metadata, backup-import history, artifact paths, automation history, and encrypted manual bridge token.

To remove the companion entirely:

1. Disable Audible Backup and wait for active work to finish.
2. Stop and remove the companion service through Docker Compose.
3. Keep a protected backup until you have confirmed that no further restore is needed.
4. Remove the companion's private volumes only when you intentionally want to erase its account state.

Removing the companion or its Docker volumes does not erase Audible Backup records held in Shelfarr's database. The first beta has no supported targeted purge action in the UI; do not delete interconnected rows manually unless you have made a verified database backup and understand their foreign-key relationships. If targeted erasure is a deployment requirement, account for this limitation before enabling the beta.

Removing the companion does not require changing Shelfarr's encryption keys or rebuilding its existing configuration.

### Downgrading Shelfarr

Disabling or removing the companion is different from downgrading the Shelfarr
application. Do not start a pre-Audible-Backup Shelfarr image against a database
that has been used by this beta. The older code does not know about the owned
library tables or recovery records, and queued beta jobs live in Shelfarr's
separate Solid Queue database even if the primary database is rolled back.

For a safe application rollback:

1. Disable scheduled sync and automatic backup, then wait for active sync,
   backup, upload, direct-download, and post-processing work to finish.
2. Stop both Shelfarr services so no worker or recurring task can mutate either
   database during the rollback.
3. Restore the complete pre-upgrade Shelfarr storage backup, not only the
   primary SQLite file. Keep the primary, queue, cache, and cable databases
   together with the auto-generated `.encryption_keys` and application-secret
   files. Deployments which supply those secrets externally must restore the
   exact same external values. Restoring encrypted rows without their matching
   key tuple makes the existing credentials unreadable.
4. Restore the matching pre-upgrade Compose file and Shelfarr image. Restore or
   retain the companion's private volume according to whether the companion is
   also being rolled back; never delete it as an incidental cleanup step.

A hand-written partial database downgrade or clearing only selected job rows is
not a supported recovery procedure. Keep the current backups until the older
installation has booted and its existing encrypted download-client, provider,
and two-factor credentials have been verified.

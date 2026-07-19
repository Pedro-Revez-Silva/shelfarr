# Shelfarr Libation Companion (beta)

The companion makes [Libation](https://github.com/rmcrackan/Libation) available
to Shelfarr as an optional Audible backup engine. It does not fork, patch, or
copy Libation's implementation. The container adds a small authenticated API
around an exact, pinned Libation CLI release.

This service is not affiliated with Audible, Amazon, or the Libation project.
The Shelfarr UI and documentation must describe the feature as **Audible Backup
(beta), powered by Libation**.

## Packaging model

The image is built from the unmodified multi-architecture
`rmcrackan/libation:13.5.1` image at the manifest digest recorded in the
[third-party notice](THIRD_PARTY_NOTICES.md). Do not replace the digest with a
floating `latest` tag. The bridge is published as a self-contained .NET 10
minimal API and the upstream Libation CLI remains a separate process.
The build also places a machine-readable snapshot of the exact upstream source
at `/companion/SOURCES/Libation-13.5.1-source.tar.gz`, beside the license and
third-party notice in the distributed image. The independently licensed
Shelfarr bridge has its own named license copy at
`/companion/LICENSES/Shelfarr-GPL-3.0.txt`; OCI source and revision labels map
the bridge binary back to its exact Shelfarr commit.

The service needs three volumes:

| Container path | Access | Contents |
| --- | --- | --- |
| `/config` | Companion only | Audible identity tokens, Libation settings/database, persistent jobs and cached library |
| `/control` | Companion read/write; Shelfarr read-only | Generated bridge bearer token only |
| `/data` | Companion read/write; Shelfarr read-only | Completed audiobook files that are ready for import |

Never mount `/config` into Shelfarr. In particular, Shelfarr must not read or
store `AccountsSettings.json`, Audible cookies, device credentials, or the
post-login browser URL.

A representative Compose service is:

```yaml
services:
  libation-companion:
    build:
      context: ./services/libation_companion
    environment:
      PUID: ${PUID:-1000}
      PGID: ${PGID:-1000}
      CHOWN_ON_START: ${CHOWN_ON_START:-auto}
    expose:
      - "8080"
    volumes:
      - libation_config:/config
      - libation_control:/control
      - libation_imports:/data
    restart: unless-stopped

volumes:
  libation_config:
  libation_control:
  libation_imports:
```

The API port should remain on a private Compose network; do not publish it to
the host or internet. Shelfarr should mount `libation_control` read-only and
resolve returned `artifactPaths` below its own read-only mount of
`libation_imports`.

The companion retains application warnings and errors but suppresses the
framework's Information-level request-path diagnostics. Backup routes contain
the owned title's ASIN, so those identifiers are not copied into normal
container access logs.

On first boot, the root entrypoint creates the named-volume directories and the
minimal Libation state files, assigns them to `PUID`/`PGID`, then permanently
drops privileges before starting the API. The final process has
`no-new-privileges` set and empty inherited, permitted, effective, bounding,
and ambient capability sets. Existing bind mounts must still permit the
configured IDs to traverse their host parent directories. With the
default `CHOWN_ON_START=auto`, correctly pre-owned paths are prepared as the
configured user without a root `chown`, which supports root-squashed storage.
Use `never` only after pre-permissioning every mounted path; use `always` when a
failed ownership adjustment must abort startup. Managed state paths and files
must be real directories or regular files—symbolic links are rejected. With
`CHOWN_ON_START=never`, `/control`, `/config`, companion state, in-progress,
and home directories must expose no group/world mode bits (normally `0700`),
and the Libation accounts, settings, database, and existing token files must be
owner-only (normally `0600`). The entrypoint validates and fails closed; it
does not repair these modes. This keeps pre-permissioned root-squashed mounts
usable without allowing credentials to remain broadly readable.

Changing `PUID` or `PGID` with `CHOWN_ON_START=auto` triggers a one-time,
no-symlink-follow ownership migration of nested config, cached job, partial,
completed-book, and token state. Per-volume owner markers avoid repeating that
recursive scan on normal restarts. With `CHOWN_ON_START=never`, an ID change
fails until the complete mounted trees have been pre-permissioned for the new
identity. The image and supplied Compose service both probe the internal
`/health` endpoint; the companion API should be healthy before Shelfarr is
enabled against it.

## Authentication

`GET /health` is intentionally unauthenticated for an internal container health
check. Every other endpoint requires:

```http
Authorization: Bearer <contents of /control/token>
```

If the token file does not exist, the companion creates a random 384-bit token
with mode `0600`. There is no API that returns the token. Deployments should
share the `/control` volume with Shelfarr instead of putting the token in an
environment variable.

Audible authentication is a two-request operation:

1. `POST /v1/auth/start` starts one Libation `login-external` process and
   returns the upstream browser login URL.
2. The user signs in directly on Amazon/Audible, then copies the final URL from
   the browser address bar.
3. `POST /v1/auth/complete` writes that URL into the **same** held Libation
   process. Terminal echo is disabled. The bridge never persists, returns, or
   logs the final URL.

The session expires after ten minutes by default. It holds the global Libation
operation lock because Libation state must not be mutated concurrently.

Supported marketplace values for Libation 13.5.1 are:

`us`, `uk`, `australia`, `canada`, `france`, `germany`, `india`, `italy`,
`japan`, and `spain`.

## API

All JSON field names use camel case.

| Method and path | Purpose |
| --- | --- |
| `GET /health` | Liveness, pinned versions, busy state, and whether a cached library exists |
| `GET /version` | Bridge/API/Libation versions and upstream attribution |
| `GET /v1/accounts` | Configured account, marketplace, scan-enabled and authentication status |
| `POST /v1/auth/start` | Begin external-browser authentication |
| `POST /v1/auth/complete` | Complete the held authentication session |
| `POST /v1/sync` | Queue a serialized Libation scan followed by a normalized JSON export |
| `GET /v1/library` | Read the complete last successful, local normalized library snapshot; never contacts Audible (legacy compatibility) |
| `GET /v1/library?offset=0&limit=250` | Read a bounded page of the local normalized library; limit range 1-1,000 |
| `POST /v1/backups/{asin}` | Queue one purchased title for backup; ASIN must be ten alphanumeric characters |
| `GET /v1/jobs/{id}` | Read persistent sync or backup job state |

Start authentication:

```json
POST /v1/auth/start
{
  "account": "reader@example.com",
  "locale": "us"
}
```

```json
{
  "status": "waiting_for_browser",
  "sessionId": "8f49d58872a64cd89b315138660b1202",
  "loginUrl": "https://www.amazon.com/...",
  "expiresAt": "2026-07-17T14:20:00Z"
}
```

Complete it without logging the body at any proxy or client layer:

```json
POST /v1/auth/complete
{
  "sessionId": "8f49d58872a64cd89b315138660b1202",
  "responseUrl": "https://www.amazon.com/ap/maplanding?..."
}
```

Sync and backup endpoints return `202 Accepted` with a job object and a
`Location` header. A successful backup job has normalized paths such as:

```json
{
  "id": "e7ef88d7f1bb4f7ca797dc885b3b9210",
  "kind": "backup",
  "status": "succeeded",
  "asin": "B012345678",
  "artifactPaths": [
    "Example Book [B012345678]/Example Book [B012345678].m4b"
  ]
}
```

Large-library clients should use the paged library form. Page responses retain
the snapshot fields (`schemaVersion`, `generatedAt`, `libationVersion`,
`skippedItems`, and `items`) and add `offset`, `limit`, `totalItems`, and
`nextOffset`. Follow `nextOffset` until it is `null`. The no-query endpoint is
kept for older Shelfarr clients, but it can exceed a client's response limit
for exceptionally large Audible libraries.

Paths are always relative to `LIBATION_BOOKS_DIR`. Symlinks, reparse points,
and paths outside that root are ignored. The API field is named
`artifactPaths`. A backup is not marked successful
unless Libation reports the title as liberated and the bridge finds a regular
audio file below the root. The companion forces one lossless M4B rather than
chapter-split or lossy output, even if imported settings request otherwise.
Artifact discovery first targets the exact top-level `[ASIN]` folder or file
names enforced by those templates. Existing libraries using older layouts get
a compatibility fallback that searches below the output root, capped at
100,000 filesystem entries so a malformed or enormous tree cannot cause an
unbounded scan.
Podcast series and episodes are excluded from the Shelfarr book-backup scope.
The companion checks its ASIN-indexed cached entitlement before Libation runs,
then asks Libation to export only the requested ASIN for the post-backup status
check. Missing, inactive, and anything not explicitly classified as purchased
are rejected. A full library export happens only during an explicit sync, not
once per backed-up title.

## Configuration

| Variable | Default | Notes |
| --- | --- | --- |
| `PUID` / `PGID` | `1000` | Numeric non-root IDs used after volume initialization |
| `CHOWN_ON_START` | `auto` | Ownership policy: `auto` adjusts only when needed, `always` fails if an adjustment fails, and `never` performs no startup `chown` |
| `ASPNETCORE_URLS` | `http://0.0.0.0:8080` | Keep reachable only on the private application network |
| `LIBATION_FILES_DIR` | `/config` | Persistent private Libation state |
| `LIBATION_BOOKS_DIR` | `/data` | Completed output shared with Shelfarr |
| `LIBATION_IN_PROGRESS_DIR` | `/config/in-progress` | Persistent resumable download workspace |
| `COMPANION_STATE_DIR` | `/config/shelfarr-companion` | Jobs and normalized library cache |
| `COMPANION_TOKEN_FILE` | `/control/token` | Shared bearer-token file |
| `AUTH_SESSION_TIMEOUT_MINUTES` | `10` | Allowed range 2-30 |
| `CLI_SHORT_TIMEOUT_SECONDS` | `60` | Account, login completion, and JSON export; range 5-300 |
| `CLI_SYNC_TIMEOUT_MINUTES` | `60` | Audible library scan; range 5-360 |
| `CLI_BACKUP_TIMEOUT_HOURS` | `6` | One-title backup; range 1-48 |
| `COMPANION_MAX_ACTIVE_JOBS` | `500` | Maximum queued plus running jobs; range 1-10,000 |
| `COMPANION_MAX_TERMINAL_JOBS` | `5000` | Maximum retained succeeded/failed job records; range 100-100,000 |
| `COMPANION_TERMINAL_JOB_RETENTION_DAYS` | `30` | Maximum age of succeeded/failed job records; range 1-365 |

The executable and pseudo-terminal paths are overrideable for tests through
`LIBATION_CLI_PATH`, `COMPANION_SCRIPT_PATH`, and
`COMPANION_LOGIN_WRAPPER_PATH`; production deployments should leave them at
their image defaults.

## Beta boundaries

- Sync and backup are explicit operations. Scheduling, backup-all, cancellation,
  and bandwidth controls are not part of the first bridge API.
- Jobs are persisted. Queued jobs resume after restart; a job interrupted while
  running is marked failed rather than silently repeated.
- The active queue and its in-memory channel are bounded. Completed and failed
  records remain pollable by Shelfarr, then the oldest records are removed
  after 30 days or when the 5,000-record terminal cap is exceeded. Active jobs
  are never removed by retention.
- The normalized library is replaced only after both scan/export validation
  succeed, so a failed refresh leaves the previous snapshot available.
- The normalized library builds one in-process ASIN index after startup or sync.
  Backup admission and per-title status checks do not repeatedly deserialize or
  export the complete library.
- Per-title library JSON deliberately omits the Audible account identifier;
  account email/status is available only from the dedicated accounts endpoint.
- Full Audible descriptions are omitted from the normalized snapshot because
  Shelfarr does not consume them and large descriptions can dominate sync size.
- One Libation CLI operation can run at a time.
- This integration depends on an undocumented Audible interface through
  Libation and can require maintenance when Audible changes its service.
- The pinned Libation release must be upgraded deliberately and tested against
  an existing state-volume copy. Never use an automatic `latest` updater.

## Development

The host needs the exact .NET SDK selected by `global.json`:

```bash
dotnet test tests/Shelfarr.Libation.Companion.Tests/Shelfarr.Libation.Companion.Tests.csproj
docker build -t shelfarr-libation-companion:test .
./tests/container-smoke.sh shelfarr-libation-companion:test
```

Release builds should pass `--build-arg APP_VERSION=<Shelfarr version>`. Empty
or omitted versions safely fall back to `0.0.0`; a leading `v` is removed.

The container smoke test creates fresh named volumes, runs with a non-default
numeric PUID/PGID, checks seeded Libation state ownership, verifies token
generation, verifies `no-new-privileges` and empty Linux capability sets,
rejects unsafe state-file symlinks and group/world-readable private state under
`CHOWN_ON_START=never`, restarts from correctly pre-owned volumes, rotates the
service IDs across representative nested state without following a symlink,
and exercises the image healthcheck plus bearer-protected state routes. It does
not contact Audible or use real credentials.

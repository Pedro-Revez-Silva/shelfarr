<p align="center">
  <img src="docs/logo.png" alt="Shelfarr" width="128" height="128">
</p>

<h1 align="center">Shelfarr</h1>

<p align="center">
  A self-hosted ebook and audiobook request and management system for the *arr ecosystem.
</p>

<p align="center">
  <a href="https://github.com/Pedro-Revez-Silva/shelfarr/blob/main/LICENSE">
    <img src="https://img.shields.io/github/license/Pedro-Revez-Silva/shelfarr" alt="License">
  </a>
  <a href="https://github.com/Pedro-Revez-Silva/shelfarr/actions/workflows/docker.yml">
    <img src="https://img.shields.io/github/actions/workflow/status/Pedro-Revez-Silva/shelfarr/docker.yml?label=build" alt="Build Status">
  </a>
  <a href="https://github.com/Pedro-Revez-Silva/shelfarr/pkgs/container/shelfarr">
    <img src="https://img.shields.io/badge/ghcr.io-shelfarr-blue?logo=docker" alt="Docker Image">
  </a>
</p>

---

Think Jellyseerr, but for books. Your users request ebooks and audiobooks; Shelfarr searches your indexers and direct sources, downloads the best release and delivers it to Audiobookshelf — the same request-and-automate workflow the video stack gets from Jellyseerr + Sonarr/Radarr.

<p align="center">
  <a href="https://shelfarr.org"><strong>Website</strong></a> &nbsp;·&nbsp;
  <a href="https://shelfarr.org/getting-started.html"><strong>Documentation</strong></a> &nbsp;·&nbsp;
  <a href="https://shelfarr.org/configuration.html">Settings Reference</a>
</p>

<p align="center">
  <img src="docs/screenshot-dashboard.png" alt="Shelfarr Dashboard" width="800">
</p>

## Features

- **Book Discovery** — Search millions of titles via Hardcover, Google Books and Open Library
- **Smart Acquisition** — Search Prowlarr, Jackett or Newznab/NZBHydra2 indexers; download via qBittorrent, Decypharr, Deluge, Transmission, SABnzbd or NZBGet
- **Direct Downloads** — Ebooks from Anna's Archive and Z-Library, public-domain audiobooks from LibriVox — no torrent client needed
- **Auto-Selection & Format Preferences** — Pick the best release automatically, scored by your preferred formats, bitrate and language
- **Auto-Processing** — Rename and organize files with path/filename templates, then deliver to Audiobookshelf, BookOrbit or Grimmory watched folders
- **Library Sync** — Automatic Audiobookshelf, BookOrbit or Grimmory scans after downloads complete
- **Manual Uploads** — Upload your own files to fulfill a request
- **Multi-User** — Role-based access with user requests and admin controls
- **Authentication** — TOTP-based 2FA with backup codes, plus OIDC/SSO (Authentik, Authelia, Keycloak, etc.)
- **Notifications** — In-app, Discord, Telegram and webhook notifications for request events
- **Download Routing** — Route specific indexers to specific clients, with priority ordering
- **REST API** — Scoped, per-user API tokens under `/api/v1`
- **Custom Acquisition Providers** — Trusted HTTP providers can contribute search results and resolve selected items into direct, torrent or usenet artifacts
- **Third-Party Store Offers (Beta)** — Surface legitimate DRM-free editions from supported sellers without handling checkout or payment data
- **Audible Backup (Beta)** — Sync purchased Audible titles, explicitly queue a one-time backup of eligible existing purchases, optionally back up future purchases automatically, and import them through the separately packaged Libation companion

### Beta integrations

The following integrations are opt-in and disabled by default:

- **Third-party stores** add a separate purchase-options section to a request. Shelfarr checks the seller's catalog, shows DRM-free formats, localized availability and an external purchase link, but never handles payment or treats an offer as a downloadable result. The first provider is eBooks.com. See [Third-party stores (Beta)](docs/drm-free-store-providers.md).
- **Audible Backup, powered by Libation** connects Shelfarr to an optional companion service running the unmodified, pinned [Libation](https://github.com/rmcrackan/Libation) CLI. Its Settings-style page separates Overview, Connection, Automation, and diagnostic Catalog concerns. After the first sync, Shelfarr asks whether to queue a conservative one-time backup of eligible existing purchases; the durable background batch and individual-title work are managed from the main Library while Libation processes one title at a time. Scheduled sync is optional, with a 24-hour default and an hourly option. Automatic backup for future purchases remains a separate opt-in. It is not an Audible store or general metadata provider. See [Audible Backup (Beta)](docs/audible-backup.md).

Both features are designed to preserve existing installations: upgrades add new, default-disabled configuration without changing existing providers or encryption keys. Review the linked guides before enabling a beta integration.

## Quick Start

### Docker (Recommended)

```bash
# 1. Create directory and download compose file
mkdir shelfarr && cd shelfarr
curl -O https://raw.githubusercontent.com/Pedro-Revez-Silva/shelfarr/main/docker-compose.example.yml
mv docker-compose.example.yml docker-compose.yml

# 2. Edit docker-compose.yml with your paths
#    - /path/to/audiobooks → your Audiobookshelf audiobooks folder
#    - /path/to/ebooks → your Audiobookshelf ebooks folder
#    - /path/to/downloads → your download client's completed folder
#    - Optionally set SHELFARR_VERSION in .env to pin Shelfarr and its companion
#      (use the OCI image version without the GitHub tag's leading "v")

# 3. Start
docker compose up -d
```

A secret key is auto-generated on first run and saved to the data volume.

The current Compose example also starts the internal Audible Backup companion, powered by Libation. It stays idle until an administrator enables the beta integration, exposes no host port, and requires no Audible account for users who leave it disabled. Existing installations must merge the companion service and volumes from the current Compose example once before enabling Audible Backup; see the [Audible Backup guide](docs/audible-backup.md#existing-installations).

Visit `http://localhost:5056` — the first user to register becomes admin.

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PUID` | `1000` | User ID for file permissions. Should match the owner of your mounted volumes |
| `PGID` | `1000` | Group ID for file permissions. Should match the group of your mounted volumes |
| `CHOWN_ON_START` | `auto` | Control startup ownership fixes for both standard containers. `auto` (default) adjusts only when needed, `always` fails on adjustment errors, and `never` skips `chown` calls for pre-permissioned/root-squashed volumes. The Audible companion still rejects group/world-accessible private state or credential/token files. |
| `HTTP_PORT` | `80` | Internal container port. Change if port 80 is in use (e.g., behind gluetun) |
| `RAILS_MASTER_KEY` | Auto-generated | Encryption key for secrets. Auto-generated on first run if not set |
| `RAILS_RELATIVE_URL_ROOT` | `/` | Base path for running behind a reverse proxy at a sub-path (e.g., `/shelfarr`) |
| `SHELFARR_VERSION` | `latest` | Pin both Shelfarr images to one OCI image version, without a leading `v` (for a GitHub release shown as `vX.Y.Z`, use `X.Y.Z`) |
| `LIBATION_BOOKS_PATH` | Docker named volume | Optional host path for retained Audible backup copies; useful for large libraries |
| `DB_ADAPTER` | `sqlite3` | Choose the database adapter. Options: `sqlite3` or `postgresql`. Default is `sqlite3`. |
| `DB_HOST` | | Required when `DB_ADAPTER=postgresql`: The PostgreSQL server hostname. |
| `DB_PORT` | `5432` | Optional when `DB_ADAPTER=postgresql`: The PostgreSQL server port. |
| `DB_USERNAME` | | Required when `DB_ADAPTER=postgresql`: The PostgreSQL username. |
| `DB_PASSWORD` | | Required when `DB_ADAPTER=postgresql`: The PostgreSQL password. |
| `DB_DATABASE` | `shelfarr_production` | Optional when `DB_ADAPTER=postgresql`: The primary database name. |

Audible Backup additionally requires the audiobook output filesystem to support advisory locks, hard links within that same mount, and Unix mode changes. Keep Shelfarr's `.shelfarr-staging` directory on the audiobook output filesystem and run the documented preflight before connecting Audible. mergerfs/libfuse mounts with a `umask=` mode override need a compatible underlying bind or a coordinated mount correction; do not bypass the check. See the [Audible Backup storage requirements and filesystem preflight](docs/audible-backup.md#preflight-the-audiobook-filesystem).

Filesystem race defenses assume every process running as Shelfarr's `PUID` is trusted. A malicious process with the same UID can modify any library file that Shelfarr itself can modify; isolate untrusted download tools under a different UID and grant only the narrow shared-directory access they need.

Example with custom port:
```yaml
environment:
  - HTTP_PORT=8080
ports:
  - "5056:8080"  # Map to the custom port
```

Example running at a sub-path (e.g., behind a reverse proxy at `/shelfarr`):
```yaml
environment:
  - RAILS_RELATIVE_URL_ROOT=/shelfarr
```

#### Settings Environment Overrides

OIDC and webhook settings can be managed by environment variables. Use `SHELFARR_SETTING_` plus the uppercased setting key, for example `SHELFARR_SETTING_OIDC_CLIENT_SECRET` or `SHELFARR_SETTING_WEBHOOK_URL`.

Supported setting keys:

`oidc_enabled`, `oidc_auto_redirect`, `oidc_provider_name`, `oidc_issuer`, `oidc_client_id`, `oidc_client_secret`, `oidc_scopes`, `oidc_link_existing_users`, `oidc_auto_create_users`, `oidc_default_role`, `webhook_enabled`, `webhook_url`, `webhook_token`, `webhook_events`, `webhook_topic`.

### PostgreSQL Support

By default, Shelfarr uses SQLite, which requires zero configuration and is highly portable. If you want to use PostgreSQL instead (e.g. for high availability or to scale out), you can pass the database environment variables:

```yaml
services:
  shelfarr:
    environment:
      - DB_ADAPTER=postgresql
      - DB_HOST=db
      - DB_PORT=5432
      - DB_USERNAME=shelfarr
      - DB_PASSWORD=my_secure_password
      - DB_DATABASE=shelfarr_production

  db:
    image: postgres:16
    environment:
      - POSTGRES_USER=shelfarr
      - POSTGRES_PASSWORD=my_secure_password
      - POSTGRES_DB=shelfarr_production
```

#### Migrating from SQLite to PostgreSQL
If you already use SQLite and want to switch to PostgreSQL, you can migrate your existing data once the empty PostgreSQL schema is initialized.

##### Phase 1: Initialize the PostgreSQL Schema
1. Start Shelfarr configured with `DB_ADAPTER=postgresql` and your PostgreSQL connection credentials.
2. Shelfarr will automatically run the standard Rails migrations on boot, creating the empty tables and indexes in PostgreSQL.

##### Phase 2: Run the Migration using `pgloader`
Because `pgloader` uses an SBCL Lisp runtime that can conflict with Docker emulation or preloaded allocators (like `jemalloc`), running the migration directly on your host machine (or Mac) is the most reliable way:

1. Expose the PostgreSQL port `5432` to your host in your database compose setup (e.g., `ports: - "5432:5432"`).
2. Install `pgloader` on your host machine (e.g., `brew install pgloader` on macOS).
3. Run `pgloader` from your project directory, pointing to the volume-mounted SQLite file:
   ```bash
   pgloader \
     --with "data only" \
     --with "truncate" \
     --with "disable triggers" \
     --with "workers = 4" \
     --with "concurrency = 2" \
     --cast "type integer when (= 1 precision) to boolean drop typemod keep default keep not null" \
     sqlite://./data/production.sqlite3 \
     postgresql://shelfarr:my_secure_password@localhost:5432/shelfarr_production
   ```

Always verify your data in the Shelfarr web UI before deleting the old `.sqlite3` file!

Example with the client secret supplied by your deployment secret store:
```yaml
services:
  shelfarr:
    environment:
      SHELFARR_SETTING_OIDC_ENABLED: "true"
      SHELFARR_SETTING_OIDC_ISSUER: "https://auth.example.com"
      SHELFARR_SETTING_OIDC_CLIENT_ID: "shelfarr"
      SHELFARR_SETTING_OIDC_CLIENT_SECRET: "${OIDC_CLIENT_SECRET}"
```

The env value takes precedence while set and is cast using the setting type. Nothing is written back to the database; removing the variable falls back to the stored value, or the default if none exists. Env-managed keys are read-only in Admin -> Settings. Other settings are not overridable, and unsupported `SHELFARR_SETTING_*` variables are ignored with a boot-time warning.

### Configuration

After logging in, go to **Admin → Settings**:

| Setting | Description |
|---------|-------------|
| Indexer | Prowlarr, Jackett or Newznab/NZBHydra2 URL + API key for searches |
| Download Clients | qBittorrent, Decypharr, Deluge, Transmission, SABnzbd or NZBGet (Admin → Download Clients) |
| Output Paths | Where to place completed audiobooks/ebooks |
| Library Platform | Audiobookshelf URL + API key, or BookOrbit/Grimmory URL + username/password for library integration (optional) |

📖 **[Read the docs](https://shelfarr.org/getting-started.html)** for a full install and setup walkthrough, plus a **[settings reference](https://shelfarr.org/configuration.html)** describing every option, its type and default.

### OIDC/SSO Setup

Shelfarr supports OpenID Connect for single sign-on with identity providers like Authentik, Authelia, Keycloak, and others.

1. Create an OIDC client in your identity provider:
   - **Redirect URI**: `http://your-shelfarr-url/auth/oidc/callback`
   - **Scopes**: `openid profile email`

2. In **Admin → Settings → OIDC/SSO Authentication**:
   - Enable OIDC
   - Enter your provider's issuer URL (e.g., `https://auth.example.com`)
   - Enter the client ID and secret from step 1
   - Optionally enable auto-creation of new users

| Setting | Description |
|---------|-------------|
| Oidc Enabled | Enable/disable SSO login |
| Oidc Provider Name | Label shown on login button (e.g., "Authentik") |
| Oidc Issuer | Your identity provider's issuer URL |
| Oidc Client Id | Client ID from your provider |
| Oidc Client Secret | Client secret from your provider |
| Oidc Auto Create Users | Auto-create accounts on first login |
| Oidc Default Role | Role for auto-created users (user/admin) |

## Integrations

| Service | Purpose |
|---------|---------|
| **Open Library** / **Google Books** / **Hardcover** | Book metadata and search |
| **Prowlarr** / **Jackett** / **NZBHydra2** | Indexer management |
| **qBittorrent**, **Decypharr**, **Deluge**, **Transmission** | Torrent downloads |
| **SABnzbd**, **NZBGet** | Usenet downloads |
| **Anna's Archive** / **Z-Library** | Direct ebook downloads |
| **LibriVox** | Public-domain audiobook downloads |
| **eBooks.com** *(Beta)* | External DRM-free ebook offers; checkout remains with the seller |
| **Libation** *(Beta)* | Optional Audible owned-library backup companion |
| **Audiobookshelf** / **BookOrbit** / **Grimmory** | Library management |
| **Discord** / **Telegram** / **Webhooks** | Notifications |

## Requirements

- Docker
- At least one way to find books:
  - An indexer — Prowlarr, Jackett or Newznab/NZBHydra2 — plus a download client (qBittorrent, Decypharr, Deluge, Transmission, SABnzbd or NZBGet), **and/or**
  - A direct source — Anna's Archive or Z-Library (ebooks), LibriVox (audiobooks), **and/or**
  - The beta eBooks.com store integration for external purchase and manual import of DRM-free ebooks
- Audiobookshelf, BookOrbit or Grimmory (optional, for library integration)

Audible Backup is independent of request acquisition: the optional Libation companion can preserve titles already owned by the connected Audible account without configuring an indexer or store provider.

BookOrbit support uses BookOrbit's current `/api/v1` endpoints for library listing, inventory sync, and scan triggers. Shelfarr still delivers files through configured output paths; direct Book Dock upload/finalize is not implemented because BookOrbit does not currently publish a stable external API for that workflow.

Grimmory support uses Grimmory's `/api/v1` endpoints for library listing, inventory sync and refresh triggers. Shelfarr delivers files to its configured output paths and asks Grimmory to rescan; Grimmory BookDrop upload/finalize is not used.

## Development

```bash
# Install Ruby 3.3.6 via rbenv
brew install rbenv ruby-build
rbenv install 3.3.6

# Clone and setup
git clone https://github.com/Pedro-Revez-Silva/shelfarr.git
cd shelfarr
bundle install
bin/rails db:setup

# Start development server
bin/dev
```

### Local Quality Gate

The repo includes a lightweight local quality gate powered by `lefthook`.

```bash
# Install hooks
bundle exec lefthook install

# Quiet staged-file check plus the 90% coverage gate used by pre-commit
bin/quality commit --staged

# Quiet full check plus coverage gate used by pre-push
bin/quality push

# Run coverage on demand
bin/quality coverage
bin/quality coverage --staged

# Run targeted mutation testing on covered service/model tests
bin/quality mutant --all
bin/quality mutant SettingsService*

# Run the full repo sweep
bin/quality deep
```

Passing runs stay quiet. On failure, the command prints only the relevant tool output.

Mutation testing is opt-in per test class. Add `cover "YourConstant*"` to logic-heavy Minitest classes you want `mutant` to evaluate.

## License

[GPL-3.0](LICENSE)

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
- **Auto-Processing** — Rename and organize files with path/filename templates, then deliver to Audiobookshelf or BookOrbit watched folders
- **Library Sync** — Automatic Audiobookshelf or BookOrbit scans after downloads complete
- **Manual Uploads** — Upload your own files to fulfill a request
- **Multi-User** — Role-based access with user requests and admin controls
- **Authentication** — TOTP-based 2FA with backup codes, plus OIDC/SSO (Authentik, Authelia, Keycloak, etc.)
- **Notifications** — In-app, Discord, Telegram and webhook notifications for request events
- **Download Routing** — Route specific indexers to specific clients, with priority ordering
- **REST API** — Scoped, per-user API tokens under `/api/v1`
- **Custom Acquisition Providers** — Trusted HTTP providers can contribute search results and resolve selected items into direct, torrent or usenet artifacts

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

# 3. Start
docker compose up -d
```

A secret key is auto-generated on first run and saved to the data volume.

Visit `http://localhost:5056` — the first user to register becomes admin.

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PUID` | `1000` | User ID for file permissions. Should match the owner of your mounted volumes |
| `PGID` | `1000` | Group ID for file permissions. Should match the group of your mounted volumes |
| `CHOWN_ON_START` | `auto` | Control startup ownership fixes for mounted storage. `auto` (default) attempts to `chown`, but continues if unsupported (eg NFS root-squash). `always` fails on `chown` errors. `never` skips all `chown` calls (use only if volume is pre-permissioned). |
| `HTTP_PORT` | `80` | Internal container port. Change if port 80 is in use (e.g., behind gluetun) |
| `RAILS_MASTER_KEY` | Auto-generated | Encryption key for secrets. Auto-generated on first run if not set |
| `RAILS_RELATIVE_URL_ROOT` | `/` | Base path for running behind a reverse proxy at a sub-path (e.g., `/shelfarr`) |

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

### Configuration

After logging in, go to **Admin → Settings**:

| Setting | Description |
|---------|-------------|
| Indexer | Prowlarr, Jackett or Newznab/NZBHydra2 URL + API key for searches |
| Download Clients | qBittorrent, Decypharr, Deluge, Transmission, SABnzbd or NZBGet (Admin → Download Clients) |
| Output Paths | Where to place completed audiobooks/ebooks |
| Library Platform | Audiobookshelf URL + API key, or BookOrbit URL + username/password for library integration (optional) |

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
| **Audiobookshelf** / **BookOrbit** | Library management |
| **Discord** / **Telegram** / **Webhooks** | Notifications |

## Requirements

- Docker
- At least one way to find books:
  - An indexer — Prowlarr, Jackett or Newznab/NZBHydra2 — plus a download client (qBittorrent, Decypharr, Deluge, Transmission, SABnzbd or NZBGet), **and/or**
  - A direct source — Anna's Archive or Z-Library (ebooks), LibriVox (audiobooks)
- Audiobookshelf or BookOrbit (optional, for library integration)

BookOrbit support uses BookOrbit's current `/api/v1` endpoints for library listing, inventory sync, and scan triggers. Shelfarr still delivers files through configured output paths; direct Book Dock upload/finalize is not implemented because BookOrbit does not currently publish a stable external API for that workflow.

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

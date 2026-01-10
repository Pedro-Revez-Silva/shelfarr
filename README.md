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

**The missing piece**: The video stack has Jellyseerr + Sonarr/Radarr + Jellyfin. For books, only the library exists (Audiobookshelf). Shelfarr fills the gap—think Readarr meets Jellyseerr, but for books that actually works.

<p align="center">
  <img src="docs/screenshot-dashboard.png" alt="Shelfarr Dashboard" width="800">
</p>

## Features

- **Book Discovery** — Search millions of books via Open Library
- **Smart Acquisition** — Searches Prowlarr indexers, downloads via qBittorrent or SABnzbd
- **Anna's Archive** — Direct ebook downloads without needing a torrent client
- **Auto-Processing** — Organizes files by author/title and delivers to Audiobookshelf
- **Library Sync** — Automatic library scans after downloads complete
- **Multi-User** — Role-based access with user requests and admin controls
- **Two-Factor Auth** — TOTP-based 2FA with backup codes
- **OIDC/SSO** — Single sign-on via OpenID Connect (Authentik, Authelia, Keycloak, etc.)
- **Notifications** — In-app notifications when your books are ready
- **Multiple Download Clients** — Configure multiple clients with priority ordering

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
docker-compose up -d
```

A secret key is auto-generated on first run and saved to the data volume.

Visit `http://localhost:5056` — the first user to register becomes admin.

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PUID` | `1000` | User ID for file permissions. Run `id -u` to find yours |
| `PGID` | `1000` | Group ID for file permissions. Run `id -g` to find yours |
| `HTTP_PORT` | `80` | Internal container port. Change if port 80 is in use (e.g., behind gluetun) |
| `RAILS_MASTER_KEY` | Auto-generated | Encryption key for secrets. Auto-generated on first run if not set |

Example with custom port:
```yaml
environment:
  - HTTP_PORT=8080
ports:
  - "5056:8080"  # Map to the custom port
```

### Configuration

After logging in, go to **Admin → Settings**:

| Setting | Description |
|---------|-------------|
| Prowlarr URL + API Key | For indexer searches |
| Download Client | qBittorrent or SABnzbd connection |
| Output Paths | Where to place completed audiobooks/ebooks |
| Audiobookshelf | URL + API key for library integration (optional) |

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
| **Open Library** | Book metadata and search |
| **Anna's Archive** | Direct ebook downloads |
| **Prowlarr** | Indexer management |
| **qBittorrent** | Torrent downloads |
| **SABnzbd** | Usenet downloads |
| **Audiobookshelf** | Library management |

## Requirements

- Docker
- At least one of:
  - Prowlarr (for indexer searches)
  - Anna's Archive (for direct ebook downloads)
- Download client (qBittorrent or SABnzbd) — optional if using Anna's Archive for ebooks
- Audiobookshelf (optional, for library integration)

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

## License

[GPL-3.0](LICENSE)

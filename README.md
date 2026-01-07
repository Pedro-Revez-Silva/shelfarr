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
  <a href="https://github.com/Pedro-Revez-Silva/shelfarr/releases">
    <img src="https://img.shields.io/github/v/release/Pedro-Revez-Silva/shelfarr" alt="Release">
  </a>
  <a href="https://hub.docker.com/r/psilva999/shelfarr">
    <img src="https://img.shields.io/docker/pulls/psilva999/shelfarr" alt="Docker Pulls">
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

### Configuration

After logging in, go to **Admin → Settings**:

| Setting | Description |
|---------|-------------|
| Prowlarr URL + API Key | For indexer searches |
| Download Client | qBittorrent or SABnzbd connection |
| Output Paths | Where to place completed audiobooks/ebooks |
| Audiobookshelf | URL + API key for library integration (optional) |

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

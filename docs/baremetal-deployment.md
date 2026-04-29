# Bare-Metal Deployment

This guide covers running Shelfarr natively (no Docker) on any Linux server with SSH access. The app runs under a regular user account, listens on a configurable port, and integrates with the torrent and Usenet clients already on your system.

---

## Prerequisites

- A Linux server with SSH access
- `git` (available on most Linux servers)
- `rbenv` installed in your home directory (see [Installing rbenv](#installing-rbenv))
- An available port for Shelfarr's web UI

---

## Installing rbenv

Most Linux servers don't ship with Ruby 3.3. Install rbenv in your home directory once:

```bash
git clone https://github.com/rbenv/rbenv.git ~/.rbenv
git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build

echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bashrc
echo 'eval "$(rbenv init -)"' >> ~/.bashrc
source ~/.bashrc
```

Verify it worked:

```bash
rbenv --version
```

---

## First-time Installation

```bash
# 1. Clone the repository
git clone https://github.com/pedro-revez-silva/shelfarr.git ~/shelfarr
cd ~/shelfarr

# 2. Run the install script
bin/shelfarr install
```

The script will ask for:

1. **Port** — the port Shelfarr listens on (any available port above 1024, e.g. `4567`). Ensure this port is reachable from your network or reverse proxy.
2. **Host URL** *(optional)* — your public URL, e.g. `https://shelfarr.example.com`. Leave blank and set it later with `bin/shelfarr install --reconfigure`.

Everything else (secret keys, database, assets) is handled automatically.

Alternatively, pass values as flags to skip the prompts:

```bash
bin/shelfarr install --port 4567 --host https://shelfarr.example.com
```

The install script saves configuration to `.baremetal-config` (automatically loaded by all `bin/shelfarr` subcommands — no file editing required).

---

## Configuration

All configuration is stored in `.baremetal-config`, generated during install. To change the port or host URL at any time:

```bash
bin/shelfarr install --reconfigure
```

Or pass specific flags to update only what you need:

```bash
bin/shelfarr install --reconfigure --port 5000
bin/shelfarr install --reconfigure --host https://shelfarr.example.com
```

Your `SECRET_KEY_BASE` is preserved automatically across reconfiguration.

---

## Starting and Stopping

```bash
bin/shelfarr start    # start in background, logs to log/production.log
bin/shelfarr stop     # graceful shutdown
bin/shelfarr restart  # stop + start
```

Check status:

```bash
bin/shelfarr status
```

Check the logs:

```bash
tail -f ~/shelfarr/log/production.log
```

Confirm the server is up:

```bash
curl http://localhost:4567/up
# → {"status":"ok"}
```

> **Compatibility note:** The legacy `bin/baremetal-start`, `bin/baremetal-stop`, `bin/baremetal-restart`, `bin/baremetal-update`, and `bin/baremetal-install` commands still work — they delegate to `bin/shelfarr`. Existing cron entries don't need to change.

---

## Auto-start on Slot Reboot

Add a cron entry so Shelfarr restarts automatically if the server reboots:

```bash
crontab -e
```

Add this line (adjust the path if you cloned elsewhere):

```
@reboot cd ~/shelfarr && bin/shelfarr start >> log/production.log 2>&1
```

---

## Post-install Settings

Open Shelfarr in your browser and go to **Settings → Paths**. Update the following to match your server's directory layout:

| Setting | Example value |
|---------|---------------|
| **Audiobook output path** | `/home/youruser/audiobooks` |
| **Ebook output path** | `/home/youruser/ebooks` |
| **Download path (remote)** | Path where qBittorrent/SABnzbd saves completed files |
| **Download path (local)** | Same as above (no Docker path remapping needed on bare-metal) |

Then configure **Settings → Integrations** to point at your Prowlarr, qBittorrent, SABnzbd, and Audiobookshelf instances. Common default URLs:

- Prowlarr: `http://localhost:9696`
- qBittorrent: `http://localhost:8080`
- SABnzbd: `http://localhost:8085`
- Audiobookshelf: `http://localhost:13378`

---

## Updating

```bash
cd ~/shelfarr
bin/shelfarr update
```

This pulls the latest code, updates gems, recompiles assets, runs any new migrations, and restarts the server.

---

## Troubleshooting

### Server won't start

```bash
# Check the last 50 log lines
tail -50 ~/shelfarr/log/production.log
```

Common causes:
- **Port already in use** — run `bin/shelfarr install --reconfigure` to pick a different port
- **No config file** — run `bin/shelfarr install` first
- **rbenv not on PATH** — run `source ~/.bashrc` then retry

### Stale PID file after a crash

```bash
rm ~/shelfarr/tmp/pids/shelfarr.pid
bin/shelfarr start
```

### Reset encryption keys (data loss warning)

If you lose `storage/.encryption_keys`, encrypted settings (API keys) will be unreadable. Restore it from a backup, or delete the database and re-run `bin/baremetal-install` to start fresh:

```bash
rm ~/shelfarr/storage/production*.sqlite3
bin/shelfarr install
```

### View running jobs

Solid Queue runs inside the Puma process (`SOLID_QUEUE_IN_PUMA=1`). Check job activity in **Shelfarr → Admin → Queue** (admin users only).

---

## Directory Layout

After install, the important directories are:

```
~/shelfarr/
├── .baremetal-config      # generated configuration (gitignored, keep safe)
├── log/production.log     # application log
├── storage/
│   ├── production.sqlite3 # main database
│   ├── .encryption_keys   # auto-generated encryption keys (keep safe!)
│   └── ...                # Active Storage uploads, cache, queue DBs
└── tmp/pids/shelfarr.pid  # PID file while server is running
```

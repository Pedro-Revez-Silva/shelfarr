---
name: verify-shelfarr
description: Drive the Shelfarr web UI from an isolated worktree, sign in through the form, and capture proof. Use for a booted check of sign-in, Admin, search, requests, or library.
---

# Verify Shelfarr

Drive the Shelfarr web UI the way a person does. Launch a fresh worktree, sign in by typing into the form, and save proof. Read [features/README.md](features/README.md) before leaving the sign-in path.

Ruby 3.3.6, Bundler, libvips, and Chrome must already be installed. Chrome is `google-chrome` on `PATH`, or set `CHROME_BIN` to the binary. The helper uses the Ruby standard library only.

## Launch

Pick a commit and a clone that is not already the worktree you are about to create. `REPO` is that clone. The worktree gets its own `storage/` directory. Never point `PORT` at an app you did not start in this run.

```bash
RUN_ID="shelfarr-verify-$$"
EVIDENCE="/tmp/shelfarr-verify/${RUN_ID}"
WT="/tmp/shelfarr-worktrees/${RUN_ID}"
mkdir -p "$EVIDENCE" /tmp/shelfarr-worktrees
git -C "$REPO" fetch origin "$HEAD_BRANCH"
git -C "$REPO" worktree add --detach "$WT" "$HEAD_SHA"
test ! -e "$WT/storage/development.sqlite3"
cd "$WT"
bundle install
bin/rails db:prepare > "$EVIDENCE/db-prepare.log"
bin/rails runner 'abort "seeded admin missing" unless User.exists?(username: "admin") && User.find_by!(username: "admin").admin?'
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
PORT="$PORT" bin/dev > "$EVIDENCE/dev.log" 2>&1 < /dev/null &
echo $! > "$EVIDENCE/foreman.pid"
```

`bin/rails db:prepare` creates the development databases and loads `db/seeds.rb` when the primary database is new. The seed creates username `admin` with password `Password1234`. That first user is an admin.

Ready means all three checks pass. Give the boot 180 seconds.

```bash
PID="$(cat "$EVIDENCE/foreman.pid")"
ready=0
for _ in $(seq 1 90); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/up" || true)"
  if kill -0 "$PID" && grep -q "Listening on" "$EVIDENCE/dev.log" && [ "$code" = "200" ] && [ -s "$WT/app/assets/builds/tailwind.css" ]; then
    ready=1
    break
  fi
  sleep 2
done
test "$ready" = 1
BASE="http://127.0.0.1:${PORT}"
STATE="$EVIDENCE/drive-state.json"
```

`grep` looks for the Puma line `Listening on`. `GET /up` must return 200. `app/assets/builds/tailwind.css` must be a non-empty file produced by `bin/rails tailwindcss:watch` in `Procfile.dev`.

Record `$PID`, `$PORT`, `$BASE`, `$WT`, `$EVIDENCE`, and `$STATE` for the rest of the run.

## Doctor

Run this before driving whenever the page looks wrong. It only reads process, log, HTTP, and file state.

```bash
PID="$(cat "$EVIDENCE/foreman.pid")"
kill -0 "$PID"
grep -q "Listening on" "$EVIDENCE/dev.log"
test "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/up")" = "200"
test -s "$WT/app/assets/builds/tailwind.css"
ps -o pid=,ppid=,cmd= -p "$PID" --ppid "$PID"
ss -ltnp "sport = :${PORT}" || true
```

The listen socket for `$PORT` must belong to `$PID` or a child of that PID. A 200 from another port is a different app. Stop if the seeded admin user is missing or is not an admin.

```bash
cd "$WT"
bin/rails runner 'user = User.find_by(username: "admin"); abort "admin missing" unless user&.admin?; puts user.username'
```

## Drive

The browser helper is [drive.rb](drive.rb). It types with key events and clicks visible controls. It does not set `document.cookie` and it does not call `sign_in_as`.

Use a 1280 by 900 viewport. The desktop nav is hidden below 1024px, so a narrow window hides Search, Requests, Library, and Admin.

```bash
ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" start --state "$STATE" --width 1280 --height 900
ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" open --state "$STATE" --url "$BASE/session/new"
ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "Sign in"
ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" fill --state "$STATE" --placeholder "Enter your username" --text admin
ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" fill --state "$STATE" --placeholder "Enter your password" --text Password1234
ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" click --state "$STATE" --role submit --name "Sign in"
ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "Requests" --timeout 30
ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" click --state "$STATE" --role link --name "Admin"
ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "Admin Dashboard" --timeout 30
ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" shot --state "$STATE" --path "$EVIDENCE/admin.png"
```

`fill` exits non-zero when the field value does not match the typed text. Stop there. A second guess can lock the account.

Confirm the session row in the worktree database. The `user_agent` must be the Chrome this run started.

```bash
cd "$WT"
bin/rails runner 'row = Session.joins(:user).where(users: { username: "admin" }).order(:id).last
abort "no admin session" if row.nil?
puts [row.id, row.user.username, row.user.role, row.ip_address, row.user_agent].join("\t")' | tee "$EVIDENCE/admin-session.txt"
```

Other pages are in the feature map. Stay inside this same browser session. Do not open a second sign-in.

## Evidence

Save proof under `$EVIDENCE`, which sits outside the worktree.

- `admin.png` shows the heading `Admin Dashboard` and the Admin nav link.
- `admin-session.txt` has one sessions row for username `admin`, including the browser user agent.
- `dev.log` contains `Listening on`.
- `db-prepare.log` is the prepare output.

A screenshot of a page reached by writing a signed `session_id` cookie is not proof. The sessions row has to come from the form POST.

## Cleanup

Stop the Chrome process recorded in the state file, then stop the foreman PID this launch started. Kill that process group. Do not use `pkill`, `killall`, or a match on `puma` or `rails`.

```bash
ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" stop --state "$STATE"
PID="$(cat "$EVIDENCE/foreman.pid")"
kill -TERM -"$PID"
for _ in $(seq 1 20); do
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.5
done
kill -KILL -"$PID" 2>/dev/null || true
test -s "$EVIDENCE/admin.png"
test -s "$EVIDENCE/admin-session.txt"
cd /
git -C "$REPO" worktree remove --force "$WT"
test ! -d "$WT"
test -s "$EVIDENCE/admin.png"
```

Removing the worktree deletes that worktree's `storage/`. The screenshot and the session note stay in `$EVIDENCE`.

## Helpers

`drive.rb` is executable. Invoke it with system Ruby from any directory. `--state` is the JSON file written by `start`.

- `start --state PATH --width 1280 --height 900` launches headless Chrome and writes the state file. The PID in that file is the process `stop` kills.
- `open --state PATH --url URL` loads that URL and waits until the document is complete.
- `fill --state PATH --placeholder TEXT --text VALUE` clicks the input with that placeholder, types `VALUE`, and exits non-zero unless the field value equals `VALUE`.
- `click --state PATH --role link|submit --name TEXT` clicks the visible link or submit control with that exact label.
- `wait --state PATH --text TEXT --timeout SECONDS` exits 0 when `innerText` contains `TEXT`. The default timeout is 20 seconds.
- `shot --state PATH --path FILE` writes a PNG. Parent directories are created. This command never deletes an existing proof file.
- `location --state PATH` prints `location.href`.
- `stop --state PATH` sends `TERM` to the Chrome process group from `start`. A missing or already exited PID still exits 0.

When the Shelfarr web UI changes, update this skill and the feature map with `/maintain-verification-skill`.

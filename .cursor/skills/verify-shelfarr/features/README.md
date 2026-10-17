# Shelfarr verification map

This directory is the maintained source for verifying the Shelfarr web UI. Read this index, then follow the feature file for the page you are proving.

## Baseline preconditions

- Launch Shelfarr with the commands in `../SKILL.md`.
- Keep `BASE`, `EVIDENCE`, `STATE`, and `WT` from that launch.
- The worktree database has the seeded admin user from `db/seeds.rb`.
- Sign in once through the form before any other feature.
- Run `drive.rb` from `../SKILL.md` against `$STATE`.
- Drive only the Chrome process and the foreman PID this run started.

## Driving conventions

- Start each feature after the sign-in recipe unless that feature is sign-in itself.
- The viewport is 1280 by 900 so the desktop nav is visible.
- Prefer the placeholder, the visible link name, and the submit value named in the feature file.
- Treat every command as literal. Keep the quoted placeholder and the password text unchanged.
- One successful sign-in per worktree. A failed attempt can lock `admin`.
- Leave files in `$EVIDENCE` in place during cleanup.

## Proof and skip reporting

- Capture the action and the resulting state, not only the final screen.
- UI proof is a PNG plus the page text the matching `wait` command required.
- Sign-in proof also includes the sessions row for `admin` and its user agent.
- Record the feature file name and the entry point with the artifact.
- Report an unreachable path with the command that failed and the unmet precondition.
- A different page does not verify a path you could not open.

## Feature entry contract

Each feature file starts with an H1 and one paragraph of user-visible behavior. It then uses these four H2 sections in order.

1. `Sub-features` lists short IDs with one line for each behavior.
2. `How to get to it (user POV)` lists every user entry point.
3. `Driving it with the browser` starts with `Preconditions:` and pairs each action with a command and an observable result.
4. `Gotchas` lists traps that can waste or invalidate a run.

## Features

- [Sign in](./sign-in.md) covers the password form for the seeded admin.
- [Admin](./admin.md) covers the Admin Dashboard after that sign-in.
- [Search](./search.md) covers the empty search page.
- [Requests](./requests.md) covers the empty requests list.
- [Library](./library.md) covers the empty library.
- [Settings](./settings.md) covers changing one field and the stored row.

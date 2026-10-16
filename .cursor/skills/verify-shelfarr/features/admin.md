# Admin

Admin shows the Admin Dashboard for the seeded admin, with user and book counts, system health, and quick links.

## Sub-features

- `admin-open` opens the dashboard from the nav.
- `admin-heading` shows `Admin Dashboard`.
- `admin-links` shows Quick Links, including Settings and Manage Users.

## How to get to it (user POV)

- Choose `Admin` in the desktop nav after signing in.
- Open `$BASE/admin` after signing in.
- Open `$BASE/admin` while signed out, then complete the sign-in form. Shelfarr returns to this page.

## Driving it with the browser

Preconditions:

- The sign-in recipe in [sign-in.md](./sign-in.md) has just succeeded in this browser.
- `$EVIDENCE/admin-session.txt` already contains a sessions row for `admin`.
- The viewport is 1280 by 900.

- **Open Admin.** Choose the `Admin` nav link. Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" click --state "$STATE" --role link --name "Admin"` and `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "Admin Dashboard" --timeout 30`. The heading reads `Admin Dashboard`.
- **Confirm the address.** Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" location --state "$STATE"`. The path is `/admin`.
- **See the dashboard blocks.** Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "System Health"` and `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "Quick Links"`. Both headings are visible.
- **Proof.** Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" shot --state "$STATE" --path "$EVIDENCE/admin.png"`. The PNG shows `Admin Dashboard` and the Admin nav link.

## Gotchas

- The Admin nav link is rendered only for an admin. The seeded first user is that admin. A non-admin account has no Admin link.
- `Check for Updates` and `Run Check` call out of this empty install. Leave both unclicked.
- Quick Links include Settings. Opening Settings is enough to see the page. Do not change a setting in this skill.
- The purple `Admin` badge next to the name is not the nav link. The click command targets the visible link named `Admin`.
- A direct visit to `$BASE/admin` while signed out is the return-to entry in [sign-in.md](./sign-in.md). Use the nav click above when this browser is already signed in.

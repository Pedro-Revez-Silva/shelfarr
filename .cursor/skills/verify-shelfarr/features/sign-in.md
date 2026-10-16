# Sign in

Sign in lets the seeded admin open Shelfarr by typing a username and password. A successful sign-in lands on the home page and shows Search, Requests, and Library.

## Sub-features

- `sign-in-open` shows the password form.
- `sign-in-submit` accepts `admin` and `Password1234`.
- `sign-in-land` shows the signed-in nav.

## How to get to it (user POV)

- Open `$BASE/session/new`.
- Choose the `Sign in` link in the top bar when no one is signed in.
- Open a signed-in page such as `$BASE/admin` while signed out. Shelfarr returns to the password form and comes back to that page after a successful sign-in.

## Driving it with the browser

Preconditions:

- Launch and Doctor from `../SKILL.md` passed.
- `$BASE/session/new` is the password form, with the placeholder `Enter your username` and the placeholder `Enter your password`.
- No browser for this run is signed in yet.

- **Open the form.** Visit the sign-in page. Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" open --state "$STATE" --url "$BASE/session/new"` and `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "Sign in"`. The heading reads `Sign in` and the submit value is `Sign in`.
- **Type the username.** Click the username field and type `admin`. Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" fill --state "$STATE" --placeholder "Enter your username" --text admin`. The command exits 0 only when that field's value is `admin`.
- **Type the password.** Click the password field and type `Password1234`. Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" fill --state "$STATE" --placeholder "Enter your password" --text Password1234`. The command exits 0 only when that field's value is `Password1234`.
- **Submit.** Choose `Sign in`. Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" click --state "$STATE" --role submit --name "Sign in"` and `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "Requests" --timeout 30`. The nav shows `Requests`.
- **Confirm the session row.** Read the newest sessions row for `admin`. Run `cd "$WT" && bin/rails runner 'row = Session.joins(:user).where(users: { username: "admin" }).order(:id).last; abort "no admin session" if row.nil?; puts [row.id, row.user.username, row.user.role, row.ip_address, row.user_agent].join("\t")' | tee "$EVIDENCE/admin-session.txt"`. The line contains `admin` and the Chrome user agent from this run.

## Gotchas

- `SessionsController` allows 10 creates in 3 minutes and then answers `Try again later.`
- Five bad passwords lock `admin`. Stop after `fill` exits non-zero. Do not submit a second guess.
- The username is stored in lowercase. Type `admin`.
- The development seed is the only source of `Password1234`. A missing admin user means `db:prepare` did not seed. Stop and fix launch.
- With authentication disabled, the password field is absent and the submit value is `Continue`. A fresh seed keeps authentication enabled.
- With OIDC auto-redirect enabled, `$BASE/session/new` leaves the password form unless the URL includes `local=1`. A fresh seed leaves OIDC off.
- Writing a signed `session_id` cookie, or calling `sign_in_as`, skips this form. That session does not prove sign-in.
- Below 1024px the signed-in links sit behind `Toggle navigation menu`. Keep the 1280 by 900 viewport.

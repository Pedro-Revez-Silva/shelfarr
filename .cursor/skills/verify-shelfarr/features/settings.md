# Settings

Settings lets an admin change one stored preference. Max Retries starts at 10, saves on its own, and the stored row becomes 11.

## Sub-features

- `settings-open` opens Settings from Admin.
- `settings-edit` changes Max Retries from 10 to 11.
- `settings-row` shows the stored `max_retries` row is 11.

## How to get to it (user POV)

- Choose `Admin`, then `Settings` under Quick Links.
- Open `$BASE/admin/settings` after signing in.
- Open `$BASE/admin/settings#system` to land on Queue & System, where Max Retries is.

## Driving it with the browser

Preconditions:

- The sign-in recipe in [sign-in.md](./sign-in.md) has succeeded in this browser.
- The dashboard from [admin.md](./admin.md) is available in this same browser.
- `db:prepare` seeded settings, so the `max_retries` row is 10.
- The viewport is 1280 by 900.

- **Open Settings.** From the dashboard, choose `Settings`. Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" click --state "$STATE" --role link --name "Settings"` and `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "Preferences save automatically." --timeout 30`. The heading reads `Settings`.
- **Open Max Retries.** Open the Queue tab. Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" open --state "$STATE" --url "$BASE/admin/settings#system"` and `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "Max Retries" --timeout 30` and `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" location --state "$STATE"`. The path is `/admin/settings` and Queue Settings is visible.
- **Change one field.** Max Retries is the number input `#settings_max_retries`. Replace `10` with `11` and leave the field. Autosave runs without Save All. Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "Saved." --timeout 30`. The status reads `Saved.`
- **Prove the stored row.** Read the `max_retries` row. Run `cd "$WT" && bin/rails runner 'row = Setting.find_by!(key: "max_retries"); abort "expected 11, got #{row.typed_value.inspect}" unless row.typed_value == 11; puts [row.key, row.value, row.updated_at.utc.iso8601].join("\t")' | tee "$EVIDENCE/settings-max-retries.txt"`. The line starts with `max_retries` and the value is `11`.
- **Proof.** Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" shot --state "$STATE" --path "$EVIDENCE/settings-max-retries.png"`. The PNG shows `Max Retries` and `Saved.`

## Gotchas

- `drive.rb fill` only accepts the sign-in placeholders. Type `11` into `#settings_max_retries`. Do not guess another field.
- Leaving the field starts an autosave about 800ms later. Wait for `Saved.` before reading the row.
- Save All is for connection details. This recipe does not click it and does not type into a password field.
- A blank Prowlarr API key is the masked placeholder. Leave it blank so the stored key stays.
- Allow Non-Atomic NFS Directory Publication stays until Save All. Do not toggle it.
- The tab labels are Search, Downloads, Integrations, Queue & System, and Security. Leave that order.
- Below 1024px the Admin link is inside `Toggle navigation menu`. Keep the 1280 by 900 viewport.

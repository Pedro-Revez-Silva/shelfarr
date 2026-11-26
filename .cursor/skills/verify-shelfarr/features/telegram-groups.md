# Telegram groups

An admin pauses, resumes, and deletes one approved Telegram group from Settings. Each action starts from a new visit of Integrations.

## Sub-features

- `telegram-groups-open` shows the approved Book Club row.
- `telegram-groups-pause` pauses Book Club.
- `telegram-groups-resume` shows Book Club as authorized again.
- `telegram-groups-delete` removes the Book Club row.

## How to get to it (user POV)

- Choose `Admin`, then `Settings`, then `Integrations`.
- Open `$BASE/admin/settings#integrations` after signing in.

## Driving it with the browser

Preconditions:

- The sign-in recipe in [sign-in.md](./sign-in.md) has succeeded in this browser.
- The viewport is 1280 by 900.
- One approved group is already stored with title `Book Club` and chat id `-100999`. This recipe does not insert that row.
- If `Book Club` is not on the page, stop. Name the missing row as `Book Club`, chat id `-100999`. Do not click `Authorize Group`.

- **Open Integrations.** Load the Integrations page. Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" open --state "$STATE" --url "$BASE/admin/settings#integrations"` and `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "Telegram Group Authorization" --timeout 30` and `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "Book Club" --timeout 30` and `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "Authorized" --timeout 30`. The heading reads `Telegram Group Authorization` and the Book Club row reads `Authorized`.
- **Pause.** The visit above is the document for this click. Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" click --state "$STATE" --role submit --name "Pause Book Club"` and `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "Telegram group paused: Book Club" --timeout 30`. The page says the group is paused.
- **Open Integrations again before Resume.** Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" open --state "$STATE" --url "$BASE/admin/settings#integrations"` and `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "Paused" --timeout 30`. The Book Club row reads `Paused`.
- **Resume.** Find `Resume Book Club` on this visit. Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" click --state "$STATE" --role submit --name "Resume Book Club"` and `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "Telegram group resumed: Book Club" --timeout 30`. The page says the group is authorized again.
- **Open Integrations again before Delete.** Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" open --state "$STATE" --url "$BASE/admin/settings#integrations"` and `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "Authorized" --timeout 30`. The Book Club row reads `Authorized`.
- **Delete.** Find `Delete Book Club` on this visit. Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" click --state "$STATE" --role submit --name "Delete Book Club"` and `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "Telegram group removed: Book Club" --timeout 30`. The page says the group was removed.
- **Confirm the row is gone.** Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" open --state "$STATE" --url "$BASE/admin/settings#integrations"` and `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "Telegram Group Authorization" --timeout 30`. `Book Club` and `-100999` are absent.
- **Proof.** Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" shot --state "$STATE" --path "$EVIDENCE/telegram-groups-deleted.png"`. The PNG shows `Telegram Group Authorization` without the Book Club row.

## Gotchas

- Pause, Resume, and Delete each start with `open` of `$BASE/admin/settings#integrations`. Find the button on that visit. Do not click a control left on the page by the previous action.
- If the wait for `Book Club` exits non-zero, stop and name the missing `Book Club` row, chat id `-100999`. Do not click `Authorize Group`.
- A second group row stays as it is. Click only `Pause Book Club`, `Resume Book Club`, and `Delete Book Club`.
- The pairing code field is a different example. Do not type a code, and do not submit `Authorize Group`.
- The tab labels are Search, Downloads, Integrations, Queue & System, and Security. Leave that order.
- Below 1024px the Admin link is inside `Toggle navigation menu`. Keep the 1280 by 900 viewport.

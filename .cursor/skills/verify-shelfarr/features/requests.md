# Requests

Requests shows the signed-in user's requests. For the seeded admin, with none created, the page title is `All Requests` and the empty state says `No requests yet`.

## Sub-features

- `requests-open` opens the requests list.
- `requests-empty` shows `No requests yet`.
- `requests-filters` shows the status filters, with `All` current.

## How to get to it (user POV)

- Choose `Requests` in the desktop nav.
- Open `$BASE/requests` after signing in.
- Choose a status count on the home page. Those links add a status filter and are a different entry from the unfiltered list.

## Driving it with the browser

Preconditions:

- The sign-in recipe in [sign-in.md](./sign-in.md) has succeeded in this browser.
- The seeded database has no request rows.
- The viewport is 1280 by 900.

- **Nav entry.** Choose `Requests`. Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" click --state "$STATE" --role link --name "Requests"` and `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "All Requests" --timeout 30`. The heading reads `All Requests`.
- **Direct entry.** Open the path. Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" open --state "$STATE" --url "$BASE/requests"` and `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" location --state "$STATE"`. The path is `/requests`.
- **Empty state.** Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "No requests yet"`. The page offers `Search Books`.
- **Filters.** Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "Need Attention"` and `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "Store Offers"`. The filter row is visible.
- **Proof.** Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" shot --state "$STATE" --path "$EVIDENCE/requests.png"`. The PNG shows the Requests nav link and `No requests yet`.

## Gotchas

- An admin sees `All Requests`. A non-admin sees `My Requests`. This recipe uses the seeded admin.
- The unfiltered empty copy is `No requests yet`. A status filter with no rows says `No matching requests` instead.
- Home-page counts link to filtered requests. Use the nav link or `$BASE/requests` for the unfiltered page.
- Creating a request needs a search result. This recipe does not create one.
- The request search box is `Search requests by title or author…`. Leave it empty.

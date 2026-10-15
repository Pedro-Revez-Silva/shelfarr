# Search

Search lets a signed-in user open a catalog search page. With no query, the page asks for a title and shows the Search nav link.

## Sub-features

- `search-open` opens the empty search page.
- `search-nav` shows the Search link in the nav.
- `search-empty` shows `Search for your next read`.

## How to get to it (user POV)

- Choose `Search` in the desktop nav.
- Choose the search prompt on the home page.
- Open `$BASE/search` after signing in.

## Driving it with the browser

Preconditions:

- The sign-in recipe in [sign-in.md](./sign-in.md) has succeeded in this browser.
- No indexer, download client, or library platform is configured.
- The viewport is 1280 by 900.

- **Nav entry.** Choose `Search`. Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" click --state "$STATE" --role link --name "Search"` and `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "Search for your next read" --timeout 30`. The empty state is visible.
- **Direct entry.** Open the path. Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" open --state "$STATE" --url "$BASE/search"` and `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" location --state "$STATE"`. The path is `/search`.
- **Empty state.** Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "Enter a title, creator, or author name"`. The query field is still empty.
- **Proof.** Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" shot --state "$STATE" --path "$EVIDENCE/search-empty.png"`. The PNG shows the Search nav link and `Search for your next read`.

## Gotchas

- A query of two or more characters asks metadata providers over the network. This recipe leaves the query field empty.
- The page can return 200 with no indexer saved. That empty page is the proof.
- The field placeholder is `Search by title, author, series, issue, or volume...`. Filling it starts a search. Do not fill it in this recipe.
- The content type select defaults to `All`. Leave it there.
- Below 1024px the Search link is inside `Toggle navigation menu`. Keep the 1280 by 900 viewport.

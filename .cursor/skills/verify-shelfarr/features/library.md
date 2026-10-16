# Library

Library lists titles stored for this Shelfarr server. With nothing imported, the heading is `Library` and the empty state says `Your library is empty`.

## Sub-features

- `library-open` opens the library page.
- `library-empty` shows `Your library is empty`.
- `library-filters` shows All, Audiobooks, Ebooks, and Audible.

## How to get to it (user POV)

- Choose `Library` in the desktop nav.
- Open `$BASE/library` after signing in.
- Choose `Search Books` from the empty library state to leave for search.

## Driving it with the browser

Preconditions:

- The sign-in recipe in [sign-in.md](./sign-in.md) has succeeded in this browser.
- The seeded database has no library titles.
- No Audiobookshelf, BookOrbit, Grimmory, or Audible connection is configured.
- The viewport is 1280 by 900.

- **Nav entry.** Choose `Library`. Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" click --state "$STATE" --role link --name "Library"` and `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "Your library is empty" --timeout 30`. The heading reads `Library`.
- **Direct entry.** Open the path. Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" open --state "$STATE" --url "$BASE/library"` and `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" location --state "$STATE"`. The path is `/library`.
- **Empty state.** Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "Requested, uploaded, and synced titles will appear here."`. The page offers `Search Books`.
- **Filters.** Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "Audiobooks"` and `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "Ebooks"`. The filter row is visible.
- **Proof.** Run `ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" shot --state "$STATE" --path "$EVIDENCE/library.png"`. The PNG shows the Library nav link and `Your library is empty`.

## Gotchas

- A title filter or a type filter with no matches says `No titles match these filters`. The unfiltered empty copy is `Your library is empty`.
- The Audible filter is visible with no Audible account connected. This recipe does not connect one.
- `Manage Audible` appears only after an owned-library connection exists. A fresh seed does not show it.
- Sync and backup actions need an external library. Leave them unused.
- Below 1024px the Library link is inside `Toggle navigation menu`. Keep the 1280 by 900 viewport.

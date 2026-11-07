# Shelfarr reading brand

The consumer apps should feel like a good shelf, not a dashboard. The admin UI
stays as it is; this direction is for reading and listening on Android, iOS and
the mobile web.

Values live in [`tokens.json`](tokens.json). `apps/scripts/check-design-tokens.py`
checks that Android and iOS match it and that text meets WCAG AA.

## Principles

- **Covers lead.** A library is a wall of jackets. Everything else is quiet around them.
- **Warm paper, one accent.** Surfaces are warm off-whites and warm near-blacks, with
  a single terracotta accent. Use it for the primary action, current selection and
  progress, and nothing else. If two accented things compete, demote one to ink.
- **Serif for reading, system sans for doing.** Newsreader carries titles and long
  text. Buttons, labels and metadata use the platform face, so they feel native.
- **No decoration that isn't information.** No gradients, stat cards, badges or
  counters. Progress is a 3px rule. Separation is a 1px hairline or space.
- **Say what's true.** State what the app really has: "Streams from your server",
  not a download icon. Never show a position, duration or state the player doesn't report.

## Patterns

**Covers.** Ebooks are 2:3, audiobooks 1:1, corners 4 (8 when large), with one soft
shadow. In a mixed grid, cells are 2:3 and jackets are bottom-aligned, so they sit
on a shared baseline. A run of only audiobooks uses square cells.

**Generated cover.** Shown whenever a cover is missing or fails. A flat swatch from
`cover.swatches`, a short rule, the title in Newsreader Display, the author in small
sans at the foot. Choose the swatch with FNV-1a (32-bit) over the UTF-8 publication
id, modulo the swatch count, so a book looks the same on every client:

```js
function coverSwatchIndex(id, count) {
  let hash = 0x811c9dc5;
  for (const byte of new TextEncoder().encode(id)) {
    hash = Math.imul(hash ^ byte, 0x01000193);
  }
  return (hash >>> 0) % count;
}
```

**Navigation.** Three bottom tabs: Home, Library, Settings. The selected tab uses the
accent on `accentSoft`. A now-playing strip sits directly above the tabs while audio is
loaded, with a 2px progress rule on its top edge.

**Home.** Wordmark, one "Continue" card for the latest publication in progress, then
horizontal shelves. There is no greeting and no statistics.

**Details.** Centred jacket, title, author, one full-width primary action
(`Continue reading`, `Start listening`), then the description and a short file table.

**Reader.** The page is everything. Tapping the centre toggles a top bar (back, title,
contents, `Aa`) and a bottom bar (chapter, position, thin scrubber). Edge taps turn
pages. With chrome hidden only a small percentage remains. Paper, Sepia and Night
recolour the chrome too, independently of the app's light or dark mode.

**Player.** Cover, title, author, one accent line for the chapter or track, a thin
scrubber with elapsed and remaining time, then back 15 / play / forward 30. Play is
the only filled control. Speed, sleep and contents are quiet ink text beneath it.

**States.** One centred serif line and one sans sentence, with a single action when
there is something to do. "Can't reach books.example.org", not "Error".

**Conflicts.** When two devices disagree, ask, showing both places. Never overwrite
silently, and never apply a place from a replaced file.

## Responsive web

- Treat phone width as the design target and widen from there. Keep the 20px gutter,
  then cap reading and details columns at about 560px, centred.
- Library: `grid-template-columns: repeat(auto-fill, minmax(104px, 1fr))`, gap 14px
  by 22px, with `align-items: end` on the cover box to keep the shelf baseline.
- Bottom tab bar below about 768px, moving to a slim left rail above it. Respect
  `env(safe-area-inset-bottom)`.
- Load Newsreader from Google Fonts with `opsz`. Use `font-optical-sizing: auto`, or
  `opsz` 72 for display sizes. Use `system-ui` for interface text.
- Map tokens to CSS custom properties under `prefers-color-scheme`. Keep the reader
  theme separate from the page theme.
- 48px minimum touch targets and a visible focus ring in the accent colour.

## Fonts

`assets/fonts` holds static instances of [Newsreader](https://github.com/productiontype/Newsreader)
(SIL OFL 1.1, see `OFL.txt`), shared by the Android and iOS builds. Regular, Italic
and SemiBold use optical size 16; Display Medium uses optical size 72.

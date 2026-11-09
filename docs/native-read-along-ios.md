# iOS and iPadOS: read-along

How the native iOS app reads along with real narration. The wire contract (statuses,
manifest version 1, saved places) is [read-along.md](read-along.md); this page covers what
the iOS client does with it. Progress, downloads and formats follow
[native-progress-ios.md](native-progress-ios.md), [native-offline-ios.md](native-offline-ios.md)
and [native-formats-ios.md](native-formats-ios.md).

Only real alignment is used: EPUB 3 Media Overlays inside the book, or an alignment an
administrator imported for the EPUB and a separate audiobook. The app never estimates
timing from percentages, durations or text length, never interpolates inside a chapter
and never uses speech synthesis. A book without usable alignment opens and reads exactly
as before.

## What the app asks for

- Publication details (`GET /library/:id`) send `X-Shelfarr-Reader-Features: read-along`
  beside `X-Shelfarr-Reader-Formats`, also when replayed after a token handover. Listings,
  Continue, status changes, progress, files and grants never send it. An older server
  ignores it.
- An EPUB asset's `read_along` summary is decoded leniently (`ReadAlongSummary`): a
  missing or malformed summary, an unknown status, or an `available` one without a
  64-hex generation and manifest URL means no read-along. Summaries on other formats are
  ignored. Cached details keep the summary for offline browsing.
- The manifest is fetched with the bearer only after its URL resolves inside the
  configured origin and subpath, through the same transport and redirect checks as every
  other request, and bounded to 48 MiB while it downloads (`ReadAlongFetch`). 404, 409,
  422 and 410 map to unaligned, stale, invalid and changed.

## Checking a manifest

`ReadAlongManifest.parse` (ShelfarrCore) refuses the whole manifest, and the book reads as
usual, unless:

- `version` is 1, `cue_fields` is exactly `text, fragment, audio, begin_ms, end_ms`, the
  generation is 64 lowercase hex and equals the summary's, `ebook_asset_id` is the EPUB
  opened, and `publication_id` (when present) is this book;
- `source` is `media_overlay` with only `epub_resource` audio, or `imported` with only
  `publication_asset` audio of one audiobook, each file named once;
- every text and audio `href` is a relative archive path (no `/` prefix, `..`, empty
  part, scheme, backslash or control character), and every audio `url` and `content_url`
  resolves inside the server;
- there are 1–10,000 texts, 1–2,000 audio files (indices 0–1999; a 2,001st is refused),
  and 1–200,000 cues;
- each cue is exactly five fields with whole-millisecond integers (booleans and fractions
  refused), `0 ≤ begin < end ≤ 48 h` or a `null` end, an element ID of 1–256 bytes, and
  in-range indices;
- cues are in reading order: their text index never decreases (spine order, then
  document order, as the server canonicalises them);
- per audio file, cues sorted by start don't overlap beyond 5 ms, and an open-ended cue
  is that file's last.

## Opening a read-along book

The reader opens the EPUB exactly as before (Readium 3.11.1, the same files, cache and
download), then decides its narration (`ReadAlongService.setup`):

| Situation | Narration |
| --- | --- |
| Online, `available` | The server's current manifest. Audio plays from this device when this generation's files are here (a media overlay's copied narration, or the paired audiobook's download); otherwise it streams from the manifest's audio URLs with the bearer through `AuthenticatedAudioLoader`. |
| Online, `unaligned` with an audiobook, `stale` or `invalid` | None. The controls overlay says why ("… Reading works as usual."). |
| Offline | Only a complete bundle on this device for exactly the EPUB opened. Otherwise the overlay says narration needs the server or a download. |

A manifest fetch that fails offline falls back to the offline rule. A downloaded book
whose server generation changed is updated in the background; the previous bundle stays
in use until the new one is complete.

## Reading along

The page is quiet: nothing is added until narration has played in this session.

- **Controls** live in the existing reading overlay (tap the middle of the page): back 15
  s, Play/Pause (the only filled control), forward 30 s, **Follow the text** and speed,
  then the source and coverage line ("Narration from this book." or "Narrated by …,
  aligned to this edition.", "Narration covers 2 of 3 sections; the others show text
  only."). They wrap onto two rows with large text or a narrow window, are capped at 640
  pt on iPad, keep 44 pt targets, and use the page theme's colours (Paper, Sepia, Night).
- **Pill**: once narration has played, a small Pause/Play capsule sits above the
  percentage when the overlay is hidden; after browsing away it adds **Back to the
  narration**.
- **Highlight**: the element of the cue being heard, as one Readium highlight decoration
  (`DecorableNavigator.apply(decorations:in:)`, group `read-along`, the element located by
  `locations.fragments`). Nothing is highlighted between cues. The decoration follows
  the element across pages, layouts and theme changes.
- **Follow**: when a new cue starts while playing with Follow on, the reader asks the
  page (`evaluateJavaScript` on the current spread) whether that element's start is in
  view, and only if not goes to it (`go(to:)` with the fragment). The setting is kept on
  this device. Reduce Motion turns the move's animation off.
- **Browsing**: a page the reader turns while narration plays writes nothing and pauses
  following until **Back to the narration**. A page turned while paused is reading: an
  ordinary EPUB place is written (no `readAlong`), and the next Play starts from the
  narration on that page (the first cue starting on it, else the cue it continues, else
  the next narrated document's first cue).
- **Layout**: changing text settings or the window size while reading along makes the
  next report an anchor, not a reading place. The size is the reading surface's
  (rotation, a resized window); showing or hiding the controls, which on iPad hides the
  status bar and changes only the safe area, is not a layout, so the next page turned
  while paused is still saved.

Narration plays through the app's one `PlaybackEngine`, so it keeps background audio,
lock-screen, headset and Control Center commands, interruptions, the sleep timer and the
now-playing information ("Read along" as the album). Loading narration saves an audiobook
that was playing, as switching books always did. Closing the book saves the place heard
and stops the narration.

## Places heard

The engine's listening checkpoints are unchanged (at most five seconds apart while
playing, at once on pause, seek, file change, errors, background and closing), but in
read-along mode they go to `ReadAlongProgress`:

- The ebook place is the element of the cue **reached** at the heard offset (in a
  silence, the cue before it) with `locations.readAlong = {generation, audio, offset_ms}`,
  `fragments`, and `totalProgression` of that document's start as Readium measured it.
  Nothing is written before a file's first cue.
- For an imported alignment the paired audiobook's own place (its asset and seconds) is
  written too, with the **same** `observed_at`. One stamp is chosen for both (moved past
  either book's previous local observation, as `ActivityTime.next` does), both records
  are written to the account's `progress.json` first, and only then is either scheduled
  to send. Each then follows its publication's ordinary queue, retry, rebase and
  conflict rules; the time heard survives queues, retries and restarts.
- Restoring a place, following, layout changes, adopting another device's place,
  accepting an offer and repeating the saved place write nothing.
- **Resume**: the first Play after opening a heard place starts five seconds earlier,
  once; the saved place stays the checkpoint until playback passes it, so pausing in the
  replayed seconds doesn't move it back, and playing again there doesn't rewind again.
  Play from a page and seeks are deliberate: no rewind, saved at once. An adopted place
  (the audiobook's, another device's) plays from exactly there, including when narration
  is already loaded and Play comes from the lock screen or headset. The choice is
  consumed once; merely showing its page does not start audio or create activity.
- **Paused reading**: background and close send pending saves without observing the
  unchanged paused audio again. A page read after pausing keeps its place and reading
  time, and the next Play starts from that page. Actual pause edges, deliberate seeks
  and natural file ends still checkpoint at once.
- **Restoring**: a heard place names an element and no progression, so the restore gate
  (`ReadingRestoration`) asks the page whether that element is on screen (`.confirm`)
  instead of comparing progressions. The usual bounded correction, retry and give-up
  apply; an answer about an older report is ignored.
- **Offers**: for an imported alignment, the paired audiobook's newer place (its local
  record or the server's, whichever was heard later) is offered when it was heard later
  than the ebook's place and lands on another cue ("Your audiobook is further along than
  this page." · **Go to the audiobook's place** · **Not now**). Accepting shows that
  element and makes narration start there; it writes nothing.

## Offline

`ReadAlongLibrary` keeps an account's bundles in `Application Support/accounts/<key>/read-along`,
excluded from backup and deleted with the account (`ReadAlongService.close()` runs before
the folder is removed, so no late write recreates it):

    <publication hash>/current.json
    <publication hash>/<generation>/manifest.json, bundle.json, audio-NNN.<ext>

- **Download** of a read-along EPUB also fetches and stores its manifest. For an import,
  the paired audiobook is queued as an ordinary `DownloadManager` download, so it uses
  transfer grants and the background session with no bearer, exactly like any
  audiobook, and is listed as its own download.
- **Media overlay audio** is copied out of the downloaded EPUB once it is ready, through
  the strict ZIP32 reader the comic reader uses (`ComicArchive.copyEntry`): stored entries
  in 1 MiB chunks, deflated ones through a streaming decoder with a 32 KiB window
  (`Inflate.stream`), each checked against its size and CRC-32, written beside its final
  name and moved into place only when verified.
- A generation becomes current only when its manifest is stored and all its audio is
  present (copied files of the right size, or every paired audiobook file downloaded).
  A failed or interrupted update leaves the previous current generation in use; an older
  generation is deleted only once a newer one is current.
- Readiness is checked against the disk every time: a missing or short copied file, a
  missing audiobook file, a manifest for another EPUB edition or an unreadable file is
  never ready, and the details screen offers **Get the narration** again.
- The details screen shows the narration line and, for a downloaded book, "Narration is
  on this device too.", what is still being prepared, or what is missing.
- Removing a book's download removes its narration bundle; the paired audiobook stays
  its own download.
- Narration work belongs to the download that started it (`ReadAlongPreparations`, one
  per account). **Cancel**, **Remove**, choosing another format or edition, a newer
  generation, and the sign-in changing or ending each stop it at once: the owned task is
  cancelled and its ticket goes stale. Every later step rechecks the ticket inside the
  actor that writes (storing the manifest, queueing the audiobook, copying narration,
  making a generation current) and before a status is shown, so work that was waiting on
  the network, the audiobook's details or the book's file can't write, report or start a
  transfer when it resumes. Asking for the same edition and generation again keeps the
  running preparation.
- Cancel deletes what that download stored but never made current; a usable earlier
  generation stays for the next download. Cleanup is bound to the stopped request;
  a newer download or automatic preparation owns its folder even after preparation
  finishes. Relaunch cleanup is accepted only before this launch has handled a new
  request for that book, so an old cancelled-record callback cannot delete new work.
- A paired audiobook queued by a book's download is cancelled with it only while it is
  unfinished (queued, downloading or failed), no other book uses it, and the user hasn't
  asked for (or retried) that audiobook themselves. A complete audiobook is never
  deleted. If another book queues it while it is being cancelled, it starts again for
  that book.
- That ownership survives relaunches like the downloads do, in
  `read-along/companions.json` in the account's folder (deleted with it). A book's claim
  is written before its audiobook is queued. A release stays recorded until the
  audiobook was cancelled, and a release cut short by the app ending is carried out at
  the next launch, as is the cleanup of a cancelled book's unfinished narration.
  - With no file (companions queued by earlier versions) nothing is assumed: those
    audiobooks stay ordinary downloads.
  - A file that can't be read, or is from another version, is moved aside as
    `companions.json.unreadable` and never trusted, so the audiobooks it named aren't
    cancelled with their books.
  - If a change can't be written, the file is deleted rather than left stale, so a
    later launch forgets ownership instead of cancelling an audiobook the user has
    since asked for. That launch still knows, from memory.

## Credentials

The bearer only goes to URLs inside the configured server, as a header: the manifest,
streamed narration (`AuthenticatedAudioLoader`) and the paired audiobook's details. It is
never put in a URL and never given to the background session. Copied narration plays from
disk with no credential. The read-along routes are not fetched by background transfers.

## Tests

Core (ShelfarrCore, `swift test`, Linux and macOS):

- `ReadAlongManifestTests`: media overlay and imported manifests, cue lookup (gaps,
  open ends, before a file's first cue), heard locators with exact keys and integer
  encoding, restoring by exact offset only for the same generation and document,
  `readAlong` validation as the server does it, and negative controls for version,
  layout, source, generation and edition mismatches, unsafe hrefs, foreign URLs, mixed or
  repeated audio, every malformed cue form, overlaps (inside and beyond 5 ms), open ends,
  reading order, 2,000 vs 2,001 audio files and size; lenient summaries; the header only
  on details; manifest statuses; a foreign manifest URL never requested.
- `ReadAlongSessionTests`: quiet pages, highlight only inside cues, follow once per cue
  only while playing, browsing vs reading, restore plans, offers (later, earlier, same
  element, implausible, unknown ebook time); and through the real `FileProgressStore`,
  `ProgressSync`, `ListeningCheckpoints` and a contract server: both imported places on
  disk before either is sent with one `observed_at`, the time heard surviving an offline
  queue, a lost response and a relaunch, nothing before a first cue, a clock stepping
  back, the five-second resume once with pauses in the replay keeping the saved place,
  restoring or repeating a place writing nothing, an adopted place or accepted offer
  replacing loaded narration, and flushes preserving a later read page and both times.
- `ReadAlongLibraryTests`, `InflateStreamTests`, `ReadingRestorationElementTests`:
  overlay audio copied from stored and zlib-deflated entries, damaged, missing and
  truncated files never ready, a failed update keeping the previous generation, imported
  readiness needing every audiobook file on disk, other editions, closing; the streaming
  decoder matching the whole decoder on every vector at 1-byte to 64 KiB reads and
  refusing what it refuses; element restores confirmed, corrected, retried and given up.

Fixture (`apps/ios/RuntimeSmoke/read_along_fixture.py`, checked by
`test_read_along_fixture.py` before the simulator smoke): a real EPUB 3 Media Overlay book
whose SMIL, WAV narration (a two-second tone per cue, 600 ms of silence between) and
manifest agree exactly, an EPUB with an imported alignment to a two-track audiobook, a
stale alignment, unchanged details for clients that don't declare the feature, refused
malformed declarations, resources served only as listed, and the server's `readAlong`
check on progress writes. The shared mock server is unchanged.

Simulator UI tests (`ReadAlongSmokeTests`, iPhone and iPad via
`apps/scripts/ios-runtime-smoke.sh --device all`): the quiet page, the highlight on p1,
nothing in the silence after it, p2, the page following to p4 only when it starts off
screen (the order heard is read from the Debug trace's record of every highlight change
since Play, `shown=`, because a two-second cue is shorter than a hosted simulator's
queries take), browsing while playing writing nothing, Back to the narration, a pause saving the
element and exact offset, a silent reopen, the five-second resume and a pause in it
keeping the saved place; an imported pair's offer, accepted without writing, and one
checkpoint writing both places with one `observed_at`; a download with its narration
reopened and played offline from the device; and a stale alignment reading as an ordinary
EPUB. A further case pauses narration, reads a page, backgrounds and closes the reader,
then checks the page reopens without replacing its reading time or writing narration.
A simulator that never starts audio skips the playback steps visibly.

## Limits

- The app, the Readium bridge, the player and the UI tests compile only with Xcode and
  the iOS SDK. They were written against Readium 3.11.1's source (decorations,
  `evaluateJavaScript`, `go(to:)`, positions) and AVFoundation as documented, and checked
  here by a syntax parse; the read-along controller and service also type-check against
  the real ShelfarrCore with stand-ins for the app types. Build, rendering and playback
  are verified only once the simulator smoke runs on Xcode for iPhone and iPad. No
  physical device was used.
- Highlighting is per cue (sentence or paragraph), never per word. A cue whose element
  starts on one page and continues onto the next is followed when it starts, not when
  narration reaches its second half.
- Follow and "Play from this page" read the page's layout with JavaScript on the
  current spread; a fixed-layout (pre-paginated) EPUB with two documents in a spread is
  treated as its current document.
- A media overlay read online without a download streams its narration from the server;
  only a download copies it to the device.
- Space doesn't toggle narration with a hardware keyboard yet.

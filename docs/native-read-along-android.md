# Read-along on Android

How the Android app implements [read-along](read-along.md): real narration
aligned to the exact EPUB on the server, followed in the text. It uses the
frozen manifest version 1 contract unchanged and adds nothing to the server.

Only real alignments are used: EPUB 3 Media Overlays inside the book and
alignments an administrator imported for a separate audiobook. The app never
estimates timing, synthesises speech or aligns anything itself. An EPUB without
an alignment reads exactly as before.

## Declaring the feature

`GET /library/:id` (publication details) sends
`X-Shelfarr-Reader-Features: read-along` alongside the existing
`X-Shelfarr-Reader-Formats`. Listings, Continue and status changes do not, so
their projections are unchanged, and an older server simply ignores the header:
no EPUB asset then carries `read_along`, and the book opens as a normal EPUB.
Read-along never changes which file is opened or which reader opens it: it is
always the Readium EPUB navigator, never the fixed-layout page reader.

## Manifest

`ConsumerApi.readAlong` fetches the summary's `manifest_url` (it must be on the
signed-in server) with a 48 MiB body bound. `ReadAlong.read` streams the cue
array into primitive arrays and refuses the whole manifest (`ReadAlongRefused`)
unless:

- `version` is the number 1, `generation` is 64 hex and matches the summary,
  `ebook_asset_id` is the open asset (otherwise *changed*, not invalid);
- `cue_fields` is exactly `text, fragment, audio, begin_ms, end_ms`;
- text and EPUB-resource paths are relative, without `..`, empty segments,
  schemes, backslashes or control characters;
- there are 1–2,000 audio tracks and 1–200,000 cues, every narration URL and
  `content_url` resolves inside this server, media types are audio and sizes
  are positive numbers; `media_overlay` uses only `epub_resource` tracks and
  `imported` only `publication_asset` tracks of one audiobook;
- every cue is five JSON values of the right type (no quoted numbers or
  fractions), names a text and track in range and an element ID, has
  `0 ≤ begin < end ≤ 48 h` (or an open end that is the last cue on its file),
  cues are in canonical reading order (non-decreasing text index) and cues on
  one file don't overlap beyond 5 ms.

Each manifest text must be a document in Readium's reading order of the open
EPUB (compared by decoded archive path); otherwise read-along is not offered.

## Playing narration

Narration is a queue in the same `PlaybackController` → `PlaybackService`
(Media3 `MediaSessionService`) as audiobooks: one player, audio focus, becoming
noisy, notification, lock screen and headset controls, and it carries on in the
background. Online, tracks stream from the manifest's `url` through the
account-scoped HTTP stack; with complete downloaded narration they play from
files. The notification and lock screen reopen the book (the session activity
follows the queued item), and the mini player is announced as "Reading along".

Listening checkpoints follow the existing rules (`ListeningCheckpoints`): at
most five seconds apart while playing, written at once on pause, seek, track
change, error, backgrounding, stop and switching to another queue, each stamped
with the wall-clock time it was heard. A genuine resume restarts five seconds
earlier once, and the place resumed from stays the saved one (with its original
time) until playback passes it, including repeated pauses inside the replay.

`ReadAlongSink` turns a checkpoint at `(track, ms)` into:

- the ebook place: the element of the cue *reached* at that offset
  (`href`, `type`, `locations.fragments`, a section-start `totalProgression`,
  and `locations.readAlong {generation, audio, offset_ms}`); nothing before the
  first cue of a file;
- for an imported alignment, the paired audiobook's own place: that file's
  `asset_id` and `position_seconds`.

Both are saved on this device with one identical `observed_at` before either
can be sent (`ProgressSync.together` holds every sync's next send until both are
on disk). Sends stay serial, debounced and idempotent: a retry repeats the same
body, mutation ID and activity time, also after a restart.

A checkpoint of the *same* point as the last one written (narration paused,
then the app backgrounded, stopped or switched away) records nothing, so old
audio is never stamped with a fresh time over a place read meanwhile.

## In the reader

`ReadAlongCoordinator` (one per open book) loads the manifest, maps it to the
reader's links and follows the player:

- **Highlight**: the cue's element as a Readium `Decoration.Style.Highlight`
  in the group `read-along` (drawn under the text in the theme's narration
  tint); nothing between cues while playing; where narration paused while
  paused. Verified against the pinned Readium Kotlin 3.4.0 artifacts:
  `DecorableNavigator.applyDecorations`, `EpubNavigatorFragment.go`,
  `evaluateJavascript` and `currentLocator`; the navigator resolves a locator's
  first `fragments` entry as an element ID for both decorations and navigation.
- **Follow**: when the heard element is out of view (checked in the page with a
  small read-only script whose IDs travel as JSON), the page turns to it. Every
  such move, every place shown on request and every re-layout (rotation, text
  settings) is display only, never reading.
- **Browsing**: turning pages while narration plays writes nothing and pauses
  follow; the pill offers "Back to the narration".
- **Paused reading**: turning pages while paused writes a normal reading place
  (without `readAlong`), and the next Play starts exactly at the cue that page
  shows (the first narrated element in view, else the next one after it, else
  the next narrated document). Only narration actually heard again (from the
  app, the lock screen or a headset) makes the narration the newest place.
- **Restoring**: opening at a place is never activity. A saved offset is
  trusted only for this generation and when its cue is in the locator's own
  document; otherwise Play starts from the page.
- **Adopted places**: choosing another device's place, or a later place in
  the paired audiobook, moves even already-loaded narration as a restoration:
  the player waits five seconds before the place, which keeps its own activity
  time, and any Play (including one pressed while the place is still being
  adopted, which waits for it, and media commands) resumes there. The audiobook
  player's conflict choice works the same way.
- **The paired audiobook's later place** (heard on its own player or another
  device) is offered ("You listened further in …") and never written into the
  ebook. If times are unknown or implausible both places are kept as they are.

The reading controls (tap the page) show Play/Pause, back 15 s, forward 30 s,
speed (0.75–2×), "Follow the text" and what the narration covers. Until
narration is used nothing is added to the page; after that a small pill offers
Pause/Play and, after browsing, "Back to the narration". Books whose narration
can't be used say why in the controls only: unaligned with a known audiobook,
stale, invalid, a refused manifest, or offline without downloaded narration.
Controls have TalkBack names and states, 48 dp targets, and stack rather than
overlap at large text sizes; colours follow the Paper, Sepia and Night themes.

## Offline

On a book's page, a book with an available alignment downloads "with narration"
(the default) or "text only". Narration is part of the book's download record:

- the exact manifest bytes (`ra-<generation>.json`) and every narration file
  (`ra-<generation>-NNNN.<ext>`) in the book's folder in this account's storage;
- Media Overlay audio is copied out of the verified EPUB on the device (size
  checked against the manifest); imported audiobook files are fetched from their
  `content_url` with this account's own credential, resuming with
  Range/If-Range when a strong validator allows it;
- the book is readable offline as soon as its own file is complete; narration is
  offered only when its manifest and every file are on disk at their sizes for
  one generation (checked again after every restart);
- a newer generation is fetched beside a complete older one, which stays in use
  until the new set is whole; a failed update changes nothing;
- asking for narration is durable intent from the moment it is asked, before
  any manifest exists: if it stops before the manifest is pinned (the app
  stopped or was killed, the sign-in expired, the connection or server failed),
  the request stays on the ready book with why it stopped. It is resumed like
  the book's own downloads: by the next host when only paused, by signing in
  again to the same account, by the foreground or a running host for a
  connection or server problem, or by "Resume narration" / "Try narration
  again". Until its files are whole for one generation nothing about it looks
  downloaded, and a complete earlier generation keeps playing;
- an expired sign-in keeps the account's downloads (including that request) for
  the same account; explicitly disconnecting is a purge that deletes the
  account's files, so nothing of it can come back, and another account's
  downloads live in its own storage and never see it;
- removing narration, stopping it, or cancelling or removing the book bumps an
  epoch: a fetch still waiting for its manifest can no longer save, pin or
  promote anything, and unrecorded narration files are deleted. Cancelling a
  ready book from the Downloads list or the notification stops only its
  narration. Cancelling or removing also cancels the request itself: no recovery
  path resumes it, and "Download again" fetches the book alone. Other downloads,
  including the paired audiobook downloaded on its own, are never touched.

Nothing is shared between accounts: storage paths, the HTTP stack, the Keystore
session and the updater are unchanged, and the evictable EPUB cache is still
used as before when nothing is downloaded.

## Development and tests

`apps/scripts/mock_consumer_server.py --read-along` adds "The Narrated Garden"
(genuine SMIL Media Overlays with WAV narration inside) and "The Paired
Lighthouse" (plain EPUB, imported alignment to a two-file audiobook);
`--read-along-stale` makes the imported one stale. Without the flag every
response is byte-identical to before.

| Test | Covers |
|---|---|
| `core/ReadAlongTest` | parsing, indexing, bounds and refusals, places and locators |
| `playback/ReadAlongPlaybackTest` | checkpoint spacing, reached cue, paired same-time writes on disk before sending, resume floor, deliberate starts, switching, retries, audiobook conflict restore |
| `reader/ReadAlongWiringTest` | coordinator + account services + Readium + controller: adopted places with loaded narration, waiting Play, lock-screen play, paused page turns through background, offer with loaded narration |
| `reader/ReadAlongReadingTest` | restore/follow/layout are not reading, page cues, offer decisions |
| `core/NarrationDownloadTest` | extraction, imported transfer, failures keep the book, updates keep the old set, cancellation during manifest fetch |
| `core/NarrationRecoveryTest` | a request stopped before its manifest, across fresh-manager relaunches: interruption, host pause, expired sign-in and same-account re-sign-in, transient failures, update keeping the old generation, removal/cancel never resurrected, other accounts and a separately downloaded audiobook untouched, disconnect purge |
| `ui/NarrationRecoveryCopyTest` | stopped-request words, retry labels and the book page's single narration retry |
| `reader/ReadAlongScreenshotTest` | rendered controls, pill, offer, unavailable note, large text, small phone, download states |
| `androidTest/.../ReadAlongSmokeTest` | real Activity, WebView highlight, Media3 notification, browse, silent reopen, offline imported narration with paired places |
| `apps/scripts/tests/test_mock_read_along.py` | the mock's fixtures, routes and opt-in behaviour |

Not implemented: word-level highlighting below the cue, computing alignments,
and switching between separately downloaded formats mid-chapter.

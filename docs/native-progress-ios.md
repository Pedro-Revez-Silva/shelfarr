# iOS progress: activity time, checkpoints and resume

How the iOS and iPadOS app saves and reconciles reading and listening places. The
wire contract is in [consumer-api.md](consumer-api.md#activity-time-and-conflicts);
this page covers what the iOS client does with it. The rules live in `ShelfarrCore`
(plain Foundation, tested on Linux and Apple platforms); the app target drives them
from Readium and AVFoundation.

## Activity time on the wire

- Every progress write carries `observed_at`: the wall-clock time the page was
  reached or the audio was heard, as UTC with milliseconds
  (`2026-11-07T09:15:30.123Z`, `ActivityTime.format`). The reader and the player
  capture it when the event happens, before any task, disk write or request, so a
  slow queue never makes a place look newer.
- `resolve_conflict: true` is sent only for an explicit **Keep this device** choice.
  It is omitted otherwise, including on automatic rebases.
- Responses are read for `observed_at` (`ReadingProgress.observedAtMillis`). Missing,
  malformed, non-string, zoneless or impossible values are an unknown time;
  `updated_at` is never used as activity time.
- A time is trusted for ordering only when it is plausible on this device: not
  before 2000-01-01 and not more than five minutes ahead of the device clock.

## Local records

Each account keeps `Application Support/accounts/<key>/progress.json`, replaced
atomically (`FileProgressStore`). Per publication it stores the newest local place,
when it was reached (`observedAt`, epoch ms), the server version it builds on, any
queued place (`dirty`), the in-flight write (`pending`), a raised conflict, the
edition's asset ids and whether the server refused the place (`rejected`). Accounts
never share a file, and sign-out still stops every sync before deleting the folder.

- A pending write is immutable: position, version, mutation id, activity time and
  resolve flag are repeated exactly on every retry, including after a restart.
- Records and pending writes saved by the previous release decode with an unknown
  time. Their queued write is retried unchanged (without `observed_at`), and a
  conflict on it asks the reader, as before.
- A file that can't be decoded is renamed to `progress.json.damaged` rather than
  overwritten. A file that exists but can't be read (for example while the device is
  locked) throws and caches nothing, so a later write can't replace records it never
  read.
- A failed write keeps the place in memory, still sends it to the server, and shows
  "Couldn't save your place on this device…" in the reader and player
  (`progress-storage-failed`) until a write succeeds.

A new local observation is never stamped earlier than the previous one for the same
book (when that one is within five minutes ahead), so a clock stepping back slightly
can't reorder one device's own reading.

## Reconciliation

Sends are debounced (5 s, at most 20 s while moving), serial and idempotent. Lifecycle
checkpoints request an immediate upload without blocking subsequent local writes;
teardown can await the outstanding attempt after those writes drain. On a definite
409 the canonical server checkpoint is compared with the **newest** local
observation, including places queued behind the rejected write:

| Situation | Result |
| --- | --- |
| The 409 names our own mutation id | Treated as saved (the answer was lost). |
| Same place | Later known local activity is still published; a later server timestamp is adopted. Legacy unknown times retain the version flow. |
| No server place (`null` or unusable) | Local place rebased onto that version. |
| Local reached later | Rebased: new mutation id, original `observed_at`, no resolve flag. |
| Server reached later | Adopted into the record; the stale local writes are dropped. |
| Equal times, an unknown or implausible time, or an asset this edition can't map | The reader chooses. |

Later activity wins wherever it is in the book, so seeking backward is a valid new
observation. Adopting never moves an open reader or a playing audiobook: it changes
the saved record, which the next open resumes from, and further activity on this
device is newer still and wins.

Opening applies the same rule before anything is shown (`ResumeDecision`): unsent
local reading continues if it is later, the server place is used if that is later,
and uncertain cases ask. A queued write the server already holds (same mutation id)
is not a conflict. A place the server refused always asks.

**Keep this device** is a new choice: it is stamped with the choice time and
`resolve_conflict: true` and written to disk before it is sent. If the version moves
again first, it is rebased like any other place, without the flag. **Use other
device** adopts the server place and its time, and going there in the reader or
player is not new activity.

Nothing creates activity by itself. Opening a book, restoring its saved page,
choosing the other device's place, acknowledgements, metadata refreshes and the resume
rewind do not write a new checkpoint.

Restoring an EPUB place (`ReadingRestoration` in `ShelfarrCore`, driven by
`ReaderModel`) does not trust Readium's first location report. On a cold or offline
open that report can name the chapter start before the page is laid out, and its
locator carries no proof of where the page settled. Each report is checked against
the viewport Readium measured with it (`ViewportObservingNavigator.viewport`: each
visible reading order resource and the progression range on screen):

- The saved place is restored when its resource is on screen and its progression lies
  in the visible range (half-open at a page end, with float slack only). That page is
  the anchor even if it starts well before the saved progression, as a large page or a
  different layout can.
- A report that misses it is not saved. Input on the book is disabled and the reader
  is sent to the saved place again with `go(to:options: .none)`. The jump finishing is
  not proof, because Readium reports the settled page later; the restore waits for a
  report whose viewport shows the place. Readium 3.11 reports only after its page script
  sees a scroll or resize, so a jump to the offset already shown reports nothing (a hosted
  cold offline open drew the saved page while its only report was an empty viewport at
  0%). After each accepted jump the app runs Readium's own scroll handler
  (`ReadiumBook.remeasure`), so Readium measures the page shown and reports it if new.
- Each attempt waits at most five seconds; after one retry the reader gives up,
  enables input, says the saved page couldn't be shown, and keeps the saved place
  unchanged. The page left on screen becomes the anchor, so the reader's own first
  turn from it is saved; the saved place arriving late is still not reading.
- Once anchored, any report of another page, forward or back, is reading and is saved
  at once.

Errors keep the last local place:

- Offline, 5xx, unreadable 2xx answers, blocked redirects and unexpected transport
  errors retry the identical write with backoff.
- 401 keeps the write for after signing in again.
- 400/403/404/422 (for example a refused future time or a replaced file) keep the
  place, still unsynced, and stop retrying until the book is opened again. Opening it
  then asks whenever the server has a different place.

## Audio checkpoints

`PlaybackEngine` reads the player every 500 ms and, while playing, writes a local
checkpoint once four seconds of monotonic time (`systemUptime`) have passed, so saved
places trail playback by at most five seconds. These write one at once: pause (app,
lock screen, headset or route change, interruption, sleep timer), stop, any seek or
skip (in-app or lock screen), a track or chapter choice, a natural move into the next
track, a player error, switching to another book and the app going to the
background. While a seek is still arriving, the player's reported time is ignored so
the old place can't be saved after the new one. Local writes run in the order they
were made. Background audio (`UIBackgroundModes` audio, the `.playback` session),
lock-screen controls, background download grants/session and the offline library are
unchanged.

## Resume rewind

A genuine resume restarts five seconds earlier, clamped to the start of the current
track (`ListeningCheckpoints`):

- opening a saved audiobook place, and
- pressing play (in the app, mini player or lock screen) after playback was paused,
  including retrying after a playback error.

It applies once per resume. It does not apply to a deliberate seek, skip, track or
chapter choice (even while paused), a natural track change, an interruption ending
with "should resume", chapter or duration loading, going to the other device's place,
or reopening the player screen while the book is already loaded. The place resumed
from stays the saved checkpoint until playback passes it or the listener moves
deliberately, so pausing during the replayed pre-roll never moves the saved place
backwards.

## Tests

`ShelfarrCore` (`apps/scripts/ios-check.sh`, or `swift test` in
`apps/ios/ShelfarrCore`):

- `ProgressReconciliationTests`: two devices with their own stores and clocks against
  a server that follows the contract. Both reconnection orders, with and without
  restarting both devices; a newer place queued behind an unanswered write that
  survives later remote activity; a stale retry against later remote activity; a
  backward seek; equal times; an older server; a legacy queued write; a far-future
  remote time from a slow clock; a fast clock's refused time; an unmappable asset;
  keep-local overriding once and its rebase dropping the flag; choosing the other
  device; adoption during playback; a choice made at open sent once.
- `ProgressTests`: disk before send, retries repeating body and event time,
  acknowledgement not changing the time, a clock stepping back, restoring a place not
  being activity, refused places kept, unreadable answers retried, storage write and
  read failures, legacy/damaged/unwritable files, and the request and response JSON.
- `ResumeDecisionTests`: later local or server activity, every unorderable case,
  acknowledged queued writes, refused places, replaced editions.
- `ActivityTimeTests`, `ListeningCheckpointsTests` (cadence over ten minutes of
  jittered ticks, rewind once, clamping, pre-roll hold, no rewind for deliberate or
  natural moves) and `ReadingRestorationTests` (a wrong first report corrected and
  never saved, a page starting well before the saved progression, page boundaries,
  immediate forward and backward turns, timeout, retry, giving up and a late arrival,
  stale timers, a chosen place, and scripted restores that never save).

Simulator UI tests (`apps/scripts/ios-runtime-smoke.sh`), in addition to the existing
library, download and offline flow:

- `testLibraryReaderDownloadsAndOfflineReopening`: the saved place is inside a chapter
  (the test turns on past a chapter start if needed). A cold relaunch with the server
  unreachable restores it from the download without recording any reading, and
  reconnecting (a foreground retry of every unsynced place) sends nothing: the
  server's saved version, mutation id and `observed_at` are unchanged.
- `testReaderSendsActivityTimeAndReopensSilently`: page turns send a plausible
  `observed_at` and no resolve flag; reopening at the saved page inside a chapter and
  closing again writes nothing (the fixture server records every progress body).
- Book text is recognised by prose from any of the fixture's three chapters, since a
  restored place can be in any of them.
- Debug builds launched by the UI test keep a restore trace (`RestoreTrace`): the
  opened place, each report's locator and measured viewport, the decision, jumps and
  timeouts. It holds only reading order file names and progressions of the synthetic
  fixture book. The tests attach it to the result bundle, and it is in `device.log`
  (subsystem `org.shelfarr.app`, category `reader-restore`). Release builds have none.
- `testAudiobookResumeRewindsOnceAndKeepsTheSavedPlace`: a skip then pause saves that
  place to the server at once; play restarts about five seconds earlier; pausing in
  the pre-roll keeps the original saved place; a deliberate skip while paused plays
  from exactly there. If the simulator never starts audio playback the test is
  skipped, visibly, rather than passing.

### Running the smoke test on iPhone and iPad

```sh
apps/scripts/ios-runtime-smoke.sh                 # iPhone (default)
apps/scripts/ios-runtime-smoke.sh --device ipad
apps/scripts/ios-runtime-smoke.sh --device all    # iPhone, then iPad
```

`SHELFARR_SMOKE_DEVICE` works too. Each family picks the newest available simulator
whose iOS runtime the selected SDK supports (preferring full-size models), unless
`IOS_SIMULATOR_UDID` names one. A simulator the script had to boot is shut down when
it finishes; one already booted is left running. Ad-hoc signing
(`CODE_SIGN_IDENTITY=-`) is kept for the background download daemon.

| Path | Contents |
| --- | --- |
| `apps/ios/build/runtime-smoke/<family>/` | `RuntimeSmoke.xcresult`, `attachments/`, `xcodebuild.log`, `server.log`, `server-stats.json` (now with `progress_writes`), `device.log`, `device.json` |
| `apps/ios/test-results/runtime-smoke/<family>/summary.json` | `xcresulttool get test-results summary` |

`<family>` is `iphone` or `ipad`. These replace the previous single
`apps/ios/build/runtime-smoke/` files and `apps/ios/test-results/runtime-smoke-summary.json`.
The fixture ports differ per family (iPhone 8765/8766, iPad
8775/8776); running both at once also needs distinct `SHELFARR_SMOKE_DERIVED_DATA`.

## Limits

- **Verified in CI:** [run 42410339450](https://github.com/Pedro-Revez-Silva/shelfarr/actions/runs/42410339450)
  on `94b74f4` passed 176 core tests and compiled the app and UI tests with Xcode
  16.4. The iPhone 16 Pro and iPad Pro 11-inch (M4), both iOS 18.5, each passed all
  three runtime tests with no failures or skips. These cover audio rewind, cold
  offline in-chapter restore, silent reopen and reconnect without a fake checkpoint.
  The core tests also pass on Linux (Swift 6.4.2).
- No physical iPhone or iPad was used. Lock-screen and Bluetooth controls, process
  death between checkpoints, real background suspension and two physical devices
  offline remain in the acceptance flow.
- The simulator's audio may not advance on CI hosts; the rewind UI test then skips.
  The cadence and rewind rules are covered by the core tests either way.
- The rewind UI test checks where its second pause really landed (the track and time
  shown). Inside the replay, the saved place, its asset, version and time must be
  unchanged and nothing written. A pause a loaded host delivers after the replay (on
  one hosted iPhone it reached the app 45 s after Play, in track 2) must instead save
  that track and place with a later time.
- Restoration relies on Readium 3.11's viewport being measured in the same step as
  the location report. The cause of the wrong first report on a cold offline open was
  not isolated (CI did not record the locators); the restore trace now does. A restore
  that fails twice leaves the reader on the page shown, with the saved place kept.
- A device whose clock is wrong by more than five minutes asks on most conflicts; the
  server refuses its future times (kept locally) until the clock is fixed. A clock
  wrong by less than that can still order two devices' activity incorrectly.
- An adopted later place is not shown in an open session; it is used on the next open.

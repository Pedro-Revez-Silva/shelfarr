# Android progress: activity time, checkpoints and resume

How the Android app saves and reconciles reading and listening places. The wire
contract is in [consumer-api.md](consumer-api.md#activity-time-and-conflicts); this
page covers what the Android client does with it.

## Activity time on the wire

- Every progress write carries `observed_at`: the wall-clock time the page was
  reached or the audio was heard, as UTC with milliseconds
  (`2026-11-07T09:15:30.123Z`). It is captured when the event happens, before any
  lock, disk write or request, so a slow queue never makes a place look newer.
- `resolve_conflict: true` is sent only for an explicit **Keep this device**
  choice. It is omitted otherwise, including on automatic rebases.
- Responses are read for `observed_at`. Missing, malformed, zoneless or impossible
  values are an unknown time; `updated_at` is never used as activity time.
- A time is trusted for ordering only when it is plausible on this device: not
  before 2000-01-01 and not more than five minutes ahead of the device clock.

## Local records

Each account keeps `accounts/<key>/progress.json`, replaced atomically. Per
publication it stores the newest local place, the time it was reached
(`observedAtEpochMs`), the server version it builds on, any queued place
(`dirty`), the in-flight write (`pending`), a raised conflict, the edition's asset
ids and whether the server refused the place (`rejected`).

- A pending write is immutable: position, version, mutation id, activity time and
  resolve flag are repeated exactly on every retry, including after a restart.
- Records and pending writes saved by earlier app versions decode with an unknown
  time. Their queued write is retried unchanged (without `observed_at`), and a
  conflict on it asks the reader, as before.
- An unreadable file is renamed to `progress.json.damaged` rather than
  overwritten. A read error leaves nothing cached, so a later write cannot replace
  records it never read.
- A failed write keeps the place in memory, still sends it to the server, and
  shows "Couldn't save your place on this device" in the reader and player until a
  write succeeds.

A new local observation is never stamped earlier than the previous one for the
same book (when that one is within five minutes ahead), so a clock stepping back
slightly cannot reorder one device's own reading.

## Reconciliation

Sends are debounced (5 s, at most 20 s while moving), serial and idempotent. On a
definite 409 the canonical server checkpoint is compared with the **newest** local
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
device** adopts the server place and its time.

Nothing creates activity by itself: opening a book, restoring the saved place
(Readium's first restored report, which can land at the start of the page holding the
saved progression), choosing the other device's place, acknowledgements and the resume
rewind do not write a new checkpoint.
Once the actual restored page is established, even a short backward page turn counts
as reading; repeated reports of that same page remain silent.

Errors keep the last local place:

- Offline, 5xx and unreadable 2xx answers retry the identical write with backoff.
- 401 keeps the write for after signing in again.
- 400/422 (for example a refused future time or a replaced file) keep the place,
  still unsynced, and stop retrying until the book is opened again. Opening it then
  asks whenever the server has a different place.

## Audio checkpoints

`PlaybackController` reads the player every 500 ms and writes a local checkpoint
when four seconds of elapsed time have passed, so saved places trail playback by at
most five seconds. These write one at once: pause (app, lock screen, headset, noisy
audio, sleep timer), stop, any seek or track choice (in-app, lock screen or
notification), a natural move into the next track, a player error, switching to
another book and the app going to the background. Background playback is still
hosted by the Media3 `PlaybackService` foreground service, unchanged.

## Resume rewind

A genuine resume restarts five seconds earlier, clamped to the start of the current
track:

- opening a saved audiobook place, and
- pressing play (anywhere) after playback was paused.

It applies once per resume. It does not apply to a deliberate seek or track or
chapter choice (even while paused), a natural track change, chapter or metadata
loading, audio focus coming back, or reopening the player screen while a book is
already loaded. The place resumed from stays the saved checkpoint until playback
passes it or the listener moves deliberately, so pausing during the replayed pre-roll
never moves the saved place backwards.

## Tests

Unit tests (`apps/scripts/android-check.sh`):

- `ProgressReconciliationTest`: two devices with their own stores and clocks against
  a server that follows the contract. Both sync orders after offline use (including
  after restarting both), a backward seek winning, an in-flight retry with a newer
  local place queued behind it, a stale retry against later remote activity, lost
  answers across restart, durability at the moment of reporting, event time versus
  processing time, a clock stepping back, older servers, older local stores, equal
  times, fast and slow clocks, an unset clock, a refused future time, unmappable
  assets, the keep-local choice (on disk first, flag never resent on rebase), a wiped
  server, storage failure and no activity from restoring a place.
- `ProgressSyncTest`, `ResumeDecisionTest`, `FileProgressStoreTest`, `ActivityTimeTest`
  for the debounce/retry rules, open-time decisions, legacy and damaged stores,
  parsing, plausibility and the request body.
- `PlaybackControllerTest` (Robolectric with a scripted Media3 player): checkpoint
  gaps and lag at most five seconds over a minute of playback, immediate checkpoints,
  resume rewind once on open and paused restart, lock-screen play, clamping to the
  track start, no rewind for deliberate seeks, track choices, lock-screen seeks or
  natural transitions, and no movement of a playing session after adoption.
- `ListeningCheckpointsTest` and `RestoredPlaceTest` for the pure rules.

Instrumentation (`apps/scripts/android-reader-smoke.sh`, run by CI's emulator):
`ReaderSmokeTest` now also checks that the real reader sends a plausible
`observed_at` and that reopening the saved page sends nothing.

## Limits

- Instrumentation is compiled locally (`assembleDebugAndroidTest`) but not run here:
  this machine has no KVM, so it runs on CI's emulator only. Real-device checks of
  lock-screen controls, Bluetooth buttons, process death between checkpoints, and two
  physical devices offline remain in the acceptance flow.
- Without an audio device the CI emulator cannot advance playback, so audio cadence and
  rewind are verified with the scripted player rather than ExoPlayer decoding.
- Restoration detection relies on Readium's first restored report identifying the
  actual page. The initial page-start tolerance does not apply to subsequent turns.
- A device whose clock is wrong by more than five minutes asks on most conflicts; the
  server refuses its future times (kept locally) until the clock is fixed.
- An adopted later place is not shown in an open session; it is used on the next open.

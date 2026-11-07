# Android: background downloads and offline library

This page covers how the native Android app keeps downloads running after you leave
it, and how the Library works offline. It describes the Android app only; see
[native-consumer.md](native-consumer.md) for the shared design.

## Background downloads

A download runs only after someone taps Download, Try again or Resume. Shelfarr asks
Android for background time only for those downloads.

### One engine, OS hosts

Each account's `DownloadManager` is the only code that writes download files. It
still pins the edition, resumes with `Range`/`If-Range` only against a strong `ETag`,
limits work to two publications at once, and marks a download ready only once every
pinned file is complete and verified. The OS hosts below transfer no data. They keep the
process alive, start the queue (`resumeQueued`), and tell it to stop (`pause`).
Because only that one engine writes, a job and a service can run together without
racing on the same files.

The queue is written to disk before any host is requested. This means a host that
starts in a fresh process always finds its work.

| Android | Host | Notes |
| --- | --- | --- |
| 14 and later (API 34+) | User-initiated data transfer job (`JobInfo.Builder.setUserInitiated(true)`, `RUN_USER_INITIATED_JOBS`) | Scheduled only while the app is visible, as Android requires. It accepts LAN/VPN networks without requiring validated public Internet, is persisted, and gives the remaining bytes as its estimate. It calls `setNotification` straight away, so it is listed in the system Task Manager, and it updates the estimate as the queue changes. If Android refuses it (for example the request came from the background), a regular job is scheduled instead, and it is upgraded the next time the app is visible. |
| 8 to 13 (API 26–33) | A `dataSync` foreground service, plus a regular persisted job | The service is started only while the app is visible and stops itself when the queue is empty. The job is the path that survives process death and network loss. Android stops ordinary jobs after about 10 minutes, so very long downloads continue in resumable slices. |

`DownloadJobService.onStopJob` handles the system's stop callbacks:

- **Stopped by the system** (connectivity, quota, timeout, thermal and so on): if the
  app isn't visible and no foreground service is running, transfers pause. Partial
  files and validators are kept, the downloads go back to the queue, and the job asks
  to be rescheduled.
- **Replaced by the app** (`STOP_REASON_CANCELLED_BY_APP`): the replacement job takes
  over, and nothing pauses.
- **Stopped by the user** (`STOP_REASON_USER`): downloads are marked *Stopped before it
  finished* and are not rescheduled.

When a job finds the queue empty but a download stopped for a passing reason (no
connection, server error), it asks Android to retry with exponential backoff from 30
seconds. After 6 attempts (about half an hour) it waits for the person to come back to
the app. Opening the app resets that budget.

On API 28+, jobs use an explicit network request that permits LAN and VPN access
without public Internet validation. API 26–27 cannot express that request: the
persisted job runs after a short delay and uses bounded retries if the connection
is unavailable. Cold job/service starts restore the account before starting the
driver, and jobs register their completion handler before execution can finish.

### What isn't promised

- **Force stop, and Stop in the Task Manager.** Android kills the process, cancels the
  app's jobs and doesn't call `onStopJob`. The next time the app starts, any download
  the manifest still lists as queued, with no job scheduled to continue it, becomes
  *Stopped before it finished · Resume*. It is not restarted silently, because that
  would undo the person's stop. Kept bytes are reused when they resume.
- **Reboot.** Jobs are persisted (`RECEIVE_BOOT_COMPLETED`), so Android *may* restore
  them after a restart. Android decides; the app doesn't start anything at boot. On
  Android 15+, `dataSync` services can't start from boot anyway.
- **Network, battery and quotas.** Jobs wait for a network. Android can delay or stop
  them for battery saver, standby buckets, thermal state or quota. User-initiated jobs
  are exempt from standby quotas, but Android can still stop them. Jobs are never
  limited to Wi-Fi, because there is no setting for that yet.
- **Process death without a host.** If Android refuses every host (rare), downloads
  run only while the app process lives. They are then reported as stopped, as above.

### Notifications

There is one low-importance channel, *Downloads*. The progress notification names the
title, or the number of titles, and gives an honest amount: a percentage bar only when
every size is known. *Cancel* (or *Cancel all*) cancels exactly the downloads listed
in that notification. Tapping the notification opens Downloads. When a job ends, a
quiet notification may say what finished, or which download needs attention.

The Cancel intent carries the account key it was built for. If a different account
is signed in when it is tapped, nothing is cancelled. Cancelling never sends a request,
so no token is involved.

On Android 13+ the notification permission is requested once, on the first Download
tap. The download starts whether or not it is granted. If notifications are off,
Downloads says so and links to the system setting. A user-initiated job still appears
in the Task Manager without the permission.

### Accounts

Hosts follow `AppContainer.transferAccounts`, the live account's services. When the
account changes, the old account's transfers stop before the next account's start, and
each manager's HTTP client carries only its own account's token. An expired sign-in
records unfinished downloads as *Stopped: signed out*. They resume when the same
account signs in again. Sign-out cancels the job, stops the service, removes the
notification and wipes the account folder after every write has stopped.

## Offline library

`LibraryCache` (`accounts/<key>/library.json`) keeps the last details this device saw,
for one account. It records them from:

- library pages, in any filter, search, status or sort
- details pages
- Continue
- successful status changes
- marking a title in progress

Downloads are also merged in, from their manifest, so a downloaded title shows offline
even if it was never listed.

- **Newest wins.** Each entry keeps the time its request started. A slow, older reply
  can't replace newer details, for example a status that was just changed.
- **Bounded.** The cache holds at most 1,500 titles; the ones seen longest ago are
  evicted first. Downloaded titles are never evicted.
- **Durable.** Writes are atomic and debounced. An unreadable file is set aside and the
  cache starts again; the data can always be fetched again. Nothing is written after an
  account's services close.
- **Older versions.** The single-title store that older versions kept is still read,
  so titles opened before upgrading reopen offline.

### Offline browsing

Only a plain connection failure falls back to the cache. A certificate error, an
expired sign-in, a server error or a redirect is still shown as an error. While
offline, the Library:

- filters by type and status, and searches title and author, ignoring case and accents
- sorts by Title A–Z, or by Recent

Recent uses the server's own order, taken from the most recent unfiltered listing.
Titles that were seen only through search or details follow, newest first.

There is no paging offline: everything local that matches is shown. Changing a
filter shows local results at once while the server is tried again. A page from an
earlier query can never overwrite the current one. When Android reports a network
again, the Library and Home reload.

The offline note never claims to show the whole library unless it does:

- **Partial** (the usual case): *"34 titles this device has seen, last updated
  2 h ago. Your library on books.example.org may have more."*
- **Complete**: shown only after one unbroken pass through every page of the
  unfiltered library, and only until the cache evicts a title. *"Your whole library as
  of yesterday, 9 titles."* A complete pass also forgets titles the server no longer
  lists, except downloads.
- **Downloads only**: *"Only your downloads are on this device."*

Status changes still need the server; offline, the status picker is disabled. Reading
progress keeps its disk-first, compare-and-swap sync and conflict choices.

## Tests

- **JVM, real HTTP and files**:
  - `DownloadManagerTest`: the queue is on disk before a host is requested; pause keeps
    bytes and resumes with a range; downloads left by an earlier process are
    interrupted, or kept for a scheduled host; an expired sign-in resumes with only
    the new token; an unreadable manifest is set aside without deleting files; a
    manifest from the previous version still loads. Ready and Failed states are
    durable before observers can close the manager; reopening retains them.
  - `TransferDriverTest`: following an account switch with no old token afterwards,
    sign-out mid-transfer, and the retry budget.
  - `LibraryCacheTest`: merging, filters, ordering, coverage, bounds, persistence,
    corruption and legacy recall.
  - `LibraryViewModelTest`: offline fallback, errors that stay visible, stale pages,
    and the reconnect refresh.
- **Robolectric**:
  - `TransferSchedulerTest` covers the host chosen for API 26, 33 and 34, visible and
    not visible.
  - `RequestedScreenNavigationTest` covers a cold notification before the navigation
    graph exists, and repeated warm notification/back navigation.
  - `ScreenshotTest` renders `13-*` (offline Library: partial, complete, no matches,
    downloads only, and 320 dp at 1.6× text) and `14-*` (Downloads with stopped,
    queued and offline downloads and notifications off; dark; 320 dp at 1.6× text;
    details of an interrupted download).
- **Instrumentation** (`BackgroundDownloadsTest`, run by `android-reader-smoke.sh` on
  the accelerated CI emulator, API 35). It drives the real app: Library, then details,
  then Download. It checks that:
  - a user-initiated job is pending, and a notification with Cancel is posted;
  - Cancel deletes the bytes, and tapping the notification opens Downloads;
  - with the UI stopped, `cmd jobscheduler timeout` pauses the download with its
    bytes kept and no ready state;
  - `cmd jobscheduler run -f` resumes it with `Range` and `If-Range` to a
    byte-identical file;
  - with the server closed, the Library shows the offline note, filters by search and
    opens the downloaded title's details;
  - a notification Cancel addressed to another account is ignored.

  It saves `downloads-after-cancel.png`, `library-offline.png` and
  `details-offline-download.png` with the other smoke screenshots. The test runs in
  the app's own process, so it can't show that a killed process survives; the JVM
  tests cover reloading from disk instead. CI has no audio output, so nothing audible
  is asserted.

  [CI run 42393424465](https://github.com/Pedro-Revez-Silva/shelfarr/actions/runs/42393424465)
  passed all four emulator tests and 197 JVM/render tests on `ea6943b`. Physical-device
  and real-library validation remain outstanding.

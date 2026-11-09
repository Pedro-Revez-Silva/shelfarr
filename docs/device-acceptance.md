# Reading and listening device acceptance

This is the physical-device pass for the completion goals. Run the cases as
their features land; an unimplemented or unrun case remains pending. Simulator
and protocol results are useful evidence but do not complete hardware checks.

Keep results and screenshots outside the source tree. Record the app/server
versions, source commits, device model, OS/firmware, test time, the case and
observed result. Use a known-good fixture EPUB and multi-track audiobook. A
missing or damaged source file is not a usable playback test.

## Android preparation without modifying app data

Keep the installed app, connection and downloads. Enable USB debugging and
authorize the computer, then collect read-only package/device metadata:

```sh
python3 apps/scripts/android-device-info.py \
  --output "$HOME/.local/share/agent-reports/shelfarr/device-acceptance/android-before.json"
```

Use `--adb /path/to/adb` if Android platform tools are not on `PATH`,
`--serial` when several devices are attached, and `--package org.shelfarr.app`
for the release channel. The default is the development app. The report contains
model/OS and package versions/install times; it hashes the device serial and
does not read credentials, app storage, library contents or system logs. It
explicitly records that no behavioral tests have run.

The Android fixture instrumentation suite signs in synthetic accounts. Run
`apps/scripts/android-reader-smoke.sh` and
`apps/android/tools/upgrade-preservation.sh` on an emulator only. Both refuse
a physical or unidentified device before installing or changing anything. Do
not bypass those guards on a personal phone. A dedicated disposable test
installation needs its own explicit test setup; the cases below use the app UI.

## Android and iPad cases

For an iPad installation, follow [iOS distribution](ios-distribution.md). Free
Personal Team testing needs access to Xcode on a Mac. Keep the same installation
identity when refreshing signing. Record the iPad model and iPadOS version from
its settings, rather than using a simulator model in the hardware results.

| Case | What to exercise and verify |
| --- | --- |
| First connection | Connect using the server address or supported setup link. Approve the correct account in the browser. Close and reopen the app; the account is retained. |
| Quiet EPUB reading | Open a long chapter, move well inside it, hide controls and read. Check taps, selection, chapter changes, large text, dark mode and both orientations. Controls must not cover the normal reading surface. |
| Exact page restore | Save a place inside a chapter, close the reader, reopen offline, then rotate/change text size. The saved paragraph must be visible. Reopening and reflow must not be reported as new reading. |
| PDF and comic pages | Open known-good PDF and CBZ editions, turn pages, zoom and reopen offline. Verify the exact page returns; zooming, rotating and opening do not change the saved page or activity time. A damaged page must show an error, keep the last good place and allow navigation past it. |
| Several formats | Use one title with EPUB and PDF. The saved place chooses its own format. Explicitly open the other format, then close it without turning a page; the original place must survive, including when opening is slow or fails. |
| iPad spreads and direction | On a comic with a saved odd-page anchor, enable landscape spreads, rotate and change fit/direction. The saved anchor and time must remain unchanged even while only one half has decoded. Check real page turns in each direction and a spread with one damaged half. |
| Audio checkpoint recovery | While playing, note the position, then terminate the app without first pausing. Reopen offline. The saved checkpoint must lag the last heard position by no more than five seconds. Initial playback may rewind a further five seconds deliberately. |
| Resume rewind | Resume after a pause, then pause/resume repeatedly before passing the original saved point. The saved point must not keep moving backwards. A deliberate seek or chapter choice must not trigger an unwanted rewind. |
| OS audio controls | Play with the screen locked, background the app, use notification/lock-screen and Bluetooth controls, unplug headphones and exercise an audio interruption. Confirm pause/seek saves the place and background playback behaves correctly. |
| Interrupted download | Download a multi-track title, leave the app, lose the network and reopen it. Resume from retained bytes; only a fully downloaded title may be offered as ready offline. Cancel and remove must give accurate feedback. |
| Offline library | Download two titles, visit other library pages, go offline and relaunch. Search/filter the saved library, open downloads, and confirm the coverage note does not claim unseen titles were saved. |
| Request to consumption | Find a fixture title, approve request permission, select a format, submit once, follow pending/failure/acquired states, then open the acquired item. Repeated taps must not create unwanted duplicate requests. |
| Permission upgrade during use | While audio plays or a download runs, allow requesting through the browser for the same account. Playback, files and queued progress must survive the token handover. A lost confirmation must offer a working retry; another account must never replace the current sign-in. |
| Read-along | When available, use a genuinely aligned edition. Check that the highlighted text matches the narration, deliberate page browsing remains usable, and pause/resume, offline reopen and reconnection keep the last actual activity. An unaligned or changed edition must not offer guessed synchronization. |
| Updates retain data | Update through the server-discovered Android offer and Android's confirmation. Keep the same package and signer. Confirm the account, preferences, downloaded files and queued place remain; capture a second device-info report. Do not uninstall or disconnect as part of the check. |

For Android, a force stop also prevents scheduled work until the app is opened
again. iOS/iPadOS may delay background transfers, and an explicit force-quit
stops them until relaunch. Record which operation was used; do not classify
those platform rules as a completed background-execution test.

## Browser acceptance

Repeat the reader cases in Android Chrome, iPad Safari and desktop Chrome and
Firefox. A resized desktop viewport establishes layout behavior, not the mobile
browser's touch, audio, storage or background behavior. Record the actual browser
and OS versions. Keep unimplemented features and unrun browser combinations pending.

Use deliberate downloads over HTTPS, then disconnect the actual device from the
network and close/reopen the reader. Check text/page restore, audio seeking and
the original activity time after reconnection. Closing every browser tab may
pause downloads; do not expect native background-transfer behavior from the web
reader. Exercise denied persistence and missing cached files, and distinguish a
simulated cache deletion from eviction observed on a real device.

Use two real tabs for one account and publication. Save different places while
one upload is delayed; closing or acknowledging the other tab must not erase the
newer observation. Reopen after all uploads complete, and repeat with the tabs
reconnecting in the opposite order. Check a second signed-in account cannot open
the first account's downloads. Shared-browser account binding is a convenience,
not a substitute for separate browser profiles when people need private local
files.

## Two devices offline

Use the same account and exact edition on two independent installations.

1. Start from one synchronized place, then take both devices offline.
2. On A, read/listen and record the actual activity time and place.
3. Later on B, read/listen elsewhere. Include a deliberate backward seek in
   one run: the latest actual activity can be earlier in the book.
4. Reconnect B first, then A. Opening the title must offer B's later activity;
   A's later upload must not replace it simply because it synchronized last.
5. Repeat from fresh places with the reconnection order reversed. Include a
   restart of both apps before reconnecting. Both orders must converge.

If clocks or editions cannot be compared reliably, the app must preserve the
places and ask for a choice. Record both observations before choosing; do not
silently treat the furthest percentage as the newest activity.

## Kobo generations and Store coexistence

Repeat the [Kobo acceptance matrix](kobo.md#physical-device-acceptance-matrix)
on the oldest, middle and newest stock Kobo available. Back up the original
configuration before editing it by USB. Do not reset or sign out the device.

For coexistence, start with that reader's own Kobo account and a downloaded
Store purchase. Enable the coexistence mode and select a Shelfarr fixture book.
Verify both catalogues synchronize, both books open, a second sync creates no
duplicate and neither reading place resets. Exercise a Store outage and retry;
the Shelfarr selection and last Store cursor must survive. Restore the original
endpoint to verify the rollback path.

For shared progress, use the same supported edition on Kobo and a native/web
client. Move in both directions and reconnect in both orders. Unsupported Kobo
locations must be retained with an explanation and an explicit choice, rather
than guessed into an exact app location. Store catalogue visibility alone is
not evidence that a protected purchase opens on another account's reader.

Never include a private device connection URL, approval code, provider token or
account key in evidence. Crop setup screenshots before sharing them. Keep real
book text out of public reports; use fixture content for reproducible UI captures.

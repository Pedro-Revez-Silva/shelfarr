# Consumer platform preview: upgrade and testing

All reading, listening, native-app, offline and Kobo work is integrated on
`feat/consumer-platform`. Test and fix the combined platform on this branch.
The earlier stacked PRs are historical; they are not separate release steps.

## Upgrade notice

**Treat this preview as a breaking update and test before upgrading a shared
instance.** It includes database migrations and new reader, offline, native-app
and Kobo workflows. Device acceptance is still in progress.

Before updating, back up the server's complete storage, including its databases
and encryption keys, together with the deployment configuration. Keep the previous
image and backup. A rollback that requires restoring data must use the matching
databases and keys; changes made after that backup would need to be recovered
separately.

Update an existing Android installation through its normal update flow, with the
same package and signing key. Keep the app installed and connected while checking
that its settings, downloads and saved places survive. Development and production
packages are separate installations. For iPad installation and signing, use the
[iOS distribution guide](ios-distribution.md).

## Start with the everyday flow

Use one known-good EPUB and one known-good audiobook before testing more unusual
formats or Kobo delivery.

1. **Existing account and library.** Sign in through the normal web interface.
   Check familiar library items, their details and their files. Open the Android
   app and confirm its existing server, account and downloads are still present.
2. **Read and reopen.** Read well inside a chapter, close the book and reopen it.
   The same paragraph should be visible. Rotate the screen and change text size;
   the paragraph should remain visible and reopening should not move the saved
   place.
3. **Listen and resume.** Play, pause, leave the player and reopen it. Resume should
   rewind once by up to five seconds. Repeated pause/play during that replay
   should not keep moving backwards. Check background and lock-screen controls
   on the actual device.
4. **Download and go offline.** Download both items deliberately. Disconnect the
   device from the network, close and reopen the app or reader, and use both
   downloads. Reconnect and confirm that the places reached offline are retained.

If one of these fails, capture that failure before proceeding to the next group.

## Then exercise the new features

- **Two devices:** use the same account and edition, read or listen on each device
  at different times, then reconnect in each order. The latest actual activity
  should win, including a deliberate move backwards in the book.
- **Find and request:** approve requesting for the correct account, request an
  ebook or audiobook, follow its stages and use **Read now** or **Listen now**.
  Repeated taps should create one request. The existing connection, downloads
  and playback should survive the permission upgrade.
- **PDF and comics:** turn pages, zoom, rotate, change direction or iPad spreads,
  then reopen offline. The exact saved page should return; layout changes should
  not become new reading activity.
- **Read-along:** use an edition with real alignment. Check the highlight, page
  following, browsing away, pause/resume and offline reopening. Ordinary or
  unaligned books should remain readable without guessed narration alignment.
- **Accounts:** use disposable test accounts to check that private downloads and
  requests belong to the correct person when switching accounts.
- **Kobo last:** start with one reader and one book. Follow [Kobo setup](kobo.md),
  retaining the original configuration. Test Store coexistence with that reader's
  own Kobo account before household sharing. For sharing, use an eligible
  purchased DRM-free EPUB, then check prepare, delivery, another sync and
  revocation. Protected-book sharing is not implemented. Record the actual
  reader behavior rather than assuming it from server tests.

## Record results

For each problem, note the server and app versions, device/browser and OS, book
format, steps, expected result and observed result. Include a screenshot when it
helps. Keep the edition and starting place consistent when comparing devices.

The [completion goals](consumer-completion.md) track the full scope. The
[device acceptance guide](device-acceptance.md) contains the deeper cases for
interruptions, offline conflicts, upgrades and platform-specific behavior.
Automated checks and simulator passes do not complete those physical-device cases.

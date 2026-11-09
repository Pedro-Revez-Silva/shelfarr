# Reading and listening completion goals

Requested on 2026-11-09. This is the working acceptance list for the complete
request-to-reading/listening experience, starting from the tested consumer and
Kobo account stack. A checkbox means the behavior has been implemented and
verified; a build or simulated test alone does not establish device acceptance.

## Kobo Store coexistence and account-owned books

- [ ] Opt-in coexistence preserves a reader's own Kobo Store authentication,
  Store catalogue and supported Store operations alongside selected Shelfarr books.
- [ ] Setup clearly explains the mode, keeps the original endpoint recoverable,
  and works across deployment subpaths.
- [ ] Store failures cannot discard local selections, reset progress, cross
  account boundaries or expose connection secrets.
- [ ] The connected real account is used to verify supported account/catalogue
  behavior without changing purchases or resetting devices.
- [ ] Household catalogue sharing is explicitly granted and revocable by its owner.
- [ ] Store-book delivery is enabled only for formats and authorization paths
  proven to work. Account connection alone is not proof of cross-account playback.

## Shared reading and listening places

- [ ] Kobo locations map to the same publication/edition and shared progress
  model as web, Android and iOS, with unsupported locations handled explicitly.
- [ ] Actual activity time survives offline queues, retries and restarts.
  Synchronization time never replaces it when ordering progress.
- [ ] Restoration, resizing, receipt of a remote place and resume rewind do not
  manufacture reading/listening activity.
- [ ] Audio loses no more than five seconds between local checkpoints, and
  resume rewinds once without repeatedly moving the saved place backwards.
- [ ] Reconnection in either order converges on the latest actual activity;
  ambiguous clocks or editions preserve both places for an explicit choice.

## Native acquisition

- [ ] Android and iOS support finding a title, selecting a supported format,
  requesting it, following acquisition status and opening the acquired item.
- [ ] Request permissions are explicitly approved. Existing reader tokens do
  not silently gain write scopes, and existing downloads/settings are preserved.
- [ ] Duplicate submissions, cancellation, provider failure, empty results,
  large text and offline behavior are tested and understandable in the UI.

## Reading formats and web offline use

- [ ] PDF and comic reading work through bounded, authorized asset handling
  with durable, edition-specific page positions on supported clients.
  API, web and Android readers implemented ([formats](consumer-formats.md));
  iOS/iPad implementation awaits SDK/runtime checks. Device acceptance pending.
- [ ] Web users can deliberately download supported books/audio, see storage
  and download state, reopen offline and later synchronize their saved place.
- [ ] Account changes, updates and cache eviction cannot silently mix accounts
  or falsely mark incomplete downloads ready.
- [ ] Read-along uses real text/audio alignment, with a quiet reading surface,
  usable controls and reliable resume. Unaligned editions are identified honestly.
  Server contract and web reader implemented, online and offline
  ([read-along](read-along.md)); native Android and iOS/iPad implementations
  include regression and smoke coverage. Final SDK/runtime and device acceptance
  remain pending; Linux/render checks do not establish hardware behavior.

## Distribution and acceptance

- [ ] A production Android publication exercises signing, compatibility-catalogue
  promotion, server caching and an actual upgrade preserving user data.
- [ ] A signed iPad build is installable through a documented distribution path.
- [ ] Automated UI tests exercise the new flows; UI opinions and implementation
  use Claude Opus 5.5 with high effort as requested.
- [ ] Android and iPad hardware checks cover offline use, background audio,
  Bluetooth/lock-screen controls, interruptions, restart and progress recovery.
- [ ] The oldest, middle and newest stock Kobo generations pass the acceptance
  matrix in `kobo.md`, including coexistence and progress behavior.

Physical devices, Apple signing/distribution access and any human-only approval
are recorded as gates rather than marked complete by simulator results. The
existing server, account credentials, personal library and device configuration
must be preserved throughout implementation and deployment.

Use [the device acceptance guide](device-acceptance.md) for the physical pass and
read-only Android version collection. Fixture instrumentation is emulator-only.

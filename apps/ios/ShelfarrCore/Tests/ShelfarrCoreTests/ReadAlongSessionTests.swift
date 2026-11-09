import Foundation
@testable import ShelfarrCore
import XCTest

/// The session's rules, and places heard written through the production stores, syncs
/// and listening checkpoints.
final class ReadAlongSessionTests: XCTestCase {
    private typealias F = ReadAlongFixture

    // MARK: Highlight and follow

    func testThePageStaysQuietUntilNarrationPlays() {
        var session = ReadAlongSession(manifest: F.overlay)
        session.restore(F.heard(F.overlay, audio: 0, ms: 3000))
        let restored = session.tick(audio: 0, ms: 3000, playing: false)
        XCTAssertNil(restored.highlight, "opening shows nothing")
        XCTAssertNil(restored.follow)
        XCTAssertFalse(session.started, "no pill before playback")
        session.began()
        let playing = session.tick(audio: 0, ms: 3100, playing: true)
        XCTAssertEqual(playing.highlight, 1)
        XCTAssertTrue(playing.changed)
        XCTAssertTrue(session.started)
    }

    func testOnlyTheCueBeingHeardIsHighlightedAndNothingBetweenCues() {
        var session = ReadAlongSession(manifest: F.overlay)
        session.began()
        XCTAssertEqual(session.tick(audio: 0, ms: 100, playing: true).highlight, 0)
        XCTAssertFalse(session.tick(audio: 0, ms: 1500, playing: true).changed, "the same cue is not redrawn")
        let gap = session.tick(audio: 0, ms: 2200, playing: true)
        XCTAssertNil(gap.highlight, "silence highlights nothing")
        XCTAssertTrue(gap.changed)
        XCTAssertEqual(session.heard?.cue, 0, "but the narration reached is still p1")
        XCTAssertEqual(session.tick(audio: 0, ms: 2600, playing: true).highlight, 1)
        session.paused()
        XCTAssertEqual(session.tick(audio: 0, ms: 2600, playing: false).highlight, 1, "a pause keeps the cue heard")
        XCTAssertNil(session.tick(audio: 0, ms: 4700, playing: false).highlight, "paused in a gap shows nothing")
    }

    func testThePageFollowsEachCueOnceAndOnlyWhilePlayingWithFollowOn() {
        var session = ReadAlongSession(manifest: F.overlay)
        session.began()
        XCTAssertEqual(session.tick(audio: 0, ms: 0, playing: true).follow, 0)
        XCTAssertNil(session.tick(audio: 0, ms: 500, playing: true).follow, "followed once per cue; the app checks visibility")
        XCTAssertNil(session.tick(audio: 0, ms: 2200, playing: true).follow, "a gap is never followed")
        XCTAssertEqual(session.tick(audio: 0, ms: 2500, playing: true).follow, 1)
        session.paused()
        XCTAssertNil(session.tick(audio: 0, ms: 5000, playing: false).follow, "a paused player moves no page")
        XCTAssertNil(session.setFollow(false))
        session.began()
        XCTAssertNil(session.tick(audio: 0, ms: 5100, playing: true).follow, "Follow off")
        XCTAssertEqual(session.setFollow(true), 2, "turning it on brings the cue into view")
    }

    func testTurningPagesWhileNarrationPlaysIsBrowsing() {
        var session = ReadAlongSession(manifest: F.overlay)
        session.began()
        _ = session.tick(audio: 0, ms: 100, playing: true)
        XCTAssertEqual(session.readerTurned(), .browsing)
        XCTAssertTrue(session.suspended, "following pauses while browsing")
        XCTAssertNil(session.tick(audio: 0, ms: 2600, playing: true).follow, "the next cue doesn't pull the page back")
        XCTAssertEqual(session.tick(audio: 0, ms: 2700, playing: true).highlight, 1, "the highlight still follows the narration")
        XCTAssertEqual(session.returnToNarration(), 1)
        XCTAssertFalse(session.suspended)
        XCTAssertEqual(session.plan(loaded: true), .resume, "browsing didn't make the narration's place a reading place")
    }

    func testTurningPagesWhilePausedIsReadingAndPlayStartsFromThatPage() {
        var session = ReadAlongSession(manifest: F.overlay)
        session.began()
        _ = session.tick(audio: 0, ms: 3000, playing: true)
        session.paused()
        XCTAssertEqual(session.plan(loaded: true), .resume)
        XCTAssertEqual(session.readerTurned(), .reading)
        XCTAssertFalse(session.suspended)
        XCTAssertEqual(session.plan(loaded: true), .fromPage, "the next Play follows the page read")
        session.began()
        XCTAssertEqual(session.plan(loaded: true), .resume)
        session.ended()
        XCTAssertEqual(session.plan(loaded: true), .fromPage, "after the last file, Play starts from the page")
    }

    func testRestoringAHeardPlaceResumesItAndAReadingPlaceStartsFromThePage() {
        var session = ReadAlongSession(manifest: F.overlay)
        session.restore(F.heard(F.overlay, audio: 1, ms: 3500))
        XCTAssertEqual(session.plan(loaded: false), .open(.init(audio: 1, ms: 3500, cue: 4, exact: true), .resume))
        session.restore(.object(["href": .string("OEBPS/c1.xhtml"), "locations": .object(["fragments": .array([.string("p3")]), "progression": .number(0.4)])]))
        XCTAssertEqual(session.plan(loaded: false), .fromPage, "a page read is where Play starts")
        session.restore(nil)
        XCTAssertEqual(session.plan(loaded: false), .fromPage)
    }

    func testALaterAudiobookPlaceIsOfferedNeverApplied() {
        let manifest = F.imported
        var session = ReadAlongSession(manifest: manifest)
        session.restore(F.heard(manifest, audio: 0, ms: 600))
        let later = manifest.point(audiobookAsset: "track-b", seconds: 1)
        session.consider(audiobook: later, observedAt: baseTime + 60_000, ebookObservedAt: baseTime, now: baseTime + 120_000)
        XCTAssertEqual(session.offer, later)
        XCTAssertEqual(session.plan(loaded: false), .open(.init(audio: 0, ms: 600, cue: 0, exact: true), .resume), "the offer changes nothing by itself")
        XCTAssertEqual(session.acceptOffer(), later)
        XCTAssertEqual(session.plan(loaded: false), .open(later!, .adopted), "the audiobook's place plays from exactly there, without a rewind")

        session.restore(F.heard(manifest, audio: 0, ms: 600))
        session.consider(audiobook: later, observedAt: baseTime - 1, ebookObservedAt: baseTime, now: baseTime + 120_000)
        XCTAssertNil(session.offer, "an older audiobook place isn't offered")
        session.consider(audiobook: manifest.point(audiobookAsset: "track-a", seconds: 1.2), observedAt: baseTime + 60_000, ebookObservedAt: baseTime, now: baseTime + 120_000)
        XCTAssertNil(session.offer, "the same element isn't offered")
        session.consider(audiobook: later, observedAt: baseTime + 3_600_000, ebookObservedAt: baseTime, now: baseTime + 120_000)
        XCTAssertNil(session.offer, "an implausible future time isn't trusted")
        session.consider(audiobook: later, observedAt: baseTime + 60_000, ebookObservedAt: nil, now: baseTime + 120_000)
        XCTAssertEqual(session.offer, later, "an ebook with no known time")
        session.dismissOffer()
        XCTAssertNil(session.offer)
    }

    func testAnAdoptedPlaceReplacesLoadedNarrationOnTheNextPlayOnly() throws {
        var session = ReadAlongSession(manifest: F.overlay)
        session.began()
        _ = session.tick(audio: 0, ms: 3000, playing: true)
        session.paused()
        let locator = F.heard(F.overlay, audio: 1, ms: 3500)
        let point = try XCTUnwrap(F.overlay.point(from: locator))
        session.restore(locator, arrival: .adopted)
        XCTAssertNil(session.tick(audio: 0, ms: 3000, playing: false).highlight)
        XCTAssertEqual(session.heard, point, "the old paused item's reports cannot replace the pending choice")
        XCTAssertEqual(session.plan(loaded: true), .open(point, .adopted), "reader and media Play must consume the remote point even with audio loaded")
        XCTAssertFalse(session.playing, "adopting never starts playback")

        var checkpoints = ListeningCheckpoints()
        let saved = SavedPosition(assetId: "read-along:1", positionSeconds: point.seconds)
        checkpoints.hold(saved)
        XCTAssertNil(checkpoints.resumed(at: saved), "the adopted point is not a five-second resume")
        XCTAssertFalse(checkpoints.isActivity(saved), "arriving does not create activity")
        session.began()
        XCTAssertNil(session.restored)
        XCTAssertEqual(session.plan(loaded: true), .resume, "the chosen point is consumed once")
    }

    func testAcceptingAnAudiobookOfferAlsoReplacesLoadedNarration() throws {
        var session = ReadAlongSession(manifest: F.imported)
        session.began()
        _ = session.tick(audio: 0, ms: 800, playing: true)
        session.paused()
        let later = try XCTUnwrap(F.imported.point(audiobookAsset: "track-b", seconds: 3.5))
        session.consider(audiobook: later, observedAt: baseTime + 60_000, ebookObservedAt: baseTime, now: baseTime + 120_000)
        XCTAssertEqual(session.plan(loaded: true), .resume, "merely offering changes nothing")
        XCTAssertEqual(session.acceptOffer(), later)
        XCTAssertEqual(session.plan(loaded: true), .open(later, .adopted))
        _ = session.tick(audio: 0, ms: 800, playing: false)
        XCTAssertEqual(session.heard, later)
        XCTAssertEqual(session.readerTurned(), .reading)
        XCTAssertEqual(session.plan(loaded: true), .fromPage, "reading after the choice takes precedence")
    }

    // MARK: Places heard, through the production stores

    private struct Pair {
        let directory: URL
        let server: ContractServer
        let audiobookServer: ContractServer
        let clock: ManualClock
        let ebookStore: FileProgressStore
        let audiobookStore: FileProgressStore
        let ebook: ProgressSync
        let audiobook: ProgressSync

        static func make(_ directory: URL, server: ContractServer? = nil, audiobookServer: ContractServer? = nil, clock: ManualClock = ManualClock(baseTime),
                         onSend: (@Sendable (String) async -> Void)? = nil) -> Pair {
            let server = server ?? ContractServer(clock: baseTime + 3_600_000)
            let audiobookServer = audiobookServer ?? ContractServer(clock: baseTime + 3_600_000)
            // One account file, as the app keeps it.
            let store = FileProgressStore(file: directory.appendingPathComponent("progress.json"))
            var timing = SyncTiming()
            timing.debounce = .seconds(600)
            timing.maxWait = .seconds(600)
            timing.firstRetry = .seconds(600)
            let ebook = ProgressSync(publicationId: "12", store: store, remote: {
                await onSend?($0)
                return try await server.save($0, $1)
            }, timing: timing, now: { clock.now })
            let audiobook = ProgressSync(publicationId: "40", store: store, remote: {
                await onSend?($0)
                return try await audiobookServer.save($0, $1)
            }, timing: timing, now: { clock.now })
            return Pair(directory: directory, server: server, audiobookServer: audiobookServer, clock: clock, ebookStore: store, audiobookStore: store, ebook: ebook, audiobook: audiobook)
        }
    }

    func testAnImportedCheckpointWritesBothPlacesWithOneTimeBothOnDiskFirst() async throws {
        let directory = F.temporaryDirectory("coupled")
        let file = directory.appendingPathComponent("progress.json")
        let seen = SendLog()
        let pair = Pair.make(directory, onSend: { publication in
            // Whichever is sent first, both places are already durable on this device.
            let stored = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: LocalProgress].self, from: $0) } ?? [:]
            await seen.note(publication, bothOnDisk: stored["12"]?.position != nil && stored["40"]?.position != nil)
        })
        let writer = ReadAlongProgress(manifest: F.imported, ebook: pair.ebook, audiobook: pair.audiobook)
        let heardAt = baseTime + 1234
        let written = await writer.checkpoint(audio: 1, ms: 3500, observedAt: heardAt, flush: true)
        XCTAssertEqual(written.observedAt, heardAt)
        XCTAssertEqual(written.audiobook, SavedPosition(assetId: "track-b", positionSeconds: 3.5))
        XCTAssertEqual(written.ebook?.locator?["locations"]?["fragments"], .array([.string("q2")]))

        await pair.ebook.flush()
        await pair.audiobook.flush()
        let sends = await seen.entries
        XCTAssertEqual(Set(sends.map(\.publication)), ["12", "40"])
        XCTAssertTrue(sends.allSatisfy(\.bothOnDisk), "neither was sent before both were saved locally")
        let ebookSent = try XCTUnwrap(pair.server.received.last)
        let audiobookSent = try XCTUnwrap(pair.audiobookServer.received.last)
        XCTAssertEqual(ebookSent.observedAt, ActivityTime.format(heardAt))
        XCTAssertEqual(audiobookSent.observedAt, ebookSent.observedAt, "the same observed_at for both")
        XCTAssertEqual(audiobookSent.assetId, "track-b")
        XCTAssertEqual(audiobookSent.positionSeconds, 3.5)
        XCTAssertNil(audiobookSent.locator)
        XCTAssertEqual(ebookSent.assetId, F.ebookAssetId)
        XCTAssertEqual(ReadAlongManifest.readAlongPoint(ebookSent.locator?["locations"]?["readAlong"])?.offsetMs, 3500)
    }

    func testTheTimeHeardSurvivesAnOfflineQueueAndARestart() async throws {
        let directory = F.temporaryDirectory("restart")
        let server = ContractServer(clock: baseTime + 3_600_000)
        let audiobookServer = ContractServer(clock: baseTime + 3_600_000)
        let first = Pair.make(directory, server: server, audiobookServer: audiobookServer)
        let writer = ReadAlongProgress(manifest: F.imported, ebook: first.ebook, audiobook: first.audiobook)
        let heardAt = baseTime + 5000
        server.fail(.offline)
        audiobookServer.fail(.loseResponse)
        await writer.checkpoint(audio: 0, ms: 2700, observedAt: heardAt, flush: true)
        await first.ebook.flush()
        await first.audiobook.flush()
        XCTAssertEqual(server.received.count, 1)
        XCTAssertNil(server.stored, "offline: nothing reached the server")
        await first.ebook.stop()
        await first.audiobook.stop()

        // A cold relaunch, minutes later, with a fresh store reading the same file.
        let clock = ManualClock(baseTime + 600_000)
        let second = Pair.make(directory, server: server, audiobookServer: audiobookServer, clock: clock)
        await second.ebook.flush()
        await second.audiobook.flush()
        XCTAssertEqual(server.stored?.observedAt, ActivityTime.format(heardAt), "the queued place kept the time it was heard")
        XCTAssertEqual(audiobookServer.stored?.observedAt, ActivityTime.format(heardAt))
        XCTAssertEqual(audiobookServer.received.map(\.clientMutationId).count, 2)
        XCTAssertEqual(Set(audiobookServer.received.map(\.clientMutationId)).count, 1, "a retry repeats the same write")
    }

    func testFlushingPausedNarrationKeepsTheLaterReadPageAndBothActivityTimes() async throws {
        let directory = F.temporaryDirectory("paused-reading-flush")
        let pair = Pair.make(directory)
        let writer = ReadAlongProgress(manifest: F.imported, ebook: pair.ebook, audiobook: pair.audiobook)
        await writer.checkpoint(audio: 0, ms: 3000, observedAt: baseTime, flush: false)
        let page = SavedPosition(assetId: F.ebookAssetId, locator: .object([
            "href": .string("OEBPS/c2.xhtml"), "locations": .object(["progression": .number(0.5)]),
        ]))
        _ = await pair.ebook.record(page, observedAt: baseTime + 1000)

        // Background and close flush what was already reached; neither observes the
        // still-paused 3s narration again. Read through a fresh store after both.
        await writer.flush()
        await writer.flush()
        await pair.ebook.flush()
        await pair.audiobook.flush()
        let fresh = FileProgressStore(file: directory.appendingPathComponent("progress.json"))
        let savedEbook = try await fresh.get("12")
        let savedAudiobook = try await fresh.get("40")
        let ebook = try XCTUnwrap(savedEbook)
        let audiobook = try XCTUnwrap(savedAudiobook)
        XCTAssertEqual(ebook.position, page)
        XCTAssertEqual(ebook.observedAt, baseTime + 1000)
        XCTAssertEqual(audiobook.position, SavedPosition(assetId: "track-a", positionSeconds: 3))
        XCTAssertEqual(audiobook.observedAt, baseTime)
        XCTAssertEqual(pair.server.stored?.locator, page.locator)
        XCTAssertEqual(pair.server.stored?.observedAt, ActivityTime.format(baseTime + 1000))
        XCTAssertEqual(pair.audiobookServer.stored?.observedAt, ActivityTime.format(baseTime))
        await pair.ebook.stop()
        await pair.audiobook.stop()
    }

    func testAMediaOverlayWritesOnlyTheEbookAndNothingBeforeAFirstCue() async throws {
        var object = F.overlayObject()
        object["cues"] = [[0, "p1", 0, 1500, 2000], [1, "q1", 1, 0, 1000]]
        let manifest = try F.parse(object)
        let pair = Pair.make(F.temporaryDirectory("overlay"))
        let writer = ReadAlongProgress(manifest: manifest, ebook: pair.ebook, audiobook: pair.audiobook)
        let early = await writer.checkpoint(audio: 0, ms: 900, observedAt: baseTime, flush: true)
        XCTAssertNil(early.ebook, "nothing is written before the first cue is reached")
        XCTAssertNil(early.audiobook, "a media overlay has no separate audiobook")
        await pair.ebook.flush()
        XCTAssertTrue(pair.server.received.isEmpty)
        let reached = await writer.checkpoint(audio: 0, ms: 1600, observedAt: baseTime + 700, flush: true)
        XCTAssertNotNil(reached.ebook)
        await pair.ebook.flush()
        XCTAssertEqual(pair.server.received.count, 1)
        XCTAssertTrue(pair.audiobookServer.received.isEmpty)
    }

    func testAClockSteppingBackStillGivesBothTheSameTime() async throws {
        let pair = Pair.make(F.temporaryDirectory("clock"))
        let writer = ReadAlongProgress(manifest: F.imported, ebook: pair.ebook, audiobook: pair.audiobook)
        // The audiobook was heard on its own player a moment "later" than this clock now says.
        await pair.audiobook.update(SavedPosition(assetId: "track-a", positionSeconds: 0.5), observedAt: baseTime + 2000)
        let written = await writer.checkpoint(audio: 0, ms: 3000, observedAt: baseTime + 1000, flush: false)
        XCTAssertEqual(written.observedAt, baseTime + 2001, "moved past the audiobook's own last observation")
        let ebook = await pair.ebook.snapshot()
        let audiobook = await pair.audiobook.snapshot()
        XCTAssertEqual(ebook.observedAt, baseTime + 2001)
        XCTAssertEqual(audiobook.observedAt, ebook.observedAt)
    }

    /// The player's listening checkpoints, called in the order `PlaybackEngine` calls them,
    /// with places written through `ReadAlongProgress`.
    func testAResumeReplaysFiveSecondsOnceAndPausingInTheReplayKeepsTheSavedPlace() async throws {
        let manifest = F.imported
        let pair = Pair.make(F.temporaryDirectory("rewind"))
        let writer = ReadAlongProgress(manifest: manifest, ebook: pair.ebook, audiobook: pair.audiobook)
        let key = { (audio: Int) in "read-along:\(audio)" }
        var checkpoints = ListeningCheckpoints()
        var session = ReadAlongSession(manifest: manifest)
        let saved = F.heard(manifest, audio: 1, ms: 9000)
        session.restore(saved)
        await pair.ebook.begin(position: SavedPosition(assetId: F.ebookAssetId, locator: saved), baseVersion: 0, observedAt: baseTime)

        // Play: a genuine resume of the restored place.
        guard case let .open(point, .resume) = session.plan(loaded: false) else { return XCTFail("\(session.plan(loaded: false))") }
        var at = checkpoints.open(SavedPosition(assetId: key(point.audio), positionSeconds: point.seconds), firstTrack: key(0))
        XCTAssertEqual(at, 4.0, "five seconds earlier, once")
        session.began()

        var writes = 0
        func heard(_ seconds: Double, flush: Bool) async {
            let place = SavedPosition(assetId: key(1), positionSeconds: seconds)
            guard checkpoints.isActivity(place) else { return }
            writes += 1
            await writer.checkpoint(audio: 1, ms: Int64(seconds * 1000), observedAt: baseTime + Int64(seconds * 1000), flush: flush)
        }
        // Ticks inside the replay, then a pause in it: none of it is new listening.
        for second in stride(from: 4.5, through: 7.0, by: 0.5) { await heard(second, flush: false) }
        checkpoints.paused()
        session.paused()
        await heard(7.0, flush: true)
        XCTAssertEqual(writes, 0, "the replayed seconds wrote nothing")
        // Playing again inside the replay continues without another rewind.
        XCTAssertEqual(session.plan(loaded: true), .resume)
        XCTAssertNil(checkpoints.resumed(at: SavedPosition(assetId: key(1), positionSeconds: 7.0)), "no second rewind")
        session.began()
        at = 7.0
        // Passing the saved place is new listening.
        await heard(9.5, flush: false)
        XCTAssertEqual(writes, 1)
        let stored = await pair.ebook.snapshot()
        XCTAssertEqual(ReadAlongManifest.readAlongPoint(stored.position?.locator?["locations"]?["readAlong"])?.offsetMs, 9500)
        // The next pause after passing it arms a fresh rewind.
        checkpoints.paused()
        XCTAssertEqual(checkpoints.resumed(at: SavedPosition(assetId: key(1), positionSeconds: 9.5)), 4.5)
        _ = at
    }

    func testRestoringAndAdoptingWriteNothing() async throws {
        let manifest = F.overlay
        let pair = Pair.make(F.temporaryDirectory("silent"))
        let saved = SavedPosition(assetId: F.ebookAssetId, locator: F.heard(manifest, audio: 0, ms: 3000))
        await pair.ebook.begin(position: saved, baseVersion: 3, observedAt: baseTime)
        var session = ReadAlongSession(manifest: manifest)
        session.restore(saved.locator)
        _ = session.tick(audio: 0, ms: 3000, playing: false)
        _ = session.returnToNarration()
        // Restoring the exact saved place again (a follow, a layout) is the same place.
        await pair.ebook.update(saved, observedAt: baseTime + 10_000)
        await pair.ebook.flush()
        XCTAssertTrue(pair.server.received.isEmpty, "restoring, following and repeating the saved place sent nothing")
        let record = await pair.ebook.snapshot()
        XCTAssertFalse(record.dirty)
        XCTAssertEqual(record.observedAt, baseTime, "the saved place keeps the time it was heard")
    }
}

private actor SendLog {
    struct Entry { let publication: String; let bothOnDisk: Bool }
    private(set) var entries: [Entry] = []
    func note(_ publication: String, bothOnDisk: Bool) { entries.append(Entry(publication: publication, bothOnDisk: bothOnDisk)) }
}

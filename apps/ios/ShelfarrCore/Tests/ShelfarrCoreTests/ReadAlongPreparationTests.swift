import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ShelfarrCore
import XCTest

/// The real account downloads, with an optional hold just before a companion is queued
/// (the suspension between a preparation's last check and the manager's enqueue).
final class HeldDownloads: ReadAlongDownloads, @unchecked Sendable {
    let base: DownloadManager
    let beforeEnqueue: HoldPoint?
    let enqueued = Shared<[String]>([])

    init(_ base: DownloadManager, beforeEnqueue: HoldPoint? = nil) {
        self.base = base
        self.beforeEnqueue = beforeEnqueue
    }

    func record(_ publicationId: String) async -> DownloadRecord? { await base.record(publicationId) }
    func ready(_ publicationId: String) async -> DownloadRecord? { await base.ready(publicationId) }
    func fileURL(_ record: DownloadRecord, assetId: String) async -> URL? { await base.fileURL(record, assetId: assetId) }
    func fileURLs(_ record: DownloadRecord) async -> [String: URL]? { await base.fileURLs(record) }
    func enqueue(_ publication: Publication, format: ReaderFormat?) async {
        await beforeEnqueue?.wait()
        enqueued.value.append(publication.id)
        await base.enqueue(publication, format: format)
    }
    func cancelUnfinished(_ publicationId: String, if allowed: @Sendable () -> Bool) async -> Bool {
        await base.cancelUnfinished(publicationId, if: allowed)
    }
}

/// The real download manager, read-along library and preparation coordinator for one
/// account, over a fake server whose transfers stay in flight until served, and the
/// app's request, cancel and remove hooks.
class ReadAlongPreparationTestCase: DownloadTestCase {
    typealias F = ReadAlongFixture

    var router = TransferRouter()
    /// Transfers stay in flight until the test serves them; like a system session, they outlive a relaunch.
    lazy var system = FakeSystem(router: router)
    /// Holds the cancelling of audiobook transfers once closed (`hold()`).
    let cancelGate = HoldPoint(open: true)
    let bookData = ReadAlongFixture.epub().data
    let trackA = Data(repeating: 3, count: 1000)
    let trackB = Data(repeating: 4, count: 2000)
    let otherAssetId = String(repeating: "f", count: 64)

    lazy var ebook = Publication(id: "12", title: "Book", bookType: .ebook, assets: [
        Asset(id: F.ebookAssetId, filename: "b.epub", mediaType: "application/epub+zip", format: "epub", sizeBytes: Int64(bookData.count), contentUrl: "/files/ebook"),
    ])
    lazy var otherEbook = Publication(id: "13", title: "Other edition", bookType: .ebook, assets: [
        Asset(id: otherAssetId, filename: "c.epub", mediaType: "application/epub+zip", format: "epub", sizeBytes: Int64(bookData.count), contentUrl: "/files/other"),
    ])
    lazy var narration = Publication(id: "40", title: "Narration", bookType: .audiobook, assets: [
        Asset(id: "track-a", filename: "01.mp3", mediaType: "audio/mpeg", format: "mp3", sizeBytes: 1000, contentUrl: "/files/track-a", position: 1),
        Asset(id: "track-b", filename: "02.mp3", mediaType: "audio/mpeg", format: "mp3", sizeBytes: 2000, contentUrl: "/files/track-b", position: 2),
    ])

    var downloads: DownloadManager!
    var library: ReadAlongLibrary!
    var preparations: ReadAlongPreparations!

    var companionsFile: URL { root.appendingPathComponent("acct/read-along/companions.json") }

    private func makeDownloads() -> DownloadManager {
        let executor = HeldExecutor(system, gate: cancelGate, holds: { $0.request.url!.path.hasPrefix("/files/track-") })
        return manager(executors: DownloadExecutors(foreground: executor), router: router)
    }

    /// A new process over the same disk: new router, manager, library and coordinator.
    /// The old objects are abandoned, not closed, as when the system ends the app.
    func relaunch() async {
        router = TransferRouter()
        system.router = router
        downloads = makeDownloads()
        await downloads.start()
        library = ReadAlongLibrary(root: root.appendingPathComponent("acct/read-along"))
        preparations = ReadAlongPreparations(storage: companionsFile)
    }

    /// Companion ownership as it is on disk now.
    func storedCompanions() -> [String: [String: Any]]? {
        guard let data = try? Data(contentsOf: companionsFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["companions"] as? [String: [String: Any]]
    }

    override func setUp() {
        super.setUp()
        transport["/files/ebook"] = .init(data: bookData, etag: "\"book\"")
        transport["/files/other"] = .init(data: bookData, etag: "\"other\"")
        transport["/files/track-a"] = .init(data: trackA, etag: "\"a\"")
        transport["/files/track-b"] = .init(data: trackB, etag: "\"b\"")
        publications = [ebook.id: ebook, otherEbook.id: otherEbook, narration.id: narration]
        downloads = makeDownloads()
        library = ReadAlongLibrary(root: root.appendingPathComponent("acct/read-along"))
        preparations = ReadAlongPreparations(storage: companionsFile)
    }

    // MARK: Fixtures

    func imported(_ publicationId: String = "12", ebookAssetId: String = F.ebookAssetId, generation: String = F.generation) -> ReadAlongPreparations.Fetched {
        var object = F.importedObject(generation: generation)
        object["publication_id"] = publicationId
        object["ebook_asset_id"] = ebookAssetId
        let data = F.data(object)
        let manifest = try! ReadAlongManifest.parse(data, ebookAssetId: ebookAssetId, generation: generation, publicationId: publicationId, server: F.server)
        return (data, manifest)
    }

    func overlay() -> ReadAlongPreparations.Fetched {
        let data = F.data(F.overlayObject(audioSizes: [1000, Int64(LongDeflate.text.count)]))
        return (data, try! ReadAlongManifest.parse(data, ebookAssetId: F.ebookAssetId, generation: F.generation, publicationId: "12", server: F.server))
    }

    func bookFolder(_ publicationId: String = "12") -> URL {
        root.appendingPathComponent("acct/read-along").appendingPathComponent(String(SHA256.hexDigest(Data(publicationId.utf8)).prefix(32)))
    }

    func generations(_ publicationId: String = "12") -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: bookFolder(publicationId).path)) ?? []).filter(ReadAlongManifest.isGeneration).sorted()
    }

    func liveJobs(_ path: String) -> [FakeSystem.Job] {
        system.live.filter { $0.request.url!.path == path }
    }

    /// Serves a book's file so its download becomes ready.
    func finishBook(_ publication: Publication, path: String, etag: String) async throws {
        try await until("the book's transfer") { !liveJobs(path).isEmpty }
        for job in liveJobs(path) { system.serve(job, bookData, etag: etag) }
        await idle(router)
        _ = try await wait(downloads, publication.id, [.ready])
    }

    /// The app's download request: `ReadAlongService.downloadRequested` then `start`.
    @discardableResult
    func request(
        _ publication: Publication,
        fetched: ReadAlongPreparations.Fetched,
        key: String? = nil,
        manifestGate: HoldPoint? = nil,
        audiobookGate: HoldPoint? = nil,
        copyGate: HoldPoint? = nil,
        failManifest: Bool = false,
        via held: HeldDownloads? = nil,
        outcome: Shared<ReadAlongPreparations.Outcome?> = Shared(nil)
    ) -> Task<Void, Never>? {
        preparations.userRequested(publication.id)
        let preparations = preparations!, library = library!
        let target: ReadAlongDownloads = held ?? downloads!
        let known = publications
        return preparations.launch(publication.id, key: key ?? "\(fetched.manifest.ebookAssetId)/\(fetched.manifest.generation)") { ticket in
            do {
                let stored = try await preparations.store(
                    ticket, library: library, downloads: target,
                    fetchManifest: {
                        await manifestGate?.wait()
                        if failManifest { throw APIError.server(500) }
                        return fetched
                    },
                    fetchAudiobook: { id in
                        await audiobookGate?.wait()
                        guard let found = known[id] else { throw APIError.notFound }
                        return found
                    }
                )
                guard let stored else {
                    outcome.value = .stale
                    return
                }
                outcome.value = await preparations.complete(ticket, stored: stored, library: library, downloads: target, willCopyAudio: { await copyGate?.wait() })
            } catch {
                outcome.value = preparations.isCurrent(ticket) ? .failed(.storage) : .stale
            }
        }
    }

    /// The app's Cancel: `DownloadsModel.cancel` → `ReadAlongService.downloadCancelled`, then the manager.
    func cancel(_ publicationId: String) async {
        preparations.userStopped(publicationId)
        let cleanup = preparations.stopped(publicationId, removing: false, library: library, downloads: downloads)
        await downloads.cancel(publicationId)
        await cleanup.value
    }

    /// The app's Remove: `DownloadsModel.remove` → `ReadAlongService.downloadRemoved`, then the manager.
    func remove(_ publicationId: String) async {
        preparations.userStopped(publicationId)
        let cleanup = preparations.stopped(publicationId, removing: true, library: library, downloads: downloads)
        await downloads.remove(publicationId)
        await cleanup.value
    }

    /// The preparation as it was before downloads owned it (PR 700 at 2196d84,
    /// `ReadAlongService.prepare`), with only the account check.
    func legacyPrepare(_ fetched: ReadAlongPreparations.Fetched, manifestGate: HoldPoint) async throws {
        await manifestGate.wait()
        let stored = try await library.save(manifestData: fetched.data, manifest: fetched.manifest, publicationId: "12")
        if fetched.manifest.source == .imported, let audiobookId = fetched.manifest.audiobookPublicationId {
            let existing = await downloads.ready(audiobookId)
            let covers = existing.map { record in fetched.manifest.audio.allSatisfy { record.pinnedAssetIds.contains($0.assetId ?? "") } } ?? false
            if !covers, let audiobook = publications[audiobookId] { await downloads.enqueue(audiobook) }
        }
        _ = stored
    }
}

/// Narration preparation owned by the download that started it: cancelling, removing,
/// replacing or signing out stops it at every suspension, with the real download
/// manager and read-along library, and each schedule held exactly where it matters.
final class ReadAlongPreparationTests: ReadAlongPreparationTestCase {
    // MARK: Cancel

    func testLegacyPreparationQueuesTheAudiobookAfterTheBookIsCancelledAndOrphansItsManifest() async throws {
        await downloads.start()
        await downloads.enqueue(ebook)
        let gate = HoldPoint()
        let legacy = Task { try await legacyPrepare(imported(), manifestGate: gate) }
        try await until("the manifest fetch") { await gate.arrived == 1 }

        // Cancel as the app did: the manager alone.
        await downloads.cancel("12")
        await gate.release()
        try await legacy.value

        let book = await downloads.record("12")
        XCTAssertEqual(book?.state, .cancelled)
        let audiobook = await downloads.record("40")
        XCTAssertEqual(audiobook?.isActive, true, "negative control: the whole audiobook starts downloading after Cancel")
        XCTAssertEqual(generations(), [F.generation], "negative control: the cancelled book's manifest stays on disk")
    }

    func testCancellingTheBookWhileItsManifestIsFetchedStopsEverything() async throws {
        await downloads.start()
        await downloads.enqueue(ebook)
        let gate = HoldPoint()
        let outcome = Shared<ReadAlongPreparations.Outcome?>(nil)
        let task = try XCTUnwrap(request(ebook, fetched: imported(), manifestGate: gate, outcome: outcome))
        try await until("the manifest fetch") { await gate.arrived == 1 }
        XCTAssertTrue(preparations.isPreparing("12"))

        await cancel("12")
        XCTAssertFalse(preparations.isPreparing("12"), "Cancel ends the preparation at once")
        await gate.release()
        await task.value

        XCTAssertEqual(outcome.value, .stale)
        let book = await downloads.record("12")
        XCTAssertEqual(book?.state, .cancelled)
        let audiobook = await downloads.record("40")
        XCTAssertNil(audiobook, "no companion is queued after Cancel")
        XCTAssertTrue(generations().isEmpty, "no manifest is stored after Cancel")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bookFolder().path))
        XCTAssertTrue(liveJobs("/files/track-a").isEmpty && liveJobs("/files/track-b").isEmpty)
    }

    func testCancellingWhileTheAudiobookDetailsAreFetchedDiscardsTheStoredManifest() async throws {
        await downloads.start()
        await downloads.enqueue(ebook)
        let gate = HoldPoint()
        let outcome = Shared<ReadAlongPreparations.Outcome?>(nil)
        let task = try XCTUnwrap(request(ebook, fetched: imported(), audiobookGate: gate, outcome: outcome))
        try await until("the audiobook details") { await gate.arrived == 1 }
        XCTAssertEqual(generations(), [F.generation], "stored before the details were asked for")

        await cancel("12")
        XCTAssertTrue(generations().isEmpty, "the manifest that never became current goes with the cancelled download")
        await gate.release()
        await task.value

        XCTAssertEqual(outcome.value, .stale)
        let audiobook = await downloads.record("40")
        XCTAssertNil(audiobook)
        XCTAssertTrue(generations().isEmpty, "nothing is written back after the details arrive")
    }

    func testACompanionQueuedJustAsTheBookIsCancelledIsCancelledAgain() async throws {
        await downloads.start()
        await downloads.enqueue(ebook)
        let gate = HoldPoint()
        let held = HeldDownloads(downloads, beforeEnqueue: gate)
        let outcome = Shared<ReadAlongPreparations.Outcome?>(nil)
        let task = try XCTUnwrap(request(ebook, fetched: imported(), via: held, outcome: outcome))
        // Past its last check, on its way into the manager.
        try await until("the companion enqueue") { await gate.arrived == 1 }

        await cancel("12")
        await gate.release()
        await task.value

        XCTAssertEqual(held.enqueued.value, ["40"])
        XCTAssertEqual(outcome.value, .stale)
        let audiobook = await downloads.record("40")
        XCTAssertEqual(audiobook?.state, .cancelled, "the companion it created is rolled back")
        await idle(router)
        XCTAssertTrue(liveJobs("/files/track-a").isEmpty && liveJobs("/files/track-b").isEmpty, "no audiobook transfer is left running")
    }

    func testCancellingAfterTheCompanionWasQueuedCancelsItAndKeepsTheUsableGeneration() async throws {
        // A usable earlier generation, kept with this download.
        let earlier = imported(generation: F.otherGeneration)
        let kept = try await library.save(manifestData: earlier.data, manifest: earlier.manifest, publicationId: "12")
        try await library.promote(kept)

        await downloads.start()
        await downloads.enqueue(ebook)
        let outcome = Shared<ReadAlongPreparations.Outcome?>(nil)
        let task = try XCTUnwrap(request(ebook, fetched: imported(), outcome: outcome))
        await task.value
        XCTAssertEqual(outcome.value, .waitingForBook)
        let queued = await downloads.record("40")
        XCTAssertEqual(queued?.isActive, true, "the update queued its audiobook")
        XCTAssertEqual(generations(), [F.generation, F.otherGeneration].sorted())

        await cancel("12")
        let audiobook = await downloads.record("40")
        XCTAssertEqual(audiobook?.state, .cancelled, "Cancel stops the companion the book started")
        XCTAssertEqual(generations(), [F.otherGeneration], "the update that never became current is discarded")
        let current = await library.currentGenerationName("12")
        XCTAssertEqual(current, F.otherGeneration, "the earlier usable generation is kept")
    }

    func testAnAudiobookTheUserAskedForIsNotCancelledWithTheBook() async throws {
        await downloads.start()
        await downloads.enqueue(ebook)
        let gate = HoldPoint()
        let task = try XCTUnwrap(request(ebook, fetched: imported(), audiobookGate: gate))
        try await until("the audiobook details") { await gate.arrived == 1 }

        // While the preparation waits, the user downloads the audiobook themselves.
        preparations.userRequested("40")
        await downloads.enqueue(narration)
        await gate.release()
        await task.value

        await cancel("12")
        let audiobook = await downloads.record("40")
        XCTAssertEqual(audiobook?.isActive, true, "the user's own download keeps going")
    }

    func testAnAudiobookAlreadyDownloadingForTheUserIsNotCancelledWithTheBook() async throws {
        await downloads.start()
        preparations.userRequested("40")
        await downloads.enqueue(narration)
        await downloads.enqueue(ebook)
        let task = try XCTUnwrap(request(ebook, fetched: imported()))
        await task.value

        await cancel("12")
        let audiobook = await downloads.record("40")
        XCTAssertEqual(audiobook?.isActive, true)
    }

    func testACompanionAnotherBookStillNeedsKeepsDownloading() async throws {
        await downloads.start()
        await downloads.enqueue(ebook)
        await downloads.enqueue(otherEbook)
        let first = try XCTUnwrap(request(ebook, fetched: imported()))
        await first.value
        // The other edition is still between deciding to use the audiobook and having queued it.
        let gate = HoldPoint()
        let second = try XCTUnwrap(request(otherEbook, fetched: imported("13", ebookAssetId: otherAssetId), audiobookGate: gate))
        try await until("the second book's audiobook details") { await gate.arrived == 1 }

        await cancel("12")
        let afterFirst = await downloads.record("40")
        XCTAssertEqual(afterFirst?.isActive, true, "another preparation is about to use it")
        await gate.release()
        await second.value
        let stillNeeded = await downloads.record("40")
        XCTAssertEqual(stillNeeded?.isActive, true)

        await cancel("13")
        let released = await downloads.record("40")
        XCTAssertEqual(released?.state, .cancelled, "once no book needs it, it stops")
    }

    func testACompleteAudiobookIsKeptWhenTheBookIsCancelled() async throws {
        await downloads.start()
        await downloads.enqueue(ebook)
        let task = try XCTUnwrap(request(ebook, fetched: imported()))
        await task.value
        try await until("the audiobook's transfers") { liveJobs("/files/track-a").count + liveJobs("/files/track-b").count == 2 }
        for job in liveJobs("/files/track-a") { system.serve(job, trackA, etag: "\"a\"") }
        for job in liveJobs("/files/track-b") { system.serve(job, trackB, etag: "\"b\"") }
        await idle(router)
        let ready = try await wait(downloads, "40", [.ready])

        await cancel("12")
        let audiobook = await downloads.record("40")
        XCTAssertEqual(audiobook?.state, .ready, "finished files are never deleted with the book")
        let files = await downloads.fileURLs(ready)
        XCTAssertEqual(files?.count, 2)
    }

    // MARK: Resume, update, remove, sign-out

    func testResumingAfterCancelLetsOnlyTheNewPreparationWrite() async throws {
        await downloads.start()
        await downloads.enqueue(ebook)
        let held = HeldDownloads(downloads)
        let oldGate = HoldPoint()
        let oldOutcome = Shared<ReadAlongPreparations.Outcome?>(nil)
        let old = try XCTUnwrap(request(ebook, fetched: imported(), manifestGate: oldGate, via: held, outcome: oldOutcome))
        try await until("the first manifest fetch") { await oldGate.arrived == 1 }

        await cancel("12")
        // Download again while the cancelled one's fetch is still out.
        await downloads.enqueue(ebook)
        let newOutcome = Shared<ReadAlongPreparations.Outcome?>(nil)
        let new = try XCTUnwrap(request(ebook, fetched: imported(), via: held, outcome: newOutcome))
        await new.value
        XCTAssertEqual(newOutcome.value, .waitingForBook)
        XCTAssertEqual(generations(), [F.generation])

        await oldGate.release()
        await old.value
        XCTAssertEqual(oldOutcome.value, .stale)
        XCTAssertEqual(held.enqueued.value, ["40"], "the cancelled preparation queues nothing when it returns")
        XCTAssertEqual(generations(), [F.generation], "and doesn't touch the new one's manifest")

        try await finishBook(ebook, path: "/files/ebook", etag: "\"book\"")
        let audiobook = await downloads.record("40")
        XCTAssertEqual(audiobook?.isActive, true)
    }

    func testCleanupAfterCancelLeavesAResumedPreparationAlone() async throws {
        await downloads.start()
        await downloads.enqueue(ebook)
        let gate = HoldPoint()
        let first = try XCTUnwrap(request(ebook, fetched: imported(), audiobookGate: gate))
        try await until("the audiobook details") { await gate.arrived == 1 }
        XCTAssertEqual(generations(), [F.generation])

        // Cancel, then download again before the cancel's cleanup reaches the library.
        preparations.userStopped("12")
        let cleanup = preparations.invalidate("12")
        await downloads.cancel("12")
        await downloads.enqueue(ebook)
        let secondGate = HoldPoint()
        let second = try XCTUnwrap(request(ebook, fetched: imported(), manifestGate: secondGate))
        await preparations.cleanUp(cleanup, removing: false, library: library, downloads: downloads)
        XCTAssertEqual(generations(), [F.generation], "the resumed download's folder isn't cleaned under it")

        await secondGate.release()
        await second.value
        await gate.release()
        await first.value
        XCTAssertEqual(generations(), [F.generation])
        let audiobook = await downloads.record("40")
        XCTAssertEqual(audiobook?.isActive, true)
    }

    func testASupersededUpdateCannotWriteAndAFailedOneKeepsTheUsableGeneration() async throws {
        let earlier = imported(generation: F.otherGeneration)
        let kept = try await library.save(manifestData: earlier.data, manifest: earlier.manifest, publicationId: "12")
        try await library.promote(kept)
        let newer = String(repeating: "c3", count: 32)

        let gate = HoldPoint()
        let staleOutcome = Shared<ReadAlongPreparations.Outcome?>(nil)
        let stale = try XCTUnwrap(request(ebook, fetched: imported(), manifestGate: gate, outcome: staleOutcome))
        try await until("the update's manifest fetch") { await gate.arrived == 1 }

        // The server moved on again: the newer generation replaces the update in flight, and fails.
        let failedOutcome = Shared<ReadAlongPreparations.Outcome?>(nil)
        let failing = try XCTUnwrap(request(ebook, fetched: imported(generation: newer), failManifest: true, outcome: failedOutcome))
        await failing.value
        XCTAssertEqual(failedOutcome.value, .failed(.storage))
        await gate.release()
        await stale.value

        XCTAssertEqual(staleOutcome.value, .stale)
        XCTAssertEqual(generations(), [F.otherGeneration], "neither update wrote anything")
        let current = await library.currentGenerationName("12")
        XCTAssertEqual(current, F.otherGeneration)
        let audiobook = await downloads.record("40")
        XCTAssertNil(audiobook)
    }

    func testRequestingTheSameDownloadAgainKeepsTheRunningPreparation() async throws {
        let gate = HoldPoint()
        let first = try XCTUnwrap(request(ebook, fetched: imported(), manifestGate: gate))
        let again = request(ebook, fetched: imported())
        XCTAssertEqual(again, first, "the same edition and generation isn't started twice")
        await gate.release()
        await first.value
        XCTAssertEqual(generations(), [F.generation])
    }

    func testRemovingTheBookWhileItsNarrationIsCopiedLeavesNothing() async throws {
        await downloads.start()
        await downloads.enqueue(ebook)
        try await finishBook(ebook, path: "/files/ebook", etag: "\"book\"")
        let gate = HoldPoint()
        let outcome = Shared<ReadAlongPreparations.Outcome?>(nil)
        let task = try XCTUnwrap(request(ebook, fetched: overlay(), copyGate: gate, outcome: outcome))
        try await until("copying the narration") { await gate.arrived == 1 }
        XCTAssertEqual(generations(), [F.generation])

        await remove("12")
        await gate.release()
        await task.value

        XCTAssertEqual(outcome.value, .stale)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bookFolder().path), "no copy or promotion recreates the removed book's narration")
        let readiness = await library.readiness("12", ebookAssetId: F.ebookAssetId, server: F.server, audiobookFiles: nil)
        XCTAssertEqual(readiness, .none)
    }

    func testAnOverlayIsCopiedAndCurrentWhenNothingStopsIt() async throws {
        await downloads.start()
        await downloads.enqueue(ebook)
        try await finishBook(ebook, path: "/files/ebook", etag: "\"book\"")
        let outcome = Shared<ReadAlongPreparations.Outcome?>(nil)
        let task = try XCTUnwrap(request(ebook, fetched: overlay(), outcome: outcome))
        await task.value
        XCTAssertEqual(outcome.value, .onDevice)
        guard case .ready = await library.readiness("12", ebookAssetId: F.ebookAssetId, server: F.server, audiobookFiles: nil) else {
            return XCTFail("not ready")
        }
    }

    func testEndingTheAccountWhileAwaitingStopsWritesAndTransfers() async throws {
        await downloads.start()
        await downloads.enqueue(ebook)
        let manifestGate = HoldPoint()
        let first = Shared<ReadAlongPreparations.Outcome?>(nil)
        let waitingForManifest = try XCTUnwrap(request(ebook, fetched: imported(), manifestGate: manifestGate, outcome: first))
        let detailsGate = HoldPoint()
        let second = Shared<ReadAlongPreparations.Outcome?>(nil)
        let waitingForDetails = try XCTUnwrap(request(otherEbook, fetched: imported("13", ebookAssetId: otherAssetId), audiobookGate: detailsGate, outcome: second))
        try await until("both preparations held") {
            let manifest = await manifestGate.arrived
            let details = await detailsGate.arrived
            return manifest == 1 && details == 1
        }

        preparations.end()
        XCTAssertNil(request(ebook, fetched: imported()), "nothing starts for an account that ended")
        await manifestGate.release()
        await detailsGate.release()
        await waitingForManifest.value
        await waitingForDetails.value

        XCTAssertEqual(first.value, .stale)
        XCTAssertEqual(second.value, .stale)
        XCTAssertTrue(generations("12").isEmpty)
        let audiobook = await downloads.record("40")
        XCTAssertNil(audiobook, "no transfer starts for an account that ended")
    }

    func testStoppingCancelsTheOwnedTask() async throws {
        let cancelled = Shared(false)
        let started = HoldPoint()
        let task = try XCTUnwrap(preparations.launch("12", key: "k") { _ in
            await started.release()
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            cancelled.value = Task.isCancelled
        })
        // Wait for it to be running before stopping it.
        await started.wait()
        preparations.invalidate("12")
        await task.value
        XCTAssertTrue(cancelled.value)
        XCTAssertFalse(preparations.isPreparing("12"))
    }
}

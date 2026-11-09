import Foundation
@testable import ShelfarrCore
import XCTest

/// Who owns a paired audiobook survives a relaunch, like the downloads themselves: every
/// "relaunch" here is a fresh router, download manager, library and coordinator over the
/// same disk, with the transfers still held by the system stand-in.
final class ReadAlongCompanionOwnershipTests: ReadAlongPreparationTestCase {
    private func prepared(_ publication: Publication, _ fetched: ReadAlongPreparations.Fetched) async throws {
        let task = try XCTUnwrap(request(publication, fetched: fetched))
        await task.value
    }

    private func companionState() async -> DownloadState? {
        await downloads.record("40")?.state
    }

    /// Still queued or transferring (a relaunched manager plans it again).
    private func companionActive() async -> Bool {
        await downloads.record("40")?.isActive == true
    }

    // MARK: Relaunch

    func testCancellingTheBookAfterARelaunchCancelsTheCompanionItQueued() async throws {
        let earlier = imported(generation: F.otherGeneration)
        let kept = try await library.save(manifestData: earlier.data, manifest: earlier.manifest, publicationId: "12")
        try await library.promote(kept)
        await downloads.start()
        await downloads.enqueue(ebook)
        try await prepared(ebook, imported())
        XCTAssertEqual(storedCompanions()?["40"]?["owned"] as? Bool, true)
        XCTAssertEqual(storedCompanions()?["40"]?["books"] as? [String], ["12"])

        await relaunch()
        let resumed = await downloads.record("40")
        XCTAssertEqual(resumed?.isActive, true, "the companion's download outlived the process")
        await cancel("12")

        let state = await companionState()
        XCTAssertEqual(state, .cancelled, "the relaunched app still knows the book queued it")
        XCTAssertNil(storedCompanions()?["40"], "a finished release is forgotten")
        XCTAssertEqual(generations(), [F.otherGeneration], "the update that never became current is discarded")
        let current = await library.currentGenerationName("12")
        XCTAssertEqual(current, F.otherGeneration, "the earlier usable narration is kept")
    }

    func testRemovingTheBookAfterARelaunchCancelsTheCompanionItQueued() async throws {
        await downloads.start()
        await downloads.enqueue(ebook)
        try await prepared(ebook, imported())
        await relaunch()
        await remove("12")
        let state = await companionState()
        XCTAssertEqual(state, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bookFolder().path))
    }

    func testAfterARelaunchAnAudiobookTheUserAskedForStaysTheirs() async throws {
        await downloads.start()
        await downloads.enqueue(ebook)
        try await prepared(ebook, imported())
        // The user taps Download on the audiobook the book queued: it's theirs now.
        preparations.userRequested("40")
        await downloads.enqueue(narration)
        XCTAssertEqual(storedCompanions()?["40"]?["owned"] as? Bool, false)

        await relaunch()
        await cancel("12")
        let state = await companionActive()
        XCTAssertTrue(state)
    }

    func testAfterARelaunchACompanionAnotherBookUsesKeepsDownloading() async throws {
        await downloads.start()
        await downloads.enqueue(ebook)
        await downloads.enqueue(otherEbook)
        try await prepared(ebook, imported())
        try await prepared(otherEbook, imported("13", ebookAssetId: otherAssetId))
        XCTAssertEqual(storedCompanions()?["40"]?["books"] as? [String], ["12", "13"])

        await relaunch()
        await cancel("12")
        let afterFirst = await companionActive()
        XCTAssertTrue(afterFirst, "the other edition still uses it")

        await relaunch()
        await cancel("13")
        let afterBoth = await companionState()
        XCTAssertEqual(afterBoth, .cancelled)
    }

    func testAfterARelaunchACompleteCompanionIsKept() async throws {
        await downloads.start()
        await downloads.enqueue(ebook)
        try await prepared(ebook, imported())
        try await until("the audiobook's transfers") { liveJobs("/files/track-a").count + liveJobs("/files/track-b").count == 2 }
        for job in liveJobs("/files/track-a") { system.serve(job, trackA, etag: "\"a\"") }
        for job in liveJobs("/files/track-b") { system.serve(job, trackB, etag: "\"b\"") }
        await idle(router)
        _ = try await wait(downloads, "40", [.ready])

        await relaunch()
        await cancel("12")
        let state = await companionState()
        XCTAssertEqual(state, .ready)
        let found = await downloads.record("40")
        let record = try XCTUnwrap(found)
        let files = await downloads.fileURLs(record)
        XCTAssertEqual(files?.count, 2)
    }

    func testAFailedCompanionIsCancelledWithTheBook() async throws {
        transport["/files/track-a"]?.status = 503
        await downloads.start()
        await downloads.enqueue(ebook)
        try await prepared(ebook, imported())
        _ = try await wait(downloads, "40", [.failed])

        await relaunch()
        await cancel("12")
        let state = await companionState()
        XCTAssertEqual(state, .cancelled, "an unfinished companion would otherwise resume with the next retry")
    }

    func testARelaunchFinishesAReleaseThatWasCutShort() async throws {
        await downloads.start()
        await downloads.enqueue(ebook)
        try await prepared(ebook, imported())
        XCTAssertEqual(generations(), [F.generation])

        // Cancel reached the book's download, and the process ended before its cleanup ran.
        preparations.userStopped("12")
        _ = preparations.invalidate("12")
        await downloads.cancel("12")
        XCTAssertEqual(storedCompanions()?["40"]?["books"] as? [String], [], "the release is recorded until it's done")

        await relaunch()
        let before = await companionActive()
        XCTAssertTrue(before)
        await preparations.resumeReleases(downloads: downloads)
        // What the service does for a cancelled book at launch.
        await preparations.cleanUp("12", removing: false, released: [], library: library, downloads: nil)

        let state = await companionState()
        XCTAssertEqual(state, .cancelled)
        XCTAssertNil(storedCompanions()?["40"])
        XCTAssertTrue(generations().isEmpty, "the cancelled book's unfinished narration goes too")
    }

    func testTheClaimIsOnDiskBeforeTheCompanionIsQueued() async throws {
        await downloads.start()
        await downloads.enqueue(ebook)
        let gate = HoldPoint()
        let held = HeldDownloads(downloads, beforeEnqueue: gate)
        let task = try XCTUnwrap(request(ebook, fetched: imported(), via: held))
        try await until("the companion enqueue") { await gate.arrived == 1 }
        XCTAssertEqual(storedCompanions()?["40"]?["owned"] as? Bool, true, "written ahead of the enqueue")
        XCTAssertEqual(storedCompanions()?["40"]?["books"] as? [String], ["12"])

        // The process ends here; nothing was queued. A new launch cancels nothing that isn't there.
        let abandoned = downloads!
        await relaunch()
        await cancel("12")
        let state = await companionState()
        XCTAssertNil(state)
        XCTAssertNil(storedCompanions()?["40"])
        // Let the abandoned process's held step finish against its closed manager.
        await abandoned.close()
        await gate.release()
        await task.value
    }

    // MARK: Migration and damage

    func testCompanionsQueuedBeforeOwnershipWasKeptStayOrdinaryDownloads() async throws {
        // An earlier build queued the audiobook for the book and kept no ownership file.
        await downloads.start()
        await downloads.enqueue(ebook)
        await downloads.enqueue(narration)
        XCTAssertFalse(FileManager.default.fileExists(atPath: companionsFile.path))

        await relaunch()
        XCTAssertNil(preparations.storageProblem, "no file is no problem")
        await cancel("12")
        let state = await companionActive()
        XCTAssertTrue(state, "unknown ownership is never assumed")
    }

    func testAnUnreadableOwnershipFileIsMovedAsideAndCancelsNothing() async throws {
        await downloads.start()
        await downloads.enqueue(ebook)
        try await prepared(ebook, imported())
        try Data("{\"version\":1,\"companions\":".utf8).write(to: companionsFile)

        await relaunch()
        XCTAssertEqual(preparations.storageProblem, .unreadable)
        let aside = companionsFile.appendingPathExtension("unreadable")
        XCTAssertEqual(try Data(contentsOf: aside), Data("{\"version\":1,\"companions\":".utf8), "kept for diagnosis")
        await cancel("12")
        let state = await companionActive()
        XCTAssertTrue(state, "ownership that can't be read is never assumed")

        // New ownership is kept normally from then on; the loss stays reported.
        await downloads.enqueue(otherEbook)
        try await prepared(otherEbook, imported("13", ebookAssetId: otherAssetId))
        XCTAssertEqual(storedCompanions()?["40"]?["books"] as? [String], ["13"])
        XCTAssertEqual(preparations.storageProblem, .unreadable)
    }

    func testAnOwnershipFileFromAnotherVersionIsNotTrusted() async throws {
        await downloads.start()
        await downloads.enqueue(ebook)
        try await prepared(ebook, imported())
        try Data("{\"version\":2,\"companions\":{\"40\":{\"owned\":true,\"books\":[\"12\"]}}}".utf8).write(to: companionsFile)

        await relaunch()
        XCTAssertEqual(preparations.storageProblem, .unreadable)
        await cancel("12")
        let state = await companionActive()
        XCTAssertTrue(state)
    }

    func testAClaimThatCantBeWrittenIsReportedAndLeavesNothingStale() async throws {
        await downloads.start()
        await downloads.enqueue(ebook)
        // Something that can't be written over sits where ownership is kept.
        try FileManager.default.createDirectory(at: companionsFile.appendingPathComponent("blocked"), withIntermediateDirectories: true)
        try await prepared(ebook, imported())
        XCTAssertEqual(preparations.storageProblem, .unwritable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: companionsFile.path), "nothing stale is left to be trusted later")

        // This launch still knows, from memory.
        await cancel("12")
        let state = await companionState()
        XCTAssertEqual(state, .cancelled)
    }

    func testAWriteThatFailsLaterIsReportedAndForgetsRatherThanTrustsOwnership() async throws {
        await downloads.start()
        await downloads.enqueue(ebook)
        try await prepared(ebook, imported())
        XCTAssertNotNil(storedCompanions()?["40"])
        // The file is replaced by something that can't be written over.
        try FileManager.default.removeItem(at: companionsFile)
        try FileManager.default.createDirectory(at: companionsFile.appendingPathComponent("blocked"), withIntermediateDirectories: true)

        preparations.userRequested("40")
        XCTAssertEqual(preparations.storageProblem, .unwritable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: companionsFile.path))

        await relaunch()
        XCTAssertNil(preparations.storageProblem)
        await cancel("12")
        let state = await companionActive()
        XCTAssertTrue(state, "the user's request wasn't lost to a stale file")
    }

    func testNothingIsWrittenOnceTheAccountEnded() async throws {
        await downloads.start()
        await downloads.enqueue(ebook)
        try await prepared(ebook, imported())
        preparations.end()
        // The account's folder is deleted after sign-out.
        try FileManager.default.removeItem(at: root.appendingPathComponent("acct/read-along"))
        preparations.userRequested("40")
        _ = preparations.invalidate("12")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("acct/read-along").path))
    }

    // MARK: Cancel and request at once

    func testACompanionReleasedWhileAnotherBookQueuesItKeepsDownloading() async throws {
        await downloads.start()
        await downloads.enqueue(ebook)
        try await prepared(ebook, imported())
        try await until("the companion's transfers") { liveJobs("/files/track-a").count + liveJobs("/files/track-b").count == 2 }

        // Cancel the first book; its companion's transfers are being stopped.
        await cancelGate.hold()
        preparations.userStopped("12")
        let cleanup = preparations.stopped("12", removing: false, library: library, downloads: downloads)
        try await until("the companion's cancel waiting on the executor") { await cancelGate.arrived == 1 }

        // Meanwhile the other edition's preparation decides to use it and queues it.
        try await prepared(otherEbook, imported("13", ebookAssetId: otherAssetId))
        await cancelGate.release()
        await cleanup.value

        let state = await companionState()
        XCTAssertEqual(state.map { $0 == .queued || $0 == .downloading }, true, "the other book's request isn't lost to the release it raced")
        XCTAssertEqual(storedCompanions()?["40"]?["books"] as? [String], ["13"])
        try await until("its transfers again") { !liveJobs("/files/track-a").isEmpty }

        await cancel("13")
        let released = await companionState()
        XCTAssertEqual(released, .cancelled)
    }
}

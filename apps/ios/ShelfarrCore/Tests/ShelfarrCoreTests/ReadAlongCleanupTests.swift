import Foundation
@testable import ShelfarrCore
import XCTest

/// Cleanup is delayed until after the replacement preparation has finished, rather
/// than only while its task is still in the coordinator's running set.
final class ReadAlongCleanupTests: ReadAlongPreparationTestCase {
    func testDelayedCancelKeepsTheNewPendingManifestAndItsCompanion() async throws {
        await downloads.start()
        await downloads.enqueue(ebook)
        await request(ebook, fetched: imported())!.value
        preparations.userStopped("12")
        let released = preparations.invalidate("12")
        await downloads.cancel("12")

        await downloads.enqueue(ebook)
        await request(ebook, fetched: imported())!.value
        XCTAssertFalse(preparations.isPreparing("12"), "the new preparation finished while its ebook still downloads")
        await preparations.cleanUp(released, removing: false, library: library, downloads: downloads)

        XCTAssertEqual(generations(), [F.generation], "old cancellation cannot delete the new request's pending narration")
        try await finishBook(ebook, path: "/files/ebook", etag: "\"book\"")
        let latest = await library.latest("12", ebookAssetId: F.ebookAssetId, server: F.server)
        XCTAssertNotNil(latest, "reconcile must still find the manifest when the ebook finishes")
        let companion = await downloads.record("40")
        XCTAssertEqual(companion?.isActive, true, "the new request still needs its companion")
    }

    func testDelayedRemoveKeepsTheNewReadyOverlayAndItsCopiedAudio() async throws {
        await downloads.start()
        await downloads.enqueue(ebook)
        await request(ebook, fetched: imported(generation: F.otherGeneration))!.value
        preparations.userStopped("12")
        let released = preparations.invalidate("12")
        await downloads.remove("12")

        await downloads.enqueue(ebook)
        try await finishBook(ebook, path: "/files/ebook", etag: "\"book\"")
        let outcome = Shared<ReadAlongPreparations.Outcome?>(nil)
        await request(ebook, fetched: overlay(), outcome: outcome)!.value
        XCTAssertEqual(outcome.value, .onDevice)
        XCTAssertFalse(preparations.isPreparing("12"))
        await preparations.cleanUp(released, removing: true, library: library, downloads: downloads)

        let generation = await library.currentGenerationName("12")
        XCTAssertEqual(generation, F.generation, "old removal cannot delete the newer completed narration")
        let latest = await library.latest("12", ebookAssetId: F.ebookAssetId, server: F.server)
        XCTAssertNotNil(latest?.overlayAudio, "the copied overlay files remain on disk")
        let ready = await downloads.ready("12")
        XCTAssertNotNil(ready)
    }

    func testInterruptedCleanupCannotDeleteARequestPreparedAfterRelaunch() async throws {
        await downloads.start()
        await downloads.enqueue(ebook)
        await request(ebook, fetched: imported())!.value
        preparations.userStopped("12")
        preparations.invalidate("12")
        await downloads.cancel("12")
        await relaunch()
        await preparations.resumeReleases(downloads: downloads)
        let interrupted = try XCTUnwrap(preparations.interruptedCleanup("12"))

        // Reconcile captured its old cancelled entry, then this request finishes
        // preparing before that asynchronous cleanup reaches the library.
        await downloads.enqueue(ebook)
        await request(ebook, fetched: imported())!.value
        XCTAssertFalse(preparations.isPreparing("12"))
        XCTAssertNil(preparations.interruptedCleanup("12"), "a later stale cancelled-record callback cannot bind cleanup to this request")
        await preparations.cleanUp(interrupted, removing: false, library: library, downloads: nil)

        XCTAssertEqual(generations(), [F.generation])
        let companion = await downloads.record("40")
        XCTAssertEqual(companion?.isActive, true)
    }

    func testAnAutomaticPreparationSupersedesCleanupAfterItFinishes() async throws {
        await downloads.start()
        let cleanup = preparations.invalidate("12")
        await downloads.enqueue(ebook)
        try await finishBook(ebook, path: "/files/ebook", etag: "\"book\"")

        // Automatic preparation does not call userRequested (unlike Download/Retry).
        let owner = preparations!, library = library!, downloads = downloads!
        let fetched = overlay()
        let outcome = Shared<ReadAlongPreparations.Outcome?>(nil)
        let task = try XCTUnwrap(owner.launch("12", key: F.generation) { ticket in
            do {
                guard let stored = try await owner.store(ticket, library: library, downloads: downloads,
                    fetchManifest: { fetched }, fetchAudiobook: { _ in throw APIError.notFound }) else { return }
                outcome.value = await owner.complete(ticket, stored: stored, library: library, downloads: downloads)
            } catch { outcome.value = .failed(.storage) }
        })
        await task.value
        XCTAssertEqual(outcome.value, .onDevice)
        XCTAssertFalse(owner.isPreparing("12"))
        XCTAssertNil(owner.interruptedCleanup("12"))
        await owner.cleanUp(cleanup, removing: true, library: library, downloads: downloads)
        let current = await library.currentGenerationName("12")
        XCTAssertEqual(current, F.generation)
    }
}

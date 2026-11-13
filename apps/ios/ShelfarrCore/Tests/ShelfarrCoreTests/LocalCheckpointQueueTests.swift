@testable import ShelfarrCore
import XCTest

private actor UploadGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

final class LocalCheckpointQueueTests: XCTestCase {
    func testLifecycleUploadDoesNotBlockLaterCheckpointsReachingDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("progress.json")
        let store = FileProgressStore(file: file), gate = UploadGate()
        let started = expectation(description: "upload is waiting for the network")
        var timing = SyncTiming()
        timing.debounce = .seconds(600)
        timing.maxWait = .seconds(600)
        let sync = ProgressSync(publicationId: "p", store: store, remote: { _, _ in
            started.fulfill()
            await gate.wait()
            throw APIError.offline(certificate: false)
        }, timing: timing)

        // The reader and player serialize local writes. A lifecycle checkpoint
        // must request an upload without extending that chain across the network.
        let firstWrite = Task {
            await sync.update(seconds(100), observedAt: baseTime)
            await sync.requestFlush()
        }
        await fulfillment(of: [started], timeout: 2)
        let saved = expectation(description: "later checkpoint is durable while upload waits")
        let nextWrite = Task {
            await firstWrite.value
            await sync.update(seconds(120), observedAt: baseTime + 4000)
            saved.fulfill()
        }
        await fulfillment(of: [saved], timeout: 2)
        let reopened = FileProgressStore(file: file)
        let durable = try await reopened.get("p")
        XCTAssertEqual(durable?.position, seconds(120))
        XCTAssertEqual(durable?.observedAt, baseTime + 4000)
        XCTAssertEqual(durable?.pending?.position, seconds(100), "uncertain upload remains immutable")
        XCTAssertEqual(durable?.dirty, true)
        await gate.release()
        await nextWrite.value
        await sync.stop()
    }
}

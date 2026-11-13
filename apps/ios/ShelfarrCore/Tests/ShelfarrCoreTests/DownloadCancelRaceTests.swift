import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ShelfarrCore
import XCTest

/// Cancel and Remove wait while the executor stops their transfers. A request for the
/// same download that arrives meanwhile starts it again; it is never swallowed.
final class DownloadCancelRaceTests: DownloadTestCase {
    private var router = TransferRouter()
    private lazy var system = FakeSystem(router: router)
    private let gate = HoldPoint()
    private lazy var executor = HeldExecutor(system, gate: gate)

    private var bookFolder: URL {
        downloadsRoot("acct").appendingPathComponent(String(SHA256.hexDigest(Data("book".utf8)).prefix(32)))
    }

    private func held() -> DownloadManager {
        manager(executors: DownloadExecutors(foreground: executor), router: router)
    }

    private func bookJobs() -> [FakeSystem.Job] { system.live.filter { $0.request.url!.path == "/files/e1" } }

    func testADownloadRequestedWhileItsCancelStopsTransfersStartsAgain() async throws {
        let downloads = held()
        await downloads.start()
        await downloads.enqueue(book)
        try await until("the book's transfer") { !bookJobs().isEmpty }

        let cancelling = Task { await downloads.cancel("book") }
        try await until("the cancel waiting on the executor") { await gate.arrived == 1 }
        // The user taps Download again while the old transfer is being stopped.
        await downloads.enqueue(book)
        await gate.release()
        await cancelling.value

        let record = await downloads.record("book")
        XCTAssertEqual(record?.isActive, true, "the new request is kept, not lost to the cancel it raced")
        try await until("the new transfer") { !bookJobs().isEmpty }
        for job in bookJobs() { system.serve(job, epub, etag: "\"e1\"") }
        await idle(router)
        let ready = try await wait(downloads, "book", [.ready])
        let file = await downloads.fileURL(ready, assetId: "e1")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(file)), epub, "the cancel didn't delete the new download's files")
    }

    func testADownloadRequestedWhileItsRemovalStopsTransfersStartsAgain() async throws {
        let downloads = held()
        await downloads.start()
        await downloads.enqueue(book)
        try await until("the book's transfer") { !bookJobs().isEmpty }

        let removing = Task { await downloads.remove("book") }
        try await until("the removal waiting on the executor") { await gate.arrived == 1 }
        await downloads.enqueue(book)
        await gate.release()
        await removing.value

        let record = await downloads.record("book")
        XCTAssertEqual(record?.isActive, true)
        try await until("the new transfer") { !bookJobs().isEmpty }
        for job in bookJobs() { system.serve(job, epub, etag: "\"e1\"") }
        await idle(router)
        _ = try await wait(downloads, "book", [.ready])
    }

    func testACancelNothingRacesStillStopsAndDeletes() async throws {
        let downloads = held()
        await downloads.start()
        await downloads.enqueue(book)
        try await until("the book's transfer") { !bookJobs().isEmpty }
        await gate.release()
        await downloads.cancel("book")
        let record = await downloads.record("book")
        XCTAssertEqual(record?.state, .cancelled)
        XCTAssertTrue(bookJobs().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bookFolder.path))
    }

    func testARelaunchFinishesACancelTheAppDidntGetToFinish() async throws {
        let downloads = held()
        await downloads.start()
        await downloads.enqueue(book)
        try await until("the book's transfer") { !bookJobs().isEmpty }
        let stopping = Task { await downloads.cancel("book") }
        try await until("the cancel waiting on the executor") { await gate.arrived == 1 }
        // The app ends here: the entry says cancelled, the transfer is still with the system.
        try FileManager.default.createDirectory(at: bookFolder, withIntermediateDirectories: true)
        try Data("left".utf8).write(to: bookFolder.appendingPathComponent("0.epub.part"))

        router = TransferRouter()
        system.router = router
        let relaunched = manager(executors: DownloadExecutors(foreground: system), router: router)
        await relaunched.start()

        let record = await relaunched.record("book")
        XCTAssertEqual(record?.state, .cancelled)
        let pending = await relaunched.pendingTickets
        XCTAssertTrue(pending.isEmpty, "a cancelled entry keeps no tickets")
        XCTAssertTrue(bookJobs().isEmpty, "the transfer it left with the system is cancelled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bookFolder.path), "and what it wrote is deleted")

        // Let the abandoned process's held cancel finish, then close it.
        await gate.release()
        await stopping.value
        await downloads.close()
    }
}

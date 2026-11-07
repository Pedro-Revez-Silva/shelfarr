import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ShelfarrCore
import XCTest

/// The manager against a transfer daemon that outlives it, as iOS's background
/// session does: relaunch, reconciliation, ordering and the account boundary.
final class BackgroundTransferTests: DownloadTestCase {
    private var router = TransferRouter()
    /// The system background session: grant-authorized requests only.
    private lazy var system = FakeSystem(router: router)
    /// The in-app foreground transport, used without grants.
    private lazy var app = FakeSystem(router: router)
    private let grants = Grants()

    private func manager(_ folder: String = "acct", token: String = "secret", max: Int = 2, chunk: Int64 = 32 << 20, onUnauthorized: @escaping @Sendable () -> Void = {}) -> DownloadManager {
        let grants = self.grants
        let executors = DownloadExecutors(foreground: app, background: system, mintGrant: { try grants.mint($0, $1) })
        return manager(folder, token: token, executors: executors, router: router, max: max, chunk: chunk, onUnauthorized: onUnauthorized)
    }

    /// A new process: a new router and manager over the same disk and daemon.
    private func relaunch(_ folder: String = "acct", token: String = "secret", max: Int = 2, chunk: Int64 = 32 << 20, onUnauthorized: @escaping @Sendable () -> Void = {}) -> DownloadManager {
        router = TransferRouter()
        system.router = router
        app.router = router
        return manager(folder, token: token, max: max, chunk: chunk, onUnauthorized: onUnauthorized)
    }

    private func submissions(_ count: Int) async throws {
        try await until("\(count) submitted transfers") { system.live.count >= count }
    }

    private func data(for job: FakeSystem.Job) -> (Data, String) {
        switch job.request.url!.path {
        case "/files/e1": return (epub, "\"e1\"")
        case "/files/t1": return (track1, "\"t1\"")
        default: return (track2, "\"t2\"")
        }
    }

    private func serve(_ job: FakeSystem.Job) async {
        let (body, etag) = data(for: job)
        system.serve(job, body, etag: etag)
        await idle(router)
    }

    func testTicketsAreDurableBeforeSubmissionAndSurviveARelaunch() async throws {
        let manifest = downloadsRoot("acct").appendingPathComponent("manifest.json")
        let seenOnDisk = Counter()
        system.onSubmit = { job in
            let text = (try? String(contentsOf: manifest, encoding: .utf8)) ?? ""
            if text.contains(job.tag.ticket) { seenOnDisk.note() }
        }
        let first = manager(chunk: 4_000)
        await first.enqueue(audiobook)
        try await submissions(4)
        XCTAssertEqual(seenOnDisk.value, system.submitted.count, "every ticket reaches the manifest before its transfer exists")
        XCTAssertEqual(system.submitted.map(\.tag.account), Array(repeating: "acct", count: system.submitted.count))
        XCTAssertTrue(system.submitted.allSatisfy { $0.request.value(forHTTPHeaderField: "Authorization") == nil }, "background requests never hold the bearer")
        XCTAssertTrue(system.submitted.allSatisfy { $0.request.url!.query?.hasPrefix("grant=") == true })
        XCTAssertFalse(system.submitted.contains { $0.tag.description.contains("secret") }, "a task description never carries the token")
        XCTAssertTrue(app.submitted.isEmpty)

        // The process ends without closing; the daemon keeps the transfers.
        let submittedBefore = system.submitted.count
        let second = relaunch(chunk: 4_000)
        await second.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(system.submitted.count, submittedBefore, "live transfers are adopted, not duplicated")
        XCTAssertTrue(transport.allRequests.filter { $0.httpMethod == "HEAD" }.count == 2, "no network is needed to adopt them")
        let adopted = await second.record("audio")
        XCTAssertEqual(adopted?.state, .downloading)

        for job in system.live { await serve(job) }
        let ready = try await wait(second, "audio", [.ready])
        let filesFound = await second.fileURLs(ready)
        let files = try XCTUnwrap(filesFound)
        XCTAssertEqual(try Data(contentsOf: files["t1"]!), track1)
        XCTAssertEqual(try Data(contentsOf: files["t2"]!), track2)
        let left = await second.pendingTickets
        XCTAssertTrue(left.isEmpty)
    }

    func testTheCompletionHandlerWaitsUntilEventsAreOnDisk() async throws {
        let downloads = manager()
        await downloads.enqueue(book)
        try await submissions(1)
        let manifest = downloadsRoot("acct").appendingPathComponent("manifest.json")
        let job = system.live[0]
        system.serve(job, epub, etag: "\"e1\"")
        let stored: String = await withCheckedContinuation { continuation in
            router.whenIdle {
                continuation.resume(returning: (try? String(contentsOf: manifest, encoding: .utf8)) ?? "")
            }
        }
        XCTAssertTrue(stored.contains("\"ready\""), "the system is told events are handled only once they are durable")
    }

    func testRangesArriveOutOfOrderAndAreAppendedInOrder() async throws {
        let downloads = manager(chunk: 1_500)
        await downloads.enqueue(book)
        try await submissions(3)
        let jobs = system.live.sorted { ($0.request.value(forHTTPHeaderField: "Range") ?? "") < ($1.request.value(forHTTPHeaderField: "Range") ?? "") }
        XCTAssertEqual(jobs.map { $0.request.value(forHTTPHeaderField: "Range") }, ["bytes=0-1499", "bytes=1500-2999", "bytes=3000-4001"])
        XCTAssertTrue(jobs.allSatisfy { $0.request.value(forHTTPHeaderField: "If-Range") == "\"e1\"" })
        await serve(jobs[2])
        await serve(jobs[1])
        let waiting = await downloads.record("book")
        XCTAssertEqual(waiting?.state, .downloading)
        XCTAssertEqual(waiting?.bytesDone, 2_502)
        await serve(jobs[0])
        let ready = try await wait(downloads, "book", [.ready])
        let readyFile = await downloads.fileURL(ready, assetId: "e1")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(readyFile)), epub)
    }

    func testStagedRangesSurviveARelaunchBeforeTheGapIsFilled() async throws {
        let first = manager(chunk: 2_100)
        await first.enqueue(book)
        try await submissions(2)
        let jobs = system.live.sorted { ($0.request.value(forHTTPHeaderField: "Range") ?? "") < ($1.request.value(forHTTPHeaderField: "Range") ?? "") }
        await serve(jobs[1])

        let second = relaunch(chunk: 2_100)
        await second.start()
        let restored = await second.record("book")
        XCTAssertEqual(restored?.bytesDone, Int64(epub.count - 2_100))
        await serve(jobs[0])
        _ = try await wait(second, "book", [.ready])
    }

    func testLostTransfersArePlannedAgainAndOrphansAreCancelled() async throws {
        let first = manager(chunk: 2_100)
        await first.enqueue(book)
        try await submissions(2)
        let lost = system.live[0]
        // The daemon forgot one transfer, and holds one no ticket owns.
        system.forget(lost.tag)
        let orphan = TransferTag(account: "acct", ticket: "orphan-1")
        system.adopt(orphan, url: URL(string: "https://example.org/files/e1")!)

        let second = relaunch(chunk: 2_100)
        await second.start()
        XCTAssertTrue(system.cancelled.contains(orphan))
        try await submissions(2)
        let replacement = try XCTUnwrap(system.live.first { $0.tag != system.submitted[1].tag })
        XCTAssertEqual(replacement.request.value(forHTTPHeaderField: "Range"), lost.request.value(forHTTPHeaderField: "Range"))
        for job in system.live { await serve(job) }
        _ = try await wait(second, "book", [.ready])
    }

    func testTransfersSentWithAnOldTokenAreReplacedAndCannotExpireTheNewSession() async throws {
        let first = manager(token: "old-token", chunk: 2_100)
        await first.enqueue(book)
        try await submissions(2)
        let old = system.live

        // Signed in again with a new token: the daemon still holds the old requests.
        let rejected = Counter()
        let second = relaunch(token: "new-token", chunk: 2_100, onUnauthorized: { rejected.note() })
        await second.start()
        XCTAssertTrue(old.allSatisfy { system.cancelled.contains($0.tag) })
        try await submissions(2)
        XCTAssertEqual(grants.count, 2, "the replacements use a grant minted by the new token")

        // The session's own token is refused while planning: that one signs it out.
        await second.cancel("book")
        grants.mode = .signedOut
        await second.enqueue(book)
        let failed = try await wait(second, "book", [.failed])
        XCTAssertEqual(failed.problem, .signIn)
        XCTAssertEqual(rejected.value, 1, "only a rejection of this session's own token signs it out")
    }

    func testARefusedGrantIsReplacedAndNeverSignsTheAccountOut() async throws {
        let rejected = Counter()
        let downloads = manager(onUnauthorized: { rejected.note() })
        await downloads.enqueue(book)
        try await submissions(1)
        system.respond(system.live[0], status: 401, body: nil)
        await idle(router)
        try await until("a replacement with a fresh grant") { grants.count == 2 && system.live.count == 1 }
        XCTAssertEqual(rejected.value, 0)
        await serve(system.live[0])
        _ = try await wait(downloads, "book", [.ready])

        // A server that keeps refusing its own grants stops instead of looping.
        await downloads.remove("book")
        await downloads.enqueue(book)
        for _ in 0 ..< 3 {
            try await submissions(1)
            system.respond(system.live[0], status: 401, body: nil)
            await idle(router)
        }
        let failed = try await wait(downloads, "book", [.failed])
        XCTAssertEqual(failed.problem, .server)
        XCTAssertEqual(rejected.value, 0)
    }

    func testWithoutGrantsTransfersStayInTheAppWithTheBearer() async throws {
        grants.mode = .unsupported
        let downloads = manager()
        await downloads.enqueue(book)
        try await until("a foreground transfer") { app.live.count == 1 }
        XCTAssertTrue(system.submitted.isEmpty, "the bearer never goes to the background session")
        let job = app.live[0]
        XCTAssertEqual(job.request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertNil(job.request.url?.query)
        app.serve(job, epub, etag: "\"e1\"")
        await idle(router)
        _ = try await wait(downloads, "book", [.ready])
        let tickets = await downloads.pendingTickets
        XCTAssertTrue(tickets.isEmpty)
    }

    func testAGrantForAnotherServerIsRefused() async throws {
        grants.mode = .offServer
        let downloads = manager()
        await downloads.enqueue(book)
        let failed = try await wait(downloads, "book", [.failed])
        XCTAssertEqual(failed.problem, .invalid)
        XCTAssertTrue(system.submitted.isEmpty)
        XCTAssertTrue(app.submitted.isEmpty)
    }

    func testAGoneGenerationIsAChangedFile() async throws {
        let downloads = manager()
        await downloads.enqueue(book)
        try await submissions(1)
        system.respond(system.live[0], status: 410, body: Data("{}".utf8))
        await idle(router)
        let failed = try await wait(downloads, "book", [.failed])
        XCTAssertEqual(failed.problem, .changed)
    }

    func testARejectedOldTicketDeliveredLateDoesNotSignOutTheCurrentSession() async throws {
        let first = manager(token: "old-token", chunk: 2_100)
        await first.enqueue(book)
        try await submissions(2)
        let old = system.live
        let rejected = Counter()
        // A new process, whose events for the old transfers arrive before it reconciles.
        let second = relaunch(token: "new-token", chunk: 2_100, onUnauthorized: { rejected.note() })
        system.respond(old[0], status: 401, body: nil)
        await idle(router)
        XCTAssertEqual(rejected.value, 0)
        let record = await second.record("book")
        XCTAssertNotEqual(record?.state, .failed)
    }

    func testCallbacksForAClosedAccountOrARemovedDownloadWriteNothing() async throws {
        let alice = manager("alice", token: "alice-token")
        await alice.enqueue(book)
        try await submissions(1)
        let aliceJob = system.live[0]
        let bob = manager("bob", token: "bob-token")
        await bob.enqueue(audiobook)
        try await submissions(3)

        // Alice signs out; the daemon still finishes her transfer afterwards.
        system.onSubmit = nil
        await alice.close()
        try FileManager.default.removeItem(at: root.appendingPathComponent("alice"))
        system.serve(aliceJob, epub, etag: "\"e1\"")
        await idle(router)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("alice").path), "a late callback never recreates a signed-out account")
        let bobsBook = await bob.record("book")
        XCTAssertNil(bobsBook, "it never reaches another account")

        // Bob removes his download; its late bodies are not written either.
        let bobJobs = system.live.filter { $0.tag.account == "bob" }
        await bob.remove("audio")
        for job in bobJobs { system.serve(job, track1, etag: "\"t1\"") }
        await idle(router)
        let staging = downloadsRoot("bob").appendingPathComponent("staging")
        let staged = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        XCTAssertTrue(staged.isEmpty)
        let removed = await bob.record("audio")
        XCTAssertNil(removed)
    }

    func testARedirectAwayFromTheServerIsDiscarded() async throws {
        let downloads = manager()
        await downloads.enqueue(book)
        try await submissions(1)
        system.serve(system.live[0], epub, etag: "\"e1\"", finalURL: URL(string: "https://cdn.example.net/e1")!)
        await idle(router)
        let failed = try await wait(downloads, "book", [.failed])
        XCTAssertEqual(failed.problem, .redirect)
        XCTAssertEqual(failed.bytesDone, 0)
        let ready = await downloads.ready("book")
        XCTAssertNil(ready)
    }

    func testAForceQuitIsReportedAndRetriedOnReturn() async throws {
        let downloads = manager()
        await downloads.enqueue(book)
        try await submissions(1)
        let reason = URLError(.cancelled, userInfo: ["NSURLErrorBackgroundTaskCancelledReasonKey": 0])
        system.fail(system.live[0], reason)
        await idle(router)
        let failed = try await wait(downloads, "book", [.failed])
        XCTAssertEqual(failed.problem, .interrupted)
        await downloads.retryInterrupted()
        try await submissions(1)
        await serve(system.live[0])
        _ = try await wait(downloads, "book", [.ready])
    }

    func testABodyThatCannotBeStoredIsAStorageFailure() async throws {
        let downloads = manager()
        await downloads.enqueue(book)
        try await submissions(1)
        let staging = downloadsRoot("acct").appendingPathComponent("staging")
        try? FileManager.default.removeItem(at: staging)
        try Data().write(to: staging)
        await serve(system.live[0])
        let failed = try await wait(downloads, "book", [.failed])
        XCTAssertEqual(failed.problem, .storage)
    }

    func testAShortOrMisplacedRangeIsNeverStitched() async throws {
        let downloads = manager(chunk: 2_100)
        await downloads.enqueue(book)
        try await submissions(2)
        let job = system.live.first { $0.request.value(forHTTPHeaderField: "Range") == "bytes=0-2099" }!
        system.respond(job, status: 206, headers: ["ETag": "\"e1\"", "Content-Range": "bytes 10-2109/4002"], body: epub.subdata(in: 10 ..< 2110))
        await idle(router)
        let failed = try await wait(downloads, "book", [.failed])
        XCTAssertEqual(failed.problem, .invalid)
        XCTAssertEqual(failed.bytesDone, 0)
    }

    func testAtMostTwoPublicationsTransferAtOnce() async throws {
        let third = Publication(id: "third", title: "Third", bookType: .ebook, assets: [
            Asset(id: "e1", filename: "b.epub", mediaType: "application/epub+zip", format: "epub", sizeBytes: Int64(epub.count), contentUrl: "/files/e1"),
        ])
        publications["third"] = third
        let downloads = manager()
        await downloads.enqueue(book)
        await downloads.enqueue(audiobook)
        await downloads.enqueue(third)
        try await submissions(3)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(Set(system.live.map(\.request.url!.path)), ["/files/e1", "/files/t1", "/files/t2"])
        let waiting = await downloads.record("third")
        XCTAssertEqual(waiting?.state, .queued)
        let bookJob = system.live.first { $0.request.url!.path == "/files/e1" }!
        await serve(bookJob)
        _ = try await wait(downloads, "book", [.ready])
        _ = try await wait(downloads, "third", [.downloading])
    }

    func testCancelStopsTransfersBeforeDeletingAndKeepsTheEntry() async throws {
        let downloads = manager(chunk: 2_100)
        await downloads.enqueue(book)
        try await submissions(2)
        let jobs = system.live
        await serve(jobs[1])
        await downloads.cancel("book")
        XCTAssertTrue(system.cancelled.contains(jobs[0].tag))
        XCTAssertTrue(system.live.isEmpty)
        let record = await downloads.record("book")
        XCTAssertEqual(record?.state, .cancelled)
        XCTAssertEqual(record?.bytesDone, 0)
        let tickets = await downloads.pendingTickets
        XCTAssertTrue(tickets.isEmpty)
        let staging = downloadsRoot("acct").appendingPathComponent("staging")
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []).isEmpty)
    }

    func testTagsRoundTripAndRejectAnythingElse() {
        let tag = TransferTag(account: "0123abcd", ticket: "f00d-1")
        XCTAssertEqual(TransferTag(tag.description), tag)
        XCTAssertNil(TransferTag("shelfarr-download/1/a/b/c"))
        XCTAssertNil(TransferTag("shelfarr-download/1/../x"))
        XCTAssertNil(TransferTag("other/1/a/b"))
        XCTAssertNil(TransferTag(nil))
    }
}

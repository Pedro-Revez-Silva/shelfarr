import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ShelfarrCore
import XCTest

/// Serves files by path, honouring HEAD, Range and If-Range like the real server,
/// and can drop a transfer part way through a body.
final class FileServer: HTTPTransport, @unchecked Sendable {
    struct Entry {
        var data: Data
        var etag: String
        /// Write this many bytes of the next body, then fail as a dropped connection.
        var cutAfter: Int?
        /// Only cut the request for this range.
        var cutRange: String?
        var status: Int?
        var failure: APIError?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var requests: [URLRequest] = []

    subscript(path: String) -> Entry? {
        get { lock.withLock { entries[path] } }
        set { lock.withLock { entries[path] = newValue } }
    }

    /// Every request, HEAD and GET, in order.
    var allRequests: [URLRequest] { lock.withLock { requests } }
    /// Body requests only.
    var contentRequests: [URLRequest] { allRequests.filter { $0.httpMethod != "HEAD" } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        let entry: Entry? = lock.withLock {
            requests.append(request)
            return entries[path]
        }
        guard request.httpMethod == "HEAD" else { throw APIError.protocolError }
        guard let entry else { return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: [:])!) }
        if let failure = entry.failure { throw failure }
        if let status = entry.status { return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!) }
        let headers = ["ETag": entry.etag, "Content-Length": String(entry.data.count)]
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }

    func download(_ request: URLRequest, to file: URL, onResponse: @escaping @Sendable (HTTPURLResponse) -> Void, onProgress: @escaping @Sendable (Int64) -> Void) async throws -> HTTPURLResponse {
        let path = request.url!.path
        let entry: Entry? = lock.withLock {
            requests.append(request)
            return entries[path]
        }
        guard var entry else { return HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: [:])! }
        if let failure = entry.failure { throw failure }
        if let status = entry.status { return HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])! }

        let (status, body, headers) = Self.respond(request, entry.data, entry.etag)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        onResponse(response)
        if let cut = entry.cutAfter, entry.cutRange == nil || entry.cutRange == request.value(forHTTPHeaderField: "Range") {
            try body.prefix(cut).write(to: file)
            entry.cutAfter = nil
            self[path] = entry
            throw APIError.offline(certificate: false)
        }
        try body.write(to: file)
        onProgress(Int64(body.count))
        return response
    }

    /// What a server sends for `request`: a range when `If-Range` still matches, else the whole file.
    static func respond(_ request: URLRequest, _ data: Data, _ etag: String) -> (Int, Data, [String: String]) {
        var headers = ["ETag": etag]
        if let range = request.value(forHTTPHeaderField: "Range"), request.value(forHTTPHeaderField: "If-Range") == etag {
            let bounds = range.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            let start = Int(bounds[0]) ?? 0
            let end = min(bounds.count > 1 ? Int(bounds[1]) ?? data.count - 1 : data.count - 1, data.count - 1)
            headers["Content-Range"] = "bytes \(start)-\(end)/\(data.count)"
            return (206, data.subdata(in: start ..< end + 1), headers)
        }
        return (200, data, headers)
    }
}

/// Stands in for the system's background transfer daemon: transfers outlive the
/// manager that submitted them, and finish only when the test says so.
final class FakeSystem: DownloadExecutor, @unchecked Sendable {
    struct Job {
        let tag: TransferTag
        let request: URLRequest
    }

    private let lock = NSLock()
    private var jobs: [Job] = []
    private var history: [Job] = []
    private var cancelledTags: [TransferTag] = []
    private var currentRouter: TransferRouter
    var onSubmit: (@Sendable (Job) -> Void)?

    init(router: TransferRouter) { currentRouter = router }

    /// After a relaunch the app owns a new router.
    var router: TransferRouter {
        get { lock.withLock { currentRouter } }
        set { lock.withLock { currentRouter = newValue } }
    }

    var live: [Job] { lock.withLock { jobs } }
    var submitted: [Job] { lock.withLock { history } }
    var cancelled: [TransferTag] { lock.withLock { cancelledTags } }

    func submit(_ request: URLRequest, tag: TransferTag, expectedBytes: Int64?) throws {
        let job = Job(tag: tag, request: request)
        lock.withLock {
            jobs.append(job)
            history.append(job)
        }
        onSubmit?(job)
    }

    func live() async -> [TransferTag] { live.map(\.tag) }

    func cancel(_ tags: [TransferTag]) async {
        let removed: [Job] = lock.withLock {
            cancelledTags += tags
            let found = jobs.filter { tags.contains($0.tag) }
            jobs.removeAll { tags.contains($0.tag) }
            return found
        }
        for job in removed {
            router.complete(job.tag.description, response: nil, error: URLError(.cancelled))
        }
    }

    /// Adds a transfer the manager never submitted, as left by an older install or account.
    func adopt(_ tag: TransferTag, url: URL) {
        lock.withLock { jobs.append(Job(tag: tag, request: URLRequest(url: url))) }
    }

    /// Loses a transfer without any callback, as when it was never handed to the daemon.
    func forget(_ tag: TransferTag) {
        lock.withLock { jobs.removeAll { $0.tag == tag } }
    }

    private func take(_ job: Job) {
        lock.withLock { jobs.removeAll { $0.tag == job.tag } }
    }

    func respond(_ job: Job, status: Int, headers: [String: String] = [:], body: Data?, finalURL: URL? = nil) {
        take(job)
        if let body {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try! body.write(to: file)
            router.stage(job.tag.description, temporaryFile: file)
            try? FileManager.default.removeItem(at: file)
        }
        let response = HTTPURLResponse(url: finalURL ?? job.request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        router.complete(job.tag.description, response: response, error: nil)
    }

    func serve(_ job: Job, _ data: Data, etag: String, finalURL: URL? = nil) {
        let (status, body, headers) = FileServer.respond(job.request, data, etag)
        respond(job, status: status, headers: headers, body: body, finalURL: finalURL)
    }

    func fail(_ job: Job, _ error: Error) {
        take(job)
        router.complete(job.tag.description, response: nil, error: error)
    }
}

/// Issues asset grants the way the server would, or refuses to.
final class Grants: @unchecked Sendable {
    enum Mode { case issue, unsupported, offServer, signedOut }
    private let lock = NSLock()
    private var issued: [String] = []
    var mode: Mode {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
    private var current = Mode.issue

    var count: Int { lock.withLock { issued.count } }

    func mint(_ publicationId: String, _ assetId: String) throws -> TransferGrant {
        let mode = self.mode
        switch mode {
        case .unsupported: throw APIError.notFound
        case .signedOut: throw APIError.unauthorized
        case .offServer: return TransferGrant(url: "https://elsewhere.example/files/\(assetId)?grant=x")
        case .issue:
            let grant = lock.withLock { () -> String in
                issued.append(assetId)
                return "g\(issued.count)"
            }
            return TransferGrant(url: "/files/\(assetId == "e1" ? "e1" : assetId)?grant=\(grant)", expiresAt: "2026-11-08T00:00:00Z")
        }
    }
}

/// Waits until every delivered event has been durably processed.
func idle(_ router: TransferRouter) async {
    await withCheckedContinuation { continuation in router.whenIdle { continuation.resume() } }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func note() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

class DownloadTestCase: XCTestCase {
    var root: URL!
    let transport = FileServer()
    var publications: [String: Publication] = [:]
    let epub = Data("PK".utf8) + Data(repeating: 7, count: 4_000)
    let track1 = Data(repeating: 1, count: 9_000)
    let track2 = Data((0 ..< 7_000).map { UInt8($0 % 251) })

    var server: ServerAddress {
        guard case let .valid(address) = ServerAddress.parse("https://example.org") else { fatalError() }
        return address
    }

    lazy var book = Publication(id: "book", title: "Book", bookType: .ebook, assets: [
        Asset(id: "e1", filename: "b.epub", mediaType: "application/epub+zip", format: "epub", sizeBytes: Int64(epub.count), contentUrl: "/files/e1"),
    ])
    lazy var audiobook = Publication(id: "audio", title: "Audio", bookType: .audiobook, assets: [
        Asset(id: "t2", filename: "2.mp3", mediaType: "audio/mpeg", format: "mp3", sizeBytes: Int64(track2.count), contentUrl: "/files/t2", position: 2),
        Asset(id: "t1", filename: "1.mp3", mediaType: "audio/mpeg", format: "mp3", sizeBytes: Int64(track1.count), contentUrl: "/files/t1", position: 1),
        Asset(id: "img", filename: "c.jpg", mediaType: "image/jpeg", format: "jpg", sizeBytes: 3, contentUrl: "/files/img", position: 0),
    ])

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        publications = [book.id: book, audiobook.id: audiobook]
        transport["/files/e1"] = .init(data: epub, etag: "\"e1\"")
        transport["/files/t1"] = .init(data: track1, etag: "\"t1\"")
        transport["/files/t2"] = .init(data: track2, etag: "\"t2\"")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func downloadsRoot(_ folder: String) -> URL {
        root.appendingPathComponent(folder).appendingPathComponent("downloads")
    }

    func manager(
        _ folder: String = "acct",
        token: String = "secret",
        executors: DownloadExecutors,
        router: TransferRouter,
        space: Int64? = nil,
        max: Int = 2,
        chunk: Int64 = 32 << 20,
        window: Int = 64,
        onUnauthorized: @escaping @Sendable () -> Void = {}
    ) -> DownloadManager {
        let server = self.server
        let api = ConsumerAPI(transport: transport, credential: { Credential(server: server, accessToken: token) })
        let known = publications
        let manager = DownloadManager(
            root: downloadsRoot(folder),
            account: folder,
            credential: DownloadManager.credentialTag(token),
            transport: transport,
            executors: executors,
            router: router,
            server: server,
            authorize: { api.authorized($0) },
            fetchPublication: { id in
                guard let found = known[id] else { throw APIError.notFound }
                return found
            },
            maxConcurrent: max,
            chunkSize: chunk,
            maxTicketsPerLane: window,
            usableSpace: { space },
            onUnauthorized: onUnauthorized
        )
        manager.connect()
        return manager
    }

    func wait(_ downloads: DownloadManager, _ id: String, _ states: Set<DownloadState>, file: StaticString = #filePath, line: UInt = #line) async throws -> DownloadRecord {
        for _ in 0 ..< 500 {
            if let record = await downloads.record(id), states.contains(record.state) { return record }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(states)", file: file, line: line)
        throw CancellationError()
    }

    func until(_ what: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () async -> Bool) async throws {
        for _ in 0 ..< 500 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(what)", file: file, line: line)
        throw CancellationError()
    }
}

/// Downloads through the in-process executor: the same manager, router and events as
/// the app's background session, over a fake HTTP server.
final class DownloadsTests: DownloadTestCase {
    private let router = TransferRouter()
    private lazy var executor = InProcessDownloadExecutor(transport: transport, router: router, scratch: root.appendingPathComponent("scratch"))

    private func manager(_ folder: String = "acct", token: String = "secret", space: Int64? = nil, max: Int = 2, chunk: Int64 = 32 << 20, window: Int = 64, onUnauthorized: @escaping @Sendable () -> Void = {}) -> DownloadManager {
        manager(folder, token: token, executors: DownloadExecutors(foreground: executor), router: router, space: space, max: max, chunk: chunk, window: window, onUnauthorized: onUnauthorized)
    }

    func testManifestFailureIsVisibleAndRetryableWithoutTransferring() async throws {
        let blocked = root.appendingPathComponent("acct/downloads/manifest.json")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let downloads = manager()
        await downloads.start()
        await downloads.enqueue(book)
        let failed = try await wait(downloads, "book", [.failed])
        XCTAssertEqual(failed.problem, .storage)
        XCTAssertTrue(transport.contentRequests.isEmpty)
        try FileManager.default.removeItem(at: blocked)
        await downloads.retry("book")
        _ = try await wait(downloads, "book", [.ready])
        await downloads.close()
    }

    func testCancelAndRemoveReportManifestWriteFailures() async throws {
        let downloads = manager()
        await downloads.enqueue(book)
        _ = try await wait(downloads, "book", [.ready])
        let blocked = root.appendingPathComponent("acct/downloads/manifest.json")
        try FileManager.default.removeItem(at: blocked)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        await downloads.cancel("book")
        let cancelled = await downloads.record("book")
        XCTAssertEqual(cancelled?.state, .failed)
        XCTAssertEqual(cancelled?.problem, .storage)
        await downloads.remove("book")
        let removed = await downloads.record("book")
        XCTAssertEqual(removed?.state, .failed)
        XCTAssertEqual(removed?.problem, .storage)
        await downloads.close()
    }

    func testAnEpubDownloadsWithItsAccountTokenAndSurvivesARestart() async throws {
        let downloads = manager()
        await downloads.start()
        await downloads.enqueue(book)
        let ready = try await wait(downloads, "book", [.ready])
        let found = await downloads.fileURL(ready, assetId: "e1")
        let file = try XCTUnwrap(found)
        XCTAssertEqual(try Data(contentsOf: file), epub)
        // The HEAD that checks the server, then one plain GET for a small file.
        XCTAssertEqual(transport.allRequests.map { $0.httpMethod ?? "GET" }, ["HEAD", "GET"])
        XCTAssertTrue(transport.allRequests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret" })
        XCTAssertNil(transport.contentRequests.first?.value(forHTTPHeaderField: "Range"))
        XCTAssertFalse(file.path.contains("Caches"))
        let tickets = await downloads.pendingTickets
        XCTAssertTrue(tickets.isEmpty)
        await downloads.close()

        let reopened = manager()
        await reopened.start()
        let reopenedReady = await reopened.ready("book")
        let restored = try XCTUnwrap(reopenedReady)
        XCTAssertEqual(restored.publication.title, "Book")
        let restoredFile = await reopened.fileURL(restored, assetId: "e1")
        XCTAssertNotNil(restoredFile)
    }

    func testAnAudiobookDownloadsEveryAudioFileBeforeItIsReady() async throws {
        let downloads = manager()
        await downloads.enqueue(audiobook)
        let ready = try await wait(downloads, "audio", [.ready])
        XCTAssertEqual(ready.pinnedAssetIds, ["t1", "t2"])
        XCTAssertEqual(transport.allRequests.filter { $0.httpMethod == "HEAD" }.map { $0.url!.path }, ["/files/t1", "/files/t2"])
        XCTAssertEqual(Set(transport.contentRequests.map { $0.url!.path }), ["/files/t1", "/files/t2"])
        let urls = await downloads.fileURLs(ready)
        let files = try XCTUnwrap(urls)
        XCTAssertEqual(try Data(contentsOf: files["t1"]!), track1)
        XCTAssertEqual(try Data(contentsOf: files["t2"]!), track2)
        XCTAssertTrue(files["t1"]!.lastPathComponent.hasSuffix(".mp3"))
    }

    func testAnInterruptedChunkIsNeverReadyAndResumesWithIfRange() async throws {
        transport["/files/t2"]?.cutAfter = 500
        let downloads = manager(chunk: 2_000)
        await downloads.enqueue(audiobook)
        let failed = try await wait(downloads, "audio", [.failed])
        XCTAssertEqual(failed.problem, .offline)
        let ready = await downloads.ready("audio")
        XCTAssertNil(ready)
        XCTAssertLessThan(failed.bytesDone, Int64(track1.count + track2.count))

        let before = transport.contentRequests.count
        await downloads.retryInterrupted()
        let done = try await wait(downloads, "audio", [.ready])
        let resumed = transport.contentRequests.dropFirst(before)
        // Only ranges that weren't already on the device are asked for again.
        XCTAssertFalse(resumed.isEmpty)
        XCTAssertLessThan(resumed.count, before)
        for request in resumed {
            let validator = request.url!.path == "/files/t1" ? "\"t1\"" : "\"t2\""
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Range"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-Range"), validator)
        }
        let doneFilesFound = await downloads.fileURLs(done)
        let doneFiles = try XCTUnwrap(doneFilesFound)
        XCTAssertEqual(try Data(contentsOf: doneFiles["t1"]!), track1)
        XCTAssertEqual(try Data(contentsOf: doneFiles["t2"]!), track2)
    }

    func testAPartialTransferResumesAfterRestart() async throws {
        // One range in flight at a time, so the first two are on disk when the third drops.
        transport["/files/e1"]?.cutAfter = 10
        transport["/files/e1"]?.cutRange = "bytes=2000-2999"
        let downloads = manager(chunk: 1_000, window: 1)
        await downloads.enqueue(book)
        let failed = try await wait(downloads, "book", [.failed])
        let kept = failed.bytesDone
        XCTAssertEqual(kept, 2_000)
        await downloads.close()

        let reopened = manager(chunk: 1_000, window: 1)
        await reopened.start()
        let partial = await reopened.record("book")
        XCTAssertEqual(partial?.bytesDone, kept)
        let before = transport.contentRequests.count
        await reopened.retryInterrupted()
        let done = try await wait(reopened, "book", [.ready])
        let ranges = transport.contentRequests.dropFirst(before).compactMap { $0.value(forHTTPHeaderField: "Range") }
        XCTAssertEqual(ranges.first, "bytes=2000-2999", "bytes already on disk are not fetched again: \(ranges)")
        let fileFound = await reopened.fileURL(done, assetId: "e1")
        let file = try XCTUnwrap(fileFound)
        XCTAssertEqual(try Data(contentsOf: file), epub)
    }

    func testAFirstManifestMigratesAndResumesItsPartialFile() async throws {
        // The format before tickets: records only, a .part file and an .etag sidecar.
        let downloads = downloadsRoot("acct")
        let folder = downloads.appendingPathComponent(String(SHA256.hexDigest(Data("book".utf8)).prefix(32)))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "000-" + String(SHA256.hexDigest(Data("e1".utf8)).prefix(32)) + ".epub"
        try epub.prefix(1_500).write(to: folder.appendingPathComponent(name + ".part"))
        try Data("\"e1\"".utf8).write(to: folder.appendingPathComponent(name + ".etag"))
        let record = DownloadRecord(publicationId: "book", publication: book, files: [
            DownloadedFile(assetId: "e1", name: name, sizeBytes: Int64(epub.count)),
        ], state: .downloading)
        try JSONEncoder().encode(["book": record]).write(to: downloads.appendingPathComponent("manifest.json"))

        let migrated = manager(chunk: 1_000)
        let loaded = await migrated.record("book")
        XCTAssertEqual(loaded?.state, .queued)
        XCTAssertEqual(loaded?.bytesDone, 1_500)
        await migrated.start()
        let done = try await wait(migrated, "book", [.ready])
        XCTAssertEqual(transport.contentRequests.first?.value(forHTTPHeaderField: "Range"), "bytes=1500-2499")
        XCTAssertEqual(transport.contentRequests.first?.value(forHTTPHeaderField: "If-Range"), "\"e1\"")
        let fileFound = await migrated.fileURL(done, assetId: "e1")
        let file = try XCTUnwrap(fileFound)
        XCTAssertEqual(try Data(contentsOf: file), epub)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name + ".etag").path))
    }

    func testAChangedFileFailsInsteadOfBeingStitched() async throws {
        transport["/files/e1"]?.cutAfter = 10
        transport["/files/e1"]?.cutRange = "bytes=1000-1999"
        let downloads = manager(chunk: 1_000, window: 1)
        await downloads.enqueue(book)
        let interrupted = try await wait(downloads, "book", [.failed])
        XCTAssertGreaterThan(interrupted.bytesDone, 0)
        transport["/files/e1"] = .init(data: Data("PK-new-edition".utf8) + Data(repeating: 3, count: epub.count - 14), etag: "\"e2\"")
        await downloads.retry("book")
        let failed = try await wait(downloads, "book", [.failed])
        XCTAssertEqual(failed.problem, .changed)
        XCTAssertEqual(failed.bytesDone, 0)
    }

    func testAReplacedEditionIsRepinned() async throws {
        let downloads = manager()
        await downloads.enqueue(book)
        let first = try await wait(downloads, "book", [.ready])
        let edition = Publication(id: "book", title: "Book", bookType: .ebook, assets: [
            Asset(id: "e9", format: "epub", sizeBytes: 6, contentUrl: "/files/e9"),
        ])
        XCTAssertFalse(first.matches(edition))
        transport["/files/e9"] = .init(data: Data("PK-new".utf8), etag: "\"n\"")
        await downloads.close()

        publications["book"] = edition
        let next = manager()
        await next.start()
        await next.enqueue(edition)
        let updated = try await wait(next, "book", [.ready])
        XCTAssertEqual(updated.pinnedAssetIds, ["e9"])
        let old = await next.fileURL(updated, assetId: "e1")
        XCTAssertNil(old)
    }

    func testFailuresStayDistinct() async throws {
        transport["/files/e1"]?.status = 401
        let rejected = Counter()
        let signedOut = manager("a", onUnauthorized: { rejected.note() })
        await signedOut.enqueue(book)
        let signIn = try await wait(signedOut, "book", [.failed])
        XCTAssertEqual(signIn.problem, .signIn)
        XCTAssertEqual(rejected.value, 1)

        transport["/files/e1"] = .init(data: epub, etag: "\"e1\"", failure: .offline(certificate: true))
        let untrusted = manager("b")
        await untrusted.enqueue(book)
        let certificate = try await wait(untrusted, "book", [.failed])
        XCTAssertEqual(certificate.problem, .certificate)

        transport["/files/e1"] = .init(data: epub, etag: "\"e1\"", failure: .redirectBlocked("https://elsewhere.example"))
        let moved = manager("d")
        await moved.enqueue(book)
        let redirect = try await wait(moved, "book", [.failed])
        XCTAssertEqual(redirect.problem, .redirect)
        XCTAssertTrue(transport.contentRequests.isEmpty, "a refused redirect in the preflight sends no body request")

        transport["/files/e1"] = .init(data: epub, etag: "\"e1\"")
        let full = manager("c", space: 10)
        await full.enqueue(book)
        let storage = try await wait(full, "book", [.failed])
        XCTAssertEqual(storage.problem, .storage)
    }

    func testMissingFilesAreNeverReported() async throws {
        let downloads = manager()
        await downloads.enqueue(book)
        let ready = try await wait(downloads, "book", [.ready])
        let readyFile = await downloads.fileURL(ready, assetId: "e1")
        try FileManager.default.removeItem(at: try XCTUnwrap(readyFile))
        await downloads.close()
        let reopened = manager()
        await reopened.start()
        let record = await reopened.record("book")
        XCTAssertEqual(record?.state, .failed)
        XCTAssertEqual(record?.problem, .missing)
    }

    func testCancelAndRemoveDeleteFiles() async throws {
        let downloads = manager()
        await downloads.enqueue(book)
        _ = try await wait(downloads, "book", [.ready])
        await downloads.cancel("book")
        let cancelled = await downloads.record("book")
        XCTAssertEqual(cancelled?.state, .cancelled)
        XCTAssertEqual(cancelled?.bytesDone, 0)
        await downloads.enqueue(book)
        _ = try await wait(downloads, "book", [.ready])
        await downloads.remove("book")
        let removed = await downloads.record("book")
        XCTAssertNil(removed)
        let folders = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("acct/downloads"), includingPropertiesForKeys: nil)
        XCTAssertEqual(folders.map(\.lastPathComponent).filter { $0 != "staging" }, ["manifest.json"])
    }

    func testClosingForSignOutStopsWritesAndKeepsAccountsApart() async throws {
        let one = manager("one", token: "token-one")
        let two = manager("two", token: "token-two")
        await one.enqueue(book)
        _ = try await wait(one, "book", [.ready])
        await two.enqueue(book)
        _ = try await wait(two, "book", [.ready])
        let tokens = transport.contentRequests.map { $0.value(forHTTPHeaderField: "Authorization") }
        XCTAssertEqual(tokens, ["Bearer token-one", "Bearer token-two"])

        await two.close()
        try FileManager.default.removeItem(at: root.appendingPathComponent("two"))
        await two.enqueue(audiobook)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("two").path))
        let kept = await one.ready("book")
        XCTAssertNotNil(kept)
    }

    func testReadingStatusIsDerivedWhenAbsentAndExplicitWhenSent() throws {
        let json = """
        {"items":[
          {"id":"a","title":"A","book_type":"ebook","reading_status":"finished"},
          {"id":"b","title":"B","book_type":"ebook","progress":{"asset_id":"x","position_seconds":1,"version":1}},
          {"id":"c","title":"C","book_type":"ebook"},
          {"id":"d","title":"D","book_type":"ebook","reading_status":"abandoned"},
          {"id":"e","title":"E","book_type":"ebook","reading_status":"unread","progress":{"asset_id":"x","position_seconds":1,"version":1}}
        ],"next_cursor":null}
        """
        let page = try JSONDecoder().decode(LibraryPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.items.map(\.status), [.finished, .inProgress, .unread, .unread, .unread])
        XCTAssertEqual(page.items[4].progress?.positionSeconds, 1)
        let roundTrip = try JSONDecoder().decode(Publication.self, from: JSONEncoder().encode(page.items[0]))
        XCTAssertEqual(roundTrip.readingStatus, .finished)
    }
}

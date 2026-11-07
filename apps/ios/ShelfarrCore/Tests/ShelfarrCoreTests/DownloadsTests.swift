import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ShelfarrCore
import XCTest

/// Serves files by path, honouring Range and If-Range like the real transport,
/// and can drop a transfer part way through a body.
final class FileServer: HTTPTransport, @unchecked Sendable {
    struct Entry {
        var data: Data
        var etag: String
        /// Write this many bytes, then fail as a dropped connection.
        var cutAfter: Int?
        var status: Int?
        var failure: APIError?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private(set) var requests: [URLRequest] = []

    subscript(path: String) -> Entry? {
        get { lock.withLock { entries[path] } }
        set { lock.withLock { entries[path] = newValue } }
    }

    var contentRequests: [URLRequest] { lock.withLock { requests } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw APIError.protocolError
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

        var status = 200
        var body = entry.data
        var headers = ["ETag": entry.etag]
        if let range = request.value(forHTTPHeaderField: "Range"), request.value(forHTTPHeaderField: "If-Range") == entry.etag,
           let start = Int(range.dropFirst("bytes=".count).split(separator: "-").first ?? "") {
            status = 206
            body = entry.data.subdata(in: start ..< entry.data.count)
            headers["Content-Range"] = "bytes \(start)-\(entry.data.count - 1)/\(entry.data.count)"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        onResponse(response)
        if status == 200 { FileManager.default.createFile(atPath: file.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: file)
        _ = try handle.seekToEnd()
        if let cut = entry.cutAfter {
            try handle.write(contentsOf: body.prefix(cut))
            try handle.close()
            entry.cutAfter = nil
            self[path] = entry
            throw APIError.offline(certificate: false)
        }
        try handle.write(contentsOf: body)
        try handle.close()
        onProgress(Int64(body.count))
        return response
    }
}

final class DownloadsTests: XCTestCase {
    private var root: URL!
    private let transport = FileServer()
    private var publications: [String: Publication] = [:]
    private let epub = Data("PK".utf8) + Data(repeating: 7, count: 4_000)
    private let track1 = Data(repeating: 1, count: 9_000)
    private let track2 = Data(repeating: 2, count: 7_000)

    private var server: ServerAddress {
        guard case let .valid(address) = ServerAddress.parse("https://example.org") else { fatalError() }
        return address
    }

    private lazy var book = Publication(id: "book", title: "Book", bookType: .ebook, assets: [
        Asset(id: "e1", filename: "b.epub", mediaType: "application/epub+zip", format: "epub", sizeBytes: Int64(epub.count), contentUrl: "/files/e1"),
    ])
    private lazy var audiobook = Publication(id: "audio", title: "Audio", bookType: .audiobook, assets: [
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

    private func manager(_ folder: String = "acct", token: String = "secret", space: Int64? = nil, max: Int = 2, onUnauthorized: @escaping @Sendable () -> Void = {}) -> DownloadManager {
        let server = self.server
        let api = ConsumerAPI(transport: transport, credential: { Credential(server: server, accessToken: token) })
        let known = publications
        return DownloadManager(
            root: root.appendingPathComponent(folder).appendingPathComponent("downloads"),
            transport: transport,
            server: server,
            authorize: { api.authorized($0) },
            fetchPublication: { id in
                guard let found = known[id] else { throw APIError.notFound }
                return found
            },
            maxConcurrent: max,
            usableSpace: { space },
            onUnauthorized: onUnauthorized
        )
    }

    private func wait(_ downloads: DownloadManager, _ id: String, _ states: Set<DownloadState>) async throws -> DownloadRecord {
        for _ in 0 ..< 500 {
            if let record = await downloads.record(id), states.contains(record.state) { return record }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(states)")
        throw CancellationError()
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
        XCTAssertEqual(transport.contentRequests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertFalse(file.path.contains("Caches"))
        await downloads.close()

        let reopened = manager()
        await reopened.start()
        let reopenedReady = await reopened.ready("book")
        let restored = try XCTUnwrap(reopenedReady)
        XCTAssertEqual(restored.publication.title, "Book")
        let restoredFile = await reopened.fileURL(restored, assetId: "e1")
        XCTAssertNotNil(restoredFile)
    }

    func testAnAudiobookDownloadsEveryAudioFileInOrder() async throws {
        let downloads = manager()
        await downloads.enqueue(audiobook)
        let ready = try await wait(downloads, "audio", [.ready])
        XCTAssertEqual(ready.pinnedAssetIds, ["t1", "t2"])
        XCTAssertEqual(transport.contentRequests.map { $0.url!.path }, ["/files/t1", "/files/t2"])
        let urls = await downloads.fileURLs(ready)
        let files = try XCTUnwrap(urls)
        XCTAssertEqual(try Data(contentsOf: files["t1"]!), track1)
        XCTAssertEqual(try Data(contentsOf: files["t2"]!), track2)
        XCTAssertTrue(files["t1"]!.lastPathComponent.hasSuffix(".mp3"))
    }

    func testAnInterruptedTransferIsNeverReadyAndResumesWithIfRange() async throws {
        transport["/files/t2"]?.cutAfter = 3_000
        let downloads = manager()
        await downloads.enqueue(audiobook)
        let failed = try await wait(downloads, "audio", [.failed])
        XCTAssertEqual(failed.problem, .offline)
        let ready = await downloads.ready("audio")
        XCTAssertNil(ready)
        XCTAssertEqual(failed.bytesDone, Int64(track1.count + 3_000))

        await downloads.retryInterrupted()
        let done = try await wait(downloads, "audio", [.ready])
        let resumed = try XCTUnwrap(transport.contentRequests.last)
        XCTAssertEqual(resumed.value(forHTTPHeaderField: "Range"), "bytes=3000-")
        XCTAssertEqual(resumed.value(forHTTPHeaderField: "If-Range"), "\"t2\"")
        XCTAssertEqual(transport.contentRequests.filter { $0.url!.path == "/files/t1" }.count, 1)
        let doneFiles = await downloads.fileURLs(done)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(doneFiles)["t2"]!), track2)
    }

    func testAPartialTransferResumesAfterRestart() async throws {
        transport["/files/e1"]?.cutAfter = 1_000
        let downloads = manager()
        await downloads.enqueue(book)
        _ = try await wait(downloads, "book", [.failed])
        await downloads.close()

        let reopened = manager()
        await reopened.start()
        let partial = await reopened.record("book")
        XCTAssertEqual(partial?.bytesDone, 1_000)
        await reopened.retryInterrupted()
        _ = try await wait(reopened, "book", [.ready])
        XCTAssertEqual(transport.contentRequests.last?.value(forHTTPHeaderField: "Range"), "bytes=1000-")
    }

    func testAChangedFileFailsInsteadOfBeingStitched() async throws {
        transport["/files/e1"]?.cutAfter = 1_000
        let downloads = manager()
        await downloads.enqueue(book)
        _ = try await wait(downloads, "book", [.failed])
        transport["/files/e1"] = .init(data: Data("PK-new-edition".utf8), etag: "\"e2\"")
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
        final class Rejections: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func note() { lock.withLock { count += 1 } }
            var value: Int { lock.withLock { count } }
        }
        let rejected = Rejections()
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
        XCTAssertEqual(folders.map(\.lastPathComponent), ["manifest.json"])
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

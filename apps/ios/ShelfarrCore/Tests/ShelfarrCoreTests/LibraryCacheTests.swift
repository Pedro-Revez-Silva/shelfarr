import Foundation
@testable import ShelfarrCore
import XCTest

final class LibraryCacheTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func title(_ id: String, _ title: String, author: String = "Someone", type: BookType = .ebook, status: ReadingStatus? = nil) -> Publication {
        Publication(id: id, title: title, author: author, bookType: type, readingStatus: status)
    }

    private var file: URL { root.appendingPathComponent("library-cache.json") }

    func testOfflineQueriesFilterSearchSortAndPageSavedTitles() async {
        let cache = LibraryCache(file: file)
        let now = Date()
        await cache.record([
            title("c", "Émile", author: "Rousseau", status: .finished),
            title("a", "Dune", author: "Frank Herbert", status: .inProgress),
            title("b", "Book 10", type: .audiobook),
            title("d", "Book 9", type: .audiobook),
        ], seenAt: now, recentOffset: 0)

        let recent = await cache.query(LibraryQuery())
        XCTAssertEqual(recent.items.map(\.id), ["c", "a", "b", "d"], "the server's last-seen order")
        let byTitle = await cache.query(LibraryQuery(sort: .title))
        XCTAssertEqual(byTitle.items.map(\.title), ["Book 9", "Book 10", "Dune", "Émile"])
        let audio = await cache.query(LibraryQuery(filter: .audiobook))
        XCTAssertEqual(Set(audio.items.map(\.id)), ["b", "d"])
        let finished = await cache.query(LibraryQuery(status: .finished))
        XCTAssertEqual(finished.items.map(\.id), ["c"])
        let accentless = await cache.query(LibraryQuery(text: "emile"))
        XCTAssertEqual(accentless.items.map(\.id), ["c"])
        let byAuthor = await cache.query(LibraryQuery(text: "herb"))
        XCTAssertEqual(byAuthor.items.map(\.id), ["a"])

        let first = await cache.query(LibraryQuery(sort: .title), limit: 3)
        XCTAssertEqual(first.items.count, 3)
        XCTAssertEqual(first.nextOffset, 3)
        XCTAssertEqual(first.total, 4)
        let second = await cache.query(LibraryQuery(sort: .title), offset: 3, limit: 3)
        XCTAssertEqual(second.items.map(\.id), ["c"])
        XCTAssertNil(second.nextOffset)
        XCTAssertEqual(second.coverage.titles, 4)
        XCTAssertEqual(second.coverage.newest, now)
    }

    func testAnOlderResponseNeverUndoesANewerCopy() async {
        let cache = LibraryCache(file: file)
        let started = Date()
        // A status change lands after a library request started but before it returned.
        await cache.record([title("a", "Dune", status: .finished)], seenAt: started.addingTimeInterval(1))
        await cache.record([title("a", "Dune", status: .inProgress)], seenAt: started, recentOffset: 0)
        let saved = await cache.title("a")
        XCTAssertEqual(saved?.publication.status, .finished)
    }

    func testDownloadsAreMergedAndSurviveEviction() async {
        let cache = LibraryCache(file: file, limit: 2)
        let now = Date()
        await cache.pin(["kept"])
        await cache.record([title("kept", "Kept")], seenAt: now.addingTimeInterval(-100))
        await cache.record([title("x", "X"), title("y", "Y")], seenAt: now)
        let after = await cache.query(LibraryQuery())
        XCTAssertEqual(after.items.count, 2, "the cache stays bounded")
        XCTAssertTrue(after.items.contains { $0.id == "kept" }, "a pinned download outlives eviction")

        // A download the cache never saw still shows offline, from its own record.
        let page = await cache.query(LibraryQuery(sort: .title), downloads: [title("only-downloaded", "Aardvark")])
        XCTAssertEqual(page.items.first?.id, "only-downloaded")
        XCTAssertEqual(page.coverage.downloaded, 1)
    }

    func testItSurvivesARestartAndNeverRecreatesASignedOutAccount() async throws {
        let cache = LibraryCache(file: file)
        await cache.record([title("a", "Dune")], seenAt: Date())
        let reopened = LibraryCache(file: file)
        let found = await reopened.title("a")
        XCTAssertEqual(found?.publication.title, "Dune")

        await reopened.close()
        try FileManager.default.removeItem(at: root)
        await reopened.record([title("b", "Late")], seenAt: Date())
        let late = LibraryCache(file: file)
        await late.record([title("c", "After sign-out")], seenAt: Date())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testListingsFallBackToTheDeviceOnlyWhenTheConnectionIsDown() async throws {
        let cache = LibraryCache(file: file)
        final class Script: @unchecked Sendable {
            var results: [Result<LibraryPage, Error>] = []
            var queries: [(LibraryQuery, String?)] = []
        }
        let script = Script()
        let source = LibrarySource(cache: cache, pageSize: 2) { query, cursor in
            script.queries.append((query, cursor))
            return try script.results.removeFirst().get()
        }
        let pageOne = LibraryPage(items: [title("a", "Alpha"), title("b", "Beta")], nextCursor: "c2")
        let pageTwo = LibraryPage(items: [title("c", "Gamma", type: .audiobook)], nextCursor: nil)
        script.results = [.success(pageOne), .success(pageTwo)]
        let online = try await source.load(LibraryQuery())
        XCTAssertEqual(online.source, .server)
        XCTAssertEqual(online.next, .server("c2"))
        let more = try await source.load(LibraryQuery(), after: online.next, shown: 2)
        XCTAssertEqual(more.items.map(\.id), ["c"])
        XCTAssertEqual(script.queries.last?.1, "c2")

        script.results = [.failure(APIError.offline(certificate: false))]
        let offline = try await source.load(LibraryQuery(), downloads: [title("d", "Delta")])
        guard case let .device(coverage) = offline.source else { return XCTFail("expected the device") }
        XCTAssertEqual(coverage.titles, 4)
        XCTAssertEqual(coverage.downloaded, 1)
        XCTAssertEqual(offline.items.map(\.id), ["a", "b"], "recent order as the server last listed it")
        XCTAssertEqual(offline.next, .device(2))
        let offlineMore = try await source.load(LibraryQuery(), after: offline.next, downloads: [title("d", "Delta")])
        XCTAssertEqual(offlineMore.items.map(\.id), ["c", "d"])
        XCTAssertEqual(script.queries.count, 3, "a device page never asks the server")

        let searched = try await { () async throws -> LibraryListing in
            script.results = [.failure(APIError.offline(certificate: false))]
            return try await source.load(LibraryQuery(filter: .audiobook, text: "gam"))
        }()
        XCTAssertEqual(searched.items.map(\.id), ["c"])

        for error in [APIError.unauthorized, .offline(certificate: true), .redirectBlocked("x"), .server(502), .forbidden] {
            script.results = [.failure(error)]
            do {
                _ = try await source.load(LibraryQuery())
                XCTFail("\(error) must stay visible")
            } catch let actual as APIError { XCTAssertEqual(actual, error) }
        }
        // A failed later page keeps the online list instead of switching sources mid-way.
        script.results = [.failure(APIError.offline(certificate: false))]
        do {
            _ = try await source.load(LibraryQuery(), after: .server("c2"), shown: 2)
            XCTFail("expected the page to fail")
        } catch {}
    }

    func testFilteredListingsDoNotRewriteTheRecentOrder() async throws {
        let cache = LibraryCache(file: file)
        let all = LibraryPage(items: [title("a", "A"), title("b", "B", type: .audiobook)], nextCursor: nil)
        let audio = LibraryPage(items: [title("b", "B", type: .audiobook)], nextCursor: nil)
        let source = LibrarySource(cache: cache) { query, _ in query.filter == .all ? all : audio }
        _ = try await source.load(LibraryQuery())
        _ = try await source.load(LibraryQuery(filter: .audiobook))
        let rank = await cache.title("b")?.recentRank
        XCTAssertEqual(rank, 1)
    }

    func testDetailsFallBackToATitleOnlySeenInAListing() async throws {
        guard case let .valid(server) = ServerAddress.parse("https://example.org") else { return XCTFail() }
        let transport = FakeTransport()
        let api = ConsumerAPI(transport: transport, credential: { Credential(server: server, accessToken: "t") })
        let cache = LibraryCache(file: file)
        await cache.record([title("p", "Listed", status: .finished)], seenAt: Date())
        let details = AccountPublications(directory: root.appendingPathComponent("publications"), cache: cache)
        transport.replies.append(.failure(APIError.offline(certificate: false)))
        let offline = try await details.load(id: "p", server: server, api: api)
        XCTAssertTrue(offline.unverified)
        XCTAssertEqual(offline.publication.status, .finished)
        transport.replies.append(.failure(APIError.unauthorized))
        do {
            _ = try await details.load(id: "p", server: server, api: api)
            XCTFail("sign-in errors are never hidden")
        } catch let error as APIError { XCTAssertEqual(error, .unauthorized) }
    }
}

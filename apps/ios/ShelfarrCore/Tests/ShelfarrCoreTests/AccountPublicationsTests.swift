import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ShelfarrCore
import XCTest

final class AccountPublicationsTests: XCTestCase {
    func testOfflineReopeningNeedsMetadataFromThisAccountAndNeverHidesAuthOrTLSErrors() async throws {
        guard case let .valid(server) = ServerAddress.parse("https://example.org") else { return XCTFail() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = FakeTransport()
        let api = ConsumerAPI(transport: transport, credential: { Credential(server: server, accessToken: "t") })
        let first = AccountPublications(directory: root.appendingPathComponent("alice"))
        transport.enqueue(200, #"{"id":"p","title":"A book","book_type":"ebook","assets":[{"id":"a","format":"epub","content_url":"/file","size_bytes":10}]}"#)
        let online = try await first.load(id: "p", server: server, api: api)
        XCTAssertFalse(online.unverified)
        transport.replies.append(.failure(APIError.offline(certificate: false)))
        let reopened = try await AccountPublications(directory: root.appendingPathComponent("alice")).load(id: "p", server: server, api: api)
        XCTAssertTrue(reopened.unverified)
        XCTAssertEqual(reopened.publication, online.publication)
        for (directory, error) in [("bob", APIError.offline(certificate: false)), ("alice", .unauthorized), ("alice", .offline(certificate: true))] {
            transport.replies.append(.failure(error))
            do {
                _ = try await AccountPublications(directory: root.appendingPathComponent(directory)).load(id: "p", server: server, api: api)
                XCTFail("must propagate \(error)")
            } catch let actual as APIError { XCTAssertEqual(actual, error) }
        }
    }
    func testLateDetailsKeepNewerCanonicalMetadataOffline() async throws {
        guard case let .valid(server) = ServerAddress.parse("https://example.org") else { return XCTFail() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = LibraryCache(file: root.appendingPathComponent("library-cache.json"))
        let store = AccountPublications(directory: root.appendingPathComponent("publications"), cache: cache)
        let transport = GatedMetadataTransport()
        let api = ConsumerAPI(transport: transport, credential: { Credential(server: server, accessToken: "t") })
        let pending = Task { try await store.load(id: "p", server: server, api: api) }
        while !(await transport.started) { try await Task.sleep(nanoseconds: 1_000_000) }
        let newer = Publication(id: "p", title: "New title", bookType: .ebook, readingStatus: .finished)
        await cache.record([newer], seenAt: Date())
        try await Task.sleep(nanoseconds: 20_000_000)
        await transport.release()
        _ = try await pending.value
        let saved = await cache.title("p")
        XCTAssertEqual(saved?.publication.title, "New title")
        let offline = try await store.load(id: "p", server: server, api: api)
        XCTAssertEqual(offline.publication.title, "New title", "completion mtime is not the metadata observation time")
    }

}

private actor GatedMetadataTransport: HTTPTransport {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var served = false
    func release() { continuation?.resume(); continuation = nil }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if served { throw APIError.offline(certificate: false) }
        served = true
        started = true
        await withCheckedContinuation { continuation = $0 }
        return (Data(#"{"id":"p","title":"Old title","book_type":"ebook","reading_status":"unread"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
    }
    func download(_ request: URLRequest, to file: URL, onResponse: @escaping @Sendable (HTTPURLResponse) -> Void, onProgress: @escaping @Sendable (Int64) -> Void) async throws -> HTTPURLResponse { throw APIError.protocolError }
}

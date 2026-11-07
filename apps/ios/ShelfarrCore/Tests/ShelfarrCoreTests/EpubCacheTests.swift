import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ShelfarrCore
import XCTest

final class EpubCacheTests: XCTestCase {
    private let transport = FakeTransport()
    private var root: URL!
    private var cache: EpubCache!
    private let bytes = "PK-a-real-epub-would-go-here"

    private var server: ServerAddress {
        guard case let .valid(address) = ServerAddress.parse("https://example.org") else { fatalError() }
        return address
    }

    private func asset(_ id: String = "a1", size: Int64? = nil, url: String = "/content/a1") -> Asset {
        Asset(id: id, format: "epub", sizeBytes: size ?? Int64(bytes.utf8.count), contentUrl: url)
    }

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let server = self.server
        let api = ConsumerAPI(transport: transport, credential: { Credential(server: server, accessToken: "secret") })
        cache = EpubCache(root: root, transport: transport, authorize: { api.authorized($0) })
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testDownloadsWithTheTokenInAHeaderNeverTheURL() async throws {
        transport.enqueue(200, bytes, headers: ["ETag": "\"v1\""])
        let result = try await cache.obtain(accountKey: "acct", server: server, asset: asset())
        XCTAssertEqual(try String(contentsOf: result.file, encoding: .utf8), bytes)
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(transport.requests.first?.url?.absoluteString.contains("secret"), false)
    }

    func testAnUnchangedETagReusesTheCopy() async throws {
        transport.enqueue(200, bytes, headers: ["ETag": "\"v1\""])
        _ = try await cache.obtain(accountKey: "acct", server: server, asset: asset())
        transport.enqueue(304)
        let again = try await cache.obtain(accountKey: "acct", server: server, asset: asset())
        XCTAssertEqual(transport.requests.last?.value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
        XCTAssertFalse(again.unverified)
    }

    func testAChangedETagReplacesTheCopy() async throws {
        transport.enqueue(200, bytes, headers: ["ETag": "\"v1\""])
        _ = try await cache.obtain(accountKey: "acct", server: server, asset: asset())
        let replacement = "PK-the-new-edition-file-bytes"
        transport.enqueue(200, replacement, headers: ["ETag": "\"v2\""])
        let again = try await cache.obtain(accountKey: "acct", server: server, asset: asset(size: Int64(replacement.utf8.count)))
        XCTAssertEqual(try String(contentsOf: again.file, encoding: .utf8), replacement)
    }

    func testOfflineReusesTheCopyAndSaysItCouldNotCheck() async throws {
        transport.enqueue(200, bytes, headers: ["ETag": "\"v1\""])
        _ = try await cache.obtain(accountKey: "acct", server: server, asset: asset())
        transport.replies.append(.failure(APIError.offline(certificate: false)))
        let again = try await cache.obtain(accountKey: "acct", server: server, asset: asset())
        XCTAssertTrue(again.unverified)
    }

    func testAWrongSizeIsThrownAway() async {
        transport.enqueue(200, bytes, headers: ["ETag": "\"v1\""])
        do {
            _ = try await cache.obtain(accountKey: "acct", server: server, asset: asset(size: 999))
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? APIError, .protocolError)
        }
    }

    func testAnHTMLPageIsNotMistakenForABook() async {
        let html = "<html>please sign in</html>"
        transport.enqueue(200, html)
        do {
            _ = try await cache.obtain(accountKey: "acct", server: server, asset: asset(size: Int64(html.utf8.count)))
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? APIError, .protocolError)
        }
    }

    func testRefusesAContentURLOutsideTheServer() async {
        do {
            _ = try await cache.obtain(accountKey: "acct", server: server, asset: asset(url: "https://evil.example.com/a.epub"))
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? APIError, .protocolError)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testResumesAnInterruptedDownloadWithARange() async throws {
        // A first response that wrote part of the file, then failed.
        let half = bytes.utf8.count / 2
        final class Dropping: HTTPTransport, @unchecked Sendable {
            let inner: FakeTransport
            let partial: String
            var dropped = false
            init(_ inner: FakeTransport, _ partial: String) {
                self.inner = inner
                self.partial = partial
            }
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { try await inner.send(request) }
            func download(_ request: URLRequest, to file: URL, onResponse: @escaping @Sendable (HTTPURLResponse) -> Void, onProgress: @escaping @Sendable (Int64) -> Void) async throws -> HTTPURLResponse {
                if !dropped {
                    dropped = true
                    onResponse(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "\"v1\""])!)
                    try Data(partial.utf8).write(to: file)
                    throw APIError.offline(certificate: false)
                }
                return try await inner.download(request, to: file, onResponse: onResponse, onProgress: onProgress)
            }
        }
        let dropping = Dropping(transport, String(bytes.prefix(half)))
        let server = self.server
        let api = ConsumerAPI(transport: dropping, credential: { Credential(server: server, accessToken: "secret") })
        let resuming = EpubCache(root: root, transport: dropping, authorize: { api.authorized($0) })

        do {
            _ = try await resuming.obtain(accountKey: "acct", server: server, asset: asset())
            XCTFail("expected a dropped connection")
        } catch {}

        transport.enqueue(206, String(bytes.dropFirst(half)))
        let result = try await resuming.obtain(accountKey: "acct", server: server, asset: asset())
        XCTAssertEqual(transport.requests.last?.value(forHTTPHeaderField: "Range"), "bytes=\(half)-")
        XCTAssertEqual(transport.requests.last?.value(forHTTPHeaderField: "If-Range"), "\"v1\"")
        XCTAssertEqual(try String(contentsOf: result.file, encoding: .utf8), bytes)
    }

    func testAccountsNeverShareACopyAndClearAlone() async throws {
        transport.enqueue(200, bytes, headers: ["ETag": "\"v1\""])
        let first = try await cache.obtain(accountKey: "one", server: server, asset: asset())
        transport.enqueue(200, bytes, headers: ["ETag": "\"v1\""])
        let second = try await cache.obtain(accountKey: "two", server: server, asset: asset())
        XCTAssertNotEqual(first.file, second.file)
        await cache.clear(accountKey: "one")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.file.path))
    }
}

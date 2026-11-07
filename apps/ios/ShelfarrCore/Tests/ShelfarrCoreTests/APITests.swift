import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ShelfarrCore
import XCTest

final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: String = ""
        var headers: [String: String] = [:]
    }

    var replies: [Result<Reply, Error>] = []
    var requests: [URLRequest] = []
    var beforeResponse: (@Sendable () -> Void)?

    func enqueue(_ status: Int, _ body: String = "", headers: [String: String] = [:]) {
        replies.append(.success(Reply(status: status, body: body, headers: headers)))
    }

    func next(_ request: URLRequest) throws -> Reply {
        requests.append(request)
        return try replies.removeFirst().get()
    }

    func http(_ request: URLRequest, _ reply: Reply) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = try next(request)
        beforeResponse?()
        return (Data(reply.body.utf8), http(request, reply))
    }

    func download(_ request: URLRequest, to file: URL, onResponse: @escaping @Sendable (HTTPURLResponse) -> Void, onProgress: @escaping @Sendable (Int64) -> Void) async throws -> HTTPURLResponse {
        let reply = try next(request)
        onResponse(http(request, reply))
        if reply.status == 200 {
            try Data(reply.body.utf8).write(to: file)
        } else if reply.status == 206 {
            let handle = try FileHandle(forWritingTo: file)
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: Data(reply.body.utf8))
            try handle.close()
        }
        return http(request, reply)
    }
}

final class APITests: XCTestCase {
    private let transport = FakeTransport()
    private var rejected: [Credential] = []

    private var server: ServerAddress {
        guard case let .valid(address) = ServerAddress.parse("https://example.org/s") else { fatalError() }
        return address
    }

    private var api: ConsumerAPI {
        let server = self.server
        return ConsumerAPI(transport: transport, credential: { Credential(server: server, accessToken: "token") }) { _ in }
    }

    func testLibrarySendsStatusAndSortAndContinueAsksForRecentActivity() async throws {
        transport.enqueue(200, #"{"items":[],"next_cursor":null}"#)
        _ = try await api.library(server: server, query: LibraryQuery(filter: .ebook, text: "dune", status: .inProgress, sort: .title), cursor: "c2")
        let query = try XCTUnwrap(transport.requests.last?.url?.query)
        for part in ["type=ebook", "q=dune", "status=in_progress", "sort=title", "cursor=c2"] {
            XCTAssertTrue(query.contains(part), part)
        }
        transport.enqueue(200, #"{"items":[],"next_cursor":null}"#)
        _ = try await api.library(server: server, query: LibraryQuery())
        let defaults = try XCTUnwrap(transport.requests.last?.url?.query)
        XCTAssertFalse(defaults.contains("status="))
        XCTAssertFalse(defaults.contains("sort="))

        transport.enqueue(200, #"{"items":[{"id":"deep","title":"Page nine","book_type":"audiobook","reading_status":"in_progress"}]}"#)
        let recent = try await api.continueReading(server: server, limit: 10)
        XCTAssertEqual(recent.map(\.id), ["deep"])
        let url = try XCTUnwrap(transport.requests.last?.url)
        XCTAssertEqual(url.path, "/s/api/consumer/v1/continue")
        XCTAssertEqual(url.query, "limit=10")
    }

    func testSettingAStatusPutsItAndReturnsThePublication() async throws {
        transport.enqueue(200, #"{"id":"p/1","title":"T","book_type":"ebook","reading_status":"finished"}"#)
        let updated = try await api.setReadingStatus(server: server, publicationId: "p/1", status: .finished)
        XCTAssertEqual(updated.status, .finished)
        let request = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertTrue(request.url!.absoluteString.hasSuffix("/library/p%2F1/reading_status"))
        XCTAssertEqual(request.httpBody, Data(#"{"status":"finished"}"#.utf8))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
    }

    func testDecodesThePublicationContractAndIgnoresUnknownFields() async throws {
        transport.enqueue(200, """
        {"items":[{"id":"p1","title":"T","author":"A","description":null,"book_type":"audiobook","cover_url":null,"future":{"a":1},
        "assets":[{"id":"a2","filename":"2.mp3","media_type":"audio/mpeg","format":"mp3","size_bytes":10,"content_url":"/c/2","position":2},
                  {"id":"a1","filename":"1.mp3","media_type":"audio/mpeg","format":"mp3","size_bytes":10,"content_url":"/c/1","position":1}],
        "progress":{"asset_id":"a1","locator":null,"position_seconds":12.5,"version":3,"updated_at":"2026-11-07T10:00:00Z","client_mutation_id":"m"}}],
        "next_cursor":"opaque"}
        """)
        let page = try await api.library(server: server, filter: .audiobook, query: "dune", cursor: "c1")
        XCTAssertEqual(page.nextCursor, "opaque")
        let publication = try XCTUnwrap(page.items.first)
        XCTAssertEqual(publication.audioAssets.map(\.id), ["a1", "a2"])
        XCTAssertEqual(publication.progress?.positionSeconds, 12.5)
        XCTAssertNil(publication.progress?.locator)

        let query = try XCTUnwrap(transport.requests.first?.url?.query)
        XCTAssertTrue(query.contains("type=audiobook"))
        XCTAssertTrue(query.contains("q=dune"))
        XCTAssertTrue(query.contains("cursor=c1"))
        XCTAssertTrue(query.contains("limit=30"))
    }

    func testAttachesTheTokenOnlyInScope() {
        XCTAssertEqual(api.authorized(server.api("me")).value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertNil(api.authorized(URL(string: "https://example.org/other")!).value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(api.authorized(URL(string: "https://cdn.example.com/s/1.jpg")!).value(forHTTPHeaderField: "Authorization"))
    }

    func testProgressUpdatesAreSnakeCase() async throws {
        transport.enqueue(200, #"{"progress":{"asset_id":"a","position_seconds":5.0,"version":1,"client_mutation_id":"m"}}"#)
        _ = try await api.saveProgress(
            server: server,
            publicationId: "p",
            update: ProgressUpdate(assetId: "a", locator: nil, positionSeconds: 5, expectedVersion: 0, clientMutationId: "m")
        )
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        let body = try XCTUnwrap(JSONValue.parse(jsonString: String(decoding: request.httpBody ?? Data(), as: UTF8.self)))
        XCTAssertEqual(body["asset_id"], .string("a"))
        XCTAssertEqual(body["expected_version"], .number(0))
        XCTAssertEqual(body["client_mutation_id"], .string("m"))
    }

    func testErrorsAreTyped() async {
        for (status, expected) in [(401, APIError.unauthorized), (403, .forbidden), (404, .notFound), (503, .server(503))] {
            transport.enqueue(status, "{}")
            do {
                _ = try await api.me(server: server)
                XCTFail("expected failure")
            } catch {
                XCTAssertEqual(error as? APIError, expected)
            }
        }
    }

    func testA401ReportsTheRejectedCredential() async {
        final class Box: @unchecked Sendable { var count = 0 }
        let box = Box()
        let server = self.server
        let client = ConsumerAPI(transport: transport, credential: { Credential(server: server, accessToken: "t") }) { _ in box.count += 1 }
        transport.enqueue(401)
        _ = try? await client.me(server: server)
        XCTAssertEqual(box.count, 1)
    }

    func testLate401CannotExpireTheReplacementCredential() async {
        final class Box: @unchecked Sendable { var token = "old"; var rejected = 0 }
        let box = Box(), server = self.server
        let client = ConsumerAPI(transport: transport, credential: { Credential(server: server, accessToken: box.token) }) { _ in box.rejected += 1 }
        transport.beforeResponse = { box.token = "new" }
        transport.enqueue(401)
        _ = try? await client.me(server: server)
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer old")
        XCTAssertEqual(box.rejected, 0)
    }

    func testConflictCarriesCurrentProgress() async {
        transport.enqueue(409, #"{"error":"progress_conflict","progress":{"asset_id":"a","position_seconds":9,"version":7,"client_mutation_id":"x"}}"#)
        do {
            _ = try await api.saveProgress(
                server: server,
                publicationId: "p",
                update: ProgressUpdate(assetId: "a", locator: nil, positionSeconds: 1, expectedVersion: 1, clientMutationId: "m")
            )
            XCTFail("expected conflict")
        } catch let APIError.progressConflict(progress) {
            XCTAssertEqual(progress?.version, 7)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testHTMLFromAProxyIsAProtocolError() async {
        transport.enqueue(200, "<html>sign in</html>")
        do {
            _ = try await api.me(server: server)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? APIError, .protocolError)
        }
    }

    func testByteRangesAreAuthenticatedHeadersNotQueryParameters() async throws {
        transport.enqueue(206, "abc", headers: ["Content-Range": "bytes 0-2/10"])
        let (data, _) = try await api.bytes(at: server.api("assets/1/content"), range: 0 ... 2)
        XCTAssertEqual(data.count, 3)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertNil(request.url?.query)
    }

    func testLocatorRoundTripsThroughJSONValue() throws {
        let json = #"{"href":"c.xhtml","locations":{"position":3,"progression":0.25,"totalProgression":0.5},"title":"One","type":"application/xhtml+xml"}"#
        let value = try XCTUnwrap(JSONValue.parse(jsonString: json))
        XCTAssertEqual(value["locations"]?["totalProgression"]?.doubleValue, 0.5)
        XCTAssertEqual(JSONValue.parse(jsonString: try XCTUnwrap(value.jsonString())), value)
    }
}

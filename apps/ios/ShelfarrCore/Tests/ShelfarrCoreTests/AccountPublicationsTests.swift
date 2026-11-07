import Foundation
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
}

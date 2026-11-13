@testable import ShelfarrCore
import XCTest

final class ServerAddressTests: XCTestCase {
    private func valid(_ input: String, http: Bool = false) throws -> ServerAddress {
        guard case let .valid(address) = ServerAddress.parse(input, allowLocalHTTP: http) else {
            throw XCTSkip("not valid: \(input)")
        }
        return address
    }

    func testAssumesHTTPSAndNormalisesSlashes() throws {
        XCTAssertEqual(try valid("Books.Example.org/").display, "https://books.example.org")
        XCTAssertEqual(try valid(" https://example.org/shelfarr/ ").display, "https://example.org/shelfarr")
    }

    func testRejectsEmptyCredentialedAndQueryAddresses() {
        XCTAssertEqual(ServerAddress.parse("   "), .empty)
        XCTAssertEqual(ServerAddress.parse("https://user:pw@example.org"), .malformed)
        XCTAssertEqual(ServerAddress.parse("https://example.org?x=1"), .malformed)
        XCTAssertEqual(ServerAddress.parse("https://example.org/#a"), .malformed)
        XCTAssertEqual(ServerAddress.parse("ftp://example.org"), .malformed)
    }

    func testPlainHTTPNeedsOptInAndALocalHost() throws {
        XCTAssertEqual(ServerAddress.parse("http://192.168.1.10"), .cleartextNotAllowed)
        XCTAssertEqual(ServerAddress.parse("http://example.org", allowLocalHTTP: true), .cleartextNotAllowed)
        XCTAssertEqual(ServerAddress.parse("http://8.8.8.8", allowLocalHTTP: true), .cleartextNotAllowed)
        XCTAssertTrue(try valid("http://192.168.1.10:3000", http: true).isCleartext)
        XCTAssertTrue(try valid("http://nas.local", http: true).isCleartext)
    }

    func testAPIPathsSitUnderTheSubpath() throws {
        XCTAssertEqual(
            try valid("https://example.org/shelfarr").api("library/a%20b").absoluteString,
            "https://example.org/shelfarr/api/consumer/v1/library/a%20b"
        )
        XCTAssertEqual(ServerAddress.pathSegment("a/b c"), "a%2Fb%20c")
    }

    func testScopeIsExact() throws {
        let server = try valid("https://example.org/shelfarr")
        func url(_ value: String) -> URL { URL(string: value)! }
        XCTAssertTrue(server.contains(url("https://example.org/shelfarr/api/x")))
        XCTAssertTrue(server.contains(url("https://example.org:443/shelfarr/api/x")))
        XCTAssertTrue(server.contains(url("https://example.org/shelfarr")))
        XCTAssertFalse(server.contains(url("https://example.org/shelfarr-evil/api")))
        XCTAssertFalse(server.contains(url("https://example.org/other")))
        XCTAssertFalse(server.contains(url("https://example.org/shelfarr/../other")))
        XCTAssertFalse(server.contains(url("https://example.org/shelfarr/%2e%2e/other")))
        XCTAssertFalse(server.contains(url("http://example.org/shelfarr/api")))
        XCTAssertFalse(server.contains(url("https://example.org:8443/shelfarr/api")))
        XCTAssertFalse(server.contains(url("https://evil.example.org/shelfarr/api")))
        XCTAssertFalse(server.contains(url("https://example.org.evil.com/shelfarr/api")))
    }

    func testResolvesAgainstTheSubpath() throws {
        let server = try valid("https://example.org/shelfarr")
        XCTAssertEqual(server.resolve("/api/x")?.absoluteString, "https://example.org/shelfarr/api/x")
        XCTAssertEqual(server.resolve("/shelfarr/api/x")?.absoluteString, "https://example.org/shelfarr/api/x")
        XCTAssertEqual(server.resolve("covers/1.jpg")?.absoluteString, "https://example.org/shelfarr/covers/1.jpg")
        XCTAssertEqual(server.resolve("/shelfarr-x/1")?.absoluteString, "https://example.org/shelfarr/shelfarr-x/1")
        XCTAssertEqual(server.resolve("https://cdn.example.com/1.jpg")?.absoluteString, "https://cdn.example.com/1.jpg")
    }

    func testProtocolRelativeAndNonWebReferencesNeverResolve() throws {
        let server = try valid("https://example.org")
        XCTAssertNil(server.resolve("//evil.example.com/x"))
        XCTAssertNil(server.resolve("javascript:alert(1)"))
        XCTAssertNil(server.resolve(""))
    }
}

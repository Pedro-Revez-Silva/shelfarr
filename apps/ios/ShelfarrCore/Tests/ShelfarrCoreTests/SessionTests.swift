@testable import ShelfarrCore
import XCTest

private final class MemorySecrets: SecretStore, @unchecked Sendable {
    var values: [String: Data] = [:]
    func read(_ name: String) -> Data? { values[name] }
    func write(_ name: String, _ value: Data) { values[name] = value }
    func delete(_ name: String) { values[name] = nil }
}

final class SessionTests: XCTestCase {
    private let server: ServerAddress = {
        guard case let .valid(address) = ServerAddress.parse("https://example.org/s") else { fatalError() }
        return address
    }()

    private var account: Session { Session(server: server, user: Me(id: "u1", name: "Ada", username: "ada"), accessToken: "token") }

    func testSHA256KnownVector() {
        XCTAssertEqual(
            SHA256.hexDigest(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            SHA256.hexDigest(Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func testSessionsSurviveARestart() {
        let store = MemorySecrets()
        SessionManager(store: store).signIn(account)
        XCTAssertEqual(SessionManager(store: store).credential()?.accessToken, "token")
    }

    func testExpiredForgetsTheTokenButKeepsTheServer() {
        let store = MemorySecrets()
        let sessions = SessionManager(store: store)
        sessions.signIn(account)
        sessions.markExpired(Credential(server: server, accessToken: "token"))
        XCTAssertNil(sessions.credential())
        guard case let .expired(saved, _) = SessionManager(store: store).state else { return XCTFail("not expired") }
        XCTAssertEqual(saved, server)
    }

    func testALate401ForAnOldTokenCannotSignOutANewerSession() {
        let sessions = SessionManager(store: MemorySecrets())
        sessions.signIn(account)
        sessions.markExpired(Credential(server: server, accessToken: "older"))
        XCTAssertNotNil(sessions.signedIn)
    }

    func testClearingRemovesEverySecret() {
        let store = MemorySecrets()
        let sessions = SessionManager(store: store)
        sessions.signIn(account)
        sessions.savePendingAuthorization(PendingAuthorization(
            server: server,
            grant: DeviceGrant(deviceCode: "d", userCode: "c", verificationUri: "/v", verificationUriComplete: "/v", expiresIn: 600),
            expiresAt: .distantFuture
        ))
        sessions.clear()
        XCTAssertTrue(store.values.isEmpty)
        XCTAssertEqual(sessions.state, .signedOut)
    }

    func testAProvisionalTokenIsNeverStored() {
        let store = MemorySecrets()
        let sessions = SessionManager(store: store)
        sessions.useProvisional(Credential(server: server, accessToken: "fresh"))
        XCTAssertEqual(sessions.credential()?.accessToken, "fresh")
        XCTAssertTrue(store.values.isEmpty)
    }

    func testAccountKeysDifferByUserAndServer() {
        guard case let .valid(other) = ServerAddress.parse("https://example.org/t") else { return XCTFail() }
        XCTAssertNotEqual(Session.accountKey(server: server, userId: "1"), Session.accountKey(server: server, userId: "2"))
        XCTAssertNotEqual(Session.accountKey(server: server, userId: "1"), Session.accountKey(server: other, userId: "1"))
    }

    func testSecretsStayOutOfDescriptions() {
        let grant = DeviceGrant(deviceCode: "secret", userCode: "ABCD", verificationUri: "u", verificationUriComplete: "c", expiresIn: 600)
        XCTAssertFalse(grant.description.contains("secret"))
        XCTAssertFalse(account.description.contains("token"))
        XCTAssertFalse(Credential(server: server, accessToken: "secret").description.contains("secret"))
    }

    private func pending(expires: Date = .distantFuture, interval: Int = 5) -> PendingAuthorization {
        PendingAuthorization(
            server: server,
            grant: DeviceGrant(deviceCode: "d", userCode: "c", verificationUri: "/v", verificationUriComplete: "/v", expiresIn: 600, interval: interval),
            expiresAt: expires
        )
    }

    private final class Script: @unchecked Sendable {
        var responses: [Result<TokenResponse, Error>]
        var calls = 0
        var sleeps: [UInt64] = []
        init(_ responses: [Result<TokenResponse, Error>]) { self.responses = responses }
    }

    private func authorizer(_ script: Script, now: @escaping @Sendable () -> Date = { Date() }) -> DeviceAuthorizer {
        DeviceAuthorizer(
            exchange: { _, _ in
                script.calls += 1
                return try script.responses.removeFirst().get()
            },
            now: now,
            sleep: { script.sleeps.append($0) }
        )
    }

    private let token = TokenResponse(accessToken: "t", tokenType: "Bearer", scope: nil, expiresIn: nil)

    func testPollsUntilApproved() async throws {
        let script = Script([.failure(APIError.authorization("authorization_pending")), .success(token)])
        let outcome = try await authorizer(script).await(pending())
        XCTAssertEqual(outcome, .approved(token))
        XCTAssertEqual(script.calls, 2)
    }

    func testSlowDownLengthensTheInterval() async throws {
        let script = Script([.failure(APIError.authorization("slow_down")), .success(token)])
        _ = try await authorizer(script).await(pending())
        XCTAssertEqual(script.sleeps.map { $0 / 1_000_000_000 }, [5, 10])
    }

    func testDenialAndExpiryStop() async throws {
        let denied = Script([.failure(APIError.authorization("access_denied"))])
        let result = try await authorizer(denied).await(pending())
        XCTAssertEqual(result, .denied)
        let expired = Script([.failure(APIError.authorization("expired_token"))])
        let other = try await authorizer(expired).await(pending())
        XCTAssertEqual(other, .expired)
    }

    func testStopsAtLocalExpiryWithoutARequest() async throws {
        let script = Script([])
        let result = try await authorizer(script, now: { Date(timeIntervalSince1970: 10) }).await(pending(expires: Date(timeIntervalSince1970: 5)))
        XCTAssertEqual(result, .expired)
        XCTAssertEqual(script.calls, 0)
    }

    func testAServerHiccupDoesNotLoseTheAttempt() async throws {
        let script = Script([.failure(APIError.server(503)), .success(token)])
        let result = try await authorizer(script).await(pending())
        XCTAssertEqual(result, .approved(token))
    }
}

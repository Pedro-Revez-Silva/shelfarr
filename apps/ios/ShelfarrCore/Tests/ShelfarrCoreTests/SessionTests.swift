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

    func testAccountKeysKeepCaseSensitiveSubpathsSeparate() {
        guard case let .valid(lower) = ServerAddress.parse("https://example.org/shelfarr"),
              case let .valid(upper) = ServerAddress.parse("https://EXAMPLE.org/Shelfarr") else { return XCTFail() }
        XCTAssertNotEqual(Session.accountKey(server: lower, userId: "1"), Session.accountKey(server: upper, userId: "1"))
    }

    func testProgressRemoteCannotBorrowTheNextAccountsCredential() async throws {
        let sessions = SessionManager(store: MemorySecrets()), transport = FakeTransport()
        sessions.signIn(account)
        let remote = SessionProgressRemote.bind(session: account, sessions: sessions, transport: transport)
        let update = ProgressUpdate(assetId: "a", locator: nil, positionSeconds: 2, expectedVersion: 0, clientMutationId: "m")
        transport.enqueue(503)
        _ = try? await remote("p", update)
        sessions.signIn(Session(server: server, user: Me(id: "bob"), accessToken: "bob-token"))
        do { _ = try await remote("p", update); XCTFail("old account must stop") }
        catch { XCTAssertEqual(error as? APIError, .unauthorized) }
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer token")
    }

    func testAHandoverContinuesTheSignInAndNothingElseDoes() {
        let sessions = SessionManager(store: MemorySecrets())
        sessions.signIn(account)
        XCTAssertEqual(sessions.continuing(account), account)
        let upgraded = Session(server: server, user: account.user, accessToken: "upgraded", grantedScopes: RequestScopes.base + RequestScopes.requesting)
        XCTAssertTrue(sessions.replaceToken(expected: account, upgraded: upgraded))
        XCTAssertEqual(sessions.continuing(account), upgraded, "work bound to the first token follows the handover")
        XCTAssertEqual(sessions.continuing(upgraded), upgraded)
        sessions.refreshUser(Me(id: "u1", name: "Ada L.", username: "ada"), expected: upgraded)
        XCTAssertEqual(sessions.continuing(account)?.user.name, "Ada L.", "fresher details continue it too")

        // Another account never continues it, even holding a token string this sign-in once used.
        XCTAssertNil(sessions.continuing(Session(server: server, user: Me(id: "bob"), accessToken: "token")))

        // Signing in again, even as the same account, is a new sign-in.
        sessions.signIn(Session(server: server, user: account.user, accessToken: "again"))
        XCTAssertNil(sessions.continuing(account))
        XCTAssertNil(sessions.continuing(upgraded))
    }

    func testExpiryAndSignOutEndTheSignInEvenAfterAHandover() {
        let sessions = SessionManager(store: MemorySecrets())
        sessions.signIn(account)
        let upgraded = Session(server: server, user: account.user, accessToken: "upgraded")
        XCTAssertTrue(sessions.replaceToken(expected: account, upgraded: upgraded))
        sessions.markExpired(Credential(server: server, accessToken: "upgraded"))
        XCTAssertNil(sessions.continuing(account))
        XCTAssertNil(sessions.continuing(upgraded))

        sessions.signIn(account)
        XCTAssertFalse(sessions.replaceToken(expected: upgraded, upgraded: upgraded), "a handover needs the live token")
        sessions.clear()
        XCTAssertNil(sessions.continuing(account))
        // A relaunch starts with the stored token only.
        let store = MemorySecrets()
        let first = SessionManager(store: store)
        first.signIn(account)
        XCTAssertTrue(first.replaceToken(expected: account, upgraded: upgraded))
        let relaunched = SessionManager(store: store)
        XCTAssertEqual(relaunched.continuing(upgraded), upgraded)
        XCTAssertNil(relaunched.continuing(account))
    }

    func testProgressRemoteFollowsAHandoverAndResendsTheWriteItInterrupted() async throws {
        let sessions = SessionManager(store: MemorySecrets()), transport = FakeTransport()
        let account = self.account
        sessions.signIn(account)
        let remote = SessionProgressRemote.bind(session: account, sessions: sessions, transport: transport)
        let update = ProgressUpdate(assetId: "a", locator: nil, positionSeconds: 2, expectedVersion: 0, clientMutationId: "m")
        let upgraded = Session(server: server, user: account.user, accessToken: "upgraded")
        let accepted = #"{"progress":{"asset_id":"a","position_seconds":2,"version":1,"client_mutation_id":"m"}}"#
        // Requesting is added while the write is out, and the server has already retired the old token.
        transport.beforeResponse = { _ = sessions.replaceToken(expected: account, upgraded: upgraded) }
        transport.enqueue(401)
        transport.enqueue(200, accepted)
        let saved = try await remote("p", update)
        XCTAssertEqual(saved.version, 1)
        XCTAssertEqual(transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer token", "Bearer upgraded"])
        XCTAssertEqual(sessions.signedIn, upgraded, "the old token's refusal doesn't sign out")

        transport.beforeResponse = nil
        transport.enqueue(200, accepted)
        _ = try await remote("p", update)
        XCTAssertEqual(transport.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer upgraded")

        // The new token refused: that one ends the sign-in, and the remote stops.
        transport.enqueue(401)
        do { _ = try await remote("p", update); XCTFail("a refused live token must fail") }
        catch { XCTAssertEqual(error as? APIError, .unauthorized) }
        XCTAssertEqual(transport.requests.count, 4, "a refusal of the token in use is not replayed")
        XCTAssertNil(sessions.signedIn)
        do { _ = try await remote("p", update); XCTFail("an ended sign-in must stop") }
        catch { XCTAssertEqual(error as? APIError, .unauthorized) }
        XCTAssertEqual(transport.requests.count, 4)
    }

    func testABindingSignsOutOnlyForARefusalOfTheTokenInUse() {
        let sessions = SessionManager(store: MemorySecrets())
        sessions.signIn(account)
        let binding = SignInBinding(session: account, sessions: sessions)
        let oldTag = binding.credentialTag
        let upgraded = Session(server: server, user: account.user, accessToken: "upgraded")
        XCTAssertTrue(sessions.replaceToken(expected: account, upgraded: upgraded))
        XCTAssertEqual(binding.credential, Credential(server: server, accessToken: "upgraded"))
        XCTAssertNotEqual(binding.credentialTag, oldTag)
        binding.refused(oldTag)
        XCTAssertEqual(sessions.signedIn, upgraded, "an answer about the replaced token changes nothing")
        binding.refused(binding.credentialTag)
        XCTAssertNil(sessions.signedIn)
        XCTAssertFalse(binding.isLive)
        XCTAssertNil(binding.credential)
        XCTAssertEqual(binding.credentialTag, "")
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

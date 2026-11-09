import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ShelfarrCore
import XCTest

private final class Secrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ name: String) -> Data? { lock.withLock { values[name] } }
    func write(_ name: String, _ value: Data) { lock.withLock { values[name] = value } }
    func delete(_ name: String) { _ = lock.withLock { values.removeValue(forKey: name) } }
}

@MainActor
extension HandoverTests {
    func testRetriesIssuedHandoverAfterLostConfirmation() async throws {
        let harness = Harness()
        let before = harness.signIn()
        harness.server.meDrops = true
        _ = await harness.requesting.start(before)
        await harness.requesting.settle()
        XCTAssertTrue(harness.sessions.hasPendingHandover(for: before))
        let count = harness.server.seen.filter { $0.path == "me" }.count
        harness.server.meDrops = false
        _ = await harness.requesting.start(before)
        await harness.requesting.settle()
        XCTAssertGreaterThan(harness.server.seen.filter { $0.path == "me" }.count, count)
        XCTAssertTrue(harness.sessions.signedIn!.canRequest)
        XCTAssertFalse(harness.sessions.hasPendingHandover(for: before))
        XCTAssertEqual(harness.requesting.state, .allowed)
    }
}

/// Holds requests until the test lets them go.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0

    func pass() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let go = lock.withLock { () -> Bool in
                arrivals += 1
                if open { return true }
                waiting.append(continuation)
                return false
            }
            if go { continuation.resume() }
        }
    }

    func release() {
        let released = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            open = true
            defer { waiting = [] }
            return waiting
        }
        released.forEach { $0.resume() }
    }
}

/// The server's credential model for adding a permission in place (app/models/api_token.rb,
/// `ConsumerDeviceGrant`), as an in-memory transport with synthetic tokens:
///
/// * a device approval started with a bearer replaces that bearer, and exchanging its code
///   issues the replacement in the same connection while the old token keeps working;
/// * the first request authenticated with the replacement retires the token it replaces
///   *before* the request is handled or answered, so a lost or slow answer still retires it;
/// * revoking any token revokes its whole connection, replacement included.
final class RetiringServer: HTTPTransport, @unchecked Sendable {
    struct Token {
        var user: String
        var scopes: [String]
        var replaces: String?
        var revoked = false
        let connection: Int
    }

    struct Seen: Equatable {
        let method: String
        let path: String
        let bearer: String?
        let body: Data?
        let status: Int
    }

    private let lock = NSLock()
    private var tokens: [String: Token] = [:]
    private var devices: [String: String?] = [:]
    private var counter = 0
    private var log: [Seen] = []
    /// `/me` waits here after it has authenticated, so the old token is already retired.
    var meGate: Gate?
    /// `/me` waits here before it is authenticated: nothing is retired yet.
    var holdMe: Gate?
    /// `/me` fails like a dropped connection after it has authenticated.
    var meDrops = false
    /// The replacement is issued to this user instead, as a server bug would.
    var approvesAs: String?

    func issue(user: String = "u1", scopes: [String] = RequestScopes.base) -> String {
        lock.withLock {
            counter += 1
            let token = "synthetic-\(counter)"
            tokens[token] = Token(user: user, scopes: scopes, connection: counter)
            return token
        }
    }

    func isUsable(_ token: String) -> Bool { lock.withLock { tokens[token].map { !$0.revoked } ?? false } }
    var seen: [Seen] { lock.withLock { log } }
    func refusals(_ path: String, of token: String) -> Int {
        seen.filter { $0.status == 401 && $0.path == path && $0.bearer == token }.count
    }

    func revokeConnection(of token: String) {
        lock.withLock {
            guard let connection = tokens[token]?.connection else { return }
            for (key, value) in tokens where value.connection == connection { tokens[key]?.revoked = true }
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path.replacingOccurrences(of: "/s/api/consumer/v1/", with: "")
        let bearer = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
        let method = request.httpMethod ?? "GET"
        if path == "me", let held = holdMe { await held.pass() }
        var (status, body) = lock.withLock { prepare(method, path, bearer, request) }
        if status == 0 {
            // Authenticated `/me`: the replaced token is gone before anything is answered.
            if let gate = meGate { await gate.pass() }
            if meDrops {
                record(method, path, bearer, request, status: -1)
                throw APIError.offline(certificate: false)
            }
            (status, body) = lock.withLock {
                let owner = tokens[bearer!]!
                let scopes = owner.scopes.map { "\"\($0)\"" }.joined(separator: ",")
                return (200, #"{"id":"\#(owner.user)","name":"Ada","scopes":[\#(scopes)]}"#)
            }
        }
        record(method, path, bearer, request, status: status)
        var headers: [String: String] = [:]
        if status == 206 { headers["Content-Range"] = "bytes 0-3/10" }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }

    func download(_ request: URLRequest, to file: URL, onResponse: @escaping @Sendable (HTTPURLResponse) -> Void, onProgress: @escaping @Sendable (Int64) -> Void) async throws -> HTTPURLResponse {
        throw APIError.protocolError
    }

    private func record(_ method: String, _ path: String, _ bearer: String?, _ request: URLRequest, status: Int) {
        lock.withLock { log.append(Seen(method: method, path: path, bearer: bearer, body: request.httpBody, status: status)) }
    }

    /// `APIToken.authenticate`: usable, then retire what it replaces. Caller holds `lock`.
    private func authenticate(_ bearer: String?) -> Token? {
        guard let bearer, var token = tokens[bearer], !token.revoked else { return nil }
        if let previous = token.replaces {
            guard tokens[previous]?.revoked == false else { return nil }
            tokens[previous]?.revoked = true
            token.replaces = nil
            tokens[bearer] = token
        }
        return token
    }

    /// Status and body, or status 0 for an authenticated `/me`. Caller holds `lock`.
    private func prepare(_ method: String, _ path: String, _ bearer: String?, _ request: URLRequest) -> (Int, String) {
        if path == "auth/device" {
            var replaces: String?
            if let bearer {
                guard authenticate(bearer) != nil else { return (401, "{}") }
                replaces = bearer
            }
            counter += 1
            devices["dev-\(counter)"] = replaces
            return (200, #"{"device_code":"dev-\#(counter)","user_code":"ABCD-EFGH","verification_uri":"/s/consumer/connect","verification_uri_complete":"/s/consumer/connect?user_code=ABCD-EFGH","expires_in":600,"interval":1}"#)
        }
        if path == "auth/token" {
            let code = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:])["device_code"] ?? ""
            guard let entry = devices.removeValue(forKey: code) else { return (400, #"{"error":"expired_token"}"#) }
            guard let replaces = entry, let previous = tokens[replaces], !previous.revoked else { return (400, #"{"error":"expired_token"}"#) }
            counter += 1
            let token = "synthetic-\(counter)"
            let scopes = RequestScopes.base + RequestScopes.requesting
            // Exchange alone leaves the old token working: a lost token response costs nothing.
            tokens[token] = Token(user: approvesAs ?? previous.user, scopes: scopes, replaces: replaces, connection: previous.connection)
            return (200, #"{"access_token":"\#(token)","token_type":"Bearer","scope":"\#(scopes.joined(separator: " "))","expires_in":2592000}"#)
        }
        guard authenticate(bearer) != nil else { return (401, "{}") }
        switch (method, path) {
        case (_, "me"):
            return (0, "")
        case ("POST", "auth/revoke"):
            let connection = tokens[bearer!]!.connection
            for (key, value) in tokens where value.connection == connection { tokens[key]?.revoked = true }
            return (204, "")
        case ("PUT", _) where path.hasSuffix("/progress"):
            let fields = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let version = (fields["expected_version"] as? Int ?? 0) + 1
            let asset = fields["asset_id"] as? String ?? ""
            let seconds = fields["position_seconds"] as? Double ?? 0
            let mutation = fields["client_mutation_id"] as? String ?? ""
            return (200, #"{"progress":{"asset_id":"\#(asset)","position_seconds":\#(seconds),"version":\#(version),"client_mutation_id":"\#(mutation)"}}"#)
        case ("GET", "assets/a1/content"):
            return (206, "ABCD")
        default:
            return (404, #"{"error":"not_found"}"#)
        }
    }
}

@MainActor
private final class Harness {
    let server = RetiringServer()
    let store: SecretStore
    var sessions: SessionManager
    var requesting: RequestingAccess
    let address: ServerAddress = {
        guard case let .valid(address) = ServerAddress.parse("https://example.org/s") else { fatalError() }
        return address
    }()

    init(store: SecretStore = Secrets()) {
        self.store = store
        sessions = SessionManager(store: store)
        requesting = Self.requesting(sessions, server)
    }

    /// The app's wiring: the signed-in API ends a session it sees refused; `apiFor` never does.
    static func requesting(_ sessions: SessionManager, _ server: RetiringServer) -> RequestingAccess {
        let api = ConsumerAPI(transport: server, credential: { sessions.credential() }, onRejected: { sessions.markExpired($0) })
        return RequestingAccess(
            backend: RequestingBackend(
                sessions: sessions,
                api: api,
                apiFor: { credential in ConsumerAPI(transport: server, credential: { credential }) },
                sleep: { _ in await Task.yield() }
            ),
            clientName: "Shelfarr iPhone"
        )
    }

    /// A new process over the same Keychain and server, wired as `AppModel` does.
    func relaunch() {
        sessions = SessionManager(store: store)
        let server = self.server
        sessions.useCandidateCheck { credential in
            try await ConsumerAPI(transport: server, credential: { credential }).me(server: credential.server)
        }
        requesting = Self.requesting(sessions, server)
    }

    func signIn(user: String = "u1") -> Session {
        let session = Session(server: address, user: Me(id: user, name: "Ada", scopes: RequestScopes.base),
                              accessToken: server.issue(user: user), grantedScopes: RequestScopes.base)
        sessions.signIn(session)
        return session
    }

    func bound(_ session: Session) -> ConsumerAPI {
        SignInBinding(session: session, sessions: sessions).api(transport: server)
    }

    var stream: URL { address.api("assets/a1/content") }

    /// Starts adding requesting and returns once the server has retired `before`'s token
    /// while it holds back its answer to the replacement's first request.
    func startHandover(_ before: Session) async throws {
        server.meGate = Gate()
        _ = await requesting.start(before)
        try await until("the replacement's first request retired the old token") { !self.server.isUsable(before.accessToken) }
    }
}

@MainActor
private func until(_ what: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () async -> Bool) async throws {
    for _ in 0 ..< 5_000 {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("timed out waiting for \(what)", file: file, line: line)
    throw CancellationError()
}

/// The old token is refused from the moment the server first authenticates its replacement,
/// before the app has read that answer. Work already running must follow the sign-in over.
@MainActor
final class HandoverTests: XCTestCase {
    func testAStreamRefusedBeforeTheNewTokenIsConfirmedContinuesWithIt() async throws {
        let harness = Harness()
        let before = harness.signIn()
        let bound = harness.bound(before)
        try await harness.startHandover(before)
        XCTAssertEqual(harness.sessions.signedIn?.accessToken, before.accessToken, "nothing is adopted before the server answers")

        let stream = harness.stream
        let playing = Task { try await bound.bytes(at: stream, range: 0 ... 3) }
        try await until("the old token's refusal") { harness.server.refusals("assets/a1/content", of: before.accessToken) == 1 }
        XCTAssertNotNil(harness.sessions.signedIn, "the refusal waits for the replacement instead of signing out")

        harness.server.meGate?.release()
        let (data, response) = try await playing.value
        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(data, Data("ABCD".utf8))
        await harness.requesting.settle()
        XCTAssertEqual(harness.requesting.state, .allowed)
        let after = try XCTUnwrap(harness.sessions.signedIn)
        XCTAssertEqual(after.accountKey, before.accountKey)
        XCTAssertNotEqual(after.accessToken, before.accessToken)
        XCTAssertTrue(after.canRequest)
        XCTAssertTrue(harness.server.isUsable(after.accessToken), "the confirmed replacement is never revoked")
        XCTAssertEqual(harness.server.seen.filter { $0.path == "assets/a1/content" }.map(\.bearer), [before.accessToken, after.accessToken],
                       "one replay, with the replacement")
    }

    func testAPlaceRefusedDuringTheHandoverIsResentUnchangedWhileLocalCheckpointsGoOn() async throws {
        let harness = Harness()
        let before = harness.signIn()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileProgressStore(file: folder.appendingPathComponent("progress.json"))
        let registry = ProgressRegistry(store: store, remote: SessionProgressRemote.bind(session: before, sessions: harness.sessions, transport: harness.server))
        let sync = registry.sync(for: "pub-1")
        await sync.begin(position: nil, baseVersion: 0)
        try await harness.startHandover(before)

        await sync.update(SavedPosition(assetId: "a1", positionSeconds: 42), observedAt: 1_000)
        let sending = Task { await sync.flush() }
        try await until("the place sent with the old token was refused") { harness.server.refusals("library/pub-1/progress", of: before.accessToken) == 1 }

        // Five-second checkpoints keep landing on the device while the answer waits.
        await sync.update(SavedPosition(assetId: "a1", positionSeconds: 47), observedAt: 6_000)
        let local = try await store.get("pub-1")
        XCTAssertEqual(local?.position?.positionSeconds, 47, "a local checkpoint is never held up by the handover")
        XCTAssertNotNil(harness.sessions.signedIn)

        harness.server.meGate?.release()
        await sending.value
        await sync.flush()
        let after = try XCTUnwrap(harness.sessions.signedIn)
        let writes = harness.server.seen.filter { $0.path == "library/pub-1/progress" }
        XCTAssertEqual(writes.first?.bearer, before.accessToken)
        XCTAssertEqual(writes.dropFirst().first?.bearer, after.accessToken)
        XCTAssertEqual(writes.dropFirst().first?.body, writes.first?.body, "the same mutation, activity time and place")
        XCTAssertEqual(writes.dropFirst().first?.status, 200)
        XCTAssertEqual(writes.last?.bearer, after.accessToken)
        let delivered = await sync.snapshot()
        XCTAssertFalse(delivered.hasUnsyncedChanges)
        XCTAssertEqual(delivered.position?.positionSeconds, 47)
        await registry.stopAll()
    }

    func testARevocationAfterTheReplacementWasConfirmedStillSignsOut() async throws {
        let harness = Harness()
        let before = harness.signIn()
        let bound = harness.bound(before)
        try await harness.startHandover(before)
        let stream = harness.stream
        let playing = Task { try await bound.bytes(at: stream, range: 0 ... 3) }
        try await until("the old token's refusal") { harness.server.refusals("assets/a1/content", of: before.accessToken) == 1 }

        // Disconnected from the server's web page: the whole connection, replacement included.
        harness.server.revokeConnection(of: before.accessToken)
        harness.server.meGate?.release()
        harness.server.meGate = nil
        // The first answer to /me went out before the revoke; the next check is refused.
        do {
            _ = try await playing.value
            // The replayed request was refused with the replacement, ending the sign-in.
        } catch APIError.unauthorized {}
        await harness.requesting.settle()
        try await until("the sign-in ends") { harness.sessions.signedIn == nil }
        XCTAssertEqual(harness.server.seen.filter { $0.path == "assets/a1/content" && $0.status != 401 }.count, 0)
        guard case .expired = harness.sessions.state else { return XCTFail("a revocation ends the sign-in: \(harness.sessions.state)") }
    }

    func testARefusedReplacementEndsTheSignInAndReleasesWaitingWork() async throws {
        let harness = Harness()
        let before = harness.signIn()
        let bound = harness.bound(before)
        harness.server.holdMe = Gate()
        _ = await harness.requesting.start(before)
        try await until("the replacement's first request") { harness.server.holdMe?.arrivals == 1 }
        // Disconnected on the server between exchange and first use: the whole connection.
        harness.server.revokeConnection(of: before.accessToken)
        let stream = harness.stream
        let playing = Task { try await bound.bytes(at: stream, range: 0 ... 3) }
        try await until("the old token's refusal") { harness.server.refusals("assets/a1/content", of: before.accessToken) == 1 }
        XCTAssertNotNil(harness.sessions.signedIn, "it waits for the replacement's answer")
        harness.server.holdMe?.release()
        do {
            _ = try await playing.value
            XCTFail("nothing replaces a revoked connection")
        } catch {
            XCTAssertEqual(error as? APIError, .unauthorized)
        }
        await harness.requesting.settle()
        XCTAssertNil(harness.sessions.signedIn)
        guard case .expired = harness.sessions.state else { return XCTFail("a revocation ends the sign-in") }
        XCTAssertEqual(harness.server.seen.filter { $0.path == "assets/a1/content" }.count, 1, "nothing to replay with")
        XCTAssertNil(harness.sessions.pendingUpgrade(accountKey: before.accountKey))
    }

    func testALostAnswerKeepsTheReplacementAndTheNextLaunchRecoversTheSameSignIn() async throws {
        let store = Secrets()
        let harness = Harness(store: store)
        let before = harness.signIn()
        let bound = harness.bound(before)
        harness.server.meDrops = true
        _ = await harness.requesting.start(before)
        await harness.requesting.settle()
        XCTAssertFalse(harness.server.isUsable(before.accessToken), "the server retired the old token although its answer was lost")
        XCTAssertEqual(harness.sessions.signedIn?.accessToken, before.accessToken)
        guard case let .notAllowed(notice) = harness.requesting.state else { return XCTFail() }
        XCTAssertTrue(notice?.contains("couldn't confirm") == true)
        let kept = try XCTUnwrap(harness.sessions.pendingUpgrade(accountKey: before.accountKey)?.issued)
        XCTAssertTrue(harness.server.isUsable(kept.accessToken))

        // Still unanswered: work refused meanwhile waits for the connection, it isn't signed out.
        do {
            _ = try await bound.bytes(at: harness.stream, range: 0 ... 3)
            XCTFail("the replacement can't be confirmed yet")
        } catch {
            XCTAssertEqual(error as? APIError, .offline(certificate: false))
        }
        XCTAssertEqual(harness.sessions.signedIn?.accessToken, before.accessToken, "nothing ended")

        // The app is killed. The next launch confirms the stored replacement for this account.
        harness.server.meDrops = false
        harness.relaunch()
        XCTAssertEqual(harness.sessions.signedIn?.accessToken, before.accessToken)
        let relaunched = harness.bound(before)
        let (_, response) = try await relaunched.bytes(at: harness.stream, range: 0 ... 3)
        XCTAssertEqual(response.statusCode, 206, "the old token's refusal recovers the sign-in with its replacement")
        let after = try XCTUnwrap(harness.sessions.signedIn)
        XCTAssertEqual(after.accessToken, kept.accessToken)
        XCTAssertEqual(after.accountKey, before.accountKey)
        XCTAssertTrue(after.canRequest)
        XCTAssertNil(harness.sessions.pendingUpgrade(accountKey: before.accountKey))
        XCTAssertEqual(SessionManager(store: store).signedIn, after, "adopted durably")
    }

    func testAfterARelaunchRequestingConfirmsTheStoredReplacementWithoutAskingAgain() async throws {
        let store = Secrets()
        let harness = Harness(store: store)
        let before = harness.signIn()
        harness.server.meDrops = true
        _ = await harness.requesting.start(before)
        await harness.requesting.settle()
        harness.server.meDrops = false

        harness.relaunch()
        harness.requesting.resume(before)
        await harness.requesting.settle()
        XCTAssertEqual(harness.requesting.state, .allowed)
        XCTAssertTrue(harness.sessions.signedIn?.canRequest == true)
        XCTAssertEqual(harness.server.seen.filter { $0.path == "auth/device" }.count, 1, "no second approval")
    }

    func testCancellingAWaitingRequestDoesNotStopTheHandover() async throws {
        let harness = Harness()
        let before = harness.signIn()
        let bound = harness.bound(before)
        try await harness.startHandover(before)
        let stream = harness.stream
        let playing = Task { try await bound.bytes(at: stream, range: 0 ... 3) }
        try await until("the old token's refusal") { harness.server.refusals("assets/a1/content", of: before.accessToken) == 1 }
        playing.cancel()
        do {
            _ = try await playing.value
            XCTFail("a cancelled request stops waiting")
        } catch is CancellationError {}
        XCTAssertNotNil(harness.sessions.signedIn, "cancelling one request ends nothing")

        harness.server.meGate?.release()
        await harness.requesting.settle()
        XCTAssertEqual(harness.requesting.state, .allowed)
        XCTAssertNotEqual(harness.sessions.signedIn?.accessToken, before.accessToken)
    }

    func testSigningOutOrInAsSomeoneElseReleasesWaitingWorkWithoutBorrowingTheirToken() async throws {
        for switchAccount in [false, true] {
            let harness = Harness()
            let before = harness.signIn()
            let bound = harness.bound(before)
            try await harness.startHandover(before)
            let stream = harness.stream
            let playing = Task { try await bound.bytes(at: stream, range: 0 ... 3) }
            try await until("the old token's refusal") { harness.server.refusals("assets/a1/content", of: before.accessToken) == 1 }

            var other: Session?
            if switchAccount {
                other = harness.signIn(user: "u2")
            } else {
                harness.sessions.clear()
            }
            do {
                _ = try await playing.value
                XCTFail("work for an ended sign-in is never replayed")
            } catch {
                XCTAssertEqual(error as? APIError, .unauthorized, "released at once, without waiting for the server")
            }
            harness.server.meGate?.release()
            await harness.requesting.settle()
            XCTAssertEqual(harness.sessions.signedIn, other, "the replacement never becomes anyone's credential")
            if let other {
                XCTAssertFalse(harness.server.seen.contains { $0.bearer == other.accessToken }, "another sign-in's token is never borrowed")
            }
            XCTAssertNil(harness.sessions.pendingUpgrade(accountKey: before.accountKey)?.issued)
        }
    }

    func testAReplacementForAnotherAccountIsDroppedAndTheRefusalHonoured() async throws {
        let harness = Harness()
        let before = harness.signIn()
        let bound = harness.bound(before)
        harness.server.approvesAs = "u2"
        try await harness.startHandover(before)
        let stream = harness.stream
        let playing = Task { try await bound.bytes(at: stream, range: 0 ... 3) }
        try await until("the old token's refusal") { harness.server.refusals("assets/a1/content", of: before.accessToken) == 1 }
        harness.server.meGate?.release()
        do {
            _ = try await playing.value
            XCTFail("another account's token is never used for this sign-in")
        } catch {
            XCTAssertEqual(error as? APIError, .unauthorized)
        }
        await harness.requesting.settle()
        XCTAssertNil(harness.sessions.signedIn, "the old token was refused, and nothing of this account replaces it")
        XCTAssertEqual(harness.server.seen.filter { $0.path == "assets/a1/content" }.count, 1)
        guard case let .notAllowed(notice) = harness.requesting.state else { return XCTFail() }
        XCTAssertTrue(notice?.contains("different account") == true)
    }

    /// Transitions are whole: a replacement paused in its storage write can't interleave
    /// with a sign-out and a new sign-in, and the new sign-in never inherits its token.
    nonisolated func testTransitionsDoNotInterleaveWithTheirStorageWrites() throws {
        final class PausingStore: SecretStore, @unchecked Sendable {
            let lock = NSLock()
            var values: [String: Data] = [:]
            var pauseNextSession = false
            let entered = DispatchSemaphore(value: 0)
            let resume = DispatchSemaphore(value: 0)
            func read(_ name: String) -> Data? { lock.withLock { values[name] } }
            func write(_ name: String, _ value: Data) {
                let pause = lock.withLock { () -> Bool in
                    defer { if name == "session" { pauseNextSession = false } }
                    return name == "session" && pauseNextSession
                }
                if pause { entered.signal(); resume.wait() }
                lock.withLock { values[name] = value }
            }
            func delete(_ name: String) { _ = lock.withLock { values.removeValue(forKey: name) } }
        }
        guard case let .valid(server) = ServerAddress.parse("https://example.org") else { return XCTFail() }
        let store = PausingStore()
        let sessions = SessionManager(store: store)
        let old = Session(server: server, user: Me(id: "u1"), accessToken: "synthetic-old")
        let upgraded = Session(server: server, user: Me(id: "u1"), accessToken: "synthetic-upgraded")
        let next = Session(server: server, user: Me(id: "u1"), accessToken: "synthetic-next")
        sessions.signIn(old)
        store.lock.withLock { store.pauseNextSession = true }
        let replaced = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            XCTAssertTrue(sessions.replaceToken(expected: old, upgraded: upgraded))
            replaced.signal()
        }
        XCTAssertEqual(store.entered.wait(timeout: .now() + 5), .success)
        let signedInAgain = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            sessions.clear()
            sessions.signIn(next)
            signedInAgain.signal()
        }
        XCTAssertEqual(signedInAgain.wait(timeout: .now() + 0.2), .timedOut, "the sign-out waits for the transition under way")
        store.resume.signal()
        XCTAssertEqual(replaced.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(signedInAgain.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(sessions.signedIn, next)
        XCTAssertEqual(SignInBinding(session: next, sessions: sessions).live, next, "the new sign-in has its own token")
        XCTAssertNil(sessions.continuing(old))
        XCTAssertEqual(SessionManager(store: store).signedIn, next)
    }
}

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

/// The consumer API's requesting contract (docs/consumer-api.md) as an in-memory
/// transport. Synthetic data only; a request moves one stage each time it is read.
final class RequestFixture: HTTPTransport, @unchecked Sendable {
    enum Decision { case approve, deny, approveAsOtherUser }

    private let lock = NSLock()
    var oldServer = false
    var offline = false
    var decision = Decision.approve
    var outcome = "available"
    private(set) var tokens: [String: (user: String, scopes: [String])] = [:]
    private(set) var revoked: [String] = []
    private(set) var deviceBearers: [String?] = []
    private(set) var creates = 0
    /// The bearer of every progress write that reached the server.
    private(set) var progressBearers: [String] = []
    private var devices: [String: (scopes: [String], polls: Int)] = [:]
    private var requests: [(id: String, work: String, type: String, title: String, step: Int, stage: String, percent: Int?)] = []
    private var counter = 0

    static let catalogue = [("fx:lighthouse", "The Lighthouse Keeper"), ("fx:in-library", "A Book Already Here"), ("fx:elsewhere", "Rivers Remember")]
    private static let steps: [(String, Int?)] = [("queued", nil), ("searching", nil), ("downloading", 30), ("downloading", 70), ("processing", nil), ("available", nil)]

    func issue(_ scopes: [String] = RequestScopes.base, user: String = "u1") -> String {
        lock.withLock {
            counter += 1
            let token = "tok-\(counter)"
            tokens[token] = (user, scopes)
            return token
        }
    }

    func setScopes(_ token: String, _ scopes: [String]) { lock.withLock { tokens[token]?.scopes = scopes } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if lock.withLock({ offline }) { throw APIError.offline(certificate: false) }
        let (status, body) = lock.withLock { handle(request) }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!)
    }

    func download(_ request: URLRequest, to file: URL, onResponse: @escaping @Sendable (HTTPURLResponse) -> Void, onProgress: @escaping @Sendable (Int64) -> Void) async throws -> HTTPURLResponse {
        throw APIError.protocolError
    }

    private func handle(_ request: URLRequest) -> (Int, String) {
        let url = request.url!
        let path = url.path.replacingOccurrences(of: "/s/api/consumer/v1/", with: "")
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let bearer = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
        let method = request.httpMethod ?? "GET"
        if path == "server.json" {
            return (200, oldServer ? #"{"schema_version":1}"# : #"{"schema_version":1,"consumer_features":["requests"]}"#)
        }
        if path == "auth/device" {
            deviceBearers.append(bearer)
            if let bearer, !oldServer, tokens[bearer] == nil { return (401, "{}") }
            let asked = (body["scope"] as? String)?.split(separator: " ").map(String.init) ?? []
            let scopes = !oldServer && RequestScopes.allows(asked) ? RequestScopes.base + RequestScopes.requesting : RequestScopes.base
            counter += 1
            devices["dev-\(counter)"] = (scopes, 0)
            return (200, #"{"device_code":"dev-\#(counter)","user_code":"ABCD-EFGH","verification_uri":"/s/consumer/connect","verification_uri_complete":"/s/consumer/connect?user_code=ABCD-EFGH","expires_in":600,"interval":1}"#)
        }
        if path == "auth/token" {
            let code = body["device_code"] as? String ?? ""
            guard var device = devices[code] else { return (400, #"{"error":"expired_token"}"#) }
            device.polls += 1
            devices[code] = device
            if device.polls < 2 { return (400, #"{"error":"authorization_pending"}"#) }
            devices[code] = nil
            if decision == .deny { return (400, #"{"error":"access_denied"}"#) }
            counter += 1
            let token = "tok-\(counter)"
            tokens[token] = (decision == .approveAsOtherUser ? "u2" : "u1", device.scopes)
            return (200, #"{"access_token":"\#(token)","token_type":"Bearer","scope":"\#(device.scopes.joined(separator: " "))","expires_in":2592000}"#)
        }
        guard let bearer, let owner = tokens[bearer] else { return (401, "{}") }
        func need(_ scope: String) -> (Int, String)? {
            owner.scopes.contains(scope) ? nil : (403, #"{"error":"insufficient_scope","required_scope":"\#(scope)"}"#)
        }
        switch (method, path) {
        case ("POST", "auth/revoke"):
            tokens[bearer] = nil
            revoked.append(bearer)
            return (204, "")
        case (_, "me"):
            let scopes = owner.scopes.map { "\"\($0)\"" }.joined(separator: ",")
            return (200, oldServer ? #"{"id":"\#(owner.user)","name":"Ada"}"# : #"{"id":"\#(owner.user)","name":"Ada","scopes":[\#(scopes)]}"#)
        case (_, "discover"):
            if let denied = need("search:read") { return denied }
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value?.lowercased() ?? ""
            return (200, #"{"items":[\#(Self.catalogue.filter { $0.1.lowercased().contains(q) }.map(item).joined(separator: ","))]}"#)
        case ("POST", "requests"):
            if let denied = need("requests:write") { return denied }
            creates += 1
            let work = body["work_id"] as? String ?? ""
            let type = body["book_type"] as? String ?? ""
            guard let entry = Self.catalogue.first(where: { $0.0 == work }) else { return (422, #"{"error":"invalid_request"}"#) }
            switch fixedState(work, type) {
            case "in_library": return (409, #"{"error":"already_in_library","message":"Already in the library.","publication_id":"lib-1"}"#)
            case "requested_by_someone": return (409, #"{"error":"already_requested","message":"Someone on this server has already requested this audiobook."}"#)
            default: break
            }
            if let mine = requests.firstIndex(where: { $0.work == work && $0.type == type && $0.stage != "failed" }) {
                return (200, #"{"request":\#(view(mine)),"existing":true}"#)
            }
            counter += 1
            requests.append(("r\(counter)", work, type, entry.1, 0, "queued", nil))
            return (201, #"{"request":\#(view(requests.count - 1))}"#)
        case ("GET", "requests"):
            if let denied = need("requests:read") { return denied }
            return (200, #"{"items":[\#(requests.indices.reversed().map { view(advance($0)) }.joined(separator: ","))]}"#)
        case ("DELETE", _) where path.hasPrefix("requests/"):
            if let denied = need("requests:write") { return denied }
            guard let index = requests.firstIndex(where: { $0.id == String(path.dropFirst(9)) }) else { return (404, "{}") }
            if ["processing", "available"].contains(requests[index].stage) {
                return (422, #"{"error":"cannot_cancel","message":"This request is being finished and can't be cancelled now."}"#)
            }
            requests[index].stage = "failed"
            return (200, #"{"request":\#(view(index))}"#)
        case ("PUT", _) where path.hasPrefix("library/") && path.hasSuffix("/progress"):
            progressBearers.append(bearer)
            let asset = body["asset_id"] as? String ?? ""
            let seconds = body["position_seconds"] as? Double ?? 0
            let version = (body["expected_version"] as? Int ?? 0) + 1
            let mutation = body["client_mutation_id"] as? String ?? ""
            return (200, #"{"progress":{"asset_id":"\#(asset)","position_seconds":\#(seconds),"version":\#(version),"client_mutation_id":"\#(mutation)"}}"#)
        case ("GET", _) where path.hasPrefix("requests/"):
            if let denied = need("requests:read") { return denied }
            guard let index = requests.firstIndex(where: { $0.id == String(path.dropFirst(9)) }) else { return (404, "{}") }
            return (200, #"{"request":\#(view(advance(index)))}"#)
        default:
            return (404, #"{"error":"not_found"}"#)
        }
    }

    private func advance(_ index: Int) -> Int {
        let stage = requests[index].stage
        if ["available", "failed", "not_found"].contains(stage) { return index }
        if stage == "searching", outcome != "available" {
            requests[index].stage = outcome
            return index
        }
        requests[index].step += 1
        let next = Self.steps[min(requests[index].step, Self.steps.count - 1)]
        requests[index].stage = next.0
        requests[index].percent = next.1
        return index
    }

    private func view(_ index: Int) -> String {
        let r = requests[index]
        let publication = r.stage == "available" ? "\"pub-\(r.id)\"" : "null"
        let percent = r.stage == "downloading" ? "\(r.percent ?? 0)" : "null"
        let cancellable = !["available", "failed"].contains(r.stage)
        return #"{"id":"\#(r.id)","stage":"\#(r.stage)","title":"\#(r.title)","book_type":"\#(r.type)","download_percent":\#(percent),"can_cancel":\#(cancellable),"publication_id":\#(publication)}"#
    }

    private func fixedState(_ work: String, _ type: String) -> String {
        if work == "fx:in-library", type == "ebook" { return "in_library" }
        if work == "fx:elsewhere", type == "audiobook" { return "requested_by_someone" }
        return "requestable"
    }

    private func item(_ entry: (String, String)) -> String {
        let formats = ["ebook", "audiobook"].map { type -> String in
            if let mine = requests.firstIndex(where: { $0.work == entry.0 && $0.type == type && $0.stage != "failed" }) {
                return #"{"book_type":"\#(type)","state":"requested","request":\#(view(mine))}"#
            }
            let state = fixedState(entry.0, type)
            return state == "in_library" ? #"{"book_type":"\#(type)","state":"in_library","publication_id":"lib-1"}"# : #"{"book_type":"\#(type)","state":"\#(state)"}"#
        }
        return #"{"id":"\#(entry.0)","work_id":"\#(entry.0)","title":"\#(entry.1)","author":"Fixture Author","year":2019,"formats":[\#(formats.joined(separator: ","))]}"#
    }
}

@MainActor
private final class Harness: FindBackend {
    let fixture = RequestFixture()
    let sessions = SessionManager(store: Secrets())
    let api: ConsumerAPI
    let requesting: RequestingAccess
    let server: ServerAddress = {
        guard case let .valid(address) = ServerAddress.parse("https://example.org/s") else { fatalError() }
        return address
    }()

    init() {
        let sessions = self.sessions
        let fixture = self.fixture
        api = ConsumerAPI(transport: fixture, credential: { sessions.credential() }, onRejected: { sessions.markExpired($0) })
        requesting = RequestingAccess(
            backend: RequestingBackend(
                sessions: sessions,
                api: api,
                apiFor: { credential in ConsumerAPI(transport: fixture, credential: { credential }) },
                sleep: { _ in await Task.yield() }
            ),
            clientName: "Shelfarr iPad"
        )
    }

    @discardableResult
    func signIn(_ scopes: [String] = RequestScopes.base) -> Session {
        let session = Session(server: server, user: Me(id: "u1", name: "Ada", scopes: scopes), accessToken: fixture.issue(scopes), grantedScopes: scopes)
        sessions.signIn(session)
        return session
    }

    private var session: Session { sessions.signedIn! }

    // FindBackend
    var access: RequestAccess { requesting.state }
    func refreshAccess() async { await requesting.refresh(session) }
    func allowRequesting() async -> URL? { await requesting.start(session) }
    func cancelApproval() { requesting.cancel() }
    func refreshScopes() async {
        if let me = try? await api.me(server: session.server) { sessions.refreshUser(me, expected: session) }
        await refreshAccess()
    }
    func discover(_ query: String) async throws -> [DiscoverItem] { try await api.discover(server: server, query: query) }
    func requests() async throws -> [RequestItem] { try await api.requests(server: server) }
    func request(_ id: String) async throws -> RequestItem { try await api.request(server: server, id: id) }
    func create(_ request: NewRequest) async throws -> RequestOutcome { try await api.createRequest(server: server, request) }
    func cancel(_ id: String) async throws -> RequestItem { try await api.cancelRequest(server: server, id: id) }
}

@MainActor
final class RequestingTests: XCTestCase {
    func testApprovedUpgradeKeepsTheAccountAndRetiresTheOldToken() async {
        let harness = Harness()
        let before = harness.signIn()
        await harness.requesting.refresh(before)
        XCTAssertEqual(harness.requesting.state, .notAllowed(notice: nil))

        let page = await harness.requesting.start(before)
        XCTAssertEqual(page?.absoluteString, "https://example.org/s/consumer/connect?user_code=ABCD-EFGH")
        XCTAssertEqual(harness.fixture.deviceBearers, [before.accessToken])
        XCTAssertNotNil(harness.sessions.pendingUpgrade(accountKey: before.accountKey))
        let second = await harness.requesting.start(before)
        XCTAssertEqual(second, page, "a second tap reopens the same approval")
        XCTAssertEqual(harness.fixture.deviceBearers.count, 1)

        await harness.requesting.settle()
        XCTAssertEqual(harness.requesting.state, .allowed)
        let after = harness.sessions.signedIn!
        XCTAssertEqual(after.accountKey, before.accountKey)
        XCTAssertNotEqual(after.accessToken, before.accessToken)
        XCTAssertTrue(after.canRequest)
        XCTAssertTrue(harness.fixture.revoked.contains(before.accessToken))
        XCTAssertNil(harness.sessions.pendingUpgrade(accountKey: before.accountKey))
    }

    /// An open book's place, saved offline before requesting was added, reaches the server
    /// with the new token afterwards: the old token is revoked, nothing signs out, and the
    /// sync built before the upgrade is the one that delivers it.
    func testAnUnsentPlaceFromBeforeTheUpgradeIsDeliveredWithTheNewToken() async throws {
        let harness = Harness()
        let before = harness.signIn()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let registry = ProgressRegistry(
            store: FileProgressStore(file: folder.appendingPathComponent("progress.json")),
            remote: SessionProgressRemote.bind(session: before, sessions: harness.sessions, transport: harness.fixture)
        )
        let sync = registry.sync(for: "pub-1")
        await sync.begin(position: nil, baseVersion: 0)
        harness.fixture.offline = true
        await sync.update(SavedPosition(assetId: "a1", positionSeconds: 42), observedAt: 1_000)
        await sync.flush()
        let waiting = await sync.snapshot()
        XCTAssertTrue(waiting.hasUnsyncedChanges, "the place waits on this device")
        harness.fixture.offline = false

        _ = await harness.requesting.start(before)
        await harness.requesting.settle()
        XCTAssertEqual(harness.requesting.state, .allowed)
        let after = try XCTUnwrap(harness.sessions.signedIn)
        XCTAssertTrue(harness.fixture.revoked.contains(before.accessToken))
        XCTAssertEqual(harness.sessions.continuing(before), after, "the same sign-in goes on with the new token")

        await sync.flush()
        let delivered = await sync.snapshot()
        XCTAssertFalse(delivered.hasUnsyncedChanges, "the place reached the server")
        XCTAssertEqual(delivered.position?.positionSeconds, 42)
        XCTAssertEqual(harness.fixture.progressBearers, [after.accessToken])
        XCTAssertEqual(harness.sessions.signedIn, after, "nothing signed out")
        await registry.stopAll()
    }

    func testDenialAndOtherAccountsLeaveTheConnectionAlone() async {
        let harness = Harness()
        let before = harness.signIn()
        harness.fixture.decision = .deny
        _ = await harness.requesting.start(before)
        await harness.requesting.settle()
        XCTAssertEqual(harness.sessions.signedIn, before)
        guard case let .notAllowed(notice) = harness.requesting.state else { return XCTFail() }
        XCTAssertTrue(notice?.contains("wasn't allowed") == true)

        harness.fixture.decision = .approveAsOtherUser
        _ = await harness.requesting.start(before)
        await harness.requesting.settle()
        XCTAssertEqual(harness.sessions.signedIn, before)
        guard case let .notAllowed(other) = harness.requesting.state else { return XCTFail() }
        XCTAssertTrue(other?.contains("different account") == true)
        XCTAssertEqual(harness.fixture.revoked.count, 1)
        XCTAssertFalse(harness.fixture.revoked.contains(before.accessToken))
    }

    func testOlderServersAndOfflineAreExplained() async {
        let harness = Harness()
        harness.fixture.oldServer = true
        let before = harness.signIn()
        await harness.requesting.refresh(before)
        XCTAssertEqual(harness.requesting.state, .serverTooOld)
        XCTAssertTrue(harness.fixture.deviceBearers.isEmpty)

        let fresh = Harness()
        let session = fresh.signIn()
        fresh.fixture.offline = true
        let page = await fresh.requesting.start(session)
        XCTAssertNil(page)
        guard case let .notAllowed(notice) = fresh.requesting.state else { return XCTFail() }
        XCTAssertTrue(notice?.contains("offline") == true)
        XCTAssertNil(fresh.sessions.pendingUpgrade(accountKey: session.accountKey))
    }

    func testSessionsSavedBeforeScopesReadAsReadOnly() {
        let store = Secrets()
        store.write("session", Data(#"{"server":{"scheme":"https","host":"example.org","basePath":"/s"},"accessToken":"t","user":{"id":"u1"}}"#.utf8))
        let restored = SessionManager(store: store).signedIn
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.scopes, RequestScopes.base)
        XCTAssertEqual(restored?.canRequest, false)
    }

    func testFindRequestFollowAndOpen() async {
        let harness = Harness()
        harness.signIn(RequestScopes.base + RequestScopes.requesting)
        let flow = FindFlow(backend: harness, pollIntervalNanoseconds: 1_000_000)
        var shown: [String] = []
        flow.onShowRequest = { shown.append($0) }
        await flow.onShown()
        XCTAssertEqual(flow.access, .allowed)
        XCTAssertTrue(flow.find.requestsLoaded)

        flow.setQuery("light")
        flow.search()
        await flow.searchSettled()
        XCTAssertEqual(flow.find.results.map(\.title), ["The Lighthouse Keeper"])
        XCTAssertEqual(flow.find.results.first?.formatsLine, "Ebook or audiobook")

        flow.choose(flow.find.results[0])
        XCTAssertEqual(flow.title.format, .ebook)
        flow.selectFormat(.audiobook)
        flow.submit()
        flow.submit()
        flow.submit()
        await flow.submitSettled()
        XCTAssertEqual(harness.fixture.creates, 1, "a burst of taps makes one request")
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(flow.track.request?.stage, .queued)
        XCTAssertEqual(flow.find.results.first?.format(.audiobook)?.state, .requested)

        flow.startTracking(shown[0])
        await flow.trackingSettled()
        XCTAssertEqual(flow.track.request?.stage, .available)
        XCTAssertEqual(flow.track.request?.publicationId, "pub-\(shown[0])")
        XCTAssertTrue(flow.track.request?.isReady == true)
    }

    func testDuplicatesElsewhereInLibraryOfflineAndCancel() async {
        let harness = Harness()
        harness.signIn(RequestScopes.base + RequestScopes.requesting)
        harness.fixture.outcome = "not_found"
        let flow = FindFlow(backend: harness, pollIntervalNanoseconds: 1_000_000)
        flow.setQuery("r")
        flow.search()
        await flow.searchSettled()
        let elsewhere = flow.find.results.first { $0.title == "Rivers Remember" }!
        XCTAssertEqual(elsewhere.formatsLine, "Ebook can be requested · Audiobook already requested")
        XCTAssertEqual(flow.find.results.first { $0.title == "A Book Already Here" }?.formatsLine, "Ebook in your library · Audiobook can be requested")

        flow.choose(elsewhere)
        flow.selectFormat(.audiobook)
        XCTAssertEqual(flow.title.format, .ebook, "a format someone else requested can't be chosen")

        harness.fixture.offline = true
        flow.submit()
        await flow.submitSettled()
        XCTAssertEqual(flow.title.message, "You're offline. Requesting needs a connection to your server.")
        XCTAssertFalse(flow.title.submitting)
        XCTAssertEqual(harness.fixture.creates, 0)

        harness.fixture.offline = false
        flow.submit()
        await flow.submitSettled()
        let id = flow.track.request!.id
        flow.startTracking(id)
        // Not found stays open (the server looks again), so tracking keeps polling until the page closes.
        for _ in 0 ..< 200 where flow.track.request?.stage != .notFound {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        flow.stopTracking()
        XCTAssertEqual(flow.track.request?.stage, .notFound)
        XCTAssertEqual(flow.track.request?.stageCopy.headline, "No copy found yet")
        await flow.cancelRequest()
        XCTAssertEqual(flow.track.request?.stage, .failed)
        XCTAssertEqual(flow.track.request?.stageCopy.headline, "Stopped")

        flow.setQuery("zzz")
        flow.search()
        await flow.searchSettled()
        XCTAssertEqual(flow.find.results, [])
        XCTAssertNil(flow.find.searchError)
        harness.fixture.offline = true
        flow.search()
        await flow.searchSettled()
        XCTAssertEqual(flow.find.searchError, .offline(certificate: false))
    }

    func testARevokedScopeReturnsToTheOptIn() async {
        let harness = Harness()
        let session = harness.signIn(RequestScopes.base + RequestScopes.requesting)
        let flow = FindFlow(backend: harness, pollIntervalNanoseconds: 1_000_000)
        await flow.onShown()
        XCTAssertEqual(flow.access, .allowed)
        harness.fixture.setScopes(session.accessToken, RequestScopes.base)
        flow.setQuery("light")
        flow.search()
        await flow.searchSettled()
        XCTAssertEqual(flow.find.searchError, .forbidden)
        XCTAssertEqual(flow.access, .notAllowed(notice: nil))
        XCTAssertEqual(harness.sessions.signedIn?.accessToken, session.accessToken)
    }
}

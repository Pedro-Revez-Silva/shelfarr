import Foundation

public protocol SecretStore: AnyObject, Sendable {
    func read(_ name: String) -> Data?
    func write(_ name: String, _ value: Data)
    func delete(_ name: String)
}

/// A signed-in account: one user on one server.
public struct Session: Equatable, Sendable, CustomStringConvertible {
    public let server: ServerAddress
    public let user: Me
    public let accessToken: String

    public init(server: ServerAddress, user: Me, accessToken: String) {
        self.server = server
        self.user = user
        self.accessToken = accessToken
    }

    /// Scopes every local file, so accounts and servers can never mix.
    public var accountKey: String { Self.accountKey(server: server, userId: user.id) }

    public static func accountKey(server: ServerAddress, userId: String) -> String {
        String(SHA256.hexDigest(Data("\(server.display.lowercased())\n\(userId)".utf8)).prefix(32))
    }

    public var description: String { "Session(server: \(server.display), user: \(user.id))" }
}

public enum SessionState: Equatable, Sendable {
    case signedOut
    case expired(ServerAddress, String?)
    case signedIn(Session)
}

public struct PendingAuthorization: Codable, Equatable, Sendable {
    public let server: ServerAddress
    public let grant: DeviceGrant
    public let expiresAt: Date

    public init(server: ServerAddress, grant: DeviceGrant, expiresAt: Date) {
        self.server = server
        self.grant = grant
        self.expiresAt = expiresAt
    }
}

/// Owns the session secret. Nothing else reads or writes the token.
public final class SessionManager: @unchecked Sendable {
    private struct Stored: Codable {
        let server: ServerAddress
        let accessToken: String
        let user: Me
    }

    private enum Keys {
        static let session = "session"
        static let authorization = "pending_authorization"
    }

    private let store: SecretStore
    private let lock = NSLock()
    private var current: SessionState
    private var provisional: Credential?

    public var onChange: (@Sendable (SessionState) -> Void)?

    public init(store: SecretStore) {
        self.store = store
        current = Self.load(store)
    }

    private static func load(_ store: SecretStore) -> SessionState {
        guard let data = store.read(Keys.session),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return .signedOut }
        if stored.accessToken.isEmpty { return .expired(stored.server, stored.user.displayName) }
        return .signedIn(Session(server: stored.server, user: stored.user, accessToken: stored.accessToken))
    }

    public var state: SessionState { lock.withLock { current } }

    public var signedIn: Session? {
        if case let .signedIn(session) = state { return session }
        return nil
    }

    public func credential() -> Credential? {
        lock.withLock {
            if let provisional { return provisional }
            if case let .signedIn(session) = current {
                return Credential(server: session.server, accessToken: session.accessToken)
            }
            return nil
        }
    }

    /// A token between approval and `/me`, held in memory only.
    public func useProvisional(_ credential: Credential?) {
        lock.withLock { provisional = credential }
    }

    public func signIn(_ session: Session) {
        persist(Stored(server: session.server, accessToken: session.accessToken, user: session.user))
        store.delete(Keys.authorization)
        update(.signedIn(session))
    }

    /// The server refused the token. Forget it, keep the address for re-authorizing.
    public func markExpired(_ rejected: Credential) {
        guard let session = signedIn, session.accessToken == rejected.accessToken else { return }
        persist(Stored(server: session.server, accessToken: "", user: session.user))
        update(.expired(session.server, session.user.displayName))
    }

    public func clear() {
        store.delete(Keys.session)
        store.delete(Keys.authorization)
        update(.signedOut)
    }

    private func persist(_ stored: Stored) {
        if let data = try? JSONEncoder().encode(stored) { store.write(Keys.session, data) }
    }

    private func update(_ state: SessionState) {
        lock.withLock {
            current = state
            provisional = nil
        }
        onChange?(state)
    }

    public func savePendingAuthorization(_ pending: PendingAuthorization) {
        if let data = try? JSONEncoder().encode(pending) { store.write(Keys.authorization, data) }
    }

    public func pendingAuthorization(now: Date = Date()) -> PendingAuthorization? {
        guard let data = store.read(Keys.authorization),
              let pending = try? JSONDecoder().decode(PendingAuthorization.self, from: data)
        else { return nil }
        if pending.expiresAt <= now {
            store.delete(Keys.authorization)
            return nil
        }
        return pending
    }

    public func clearPendingAuthorization() { store.delete(Keys.authorization) }
}

public enum AuthorizationOutcome: Equatable, Sendable {
    case approved(TokenResponse)
    case expired
    case denied
}

/// Runs the token polling loop for one grant. It stops at approval, expiry, denial
/// or task cancellation, and only ever has one request outstanding.
public struct DeviceAuthorizer: Sendable {
    private let exchange: @Sendable (ServerAddress, String) async throws -> TokenResponse
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (UInt64) async throws -> Void

    public init(
        exchange: @escaping @Sendable (ServerAddress, String) async throws -> TokenResponse,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.exchange = exchange
        self.now = now
        self.sleep = sleep
    }

    public func await(_ pending: PendingAuthorization) async throws -> AuthorizationOutcome {
        var interval = max(pending.grant.interval, 1)
        var failures = 0
        while true {
            let backoff = failures > 0 ? min(30, 1 << min(failures, 5)) : 0
            try await sleep(UInt64(interval + backoff) * 1_000_000_000)
            try Task.checkCancellation()
            if now() >= pending.expiresAt { return .expired }
            do {
                return .approved(try await exchange(pending.server, pending.grant.deviceCode))
            } catch let APIError.authorization(code) {
                failures = 0
                switch code {
                case "authorization_pending": continue
                case "slow_down": interval += 5
                case "access_denied": return .denied
                default: return .expired
                }
            } catch let error as APIError where error.isRetryable {
                // A dropped connection must not cost the user their sign-in attempt.
                failures += 1
            }
        }
    }
}

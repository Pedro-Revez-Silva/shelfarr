import Foundation

/// Whether this connection may find and request titles, and how to change that.
public enum RequestAccess: Equatable, Sendable {
    case checking
    case allowed
    /// The server has no requesting for apps. Reading and listening are unaffected.
    case serverTooOld
    /// Read-and-listen only. The notice explains how the last attempt ended.
    case notAllowed(notice: String?)
    /// Waiting for the person to approve in the browser.
    case approving(userCode: String, verificationURL: URL, browserURL: URL, expiresAt: Date)
}

/// What adding requesting needs from the outside world.
public struct RequestingBackend: Sendable {
    public let sessions: SessionManager
    /// The signed-in API: it sends the live bearer to the configured server.
    public let api: ConsumerAPI
    /// A client that sends exactly this credential and never ends the live session on a 401.
    public let apiFor: @Sendable (Credential) -> ConsumerAPI
    public let sleep: @Sendable (UInt64) async throws -> Void

    public init(sessions: SessionManager, api: ConsumerAPI, apiFor: @escaping @Sendable (Credential) -> ConsumerAPI,
                sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.sessions = sessions
        self.api = api
        self.apiFor = apiFor
        self.sleep = sleep
    }
}

/// Adds the requesting permission to the signed-in connection without disconnecting:
/// the server, account files, downloads, settings and saved places stay as they are.
/// Only a fresh, explicit browser approval for the same account grants it; an approval
/// by another account, a denial or an expiry leaves the existing connection untouched.
@MainActor
public final class RequestingAccess {
    public private(set) var state: RequestAccess = .checking {
        didSet { if state != oldValue { onChange?(state) } }
    }
    public var onChange: ((RequestAccess) -> Void)?

    private let backend: RequestingBackend
    private let clientName: String
    private var polling: Task<Void, Never>?
    private var starting = false
    private var facts: [String: Bool] = [:]

    public init(backend: RequestingBackend, clientName: String) {
        self.backend = backend
        self.clientName = clientName
    }

    /// Recomputes from the live session, asking the server what it offers when needed.
    public func refresh(_ session: Session) async {
        if case .approving = state { return }
        if session.canRequest {
            state = .allowed
            return
        }
        var offered = facts[session.server.display]
        if offered == nil {
            do {
                offered = try await backend.api.serverFacts(server: session.server).offersRequesting
            } catch APIError.notFound {
                offered = false
            } catch {
                offered = nil // Unknown while offline: let the person try; the attempt explains itself.
            }
            if let offered { facts[session.server.display] = offered }
        }
        if offered == false {
            state = .serverTooOld
        } else if case .notAllowed = state {
            return
        } else {
            state = .notAllowed(notice: nil)
        }
    }

    /// Continues an approval the app was killed during.
    public func resume(_ session: Session) {
        guard let pending = backend.sessions.pendingUpgrade(accountKey: session.accountKey) else { return }
        poll(session, pending)
    }

    /// Starts one approval and returns the page to open, or nil when nothing started.
    /// A second tap while starting or approving opens the same page or does nothing.
    public func start(_ session: Session) async -> URL? {
        if case let .approving(_, _, browser, _) = state { return browser }
        guard !starting else { return nil }
        starting = true
        defer { starting = false }
        do {
            let grant = try await backend.api.startDeviceAuthorization(server: session.server, clientName: clientName, scope: RequestScopes.all)
            guard let browser = session.server.resolve(grant.verificationUriComplete),
                  let verification = session.server.resolve(grant.verificationUri),
                  session.server.contains(browser), session.server.contains(verification)
            else {
                state = .notAllowed(notice: "\(session.server.host) asked to approve this somewhere else, so nothing was opened.")
                return nil
            }
            let pending = PendingUpgrade(accountKey: session.accountKey, grant: grant, expiresAt: Date().addingTimeInterval(TimeInterval(grant.expiresIn)))
            backend.sessions.savePendingUpgrade(pending)
            poll(session, pending)
            return browser
        } catch let error as APIError {
            switch error {
            case .notFound: state = .serverTooOld
            case .offline(certificate: false): state = .notAllowed(notice: "You're offline. Allowing requesting needs a connection to \(session.server.host).")
            case .unauthorized: state = .notAllowed(notice: "Your sign-in has ended. Sign in again, then allow requesting.")
            default: state = .notAllowed(notice: "\(session.server.host) couldn't start the approval. Try again in a moment.")
            }
            return nil
        } catch {
            state = .notAllowed(notice: "\(session.server.host) couldn't start the approval. Try again in a moment.")
            return nil
        }
    }

    public func cancel() {
        polling?.cancel()
        polling = nil
        backend.sessions.clearPendingUpgrade()
        state = .notAllowed(notice: nil)
    }

    /// Signed out: forget the attempt; the stored grant went with the session.
    public func detach() {
        polling?.cancel()
        polling = nil
        facts = [:]
        state = .checking
    }

    /// Completes when the current approval has ended. For tests and callers that wait.
    public func settle() async {
        await polling?.value
    }

    private func poll(_ session: Session, _ pending: PendingUpgrade) {
        polling?.cancel()
        let server = session.server
        state = .approving(
            userCode: pending.grant.userCode,
            verificationURL: server.resolve(pending.grant.verificationUri) ?? server.baseURL,
            browserURL: server.resolve(pending.grant.verificationUriComplete) ?? server.baseURL,
            expiresAt: pending.expiresAt
        )
        let api = backend.api
        let authorizer = DeviceAuthorizer(
            exchange: { server, code in try await api.exchangeDeviceCode(server: server, deviceCode: code) },
            sleep: backend.sleep
        )
        polling = Task { [weak self] in
            let ended: RequestAccess
            do {
                switch try await authorizer.await(PendingAuthorization(server: server, grant: pending.grant, expiresAt: pending.expiresAt)) {
                case let .approved(token): ended = await self?.adopt(session, token) ?? .checking
                case .denied: ended = .notAllowed(notice: "Requesting wasn't allowed. The app still reads and plays everything as before.")
                case .expired: ended = .notAllowed(notice: "The approval code expired. Try again when you're ready.")
                }
            } catch is CancellationError {
                return
            } catch APIError.offline(certificate: false) {
                ended = .notAllowed(notice: "The connection dropped before approval finished. Try again.")
            } catch {
                ended = .notAllowed(notice: "Approval couldn't finish. Try again.")
            }
            guard let self, !Task.isCancelled else { return }
            self.backend.sessions.clearPendingUpgrade()
            self.state = ended
        }
    }

    private func adopt(_ session: Session, _ token: TokenResponse) async -> RequestAccess {
        let fresh = backend.apiFor(Credential(server: session.server, accessToken: token.accessToken))
        guard let user = try? await fresh.me(server: session.server) else {
            return .notAllowed(notice: "Approval finished, but \(session.server.host) couldn't confirm it. Try again.")
        }
        guard user.id == session.user.id else {
            // Never switch accounts from here; the server already refuses this, so a stray token is dropped.
            try? await fresh.revoke(server: session.server)
            return .notAllowed(notice: "That approval was for a different account, so nothing changed.")
        }
        let granted = (token.scope ?? "").split(separator: " ").map(String.init)
        let upgraded = Session(server: session.server, user: user, accessToken: token.accessToken, grantedScopes: granted)
        guard backend.sessions.replaceToken(expected: session, upgraded: upgraded) else {
            try? await fresh.revoke(server: session.server)
            return .notAllowed(notice: nil)
        }
        // The server retires the old credential once the new one is used; this also covers older servers.
        try? await backend.apiFor(Credential(server: session.server, accessToken: session.accessToken)).revoke(server: session.server)
        if upgraded.canRequest { return .allowed }
        facts[session.server.display] = false
        return .serverTooOld
    }
}

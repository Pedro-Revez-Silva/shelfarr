import Foundation
import ShelfarrCore

@MainActor
final class SetupModel: ObservableObject {
    enum Phase: Equatable {
        case enterServer
        case connecting
        case authorizing(PendingAuthorization)
        case ended(ServerAddress, denied: Bool)
    }

    @Published var address = ""
    @Published var allowLocalHTTP = false
    @Published var errorMessage: String?
    @Published private(set) var phase: Phase = .enterServer
    @Published private(set) var secondsLeft = 0
    @Published var browserRequest: URL?

    private(set) var expiredFor: String?
    private let app: AppModel
    private var polling: Task<Void, Never>?
    private var countdown: Task<Void, Never>?

    #if ALLOW_LOCAL_HTTP
    let canUseLocalHTTP = true
    #else
    let canUseLocalHTTP = false
    #endif

    init(app: AppModel) {
        self.app = app
        if case let .expired(server, name) = app.state {
            address = server.display
            allowLocalHTTP = server.isCleartext
            expiredFor = name
        }
        // iOS may have stopped us while Safari was in front.
        if let pending = app.sessions.pendingAuthorization() { waitForApproval(pending) }
    }

    func connect() {
        let server: ServerAddress
        switch ServerAddress.parse(address, allowLocalHTTP: canUseLocalHTTP && allowLocalHTTP) {
        case let .valid(parsed):
            server = parsed
        case .empty:
            errorMessage = "Enter your server's address."
            return
        case .malformed:
            errorMessage = "That doesn't look like a web address."
            return
        case .cleartextNotAllowed:
            errorMessage = canUseLocalHTTP
                ? "Plain HTTP needs the local-server option, and only works for hosts on your own network."
                : "Shelfarr needs a secure https:// address."
            return
        }

        errorMessage = nil
        phase = .connecting
        Task {
            do {
                let grant = try await app.api.startDeviceAuthorization(server: server, clientName: "Shelfarr iOS")
                let pending = PendingAuthorization(
                    server: server,
                    grant: grant,
                    expiresAt: Date().addingTimeInterval(TimeInterval(grant.expiresIn))
                )
                app.sessions.savePendingAuthorization(pending)
                waitForApproval(pending)
                browserRequest = browserURL(pending)
            } catch {
                phase = .enterServer
                errorMessage = message(error, server)
            }
        }
    }

    func browserURL(_ pending: PendingAuthorization) -> URL? {
        pending.server.resolve(pending.grant.verificationUriComplete)
    }

    func verificationAddress(_ pending: PendingAuthorization) -> String {
        pending.server.resolve(pending.grant.verificationUri)?.absoluteString ?? pending.grant.verificationUri
    }

    private func waitForApproval(_ pending: PendingAuthorization) {
        polling?.cancel()
        countdown?.cancel()
        address = pending.server.display
        phase = .authorizing(pending)
        secondsLeft = max(Int(pending.expiresAt.timeIntervalSinceNow), 0)

        countdown = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.secondsLeft = max(Int(pending.expiresAt.timeIntervalSinceNow), 0)
            }
        }

        let api = app.api
        let authorizer = DeviceAuthorizer(exchange: { try await api.exchangeDeviceCode(server: $0, deviceCode: $1) })
        polling = Task { [weak self] in
            do {
                let outcome = try await authorizer.await(pending)
                self?.countdown?.cancel()
                switch outcome {
                case let .approved(token): await self?.finish(pending.server, token.accessToken)
                case .denied: self?.end(pending.server, denied: true)
                case .expired: self?.end(pending.server, denied: false)
                }
            } catch is CancellationError {
                return
            } catch {
                self?.countdown?.cancel()
                self?.app.sessions.clearPendingAuthorization()
                self?.phase = .enterServer
                self?.errorMessage = self?.message(error, pending.server)
            }
        }
    }

    private func finish(_ server: ServerAddress, _ token: String) async {
        app.sessions.useProvisional(Credential(server: server, accessToken: token))
        do {
            let user = try await app.api.me(server: server)
            app.sessions.signIn(Session(server: server, user: user, accessToken: token))
        } catch {
            app.sessions.useProvisional(nil)
            app.sessions.clearPendingAuthorization()
            phase = .enterServer
            errorMessage = message(error, server)
        }
    }

    private func end(_ server: ServerAddress, denied: Bool) {
        app.sessions.clearPendingAuthorization()
        phase = .ended(server, denied: denied)
    }

    func cancel() {
        polling?.cancel()
        countdown?.cancel()
        app.sessions.clearPendingAuthorization()
        phase = .enterServer
    }

    private func message(_ error: Error, _ server: ServerAddress) -> String {
        switch error as? APIError {
        case .notFound: return "\(server.host) answered, but doesn't offer the reading API. It may need updating."
        case .protocolError: return "\(server.host) doesn't look like a Shelfarr server."
        case let .redirectBlocked(location): return "\(server.host) redirects to \(location). Use that address instead."
        case .offline(certificate: true): return "The security certificate for \(server.host) couldn't be trusted."
        case .offline: return "Couldn't reach \(server.host). Check the address and your connection."
        case let .server(status): return "\(server.host) had a problem (error \(status)). Try again in a moment."
        default: return "Couldn't connect to \(server.host)."
        }
    }
}

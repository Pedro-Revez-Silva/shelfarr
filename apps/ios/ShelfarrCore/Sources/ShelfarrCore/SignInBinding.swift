import Foundation

/// The credential of one sign-in, for the services built for it: progress sync,
/// downloads, streaming and loads that are already running.
///
/// It follows that sign-in's token when requesting is added in place
/// (`SessionManager.replaceToken`), so nothing has to restart, and it gives nothing once
/// the sign-in has ended: after any other sign-in, an expiry or a sign-out, work bound
/// here can't send a token, so it can never borrow another account's or sign-in's.
public struct SignInBinding: Sendable {
    /// The session these services were built for. Its token may have been replaced since.
    public let session: Session
    private let sessions: SessionManager

    public init(session: Session, sessions: SessionManager) {
        self.session = session
        self.sessions = sessions
    }

    /// The live session while this sign-in lasts, with any token handed over in place.
    public var live: Session? { sessions.continuing(session) }

    public var isLive: Bool { live != nil }

    public var credential: Credential? {
        live.map { Credential(server: $0.server, accessToken: $0.accessToken) }
    }

    /// `DownloadManager.credentialTag` of the live token, for `DownloadManager`'s
    /// `currentCredential`; empty, matching no transfer, once the sign-in has ended.
    public var credentialTag: String {
        live.map { DownloadManager.credentialTag($0.accessToken) } ?? ""
    }

    /// A client for this sign-in. A request refused because its token was replaced while
    /// it was out is sent once more with the replacement; only a refusal of the token in
    /// use ends the sign-in.
    public func api(transport: HTTPTransport) -> ConsumerAPI {
        let sessions = self.sessions, session = self.session
        return ConsumerAPI(
            transport: transport,
            credential: { sessions.continuing(session).map { Credential(server: $0.server, accessToken: $0.accessToken) } },
            onRejected: { sessions.markExpired($0) },
            replaysAfterHandover: true
        )
    }

    /// The server refused the credential tagged `refused`. Ends the sign-in only when that
    /// is still the token in use, never for one that was handed over before the answer came.
    public func refused(_ refused: String) {
        guard let live, DownloadManager.credentialTag(live.accessToken) == refused else { return }
        // `markExpired` checks the token again, so a handover in between changes nothing.
        sessions.markExpired(Credential(server: live.server, accessToken: live.accessToken))
    }
}

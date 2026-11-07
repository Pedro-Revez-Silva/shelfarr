import Foundation

/// Progress work belongs to the session that created it, including retries.
public enum SessionProgressRemote {
    public static func bind(session: Session, sessions: SessionManager, transport: HTTPTransport) -> ProgressSync.Remote {
        let credential = Credential(server: session.server, accessToken: session.accessToken)
        let api = ConsumerAPI(transport: transport, credential: { credential }, onRejected: { sessions.markExpired($0) })
        return { publicationId, update in
            guard sessions.signedIn == session else { throw APIError.unauthorized }
            return try await api.saveProgress(server: session.server, publicationId: publicationId, update: update)
        }
    }
}

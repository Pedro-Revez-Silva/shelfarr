import Foundation

/// Progress work belongs to the sign-in that created it, including retries. It follows
/// that sign-in's token when requesting is added in place, and stops at any other
/// sign-in, an expiry or a sign-out.
public enum SessionProgressRemote {
    public static func bind(session: Session, sessions: SessionManager, transport: HTTPTransport) -> ProgressSync.Remote {
        bind(SignInBinding(session: session, sessions: sessions), transport: transport)
    }

    public static func bind(_ binding: SignInBinding, transport: HTTPTransport) -> ProgressSync.Remote {
        let api = binding.api(transport: transport)
        let server = binding.session.server
        return { publicationId, update in
            guard binding.isLive else { throw APIError.unauthorized }
            return try await api.saveProgress(server: server, publicationId: publicationId, update: update)
        }
    }
}

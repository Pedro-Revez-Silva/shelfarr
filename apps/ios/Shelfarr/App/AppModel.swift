import Foundation
import ShelfarrCore
import SwiftUI

/// The app's dependency graph and session state.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: SessionState
    @Published var appearance: AppearanceMode {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey) }
    }

    /// Bumped when a reader or player closes, so progress on screen stays current.
    @Published var libraryGeneration = 0

    let sessions: SessionManager
    let transport: URLSessionTransport
    let api: ConsumerAPI
    let epubCache: EpubCache
    let playback = PlaybackEngine()
    let readerSettings = ReaderSettingsStore()

    private var registry: ProgressRegistry?
    private var registrySession: Session?

    private static let appearanceKey = "appearance"

    init() {
        let sessions = SessionManager(store: KeychainStore())
        let transport = URLSessionTransport(credential: { sessions.credential() })
        let api = ConsumerAPI(
            transport: transport,
            credential: { sessions.credential() },
            onRejected: { sessions.markExpired($0) }
        )
        self.sessions = sessions
        self.transport = transport
        self.api = api
        state = sessions.state
        appearance = AppearanceMode(rawValue: UserDefaults.standard.integer(forKey: Self.appearanceKey)) ?? .system

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        epubCache = EpubCache(
            root: caches.appendingPathComponent("epub", isDirectory: true),
            transport: transport,
            authorize: { api.authorized($0) }
        )

        sessions.onChange = { [weak self] _ in
            Task { @MainActor in self?.apply() }
        }
    }

    private func apply() {
        let newState = sessions.state
        let changed = state != newState
        state = newState
        guard changed else { return }
        let previous = registry
        registry = nil
        registrySession = nil
        Task {
            await playback.stop()
            await previous?.stopAll()
        }
    }

    var session: Session? {
        sessions.signedIn
    }

    private func accountDirectory(_ session: Session) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("accounts/\(session.accountKey)", isDirectory: true)
    }

    func api(for session: Session) -> ConsumerAPI {
        let credential = Credential(server: session.server, accessToken: session.accessToken)
        return ConsumerAPI(transport: transport, credential: { credential }, onRejected: { [sessions] in sessions.markExpired($0) })
    }

    func publications(for session: Session) -> AccountPublications {
        AccountPublications(directory: accountDirectory(session).appendingPathComponent("publications", isDirectory: true))
    }

    /// Live progress sync for the signed-in account. Accounts never share a store.
    func progressRegistry() -> ProgressRegistry? {
        guard let session else { return nil }
        if registrySession == session, let registry { return registry }
        if let previous = registry { Task { await previous.stopAll() } }
        let store = FileProgressStore(file: accountDirectory(session).appendingPathComponent("progress.json"))
        let created = ProgressRegistry(store: store, remote: SessionProgressRemote.bind(
            session: session, sessions: sessions, transport: transport
        ))
        registry = created
        registrySession = session
        return created
    }

    func onForeground() {
        guard let session, let registry = progressRegistry() else { return }
        let api = self.api(for: session)
        Task {
            await registry.flushAll()
            // Validates the token; a 401 flows through `onRejected`.
            _ = try? await api.me(server: session.server)
        }
    }

    func onBackground() {
        guard let registry = progressRegistry() else { return }
        Task { await registry.flushAll() }
    }

    /// Disconnects this device: last sync, server-side revoke, then every local trace.
    /// Local cleanup happens whether or not the server could be reached.
    func disconnect() async {
        guard let session else {
            sessions.clear()
            return
        }
        await playback.stop()
        let registry = progressRegistry()
        let api = self.api(for: session)
        let network = Task {
            await registry?.flushAll()
            try? await api.revoke(server: session.server)
        }
        let timeout = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            network.cancel()
        }
        await network.value
        timeout.cancel()

        await registry?.stopAll()
        self.registry = nil
        registrySession = nil
        sessions.clear()
        await epubCache.clear(accountKey: session.accountKey)
        try? FileManager.default.removeItem(at: accountDirectory(session))
        CoverLoader.clearCache()
    }
}

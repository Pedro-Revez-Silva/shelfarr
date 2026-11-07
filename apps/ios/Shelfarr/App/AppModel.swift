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
    private var registryKey: String?

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

        sessions.onChange = { [weak self] state in
            Task { @MainActor in self?.apply(state) }
        }
    }

    private func apply(_ newState: SessionState) {
        state = newState
        if case .signedIn = newState { return }
        // Streams can't continue without a session, so don't leave a dead player behind.
        Task { await playback.stop() }
    }

    var session: Session? {
        if case let .signedIn(session) = state { return session }
        return nil
    }

    private func accountDirectory(_ session: Session) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("accounts/\(session.accountKey)", isDirectory: true)
    }

    /// Live progress sync for the signed-in account. Accounts never share a store.
    func progressRegistry() -> ProgressRegistry? {
        guard let session else { return nil }
        if registryKey == session.accountKey, let registry { return registry }
        let store = FileProgressStore(file: accountDirectory(session).appendingPathComponent("progress.json"))
        let api = self.api
        let server = session.server
        let created = ProgressRegistry(store: store) { id, update in
            try await api.saveProgress(server: server, publicationId: id, update: update)
        }
        registry = created
        registryKey = session.accountKey
        return created
    }

    func onForeground() {
        guard let session, let registry = progressRegistry() else { return }
        let api = self.api
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
        let api = self.api
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

        self.registry = nil
        registryKey = nil
        sessions.clear()
        await epubCache.clear(accountKey: session.accountKey)
        try? FileManager.default.removeItem(at: accountDirectory(session))
        CoverLoader.clearCache()
    }
}

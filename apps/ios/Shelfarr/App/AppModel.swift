import Foundation
import ShelfarrCore
import SwiftUI

/// The app's dependency graph and session state.
@MainActor
final class AppModel: ObservableObject {
    /// One per process, created at launch, including a background relaunch with no UI.
    static let shared = AppModel()

    @Published private(set) var state: SessionState
    @Published var appearance: AppearanceMode {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey) }
    }

    /// Bumped after reading, listening or status changes, so the library stays current.
    @Published var libraryGeneration = 0

    let sessions: SessionManager
    let transport: URLSessionTransport
    let api: ConsumerAPI
    let epubCache: EpubCache
    let playback = PlaybackEngine()
    let readerSettings = ReaderSettingsStore()
    let downloads = DownloadsModel()
    let transferRouter: TransferRouter
    let backgroundDownloads: BackgroundDownloadSession
    /// Runs grant-less transfers in this process, behind the transport's redirect checks.
    let foregroundDownloads: InProcessDownloadExecutor

    private var registry: ProgressRegistry?
    private var registrySession: Session?
    private var downloadManager: DownloadManager?
    private var downloadSession: Session?
    private var libraryCaches: [String: LibraryCache] = [:]

    private static let appearanceKey = "appearance"

    private init() {
        #if DEBUG
        let store: SecretStore = UITestFixture.secretStore() ?? KeychainStore()
        #else
        let store: SecretStore = KeychainStore()
        #endif
        let sessions = SessionManager(store: store)
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
        let router = TransferRouter()
        transferRouter = router
        backgroundDownloads = BackgroundDownloadSession(router: router)
        foregroundDownloads = InProcessDownloadExecutor(
            transport: transport,
            router: router,
            scratch: FileManager.default.temporaryDirectory.appendingPathComponent("downloads", isDirectory: true)
        )
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
        // Resume this account's unfinished downloads at launch. Its manager is connected to
        // the router before the background session exists, so no early callback is dropped.
        if sessions.signedIn != nil { _ = downloadsForSession() }
        backgroundDownloads.activate()
    }

    private func apply() {
        let newState = sessions.state
        let changed = state != newState
        state = newState
        guard changed else { return }
        let previous = registry
        registry = nil
        registrySession = nil
        let previousDownloads = downloadManager
        downloadManager = nil
        downloadSession = nil
        Task {
            await playback.stop()
            await previous?.stopAll()
            await previousDownloads?.close()
            await downloads.attach(nil)
            // A signed-in account resumes its own queue; an expired one keeps its files.
            if sessions.signedIn != nil { _ = downloadsForSession() }
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
        AccountPublications(
            directory: accountDirectory(session).appendingPathComponent("publications", isDirectory: true),
            cache: libraryCache(for: session)
        )
    }

    /// Titles this account has seen, for browsing offline. One per account, never shared.
    func libraryCache(for session: Session) -> LibraryCache {
        if let cache = libraryCaches[session.accountKey] { return cache }
        let directory = accountDirectory(session)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = LibraryCache(file: directory.appendingPathComponent("library-cache.json"))
        libraryCaches[session.accountKey] = cache
        return cache
    }

    /// Keeps a status change or other fresh copy for offline browsing.
    func remember(_ publication: ShelfarrCore.Publication, for session: Session) {
        let cache = libraryCache(for: session)
        let seen = Date()
        Task { await cache.record([publication], seenAt: seen) }
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

    /// Managed downloads for the signed-in account, bound to its own credential.
    func downloadsForSession() -> DownloadManager? {
        guard let session else { return nil }
        if downloadSession == session, let downloadManager { return downloadManager }
        let previous = downloadManager
        let api = self.api(for: session)
        let sessions = self.sessions
        let root = accountDirectory(session).appendingPathComponent("downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var excluded = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        let manager = DownloadManager(
            root: root,
            account: session.accountKey,
            credential: DownloadManager.credentialTag(session.accessToken),
            transport: transport,
            executors: DownloadExecutors(
                foreground: foregroundDownloads,
                background: backgroundDownloads,
                mintGrant: { publicationId, assetId in
                    guard sessions.signedIn == session else { throw CancellationError() }
                    return try await api.transferGrant(server: session.server, publicationId: publicationId, assetId: assetId)
                }
            ),
            router: transferRouter,
            server: session.server,
            authorize: { api.authorized($0) },
            fetchPublication: { id in
                guard sessions.signedIn == session else { throw APIError.unauthorized }
                return try await api.publication(server: session.server, id: id)
            },
            usableSpace: {
                let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                return values?.volumeAvailableCapacityForImportantUsage
            },
            onUnauthorized: { sessions.markExpired(Credential(server: session.server, accessToken: session.accessToken)) }
        )
        // Before anything can deliver this account's events.
        manager.connect()
        downloadManager = manager
        downloadSession = session
        let model = downloads
        Task {
            // The next account's transfers wait until the previous ones have stopped.
            await previous?.close()
            await manager.start()
            await model.attach(manager)
        }
        return manager
    }

    /// Best effort: an explicit Read or Listen marks an unread publication in progress.
    /// It never blocks opening, and never changes a finished status.
    func markStarted(_ publication: ShelfarrCore.Publication) {
        guard publication.status == .unread, let session else { return }
        let api = self.api(for: session)
        Task { _ = try? await api.setReadingStatus(server: session.server, publicationId: publication.id, status: .inProgress) }
    }

    func onForeground() {
        guard let session, let registry = progressRegistry() else { return }
        let api = self.api(for: session)
        let manager = downloadsForSession()
        Task {
            await manager?.retryInterrupted()
            await registry.flushAll()
            // Validates the token; a 401 flows through `onRejected`.
            _ = try? await api.me(server: session.server)
        }
    }

    func onBackground() {
        // The place being listened to is saved at once, not at the next checkpoint.
        playback.checkpointNow()
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
        // Stop every transfer before the account's files are deleted.
        await downloadManager?.close()
        downloadManager = nil
        downloadSession = nil
        await downloads.attach(nil)
        sessions.clear()
        await epubCache.clear(accountKey: session.accountKey)
        // No late write may recreate the account folder.
        await libraryCaches.removeValue(forKey: session.accountKey)?.close()
        try? FileManager.default.removeItem(at: accountDirectory(session))
        CoverLoader.clearCache()
    }
}

/// Publishes one account's download records for SwiftUI.
@MainActor
final class DownloadsModel: ObservableObject {
    @Published private(set) var records: [String: DownloadRecord] = [:]
    private(set) var manager: DownloadManager?
    private var observation: UUID?

    func attach(_ manager: DownloadManager?) async {
        if let previous = self.manager, let observation { await previous.stopObserving(observation) }
        self.manager = manager
        observation = nil
        records = [:]
        guard let manager else { return }
        observation = await manager.observe { [weak self] records in
            Task { @MainActor in
                guard let self, self.manager === manager else { return }
                self.records = records
            }
        }
    }

    var ready: [ShelfarrCore.Publication] {
        records.values.filter(\.isReady).sorted { $0.updatedAt > $1.updatedAt }.map(\.publication)
    }

    func enqueue(_ publication: ShelfarrCore.Publication) {
        guard let manager else { return }
        Task { await manager.enqueue(publication) }
    }

    func cancel(_ id: String) {
        guard let manager else { return }
        Task { await manager.cancel(id) }
    }

    func remove(_ id: String) {
        guard let manager else { return }
        Task { await manager.remove(id) }
    }

    func retry(_ id: String) {
        guard let manager else { return }
        Task { await manager.retry(id) }
    }
}

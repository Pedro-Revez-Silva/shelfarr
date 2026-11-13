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
    let pageLayouts = PageLayoutStore()
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
        // Follows whoever is signed in. A refusal is replayed only for the sign-in that held
        // the refused token, with the replacement it was handed over to.
        let api = ConsumerAPI(
            transport: transport,
            credential: { sessions.credential() },
            onRejected: { sessions.markExpired($0) },
            resolveRefusal: { await sessions.resolveRefusal(of: $0) }
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
        // A replacement token left unconfirmed by an earlier launch is checked with exactly
        // that token, before the old one's first refusal can end the sign-in.
        sessions.useCandidateCheck { credential in
            try await ConsumerAPI(transport: transport, credential: { credential }).me(server: credential.server)
        }
        // Resume this account's unfinished downloads at launch. Its manager is connected to
        // the router before the background session exists, so no early callback is dropped.
        if sessions.signedIn != nil { _ = downloadsForSession() }
        backgroundDownloads.activate()
        if let session = sessions.signedIn, sessions.hasPendingHandover(for: session) {
            // Confirms it now rather than at the first refusal.
            _ = requesting
        }
    }

    /// Narration kept with downloads, and what readers need to read along.
    lazy var readAlong = ReadAlongService(app: self)

    /// Adding the opt-in requesting permission to this connection, in place.
    lazy var requesting: RequestingAccess = {
        let transport = self.transport
        let access = RequestingAccess(
            backend: RequestingBackend(
                sessions: sessions,
                api: api,
                apiFor: { credential in ConsumerAPI(transport: transport, credential: { credential }) }
            ),
            clientName: "Shelfarr iOS"
        )
        if let session = sessions.signedIn { access.resume(session) }
        return access
    }()

    private func apply() {
        let newState = sessions.state
        let changed = state != newState
        let previousState = state
        state = newState
        guard changed else { return }
        if case let .signedIn(before) = previousState, case .signedIn = newState, sessions.continuing(before) != nil {
            // The same sign-in goes on: fresher details, or requesting added in place with a
            // new token for this account. Playback, an open book, unsent places and downloads
            // all read the live credential through `sessions.continuing`, so nothing restarts.
            return
        }
        // Narration work for the previous sign-in stops before anything else can resume.
        readAlong.endPreparations()
        if sessions.signedIn == nil { requesting.detach() }
        let previous = registry
        registry = nil
        registrySession = nil
        let previousDownloads = downloadManager
        downloadManager = nil
        downloadSession = nil
        Task {
            await playback.stop()
            await readAlong.close()
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

    /// Whether `session` is still the live sign-in, perhaps with a token handed over in place.
    func isCurrent(_ session: Session?) -> Bool {
        session.flatMap(sessions.continuing) != nil
    }

    /// The account's own folder; deleted on sign-out.
    func accountFolder(_ session: Session) -> URL {
        accountDirectory(session)
    }

    private func accountDirectory(_ session: Session) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("accounts/\(session.accountKey)", isDirectory: true)
    }

    /// A client for `session`'s sign-in. It follows a token handed over in place (so a
    /// stream or a load that is already running keeps working) and sends nothing once
    /// that sign-in has ended, so it can never carry another account's token.
    func api(for session: Session) -> ConsumerAPI {
        SignInBinding(session: session, sessions: sessions).api(transport: transport)
    }

    /// Runs `work`, which sends `session`'s token on its own (`api(for:).authorized`), once
    /// more when the server refused that token because it was being handed over to a
    /// replacement. Any other refusal is rethrown as it was.
    func followingHandover<T>(_ session: Session, _ work: () async throws -> T) async throws -> T {
        let sent = sessions.continuing(session)
        do {
            return try await work()
        } catch APIError.unauthorized {
            guard let sent else { throw APIError.unauthorized }
            switch await sessions.resolveRefusal(of: Credential(server: sent.server, accessToken: sent.accessToken), signIn: session) {
            case .replay: return try await work()
            case .unconfirmed: throw APIError.offline(certificate: false)
            case .ended: throw APIError.unauthorized
            }
        }
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
        if let registrySession, isCurrent(registrySession), let registry { return registry }
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
        if let downloadSession, isCurrent(downloadSession), let downloadManager { return downloadManager }
        let previous = downloadManager
        let binding = SignInBinding(session: session, sessions: sessions)
        let api = binding.api(transport: transport)
        let root = accountDirectory(session).appendingPathComponent("downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var excluded = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        let manager = DownloadManager(
            root: root,
            account: session.accountKey,
            // The live token's tag: it changes when requesting is added in place, at the
            // same moment `api` starts sending the new token.
            currentCredential: { binding.credentialTag },
            transport: transport,
            executors: DownloadExecutors(
                foreground: foregroundDownloads,
                background: backgroundDownloads,
                mintGrant: { publicationId, assetId in
                    guard binding.isLive else { throw CancellationError() }
                    return try await api.transferGrant(server: session.server, publicationId: publicationId, assetId: assetId)
                }
            ),
            router: transferRouter,
            server: session.server,
            authorize: { api.authorized($0) },
            fetchPublication: { id in
                guard binding.isLive else { throw APIError.unauthorized }
                return try await api.publication(server: session.server, id: id)
            },
            usableSpace: {
                let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                return values?.volumeAvailableCapacityForImportantUsage
            },
            // Only a refusal of the token in use now signs out; an earlier token's late refusals are replanned.
            onUnauthorized: { binding.refused($0) },
            // One refused while its replacement is being confirmed waits, then continues with it.
            resolveRefusal: { await binding.resolveRefusal($0) }
        )
        // Before anything can deliver this account's events.
        manager.connect()
        downloadManager = manager
        downloadSession = session
        let model = downloads
        let readAlong = self.readAlong
        model.onRecords = { [weak readAlong] in readAlong?.reconcile($0) }
        model.onEnqueue = { [weak readAlong] in readAlong?.downloadRequested($0, format: $1) }
        model.onCancel = { [weak readAlong] in readAlong?.downloadCancelled($0) }
        model.onRemove = { [weak readAlong] in readAlong?.downloadRemoved($0) }
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
        // No narration work for this account writes or queues anything from now on.
        readAlong.endPreparations()
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
        await readAlong.close()
        sessions.clear()
        await epubCache.clear(accountKey: session.accountKey)
        pageLayouts.forget(accountKey: session.accountKey)
        // No late write may recreate the account folder.
        await libraryCaches.removeValue(forKey: session.accountKey)?.close()
        try? FileManager.default.removeItem(at: accountDirectory(session))
        CoverLoader.clearCache()
    }
}

/// Publishes one account's download records for SwiftUI.
@MainActor
final class DownloadsModel: ObservableObject {
    @Published private(set) var records: [String: DownloadRecord] = [:] {
        didSet { onRecords?(records) }
    }
    private(set) var manager: DownloadManager?
    private var observation: UUID?
    /// Read-along follows downloads: their states, and what the user asks for, cancels and
    /// removes. Each is told synchronously, before the manager acts, so narration work for
    /// a stopped download stops first.
    var onRecords: (@MainActor ([String: DownloadRecord]) -> Void)?
    var onEnqueue: (@MainActor (ShelfarrCore.Publication, ReaderFormat?) -> Void)?
    var onCancel: (@MainActor (String) -> Void)?
    var onRemove: (@MainActor (String) -> Void)?

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

    /// A book's download holds one format; without one it keeps the format it has.
    func enqueue(_ publication: ShelfarrCore.Publication, format: ReaderFormat? = nil) {
        guard let manager else { return }
        Task { await manager.enqueue(publication, format: format) }
        onEnqueue?(publication, format ?? records[publication.id]?.readerFormat)
    }

    func cancel(_ id: String) {
        guard let manager else { return }
        onCancel?(id)
        Task { await manager.cancel(id) }
    }

    func remove(_ id: String) {
        guard let manager else { return }
        onRemove?(id)
        Task { await manager.remove(id) }
    }

    /// Retrying is asking for the download again, with the details and format it has.
    func retry(_ id: String) {
        guard let manager else { return }
        Task { await manager.retry(id) }
        if let record = records[id] { onEnqueue?(record.publication, record.readerFormat) }
    }
}

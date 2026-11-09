import Foundation
import ShelfarrCore

/// What this device can do with a book's narration now, for the details screen.
enum NarrationStatus: Equatable {
    /// Downloaded: the manifest and every audio file for one generation are here.
    case onDevice
    /// Being prepared for offline use (the manifest, copying audio, or the audiobook download).
    case preparing(String)
    /// The download has the book but not (all of) its narration; trying again may fix it.
    case missing(String)
}

/// Read-along for the signed-in account: the narration kept with downloads, and what a
/// reader needs to open a book with its narration.
///
/// Durable bundles live in the account's folder (`accounts/<key>/read-along`) and are
/// deleted with it. An imported alignment's audio is the paired audiobook's ordinary
/// download, so it uses the same transfer grants, background session and offline rules
/// as any audiobook. A media overlay's audio is copied out of the downloaded EPUB.
@MainActor
final class ReadAlongService: ObservableObject {
    /// Per publication, while it has a download.
    @Published private(set) var status: [String: NarrationStatus] = [:]

    private unowned let app: AppModel
    private var library: ReadAlongLibrary?
    private var librarySession: Session?
    /// The account's narration work: one owned preparation per book download, stopped
    /// with that download (cancel, remove, another format or edition) or the account.
    private var preparations = ReadAlongPreparations()
    /// Books whose new download state is being followed up, so a burst of updates starts one job each.
    private var reconciling: Set<String> = []
    private var lastStates: [String: DownloadState] = [:]

    init(app: AppModel) {
        self.app = app
    }

    func library(for session: Session) -> ReadAlongLibrary {
        if let library, let librarySession, librarySession.accountKey == session.accountKey { return library }
        let folder = app.accountFolder(session).appendingPathComponent("read-along", isDirectory: true)
        preparations.end()
        // Which paired audiobooks a book's download queued outlives the process, like the downloads.
        let preparations = ReadAlongPreparations(storage: folder.appendingPathComponent("companions.json"))
        self.preparations = preparations
        let created = ReadAlongLibrary(root: folder)
        library = created
        librarySession = session
        status = [:]
        reconciling = []
        lastStates = [:]
        if let downloads = app.downloadsForSession() {
            // Cancels what a Cancel or Remove cut short by the app ending had released.
            Task { await preparations.resumeReleases(downloads: downloads) }
        }
        return created
    }

    /// The sign-in changed or ended: nothing started for it may write, report or queue
    /// anything from now on. Called at once, before `close`.
    func endPreparations() {
        preparations.end()
    }

    /// Stops writing before the account's folder is deleted.
    func close() async {
        preparations.end()
        await library?.close()
        library = nil
        librarySession = nil
        preparations = ReadAlongPreparations()
        status = [:]
        reconciling = []
        lastStates = [:]
    }

    // MARK: Downloads

    /// The user asked for a download of `publication` (or to retry one). For a read-along
    /// EPUB its narration is prepared too: the manifest, and for an imported alignment the
    /// paired audiobook's own download. Any other format replaces the EPUB, and its
    /// narration work stops.
    func downloadRequested(_ publication: ShelfarrCore.Publication, format: ReaderFormat?) {
        guard let session = app.session else { return }
        _ = library(for: session)
        // What the user downloads is theirs: an audiobook they asked for is never cancelled with a book.
        preparations.userRequested(publication.id)
        guard publication.bookType == .ebook else { return }
        guard (format ?? .epub) == .epub, let asset = publication.asset(for: .epub), asset.readAlong?.isAvailable == true else {
            stop(publication.id, removing: false)
            return
        }
        start(publication, asset: asset, session: session)
    }

    /// The download was cancelled: its narration work stops now, what it stored but never
    /// made current is deleted (a usable earlier generation stays for a later download),
    /// and an audiobook it queued that nothing else uses is cancelled while still transferring.
    func downloadCancelled(_ publicationId: String) {
        guard let session = app.session else { return }
        _ = library(for: session)
        preparations.userStopped(publicationId)
        stop(publicationId, removing: false)
    }

    /// The download was removed: its narration goes with it (an audiobook the user
    /// downloaded, or one already complete, stays its own download).
    func downloadRemoved(_ publicationId: String) {
        guard let session = app.session else { return }
        _ = library(for: session)
        preparations.userStopped(publicationId)
        stop(publicationId, removing: true)
    }

    private func stop(_ publicationId: String, removing: Bool) {
        guard let session = app.session else { return }
        status[publicationId] = nil
        preparations.stopped(publicationId, removing: removing, library: library(for: session), downloads: app.downloadsForSession())
    }

    /// Prepares `asset`'s current generation for its download and waits for it. The
    /// previous generation stays in use until the new one is complete.
    func prepare(_ publication: ShelfarrCore.Publication, asset: ShelfarrCore.Asset, session: Session) async {
        await start(publication, asset: asset, session: session)?.value
    }

    /// Starts the owned preparation, or returns the one already running for this edition
    /// and generation. One for an older generation or edition is superseded.
    @discardableResult
    private func start(_ publication: ShelfarrCore.Publication, asset: ShelfarrCore.Asset, session: Session) -> Task<Void, Never>? {
        guard let summary = asset.readAlong, summary.isAvailable, app.isCurrent(session) else { return nil }
        let library = library(for: session)
        let preparations = self.preparations
        let downloads = app.downloadsForSession()
        return preparations.launch(publication.id, key: "\(asset.id)/\(summary.generation ?? "")") { [weak self] ticket in
            await self?.run(ticket, publication: publication, asset: asset, summary: summary, session: session,
                            library: library, preparations: preparations, downloads: downloads)
        }
    }

    private func run(
        _ ticket: ReadAlongPreparations.Ticket, publication: ShelfarrCore.Publication, asset: ShelfarrCore.Asset, summary: ReadAlongSummary,
        session: Session, library: ReadAlongLibrary, preparations: ReadAlongPreparations, downloads: DownloadManager?
    ) async {
        guard app.isCurrent(session) else { return }
        report(.preparing("Getting the narration's alignment…"), ticket, preparations)
        let api = app.api(for: session)
        do {
            let stored = try await preparations.store(
                ticket, library: library, downloads: downloads,
                fetchManifest: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.fetchManifest(summary, asset: asset, publication: publication, session: session)
                },
                fetchAudiobook: { id in try await api.publication(server: session.server, id: id) }
            )
            guard let stored else { return }
            await finish(ticket, stored, library: library, preparations: preparations, downloads: downloads)
        } catch {
            report(.missing(Self.message(error)), ticket, preparations)
        }
    }

    /// Sets a book's status only for a preparation still current for this account.
    private func report(_ value: NarrationStatus?, _ ticket: ReadAlongPreparations.Ticket, _ owner: ReadAlongPreparations) {
        guard owner === preparations, owner.isCurrent(ticket) else { return }
        status[ticket.publicationId] = value
    }

    /// Finishes whatever downloaded books' narration still needs: copying overlay audio
    /// out of a ready EPUB, or adopting a generation once its audiobook is downloaded.
    func reconcile(_ records: [String: DownloadRecord]) {
        guard let session = app.session else { return }
        let library = library(for: session)
        let preparations = self.preparations
        let downloads = app.downloadsForSession()
        // Byte progress changes constantly; only a change of state can change narration.
        let states = records.mapValues(\.state)
        let changed = Set(states.filter { lastStates[$0.key] != $0.value }.keys)
        let audiobookChanged = changed.contains { records[$0]?.publication.bookType == .audiobook }
        lastStates = states
        for record in records.values where record.publication.bookType == .ebook && record.readerFormat == .epub
            && (changed.contains(record.publicationId) || audiobookChanged) {
            let id = record.publicationId
            guard let asset = record.publication.asset(for: .epub), record.pinnedAssetIds == [asset.id],
                  !preparations.isPreparing(id), !reconciling.contains(id) else { continue }
            // A cancelled download prepares nothing. Cancel cleaned up after it; this also
            // finishes a cleanup the app ended before (a usable generation stays).
            if record.state == .cancelled {
                status[id] = nil
                if let cleanup = preparations.interruptedCleanup(id) {
                    Task { await preparations.cleanUp(cleanup, removing: false, library: library, downloads: nil) }
                }
                continue
            }
            guard let ticket = preparations.snapshot(id) else { continue }
            reconciling.insert(id)
            Task {
                defer { reconciling.remove(id) }
                guard let stored = await library.latest(id, ebookAssetId: asset.id, server: session.server) else {
                    report(asset.readAlong?.isAvailable == true && record.isReady ? .missing("The narration isn't on this device yet.") : nil, ticket, preparations)
                    return
                }
                guard record.isReady else {
                    report(.preparing("The narration is ready once the book has downloaded."), ticket, preparations)
                    return
                }
                await finish(ticket, stored, library: library, preparations: preparations, downloads: downloads)
            }
        }
        for id in status.keys where records[id] == nil { status[id] = nil }
    }

    private func finish(
        _ ticket: ReadAlongPreparations.Ticket, _ stored: ReadAlongLibrary.Stored, library: ReadAlongLibrary,
        preparations: ReadAlongPreparations, downloads: DownloadManager?
    ) async {
        let outcome = await preparations.complete(ticket, stored: stored, library: library, downloads: downloads, willCopyAudio: { [weak self] in
            await self?.report(.preparing("Preparing the narration from this book…"), ticket, preparations)
        })
        switch outcome {
        case .stale: return
        case .onDevice: report(.onDevice, ticket, preparations)
        case .waitingForBook: report(.preparing("The narration is ready once the book has downloaded."), ticket, preparations)
        case .downloadingAudiobook: report(.preparing("Downloading the audiobook it's aligned with…"), ticket, preparations)
        case .audiobookMissing: report(.missing("The audiobook it's aligned with isn't downloaded."), ticket, preparations)
        case let .failed(failure): report(.missing(Self.message(failure)), ticket, preparations)
        }
    }

    /// The paired audiobook's local files, when its download is ready.
    func audiobookFiles(_ manifest: ReadAlongManifest, session: Session) async -> [String: URL]? {
        guard let id = manifest.audiobookPublicationId, let manager = app.downloadsForSession(), let record = await manager.ready(id) else { return nil }
        return await manager.fileURLs(record)
    }

    // MARK: Reading

    /// What the reader opens with: narration it can play now, or why there is none.
    enum Setup {
        /// Nothing about narration to say (no summary, an older server, not aligned).
        case none
        /// Shown in the reading controls; the book reads as usual.
        case note(String)
        case ready(Narration)
    }

    struct Narration {
        let manifest: ReadAlongManifest
        let tracks: [ReadAlongProgram.Track]
        /// For an imported alignment, the paired audiobook (title, for copy).
        let audiobookTitle: String?
        let fromDevice: Bool
    }

    /// Decides the narration for an EPUB being opened.
    ///
    /// Online, the server's current manifest is used and audio plays from this device's
    /// files when they are this generation's, otherwise streams from the server with the
    /// bearer. Offline, only a complete bundle on this device for the EPUB opened is used.
    func setup(publication: ShelfarrCore.Publication, asset: ShelfarrCore.Asset, offline: Bool, session: Session) async -> Setup {
        let library = library(for: session)
        let summary = asset.readAlong
        let audiobookTitle = summary?.audiobook?.title
        if offline {
            // A complete bundle for exactly this EPUB is internally consistent; use it.
            let files = await libraryAudiobookFiles(library, publication: publication, asset: asset, session: session)
            if case let .ready(stored, audio) = await library.readiness(publication.id, ebookAssetId: asset.id, server: session.server, audiobookFiles: files) {
                return .ready(Narration(manifest: stored.manifest, tracks: tracks(stored.manifest, local: audio, remote: false, session: session),
                                        audiobookTitle: audiobookTitle, fromDevice: true))
            }
            let kept = await library.current(publication.id, ebookAssetId: asset.id, server: session.server)
            if summary?.isAvailable == true || kept != nil {
                return .note(summary?.source == .imported
                    ? "Narration needs your server, or the book and its audiobook downloaded."
                    : "Narration needs your server, or the book downloaded with its narration.")
            }
            return Self.note(for: summary)
        }
        // Online, the server decides: unaligned, stale or invalid read as usual.
        guard let summary, summary.isAvailable else { return Self.note(for: summary) }
        do {
            let fetched = try await fetchManifest(summary, asset: asset, publication: publication, session: session)
            let manifest = fetched.manifest
            // This generation's local audio, when complete; otherwise stream it.
            var local: [URL]?
            let files = await audiobookFiles(manifest, session: session)
            if let stored = await library.stored(publication.id, generation: manifest.generation, ebookAssetId: asset.id, server: session.server),
               case let .ready(_, audio) = ReadAlongLibrary.readiness(stored, audiobookFiles: files) {
                local = audio
            } else if manifest.source == .imported, let files {
                let audio = manifest.audio.compactMap { $0.assetId.flatMap { files[$0] } }
                if audio.count == manifest.audio.count { local = audio }
            }
            if await app.downloadsForSession()?.ready(publication.id) != nil,
               await library.currentGenerationName(publication.id) != manifest.generation {
                // A downloaded book with newer narration: update it; the old one stays until then.
                start(publication, asset: asset, session: session)
            }
            return .ready(Narration(manifest: manifest, tracks: tracks(manifest, local: local, remote: local == nil, session: session),
                                    audiobookTitle: audiobookTitle, fromDevice: local != nil))
        } catch let error as APIError where error.isPlainOffline {
            return await setup(publication: publication, asset: asset, offline: true, session: session)
        } catch {
            return .note("\(Self.message(error)) Reading works as usual.")
        }
    }

    private func libraryAudiobookFiles(_ library: ReadAlongLibrary, publication: ShelfarrCore.Publication, asset: ShelfarrCore.Asset, session: Session) async -> [String: URL]? {
        guard let stored = await library.current(publication.id, ebookAssetId: asset.id, server: session.server) else { return nil }
        return await audiobookFiles(stored.manifest, session: session)
    }

    private func tracks(_ manifest: ReadAlongManifest, local: [URL]?, remote: Bool, session: Session) -> [ReadAlongProgram.Track] {
        manifest.audio.enumerated().map { index, audio in
            let stream = remote ? session.server.resolve(audio.url).flatMap { session.server.contains($0) ? $0 : nil } : nil
            return ReadAlongProgram.Track(key: "read-along:\(index)", local: local?[index], remote: stream)
        }
    }

    private func fetchManifest(_ summary: ReadAlongSummary, asset: ShelfarrCore.Asset, publication: ShelfarrCore.Publication, session: Session) async throws -> (data: Data, manifest: ReadAlongManifest) {
        let api = app.api(for: session)
        let transport = app.transport
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("read-along-\(UUID().uuidString).json")
        return try await app.followingHandover(session) {
            try await ReadAlongFetch.manifest(summary, ebookAssetId: asset.id, publicationId: publication.id, server: session.server,
                                              transport: transport, authorize: { api.authorized($0) }, scratch: scratch)
        }
    }

    static func note(for summary: ReadAlongSummary?) -> Setup {
        guard let summary else { return .none }
        switch summary.status {
        case .available:
            return .note("This book's narration data can't be used. Reading works as usual.")
        case .stale, .invalid:
            return .note("\(summary.reason ?? "This book's narration data can't be used.") Reading works as usual.")
        case .unaligned:
            if let audiobook = summary.audiobook {
                return .note("“\(audiobook.title)” isn't aligned with this text, so read-along isn't available. You can listen to it on its own.")
            }
            return .none
        }
    }

    static func message(_ error: Error) -> String {
        switch error {
        case let error as ReadAlongError:
            switch error {
            case let .unaligned(reason): return reason ?? "Your server has no narration for this edition."
            case let .stale(reason): return reason ?? "This narration was aligned with an earlier file. An administrator can recheck it."
            case let .invalid(reason): return reason ?? "This book's narration data can't be used."
            case .changed: return "This book changed on your server. Open it again to use the current edition."
            case let .unusable(reason): return reason
            }
        case let error as ReadAlongLibrary.Failure:
            switch error {
            case .closed: return "Signed out."
            case .storage: return "Couldn't save the narration on this device. Free some space and try again."
            case let .audio(reason): return reason
            }
        case let error as APIError:
            return error.isPlainOffline ? "Getting the narration needs a connection to your server." : "Couldn't get the narration from your server. Try again."
        default:
            return "Couldn't prepare the narration. Try again."
        }
    }
}

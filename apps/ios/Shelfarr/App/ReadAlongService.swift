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
    /// Bundles being prepared, so a burst of download updates starts one job each.
    private var working: Set<String> = []
    private var lastStates: [String: DownloadState] = [:]

    init(app: AppModel) {
        self.app = app
    }

    func library(for session: Session) -> ReadAlongLibrary {
        if let library, let librarySession, librarySession.accountKey == session.accountKey { return library }
        let created = ReadAlongLibrary(root: app.accountFolder(session).appendingPathComponent("read-along", isDirectory: true))
        library = created
        librarySession = session
        status = [:]
        working = []
        lastStates = [:]
        return created
    }

    /// Stops writing before the account's folder is deleted.
    func close() async {
        await library?.close()
        library = nil
        librarySession = nil
        status = [:]
        working = []
        lastStates = [:]
    }

    // MARK: Downloads

    /// A download of `publication` was requested: fetch and keep its manifest, and for an
    /// imported alignment queue the paired audiobook too. Books without read-along are untouched.
    func downloadRequested(_ publication: ShelfarrCore.Publication, format: ReaderFormat?) {
        guard (format ?? .epub) == .epub, let asset = publication.asset(for: .epub), asset.readAlong?.isAvailable == true,
              let session = app.session
        else { return }
        Task { await prepare(publication, asset: asset, session: session) }
    }

    /// Fetches the manifest for `asset`'s current generation and stores it. The previous
    /// generation stays in use until the new one is complete.
    @discardableResult
    func prepare(_ publication: ShelfarrCore.Publication, asset: ShelfarrCore.Asset, session: Session) async -> ReadAlongManifest? {
        guard let summary = asset.readAlong, summary.isAvailable, app.isCurrent(session), !working.contains(publication.id) else { return nil }
        working.insert(publication.id)
        defer { working.remove(publication.id) }
        status[publication.id] = .preparing("Getting the narration's alignment…")
        let library = library(for: session)
        do {
            let fetched = try await fetchManifest(summary, asset: asset, publication: publication, session: session)
            guard app.isCurrent(session) else { return nil }
            let stored = try await library.save(manifestData: fetched.data, manifest: fetched.manifest, publicationId: publication.id)
            if fetched.manifest.source == .imported, let audiobookId = fetched.manifest.audiobookPublicationId {
                // The paired audiobook downloads like any other: grants, background session, offline rules.
                if let manager = app.downloadsForSession() {
                    let existing = await manager.ready(audiobookId)
                    let covers = existing.map { record in fetched.manifest.audio.allSatisfy { record.pinnedAssetIds.contains($0.assetId ?? "") } } ?? false
                    if !covers {
                        let audiobook = try await app.api(for: session).publication(server: session.server, id: audiobookId)
                        await manager.enqueue(audiobook)
                    }
                }
            }
            await complete(stored, session: session)
            return fetched.manifest
        } catch {
            status[publication.id] = .missing(Self.message(error))
            return nil
        }
    }

    /// Finishes whatever downloaded books' narration still needs: copying overlay audio
    /// out of a ready EPUB, or adopting a generation once its audiobook is downloaded.
    func reconcile(_ records: [String: DownloadRecord]) {
        guard let session = app.session else { return }
        let library = library(for: session)
        // Byte progress changes constantly; only a change of state can change narration.
        let states = records.mapValues(\.state)
        let changed = Set(states.filter { lastStates[$0.key] != $0.value }.keys)
        let audiobookChanged = changed.contains { records[$0]?.publication.bookType == .audiobook }
        lastStates = states
        for record in records.values where record.publication.bookType == .ebook && record.readerFormat == .epub
            && (changed.contains(record.publicationId) || audiobookChanged) {
            guard let asset = record.publication.asset(for: .epub), record.pinnedAssetIds == [asset.id], !working.contains(record.publicationId) else { continue }
            let id = record.publicationId
            working.insert(id)
            Task {
                defer { working.remove(id) }
                guard let stored = await library.latest(id, ebookAssetId: asset.id, server: session.server) else {
                    if asset.readAlong?.isAvailable == true, record.isReady {
                        status[id] = .missing("The narration isn't on this device yet.")
                    } else {
                        status[id] = nil
                    }
                    return
                }
                guard record.isReady else {
                    status[id] = .preparing("The narration is ready once the book has downloaded.")
                    return
                }
                await complete(stored, session: session)
            }
        }
        for id in status.keys where records[id] == nil { status[id] = nil }
    }

    private func complete(_ stored: ReadAlongLibrary.Stored, session: Session) async {
        let library = library(for: session)
        let id = stored.bundle.publicationId
        guard let manager = app.downloadsForSession(), let record = await manager.ready(id),
              let epub = await manager.fileURL(record, assetId: stored.manifest.ebookAssetId)
        else {
            status[id] = .preparing("The narration is ready once the book has downloaded.")
            return
        }
        switch stored.manifest.source {
        case .mediaOverlay:
            if stored.overlayAudio == nil { status[id] = .preparing("Preparing the narration from this book…") }
            do {
                // Streams each narration file out of the EPUB off the main thread.
                _ = try await library.prepareAudio(stored, epub: epub)
                status[id] = .onDevice
            } catch {
                status[id] = .missing(Self.message(error))
            }
        case .imported:
            let files = await audiobookFiles(stored.manifest, session: session)
            if case .ready = ReadAlongLibrary.readiness(stored, audiobookFiles: files) {
                try? await library.promote(stored)
                status[id] = .onDevice
            } else if let audiobookId = stored.manifest.audiobookPublicationId, let audiobook = await manager.record(audiobookId), audiobook.isActive {
                status[id] = .preparing("Downloading the audiobook it's aligned with…")
            } else {
                status[id] = .missing("The audiobook it's aligned with isn't downloaded.")
            }
        }
    }

    /// The paired audiobook's local files, when its download is ready.
    func audiobookFiles(_ manifest: ReadAlongManifest, session: Session) async -> [String: URL]? {
        guard let id = manifest.audiobookPublicationId, let manager = app.downloadsForSession(), let record = await manager.ready(id) else { return nil }
        return await manager.fileURLs(record)
    }

    /// The download was removed: its narration goes with it (the audiobook stays its own download).
    func downloadRemoved(_ publicationId: String) {
        guard let session = app.session else { return }
        let library = library(for: session)
        status[publicationId] = nil
        Task { await library.remove(publicationId) }
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
                Task { await prepare(publication, asset: asset, session: session) }
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

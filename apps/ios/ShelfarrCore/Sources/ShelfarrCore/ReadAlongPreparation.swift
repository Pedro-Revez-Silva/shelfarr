import Foundation

/// What preparing a book's narration needs from its account's downloads. `DownloadManager`
/// is the real one; nothing else decides where download files live or how they transfer.
public protocol ReadAlongDownloads: Sendable {
    func record(_ publicationId: String) async -> DownloadRecord?
    func ready(_ publicationId: String) async -> DownloadRecord?
    func fileURL(_ record: DownloadRecord, assetId: String) async -> URL?
    func fileURLs(_ record: DownloadRecord) async -> [String: URL]?
    func enqueue(_ publication: Publication, format: ReaderFormat?) async
    @discardableResult
    func cancelUnfinished(_ publicationId: String, if allowed: @Sendable () -> Bool) async -> Bool
}

extension DownloadManager: ReadAlongDownloads {}

/// Owns the narration preparation that each ebook download starts, for one account.
///
/// A preparation runs as a task owned here, under a ticket for its book. Cancelling or
/// removing that download, replacing it (another format, edition or generation) or the
/// account ending invalidates the ticket at once and cancels the task. Every step that
/// writes checks the ticket again, synchronously and inside the actor that writes
/// (`ReadAlongLibrary`, `DownloadManager`), so a stopped preparation never stores a
/// manifest, copies audio, makes a generation current, reports a status or queues a
/// transfer once it resumes. Cleanup after invalidation runs on those same actors, so it
/// is ordered after any write that had already passed its check.
///
/// The paired audiobook an imported alignment needs is a companion: queued by the
/// preparation as the audiobook's own ordinary download. A companion a preparation
/// created is cancelled with the book's download only while it is unfinished, no other
/// book uses it, and the user hasn't asked for the audiobook themselves. An audiobook
/// the user downloaded, or one already complete, is never touched.
///
/// Downloads outlive the process, so who owns which companion does too: with a
/// `storage` file (in the account's folder) every change is written before it matters.
/// A claim is on disk before its companion is queued, and a release stays on disk until
/// the companion was cancelled (`resumeReleases` finishes one cut short by a relaunch).
/// A missing file knows nothing, so companions queued before it existed stay ordinary
/// downloads. An unreadable one is moved aside and reported (`storageProblem`): the
/// companions it named are then never cancelled. If the file can't be written it is
/// deleted, so a later launch forgets ownership rather than trusting a stale one.
public final class ReadAlongPreparations: @unchecked Sendable {
    /// Why ownership on disk can't be fully trusted.
    public enum StorageProblem: Equatable, Sendable {
        /// The file couldn't be read or wasn't understood; it was moved aside.
        case unreadable
        /// The latest change couldn't be written.
        case unwritable
    }

    /// One preparation's claim on its book. Stale once invalidated.
    public struct Ticket: Hashable, Sendable {
        public let publicationId: String
        fileprivate let epoch: UInt64
        fileprivate let key: String
    }

    /// Cleanup belongs to the stopped request, even after a later preparation finishes.
    public struct Cleanup: Sendable {
        public let publicationId: String
        fileprivate let epoch: UInt64
        fileprivate let request: Int
        fileprivate let released: [String]
    }

    /// What finishing a stored generation came to.
    public enum Outcome: Equatable, Sendable {
        /// The ticket was invalidated: nothing more was written or reported.
        case stale
        /// The manifest and all its audio are on this device; the generation is current.
        case onDevice
        /// The book itself isn't downloaded yet.
        case waitingForBook
        /// The paired audiobook is still downloading.
        case downloadingAudiobook
        /// The paired audiobook isn't (fully) downloaded and isn't downloading.
        case audiobookMissing
        /// A media overlay's narration couldn't be copied out of the book.
        case failed(ReadAlongLibrary.Failure)
    }

    public typealias Fetched = (data: Data, manifest: ReadAlongManifest)

    private struct Running {
        let ticket: Ticket
        var task: Task<Void, Never>?
    }

    private struct Companion {
        /// Queued by a preparation and never asked for by the user.
        var owned = false
        /// Books whose stored narration uses it.
        var claimants: Set<String> = []
        /// Preparations between deciding to queue it and having queued it.
        var intents: Set<UUID> = []
        var isNeeded: Bool { !claimants.isEmpty || !intents.isEmpty }
    }

    /// One companion as kept on disk.
    private struct StoredCompanion: Codable, Equatable {
        var owned: Bool
        var books: [String]
    }

    private struct StoredState: Codable {
        var version: Int
        var companions: [String: StoredCompanion]
    }

    private static let storageVersion = 1

    private struct Intent {
        let ticket: Ticket
        let audiobookId: String
        let token: UUID
        let requests: Int
    }

    private let lock = NSLock()
    private var ended = false
    private var serial: UInt64 = 0
    private var epochs: [String: UInt64] = [:]
    private var running: [String: Running] = [:]
    private var companions: [String: Companion] = [:]
    /// Bumped whenever the user asks for, cancels or removes a download.
    private var requests: [String: Int] = [:]
    /// Downloads the user asked for and hasn't cancelled or removed since.
    private var wanted: Set<String> = []
    private let storage: URL?
    private var problem: StorageProblem?
    /// Serializes writes, newest last; taken before `lock`, never inside it.
    private let writeLock = NSLock()
    private var queuedWrite: UInt64 = 0
    private var writtenVersion: UInt64 = 0

    /// `storage` keeps companion ownership across launches; nil keeps it in memory.
    public init(storage: URL? = nil) {
        self.storage = storage
        guard let storage, FileManager.default.fileExists(atPath: storage.path) else { return }
        if let data = try? Data(contentsOf: storage),
           let state = try? JSONDecoder().decode(StoredState.self, from: data),
           state.version == Self.storageVersion,
           state.companions.allSatisfy({ !$0.key.isEmpty && !$0.value.books.contains(where: \.isEmpty) }) {
            companions = state.companions.mapValues { Companion(owned: $0.owned, claimants: Set($0.books)) }
        } else {
            // Kept for diagnosis, never trusted: nothing it named is cancelled.
            let aside = storage.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: aside)
            if (try? FileManager.default.moveItem(at: storage, to: aside)) == nil { try? FileManager.default.removeItem(at: storage) }
            problem = .unreadable
        }
    }

    public var storageProblem: StorageProblem? { lock.withLock { problem } }

    /// Runs `body` under the lock and writes companion ownership if it changed.
    private func update<T>(_ body: () -> T) -> T {
        let (result, pending): (T, (StoredState, UInt64)?) = lock.withLock {
            let before = durable()
            let result = body()
            let after = durable()
            guard storage != nil, !ended, after != before else { return (result, nil) }
            queuedWrite += 1
            return (result, (StoredState(version: Self.storageVersion, companions: after), queuedWrite))
        }
        if let pending { write(pending.0, version: pending.1) }
        return result
    }

    private func durable() -> [String: StoredCompanion] {
        companions.compactMapValues { companion in
            companion.owned || !companion.claimants.isEmpty ? StoredCompanion(owned: companion.owned, books: companion.claimants.sorted()) : nil
        }
    }

    private func write(_ state: StoredState, version: UInt64) {
        writeLock.withLock {
            // After `end`, no write may recreate a folder being deleted with the account.
            guard let storage, !lock.withLock({ ended }), version > writtenVersion else { return }
            writtenVersion = version
            do {
                try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(state).write(to: storage, options: .atomic)
                // An unreadable file's ownership stays lost; only a failed write is mended.
                lock.withLock { if problem == .unwritable { problem = nil } }
            } catch {
                // A stale file could name as ours an audiobook the user asked for since; a missing one only forgets.
                try? FileManager.default.removeItem(at: storage)
                lock.withLock { problem = .unwritable }
            }
        }
    }

    // MARK: Tickets

    public func isCurrent(_ ticket: Ticket) -> Bool {
        lock.withLock { current(ticket) }
    }

    private func current(_ ticket: Ticket) -> Bool {
        !ended && (epochs[ticket.publicationId] ?? 0) == ticket.epoch
    }

    public var isEnded: Bool { lock.withLock { ended } }

    /// Whether a preparation for this book is running.
    public func isPreparing(_ publicationId: String) -> Bool {
        lock.withLock { running[publicationId] != nil }
    }

    /// A ticket for work on a book that isn't a preparation of its own (finishing what a
    /// download's new state allows), invalidated like any other. Nil once the account ended.
    public func snapshot(_ publicationId: String) -> Ticket? {
        lock.withLock { ended ? nil : Ticket(publicationId: publicationId, epoch: epochs[publicationId] ?? 0, key: "") }
    }

    /// Starts the owned preparation of `publicationId` for `key` (its edition and
    /// generation). One already running for the same key is kept and its task returned;
    /// one for another key is superseded. Nil once the account ended.
    @discardableResult
    public func launch(_ publicationId: String, key: String, _ work: @escaping @Sendable (Ticket) async -> Void) -> Task<Void, Never>? {
        let (ticket, kept, superseded): (Ticket?, Task<Void, Never>?, Task<Void, Never>?) = lock.withLock {
            guard !ended else { return (nil, nil, nil) }
            var superseded: Task<Void, Never>?
            if let existing = running[publicationId] {
                if existing.ticket.key == key { return (nil, existing.task, nil) }
                superseded = existing.task
            }
            // A completed preparation still supersedes older cleanup. Its identity
            // must survive leaving `running`, including automatic preparations.
            bump(publicationId)
            let ticket = Ticket(publicationId: publicationId, epoch: epochs[publicationId] ?? 0, key: key)
            running[publicationId] = Running(ticket: ticket)
            return (ticket, nil, superseded)
        }
        superseded?.cancel()
        guard let ticket else { return kept }
        let task = Task {
            await work(ticket)
            self.finish(ticket)
        }
        let owned: Bool = lock.withLock {
            guard running[publicationId]?.ticket == ticket else { return false }
            running[publicationId]?.task = task
            return true
        }
        if !owned { task.cancel() }
        return task
    }

    private func finish(_ ticket: Ticket) {
        lock.withLock {
            if running[ticket.publicationId]?.ticket == ticket { running[ticket.publicationId] = nil }
        }
    }

    private func bump(_ publicationId: String) {
        serial += 1
        epochs[publicationId] = serial
    }

    /// The book's download was cancelled, removed or replaced: its preparation stops now.
    /// Returns its identity and companions nothing needs any more, for `cleanUp`.
    @discardableResult
    public func invalidate(_ publicationId: String) -> Cleanup {
        let (task, cleanup): (Task<Void, Never>?, Cleanup) = update {
            bump(publicationId)
            let task = running.removeValue(forKey: publicationId)?.task
            let released = unclaim(publicationId, except: nil)
            return (task, Cleanup(publicationId: publicationId, epoch: epochs[publicationId] ?? 0,
                                  request: requests[publicationId] ?? 0, released: released))
        }
        task?.cancel()
        return cleanup
    }

    /// A persisted cancelled entry may need cleanup interrupted by process death.
    /// Once this launch has seen a request/preparation/stop for it, only that operation's
    /// own cleanup may act; a delayed old records callback cannot bind to the new request.
    public func interruptedCleanup(_ publicationId: String) -> Cleanup? {
        lock.withLock {
            guard !ended, epochs[publicationId] == nil, requests[publicationId] == nil,
                  running[publicationId] == nil else { return nil }
            return Cleanup(publicationId: publicationId, epoch: 0, request: 0, released: [])
        }
    }

    /// The account ended: every preparation stops, and nothing is cancelled for it.
    public func end() {
        let tasks: [Task<Void, Never>] = lock.withLock {
            ended = true
            let tasks = running.values.compactMap(\.task)
            running.removeAll()
            companions.removeAll()
            return tasks
        }
        // Waits out a write in progress; none starts after this.
        writeLock.withLock {}
        tasks.forEach { $0.cancel() }
    }

    // MARK: The user's own downloads

    /// The user asked for this download (or to retry it). As an audiobook, it is theirs from now on.
    public func userRequested(_ publicationId: String) {
        update {
            requests[publicationId, default: 0] += 1
            wanted.insert(publicationId)
            companions[publicationId]?.owned = false
        }
    }

    /// The user cancelled or removed this download themselves.
    public func userStopped(_ publicationId: String) {
        update {
            requests[publicationId, default: 0] += 1
            wanted.remove(publicationId)
            companions[publicationId]?.owned = false
        }
    }

    /// Whether cancelling this companion is still right at this moment.
    public func releasable(_ audiobookId: String) -> Bool {
        lock.withLock { !ended && !wanted.contains(audiobookId) && companions[audiobookId]?.isNeeded != true }
    }

    /// Drops `publicationId`'s claims (but the one on `except`), returning companions
    /// left owned and unneeded. Those stay recorded, unclaimed, until `release` has
    /// cancelled them. Caller holds the lock.
    private func unclaim(_ publicationId: String, except: String?) -> [String] {
        var released: [String] = []
        for (audiobookId, var companion) in companions where audiobookId != except && companion.claimants.contains(publicationId) {
            companion.claimants.remove(publicationId)
            if companion.isNeeded {
                companions[audiobookId] = companion
            } else if companion.owned && !wanted.contains(audiobookId) {
                companions[audiobookId] = companion
                released.append(audiobookId)
            } else {
                companions[audiobookId] = nil
            }
        }
        return released.sorted()
    }

    /// Records the claim of `intent`'s book before its companion is queued, owned when
    /// queueing creates it. False, and nothing is queued, once the ticket is stale.
    private func reserve(_ intent: Intent, created: Bool) -> Bool {
        update {
            guard current(intent.ticket) else { return false }
            let audiobookId = intent.audiobookId
            var companion = companions[audiobookId] ?? Companion()
            if created, (requests[audiobookId] ?? 0) == intent.requests, !wanted.contains(audiobookId) {
                companion.owned = true
            }
            companion.claimants.insert(intent.ticket.publicationId)
            companions[audiobookId] = companion
            return true
        }
    }

    private func intend(_ ticket: Ticket, _ audiobookId: String) -> Intent? {
        lock.withLock {
            guard current(ticket) else { return nil }
            let token = UUID()
            companions[audiobookId, default: Companion()].intents.insert(token)
            return Intent(ticket: ticket, audiobookId: audiobookId, token: token, requests: requests[audiobookId] ?? 0)
        }
    }

    /// Ends an intent; `queued` when `reserve` let it queue the companion. Returns
    /// companions to cancel.
    private func settle(_ intent: Intent, queued: Bool) -> [String] {
        update {
            let audiobookId = intent.audiobookId
            var companion = companions[audiobookId] ?? Companion()
            companion.intents.remove(intent.token)
            if queued, current(intent.ticket) {
                companions[audiobookId] = companion
                // This book's narration now uses only this audiobook.
                return unclaim(intent.ticket.publicationId, except: audiobookId)
            }
            if companion.isNeeded {
                companions[audiobookId] = companion
                return []
            }
            if companion.owned, !wanted.contains(audiobookId), !ended {
                companions[audiobookId] = companion
                return [audiobookId]
            }
            companions[audiobookId] = nil
            return []
        }
    }

    /// A release has been carried out (or wasn't needed after all): forgets the companion
    /// unless something uses it again.
    private func released(_ audiobookId: String) {
        update {
            if let companion = companions[audiobookId], !companion.isNeeded { companions[audiobookId] = nil }
        }
    }

    /// Finishes releases a previous launch recorded but didn't get to carry out. Run once
    /// the account's downloads are available.
    public func resumeReleases(downloads: ReadAlongDownloads) async {
        let pending: [String] = lock.withLock {
            companions.filter { $0.value.owned && !$0.value.isNeeded && !wanted.contains($0.key) }.keys.sorted()
        }
        await release(pending, downloads)
    }

    // MARK: Preparing

    /// Fetches and stores the manifest for `ticket`'s book and, for an imported alignment,
    /// queues the paired audiobook unless its download already covers every track.
    /// Returns the stored generation, or nil once the ticket is stale: nothing is written
    /// or queued after that. A companion queued just as the ticket went stale is cancelled
    /// again under the companion rules.
    public func store(
        _ ticket: Ticket,
        library: ReadAlongLibrary,
        downloads: ReadAlongDownloads?,
        fetchManifest: @Sendable () async throws -> Fetched,
        fetchAudiobook: @Sendable (String) async throws -> Publication
    ) async throws -> ReadAlongLibrary.Stored? {
        let valid: @Sendable () -> Bool = { [self] in isCurrent(ticket) }
        guard valid() else { return nil }
        let fetched = try await fetchManifest()
        guard valid(),
              let stored = try await library.save(manifestData: fetched.data, manifest: fetched.manifest, publicationId: ticket.publicationId, while: valid)
        else { return nil }
        if fetched.manifest.source == .imported, let audiobookId = fetched.manifest.audiobookPublicationId, let downloads {
            try await queueCompanion(audiobookId, for: fetched.manifest, ticket: ticket, downloads: downloads, fetchAudiobook: fetchAudiobook)
        }
        return valid() ? stored : nil
    }

    private func queueCompanion(
        _ audiobookId: String,
        for manifest: ReadAlongManifest,
        ticket: Ticket,
        downloads: ReadAlongDownloads,
        fetchAudiobook: @Sendable (String) async throws -> Publication
    ) async throws {
        guard let intent = intend(ticket, audiobookId) else { return }
        var queued = false
        do {
            let existing = await downloads.ready(audiobookId)
            let covers = existing.map { record in manifest.audio.allSatisfy { record.pinnedAssetIds.contains($0.assetId ?? "") } } ?? false
            if !covers, isCurrent(ticket) {
                // The paired audiobook downloads like any other: grants, background session, offline rules.
                let audiobook = try await fetchAudiobook(audiobookId)
                if isCurrent(ticket) {
                    let before = await downloads.record(audiobookId)
                    if reserve(intent, created: before == nil || before?.state == .cancelled) {
                        await downloads.enqueue(audiobook, format: nil)
                        queued = true
                    }
                }
            }
        } catch {
            await release(settle(intent, queued: false), downloads)
            throw error
        }
        await release(settle(intent, queued: queued), downloads)
    }

    private func release(_ audiobookIds: [String], _ downloads: ReadAlongDownloads) async {
        for audiobookId in audiobookIds {
            await downloads.cancelUnfinished(audiobookId, if: { [self] in releasable(audiobookId) })
            released(audiobookId)
        }
    }

    /// Finishes a stored generation once the book is downloaded: copies a media overlay's
    /// narration out of the EPUB, or makes an imported one current once the paired
    /// audiobook's files are here. `willCopyAudio` runs before copying starts.
    public func complete(
        _ ticket: Ticket,
        stored: ReadAlongLibrary.Stored,
        library: ReadAlongLibrary,
        downloads: ReadAlongDownloads?,
        willCopyAudio: @Sendable () async -> Void = {}
    ) async -> Outcome {
        let valid: @Sendable () -> Bool = { [self] in isCurrent(ticket) }
        guard valid() else { return .stale }
        guard let downloads, let record = await downloads.ready(ticket.publicationId),
              let epub = await downloads.fileURL(record, assetId: stored.manifest.ebookAssetId)
        else { return valid() ? .waitingForBook : .stale }
        guard valid() else { return .stale }
        switch stored.manifest.source {
        case .mediaOverlay:
            if stored.overlayAudio == nil { await willCopyAudio() }
            do {
                // Streams each narration file out of the EPUB inside the library actor.
                guard try await library.prepareAudio(stored, epub: epub, while: valid) != nil else { return .stale }
                return valid() ? .onDevice : .stale
            } catch let failure as ReadAlongLibrary.Failure {
                return valid() ? .failed(failure) : .stale
            } catch {
                return valid() ? .failed(.storage) : .stale
            }
        case .imported:
            var files: [String: URL]?
            if let audiobookId = stored.manifest.audiobookPublicationId, let audiobook = await downloads.ready(audiobookId) {
                files = await downloads.fileURLs(audiobook)
            }
            guard valid() else { return .stale }
            if case .ready = ReadAlongLibrary.readiness(stored, audiobookFiles: files) {
                // A generation whose pointer couldn't be written is still usable from its files.
                let promoted = (try? await library.promote(stored, while: valid)) ?? true
                return promoted && valid() ? .onDevice : .stale
            }
            if let audiobookId = stored.manifest.audiobookPublicationId, let audiobook = await downloads.record(audiobookId), audiobook.isActive {
                return valid() ? .downloadingAudiobook : .stale
            }
            return valid() ? .audiobookMissing : .stale
        }
    }

    /// The book's download was cancelled or replaced (`removing` false) or removed: its
    /// preparation stops now, and the returned task cleans up after it (`cleanUp`).
    @discardableResult
    public func stopped(_ publicationId: String, removing: Bool, library: ReadAlongLibrary, downloads: ReadAlongDownloads?) -> Task<Void, Never> {
        let cleanup = invalidate(publicationId)
        return Task {
            await self.cleanUp(cleanup, removing: removing, library: library, downloads: downloads)
        }
    }

    /// After `invalidate`: deletes what the stopped preparation stored but never made
    /// current, keeping a usable earlier generation (or, when the download was removed,
    /// everything kept for the book), then cancels the companions it released. Deleting
    /// is skipped when the book's download was asked for again since: its new preparation
    /// owns the folder.
    public func cleanUp(_ cleanup: Cleanup, removing: Bool, library: ReadAlongLibrary, downloads: ReadAlongDownloads?) async {
        let unchanged: @Sendable () -> Bool = { [self] in
            lock.withLock {
                !ended && (epochs[cleanup.publicationId] ?? 0) == cleanup.epoch
                    && (requests[cleanup.publicationId] ?? 0) == cleanup.request
            }
        }
        if removing {
            await library.remove(cleanup.publicationId, while: unchanged)
        } else {
            await library.discardPending(cleanup.publicationId, while: unchanged)
        }
        if let downloads { await release(cleanup.released, downloads) }
    }
}

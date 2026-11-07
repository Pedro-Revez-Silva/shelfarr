import Foundation

/// A place in one specific asset: a Readium locator or a time within an audio file.
public struct SavedPosition: Codable, Equatable, Sendable {
    public let assetId: String
    public let locator: JSONValue?
    public let positionSeconds: Double?

    public init(assetId: String, locator: JSONValue? = nil, positionSeconds: Double? = nil) {
        self.assetId = assetId
        self.locator = locator
        self.positionSeconds = positionSeconds
    }

    public init(_ progress: ReadingProgress) {
        self.init(assetId: progress.assetId, locator: progress.locator, positionSeconds: progress.positionSeconds)
    }
}

/// A progress write that may already have reached the server. Immutable once made:
/// a retry must repeat the same body and mutation id.
public struct PendingMutation: Codable, Equatable, Sendable {
    public let position: SavedPosition
    public let expectedVersion: Int
    public let mutationId: String
}

/// This device's knowledge of one publication's position.
public struct LocalProgress: Codable, Equatable, Sendable {
    public var publicationId: String
    public var position: SavedPosition?
    /// The server version this position was built on.
    public var baseVersion: Int
    /// True when `position` holds something the server has not been sent yet.
    public var dirty: Bool
    public var pending: PendingMutation?
    public var conflict: ReadingProgress?
    public var touched: Bool

    public init(publicationId: String, position: SavedPosition? = nil, baseVersion: Int = 0, dirty: Bool = false, pending: PendingMutation? = nil, conflict: ReadingProgress? = nil, touched: Bool = false) {
        self.publicationId = publicationId
        self.position = position
        self.baseVersion = baseVersion
        self.dirty = dirty
        self.pending = pending
        self.conflict = conflict
        self.touched = touched
    }

    public var hasUnsyncedChanges: Bool { dirty || pending != nil }
}

public protocol ProgressStore: Sendable {
    func get(_ publicationId: String) async -> LocalProgress?
    func put(_ record: LocalProgress) async
    func unsynced() async -> [LocalProgress]
}

/// One small JSON file per account, replaced atomically on each write.
public actor FileProgressStore: ProgressStore {
    private let file: URL
    private var records: [String: LocalProgress]?

    public init(file: URL) {
        self.file = file
    }

    private func loaded() -> [String: LocalProgress] {
        if let records { return records }
        let parsed = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: LocalProgress].self, from: $0) }
        let value = parsed ?? [:]
        records = value
        return value
    }

    public func get(_ publicationId: String) -> LocalProgress? { loaded()[publicationId] }

    public func put(_ record: LocalProgress) {
        var all = loaded()
        all[record.publicationId] = record
        records = all
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(all) {
            try? data.write(to: file, options: .atomic)
        }
    }

    public func unsynced() -> [LocalProgress] {
        loaded().values.filter { $0.hasUnsyncedChanges && $0.conflict == nil }
    }
}

/// Where a publication should open, decided before anything is shown.
public enum ResumeDecision: Equatable, Sendable {
    case beginning
    case resume(SavedPosition, baseVersion: Int)
    /// This device has unsent reading the server has since moved past.
    case choose(local: SavedPosition, server: ReadingProgress)
    /// The saved place belongs to a file this publication no longer has.
    case editionChanged(staleVersion: Int)

    public static func decide(publication: Publication, server: ReadingProgress?, local: LocalProgress?, offline: Bool = false) -> ResumeDecision {
        let assets = Set(publication.playableAssets.map(\.id))
        let serverVersion = server?.version ?? 0
        let usableServer = server.flatMap { $0.version > 0 && $0.isUsable && assets.contains($0.assetId) ? $0 : nil }

        if let local, (local.hasUnsyncedChanges || offline),
           let position = local.position, assets.contains(position.assetId) {
            guard !offline, let usableServer, serverVersion > local.baseVersion else {
                return .resume(position, baseVersion: max(local.baseVersion, serverVersion))
            }
            if position == SavedPosition(usableServer) {
                return .resume(position, baseVersion: serverVersion)
            }
            return .choose(local: position, server: usableServer)
        }

        if let usableServer { return .resume(SavedPosition(usableServer), baseVersion: serverVersion) }
        if serverVersion > 0 { return .editionChanged(staleVersion: serverVersion) }
        return .beginning
    }
}

public enum SyncStatus: Equatable, Sendable {
    case idle
    case pending
    case saved
    /// Saved on this device; the server will get it once reachable.
    case waitingForServer
    /// Another device moved on. Nothing more is sent until the reader chooses.
    case conflict(local: SavedPosition?, server: ReadingProgress)
    case needsSignIn
    /// The server refused this position outright, e.g. the asset was replaced.
    case rejected
}

public struct SyncTiming: Sendable {
    public var debounce: Duration = .seconds(5)
    public var maxWait: Duration = .seconds(20)
    public var firstRetry: Duration = .seconds(5)
    public var maxRetry: Duration = .seconds(300)
    public var maxRetries = 8

    public init() {}
}

/// Keeps one publication's position safe locally and in step with the server.
///
/// Every position lands on disk first. Sends are debounced, serial and idempotent:
/// a write keeps its mutation id until the server has given a definite answer,
/// while newer positions wait behind it.
public actor ProgressSync {
    public typealias Remote = @Sendable (String, ProgressUpdate) async throws -> ReadingProgress

    public nonisolated let publicationId: String
    private let store: ProgressStore
    private let remote: Remote
    private let timing: SyncTiming
    private let clock: ContinuousClock
    private let newMutationId: @Sendable () -> String

    private var record: LocalProgress?
    private var dirtySince: ContinuousClock.Instant?
    private var timer: Task<Void, Never>?
    private var retries = 0
    private var sending = false
    private var sendAgain = false
    private var stopped = false
    private var requestTask: Task<ReadingProgress, Error>?
    private var observers: [UUID: @Sendable (SyncStatus) -> Void] = [:]

    public private(set) var status: SyncStatus = .idle {
        didSet { observers.values.forEach { $0(status) } }
    }

    public init(
        publicationId: String,
        store: ProgressStore,
        remote: @escaping Remote,
        timing: SyncTiming = SyncTiming(),
        newMutationId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        initiallyStopped: Bool = false
    ) {
        self.publicationId = publicationId
        self.store = store
        self.remote = remote
        self.timing = timing
        clock = ContinuousClock()
        self.newMutationId = newMutationId
        stopped = initiallyStopped
    }

    @discardableResult
    public func observe(_ observer: @escaping @Sendable (SyncStatus) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        observer(status)
        return id
    }

    public func stopObserving(_ id: UUID) { observers[id] = nil }

    private func current() async -> LocalProgress {
        if let record { return record }
        let loaded = await store.get(publicationId) ?? LocalProgress(publicationId: publicationId)
        if let record { return record }
        record = loaded
        if let conflict = loaded.conflict { status = .conflict(local: loaded.position, server: conflict) }
        return loaded
    }

    private func save(_ updated: LocalProgress) async {
        guard !stopped else { return }
        record = updated
        await store.put(updated)
    }

    public func snapshot() async -> LocalProgress { await current() }

    /// Anchors this session after a `ResumeDecision`, before the first `update`.
    public func begin(position: SavedPosition?, baseVersion: Int) async {
        guard !stopped else { return }
        var existing = await current()
        if existing.position == position, existing.baseVersion == baseVersion { return }
        existing.dirty = existing.dirty && existing.position == position
        // A pending write is only still valid if it was built on this same version.
        if existing.pending?.expectedVersion != baseVersion { existing.pending = nil }
        existing.position = position
        existing.baseVersion = baseVersion
        existing.conflict = nil
        await save(existing)
        status = .idle
    }

    /// Records the latest place. Cheap enough to call on every page turn or tick.
    public func update(_ position: SavedPosition) async {
        guard !stopped else { return }
        var existing = await current()
        if existing.position == position { return }
        existing.position = position
        existing.dirty = true
        existing.touched = true
        await save(existing)
        if existing.conflict != nil { return }

        status = .pending
        let now = clock.now
        let started = dirtySince ?? now
        dirtySince = started
        let remaining = timing.maxWait - started.duration(to: now)
        schedule(after: max(.zero, min(timing.debounce, remaining)))
    }

    /// Sends everything outstanding now. Call on pause, stop and background.
    public func flush() async {
        guard !stopped else { return }
        timer?.cancel()
        timer = nil
        await send()
    }

    /// Ends account work without discarding its durable unsent position.
    public func stop() async {
        stopped = true
        timer?.cancel()
        timer = nil
        requestTask?.cancel()
        sendAgain = false
        observers.removeAll()
        // Drain writes already queued before sign-out removes the directory.
        _ = await store.get(publicationId)
    }

    /// Keeps this device's place, replacing what the other device saved.
    public func keepLocal() async {
        var existing = await current()
        guard let server = existing.conflict else { return }
        existing.baseVersion = server.version
        existing.conflict = nil
        existing.pending = nil
        existing.dirty = true
        await save(existing)
        status = .pending
        await flush()
    }

    /// Adopts the other device's place and forgets the unsent local one.
    public func useServer() async -> SavedPosition? {
        var existing = await current()
        guard let server = existing.conflict else { return nil }
        let position = SavedPosition(server)
        existing.position = position
        existing.baseVersion = server.version
        existing.conflict = nil
        existing.pending = nil
        existing.dirty = false
        await save(existing)
        status = .saved
        return position
    }

    /// Resolves a choice raised before opening, when no write has conflicted yet.
    public func chooseAtOpen(position: SavedPosition, serverVersion: Int, keepLocal: Bool) async {
        var existing = await current()
        existing.position = position
        existing.baseVersion = serverVersion
        existing.dirty = keepLocal
        existing.pending = nil
        existing.conflict = nil
        await save(existing)
        if keepLocal { await flush() }
    }

    private func schedule(after delay: Duration) {
        guard !stopped else { return }
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            await self?.send()
        }
    }

    private func send() async {
        guard !stopped else { return }
        // Actor reentrancy: an in-flight send picks up any later request itself.
        if sending {
            sendAgain = true
            return
        }
        sending = true
        defer { sending = false; requestTask = nil }

        repeat {
            sendAgain = false
            while let mutation = await nextMutation() {
                guard !stopped else { return }
                do {
                    let update = ProgressUpdate(
                        assetId: mutation.position.assetId,
                        locator: mutation.position.locator,
                        positionSeconds: mutation.position.positionSeconds,
                        expectedVersion: mutation.expectedVersion,
                        clientMutationId: mutation.mutationId
                    )
                    let remote = self.remote, id = publicationId
                    let task = Task { try await remote(id, update) }
                    requestTask = task
                    let result = try await task.value
                    guard !stopped else { return }
                    await accept(result)
                } catch let APIError.progressConflict(server) {
                    guard !stopped else { return }
                    if let server, server.clientMutationId == mutation.mutationId {
                        // Our earlier attempt landed and only the response was lost.
                        await accept(server)
                    } else if let server {
                        await raiseConflict(server)
                        return
                    } else {
                        await discard()
                        return
                    }
                } catch APIError.unauthorized {
                    guard !stopped else { return }
                    status = .needsSignIn
                    return
                } catch let error as APIError where error.isRetryable {
                    guard !stopped else { return }
                    status = .waitingForServer
                    scheduleRetry()
                    return
                } catch is CancellationError {
                    return
                } catch {
                    guard !stopped else { return }
                    await discard()
                    return
                }
            }
        } while sendAgain
    }

    private func nextMutation() async -> PendingMutation? {
        var existing = await current()
        guard !stopped else { return nil }
        if existing.conflict != nil { return nil }
        if let queued = existing.pending { return queued }
        guard existing.dirty, let position = existing.position else {
            if status != .rejected { status = existing.touched ? .saved : .idle }
            dirtySince = nil
            return nil
        }
        let created = PendingMutation(position: position, expectedVersion: existing.baseVersion, mutationId: newMutationId())
        existing.pending = created
        existing.dirty = false
        await save(existing)
        return created
    }

    private func accept(_ saved: ReadingProgress) async {
        var existing = await current()
        retries = 0
        existing.baseVersion = saved.version
        existing.pending = nil
        existing.touched = true
        await save(existing)
    }

    private func raiseConflict(_ server: ReadingProgress) async {
        var existing = await current()
        existing.conflict = server
        existing.pending = nil
        existing.dirty = true
        await save(existing)
        status = .conflict(local: existing.position, server: server)
    }

    private func discard() async {
        var existing = await current()
        existing.pending = nil
        existing.dirty = false
        await save(existing)
        status = .rejected
    }

    private func scheduleRetry() {
        guard retries < timing.maxRetries else { return }
        var delay = timing.firstRetry
        for _ in 0 ..< retries { delay = min(delay * 2, timing.maxRetry) }
        retries += 1
        schedule(after: delay)
    }
}

/// Live `ProgressSync` instances for one account.
public final class ProgressRegistry: @unchecked Sendable {
    private let store: ProgressStore
    private let remote: ProgressSync.Remote
    private let lock = NSLock()
    private var syncs: [String: ProgressSync] = [:]
    private var stopped = false

    public init(store: ProgressStore, remote: @escaping ProgressSync.Remote) {
        self.store = store
        self.remote = remote
    }

    public func sync(for publicationId: String) -> ProgressSync {
        lock.withLock {
            if let existing = syncs[publicationId] { return existing }
            let created = ProgressSync(publicationId: publicationId, store: store, remote: remote, initiallyStopped: stopped)
            syncs[publicationId] = created
            return created
        }
    }

    /// Retries whatever earlier sessions could not deliver.
    public func flushAll() async {
        guard !lock.withLock({ stopped }) else { return }
        for record in await store.unsynced() {
            await sync(for: record.publicationId).flush()
        }
    }

    public func stopAll() async {
        let pending = lock.withLock { () -> [ProgressSync] in
            stopped = true
            let values = Array(syncs.values)
            syncs.removeAll()
            return values
        }
        for sync in pending { await sync.stop() }
    }
}

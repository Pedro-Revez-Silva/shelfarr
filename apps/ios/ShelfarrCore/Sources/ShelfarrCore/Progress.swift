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
/// a retry repeats the same body, activity time, resolve flag and mutation id.
public struct PendingMutation: Codable, Equatable, Sendable {
    public let position: SavedPosition
    public let expectedVersion: Int
    public let mutationId: String
    /// When `position` was observed, epoch ms. Nil for writes queued before activity times existed.
    public let observedAt: Int64?
    /// An explicit "Keep this device" choice. Automatic rebasing never sets it.
    public let resolveConflict: Bool

    public init(position: SavedPosition, expectedVersion: Int, mutationId: String, observedAt: Int64? = nil, resolveConflict: Bool = false) {
        self.position = position
        self.expectedVersion = expectedVersion
        self.mutationId = mutationId
        self.observedAt = observedAt
        self.resolveConflict = resolveConflict
    }

    enum CodingKeys: String, CodingKey {
        case position, expectedVersion, mutationId, observedAt, resolveConflict
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        position = try container.decode(SavedPosition.self, forKey: .position)
        expectedVersion = try container.decode(Int.self, forKey: .expectedVersion)
        mutationId = try container.decode(String.self, forKey: .mutationId)
        observedAt = try container.decodeIfPresent(Int64.self, forKey: .observedAt)
        resolveConflict = try container.decodeIfPresent(Bool.self, forKey: .resolveConflict) ?? false
    }

    /// The request body. Identical on every attempt.
    public var update: ProgressUpdate {
        ProgressUpdate(
            assetId: position.assetId,
            locator: position.locator,
            positionSeconds: position.positionSeconds,
            expectedVersion: expectedVersion,
            clientMutationId: mutationId,
            observedAt: observedAt.map(ActivityTime.format),
            resolveConflict: resolveConflict ? true : nil
        )
    }
}

/// This device's knowledge of one publication's position.
///
/// Records written before activity times existed decode with `observedAt` nil: unknown,
/// so they keep the explicit-choice flow rather than borrowing a time.
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
    /// When `position` was reached, here or on the device it was adopted from. Nil when unknown.
    public var observedAt: Int64?
    /// The assets this edition's positions may name, so a background sync can tell an unmappable place.
    public var assetIds: [String]?
    /// The server refused this place (a replaced file, a wrong clock). It is kept here,
    /// still unsynced, but not resent until the publication is opened again.
    public var rejected: Bool

    public init(publicationId: String, position: SavedPosition? = nil, baseVersion: Int = 0, dirty: Bool = false, pending: PendingMutation? = nil, conflict: ReadingProgress? = nil, touched: Bool = false, observedAt: Int64? = nil, assetIds: [String]? = nil, rejected: Bool = false) {
        self.publicationId = publicationId
        self.position = position
        self.baseVersion = baseVersion
        self.dirty = dirty
        self.pending = pending
        self.conflict = conflict
        self.touched = touched
        self.observedAt = observedAt
        self.assetIds = assetIds
        self.rejected = rejected
    }

    enum CodingKeys: String, CodingKey {
        case publicationId, position, baseVersion, dirty, pending, conflict, touched, observedAt, assetIds, rejected
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        publicationId = try container.decode(String.self, forKey: .publicationId)
        position = try container.decodeIfPresent(SavedPosition.self, forKey: .position)
        baseVersion = try container.decodeIfPresent(Int.self, forKey: .baseVersion) ?? 0
        dirty = try container.decodeIfPresent(Bool.self, forKey: .dirty) ?? false
        pending = try container.decodeIfPresent(PendingMutation.self, forKey: .pending)
        conflict = try container.decodeIfPresent(ReadingProgress.self, forKey: .conflict)
        touched = try container.decodeIfPresent(Bool.self, forKey: .touched) ?? false
        observedAt = try container.decodeIfPresent(Int64.self, forKey: .observedAt)
        assetIds = try container.decodeIfPresent([String].self, forKey: .assetIds)
        rejected = try container.decodeIfPresent(Bool.self, forKey: .rejected) ?? false
    }

    public var hasUnsyncedChanges: Bool { dirty || pending != nil }

    /// Whether background syncing should send this record now.
    public var isSendable: Bool { hasUnsyncedChanges && conflict == nil && !rejected }
}

public enum ProgressStoreError: Error, Equatable, Sendable {
    /// The saved places exist but could not be read (for example while the device is locked).
    case unreadable
    /// The place could not be written.
    case unwritable
}

public protocol ProgressStore: Sendable {
    func get(_ publicationId: String) async throws -> LocalProgress?
    /// Throws when the place could not be written.
    func put(_ record: LocalProgress) async throws
    func unsynced() async throws -> [LocalProgress]
}

/// One small JSON file per account, replaced atomically on each write.
public actor FileProgressStore: ProgressStore {
    private let file: URL
    private var records: [String: LocalProgress]?

    public init(file: URL) {
        self.file = file
    }

    /// A read failure throws and caches nothing, so a later write can't replace records
    /// it never read. An unreadable file is set aside rather than overwritten.
    private func loaded() throws -> [String: LocalProgress] {
        if let records { return records }
        guard FileManager.default.fileExists(atPath: file.path) else {
            records = [:]
            return [:]
        }
        guard let data = try? Data(contentsOf: file) else { throw ProgressStoreError.unreadable }
        if let parsed = try? JSONDecoder().decode([String: LocalProgress].self, from: data) {
            records = parsed
            return parsed
        }
        setAside()
        records = [:]
        return [:]
    }

    private func setAside() {
        let damaged = file.appendingPathExtension("damaged")
        try? FileManager.default.removeItem(at: damaged)
        try? FileManager.default.moveItem(at: file, to: damaged)
    }

    public func get(_ publicationId: String) throws -> LocalProgress? { try loaded()[publicationId] }

    public func put(_ record: LocalProgress) throws {
        var all = try loaded()
        all[record.publicationId] = record
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(all).write(to: file, options: .atomic)
        } catch {
            throw ProgressStoreError.unwritable
        }
        records = all
    }

    public func unsynced() throws -> [LocalProgress] {
        try loaded().values.filter(\.isSendable)
    }
}

/// Where a publication should open, decided before anything is shown.
public enum ResumeDecision: Equatable, Sendable {
    case beginning
    /// Open at the place. `observedAt` is when it was reached, if known.
    case resume(SavedPosition, baseVersion: Int, observedAt: Int64?)
    /// The two places can't be ordered by when they were reached. The reader decides.
    case choose(local: SavedPosition, server: ReadingProgress)
    /// The saved place belongs to a file this publication no longer has.
    case editionChanged(staleVersion: Int)

    public static func decide(publication: Publication, server: ReadingProgress?, local: LocalProgress?, offline: Bool = false, now: Int64 = ActivityTime.now()) -> ResumeDecision {
        let assets = Set(publication.playableAssets.map(\.id))
        let serverVersion = server?.version ?? 0
        let usableServer = server.flatMap { $0.version > 0 && $0.isUsable && assets.contains($0.assetId) ? $0 : nil }
        let serverTime = server?.observedAtMillis

        // Our queued write already reached the server; only the answer was lost.
        let acknowledged = local?.pending.map { $0.mutationId == server?.clientMutationId } ?? false
        let localBase = acknowledged ? serverVersion : local?.baseVersion ?? 0
        let unsynced = local.map { $0.dirty || ($0.pending != nil && !acknowledged) } ?? false

        if let local, unsynced || offline, let position = local.position, assets.contains(position.assetId) {
            guard !offline, let usableServer, serverVersion > localBase else {
                return .resume(position, baseVersion: max(localBase, serverVersion), observedAt: local.observedAt)
            }
            if position == SavedPosition(usableServer) {
                return .resume(position, baseVersion: serverVersion, observedAt: local.observedAt ?? serverTime)
            }
            // The server refused this place before: never settle it automatically.
            if local.rejected { return .choose(local: position, server: usableServer) }
            return byActivityTime(position, local.observedAt, usableServer, now: now)
        }

        if let usableServer { return .resume(SavedPosition(usableServer), baseVersion: serverVersion, observedAt: serverTime) }
        if serverVersion > 0 { return .editionChanged(staleVersion: serverVersion) }
        return .beginning
    }

    /// The later real activity wins, wherever it is in the book. Uncertain times ask.
    private static func byActivityTime(_ local: SavedPosition, _ localTime: Int64?, _ server: ReadingProgress, now: Int64) -> ResumeDecision {
        let mine = localTime.flatMap { ActivityTime.isPlausible($0, now: now) ? $0 : nil }
        let theirs = server.observedAtMillis.flatMap { ActivityTime.isPlausible($0, now: now) ? $0 : nil }
        guard let mine, let theirs, mine != theirs else { return .choose(local: local, server: server) }
        // Built again on the server's version when the session begins.
        if mine > theirs { return .resume(local, baseVersion: server.version, observedAt: mine) }
        return .resume(SavedPosition(server), baseVersion: server.version, observedAt: theirs)
    }
}

public enum SyncStatus: Equatable, Sendable {
    case idle
    case pending
    case saved
    /// Saved on this device; the server will get it once reachable.
    case waitingForServer
    /// The devices can't be ordered by time. Nothing more is sent until the reader chooses.
    case conflict(local: SavedPosition?, server: ReadingProgress)
    case needsSignIn
    /// The server refused this position, e.g. the asset was replaced. It is still kept on this device.
    case rejected
    /// This device could not write its place. It is held in memory and still sent to the server.
    case storageFailed
}

public struct SyncTiming: Sendable {
    public var debounce: Duration = .seconds(5)
    public var maxWait: Duration = .seconds(20)
    public var firstRetry: Duration = .seconds(5)
    public var maxRetry: Duration = .seconds(300)
    public var maxRetries = 8
    /// Rebases in one send before backing off, in case another device keeps writing.
    public var maxRebases = 4

    public init() {}
}

/// Keeps one publication's position safe locally and in step with the server.
///
/// Every position lands on disk first, with the time it was reached. Sends are
/// debounced, serial and idempotent: a write keeps its body, activity time and mutation
/// id until the server has given a definite answer, while newer positions wait behind
/// it. A definite conflict is settled by activity time when both sides have a
/// trustworthy one; otherwise the reader chooses.
///
/// Nothing here moves a live reader or player. Adopting another device's later place
/// only changes the saved record, which the next open resumes from.
public actor ProgressSync {
    public typealias Remote = @Sendable (String, ProgressUpdate) async throws -> ReadingProgress

    public nonisolated let publicationId: String
    private let store: ProgressStore
    private let remote: Remote
    private let timing: SyncTiming
    private let clock: ContinuousClock
    private let now: @Sendable () -> Int64
    private let newMutationId: @Sendable () -> String

    private var record: LocalProgress?
    private var dirtySince: ContinuousClock.Instant?
    private var timer: Task<Void, Never>?
    private var retries = 0
    private var sending = false
    private var sendAgain = false
    private var stopped = false
    private var storageFailed = false
    /// The last place the open session reported or started from; repeating it is not new activity.
    private var reported: SavedPosition?
    private var requestTask: Task<ReadingProgress, Error>?
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [UUID: @Sendable (SyncStatus) -> Void] = [:]
    private var underlying: SyncStatus = .idle

    public private(set) var status: SyncStatus = .idle {
        didSet { observers.values.forEach { $0(status) } }
    }

    public init(
        publicationId: String,
        store: ProgressStore,
        remote: @escaping Remote,
        timing: SyncTiming = SyncTiming(),
        now: @escaping @Sendable () -> Int64 = { ActivityTime.now() },
        newMutationId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        initiallyStopped: Bool = false
    ) {
        self.publicationId = publicationId
        self.store = store
        self.remote = remote
        self.timing = timing
        clock = ContinuousClock()
        self.now = now
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
        var loaded: LocalProgress?
        var failed = false
        do {
            loaded = try await store.get(publicationId)
        } catch {
            failed = true
        }
        if let record { return record }
        let value = loaded ?? LocalProgress(publicationId: publicationId)
        record = value
        if failed { storageFailed = true }
        if let conflict = value.conflict {
            publish(.conflict(local: value.position, server: conflict))
        } else if failed {
            publish(underlying)
        }
        return value
    }

    /// Writes locally. A failed write keeps the record in memory and is surfaced, never thrown.
    private func save(_ updated: LocalProgress) async {
        guard !stopped else { return }
        record = updated
        do {
            try await store.put(updated)
            if storageFailed {
                storageFailed = false
                publish(underlying)
            }
        } catch {
            storageFailed = true
            publish(underlying)
        }
    }

    private func publish(_ value: SyncStatus) {
        underlying = value
        if case .conflict = value {
            status = value
        } else {
            status = storageFailed ? .storageFailed : value
        }
    }

    public func snapshot() async -> LocalProgress { await current() }

    /// Anchors this session after a `ResumeDecision`, before the first `update`. Restoring a
    /// place is not activity: it keeps the time the place was reached, `observedAt`.
    public func begin(position: SavedPosition?, baseVersion: Int, observedAt: Int64? = nil, assets: [String]? = nil) async {
        guard !stopped else { return }
        let existing = await current()
        reported = position
        let samePlace = existing.position == position
        let base = samePlace ? max(existing.baseVersion, baseVersion) : baseVersion
        // A pending write is only still valid for this place and on this same version.
        let pending = samePlace ? existing.pending.flatMap { $0.expectedVersion == base ? $0 : nil } : nil
        var updated = existing
        updated.position = position
        updated.baseVersion = base
        updated.pending = pending
        // A dropped write that held this place still has to reach the server, rebased.
        updated.dirty = samePlace && (existing.dirty || (existing.pending != nil && pending == nil))
        updated.conflict = nil
        updated.observedAt = samePlace ? existing.observedAt ?? observedAt : observedAt
        updated.assetIds = assets ?? existing.assetIds
        updated.rejected = false
        if updated != existing { await save(updated) }
        if updated.hasUnsyncedChanges {
            publish(.pending)
            schedule(after: .zero)
        } else {
            publish(.idle)
        }
    }

    /// Records a place the reader or listener actually reached at `observedAt`, the
    /// wall-clock time captured when it happened (before any waiting). Cheap enough to
    /// call on every page turn or checkpoint.
    public func update(_ position: SavedPosition, observedAt: Int64) async {
        guard !stopped else { return }
        var existing = await current()
        if position == reported || existing.position == position {
            reported = position
            return
        }
        reported = position
        existing.position = position
        existing.dirty = true
        existing.touched = true
        existing.observedAt = ActivityTime.next(observedAt, after: existing.observedAt)
        await save(existing)
        if existing.conflict != nil || existing.rejected { return }

        publish(.pending)
        let instant = clock.now
        let started = dirtySince ?? instant
        dirtySince = started
        let remaining = timing.maxWait - started.duration(to: instant)
        schedule(after: max(.zero, min(timing.debounce, remaining)))
    }

    /// Sends everything outstanding now, and returns once that attempt (or one already
    /// under way) has finished. Call on pause, stop and background.
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
        _ = try? await store.get(publicationId)
    }

    /// Keeps this device's place over the other device's. This is a new, explicit choice:
    /// it gets its own activity time and the resolve flag, on disk before it is sent.
    public func keepLocal() async {
        let chosenAt = now()
        var existing = await current()
        guard let server = existing.conflict, let position = existing.position else { return }
        existing.pending = PendingMutation(position: position, expectedVersion: server.version, mutationId: newMutationId(), observedAt: chosenAt, resolveConflict: true)
        existing.baseVersion = server.version
        existing.conflict = nil
        existing.dirty = false
        existing.observedAt = chosenAt
        existing.rejected = false
        await save(existing)
        publish(.pending)
        await flush()
    }

    /// Adopts the other device's place and forgets the unsent local one.
    public func useServer() async -> SavedPosition? {
        let existing = await current()
        guard let server = existing.conflict else { return nil }
        let position = SavedPosition(server)
        reported = position
        await save(adopted(existing, server))
        publish(.saved)
        return position
    }

    /// Resolves a choice raised before opening, when no write has conflicted yet. The
    /// choice is on disk when this returns; keeping this device's place is sent soon after.
    public func chooseAtOpen(position: SavedPosition, server: ReadingProgress, keepLocal: Bool) async {
        let chosenAt = now()
        var existing = await current()
        reported = position
        if keepLocal {
            existing.position = position
            existing.baseVersion = server.version
            existing.dirty = false
            existing.pending = PendingMutation(position: position, expectedVersion: server.version, mutationId: newMutationId(), observedAt: chosenAt, resolveConflict: true)
            existing.conflict = nil
            existing.observedAt = chosenAt
            existing.rejected = false
            await save(existing)
            publish(.pending)
            schedule(after: .zero)
        } else {
            await save(adopted(existing, server))
            publish(.saved)
        }
    }

    private func adopted(_ existing: LocalProgress, _ server: ReadingProgress) -> LocalProgress {
        var updated = existing
        updated.position = SavedPosition(server)
        updated.baseVersion = server.version
        updated.conflict = nil
        updated.pending = nil
        updated.dirty = false
        updated.observedAt = server.observedAtMillis
        updated.rejected = false
        return updated
    }

    private func schedule(after delay: Duration) {
        guard !stopped else { return }
        timer?.cancel()
        timer = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            if Task.isCancelled { return }
            await self?.send()
        }
    }

    private func send() async {
        guard !stopped else { return }
        // Actor reentrancy: an in-flight send picks up any later request itself, and the
        // caller waits for it, so a flush on pause or background has really been tried.
        if sending {
            sendAgain = true
            await withCheckedContinuation { sendWaiters.append($0) }
            return
        }
        sending = true
        defer {
            sending = false
            requestTask = nil
            let waiting = sendWaiters
            sendWaiters = []
            waiting.forEach { $0.resume() }
        }
        var rebases = 0

        repeat {
            sendAgain = false
            while let mutation = await nextMutation() {
                guard !stopped else { return }
                do {
                    let remote = self.remote, id = publicationId, update = mutation.update
                    let task = Task { try await remote(id, update) }
                    requestTask = task
                    let result = try await task.value
                    guard !stopped else { return }
                    await accept(mutation, result)
                } catch let APIError.progressConflict(server) {
                    guard !stopped else { return }
                    if let server, server.clientMutationId == mutation.mutationId {
                        // Our earlier attempt landed and only the response was lost.
                        await accept(mutation, server)
                        continue
                    }
                    guard await reconcile(mutation, server) else { return }
                    rebases += 1
                    if rebases > timing.maxRebases {
                        waitAndRetry()
                        return
                    }
                } catch APIError.unauthorized {
                    guard !stopped else { return }
                    publish(.needsSignIn)
                    return
                } catch is CancellationError {
                    return
                } catch let error as APIError {
                    guard !stopped else { return }
                    switch error {
                    // An unreadable answer (a captive portal, a proxy) may or may not have landed: retry it as it is.
                    case .offline, .server, .protocolError, .redirectBlocked:
                        waitAndRetry()
                    default:
                        await reject(mutation)
                    }
                    return
                } catch {
                    guard !stopped else { return }
                    waitAndRetry()
                    return
                }
            }
        } while sendAgain
    }

    private func nextMutation() async -> PendingMutation? {
        var existing = await current()
        guard !stopped else { return nil }
        if existing.conflict != nil || existing.rejected { return nil }
        if let queued = existing.pending { return queued }
        guard existing.dirty, let position = existing.position else {
            publish(existing.touched ? .saved : .idle)
            dirtySince = nil
            return nil
        }
        let created = PendingMutation(position: position, expectedVersion: existing.baseVersion, mutationId: newMutationId(), observedAt: existing.observedAt)
        existing.pending = created
        existing.dirty = false
        await save(existing)
        return created
    }

    /// Settles a definite conflict. Returns true when there is something new to send.
    ///
    /// The newest local observation, including places queued behind `mutation`, is
    /// compared with the server's canonical checkpoint. The later real activity wins
    /// wherever it is in the book. Equal, unknown or implausible times, and places this
    /// edition can't map, are left to the reader.
    private func reconcile(_ mutation: PendingMutation, _ server: ReadingProgress?) async -> Bool {
        var existing = await current()
        // Something else (a new session, a choice) replaced this write meanwhile.
        guard existing.pending?.mutationId == mutation.mutationId else { return true }
        let local = existing.position ?? mutation.position
        guard let server, server.isUsable else {
            // Nothing usable to compare with: this device holds the only place.
            await rebase(existing, local, server?.version ?? 0)
            return true
        }
        if local == SavedPosition(server) {
            existing.baseVersion = server.version
            existing.pending = nil
            existing.dirty = false
            await save(existing)
            return true
        }
        let clock = now()
        let mappable = existing.assetIds?.contains(server.assetId) ?? (server.assetId == local.assetId)
        let serverTime = server.observedAtMillis.flatMap { ActivityTime.isPlausible($0, now: clock) ? $0 : nil }
        let localTime = existing.observedAt.flatMap { ActivityTime.isPlausible($0, now: clock) ? $0 : nil }
        guard mappable, let serverTime, let localTime, serverTime != localTime else {
            existing.conflict = server
            existing.pending = nil
            existing.dirty = true
            await save(existing)
            publish(.conflict(local: local, server: server))
            return false
        }
        if localTime > serverTime {
            await rebase(existing, local, server.version)
            return true
        }
        // The other device was used later. Its place becomes the saved one.
        await save(adopted(existing, server))
        publish(.saved)
        return false
    }

    /// Resends the newest local place on top of `version`: a new id, the original activity time.
    private func rebase(_ existing: LocalProgress, _ local: SavedPosition, _ version: Int) async {
        var updated = existing
        updated.position = local
        updated.baseVersion = version
        updated.pending = PendingMutation(position: local, expectedVersion: version, mutationId: newMutationId(), observedAt: existing.observedAt)
        updated.dirty = false
        await save(updated)
    }

    private func accept(_ mutation: PendingMutation, _ saved: ReadingProgress) async {
        retries = 0
        var existing = await current()
        // An answer to a write a newer session already replaced changes nothing.
        guard existing.pending?.mutationId == mutation.mutationId else { return }
        existing.baseVersion = saved.version
        existing.pending = nil
        existing.touched = true
        await save(existing)
    }

    private func reject(_ mutation: PendingMutation) async {
        var existing = await current()
        guard existing.pending?.mutationId == mutation.mutationId else { return }
        // Keep the place: it is still where this device was, and still unsynced.
        existing.pending = nil
        existing.dirty = true
        existing.rejected = true
        await save(existing)
        publish(.rejected)
    }

    private func waitAndRetry() {
        publish(.waitingForServer)
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

    /// Retries whatever earlier sessions could not deliver. A store that can't be read retries nothing.
    public func flushAll() async {
        guard !lock.withLock({ stopped }) else { return }
        let outstanding = (try? await store.unsynced()) ?? []
        for record in outstanding where record.isSendable {
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

@testable import ShelfarrCore
import XCTest

/// In-memory saved places for one device.
actor MemoryProgressStore: ProgressStore {
    var records: [String: LocalProgress] = [:]
    var failWrites = false
    var failReads = false
    private(set) var writes = 0

    func get(_ id: String) throws -> LocalProgress? {
        if failReads { throw ProgressStoreError.unreadable }
        return records[id]
    }

    func put(_ record: LocalProgress) throws {
        if failWrites { throw ProgressStoreError.unwritable }
        writes += 1
        records[record.publicationId] = record
    }

    func unsynced() throws -> [LocalProgress] {
        if failReads { throw ProgressStoreError.unreadable }
        return records.values.filter(\.isSendable)
    }

    func set(failWrites: Bool) { self.failWrites = failWrites }
    func set(failReads: Bool) { self.failReads = failReads }
    func seed(_ record: LocalProgress) { records[record.publicationId] = record }
}

/// A wall clock a test moves by hand.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64

    init(_ value: Int64) { self.value = value }

    var now: Int64 { lock.withLock { value } }
    func set(_ next: Int64) { lock.withLock { value = next } }
    func advance(_ by: Int64) { lock.withLock { value += by } }
}

/// A server that follows the consumer API's activity-time contract for one publication:
/// idempotent retries by UUID, expected-version CAS, the chronological guard unless
/// `resolve_conflict`, and refusal of malformed or implausibly future `observed_at`.
final class ContractServer: @unchecked Sendable {
    enum Failure { case offline, loseResponse, server }

    private let lock = NSLock()
    private(set) var stored: ReadingProgress?
    private var calls: [ProgressUpdate] = []
    private var failures: [Failure] = []
    /// The server's own clock, for the future-time limit.
    var clock: Int64
    /// An older server: ignores both fields and never returns `observed_at`.
    var legacy = false

    init(clock: Int64) { self.clock = clock }

    var received: [ProgressUpdate] { lock.withLock { calls } }
    func fail(_ failure: Failure) { lock.withLock { failures.append(failure) } }
    func seed(_ progress: ReadingProgress) { lock.withLock { stored = progress } }

    func save(_: String, _ update: ProgressUpdate) async throws -> ReadingProgress {
        let (failure, result) = lock.withLock { () -> (Failure?, Result<ReadingProgress, APIError>) in
            calls.append(update)
            let failure = failures.isEmpty ? nil : failures.removeFirst()
            if failure == .offline { return (failure, .failure(.offline(certificate: false))) }
            if failure == .server { return (failure, .failure(.server(503))) }
            return (failure, apply(update))
        }
        if failure == .loseResponse { throw APIError.offline(certificate: false) }
        return try result.get()
    }

    private func apply(_ update: ProgressUpdate) -> Result<ReadingProgress, APIError> {
        let version = stored?.version ?? 0
        let observed: Int64?
        if legacy {
            observed = nil
        } else if let raw = update.observedAt {
            guard let parsed = ActivityTime.parse(raw), parsed <= clock + ActivityTime.futureTolerance else {
                return .failure(.rejected("invalid_observed_at"))
            }
            observed = parsed
        } else {
            observed = nil
        }
        let samePlace = { (stored: ReadingProgress) in
            stored.assetId == update.assetId && stored.locator == update.locator && stored.positionSeconds == update.positionSeconds
        }
        if let stored, stored.clientMutationId == update.clientMutationId {
            if samePlace(stored), stored.observedAtMillis == observed { return .success(stored) }
            return .failure(.progressConflict(stored))
        }
        guard update.expectedVersion == version else { return .failure(.progressConflict(stored)) }
        if !legacy, update.resolveConflict != true, let stored, let theirs = stored.observedAtMillis, let mine = observed {
            if mine < theirs || (mine == theirs && !samePlace(stored)) { return .failure(.progressConflict(stored)) }
        }
        let saved = ReadingProgress(
            assetId: update.assetId,
            locator: update.locator,
            positionSeconds: update.positionSeconds,
            version: version + 1,
            updatedAt: ActivityTime.format(clock),
            clientMutationId: update.clientMutationId,
            observedAt: observed.map(ActivityTime.format)
        )
        stored = saved
        return .success(saved)
    }
}

/// One device: its own store, wall clock and mutation ids, against a shared server.
struct Device {
    let name: String
    let store: MemoryProgressStore
    let clock: ManualClock
    let server: ContractServer

    init(_ name: String, server: ContractServer, clock: Int64, store: MemoryProgressStore = MemoryProgressStore()) {
        self.name = name
        self.store = store
        self.clock = ManualClock(clock)
        self.server = server
    }

    /// A fresh `ProgressSync`, as after an app restart. Sends only on `flush`.
    func sync(publicationId: String = "p") -> ProgressSync {
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var value = 0
            func next() -> Int { lock.withLock { value += 1; return value } }
        }
        let counter = Counter(), name = self.name, clock = self.clock, server = self.server
        var timing = SyncTiming()
        timing.debounce = .seconds(600)
        timing.maxWait = .seconds(600)
        timing.firstRetry = .seconds(600)
        return ProgressSync(
            publicationId: publicationId,
            store: store,
            remote: { try await server.save($0, $1) },
            timing: timing,
            now: { clock.now },
            newMutationId: { "\(name)-\(UUID().uuidString.prefix(4))-\(counter.next())" }
        )
    }
}

/// 2026-11-07T09:00:00Z.
let baseTime: Int64 = 1_794_042_000_000

func seconds(_ value: Double, asset: String = "a") -> SavedPosition {
    SavedPosition(assetId: asset, positionSeconds: value)
}

func audiobook(_ tracks: [String] = ["a"]) -> Publication {
    Publication(id: "p", title: "T", bookType: .audiobook, assets: tracks.enumerated().map {
        Asset(id: $1, mediaType: "audio/mpeg", format: "mp3", contentUrl: "/\($1)", position: $0)
    })
}

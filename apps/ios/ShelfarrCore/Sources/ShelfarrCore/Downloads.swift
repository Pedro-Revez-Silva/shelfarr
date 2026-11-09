import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum DownloadState: String, Codable, Sendable {
    case queued, downloading, ready, failed, cancelled
}

/// Why a download stopped. Each needs different words and a different fix.
public enum DownloadProblem: String, Codable, Sendable {
    /// No connection. Retried when the app returns to the foreground.
    case offline
    /// The system stopped the transfer: the app was force-quit, or iOS withdrew its
    /// background time. Retried when the app returns to the foreground.
    case interrupted
    /// The server's certificate could not be trusted. Never retried silently.
    case certificate
    /// The sign-in ended. Resumes after signing in to the same account again.
    case signIn
    case forbidden
    case notFound
    case server
    case redirect
    /// The file on the server changed under the pinned edition. Nothing was overwritten.
    case changed
    /// The server sent something that isn't the expected file.
    case invalid
    /// Not enough space, or the device refused the write.
    case storage
    /// Files that were complete are no longer on the device.
    case missing
    /// The publication has no file this app can download and open.
    case unsupported
}

/// One pinned asset of a managed download.
public struct DownloadedFile: Codable, Equatable, Sendable {
    public let assetId: String
    /// Local file name inside the publication's folder.
    public let name: String
    public let sizeBytes: Int64
    /// The strong validator every range of this file is requested against.
    public var etag: String?
    public var complete: Bool
    /// Bytes on disk, kept current in memory; recomputed from disk on load.
    public var bytesDone: Int64
    /// The length the server stated, when the publication didn't.
    public var length: Int64?

    public init(assetId: String, name: String, sizeBytes: Int64, etag: String? = nil, complete: Bool = false, bytesDone: Int64 = 0, length: Int64? = nil) {
        self.assetId = assetId
        self.name = name
        self.sizeBytes = sizeBytes
        self.etag = etag
        self.complete = complete
        self.bytesDone = bytesDone
        self.length = length
    }

    /// The length this file must have on disk, when anyone stated one.
    public var expectedBytes: Int64? {
        if sizeBytes > 0 { return sizeBytes }
        return length.flatMap { $0 > 0 ? $0 : nil }
    }

    func reset() -> DownloadedFile {
        DownloadedFile(assetId: assetId, name: name, sizeBytes: sizeBytes)
    }
}

/// A publication kept on this device by the user's choice. It pins one edition: the
/// exact asset ids it started with, and is only `ready` once every file is complete.
public struct DownloadRecord: Codable, Equatable, Sendable, Identifiable {
    public let publicationId: String
    public var publication: Publication
    public var files: [DownloadedFile]
    public var state: DownloadState
    public var problem: DownloadProblem?
    public var updatedAt: Date

    public var id: String { publicationId }

    public init(publicationId: String, publication: Publication, files: [DownloadedFile], state: DownloadState, problem: DownloadProblem? = nil, updatedAt: Date = Date()) {
        self.publicationId = publicationId
        self.publication = publication
        self.files = files
        self.state = state
        self.problem = problem
        self.updatedAt = updatedAt
    }

    public var pinnedAssetIds: [String] { files.map(\.assetId) }

    /// Nil when the server didn't state every size, so no honest total exists.
    public var bytesTotal: Int64? {
        files.contains { $0.sizeBytes <= 0 } ? nil : files.reduce(0) { $0 + $1.sizeBytes }
    }

    public var bytesDone: Int64 {
        files.reduce(0) { $0 + ($1.complete ? max($1.sizeBytes, $1.bytesDone) : $1.bytesDone) }
    }

    public var fraction: Double? {
        guard let total = bytesTotal, total > 0 else { return nil }
        return min(1, max(0, Double(bytesDone) / Double(total)))
    }

    public var isReady: Bool { state == .ready }
    public var isActive: Bool { state == .queued || state == .downloading }

    /// True when `current` is the same edition this download pinned.
    public func matches(_ current: Publication) -> Bool {
        current.playableAssets.map(\.id) == pinnedAssetIds
    }
}

/// One request handed to an executor: a byte range of one pinned file. It is written to
/// the manifest before the transfer starts, so a relaunched app knows what every system
/// task is for, and which credential it was sent with.
public struct TransferTicket: Codable, Equatable, Sendable {
    public let id: String
    public let publicationId: String
    public let assetId: String
    /// First byte requested.
    public let start: Int64
    /// Last byte requested, inclusive. Nil asks for the whole file without a range.
    public let end: Int64?
    /// The strong ETag sent as `If-Range`, or required of a whole-file response.
    public let validator: String?
    /// A fingerprint of the token the request carried, or that minted its grant. Never the token itself.
    public let credential: String
    /// True when the request carries an asset grant and runs in the background executor;
    /// otherwise it carries the bearer and runs in the foreground one.
    public let background: Bool?
    public let createdAt: Date
    /// Set once the response body is staged and waiting to be appended, in order.
    public var staged: Int64?
}

private struct EditionChanged: Error {}
private struct StorageFailure: Error {}
private struct Unsupported: Error {}
private struct LeftServer: Error {}
private struct GrantRejected: Error {}

/// Where a download manager's transfers run.
public struct DownloadExecutors: Sendable {
    /// Runs in this process with the bearer token. Its transport must refuse redirects
    /// that leave the server, as `URLSessionTransport` does.
    public let foreground: DownloadExecutor
    /// Outlives the process, such as a system background session. It only ever gets
    /// requests authorized by an asset grant, never the bearer token, because it follows
    /// redirects on its own and keeps requests outside the Keychain.
    public let background: DownloadExecutor?
    /// Mints the grant for one asset with the bearer token. A 404 means the server has no
    /// grants, and that account's transfers stay in the foreground.
    public let mintGrant: (@Sendable (_ publicationId: String, _ assetId: String) async throws -> TransferGrant)?

    public init(foreground: DownloadExecutor, background: DownloadExecutor? = nil, mintGrant: (@Sendable (String, String) async throws -> TransferGrant)? = nil) {
        self.foreground = foreground
        self.background = mintGrant == nil ? nil : background
        self.mintGrant = background == nil ? nil : mintGrant
    }

    var all: [DownloadExecutor] { [foreground] + (background.map { [$0] } ?? []) }
}

/// Managed downloads for one account: durable files in Application Support, never the
/// evictable caches directory.
///
/// This actor alone owns the account's download files and its manifest. Every transfer
/// is a persisted ticket: a byte range of one pinned file, requested with `If-Range`
/// against the file's strong validator. When the server issues asset grants, tickets run
/// in the background executor (in the app, a system background session, so they continue
/// while the app is suspended or after the system ends it) with a grant and no bearer.
/// Otherwise they run in the foreground executor with this account's bearer, only while
/// the app runs. Bodies arrive through a `TransferRouter`, are staged, and are appended
/// strictly in order, so the bytes on disk are always a verified prefix of one edition.
///
/// `close()` stops every transfer before the caller deletes `root`.
public actor DownloadManager: TransferSink {
    public typealias Observer = @Sendable ([String: DownloadRecord]) -> Void

    private let root: URL
    private let account: String
    /// The tag of the token this account's requests use now. It changes only when a
    /// replacement token for the same sign-in is handed over in place.
    private let currentCredential: @Sendable () -> String
    private var credential: String { currentCredential() }
    private let transport: HTTPTransport
    private let executors: DownloadExecutors
    private let router: TransferRouter
    private let server: ServerAddress
    private let authorize: @Sendable (URL) -> URLRequest
    private let fetchPublication: @Sendable (String) async throws -> Publication
    private let maxConcurrent: Int
    private let chunkSize: Int64
    private let maxTicketsPerLane: Int
    private let usableSpace: @Sendable () -> Int64?
    /// Told the tag of the credential the server refused, only when it was the current one.
    private let onUnauthorized: @Sendable (_ refusedCredential: String) -> Void
    private let files = FileManager.default

    private var records: [String: DownloadRecord] = [:] {
        didSet { if records != oldValue { observers.values.forEach { $0(records) } } }
    }
    private var tickets: [String: TransferTicket] = [:]
    private var receiving: [String: Int64] = [:]
    private var observers: [UUID: Observer] = [:]
    private var loaded = false
    private var closed = false
    /// Publications with transfers in flight or being planned; at most `maxConcurrent`.
    private var lanes: Set<String> = []
    private var waiting: [String] = []
    private var preparing: [String: Task<Void, Never>] = [:]
    /// Bumped whenever a lane is stopped, so planning that was in flight gives up.
    private var epochs: [String: Int] = [:]
    /// Set once the server answered that it has no asset grants.
    private var grantsUnsupported = false
    /// Grant rejections per publication since it last made progress.
    private var grantRejections: [String: Int] = [:]

    private static let part = ".part"
    private static let spaceMargin: Int64 = 64 << 20
    private static let transient: Set<DownloadProblem> = [.offline, .interrupted, .server]

    public init(
        root: URL,
        account: String,
        credential: String,
        transport: HTTPTransport,
        executors: DownloadExecutors,
        router: TransferRouter,
        server: ServerAddress,
        authorize: @escaping @Sendable (URL) -> URLRequest,
        fetchPublication: @escaping @Sendable (String) async throws -> Publication,
        maxConcurrent: Int = 2,
        chunkSize: Int64 = 32 << 20,
        maxTicketsPerLane: Int = 64,
        usableSpace: @escaping @Sendable () -> Int64? = { nil },
        onUnauthorized: @escaping @Sendable () -> Void = {}
    ) {
        self.init(
            root: root, account: account, currentCredential: { credential }, transport: transport, executors: executors,
            router: router, server: server, authorize: authorize, fetchPublication: fetchPublication,
            maxConcurrent: maxConcurrent, chunkSize: chunkSize, maxTicketsPerLane: maxTicketsPerLane,
            usableSpace: usableSpace, onUnauthorized: { _ in onUnauthorized() }
        )
    }

    /// For a sign-in whose token can be replaced in place. `currentCredential` is the
    /// `credentialTag` of the token `authorize` and `executors.mintGrant` use at that
    /// moment; it must change no later than they do. Transfers already sent with the
    /// earlier token keep running, and if that token is refused they are planned again
    /// with the new one rather than signing the account out. `onUnauthorized` gets the
    /// tag that was refused, so the caller can tell it from a token handed over since.
    public init(
        root: URL,
        account: String,
        currentCredential: @escaping @Sendable () -> String,
        transport: HTTPTransport,
        executors: DownloadExecutors,
        router: TransferRouter,
        server: ServerAddress,
        authorize: @escaping @Sendable (URL) -> URLRequest,
        fetchPublication: @escaping @Sendable (String) async throws -> Publication,
        maxConcurrent: Int = 2,
        chunkSize: Int64 = 32 << 20,
        maxTicketsPerLane: Int = 64,
        usableSpace: @escaping @Sendable () -> Int64? = { nil },
        onUnauthorized: @escaping @Sendable (_ refusedCredential: String) -> Void = { _ in }
    ) {
        self.root = root
        self.account = account
        self.currentCredential = currentCredential
        self.transport = transport
        self.executors = executors
        self.router = router
        self.server = server
        self.authorize = authorize
        self.fetchPublication = fetchPublication
        self.maxConcurrent = max(1, maxConcurrent)
        self.chunkSize = max(1, chunkSize)
        self.maxTicketsPerLane = max(1, maxTicketsPerLane)
        self.usableSpace = usableSpace
        self.onUnauthorized = onUnauthorized
    }

    /// A stable fingerprint of a token, so a ticket can name the credential it used.
    public static func credentialTag(_ token: String) -> String {
        String(SHA256.hexDigest(Data("shelfarr-download\n\(token)".utf8)).prefix(16))
    }

    private var manifest: URL { root.appendingPathComponent("manifest.json") }
    private nonisolated var staging: URL { root.appendingPathComponent("staging", isDirectory: true) }

    /// Starts receiving this account's transfer events. Call before the executor can
    /// deliver any, then `start()`.
    public nonisolated func connect() {
        router.register(account: account, staging: staging, sink: self)
    }

    // MARK: Reading

    public func observe(_ observer: @escaping Observer) -> UUID {
        load()
        let id = UUID()
        observers[id] = observer
        observer(records)
        return id
    }

    public func stopObserving(_ id: UUID) { observers[id] = nil }

    public var all: [String: DownloadRecord] {
        load()
        return records
    }

    public func record(_ publicationId: String) -> DownloadRecord? {
        load()
        return records[publicationId]
    }

    /// Tickets in the manifest; for tests and diagnostics.
    public var pendingTickets: [TransferTicket] {
        load()
        return tickets.values.sorted { ($0.publicationId, $0.assetId, $0.start) < ($1.publicationId, $1.assetId, $1.start) }
    }

    /// A finished download, or nil. Partial downloads are never offered for reading.
    public func ready(_ publicationId: String) -> DownloadRecord? {
        record(publicationId).flatMap { $0.isReady ? $0 : nil }
    }

    /// The verified local file for one pinned asset of a ready download.
    public func fileURL(_ record: DownloadRecord, assetId: String) -> URL? {
        guard record.isReady, let pinned = record.files.first(where: { $0.assetId == assetId && $0.complete }) else { return nil }
        let url = folder(record.publicationId).appendingPathComponent(pinned.name)
        return files.fileExists(atPath: url.path) ? url : nil
    }

    /// Local files for every pinned asset, or nil unless the whole download is ready.
    public func fileURLs(_ record: DownloadRecord) -> [String: URL]? {
        var found: [String: URL] = [:]
        for file in record.files {
            guard let url = fileURL(record, assetId: file.assetId) else { return nil }
            found[file.assetId] = url
        }
        return found.isEmpty ? nil : found
    }

    // MARK: Actions

    /// Loads the manifest, reconciles it with the transfers the executor still holds,
    /// and resumes unfinished work.
    public func start() async {
        load()
        guard !closed else { return }
        connect()
        await reconcileWithExecutor()
        guard !closed else { return }
        for record in records.values.sorted(by: { $0.updatedAt < $1.updatedAt })
            where record.isActive || (record.state == .failed && record.problem == .signIn) {
            schedule(record.publicationId)
        }
    }

    /// Queues `publication`. The transfer fetches the current edition first, so a
    /// download never pins details that were already stale on screen.
    public func enqueue(_ publication: Publication) {
        guard !closed else { return }
        load()
        let existing = records[publication.id]
        if let existing, existing.isActive { return }
        grantRejections[publication.id] = nil
        if let existing, existing.matches(publication), existing.state != .cancelled {
            var record = existing
            record.state = .queued
            record.problem = nil
            record.publication = publication
            record.updatedAt = Date()
            guard save(record) else { return }
        } else {
            if existing != nil {
                discardTickets(publication.id)
                try? files.removeItem(at: folder(publication.id))
            }
            guard save(DownloadRecord(publicationId: publication.id, publication: publication, files: pin(publication.playableAssets), state: .queued)) else { return }
        }
        schedule(publication.id)
    }

    /// Retries a failed or cancelled download with the details it already has.
    public func retry(_ publicationId: String) {
        guard let record = record(publicationId) else { return }
        enqueue(record.publication)
    }

    /// Resumes downloads that stopped for a reason that may have passed, such as the connection.
    public func retryInterrupted() {
        load()
        for record in records.values where record.state == .failed && record.problem.map(Self.transient.contains) == true {
            retry(record.publicationId)
        }
    }

    /// Stops the transfers and deletes what they wrote. The entry stays, marked cancelled.
    public func cancel(_ publicationId: String) async {
        load()
        await stop(publicationId)
        try? files.removeItem(at: folder(publicationId))
        guard var record = records[publicationId] else { return }
        record.state = .cancelled
        record.problem = nil
        record.files = record.files.map { $0.reset() }
        record.updatedAt = Date()
        save(record)
        pump()
    }

    /// Stops any transfer and deletes the download and its entry.
    public func remove(_ publicationId: String) async {
        load()
        await stop(publicationId)
        try? files.removeItem(at: folder(publicationId))
        let removed = records.removeValue(forKey: publicationId)
        if !persist(), var record = removed {
            record.state = .failed
            record.problem = .storage
            record.files = record.files.map { $0.reset() }
            records[publicationId] = record
        }
        pump()
    }

    /// Stops every transfer and all further writes. The caller may then delete `root`.
    public func close() async {
        guard !closed else { return }
        closed = true
        router.unregister(account: account, sink: self)
        waiting.removeAll()
        let planning = Array(preparing.values)
        preparing.removeAll()
        planning.forEach { $0.cancel() }
        for executor in executors.all {
            var tags = Set(tickets.keys.map { TransferTag(account: account, ticket: $0) })
            tags.formUnion(await executor.live().filter { $0.account == account })
            await executor.cancel(Array(tags))
        }
        for task in planning { await task.value }
        observers.removeAll()
    }

    /// Revokes, cancels and forgets every ticket of a publication, staged ones included.
    private func stop(_ publicationId: String) async {
        epochs[publicationId, default: 0] += 1
        waiting.removeAll { $0 == publicationId }
        lanes.remove(publicationId)
        let planning = preparing.removeValue(forKey: publicationId)
        planning?.cancel()
        await cancelTransfers(discardTickets(publicationId))
        await planning?.value
    }

    /// Cancels in-flight transfers in whichever executor runs them. Their tickets are already revoked.
    private func cancelTransfers(_ stopped: [TransferTicket]) async {
        let inFlight = stopped.filter { $0.staged == nil }
        guard !inFlight.isEmpty else { return }
        let background = inFlight.filter { $0.background == true }.map { TransferTag(account: account, ticket: $0.id) }
        let foreground = inFlight.filter { $0.background != true }.map { TransferTag(account: account, ticket: $0.id) }
        if !foreground.isEmpty { await executors.foreground.cancel(foreground) }
        if !background.isEmpty { await executors.background?.cancel(background) }
    }

    private func cancelLater(_ stopped: [TransferTicket]) {
        guard stopped.contains(where: { $0.staged == nil }) else { return }
        Task { await self.cancelTransfers(stopped) }
    }

    /// Forgets a publication's tickets, deleting staged bodies, and returns them for cancelling.
    @discardableResult
    private func discardTickets(_ publicationId: String, keepStaged: Bool = false) -> [TransferTicket] {
        let found = tickets.values.filter { $0.publicationId == publicationId && !(keepStaged && $0.staged != nil) }
        router.revoke(found.map(\.id))
        for ticket in found {
            tickets[ticket.id] = nil
            receiving[ticket.id] = nil
            try? files.removeItem(at: stagedBody(ticket.id))
        }
        return found
    }

    // MARK: Queue

    private func schedule(_ publicationId: String) {
        guard !closed, !lanes.contains(publicationId), !waiting.contains(publicationId) else { return }
        waiting.append(publicationId)
        pump()
    }

    private func pump() {
        while !closed, lanes.count < maxConcurrent, !waiting.isEmpty {
            let id = waiting.removeFirst()
            lanes.insert(id)
            plan(id)
        }
    }

    private func release(_ publicationId: String) {
        lanes.remove(publicationId)
        pump()
    }

    private func plan(_ publicationId: String) {
        guard !closed, preparing[publicationId] == nil else { return }
        let epoch = epochs[publicationId, default: 0]
        preparing[publicationId] = Task { [weak self] in
            await self?.prepare(publicationId, epoch)
            await self?.prepared(publicationId, epoch)
        }
    }

    private func prepared(_ publicationId: String, _ epoch: Int) {
        guard epochs[publicationId, default: 0] == epoch else { return }
        preparing[publicationId] = nil
    }

    private func current(_ publicationId: String, _ epoch: Int) -> Bool {
        !closed && !Task.isCancelled && epochs[publicationId, default: 0] == epoch && lanes.contains(publicationId)
    }

    private func ticketsFor(_ publicationId: String, _ assetId: String? = nil) -> [TransferTicket] {
        tickets.values.filter { $0.publicationId == publicationId && (assetId == nil || $0.assetId == assetId) }
    }

    /// Re-pins against the server and hands the executor every range not yet on the
    /// device or in flight. A relaunched app whose ranges are all in flight does nothing.
    private func prepare(_ publicationId: String, _ epoch: Int) async {
        guard var record = records[publicationId],
              record.isActive || (record.state == .failed && record.problem == .signIn)
        else { return release(publicationId) }
        do {
            if !needsPlanning(record) {
                // Everything is on the device or in flight, as after a relaunch: no network needed.
                if record.state != .downloading || record.problem != nil {
                    record.state = .downloading
                    record.problem = nil
                    guard save(record) else { return release(publicationId) }
                }
                for file in record.files where !file.complete && ticketsFor(publicationId, file.assetId).contains(where: { $0.staged != nil }) {
                    try assemble(publicationId, file.assetId)
                }
                return try completeIfReady(publicationId)
            }
            // Re-pin against the server's current edition before moving any bytes.
            let current = try await fetchPublication(publicationId)
            guard self.current(publicationId, epoch) else { return }
            record = records[publicationId] ?? record
            if !record.matches(current) {
                await cancelTransfers(discardTickets(publicationId))
                guard self.current(publicationId, epoch) else { return }
                try? files.removeItem(at: folder(publicationId))
                record.files = pin(current.playableAssets)
            }
            if record.files.isEmpty { throw Unsupported() }
            record.publication = current
            record.state = .downloading
            record.problem = nil
            record.updatedAt = Date()
            guard save(record) else { return release(publicationId) }

            let remaining = record.files.filter { !$0.complete }.reduce(Int64(0)) { $0 + max(0, $1.sizeBytes - $1.bytesDone) }
            if let space = usableSpace(), space < remaining + Self.spaceMargin { throw StorageFailure() }

            let assets = Dictionary(current.playableAssets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for pinned in record.files where !pinned.complete {
                guard let asset = assets[pinned.assetId] else { throw EditionChanged() }
                try await planFile(publicationId, asset, epoch)
                guard self.current(publicationId, epoch) else { return }
                if ticketsFor(publicationId).count >= maxTicketsPerLane { break }
            }
            try completeIfReady(publicationId)
        } catch is CancellationError {
            return
        } catch {
            guard self.current(publicationId, epoch) else { return }
            fail(publicationId, Self.classify(error))
        }
    }

    /// True when some byte of an unfinished file is neither on disk nor requested.
    private func needsPlanning(_ record: DownloadRecord) -> Bool {
        for file in record.files where !file.complete {
            let pending = ticketsFor(record.publicationId, file.assetId)
            if pending.contains(where: { $0.end == nil }) { continue }
            guard let length = file.expectedBytes, file.etag != nil else { return true }
            var cursor = Self.size(of: partial(record.publicationId, file))
            for ticket in pending.sorted(by: { $0.start < $1.start }) where ticket.start <= cursor {
                cursor = max(cursor, (ticket.end ?? length - 1) + 1)
            }
            if cursor < length { return true }
        }
        return false
    }

    private func planFile(_ publicationId: String, _ asset: Asset, _ epoch: Int) async throws {
        guard let url = server.resolve(asset.contentUrl), server.contains(url) else { throw APIError.protocolError }
        guard let pinned = records[publicationId]?.files.first(where: { $0.assetId == asset.id }) else { throw EditionChanged() }
        if pinned.complete { return }
        do {
            try files.createDirectory(at: folder(publicationId), withIntermediateDirectories: true)
        } catch {
            throw StorageFailure()
        }

        // The foreground transport refuses redirects that leave the server; a system
        // background session would follow them. Checking first keeps the token here.
        let head = try await preflight(url)
        guard current(publicationId, epoch) else { throw CancellationError() }
        guard let file = records[publicationId]?.files.first(where: { $0.assetId == asset.id }), !file.complete else { return }
        let part = partial(publicationId, file)
        let sidecar = folder(publicationId).appendingPathComponent(file.name + ".etag")
        let stored = file.etag ?? (try? String(contentsOf: sidecar, encoding: .utf8))
        let strong = head?.etag.flatMap { $0.hasPrefix("W/") ? nil : $0 }
        if let stated = head?.length, asset.sizeBytes > 0, stated != asset.sizeBytes { throw APIError.protocolError }
        let length = asset.sizeBytes > 0 ? asset.sizeBytes : (head?.length ?? 0)

        var existing = ticketsFor(publicationId, asset.id)
        let holdsBytes = Self.size(of: part) > 0 || !existing.isEmpty
        if holdsBytes, let stored, stored != strong {
            throw EditionChanged()
        }
        if holdsBytes, stored == nil {
            // Bytes without a validator can't be proven to be this edition.
            await cancelTransfers(discardFile(publicationId, asset.id))
            guard current(publicationId, epoch) else { throw CancellationError() }
            existing = []
        }
        try? files.removeItem(at: sidecar)
        updateFile(publicationId, asset.id) {
            $0.etag = strong
            $0.length = length > 0 ? length : nil
        }

        let offset = Self.size(of: part)
        if strong != nil, length > 0, offset >= length {
            try finishFile(publicationId, asset)
            return
        }
        // The grant, if any, is minted before anything is planned: its URL is the request.
        let target = try await transferURL(publicationId, asset, contentURL: url)
        guard current(publicationId, epoch) else { throw CancellationError() }
        let background = target.background
        var planned: [TransferTicket] = []
        if strong == nil || length <= 0 {
            if existing.isEmpty { planned.append(ticket(publicationId, asset.id, start: 0, end: nil, validator: strong, background: background)) }
        } else if offset == 0, existing.isEmpty, length <= chunkSize {
            planned.append(ticket(publicationId, asset.id, start: 0, end: nil, validator: strong, background: background))
        } else {
            var cursor = offset
            let covered = existing.sorted { $0.start < $1.start }
            let budget = max(0, maxTicketsPerLane - ticketsFor(publicationId).count)
            var index = 0
            while cursor < length, planned.count < budget {
                while index < covered.count, (covered[index].end ?? length - 1) < cursor { index += 1 }
                if index < covered.count, covered[index].start <= cursor {
                    cursor = (covered[index].end ?? length - 1) + 1
                    continue
                }
                let limit = index < covered.count ? covered[index].start : length
                let end = min(cursor + chunkSize, limit) - 1
                planned.append(ticket(publicationId, asset.id, start: cursor, end: end, validator: strong, background: background))
                cursor = end + 1
            }
        }
        guard !planned.isEmpty else { return }

        // The mapping is durable before any transfer exists.
        for ticket in planned { tickets[ticket.id] = ticket }
        guard persist() else {
            for ticket in planned { tickets[ticket.id] = nil }
            throw StorageFailure()
        }
        for ticket in planned {
            var request: URLRequest
            let executor: DownloadExecutor
            if background, let runner = executors.background {
                // No bearer: the grant in the URL is the only credential this request holds.
                request = URLRequest(url: target.url)
                executor = runner
            } else {
                request = authorize(url)
                executor = executors.foreground
            }
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            if let end = ticket.end, let validator = ticket.validator {
                request.setValue("bytes=\(ticket.start)-\(end)", forHTTPHeaderField: "Range")
                request.setValue(validator, forHTTPHeaderField: "If-Range")
            }
            let expected = ticket.end.map { $0 - ticket.start + 1 } ?? (length > 0 ? length : nil)
            do {
                try executor.submit(request, tag: TransferTag(account: account, ticket: ticket.id), expectedBytes: expected)
            } catch {
                tickets[ticket.id] = nil
                persist()
                throw StorageFailure()
            }
        }
    }

    private func ticket(_ publicationId: String, _ assetId: String, start: Int64, end: Int64?, validator: String?, background: Bool) -> TransferTicket {
        TransferTicket(
            id: UUID().uuidString.lowercased(),
            publicationId: publicationId,
            assetId: assetId,
            start: start,
            end: end,
            validator: validator,
            credential: credential,
            background: background,
            createdAt: Date()
        )
    }

    /// The URL a file's tickets request: a grant URL for the background executor, or the
    /// asset's own URL for the foreground one when the server issues no grants.
    private func transferURL(_ publicationId: String, _ asset: Asset, contentURL: URL) async throws -> (url: URL, background: Bool) {
        guard let mint = executors.mintGrant, !grantsUnsupported else { return (contentURL, false) }
        let grant: TransferGrant
        let minting = credential
        do {
            grant = try await mint(publicationId, asset.id)
        } catch APIError.notFound {
            // The asset answered the preflight, so a 404 here means no grant endpoint.
            grantsUnsupported = true
            return (contentURL, false)
        } catch APIError.unauthorized {
            onUnauthorized(minting)
            throw APIError.unauthorized
        }
        // A grant is only ever sent to this server, inside its subpath.
        guard let url = server.resolve(grant.url), server.contains(url) else { throw APIError.protocolError }
        return (url, true)
    }

    private struct Preflight {
        let etag: String?
        let length: Int64?
    }

    private func preflight(_ url: URL) async throws -> Preflight? {
        // Read before `authorize`, so the tag is never newer than the token sent.
        let sent = credential
        var request = authorize(url)
        request.httpMethod = "HEAD"
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let (_, response) = try await transport.send(request)
        switch response.statusCode {
        case 200 ..< 300:
            return Preflight(
                etag: response.value(forHTTPHeaderField: "ETag"),
                length: response.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
            )
        case 405, 501:
            return nil
        case 401:
            onUnauthorized(sent)
            throw APIError.unauthorized
        default:
            throw Self.failure(response.statusCode)
        }
    }

    // MARK: Events

    public func progress(ticket: String, received: Int64) {
        guard let found = tickets[ticket], found.staged == nil else { return }
        receiving[ticket] = received
        refreshBytes(found.publicationId, found.assetId)
    }

    public func deliver(_ event: TransferEvent) async {
        load()
        guard !closed, let ticket = tickets[event.ticket] else {
            if case let .response(_, _, _, body?, _) = event.outcome { try? files.removeItem(at: body) }
            return
        }
        receiving[ticket.id] = nil
        let publicationId = ticket.publicationId
        guard let record = records[publicationId], record.isActive else {
            tickets[ticket.id] = nil
            try? files.removeItem(at: stagedBody(ticket.id))
            persist()
            return
        }
        do {
            switch event.outcome {
            case let .failed(failure):
                tickets[ticket.id] = nil
                persist()
                if ticket.credential != credential, failure != .certificate {
                    return replan(publicationId)
                }
                switch failure {
                case .offline: throw APIError.offline(certificate: false)
                case .interrupted, .cancelled: return fail(publicationId, .interrupted)
                case .certificate: throw APIError.offline(certificate: true)
                case .redirect: throw APIError.redirectBlocked("")
                }
            case let .response(status, headers, finalURL, body, storageFailed):
                try accept(ticket, status: status, headers: headers, finalURL: finalURL, body: body, storageFailed: storageFailed)
            }
        } catch {
            fail(publicationId, Self.classify(error))
        }
    }

    private func accept(_ ticket: TransferTicket, status: Int, headers: [String: String], finalURL: URL?, body: URL?, storageFailed: Bool) throws {
        let staged = stagedBody(ticket.id)
        var keep = false
        defer { if !keep, let body { try? files.removeItem(at: body) } }
        tickets[ticket.id] = nil
        // A background session follows redirects on its own. Bytes from elsewhere are never used.
        if let finalURL, !server.contains(finalURL) { throw LeftServer() }
        guard let record = records[ticket.publicationId], let file = record.files.first(where: { $0.assetId == ticket.assetId }) else {
            persist()
            return
        }
        let tag = headers["etag"]
        switch status {
        case 200:
            guard let body else { throw storageFailed ? StorageFailure() : APIError.protocolError }
            if let validator = ticket.validator, tag != validator { throw EditionChanged() }
            // The whole file, whatever was requested: it replaces every partial byte.
            cancelLater(discardFile(ticket.publicationId, ticket.assetId))
            let part = partial(ticket.publicationId, file)
            try? files.removeItem(at: part)
            do {
                try files.moveItem(at: body, to: part)
            } catch {
                throw StorageFailure()
            }
            keep = true
            grantRejections[ticket.publicationId] = nil
            updateFile(ticket.publicationId, ticket.assetId) { $0.etag = tag.flatMap { $0.hasPrefix("W/") ? nil : $0 } }
            guard let asset = assetFor(ticket.publicationId, ticket.assetId) else { throw EditionChanged() }
            try finishFile(ticket.publicationId, asset)
        case 206:
            guard let body else { throw storageFailed ? StorageFailure() : APIError.protocolError }
            guard let validator = ticket.validator else { throw APIError.protocolError }
            if let tag, tag != validator { throw EditionChanged() }
            guard let range = Self.contentRange(headers["content-range"]), range.start == ticket.start,
                  ticket.end == nil || range.end == ticket.end
            else { throw APIError.protocolError }
            let length = Self.size(of: body)
            guard length == range.end - range.start + 1 else { throw APIError.protocolError }
            if body.standardizedFileURL != staged.standardizedFileURL {
                try? files.removeItem(at: staged)
                do {
                    try files.moveItem(at: body, to: staged)
                } catch {
                    throw StorageFailure()
                }
            }
            keep = true
            grantRejections[ticket.publicationId] = nil
            var waiting = ticket
            waiting.staged = length
            tickets[ticket.id] = waiting
            try assemble(ticket.publicationId, ticket.assetId)
        case 401:
            if ticket.background == true {
                // Retire this whole in-flight window before retrying. Its ranges
                // share one grant; their late 401s are one rejection, not several.
                // Valid staged bytes remain available for ordered assembly.
                epochs[ticket.publicationId, default: 0] += 1
                preparing.removeValue(forKey: ticket.publicationId)?.cancel()
                cancelLater(discardTickets(ticket.publicationId, keepStaged: true))
                guard persist() else { throw StorageFailure() }
                grantRejections[ticket.publicationId, default: 0] += 1
                if grantRejections[ticket.publicationId, default: 0] > 2 { throw GrantRejected() }
                return replan(ticket.publicationId)
            }
            if ticket.credential == credential {
                onUnauthorized(ticket.credential)
                throw APIError.unauthorized
            }
            persist()
            replan(ticket.publicationId)
        case 410, 412, 416:
            throw EditionChanged()
        default:
            throw Self.failure(status)
        }
    }

    /// Appends staged ranges that continue the partial file, in order.
    private func assemble(_ publicationId: String, _ assetId: String) throws {
        guard let file = records[publicationId]?.files.first(where: { $0.assetId == assetId }) else { return }
        let part = partial(publicationId, file)
        var offset = Self.size(of: part)
        var progressed = true
        while progressed {
            progressed = false
            for ticket in ticketsFor(publicationId, assetId).sorted(by: { $0.start < $1.start }) {
                guard let length = ticket.staged, ticket.start <= offset else { continue }
                let body = stagedBody(ticket.id)
                if ticket.start + length > offset {
                    do {
                        try Self.append(body, from: offset - ticket.start, to: part)
                    } catch {
                        throw StorageFailure()
                    }
                    offset = Self.size(of: part)
                }
                tickets[ticket.id] = nil
                try? files.removeItem(at: body)
                progressed = true
            }
        }
        refreshBytes(publicationId, assetId)
        guard persist() else { throw StorageFailure() }
        if let expected = file.expectedBytes, offset >= expected, ticketsFor(publicationId, assetId).isEmpty,
           let asset = assetFor(publicationId, assetId) {
            try finishFile(publicationId, asset)
        } else {
            try completeIfReady(publicationId)
        }
    }

    private func finishFile(_ publicationId: String, _ asset: Asset) throws {
        guard let file = records[publicationId]?.files.first(where: { $0.assetId == asset.id }) else { return }
        let part = partial(publicationId, file)
        let final = folder(publicationId).appendingPathComponent(file.name)
        let length = Self.size(of: part)
        let lengthOK = file.expectedBytes.map { length == $0 } ?? true
        let epubOK = !asset.isEpub || Self.head(of: part) == Data("PK".utf8)
        guard lengthOK, epubOK, length > 0 else {
            try? files.removeItem(at: part)
            updateFile(publicationId, asset.id) {
                $0.bytesDone = 0
                $0.etag = nil
            }
            throw APIError.protocolError
        }
        try? files.removeItem(at: final)
        do {
            try files.moveItem(at: part, to: final)
        } catch {
            throw StorageFailure()
        }
        updateFile(publicationId, asset.id) {
            $0.complete = true
            $0.bytesDone = length
        }
        if !persist() { throw StorageFailure() }
        try completeIfReady(publicationId)
    }

    /// Marks a download ready once every pinned file is complete, or plans what's left.
    private func completeIfReady(_ publicationId: String) throws {
        guard var record = records[publicationId], record.isActive else { return }
        if !record.files.isEmpty, record.files.allSatisfy(\.complete) {
            record.state = .ready
            record.problem = nil
            record.updatedAt = Date()
            discardTickets(publicationId)
            guard save(record) else { throw StorageFailure() }
            release(publicationId)
        } else if ticketsFor(publicationId).allSatisfy({ $0.staged != nil }) {
            replan(publicationId)
        }
    }

    /// Plans again for ranges that are no longer covered, such as after a window filled.
    private func replan(_ publicationId: String) {
        guard !closed, records[publicationId]?.isActive == true else { return }
        if lanes.contains(publicationId) {
            if preparing[publicationId] == nil { plan(publicationId) }
        } else {
            schedule(publicationId)
        }
    }

    private func fail(_ publicationId: String, _ problem: DownloadProblem) {
        epochs[publicationId, default: 0] += 1
        preparing.removeValue(forKey: publicationId)?.cancel()
        let changed = problem == .changed
        cancelLater(discardTickets(publicationId, keepStaged: !changed))
        if changed { try? files.removeItem(at: folder(publicationId)) }
        if var latest = records[publicationId] {
            if changed { latest.files = latest.files.map { $0.reset() } }
            latest.state = .failed
            latest.problem = problem
            latest.updatedAt = Date()
            records[publicationId] = latest
            for file in latest.files where !file.complete { refreshBytes(publicationId, file.assetId) }
            save(records[publicationId] ?? latest)
        }
        release(publicationId)
    }

    /// Forgets one file's tickets and partial bytes; returns them for cancelling.
    private func discardFile(_ publicationId: String, _ assetId: String) -> [TransferTicket] {
        let found = ticketsFor(publicationId, assetId)
        router.revoke(found.map(\.id))
        for ticket in found {
            tickets[ticket.id] = nil
            receiving[ticket.id] = nil
            try? files.removeItem(at: stagedBody(ticket.id))
        }
        if let file = records[publicationId]?.files.first(where: { $0.assetId == assetId }) {
            try? files.removeItem(at: partial(publicationId, file))
        }
        updateFile(publicationId, assetId) { $0.bytesDone = 0 }
        return found
    }

    private func assetFor(_ publicationId: String, _ assetId: String) -> Asset? {
        records[publicationId]?.publication.playableAssets.first { $0.id == assetId }
    }

    private func refreshBytes(_ publicationId: String, _ assetId: String) {
        guard let file = records[publicationId]?.files.first(where: { $0.assetId == assetId }), !file.complete else { return }
        let pending = ticketsFor(publicationId, assetId)
        let bytes = Self.size(of: partial(publicationId, file))
            + pending.reduce(Int64(0)) { $0 + ($1.staged ?? receiving[$1.id] ?? 0) }
        updateFile(publicationId, assetId) { $0.bytesDone = bytes }
    }

    // MARK: Reconciling

    /// Matches the manifest's tickets against the executor's live transfers: lost
    /// tickets are dropped so their ranges are planned again, and transfers that no
    /// ticket owns, or that carry a credential this account no longer uses, are cancelled.
    private func reconcileWithExecutor() async {
        var held: [(DownloadExecutor, [TransferTag])] = []
        for executor in executors.all {
            held.append((executor, await executor.live().filter { $0.account == account }))
        }
        guard !closed else { return }
        let busy = router.busyTickets()
        let live = Set(held.flatMap { $0.1.map(\.ticket) }).union(busy)
        var stale: Set<String> = []
        var changed = false
        for ticket in tickets.values where ticket.staged == nil {
            if !live.contains(ticket.id) {
                tickets[ticket.id] = nil
                changed = true
            } else if ticket.credential != credential {
                // Sent with, or minted by, a token this account no longer uses.
                tickets[ticket.id] = nil
                stale.insert(ticket.id)
                changed = true
            }
        }
        let cancel = held.map { executor, tags in (executor, tags.filter { tickets[$0.ticket] == nil || stale.contains($0.ticket) }) }
        router.revoke(cancel.flatMap { $0.1.map(\.ticket) })
        // Bodies that no ticket waits for were left by a process that stopped mid-way.
        let waitingFor = Set(tickets.values.filter { $0.staged != nil }.map(\.id))
        if let leftovers = try? files.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
            for file in leftovers where !waitingFor.contains(file.deletingPathExtension().lastPathComponent) {
                if !live.contains(file.deletingPathExtension().lastPathComponent) { try? files.removeItem(at: file) }
            }
        }
        if changed {
            for record in records.values where record.isActive {
                for file in record.files where !file.complete { refreshBytes(record.publicationId, file.assetId) }
            }
            persist()
        }
        for (executor, tags) in cancel where !tags.isEmpty { await executor.cancel(tags) }
    }

    // MARK: Storage

    private struct Manifest: Codable {
        var version: Int
        var records: [String: DownloadRecord]
        var tickets: [String: TransferTicket]
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: manifest) else { return }
        let stored: [String: DownloadRecord]
        if let current = try? JSONDecoder().decode(Manifest.self, from: data) {
            stored = current.records
            tickets = current.tickets.filter { entry in
                current.records[entry.value.publicationId]?.files.contains { $0.assetId == entry.value.assetId } == true
            }
        } else if let first = try? JSONDecoder().decode([String: DownloadRecord].self, from: data) {
            // The first manifest held only records, and transfers ran in-process.
            stored = first
        } else {
            return
        }
        for (id, ticket) in tickets where ticket.staged != nil && !files.fileExists(atPath: stagedBody(id).path) {
            tickets[id] = nil
        }
        let checked = stored.mapValues(reconcile)
        records = checked
        if checked != stored, !persist() {
            records = records.mapValues { record in
                guard record.isActive else { return record }
                var failed = record
                failed.state = .failed
                failed.problem = .storage
                return failed
            }
        }
    }

    /// Recomputes sizes from disk and refuses to call missing or short files ready.
    private func reconcile(_ record: DownloadRecord) -> DownloadRecord {
        var record = record
        let directory = folder(record.publicationId)
        record.files = record.files.map { file in
            var file = file
            let final = directory.appendingPathComponent(file.name)
            let finalSize = Self.size(of: final)
            if file.complete, files.fileExists(atPath: final.path), file.expectedBytes.map({ finalSize == $0 }) ?? true {
                file.bytesDone = finalSize
            } else if file.complete {
                file.complete = false
                file.bytesDone = 0
            } else {
                file.bytesDone = Self.size(of: partial(record.publicationId, file))
                    + tickets.values.filter { $0.publicationId == record.publicationId && $0.assetId == file.assetId }
                    .reduce(Int64(0)) { $0 + ($1.staged ?? 0) }
            }
            return file
        }
        let allComplete = !record.files.isEmpty && record.files.allSatisfy(\.complete)
        if record.state == .ready, !allComplete {
            record.state = .failed
            record.problem = .missing
        } else if record.state == .downloading {
            record.state = .queued
        }
        return record
    }

    @discardableResult
    private func save(_ record: DownloadRecord) -> Bool {
        guard !closed else { return false }
        records[record.publicationId] = record
        guard persist() else {
            // Keep the error visible even when the disk cannot persist the failure itself.
            var failed = record
            failed.state = .failed
            failed.problem = .storage
            records[record.publicationId] = failed
            return false
        }
        return true
    }

    private func updateFile(_ publicationId: String, _ assetId: String, _ change: (inout DownloadedFile) -> Void) {
        guard var record = records[publicationId], let index = record.files.firstIndex(where: { $0.assetId == assetId }) else { return }
        change(&record.files[index])
        records[publicationId] = record
    }

    @discardableResult
    private func persist() -> Bool {
        guard !closed else { return false }
        do {
            try files.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(Manifest(version: 2, records: records, tickets: tickets)).write(to: manifest, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func pin(_ assets: [Asset]) -> [DownloadedFile] {
        assets.enumerated().map { index, asset in
            DownloadedFile(assetId: asset.id, name: Self.fileName(index, asset), sizeBytes: asset.sizeBytes)
        }
    }

    private func folder(_ publicationId: String) -> URL {
        root.appendingPathComponent(String(SHA256.hexDigest(Data(publicationId.utf8)).prefix(32)), isDirectory: true)
    }

    private func partial(_ publicationId: String, _ file: DownloadedFile) -> URL {
        folder(publicationId).appendingPathComponent(file.name + Self.part)
    }

    private func stagedBody(_ ticket: String) -> URL {
        TransferRouter.stagingFile(staging, ticket: ticket)
    }

    private static func fileName(_ index: Int, _ asset: Asset) -> String {
        let allowed = { (value: String) -> String? in
            let lower = value.lowercased()
            return (1 ... 5).contains(lower.count) && lower.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } ? lower : nil
        }
        let ext = allowed(asset.format) ?? allowed((asset.filename as NSString).pathExtension) ?? "bin"
        return String(format: "%03d-", index) + String(SHA256.hexDigest(Data(asset.id.utf8)).prefix(32)) + "." + ext
    }

    static func size(of url: URL) -> Int64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        return (try? handle.seekToEnd()).map(Int64.init) ?? 0
    }

    private static func head(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: 2)
    }

    /// Appends `source` from `offset` onward to `target`, creating it if needed.
    private static func append(_ source: URL, from offset: Int64, to target: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: target.path) {
            guard manager.createFile(atPath: target.path, contents: nil) else { throw StorageFailure() }
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        try input.seek(toOffset: UInt64(max(0, offset)))
        _ = try output.seekToEnd()
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
    }

    static func contentRange(_ header: String?) -> (start: Int64, end: Int64)? {
        guard let header, header.lowercased().hasPrefix("bytes ") else { return nil }
        let spec = header.dropFirst("bytes ".count).split(separator: "/").first ?? ""
        let bounds = spec.split(separator: "-")
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]), end >= start else { return nil }
        return (start, end)
    }

    private static func failure(_ status: Int) -> APIError {
        switch status {
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 500 ..< 600: return .server(status)
        default: return .protocolError
        }
    }

    private static func classify(_ error: Error) -> DownloadProblem {
        switch error {
        case is EditionChanged: return .changed
        case is StorageFailure: return .storage
        case is Unsupported: return .unsupported
        case is LeftServer: return .redirect
        case is GrantRejected: return .server
        case let error as APIError:
            switch error {
            case let .offline(certificate): return certificate ? .certificate : .offline
            case .unauthorized: return .signIn
            case .forbidden: return .forbidden
            case .notFound: return .notFound
            case .server: return .server
            case .redirectBlocked: return .redirect
            default: return .invalid
            }
        default:
            return (error as NSError).domain == NSCocoaErrorDomain ? .storage : .invalid
        }
    }
}

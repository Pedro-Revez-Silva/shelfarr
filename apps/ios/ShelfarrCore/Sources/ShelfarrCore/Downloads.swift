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
    /// The strong validator the first response carried, used for safe resumption.
    public var etag: String?
    public var complete: Bool
    /// Bytes on disk, kept current in memory; recomputed from disk on load.
    public var bytesDone: Int64

    public init(assetId: String, name: String, sizeBytes: Int64, etag: String? = nil, complete: Bool = false, bytesDone: Int64 = 0) {
        self.assetId = assetId
        self.name = name
        self.sizeBytes = sizeBytes
        self.etag = etag
        self.complete = complete
        self.bytesDone = bytesDone
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

private struct EditionChanged: Error {}
private struct StorageFailure: Error {}
private struct Unsupported: Error {}

/// Managed downloads for one account: durable files in Application Support, never the
/// evictable caches directory. The queue is durable: unfinished work resumes when the
/// account's services start again. Transfers only run while the app is running; this
/// is not an OS background transfer.
///
/// Every request is authorized with this account's credential only. `close()` stops
/// every transfer before the caller deletes `root`.
public actor DownloadManager {
    public typealias Observer = @Sendable ([String: DownloadRecord]) -> Void

    private let root: URL
    private let transport: HTTPTransport
    private let server: ServerAddress
    private let authorize: @Sendable (URL) -> URLRequest
    private let fetchPublication: @Sendable (String) async throws -> Publication
    private let maxConcurrent: Int
    private let usableSpace: @Sendable () -> Int64?
    private let files = FileManager.default

    private var records: [String: DownloadRecord] = [:] {
        didSet { if records != oldValue { observers.values.forEach { $0(records) } } }
    }
    private var observers: [UUID: Observer] = [:]
    private var loaded = false
    private var closed = false
    private var waiting: [String] = []
    private var running: [String: Task<Void, Never>] = [:]

    private static let part = ".part"
    private static let spaceMargin: Int64 = 64 << 20
    private static let transient: Set<DownloadProblem> = [.offline, .server]

    public init(
        root: URL,
        transport: HTTPTransport,
        server: ServerAddress,
        authorize: @escaping @Sendable (URL) -> URLRequest,
        fetchPublication: @escaping @Sendable (String) async throws -> Publication,
        maxConcurrent: Int = 2,
        usableSpace: @escaping @Sendable () -> Int64? = { nil }
    ) {
        self.root = root
        self.transport = transport
        self.server = server
        self.authorize = authorize
        self.fetchPublication = fetchPublication
        self.maxConcurrent = max(1, maxConcurrent)
        self.usableSpace = usableSpace
    }

    private var manifest: URL { root.appendingPathComponent("manifest.json") }

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

    /// Loads the manifest, checks finished files are still there, and resumes unfinished work.
    public func start() {
        load()
        for record in records.values where record.isActive || (record.state == .failed && record.problem == .signIn) {
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
        if let existing, existing.matches(publication), existing.state != .cancelled {
            var record = existing
            record.state = .queued
            record.problem = nil
            record.publication = publication
            record.updatedAt = Date()
            save(record)
        } else {
            if existing != nil { try? files.removeItem(at: folder(publication.id)) }
            save(DownloadRecord(publicationId: publication.id, publication: publication, files: pin(publication.playableAssets), state: .queued))
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

    /// Stops a transfer and deletes what it wrote. The entry stays, marked cancelled.
    public func cancel(_ publicationId: String) async {
        await stop(publicationId)
        guard var record = records[publicationId] else { return }
        try? files.removeItem(at: folder(publicationId))
        record.state = .cancelled
        record.problem = nil
        record.files = record.files.map { DownloadedFile(assetId: $0.assetId, name: $0.name, sizeBytes: $0.sizeBytes) }
        record.updatedAt = Date()
        save(record)
    }

    /// Stops any transfer and deletes the download and its entry.
    public func remove(_ publicationId: String) async {
        await stop(publicationId)
        try? files.removeItem(at: folder(publicationId))
        records[publicationId] = nil
        persist()
    }

    /// Stops every transfer and all further writes. The caller may then delete `root`.
    public func close() async {
        closed = true
        waiting.removeAll()
        let tasks = Array(running.values)
        running.removeAll()
        tasks.forEach { $0.cancel() }
        for task in tasks { await task.value }
        observers.removeAll()
    }

    private func stop(_ publicationId: String) async {
        waiting.removeAll { $0 == publicationId }
        if let task = running.removeValue(forKey: publicationId) {
            task.cancel()
            await task.value
        }
    }

    // MARK: Queue

    private func schedule(_ publicationId: String) {
        guard !closed, running[publicationId] == nil, !waiting.contains(publicationId) else { return }
        waiting.append(publicationId)
        pump()
    }

    private func pump() {
        while !closed, running.count < maxConcurrent, !waiting.isEmpty {
            let id = waiting.removeFirst()
            running[id] = Task { [weak self] in
                await self?.run(id)
                await self?.finished(id)
            }
        }
    }

    private func finished(_ publicationId: String) {
        running[publicationId] = nil
        pump()
    }

    private func run(_ publicationId: String) async {
        guard var record = records[publicationId],
              record.isActive || (record.state == .failed && record.problem == .signIn)
        else { return }
        do {
            // Re-pin against the server's current edition before moving any bytes.
            let current = try await fetchPublication(publicationId)
            try Task.checkCancellation()
            record = records[publicationId] ?? record
            if !record.matches(current) {
                try? files.removeItem(at: folder(publicationId))
                record.files = pin(current.playableAssets)
            }
            if record.files.isEmpty { throw Unsupported() }
            record.publication = current
            record.state = .downloading
            record.problem = nil
            record.updatedAt = Date()
            save(record)

            let remaining = record.files.filter { !$0.complete }.reduce(Int64(0)) { $0 + max(0, $1.sizeBytes - $1.bytesDone) }
            if let space = usableSpace(), space < remaining + Self.spaceMargin { throw StorageFailure() }

            let assets = Dictionary(current.playableAssets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // In order, one file at a time, so a long audiobook fills from the start.
            for pinned in record.files where !pinned.complete {
                try Task.checkCancellation()
                guard let asset = assets[pinned.assetId] else { throw EditionChanged() }
                try await transfer(publicationId, asset)
            }
            guard var finished = records[publicationId], !finished.files.isEmpty, finished.files.allSatisfy(\.complete) else {
                throw APIError.protocolError
            }
            finished.state = .ready
            finished.problem = nil
            finished.updatedAt = Date()
            save(finished)
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            let problem = Self.classify(error)
            if problem == .changed { try? files.removeItem(at: folder(publicationId)) }
            guard var latest = records[publicationId] else { return }
            if problem == .changed {
                latest.files = latest.files.map { DownloadedFile(assetId: $0.assetId, name: $0.name, sizeBytes: $0.sizeBytes) }
            }
            latest.state = .failed
            latest.problem = problem
            latest.updatedAt = Date()
            save(latest)
        }
    }

    /// Downloads one asset to `<name>.part`, resuming with Range + If-Range when that is provably safe.
    private func transfer(_ publicationId: String, _ asset: Asset) async throws {
        guard let url = server.resolve(asset.contentUrl), server.contains(url) else { throw APIError.protocolError }
        guard let pinned = records[publicationId]?.files.first(where: { $0.assetId == asset.id }) else { throw EditionChanged() }
        let directory = folder(publicationId)
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw StorageFailure()
        }
        let partial = directory.appendingPathComponent(pinned.name + Self.part)
        let final = directory.appendingPathComponent(pinned.name)
        let sidecar = directory.appendingPathComponent(pinned.name + ".etag")

        let validator = pinned.etag ?? (try? String(contentsOf: sidecar, encoding: .utf8))
        let strong = validator.flatMap { $0.hasPrefix("W/") ? nil : $0 }
        let offset = strong == nil ? 0 : Self.size(of: partial)
        if offset == 0 { try? files.removeItem(at: partial) }
        if pinned.sizeBytes > 0, offset >= pinned.sizeBytes {
            try finish(publicationId, asset, partial: partial, final: final, sidecar: sidecar)
            return
        }

        var request = authorize(url)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if offset > 0, let strong {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            request.setValue(strong, forHTTPHeaderField: "If-Range")
        }

        let reporter = ProgressReporter { [weak self] written in
            Task { await self?.progress(publicationId, asset.id, written) }
        }
        let response: HTTPURLResponse
        do {
            response = try await transport.download(request, to: partial, onResponse: { response in
                // The validator goes to disk before any body, so a killed transfer can resume.
                if response.statusCode == 200, let tag = response.value(forHTTPHeaderField: "ETag") {
                    try? Data(tag.utf8).write(to: sidecar, options: .atomic)
                }
            }, onProgress: { reporter.report($0) })
        } catch {
            noteBytes(publicationId, asset.id, Self.size(of: partial))
            throw error
        }

        let tag = response.value(forHTTPHeaderField: "ETag")
        switch response.statusCode {
        case 206:
            let start = response.value(forHTTPHeaderField: "Content-Range")
                .flatMap { $0.components(separatedBy: " ").last?.components(separatedBy: "-").first }
                .flatMap { Int64($0) }
            guard offset > 0, start == offset else {
                try? files.removeItem(at: partial)
                throw APIError.protocolError
            }
        case 200:
            // A full body: either the server ignored the range, or the file changed.
            if let validator, tag != validator {
                try? files.removeItem(at: partial)
                throw EditionChanged()
            }
            updateFile(publicationId, asset.id) { $0.etag = tag }
        case 412, 416:
            throw EditionChanged()
        default:
            try? files.removeItem(at: partial)
            throw Self.failure(response.statusCode)
        }
        try finish(publicationId, asset, partial: partial, final: final, sidecar: sidecar)
    }

    private func finish(_ publicationId: String, _ asset: Asset, partial: URL, final: URL, sidecar: URL) throws {
        let length = Self.size(of: partial)
        let lengthOK = asset.sizeBytes <= 0 || length == asset.sizeBytes
        let epubOK = !asset.isEpub || Self.head(of: partial) == Data("PK".utf8)
        guard lengthOK, epubOK, length > 0 else {
            try? files.removeItem(at: partial)
            try? files.removeItem(at: sidecar)
            updateFile(publicationId, asset.id) {
                $0.bytesDone = 0
                $0.etag = nil
            }
            throw APIError.protocolError
        }
        try? files.removeItem(at: final)
        do {
            try files.moveItem(at: partial, to: final)
        } catch {
            throw StorageFailure()
        }
        try? files.removeItem(at: sidecar)
        updateFile(publicationId, asset.id) {
            $0.complete = true
            $0.bytesDone = length
        }
        persist()
    }

    private func progress(_ publicationId: String, _ assetId: String, _ written: Int64) {
        guard let file = records[publicationId]?.files.first(where: { $0.assetId == assetId }), !file.complete else { return }
        updateFile(publicationId, assetId) { $0.bytesDone = written }
    }

    private func noteBytes(_ publicationId: String, _ assetId: String, _ bytes: Int64) {
        updateFile(publicationId, assetId) { if !$0.complete { $0.bytesDone = bytes } }
    }

    // MARK: Storage

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: manifest),
              let stored = try? JSONDecoder().decode([String: DownloadRecord].self, from: data)
        else { return }
        let checked = stored.mapValues(reconcile)
        records = checked
        if checked != stored { persist() }
    }

    /// Recomputes sizes from disk and refuses to call missing or short files ready.
    private func reconcile(_ record: DownloadRecord) -> DownloadRecord {
        var record = record
        let directory = folder(record.publicationId)
        record.files = record.files.map { file in
            var file = file
            let final = directory.appendingPathComponent(file.name)
            let partial = directory.appendingPathComponent(file.name + Self.part)
            let finalSize = Self.size(of: final)
            if file.complete, files.fileExists(atPath: final.path), file.sizeBytes <= 0 || finalSize == file.sizeBytes {
                file.bytesDone = finalSize
            } else if file.complete {
                file.complete = false
                file.bytesDone = 0
            } else {
                file.bytesDone = Self.size(of: partial)
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

    private func save(_ record: DownloadRecord) {
        records[record.publicationId] = record
        persist()
    }

    private func updateFile(_ publicationId: String, _ assetId: String, _ change: (inout DownloadedFile) -> Void) {
        guard var record = records[publicationId], let index = record.files.firstIndex(where: { $0.assetId == assetId }) else { return }
        change(&record.files[index])
        records[publicationId] = record
    }

    private func persist() {
        guard !closed else { return }
        try? files.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: manifest, options: .atomic) }
    }

    private func pin(_ assets: [Asset]) -> [DownloadedFile] {
        assets.enumerated().map { index, asset in
            DownloadedFile(assetId: asset.id, name: Self.fileName(index, asset), sizeBytes: asset.sizeBytes)
        }
    }

    private func folder(_ publicationId: String) -> URL {
        root.appendingPathComponent(String(SHA256.hexDigest(Data(publicationId.utf8)).prefix(32)), isDirectory: true)
    }

    private static func fileName(_ index: Int, _ asset: Asset) -> String {
        let allowed = { (value: String) -> String? in
            let lower = value.lowercased()
            return (1 ... 5).contains(lower.count) && lower.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } ? lower : nil
        }
        let ext = allowed(asset.format) ?? allowed((asset.filename as NSString).pathExtension) ?? "bin"
        return String(format: "%03d-", index) + String(SHA256.hexDigest(Data(asset.id.utf8)).prefix(32)) + "." + ext
    }

    private static func size(of url: URL) -> Int64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        return (try? handle.seekToEnd()).map(Int64.init) ?? 0
    }

    private static func head(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: 2)
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

/// Throttles progress reports from the transport's delegate queue.
private final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var reported: Int64 = 0
    private let deliver: @Sendable (Int64) -> Void

    init(_ deliver: @escaping @Sendable (Int64) -> Void) { self.deliver = deliver }

    func report(_ written: Int64) {
        let send = lock.withLock { () -> Bool in
            guard written - reported >= 256 * 1024 else { return false }
            reported = written
            return true
        }
        if send { deliver(written) }
    }
}

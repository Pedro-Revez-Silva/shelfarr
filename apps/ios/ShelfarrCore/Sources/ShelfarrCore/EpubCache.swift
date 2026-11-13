import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CachedEpub: Equatable, Sendable {
    public let file: URL
    /// True when the copy could not be checked against the server just now.
    public let unverified: Bool
    /// A comic's page order for this file, already checked against the archive.
    public let readingOrder: ReadingOrder?

    public init(file: URL, unverified: Bool, readingOrder: ReadingOrder? = nil) {
        self.file = file
        self.unverified = unverified
        self.readingOrder = readingOrder
    }
}

/// A working copy of book files (EPUB, PDF and CBZ) so the readers can open them from
/// disk. It lives in the caches directory: the OS may evict it, so this is not an offline
/// library.
///
/// Files are scoped by account and asset id, the server's ETag decides when a copy
/// is stale, and the token only ever travels as a request header. An EPUB keeps the
/// `book.epub` name it always had; a PDF is `book.pdf`, a CBZ `book.cbz` with its page
/// order beside it as `book.order.json`. A comic copy is complete only with both.
public actor EpubCache {
    private struct Info: Codable, Sendable {
        var etag: String?
        var sizeBytes: Int64
    }

    private let root: URL
    private let transport: HTTPTransport
    private let authorize: @Sendable (URL) -> URLRequest
    private let maxBytes: Int64
    private let files = FileManager.default

    public init(root: URL, transport: HTTPTransport, authorize: @escaping @Sendable (URL) -> URLRequest, maxBytes: Int64 = 1 << 30) {
        self.root = root
        self.transport = transport
        self.authorize = authorize
        self.maxBytes = maxBytes
    }

    private func directory(_ accountKey: String, _ assetId: String) -> URL {
        root.appendingPathComponent(accountKey, isDirectory: true)
            .appendingPathComponent(String(SHA256.hexDigest(Data(assetId.utf8)).prefix(32)), isDirectory: true)
    }

    public func obtain(
        accountKey: String,
        server: ServerAddress,
        asset: Asset,
        authorize: (@Sendable (URL) -> URLRequest)? = nil,
        onProgress: @escaping @Sendable (Double?) -> Void = { _ in }
    ) async throws -> CachedEpub {
        let authorize = authorize ?? self.authorize
        guard let url = server.resolve(asset.contentUrl), server.contains(url) else { throw APIError.protocolError }

        let folder = directory(accountKey, asset.id)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let book = folder.appendingPathComponent(Self.bookName(asset))
        let orderFile = folder.appendingPathComponent(Self.orderName)
        let partial = folder.appendingPathComponent("book.part")
        let infoFile = folder.appendingPathComponent("book.json")
        let partialInfoFile = folder.appendingPathComponent("part.json")

        if files.fileExists(atPath: book.path), let info = readInfo(infoFile) {
            var check = authorize(url)
            if let etag = info.etag { check.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            // Conditional GET: a 200 streams the replacement straight into `partial`.
            try? files.removeItem(at: partial)
            let response: HTTPURLResponse
            do {
                response = try await transport.download(check, to: partial, onResponse: responseInfo(partialInfoFile, asset), onProgress: progress(asset, onProgress))
            } catch let APIError.offline(certificate) where !certificate {
                if asset.readerFormat == .cbz {
                    // Offline, a comic opens only with the page order kept beside it.
                    guard let order = Self.storedOrder(orderFile, assetId: asset.id) else { throw APIError.offline(certificate: false) }
                    onProgress(1)
                    return CachedEpub(file: book, unverified: true, readingOrder: order)
                }
                onProgress(1)
                return CachedEpub(file: book, unverified: true)
            }
            // Servers may ignore If-None-Match, so a 200 with the same tag is unchanged too.
            let sameTag = info.etag != nil && response.value(forHTTPHeaderField: "ETag") == info.etag
            let sameSize = info.etag == nil && info.sizeBytes == asset.sizeBytes
            if response.statusCode == 304 || ((200 ..< 300).contains(response.statusCode) && (sameTag || sameSize)) {
                try? files.removeItem(at: partial)
                let order = try await readingOrder(for: asset, book: book, orderFile: orderFile, server: server, authorize: authorize)
                onProgress(1)
                return CachedEpub(file: book, unverified: false, readingOrder: order)
            }
            try require(response)
            // Replaced bytes: the order belonged to the old copy.
            try? files.removeItem(at: orderFile)
            Self.writeInfo(partialInfoFile, Info(etag: response.value(forHTTPHeaderField: "ETag"), sizeBytes: asset.sizeBytes))
        } else {
            try await download(url, asset, partial, partialInfoFile, authorize, onProgress)
        }

        try verify(partial, asset)
        let finished = readInfo(partialInfoFile) ?? Info(etag: nil, sizeBytes: asset.sizeBytes)
        try? files.removeItem(at: book)
        try? files.removeItem(at: orderFile)
        try files.moveItem(at: partial, to: book)
        Self.writeInfo(infoFile, finished)
        try? files.removeItem(at: partialInfoFile)
        let order = try await readingOrder(for: asset, book: book, orderFile: orderFile, server: server, authorize: authorize)
        trim(keeping: folder)
        return CachedEpub(file: book, unverified: false, readingOrder: order)
    }

    /// Whether a complete copy of `asset` is on this device, comic page order included.
    /// For choosing a format offline; opening still goes through `obtain`.
    public func hasCopy(accountKey: String, asset: Asset) -> Bool {
        let folder = directory(accountKey, asset.id)
        guard files.fileExists(atPath: folder.appendingPathComponent(Self.bookName(asset)).path),
              readInfo(folder.appendingPathComponent("book.json")) != nil
        else { return false }
        if asset.readerFormat == .cbz {
            return Self.storedOrder(folder.appendingPathComponent(Self.orderName), assetId: asset.id) != nil
        }
        return true
    }

    /// The comic page order for a cached CBZ: the stored one, else fetched from the
    /// server, checked against the archive and stored. Nil for other formats.
    private func readingOrder(
        for asset: Asset,
        book: URL,
        orderFile: URL,
        server: ServerAddress,
        authorize: @escaping @Sendable (URL) -> URLRequest
    ) async throws -> ReadingOrder? {
        guard asset.readerFormat == .cbz else { return nil }
        if let stored = Self.storedOrder(orderFile, assetId: asset.id) { return stored }
        guard let reference = asset.readingOrderUrl, let url = server.resolve(reference), server.contains(url) else { throw APIError.protocolError }
        var request = authorize(url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response: HTTPURLResponse
        let body: Data?
        do {
            (response, body) = try await BoundedFetch.fetch(transport, request, scratch: orderFile.appendingPathExtension("part"), limit: ReadingOrder.maxBytes)
        } catch is BoundedFetch.TooLarge {
            throw APIError.protocolError
        }
        // 410: this file generation is no longer the server's.
        if response.statusCode == 410 { throw APIError.notFound }
        try require(response)
        let order: ReadingOrder
        do {
            order = try ReadingOrder.decode(body ?? Data(), assetId: asset.id)
            try ComicArchive.open(book, order: order).close()
        } catch {
            try? files.removeItem(at: book)
            throw APIError.protocolError
        }
        do {
            try JSONEncoder().encode(order).write(to: orderFile, options: .atomic)
        } catch {
            throw APIError.protocolError
        }
        return order
    }

    private static let orderName = "book.order.json"
    private static let bookNames = ["book.epub", "book.pdf", "book.cbz"]

    private static func bookName(_ asset: Asset) -> String {
        switch asset.readerFormat {
        case .pdf: return "book.pdf"
        case .cbz: return "book.cbz"
        case .epub, nil: return "book.epub"
        }
    }

    private static func storedOrder(_ file: URL, assetId: String) -> ReadingOrder? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? ReadingOrder.decode(data, assetId: assetId)
    }

    private func download(
        _ url: URL,
        _ asset: Asset,
        _ partial: URL,
        _ partialInfoFile: URL,
        _ authorize: @escaping @Sendable (URL) -> URLRequest,
        _ onProgress: @escaping @Sendable (Double?) -> Void
    ) async throws {
        var request = authorize(url)
        let resumeInfo = readInfo(partialInfoFile)
        let offset = (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
        if offset > 0, let etag = resumeInfo?.etag {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            request.setValue(etag, forHTTPHeaderField: "If-Range")
        } else {
            try? files.removeItem(at: partial)
        }

        let response = try await transport.download(request, to: partial, onResponse: responseInfo(partialInfoFile, asset), onProgress: progress(asset, onProgress))
        if response.statusCode == 416 {
            try? files.removeItem(at: partial)
            try? files.removeItem(at: partialInfoFile)
            throw APIError.server(416)
        }
        try require(response)
        if response.statusCode == 200 {
            Self.writeInfo(partialInfoFile, Info(etag: response.value(forHTTPHeaderField: "ETag"), sizeBytes: asset.sizeBytes))
        }
    }

    /// Save the validator before any body arrives, so interrupted transfers resume.
    private func responseInfo(_ file: URL, _ asset: Asset) -> @Sendable (HTTPURLResponse) -> Void {
        { response in
            if response.statusCode == 200 {
                Self.writeInfo(file, Info(etag: response.value(forHTTPHeaderField: "ETag"), sizeBytes: asset.sizeBytes))
            }
        }
    }

    private func progress(_ asset: Asset, _ onProgress: @escaping @Sendable (Double?) -> Void) -> @Sendable (Int64) -> Void {
        let total = asset.sizeBytes
        return { written in onProgress(total > 0 ? min(1, Double(written) / Double(total)) : nil) }
    }

    private func require(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200 ..< 300: return
        case 401: throw APIError.unauthorized
        case 403: throw APIError.forbidden
        case 404: throw APIError.notFound
        case 500 ..< 600: throw APIError.server(response.statusCode)
        default: throw APIError.protocolError
        }
    }

    private func verify(_ file: URL, _ asset: Asset) throws {
        // Foundation URLs can cache resource values. A resumed download grew
        // since the offset lookup, so verify the open file rather than that cache.
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: PDFSniff.window) ?? Data()
        let formatOK: Bool
        switch asset.readerFormat {
        case .pdf: formatOK = PDFSniff.hasHeader(head)
        // The archive itself is checked against its page order before it is kept.
        case .cbz: formatOK = true
        case .epub, nil: formatOK = head.prefix(2) == Data("PK".utf8)
        }
        if (asset.sizeBytes > 0 && size != UInt64(asset.sizeBytes)) || !formatOK {
            try? files.removeItem(at: file)
            throw APIError.protocolError
        }
    }

    /// Removes everything held for one account.
    public func clear(accountKey: String) {
        try? files.removeItem(at: root.appendingPathComponent(accountKey, isDirectory: true))
    }

    private func trim(keeping: URL) {
        let accounts = (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let entries = accounts
            .flatMap { (try? files.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { $0.standardizedFileURL != keeping.standardizedFileURL }
            .sorted { modified($0) < modified($1) }
        var total = entries.reduce(size(of: keeping)) { $0 + size(of: $1) }
        for entry in entries where total > maxBytes {
            total -= size(of: entry)
            try? files.removeItem(at: entry)
        }
    }

    private func modified(_ entry: URL) -> Date {
        Self.bookNames.compactMap { name in
            (try? entry.appendingPathComponent(name).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).flatMap { $0 }
        }.max() ?? .distantPast
    }

    private func size(of directory: URL) -> Int64 {
        let items = (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return items.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0) }
    }

    private func readInfo(_ file: URL) -> Info? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Info.self, from: $0) }
    }

    private nonisolated static func writeInfo(_ file: URL, _ info: Info) {
        if let data = try? JSONEncoder().encode(info) { try? data.write(to: file, options: .atomic) }
    }
}

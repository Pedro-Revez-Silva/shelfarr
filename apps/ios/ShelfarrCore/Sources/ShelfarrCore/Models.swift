import Foundation

/// Passes arbitrary JSON (Readium locators) through unchanged.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value):
            // A whole number is written as an integer (`12`, never `12.0`): servers check
            // page positions with an integer type.
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case let .object(value) = self { return value[key] }
        return nil
    }

    public var doubleValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    /// The JSON text, for handing a locator to Readium.
    public func jsonString() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func parse(jsonString: String) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: Data(jsonString.utf8))
    }
}

public struct DeviceGrant: Codable, Equatable, Sendable, CustomStringConvertible {
    public let deviceCode: String
    public let userCode: String
    public let verificationUri: String
    public let verificationUriComplete: String
    public let expiresIn: Int
    public var interval: Int

    public init(deviceCode: String, userCode: String, verificationUri: String, verificationUriComplete: String, expiresIn: Int, interval: Int = 5) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationUri = verificationUri
        self.verificationUriComplete = verificationUriComplete
        self.expiresIn = expiresIn
        self.interval = interval
    }

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUri = "verification_uri"
        case verificationUriComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }

    // A grant is a live secret: keep it out of logs.
    public var description: String { "DeviceGrant(userCode: \(userCode), expiresIn: \(expiresIn))" }
}

public struct TokenResponse: Codable, Equatable, Sendable, CustomStringConvertible {
    public let accessToken: String
    public let tokenType: String?
    public let scope: String?
    public let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case scope
        case expiresIn = "expires_in"
    }

    public var description: String { "TokenResponse(scope: \(scope ?? ""))" }
}

public struct Me: Codable, Equatable, Sendable {
    public let id: String
    public let name: String?
    public let username: String?
    /// What this credential may do. Absent from servers that predate requesting.
    public let scopes: [String]?

    public init(id: String, name: String? = nil, username: String? = nil, scopes: [String]? = nil) {
        self.id = id
        self.name = name
        self.username = username
        self.scopes = scopes
    }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return username ?? "Reader"
    }
}

public enum BookType: String, Codable, Sendable {
    case ebook
    case audiobook
}

/// Where the reader is with a publication. Set explicitly, or derived when an older server omits it.
public enum ReadingStatus: String, Codable, CaseIterable, Sendable {
    case unread
    case inProgress = "in_progress"
    case finished
}

public struct Asset: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let filename: String
    public let mediaType: String
    public let format: String
    public let sizeBytes: Int64
    public let contentUrl: String
    public let position: Int
    /// Pages in a CBZ, when the server inspected it. Absent from older servers and other formats.
    public let pageCount: Int?
    /// Where a CBZ's authoritative page order is, for this exact file generation.
    public let readingOrderUrl: String?
    /// An EPUB's read-along summary, only in details requested with `ReaderFeatures.header`.
    public let readAlong: ReadAlongSummary?

    public init(id: String, filename: String = "", mediaType: String = "", format: String = "", sizeBytes: Int64 = 0, contentUrl: String, position: Int = 0, pageCount: Int? = nil, readingOrderUrl: String? = nil, readAlong: ReadAlongSummary? = nil) {
        self.id = id
        self.filename = filename
        self.mediaType = mediaType
        self.format = format
        self.sizeBytes = sizeBytes
        self.contentUrl = contentUrl
        self.position = position
        self.pageCount = pageCount
        self.readingOrderUrl = readingOrderUrl
        self.readAlong = readAlong
    }

    enum CodingKeys: String, CodingKey {
        case id, filename, format, position
        case mediaType = "media_type"
        case sizeBytes = "size_bytes"
        case contentUrl = "content_url"
        case pageCount = "page_count"
        case readingOrderUrl = "reading_order_url"
        case readAlong = "read_along"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        filename = try container.decodeIfPresent(String.self, forKey: .filename) ?? ""
        mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType) ?? ""
        format = try container.decodeIfPresent(String.self, forKey: .format) ?? ""
        sizeBytes = try container.decodeIfPresent(Int64.self, forKey: .sizeBytes) ?? 0
        contentUrl = try container.decode(String.self, forKey: .contentUrl)
        position = try container.decodeIfPresent(Int.self, forKey: .position) ?? 0
        // Optional and additive: a malformed value is treated as absent, never a failed listing.
        pageCount = (try? container.decodeIfPresent(Int.self, forKey: .pageCount)) ?? nil
        readingOrderUrl = (try? container.decodeIfPresent(String.self, forKey: .readingOrderUrl)) ?? nil
        // Only an EPUB carries one; anything malformed reads as no read-along at all.
        let summary = (try? container.decodeIfPresent(ReadAlongSummary.self, forKey: .readAlong)) ?? nil
        let epub = format.lowercased() == "epub" || mediaType == "application/epub+zip"
        readAlong = epub ? summary : nil
    }

    public var isEpub: Bool { format.lowercased() == "epub" || mediaType == "application/epub+zip" }

    /// The reader format this file is, if the reader opens it at all.
    public var readerFormat: ReaderFormat? {
        if isEpub { return .epub }
        let name = format.lowercased()
        if name == "pdf" || mediaType == ReaderFormat.pdfMediaType { return .pdf }
        if name == "cbz" || mediaType == ReaderFormat.cbzMediaType { return .cbz }
        return nil
    }

    /// A format the reader opens, within the server's caps. A CBZ needs its page order.
    public var isReadable: Bool {
        switch readerFormat {
        case .epub: return true
        case .pdf: return sizeBytes <= ReaderFormat.maxPDFBytes
        case .cbz: return sizeBytes <= ReaderFormat.maxCBZBytes && !(readingOrderUrl ?? "").isEmpty
        case nil: return false
        }
    }

    public var isAudio: Bool {
        mediaType.hasPrefix("audio/")
            || ["mp3", "m4b", "m4a", "aac", "ogg", "oga", "opus", "flac", "wav"].contains(format.lowercased())
    }
}

public struct ReadingProgress: Codable, Equatable, Sendable {
    public let assetId: String
    public let locator: JSONValue?
    public let positionSeconds: Double?
    public let version: Int
    /// When the server accepted the write. Never activity time.
    public let updatedAt: String?
    public let clientMutationId: String?
    /// When the place was actually reached, as sent by the device that reached it.
    /// Nil from older servers and rows: unknown, never the upload time.
    public let observedAt: String?

    public init(assetId: String, locator: JSONValue? = nil, positionSeconds: Double? = nil, version: Int = 0, updatedAt: String? = nil, clientMutationId: String? = nil, observedAt: String? = nil) {
        self.assetId = assetId
        self.locator = locator
        self.positionSeconds = positionSeconds
        self.version = version
        self.updatedAt = updatedAt
        self.clientMutationId = clientMutationId
        self.observedAt = observedAt
    }

    enum CodingKeys: String, CodingKey {
        case assetId = "asset_id"
        case locator
        case positionSeconds = "position_seconds"
        case version
        case updatedAt = "updated_at"
        case clientMutationId = "client_mutation_id"
        case observedAt = "observed_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assetId = try container.decode(String.self, forKey: .assetId)
        let rawLocator = try container.decodeIfPresent(JSONValue.self, forKey: .locator)
        locator = rawLocator == .null ? nil : rawLocator
        positionSeconds = try container.decodeIfPresent(Double.self, forKey: .positionSeconds)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        clientMutationId = try container.decodeIfPresent(String.self, forKey: .clientMutationId)
        // A malformed or non-string value is an unknown time, not a reason to drop the place.
        observedAt = (try? container.decodeIfPresent(String.self, forKey: .observedAt)) ?? nil
    }

    /// `observedAt` as epoch milliseconds when well formed. Check plausibility before ordering by it.
    public var observedAtMillis: Int64? { ActivityTime.parse(observedAt) }

    /// 0–1 through the whole publication, when the locator states it.
    public var totalProgression: Double? {
        locator?["locations"]?["totalProgression"]?.doubleValue.map { min(max($0, 0), 1) }
    }

    public var isUsable: Bool { locator != nil || positionSeconds != nil }
}

public struct Publication: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let author: String?
    public let description: String?
    public let bookType: BookType
    public let coverUrl: String?
    public let assets: [Asset]
    public let progress: ReadingProgress?
    /// Absent from older servers; read `status` instead. Unknown values decode as absent.
    public let readingStatus: ReadingStatus?
    /// `graphic` for comics, `book` otherwise; only sent to clients that declare reader formats.
    public let contentKind: String?

    public init(id: String, title: String, author: String? = nil, description: String? = nil, bookType: BookType, coverUrl: String? = nil, assets: [Asset] = [], progress: ReadingProgress? = nil, readingStatus: ReadingStatus? = nil, contentKind: String? = nil) {
        self.id = id
        self.title = title
        self.author = author
        self.description = description
        self.bookType = bookType
        self.coverUrl = coverUrl
        self.assets = assets
        self.progress = progress
        self.readingStatus = readingStatus
        self.contentKind = contentKind
    }

    enum CodingKeys: String, CodingKey {
        case id, title, author, description, assets, progress
        case bookType = "book_type"
        case coverUrl = "cover_url"
        case readingStatus = "reading_status"
        case contentKind = "content_kind"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        bookType = try container.decode(BookType.self, forKey: .bookType)
        coverUrl = try container.decodeIfPresent(String.self, forKey: .coverUrl)
        assets = try container.decodeIfPresent([Asset].self, forKey: .assets) ?? []
        progress = try container.decodeIfPresent(ReadingProgress.self, forKey: .progress)
        readingStatus = (try? container.decodeIfPresent(ReadingStatus.self, forKey: .readingStatus)) ?? nil
        contentKind = (try? container.decodeIfPresent(String.self, forKey: .contentKind)) ?? nil
    }

    /// The explicit status, or one derived from the saved place when the server sends none.
    public var status: ReadingStatus {
        readingStatus ?? (progress?.isUsable == true ? .inProgress : .unread)
    }

    public func with(readingStatus: ReadingStatus?) -> Publication {
        Publication(id: id, title: title, author: author, description: description, bookType: bookType, coverUrl: coverUrl, assets: assets, progress: progress, readingStatus: readingStatus, contentKind: contentKind)
    }

    public var orderedAssets: [Asset] { assets.sorted { $0.position < $1.position } }
    public var epubAsset: Asset? { orderedAssets.first(where: \.isEpub) }
    public var audioAssets: [Asset] { orderedAssets.filter(\.isAudio) }

    /// A comic, whatever its file format. Its `bookType` is still `ebook`.
    public var isGraphic: Bool { contentKind == "graphic" }

    /// One file per format the reader opens: the first of each in the server's order. An
    /// EPUB-only book is exactly its first EPUB, as before formats existed.
    public var readableAssets: [Asset] {
        guard bookType == .ebook else { return [] }
        var seen: Set<ReaderFormat> = []
        return orderedAssets.filter { asset in
            guard asset.isReadable, let format = asset.readerFormat, !seen.contains(format) else { return false }
            seen.insert(format)
            return true
        }
    }

    public var readerFormats: [ReaderFormat] { readableAssets.compactMap(\.readerFormat) }

    public func asset(for format: ReaderFormat) -> Asset? {
        readableAssets.first { $0.readerFormat == format }
    }

    /// The assets a saved position may legitimately refer to in this edition.
    public var playableAssets: [Asset] {
        bookType == .ebook ? readableAssets : audioAssets
    }

    /// What a download of `format` keeps: every track of an audiobook, or the one file of
    /// that format of a book. Empty when this edition has no such file.
    public func downloadableAssets(format: ReaderFormat?) -> [Asset] {
        guard bookType == .ebook else { return audioAssets }
        return format.flatMap { asset(for: $0) }.map { [$0] } ?? []
    }

    public var isReadableHere: Bool { !playableAssets.isEmpty }
}

/// Permission to fetch one asset without the account's bearer token. The grant is in the
/// URL, valid only for GET and HEAD of that asset, and short-lived, so a system
/// background transfer never holds the general credential and a redirect can't carry it.
public struct TransferGrant: Codable, Equatable, Sendable, CustomStringConvertible {
    public let url: String
    public let expiresAt: String?

    public init(url: String, expiresAt: String? = nil) {
        self.url = url
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case url
        case expiresAt = "expires_at"
    }

    // The URL is a credential: keep it out of logs.
    public var description: String { "TransferGrant(expiresAt: \(expiresAt ?? "-"))" }
}

public struct ContinueList: Codable, Equatable, Sendable {
    public let items: [Publication]
}

public struct LibraryPage: Codable, Equatable, Sendable {
    public let items: [Publication]
    public let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
    }
}

public struct ProgressUpdate: Codable, Equatable, Sendable {
    public let assetId: String
    public let locator: JSONValue?
    public let positionSeconds: Double?
    public let expectedVersion: Int
    public let clientMutationId: String
    /// Omitted when this device does not know when the place was reached.
    public let observedAt: String?
    /// Only ever true for an explicit "Keep this device" choice; omitted otherwise.
    public let resolveConflict: Bool?

    public init(assetId: String, locator: JSONValue?, positionSeconds: Double?, expectedVersion: Int, clientMutationId: String, observedAt: String? = nil, resolveConflict: Bool? = nil) {
        self.assetId = assetId
        self.locator = locator
        self.positionSeconds = positionSeconds
        self.expectedVersion = expectedVersion
        self.clientMutationId = clientMutationId
        self.observedAt = observedAt
        self.resolveConflict = resolveConflict == true ? true : nil
    }

    enum CodingKeys: String, CodingKey {
        case assetId = "asset_id"
        case locator
        case positionSeconds = "position_seconds"
        case expectedVersion = "expected_version"
        case clientMutationId = "client_mutation_id"
        case observedAt = "observed_at"
        case resolveConflict = "resolve_conflict"
    }
}

/// Every way a server call can fail, in terms the UI can act on.
public enum APIError: Error, Equatable, Sendable {
    case offline(certificate: Bool)
    case unauthorized
    case forbidden
    case notFound
    case progressConflict(ReadingProgress?)
    case rejected(String?)
    case server(Int)
    case protocolError
    case redirectBlocked(String)
    case authorization(String)

    public var isRetryable: Bool {
        switch self {
        case .offline, .server: return true
        default: return false
        }
    }
}

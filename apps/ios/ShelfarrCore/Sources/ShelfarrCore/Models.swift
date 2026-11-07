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
        case let .number(value): try container.encode(value)
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

    public init(id: String, name: String? = nil, username: String? = nil) {
        self.id = id
        self.name = name
        self.username = username
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

public struct Asset: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let filename: String
    public let mediaType: String
    public let format: String
    public let sizeBytes: Int64
    public let contentUrl: String
    public let position: Int

    public init(id: String, filename: String = "", mediaType: String = "", format: String = "", sizeBytes: Int64 = 0, contentUrl: String, position: Int = 0) {
        self.id = id
        self.filename = filename
        self.mediaType = mediaType
        self.format = format
        self.sizeBytes = sizeBytes
        self.contentUrl = contentUrl
        self.position = position
    }

    enum CodingKeys: String, CodingKey {
        case id, filename, format, position
        case mediaType = "media_type"
        case sizeBytes = "size_bytes"
        case contentUrl = "content_url"
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
    }

    public var isEpub: Bool { format.lowercased() == "epub" || mediaType == "application/epub+zip" }

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
    public let updatedAt: String?
    public let clientMutationId: String?

    public init(assetId: String, locator: JSONValue? = nil, positionSeconds: Double? = nil, version: Int = 0, updatedAt: String? = nil, clientMutationId: String? = nil) {
        self.assetId = assetId
        self.locator = locator
        self.positionSeconds = positionSeconds
        self.version = version
        self.updatedAt = updatedAt
        self.clientMutationId = clientMutationId
    }

    enum CodingKeys: String, CodingKey {
        case assetId = "asset_id"
        case locator
        case positionSeconds = "position_seconds"
        case version
        case updatedAt = "updated_at"
        case clientMutationId = "client_mutation_id"
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
    }

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

    public init(id: String, title: String, author: String? = nil, description: String? = nil, bookType: BookType, coverUrl: String? = nil, assets: [Asset] = [], progress: ReadingProgress? = nil) {
        self.id = id
        self.title = title
        self.author = author
        self.description = description
        self.bookType = bookType
        self.coverUrl = coverUrl
        self.assets = assets
        self.progress = progress
    }

    enum CodingKeys: String, CodingKey {
        case id, title, author, description, assets, progress
        case bookType = "book_type"
        case coverUrl = "cover_url"
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
    }

    public var orderedAssets: [Asset] { assets.sorted { $0.position < $1.position } }
    public var epubAsset: Asset? { orderedAssets.first(where: \.isEpub) }
    public var audioAssets: [Asset] { orderedAssets.filter(\.isAudio) }

    /// The assets a saved position may legitimately refer to in this edition.
    public var playableAssets: [Asset] {
        bookType == .ebook ? [epubAsset].compactMap { $0 } : audioAssets
    }

    public var isReadableHere: Bool { !playableAssets.isEmpty }
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

    public init(assetId: String, locator: JSONValue?, positionSeconds: Double?, expectedVersion: Int, clientMutationId: String) {
        self.assetId = assetId
        self.locator = locator
        self.positionSeconds = positionSeconds
        self.expectedVersion = expectedVersion
        self.clientMutationId = clientMutationId
    }

    enum CodingKeys: String, CodingKey {
        case assetId = "asset_id"
        case locator
        case positionSeconds = "position_seconds"
        case expectedVersion = "expected_version"
        case clientMutationId = "client_mutation_id"
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

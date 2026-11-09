import Foundation

/// The scopes that together let an app find and request titles for its own account.
public enum RequestScopes {
    public static let base = ["library:read", "progress:write"]
    public static let requesting = ["search:read", "requests:read", "requests:write"]
    public static var all: String { (base + requesting).joined(separator: " ") }

    public static func allows(_ scopes: [String]?) -> Bool {
        guard let scopes else { return false }
        return requesting.allSatisfy(scopes.contains)
    }
}

/// Public facts from `/server.json`. Older servers omit `consumer_features`.
public struct ServerFacts: Decodable, Equatable, Sendable {
    public let consumerFeatures: [String]
    /// Formats the server can serve, from servers that know about reader formats. It says
    /// nothing about what this app renders.
    public let readerFormats: [String]?

    enum CodingKeys: String, CodingKey {
        case consumerFeatures = "consumer_features"
        case readerFormats = "reader_formats"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        consumerFeatures = try container.decodeIfPresent([String].self, forKey: .consumerFeatures) ?? []
        readerFormats = (try? container.decodeIfPresent([String].self, forKey: .readerFormats)) ?? nil
    }

    public var offersRequesting: Bool { consumerFeatures.contains("requests") }
}

/// Where a request is. Unknown future stages decode as `.unknown`.
public enum RequestStage: String, Codable, Sendable {
    case queued, searching
    case notFound = "not_found"
    case awaitingPurchase = "awaiting_purchase"
    case downloading, processing, available, completed, failed, unknown

    public init(from decoder: Decoder) throws {
        self = RequestStage(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .unknown
    }

    /// Still on its way: worth following.
    public var isOpen: Bool { [.queued, .searching, .notFound, .awaitingPurchase, .downloading, .processing].contains(self) }
}

public struct RequestItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let stage: RequestStage
    public let title: String
    public let author: String?
    public let bookType: BookType
    public let coverUrl: String?
    public let downloadPercent: Int?
    public let canCancel: Bool
    public let attentionNeeded: Bool
    public let publicationId: String?

    public init(id: String, stage: RequestStage, title: String, author: String? = nil, bookType: BookType, coverUrl: String? = nil,
                downloadPercent: Int? = nil, canCancel: Bool = false, attentionNeeded: Bool = false, publicationId: String? = nil) {
        self.id = id
        self.stage = stage
        self.title = title
        self.author = author
        self.bookType = bookType
        self.coverUrl = coverUrl
        self.downloadPercent = downloadPercent
        self.canCancel = canCancel
        self.attentionNeeded = attentionNeeded
        self.publicationId = publicationId
    }

    enum CodingKeys: String, CodingKey {
        case id, stage, title, author
        case bookType = "book_type"
        case coverUrl = "cover_url"
        case downloadPercent = "download_percent"
        case canCancel = "can_cancel"
        case attentionNeeded = "attention_needed"
        case publicationId = "publication_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        stage = try c.decodeIfPresent(RequestStage.self, forKey: .stage) ?? .unknown
        title = try c.decode(String.self, forKey: .title)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        bookType = try c.decode(BookType.self, forKey: .bookType)
        coverUrl = try c.decodeIfPresent(String.self, forKey: .coverUrl)
        downloadPercent = try c.decodeIfPresent(Int.self, forKey: .downloadPercent)
        canCancel = try c.decodeIfPresent(Bool.self, forKey: .canCancel) ?? false
        attentionNeeded = try c.decodeIfPresent(Bool.self, forKey: .attentionNeeded) ?? false
        publicationId = try c.decodeIfPresent(String.self, forKey: .publicationId)
    }

    public var isReady: Bool { stage == .available && publicationId != nil }

    /// A stand-in so the shared cover drawing can render it.
    public var coverPublication: Publication {
        Publication(id: "request:\(id)", title: title, author: author, bookType: bookType, coverUrl: coverUrl)
    }
}

public enum FormatState: String, Codable, Sendable {
    case requestable
    case inLibrary = "in_library"
    case requested
    case requestedBySomeone = "requested_by_someone"
    case unknown

    public init(from decoder: Decoder) throws {
        self = FormatState(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .unknown
    }
}

public struct FormatOption: Codable, Equatable, Sendable {
    public let bookType: BookType
    public var state: FormatState
    public var publicationId: String?
    public var request: RequestItem?

    public init(bookType: BookType, state: FormatState = .unknown, publicationId: String? = nil, request: RequestItem? = nil) {
        self.bookType = bookType
        self.state = state
        self.publicationId = publicationId
        self.request = request
    }

    enum CodingKeys: String, CodingKey {
        case state, request
        case bookType = "book_type"
        case publicationId = "publication_id"
    }

    /// One line under a format's name on the title page.
    public var summary: String {
        switch state {
        case .requestable: return bookType == .ebook ? "Read it in the app" : "Listen in the app"
        case .inLibrary: return "Already in your library"
        case .requested: return request.map { "You requested it · \($0.stageCopy.headline)" } ?? "You requested it"
        case .requestedBySomeone: return "Already requested on this server. It will appear in the library."
        case .unknown: return "Not available to request"
        }
    }
}

public struct DiscoverItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let workId: String
    public let sourceWorkIds: [String]
    public let title: String
    public let author: String?
    public let year: Int?
    public let description: String?
    public let coverUrl: String?
    public let seriesName: String?
    public let seriesPosition: String?
    public var formats: [FormatOption]

    enum CodingKeys: String, CodingKey {
        case id, title, author, year, description, formats
        case workId = "work_id"
        case sourceWorkIds = "source_work_ids"
        case coverUrl = "cover_url"
        case seriesName = "series_name"
        case seriesPosition = "series_position"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        workId = try c.decode(String.self, forKey: .workId)
        sourceWorkIds = try c.decodeIfPresent([String].self, forKey: .sourceWorkIds) ?? []
        title = try c.decode(String.self, forKey: .title)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        coverUrl = try c.decodeIfPresent(String.self, forKey: .coverUrl)
        seriesName = try c.decodeIfPresent(String.self, forKey: .seriesName)
        seriesPosition = try c.decodeIfPresent(String.self, forKey: .seriesPosition)
        formats = try c.decodeIfPresent([FormatOption].self, forKey: .formats) ?? []
    }

    public func format(_ type: BookType) -> FormatOption? { formats.first { $0.bookType == type } }

    /// "Ebook or audiobook", or each format's state in reading order when they differ.
    public var formatsLine: String {
        let options = [BookType.ebook, .audiobook].compactMap(format)
        if options.count == 2, options.allSatisfy({ $0.state == .requestable }) { return "Ebook or audiobook" }
        return options.map { option in
            let state: String
            switch option.state {
            case .requestable: state = "can be requested"
            case .inLibrary: state = "in your library"
            case .requested: state = "requested"
            case .requestedBySomeone: state = "already requested"
            case .unknown: state = "unavailable"
            }
            return "\(option.bookType.label) \(state)"
        }.joined(separator: " · ")
    }

    public var coverPublication: Publication {
        Publication(id: "find:\(id)", title: title, author: author, bookType: .ebook, coverUrl: coverUrl)
    }
}

public struct NewRequest: Encodable, Equatable, Sendable {
    public let workId: String
    public let bookType: BookType
    public let title: String
    public let author: String?
    public let coverUrl: String?
    public let year: Int?
    public let sourceWorkIds: [String]

    public init(_ item: DiscoverItem, _ type: BookType) {
        workId = item.workId
        bookType = type
        title = item.title
        author = item.author
        coverUrl = item.coverUrl
        year = item.year
        sourceWorkIds = item.sourceWorkIds
    }

    enum CodingKeys: String, CodingKey {
        case title, author, year
        case workId = "work_id"
        case bookType = "book_type"
        case coverUrl = "cover_url"
        case sourceWorkIds = "source_work_ids"
    }
}

/// What asking for a title produced. Only `.created` made something new.
public enum RequestOutcome: Equatable, Sendable {
    case created(RequestItem)
    /// This account had already asked; nothing new was made.
    case existing(RequestItem)
    case inLibrary(publicationId: String?, message: String?)
    case requestedBySomeone(message: String?)
    case refused(message: String?)
}

/// A request's state in plain words: a short headline and one sentence of detail.
public struct StageCopy: Equatable, Sendable {
    public let headline: String
    public let detail: String
}

public extension RequestItem {
    var stageCopy: StageCopy {
        switch stage {
        case .queued: return StageCopy(headline: "Requested", detail: "Waiting for Shelfarr to start looking.")
        case .searching:
            return attentionNeeded
                ? StageCopy(headline: "Waiting for the server's admin", detail: "Copies were found, but someone needs to choose one.")
                : StageCopy(headline: "Looking for a copy", detail: "This can take a few minutes.")
        case .notFound: return StageCopy(headline: "No copy found yet", detail: "Shelfarr will keep looking and try again later.")
        case .awaitingPurchase: return StageCopy(headline: "Available to buy", detail: "A store has it. Ask the server's admin to buy it and add it.")
        case .downloading:
            return StageCopy(headline: downloadPercent.map { "Downloading · \($0)%" } ?? "Downloading", detail: "Fetching the files to the server.")
        case .processing: return StageCopy(headline: "Adding to your library", detail: "Almost there.")
        case .available:
            return StageCopy(headline: "Ready", detail: bookType == .ebook ? "In your library and ready to read." : "In your library and ready to listen.")
        case .completed: return StageCopy(headline: "Finished", detail: "It was added, but isn't in the library now.")
        case .failed: return StageCopy(headline: "Stopped", detail: "This request was cancelled or couldn't be completed. You can request it again from Find.")
        case .unknown: return StageCopy(headline: "Requested", detail: "Shelfarr is working on it.")
        }
    }

    /// How far along the tracker's steps it is; -1 once stopped.
    var stepReached: Int {
        switch stage {
        case .queued, .unknown: return 0
        case .searching, .notFound, .awaitingPurchase: return 1
        case .downloading: return 2
        case .processing: return 3
        case .available, .completed: return 4
        case .failed: return -1
        }
    }

    static let steps = ["Requested", "Finding a copy", "Downloading", "Adding to the library", "Ready"]
}

public extension BookType {
    var label: String { self == .ebook ? "Ebook" : "Audiobook" }
    var word: String { self == .ebook ? "ebook" : "audiobook" }
}

/// Plain words for a failed request call.
public func requestFailureMessage(_ error: Error) -> String {
    switch error as? APIError {
    case .offline(certificate: false): return "You're offline. Requesting needs a connection to your server."
    case .offline(certificate: true): return "The server's security certificate couldn't be trusted."
    case .forbidden: return "This connection isn't allowed to request books any more. Allow requesting again from Find."
    case let .server(status): return "The server had a problem (error \(status)). Try again in a moment."
    case .notFound: return "That isn't on the server any more."
    case let .rejected(message): return message ?? "The server didn't accept that."
    default: return "Something went wrong. Try again."
    }
}

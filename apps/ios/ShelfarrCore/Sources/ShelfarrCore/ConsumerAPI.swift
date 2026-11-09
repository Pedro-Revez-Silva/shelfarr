import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum LibraryFilter: String, CaseIterable, Sendable {
    case all
    case ebook
    case audiobook

    var query: String? { self == .all ? nil : rawValue }
}

public enum LibrarySort: String, CaseIterable, Sendable {
    /// Recently acquired first, the server default.
    case recent
    case title

    var query: String? { self == .recent ? nil : rawValue }
}

/// Everything that selects one library listing. A cursor is only valid for the query that produced it.
public struct LibraryQuery: Equatable, Sendable {
    public var filter: LibraryFilter
    public var text: String
    public var status: ReadingStatus?
    public var sort: LibrarySort

    public init(filter: LibraryFilter = .all, text: String = "", status: ReadingStatus? = nil, sort: LibrarySort = .recent) {
        self.filter = filter
        self.text = text
        self.status = status
        self.sort = sort
    }
}

/// Typed client for `/api/consumer/v1`.
public final class ConsumerAPI: Sendable {
    private let transport: HTTPTransport
    private let credential: @Sendable () -> Credential?
    private let onRejected: @Sendable (Credential) -> Void

    public init(
        transport: HTTPTransport,
        credential: @escaping @Sendable () -> Credential?,
        onRejected: @escaping @Sendable (Credential) -> Void = { _ in }
    ) {
        self.transport = transport
        self.credential = credential
        self.onRejected = onRejected
    }

    private struct ErrorBody: Decodable {
        let error: String?
        let progress: ReadingProgress?
        var message: String?
        var publication_id: String?
    }

    private struct RequestEnvelope: Decodable {
        let request: RequestItem
    }

    private struct ProgressEnvelope: Decodable {
        let progress: ReadingProgress?
    }

    /// Applies the bearer token, but only for URLs inside the credential's server.
    public func authorized(_ url: URL, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let credential = credential(), credential.server.contains(url) {
            request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Starts a browser approval. With `scope`, an app asks for more than reading and
    /// listening; when already signed in, its bearer is sent, so the server adds the
    /// permission to this connection and only its own account may approve it.
    public func startDeviceAuthorization(server: ServerAddress, clientName: String, scope: String? = nil) async throws -> DeviceGrant {
        var fields = ["client_name": clientName]
        if let scope { fields["scope"] = scope }
        let body = try JSONEncoder().encode(fields)
        return try await decode(perform(authorized(server.api("auth/device"), method: "POST", body: body)))
    }

    /// Public, bearer-free server facts. A server without the file answers 404.
    public func serverFacts(server: ServerAddress) async throws -> ServerFacts {
        try await decode(perform(authorized(server.api("server.json"))))
    }

    private struct DiscoverPage: Decodable { let items: [DiscoverItem] }
    private struct RequestList: Decodable { let items: [RequestItem] }

    /// Metadata search beyond the library. Needs `search:read`.
    public func discover(server: ServerAddress, query: String, limit: Int = 12) async throws -> [DiscoverItem] {
        let page: DiscoverPage = try await decode(perform(authorized(server.api("discover", query: [("q", query), ("limit", String(limit))]))))
        return page.items
    }

    /// This account's requests, most recently changed first.
    public func requests(server: ServerAddress, limit: Int = 30) async throws -> [RequestItem] {
        let list: RequestList = try await decode(perform(authorized(server.api("requests", query: [("limit", String(limit))]))))
        return list.items
    }

    public func request(server: ServerAddress, id: String) async throws -> RequestItem {
        let envelope: RequestEnvelope = try await decode(perform(authorized(server.api("requests/\(ServerAddress.pathSegment(id))"))))
        return envelope.request
    }

    /// Asks for one format of a title. A duplicate is never an error: the server answers
    /// with what already exists, reported as anything but `.created`.
    public func createRequest(server: ServerAddress, _ request: NewRequest) async throws -> RequestOutcome {
        let (data, response) = try await send(authorized(server.api("requests"), method: "POST", body: try JSONEncoder().encode(request)))
        let error = try? JSONDecoder().decode(ErrorBody.self, from: data)
        switch (response.statusCode, error?.error) {
        case (201, _): return .created(try (decode(data) as RequestEnvelope).request)
        case (200 ..< 300, _): return .existing(try (decode(data) as RequestEnvelope).request)
        case (409, "already_in_library"): return .inLibrary(publicationId: error?.publication_id, message: error?.message)
        case (409, "already_requested"): return .requestedBySomeone(message: error?.message)
        case (422, "request_rejected"): return .refused(message: error?.message)
        default:
            try check(data, response)
            throw APIError.protocolError
        }
    }

    /// Stops a request that hasn't finished. The server decides whether it still can be.
    public func cancelRequest(server: ServerAddress, id: String) async throws -> RequestItem {
        let (data, response) = try await send(authorized(server.api("requests/\(ServerAddress.pathSegment(id))"), method: "DELETE"))
        if response.statusCode == 422 {
            throw APIError.rejected((try? JSONDecoder().decode(ErrorBody.self, from: data))?.message ?? "This request can't be cancelled now.")
        }
        try check(data, response)
        return try (decode(data) as RequestEnvelope).request
    }

    /// Polls once. Pending and terminal states arrive as `APIError.authorization`.
    public func exchangeDeviceCode(server: ServerAddress, deviceCode: String) async throws -> TokenResponse {
        let body = try JSONEncoder().encode(["device_code": deviceCode])
        let (data, response) = try await send(authorized(server.api("auth/token"), method: "POST", body: body))
        if response.statusCode == 400 {
            let code = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            throw APIError.authorization(code ?? "invalid_request")
        }
        try check(data, response)
        return try decode(data)
    }

    public func me(server: ServerAddress) async throws -> Me {
        try await decode(perform(authorized(server.api("me"))))
    }

    public func revoke(server: ServerAddress) async throws {
        _ = try await perform(authorized(server.api("auth/revoke"), method: "POST", body: Data("{}".utf8)))
    }

    public func library(
        server: ServerAddress,
        filter: LibraryFilter = .all,
        query: String? = nil,
        cursor: String? = nil,
        limit: Int = 30
    ) async throws -> LibraryPage {
        try await library(server: server, query: LibraryQuery(filter: filter, text: query ?? ""), cursor: cursor, limit: limit)
    }

    public func library(server: ServerAddress, query: LibraryQuery, cursor: String? = nil, limit: Int = 30) async throws -> LibraryPage {
        var items: [(String, String)] = []
        if let type = query.filter.query { items.append(("type", type)) }
        if !query.text.isEmpty { items.append(("q", query.text)) }
        if let status = query.status { items.append(("status", status.rawValue)) }
        if let sort = query.sort.query { items.append(("sort", sort)) }
        if let cursor { items.append(("cursor", cursor)) }
        items.append(("limit", String(limit)))
        return try await decode(perform(authorized(server.api("library", query: items))))
    }

    /// Library-wide recent activity across every acquired publication.
    public func continueReading(server: ServerAddress, limit: Int = 10) async throws -> [Publication] {
        let list: ContinueList = try await decode(perform(authorized(server.api("continue", query: [("limit", String(limit))]))))
        return list.items
    }

    /// Sets the explicit status. The server keeps the saved place.
    public func setReadingStatus(server: ServerAddress, publicationId: String, status: ReadingStatus) async throws -> Publication {
        let url = server.api("library/\(ServerAddress.pathSegment(publicationId))/reading_status")
        let body = try JSONEncoder().encode(["status": status.rawValue])
        return try await decode(perform(authorized(url, method: "PUT", body: body)))
    }

    /// Asks for an asset-scoped grant for a background transfer. Older servers answer 404.
    public func transferGrant(server: ServerAddress, publicationId: String, assetId: String) async throws -> TransferGrant {
        let url = server.api("library/\(ServerAddress.pathSegment(publicationId))/assets/\(ServerAddress.pathSegment(assetId))/transfer_grant")
        return try await decode(perform(authorized(url, method: "POST", body: Data("{}".utf8))))
    }

    public func publication(server: ServerAddress, id: String) async throws -> Publication {
        try await decode(perform(authorized(server.api("library/\(ServerAddress.pathSegment(id))"))))
    }

    public func saveProgress(server: ServerAddress, publicationId: String, update: ProgressUpdate) async throws -> ReadingProgress {
        let url = server.api("library/\(ServerAddress.pathSegment(publicationId))/progress")
        let body = try JSONEncoder().encode(update)
        let envelope: ProgressEnvelope = try await decode(perform(authorized(url, method: "PUT", body: body)))
        guard let progress = envelope.progress else { throw APIError.protocolError }
        return progress
    }

    /// Fetches a cover or other binary resource.
    public func data(from url: URL) async throws -> Data {
        try await perform(authorized(url))
    }

    /// Fetches one byte range of an authenticated asset, for streaming audio.
    public func bytes(at url: URL, range: ClosedRange<Int64>) async throws -> (Data, HTTPURLResponse) {
        var request = authorized(url)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        let (data, response) = try await send(request)
        try check(data, response)
        return (data, response)
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result = try await transport.send(request)
        noteRejection(result.1, request)
        return result
    }

    private func noteRejection(_ response: HTTPURLResponse, _ request: URLRequest) {
        guard response.statusCode == 401, let credential = credential(),
              request.value(forHTTPHeaderField: "Authorization") == "Bearer \(credential.accessToken)",
              request.url.map(credential.server.contains) == true
        else { return }
        onRejected(credential)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await send(request)
        try check(data, response)
        return data
    }

    private func check(_ data: Data, _ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200 ..< 300: return
        case 401: throw APIError.unauthorized
        case 403: throw APIError.forbidden
        case 404: throw APIError.notFound
        case 409:
            throw APIError.progressConflict((try? JSONDecoder().decode(ErrorBody.self, from: data))?.progress)
        case 400, 422:
            throw APIError.rejected((try? JSONDecoder().decode(ErrorBody.self, from: data))?.error)
        case 500 ..< 600: throw APIError.server(response.statusCode)
        default: throw APIError.protocolError
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.protocolError
        }
    }
}

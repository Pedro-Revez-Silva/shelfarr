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

    public func startDeviceAuthorization(server: ServerAddress, clientName: String) async throws -> DeviceGrant {
        let body = try JSONEncoder().encode(["client_name": clientName])
        return try await decode(perform(authorized(server.api("auth/device"), method: "POST", body: body)))
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
        var items: [(String, String)] = []
        if let type = filter.query { items.append(("type", type)) }
        if let query, !query.isEmpty { items.append(("q", query)) }
        if let cursor { items.append(("cursor", cursor)) }
        items.append(("limit", String(limit)))
        return try await decode(perform(authorized(server.api("library", query: items))))
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

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result = try await transport.send(request)
        noteRejection(result.1, request)
        return result
    }

    private func noteRejection(_ response: HTTPURLResponse, _ request: URLRequest) {
        guard response.statusCode == 401, let credential = credential(),
              request.value(forHTTPHeaderField: "Authorization") != nil
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

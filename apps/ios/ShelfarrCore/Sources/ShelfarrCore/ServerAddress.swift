import Foundation

/// The configured Shelfarr server: an origin plus an optional subpath.
///
/// This is also the credential boundary. A bearer token is only attached to URLs
/// for which `contains(_:)` returns true.
public struct ServerAddress: Hashable, Codable, Sendable {
    public let scheme: String
    public let host: String
    public let port: Int?
    /// Normalised subpath with no trailing slash; empty at the root.
    public let basePath: String

    public var display: String {
        var value = "\(scheme)://\(host)"
        if let port { value += ":\(port)" }
        return value + basePath
    }

    public var isCleartext: Bool { scheme != "https" }

    public var baseURL: URL { URL(string: display)! }

    /// Builds the URL of an endpoint under `/api/consumer/v1`.
    public func api(_ path: String, query: [(String, String)] = []) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        components.percentEncodedPath = "\(basePath)/api/consumer/v1/\(path)"
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        return components.url!
    }

    /// Percent-encodes an opaque id for use as one path segment.
    public static func pathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%;")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// True when `url` shares this server's scheme, host, port and subpath.
    public func contains(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == host,
              Self.effectivePort(components.port, scheme: scheme) == Self.effectivePort(port, scheme: scheme)
        else { return false }
        if basePath.isEmpty { return true }
        let path = Self.normalised(path: components.percentEncodedPath)
        return path == basePath || path.hasPrefix(basePath + "/")
    }

    /// Resolves a URL from an API response.
    ///
    /// Absolute URLs are returned untouched, so callers must still check
    /// `contains(_:)`. A server-relative path gains the configured subpath unless
    /// it already has it.
    public func resolve(_ reference: String) -> URL? {
        let value = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value.hasPrefix("//") { return nil }
        if let schemeEnd = value.firstIndex(of: ":"),
           Self.isScheme(String(value[..<schemeEnd])) {
            guard let url = URL(string: value), let found = url.scheme?.lowercased(),
                  found == "https" || found == "http"
            else { return nil }
            return url
        }
        let path: String
        if !value.hasPrefix("/") {
            path = "\(basePath)/\(value)"
        } else if !basePath.isEmpty, value == basePath || value.hasPrefix(basePath + "/") {
            path = value
        } else {
            path = basePath + value
        }
        return URL(string: originString + path)
    }

    private var originString: String {
        var value = "\(scheme)://\(host)"
        if let port { value += ":\(port)" }
        return value
    }

    public enum ParseResult: Equatable, Sendable {
        case valid(ServerAddress)
        case empty
        case malformed
        case cleartextNotAllowed
    }

    /// Parses user input. HTTPS is assumed when no scheme is given. Plain HTTP
    /// needs `allowLocalHTTP` and a host that is only reachable locally.
    public static func parse(_ input: String, allowLocalHTTP: Bool = false) -> ParseResult {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return .empty }
        let withScheme = value.contains("://") ? value : "https://\(value)"
        guard let components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let rawHost = components.host, !rawHost.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil
        else { return .malformed }

        let host = rawHost.lowercased()
        if scheme == "http", !(allowLocalHTTP && isLocalHost(host)) { return .cleartextNotAllowed }
        let path = normalised(path: components.percentEncodedPath)
        let port = components.port == defaultPort(scheme) ? nil : components.port
        return .valid(ServerAddress(scheme: scheme, host: host, port: port, basePath: path))
    }

    private static func isScheme(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first, CharacterSet.letters.contains(first) else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "+-.".unicodeScalars.contains($0)
        }
    }

    private static func defaultPort(_ scheme: String) -> Int { scheme == "https" ? 443 : 80 }

    private static func effectivePort(_ port: Int?, scheme: String) -> Int { port ?? defaultPort(scheme) }

    /// Collapses dot segments, including percent-encoded ones, so a path can't
    /// escape the subpath while still appearing to start with it.
    static func normalised(path: String) -> String {
        var output: [Substring] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            let decoded = segment.replacingOccurrences(of: "%2e", with: ".", options: .caseInsensitive)
            if decoded == "." { continue }
            if decoded == ".." {
                _ = output.popLast()
                continue
            }
            output.append(segment)
        }
        return output.isEmpty ? "" : "/" + output.joined(separator: "/")
    }

    static func isLocalHost(_ host: String) -> Bool {
        let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if name == "localhost" || name == "::1" || name.hasSuffix(".local") { return true }
        let parts = name.split(separator: ".").map { Int($0) }
        guard parts.count == 4, !parts.contains(where: { $0 == nil || !(0 ... 255).contains($0!) }) else { return false }
        let first = parts[0]!, second = parts[1]!
        return first == 127 || first == 10 || (first == 192 && second == 168)
            || (first == 172 && (16 ... 31).contains(second)) || (first == 169 && second == 254)
    }
}

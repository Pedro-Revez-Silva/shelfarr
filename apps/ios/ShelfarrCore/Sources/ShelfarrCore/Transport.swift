import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct Credential: Equatable, Sendable, CustomStringConvertible {
    public let server: ServerAddress
    public let accessToken: String

    public init(server: ServerAddress, accessToken: String) {
        self.server = server
        self.accessToken = accessToken
    }

    public var description: String { "Credential(server: \(server.display))" }
}

public protocol HTTPTransport: Sendable {
    /// Performs one request. Redirects that leave the credential scope are refused.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Streams the response body into `file`, truncating unless the server sends
    /// a partial response. Non-success bodies are not written.
    func download(_ request: URLRequest, to file: URL, onResponse: @escaping @Sendable (HTTPURLResponse) -> Void, onProgress: @escaping @Sendable (Int64) -> Void) async throws -> HTTPURLResponse
}

/// The default transport. It re-checks every redirect, so a token can never follow
/// the server somewhere else.
public final class URLSessionTransport: NSObject, HTTPTransport, URLSessionDataDelegate, @unchecked Sendable {
    private final class Transfer {
        var body = Data()
        var file: FileHandle?
        var response: HTTPURLResponse?
        var blockedLocation: String?
        var written: Int64 = 0
        var onProgress: (@Sendable (Int64) -> Void)?
        var onResponse: (@Sendable (HTTPURLResponse) -> Void)?
        var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        var destination: URL?
    }

    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]
    private var session: URLSession!
    private let credential: @Sendable () -> Credential?

    public init(credential: @escaping @Sendable () -> Credential?) {
        self.credential = credential
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await run(request, Transfer())
    }

    public func download(_ request: URLRequest, to file: URL, onResponse: @escaping @Sendable (HTTPURLResponse) -> Void, onProgress: @escaping @Sendable (Int64) -> Void) async throws -> HTTPURLResponse {
        let transfer = Transfer()
        transfer.destination = file
        transfer.onResponse = onResponse
        transfer.onProgress = onProgress
        return try await run(request, transfer).1
    }

    private func run(_ request: URLRequest, _ transfer: Transfer) async throws -> (Data, HTTPURLResponse) {
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transfer.continuation = continuation
                lock.withLock { transfers[task.taskIdentifier] = transfer }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func transfer(for task: URLSessionTask) -> Transfer? {
        lock.withLock { transfers[task.taskIdentifier] }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let scope = credential()?.server
        if let target = request.url, let origin = task.originalRequest?.url, let scope,
           scope.contains(target), scope.contains(origin) {
            completionHandler(request)
        } else {
            transfer(for: task)?.blockedLocation = request.url?.absoluteString ?? ""
            completionHandler(nil)
        }
    }

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let transfer = transfer(for: dataTask), let http = response as? HTTPURLResponse {
            transfer.response = http
            transfer.onResponse?(http)
            if let destination = transfer.destination, (200 ..< 300).contains(http.statusCode) {
                let manager = FileManager.default
                if http.statusCode == 200 || !manager.fileExists(atPath: destination.path) {
                    _ = manager.createFile(atPath: destination.path, contents: nil)
                }
                transfer.file = try? FileHandle(forWritingTo: destination)
                if let handle = transfer.file { _ = try? handle.seekToEnd() }
                transfer.written = (try? transfer.file?.offset()).flatMap { $0 }.map(Int64.init) ?? 0
            }
        }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer = transfer(for: dataTask) else { return }
        if let file = transfer.file {
            try? file.write(contentsOf: data)
            transfer.written += Int64(data.count)
            transfer.onProgress?(transfer.written)
        } else if transfer.destination == nil {
            transfer.body.append(data)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let transfer = lock.withLock({ transfers.removeValue(forKey: task.taskIdentifier) }) else { return }
        try? transfer.file?.close()
        if let location = transfer.blockedLocation {
            transfer.continuation?.resume(throwing: APIError.redirectBlocked(location))
        } else if let error {
            transfer.continuation?.resume(throwing: Self.mapped(error))
        } else if let response = transfer.response {
            transfer.continuation?.resume(returning: (transfer.body, response))
        } else {
            transfer.continuation?.resume(throwing: APIError.protocolError)
        }
    }

    private static func mapped(_ error: Error) -> Error {
        let code = (error as? URLError)?.code
        if code == .cancelled { return CancellationError() }
        let certificate = [
            URLError.serverCertificateUntrusted, .serverCertificateHasBadDate,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
            .secureConnectionFailed,
        ].contains { $0 == code }
        return APIError.offline(certificate: certificate)
    }
}

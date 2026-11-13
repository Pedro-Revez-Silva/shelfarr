import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches a small JSON body, such as a reading order, into a file without ever
/// holding more than `limit` bytes: the transfer is cancelled once it passes the bound.
enum BoundedFetch {
    struct TooLarge: Error {}

    private final class Guard: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<HTTPURLResponse, Error>?
        private var exceeded = false

        func attach(_ task: Task<HTTPURLResponse, Error>) {
            let cancel = lock.withLock { () -> Bool in
                self.task = task
                return exceeded
            }
            if cancel { task.cancel() }
        }

        func trip() {
            let task = lock.withLock { () -> Task<HTTPURLResponse, Error>? in
                exceeded = true
                return self.task
            }
            task?.cancel()
        }

        var tripped: Bool { lock.withLock { exceeded } }

        func cancel() { lock.withLock { task }?.cancel() }
    }

    /// The response, and the body when it was a success within the bound.
    static func fetch(_ transport: HTTPTransport, _ request: URLRequest, scratch: URL, limit: Int64) async throws -> (HTTPURLResponse, Data?) {
        try? FileManager.default.removeItem(at: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let bound = Guard()
        let task = Task {
            try await transport.download(request, to: scratch, onResponse: { _ in }, onProgress: { written in
                if written > limit { bound.trip() }
            })
        }
        bound.attach(task)
        let response: HTTPURLResponse
        do {
            response = try await withTaskCancellationHandler { try await task.value } onCancel: { bound.cancel() }
        } catch {
            if bound.tripped { throw TooLarge() }
            throw error
        }
        if bound.tripped { throw TooLarge() }
        guard (200 ..< 300).contains(response.statusCode) else { return (response, nil) }
        guard let handle = try? FileHandle(forReadingFrom: scratch) else { return (response, Data()) }
        defer { try? handle.close() }
        let body = try handle.read(upToCount: Int(limit) + 1) ?? Data()
        guard Int64(body.count) <= limit else { throw TooLarge() }
        return (response, body)
    }
}

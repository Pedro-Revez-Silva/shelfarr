import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Names the account and ticket a system transfer belongs to. It is written into the
/// task's description, so a relaunched app can route a finished task without trusting
/// anything else about it. It carries no credential.
public struct TransferTag: Hashable, Sendable, CustomStringConvertible {
    public static let prefix = "shelfarr-download/1/"

    public let account: String
    public let ticket: String

    public init(account: String, ticket: String) {
        self.account = account
        self.ticket = ticket
    }

    public var description: String { Self.prefix + account + "/" + ticket }

    public init?(_ description: String?) {
        guard let description, description.hasPrefix(Self.prefix) else { return nil }
        let parts = description.dropFirst(Self.prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy(Self.isSafe) else { return nil }
        account = String(parts[0])
        ticket = String(parts[1])
    }

    private static func isSafe(_ part: Substring) -> Bool {
        (1 ... 64).contains(part.count) && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}

/// How a system transfer ended without a usable HTTP response.
public enum TransferFailure: String, Codable, Sendable {
    case offline
    case certificate
    /// Cancelled by this app; nothing to report.
    case cancelled
    /// Stopped by the system: the user force-quit the app, or iOS withdrew background time.
    case interrupted
    /// A redirect left the server, and the foreground transport refused it.
    case redirect
}

public enum TransferOutcome: Sendable {
    /// The server answered. `body` is the response body moved out of the system's
    /// temporary location, or nil when nothing was kept. `storageFailed` means a body
    /// arrived but could not be moved onto this device.
    case response(status: Int, headers: [String: String], finalURL: URL?, body: URL?, storageFailed: Bool)
    case failed(TransferFailure)
}

public struct TransferEvent: Sendable {
    public let ticket: String
    public let outcome: TransferOutcome
}

/// Receives the events of one account's transfers.
public protocol TransferSink: AnyObject, Sendable {
    /// Returns once the event's effect is durable on disk.
    func deliver(_ event: TransferEvent) async
    func progress(ticket: String, received: Int64) async
}

/// Runs the transfers a `DownloadManager` hands it, possibly outside the app process.
/// Every event comes back through a `TransferRouter`.
public protocol DownloadExecutor: AnyObject, Sendable {
    /// Starts one transfer. The caller has already persisted the ticket.
    func submit(_ request: URLRequest, tag: TransferTag, expectedBytes: Int64?) throws
    /// Every transfer the executor still holds, for any account.
    func live() async -> [TransferTag]
    /// Cancels these transfers. Their later events are dropped by the router.
    func cancel(_ tags: [TransferTag]) async
}

/// Routes transfer events to the account that owns them, and decides synchronously,
/// before the system deletes a finished body, whether that body may be kept.
///
/// Only a registered account gets files written, and only into its own staging folder.
/// Unregistering an account (sign-out) or revoking a ticket (cancel, remove) takes
/// effect before the caller deletes anything, so a late callback can never recreate
/// a deleted file or reach a different account.
public final class TransferRouter: @unchecked Sendable {
    private struct Account {
        let staging: URL
        let sink: TransferSink
    }

    private let lock = NSLock()
    private var accounts: [String: Account] = [:]
    private var revoked: Set<String> = []
    private var staged: [String: (file: URL?, failed: Bool)] = [:]
    private var reported: [String: Int64] = [:]
    /// Tickets whose body is staged or whose event is still being delivered.
    private var busy: Set<String> = []
    private var pending = 0
    private var idle: [@Sendable () -> Void] = []
    private let files = FileManager.default

    public init() {}

    public func register(account: String, staging: URL, sink: TransferSink) {
        lock.withLock { accounts[account] = Account(staging: staging, sink: sink) }
    }

    /// Stops all writes and deliveries for `account`. Returns once no staging is in progress.
    public func unregister(account: String, sink: TransferSink) {
        lock.withLock {
            if accounts[account]?.sink === sink { accounts[account] = nil }
        }
    }

    public func isRegistered(_ account: String) -> Bool {
        lock.withLock { accounts[account] != nil }
    }

    /// No body for these tickets is written after this returns.
    public func revoke<S: Sequence>(_ tickets: S) where S.Element == String {
        lock.withLock { revoked.formUnion(tickets) }
    }

    /// The staging file a ticket's body is moved to.
    public static func stagingFile(_ staging: URL, ticket: String) -> URL {
        staging.appendingPathComponent(ticket + ".body")
    }

    /// Call from the system's finished-downloading callback, before it returns.
    public func stage(_ description: String?, temporaryFile: URL) {
        guard let tag = TransferTag(description) else { return }
        lock.withLock {
            guard let account = accounts[tag.account], !revoked.contains(tag.ticket) else { return }
            let target = Self.stagingFile(account.staging, ticket: tag.ticket)
            do {
                try files.createDirectory(at: account.staging, withIntermediateDirectories: true)
                try? files.removeItem(at: target)
                try files.moveItem(at: temporaryFile, to: target)
                staged[tag.ticket] = (target, false)
            } catch {
                staged[tag.ticket] = (nil, true)
            }
            busy.insert(tag.ticket)
        }
    }

    public func progress(_ description: String?, received: Int64) {
        guard let tag = TransferTag(description) else { return }
        let sink: TransferSink? = lock.withLock {
            guard let account = accounts[tag.account], !revoked.contains(tag.ticket),
                  received - (reported[tag.ticket] ?? 0) >= 256 * 1024
            else { return nil }
            reported[tag.ticket] = received
            return account.sink
        }
        guard let sink else { return }
        Task { await sink.progress(ticket: tag.ticket, received: received) }
    }

    /// Call from the system's task-completed callback.
    public func complete(_ description: String?, response: HTTPURLResponse?, error: Error?) {
        guard let tag = TransferTag(description) else { return }
        let outcome: TransferOutcome
        if let error {
            outcome = .failed(Self.failure(error))
        } else if let response {
            outcome = .pending(response)
        } else {
            outcome = .failed(.offline)
        }
        let delivery: (TransferSink, TransferEvent)? = lock.withLock {
            let body = staged.removeValue(forKey: tag.ticket)
            reported[tag.ticket] = nil
            guard let account = accounts[tag.account], !revoked.contains(tag.ticket) else {
                if let file = body?.file { try? files.removeItem(at: file) }
                busy.remove(tag.ticket)
                return nil
            }
            busy.insert(tag.ticket)
            let resolved: TransferOutcome
            if case let .response(status, headers, finalURL, _, _) = outcome {
                resolved = .response(status: status, headers: headers, finalURL: finalURL, body: body?.file, storageFailed: body?.failed ?? false)
            } else {
                if let file = body?.file { try? files.removeItem(at: file) }
                resolved = outcome
            }
            pending += 1
            return (account.sink, TransferEvent(ticket: tag.ticket, outcome: resolved))
        }
        guard let (sink, event) = delivery else { return }
        Task {
            await sink.deliver(event)
            self.finishedDelivery(tag.ticket)
        }
    }

    /// Tickets with a staged body or an event not yet processed. Their absence from the
    /// executor's live transfers does not mean they were lost.
    public func busyTickets() -> Set<String> {
        lock.withLock { busy }
    }

    private func finishedDelivery(_ ticket: String) {
        let waiters: [@Sendable () -> Void] = lock.withLock {
            busy.remove(ticket)
            pending -= 1
            guard pending == 0 else { return [] }
            defer { idle.removeAll() }
            return idle
        }
        waiters.forEach { $0() }
    }

    /// Runs `body` once every event delivered so far has been durably processed.
    public func whenIdle(_ body: @escaping @Sendable () -> Void) {
        let now: Bool = lock.withLock {
            if pending == 0 { return true }
            idle.append(body)
            return false
        }
        if now { body() }
    }

    /// The URL error's meaning for a download. Only a lost connection is "offline".
    public static func failure(_ error: Error) -> TransferFailure {
        if error is CancellationError { return .cancelled }
        if let error = error as? APIError {
            switch error {
            case let .offline(certificate): return certificate ? .certificate : .offline
            case .redirectBlocked: return .redirect
            default: return .offline
            }
        }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return .offline }
        switch nsError.code {
        case NSURLErrorCancelled:
            // Set when the system, not this app, cancelled a background task.
            return nsError.userInfo["NSURLErrorBackgroundTaskCancelledReasonKey"] != nil ? .interrupted : .cancelled
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorSecureConnectionFailed, NSURLErrorClientCertificateRejected:
            return .certificate
        default:
            return .offline
        }
    }
}

private extension TransferOutcome {
    static func pending(_ response: HTTPURLResponse) -> TransferOutcome {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        return .response(status: response.statusCode, headers: headers, finalURL: response.url, body: nil, storageFailed: false)
    }
}

/// Runs transfers inside this process through an `HTTPTransport`, delivering the same
/// events a system background session would. Used by tests and platforms without one.
public final class InProcessDownloadExecutor: DownloadExecutor, @unchecked Sendable {
    private let transport: HTTPTransport
    private let router: TransferRouter
    private let scratch: URL
    private let limiter: Limiter
    private let lock = NSLock()
    private var tasks: [TransferTag: Task<Void, Never>] = [:]

    public init(transport: HTTPTransport, router: TransferRouter, scratch: URL, maxConnections: Int = 2) {
        self.transport = transport
        self.router = router
        self.scratch = scratch
        limiter = Limiter(max(1, maxConnections))
    }

    public func submit(_ request: URLRequest, tag: TransferTag, expectedBytes: Int64?) throws {
        let file = scratch.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let task = Task { [transport, router, limiter] in
            await limiter.acquire()
            do {
                try Task.checkCancellation()
                let response = try await transport.download(request, to: file, onResponse: { _ in }, onProgress: { router.progress(tag.description, received: $0) })
                if FileManager.default.fileExists(atPath: file.path) { router.stage(tag.description, temporaryFile: file) }
                try? FileManager.default.removeItem(at: file)
                await limiter.release()
                self.forget(tag)
                router.complete(tag.description, response: response, error: nil)
            } catch {
                try? FileManager.default.removeItem(at: file)
                await limiter.release()
                self.forget(tag)
                router.complete(tag.description, response: nil, error: error)
            }
        }
        lock.withLock { tasks[tag] = task }
    }

    private func forget(_ tag: TransferTag) {
        _ = lock.withLock { tasks.removeValue(forKey: tag) }
    }

    public func live() async -> [TransferTag] {
        lock.withLock { Array(tasks.keys) }
    }

    public func cancel(_ tags: [TransferTag]) async {
        let found = lock.withLock { tags.compactMap { tasks[$0] } }
        found.forEach { $0.cancel() }
        for task in found { await task.value }
    }
}

/// A counting semaphore for async code.
actor Limiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ count: Int) { available = count }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ShelfarrCore

/// Holds an async step until the test opens it, and counts who reached it.
actor HoldPoint {
    private var open: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrived = 0

    init(open: Bool = false) { self.open = open }

    /// Closes it again: later arrivals wait.
    func hold() { open = false }

    func wait() async {
        arrived += 1
        guard !open else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

final class Shared<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A download executor whose cancellations wait at `gate` while `holds` says so, as a
/// system session does while it looks up its tasks. Everything else is `base`'s.
final class HeldExecutor: DownloadExecutor, @unchecked Sendable {
    let base: FakeSystem
    let gate: HoldPoint
    private let holds: @Sendable (FakeSystem.Job) -> Bool

    init(_ base: FakeSystem, gate: HoldPoint, holds: @escaping @Sendable (FakeSystem.Job) -> Bool = { _ in true }) {
        self.base = base
        self.gate = gate
        self.holds = holds
    }

    func submit(_ request: URLRequest, tag: TransferTag, expectedBytes: Int64?) throws {
        try base.submit(request, tag: tag, expectedBytes: expectedBytes)
    }

    func live() async -> [TransferTag] { await base.live() }

    func cancel(_ tags: [TransferTag]) async {
        if base.live.contains(where: { tags.contains($0.tag) && holds($0) }) { await gate.wait() }
        await base.cancel(tags)
    }
}

@testable import ShelfarrCore
import XCTest

/// Two devices with their own stores and clocks, against a server that follows the
/// activity-time contract. The later real activity must win however the writes arrive.
final class ProgressReconciliationTests: XCTestCase {
    private let earlier = baseTime + 60000
    private let later = baseTime + 120_000

    private func status(_ sync: ProgressSync) async -> SyncStatus { await sync.status }

    /// Device A listens far into the book first; device B, later, deliberately seeks back.
    private func offlineUse(restart: Bool) async -> (ContractServer, Device, Device, ProgressSync, ProgressSync) {
        let server = ContractServer(clock: later + 600_000)
        let a = Device("A", server: server, clock: earlier)
        let b = Device("B", server: server, clock: later)
        var syncA = a.sync(), syncB = b.sync()
        await syncA.begin(position: nil, baseVersion: 0, assets: ["a"])
        await syncB.begin(position: nil, baseVersion: 0, assets: ["a"])
        await syncA.update(seconds(3000), observedAt: earlier)
        await syncB.update(seconds(120), observedAt: later)
        if restart {
            syncA = a.sync()
            syncB = b.sync()
        }
        a.clock.set(later + 300_000)
        b.clock.set(later + 300_000)
        return (server, a, b, syncA, syncB)
    }

    func testEarlierDeviceReconnectingFirstStillLosesToLaterActivity() async throws {
        for restart in [false, true] {
            let (server, a, _, syncA, syncB) = await offlineUse(restart: restart)
            await syncA.flush()
            await syncB.flush()
            XCTAssertEqual(server.stored.map(SavedPosition.init), seconds(120), "restart \(restart)")
            XCTAssertEqual(server.stored?.observedAtMillis, later)
            XCTAssertTrue(server.received.allSatisfy { $0.resolveConflict == nil }, "automatic rebasing never sets the flag")

            // A opens again online: the later activity wins even though it is earlier in the book.
            let localA = try await a.store.get("p")
            XCTAssertEqual(
                ResumeDecision.decide(publication: audiobook(), server: server.stored, local: localA, now: a.clock.now),
                .resume(seconds(120), baseVersion: server.stored?.version ?? -1, observedAt: later)
            )
        }
    }

    func testLaterDeviceReconnectingFirstIsAdoptedByTheEarlierOne() async throws {
        for restart in [false, true] {
            let (server, a, _, syncA, syncB) = await offlineUse(restart: restart)
            await syncB.flush()
            await syncA.flush()
            XCTAssertEqual(server.stored.map(SavedPosition.init), seconds(120), "restart \(restart)")
            XCTAssertEqual(server.stored?.observedAtMillis, later)
            XCTAssertEqual(server.received.count, 2, "the stale write is dropped, not retried")
            let localA = try await a.store.get("p")
            XCTAssertEqual(localA?.position, seconds(120), "A adopted B's later place")
            XCTAssertEqual(localA?.observedAt, later)
            XCTAssertEqual(localA?.hasUnsyncedChanges, false)
            let shown = await status(syncA)
            XCTAssertEqual(shown, .saved, "no choice is needed")
        }
    }

    func testANewerPlaceQueuedBehindAnInFlightRetrySurvivesLaterRemoteActivity() async throws {
        let server = ContractServer(clock: baseTime + 3_600_000)
        let a = Device("A", server: server, clock: baseTime)
        let b = Device("B", server: server, clock: baseTime)
        let syncA = a.sync()
        await syncA.begin(position: nil, baseVersion: 0, assets: ["a"])
        // A's first write lands, but its answer is lost.
        await syncA.update(seconds(100), observedAt: baseTime + 1000)
        server.fail(.loseResponse)
        await syncA.flush()
        // A keeps listening; this place waits behind the unanswered write.
        await syncA.update(seconds(400), observedAt: baseTime + 3000)
        // Meanwhile B listened in between and synced.
        let syncB = b.sync()
        await syncB.begin(position: nil, baseVersion: 0, assets: ["a"])
        await syncB.update(seconds(250), observedAt: baseTime + 2000)
        await syncB.flush()
        XCTAssertEqual(server.stored?.positionSeconds, 250)

        // Now A restarts and retries.
        let restarted = a.sync()
        await restarted.flush()
        let fromA = server.received.filter { $0.clientMutationId.hasPrefix("A") }
        XCTAssertEqual(fromA[0], fromA[1], "the retry repeats position, time and id exactly")
        XCTAssertEqual(fromA[1].observedAt, ActivityTime.format(baseTime + 1000), "the retry keeps its own event time")
        XCTAssertEqual(server.stored?.positionSeconds, 400, "A's newest place wins over B's earlier activity")
        XCTAssertEqual(server.stored?.observedAtMillis, baseTime + 3000)
        XCTAssertNotEqual(fromA.last?.clientMutationId, fromA[0].clientMutationId, "rebased under a new id")
        let localA = try await a.store.get("p")
        XCTAssertEqual(localA?.hasUnsyncedChanges, false)
    }

    func testAStaleRetryNeverOverwritesLaterRemoteActivity() async throws {
        let server = ContractServer(clock: baseTime + 3_600_000)
        let a = Device("A", server: server, clock: baseTime)
        let b = Device("B", server: server, clock: baseTime)
        let syncA = a.sync()
        await syncA.update(seconds(900), observedAt: baseTime + 1000)
        server.fail(.offline)
        await syncA.flush()
        let syncB = b.sync()
        await syncB.update(seconds(30), observedAt: baseTime + 5000)
        await syncB.flush()

        await syncA.flush()
        XCTAssertEqual(server.stored?.positionSeconds, 30)
        XCTAssertEqual(server.stored?.clientMutationId?.hasPrefix("B"), true)
        let localA = try await a.store.get("p")
        XCTAssertEqual(localA?.position, seconds(30))
        XCTAssertEqual(localA?.hasUnsyncedChanges, false)
    }

    func testABackwardSeekIsAValidNewObservation() async throws {
        let server = ContractServer(clock: baseTime + 3_600_000)
        let a = Device("A", server: server, clock: baseTime)
        let syncA = a.sync()
        await syncA.update(seconds(2000), observedAt: baseTime + 1000)
        await syncA.flush()
        await syncA.update(seconds(10), observedAt: baseTime + 2000)
        await syncA.flush()
        XCTAssertEqual(server.stored?.positionSeconds, 10)
        XCTAssertEqual(server.stored?.version, 2)
    }

    func testEqualTimesWithDifferentPlacesAsk() async {
        let server = ContractServer(clock: baseTime + 3_600_000)
        server.seed(ReadingProgress(assetId: "a", positionSeconds: 77, version: 1, clientMutationId: "B-1", observedAt: ActivityTime.format(baseTime + 1000)))
        let a = Device("A", server: server, clock: baseTime + 5000)
        let syncA = a.sync()
        await syncA.update(seconds(5), observedAt: baseTime + 1000)
        await syncA.flush()
        guard case .conflict = await status(syncA) else { return XCTFail("expected a choice") }
        let local = await syncA.snapshot()
        XCTAssertEqual(local.position, seconds(5), "the local place is retained while asking")
    }

    func testAnOlderServerWithoutActivityTimesKeepsTheExplicitChoice() async {
        let server = ContractServer(clock: baseTime + 3_600_000)
        server.legacy = true
        let a = Device("A", server: server, clock: baseTime)
        let b = Device("B", server: server, clock: baseTime)
        let syncB = b.sync()
        await syncB.update(seconds(50), observedAt: baseTime + 9000)
        await syncB.flush()
        XCTAssertNil(server.stored?.observedAt)

        let syncA = a.sync()
        await syncA.update(seconds(5), observedAt: baseTime + 1000)
        await syncA.flush()
        guard case .conflict = await status(syncA) else { return XCTFail("unknown time must ask") }
    }

    func testALegacyQueuedWriteIsRetriedUnchangedAndAsksOnConflict() async throws {
        let server = ContractServer(clock: baseTime + 3_600_000)
        server.seed(ReadingProgress(assetId: "a", positionSeconds: 80, version: 4, clientMutationId: "B-1", observedAt: ActivityTime.format(baseTime)))
        let store = MemoryProgressStore()
        await store.seed(LocalProgress(
            publicationId: "p",
            position: seconds(20),
            baseVersion: 3,
            pending: PendingMutation(position: seconds(20), expectedVersion: 3, mutationId: "legacy"),
            touched: true
        ))
        let a = Device("A", server: server, clock: baseTime + 60000, store: store)
        let sync = a.sync()
        await sync.flush()
        XCTAssertNil(server.received.first?.observedAt, "never stamped with the sync time")
        XCTAssertEqual(server.received.first?.clientMutationId, "legacy")
        guard case .conflict = await status(sync) else { return XCTFail("an unknown local time must ask") }
    }

    func testAFarFutureRemoteTimeAsksRatherThanWinning() async {
        // This device's clock is ten minutes slow, so the other device's honest time looks future.
        let server = ContractServer(clock: baseTime + 3_600_000)
        server.seed(ReadingProgress(assetId: "a", positionSeconds: 80, version: 1, clientMutationId: "B-1", observedAt: ActivityTime.format(baseTime + 600_000)))
        let slow = Device("S", server: server, clock: baseTime)
        let sync = slow.sync()
        await sync.update(seconds(5), observedAt: baseTime - 1000)
        await sync.flush()
        guard case .conflict = await status(sync) else { return XCTFail("an implausible time must ask") }
    }

    func testAFastClocksRefusedTimeKeepsTheLocalPlace() async throws {
        let server = ContractServer(clock: baseTime)
        let fast = Device("F", server: server, clock: baseTime + 3_600_000)
        let sync = fast.sync()
        await sync.update(seconds(42), observedAt: fast.clock.now)
        await sync.flush()
        let shown = await status(sync)
        XCTAssertEqual(shown, .rejected)
        XCTAssertNil(server.stored)
        let local = try await fast.store.get("p")
        XCTAssertEqual(local?.position, seconds(42))
        XCTAssertEqual(local?.hasUnsyncedChanges, true)
    }

    func testAnUnmappableRemoteAssetAsks() async {
        let server = ContractServer(clock: baseTime + 3_600_000)
        server.seed(ReadingProgress(assetId: "old-edition", positionSeconds: 80, version: 1, clientMutationId: "B-1", observedAt: ActivityTime.format(baseTime)))
        let a = Device("A", server: server, clock: baseTime + 5000)
        let sync = a.sync()
        await sync.begin(position: nil, baseVersion: 0, assets: ["a"])
        await sync.update(seconds(5), observedAt: baseTime + 4000)
        await sync.flush()
        guard case .conflict = await status(sync) else { return XCTFail("an asset this edition can't map must ask") }
    }

    func testKeepingThisDeviceOverridesOnceAndARebaseAfterwardsDropsTheFlag() async throws {
        let server = ContractServer(clock: baseTime + 3_600_000)
        server.legacy = false
        server.seed(ReadingProgress(assetId: "a", positionSeconds: 80, version: 1, clientMutationId: "B-1"))
        let a = Device("A", server: server, clock: baseTime + 5000)
        let sync = a.sync()
        await sync.update(seconds(5), observedAt: baseTime + 4000)
        await sync.flush()
        guard case .conflict = await status(sync) else { return XCTFail("unknown server time must ask") }

        // Another device writes again before the choice reaches the server.
        server.seed(ReadingProgress(assetId: "a", positionSeconds: 81, version: 2, clientMutationId: "B-2", observedAt: ActivityTime.format(baseTime + 4500)))
        a.clock.set(baseTime + 9000)
        await sync.keepLocal()
        let sent = server.received.suffix(2)
        XCTAssertEqual(sent.first?.resolveConflict, true)
        XCTAssertEqual(sent.first?.observedAt, ActivityTime.format(baseTime + 9000))
        XCTAssertNil(sent.last?.resolveConflict, "the automatic rebase never carries the flag")
        XCTAssertEqual(sent.last?.observedAt, ActivityTime.format(baseTime + 9000), "it keeps the choice's time")
        XCTAssertEqual(server.stored?.positionSeconds, 5)
    }

    func testChoosingTheOtherDeviceDiscardsLocalWritesAndKeepsItsTime() async throws {
        let server = ContractServer(clock: baseTime + 3_600_000)
        let theirs = ReadingProgress(assetId: "a", positionSeconds: 80, version: 1, clientMutationId: "B-1", observedAt: ActivityTime.format(baseTime + 4000))
        server.seed(theirs)
        let a = Device("A", server: server, clock: baseTime + 5000)
        let sync = a.sync()
        await sync.update(seconds(5), observedAt: baseTime + 4000)
        await sync.flush()
        _ = await sync.useServer()
        await sync.flush()
        XCTAssertEqual(server.received.count, 1)
        let local = try await a.store.get("p")
        XCTAssertEqual(local?.position, seconds(80))
        XCTAssertEqual(local?.observedAt, baseTime + 4000)
    }

    func testAdoptingALaterPlaceNeverStopsLaterPlaybackFromWinning() async throws {
        // The adoption only changes the saved record; the next checkpoint of a session that is
        // still playing here is newer again and is sent.
        let server = ContractServer(clock: baseTime + 3_600_000)
        let a = Device("A", server: server, clock: baseTime)
        let b = Device("B", server: server, clock: baseTime)
        let syncA = a.sync()
        await syncA.begin(position: seconds(10), baseVersion: 0, assets: ["a"])
        await syncA.update(seconds(15), observedAt: baseTime + 1000)
        let syncB = b.sync()
        await syncB.update(seconds(500), observedAt: baseTime + 2000)
        await syncB.flush()
        await syncA.flush()
        let adopted = try await a.store.get("p")
        XCTAssertEqual(adopted?.position, seconds(500))
        await syncA.update(seconds(20), observedAt: baseTime + 3000)
        await syncA.flush()
        XCTAssertEqual(server.stored?.positionSeconds, 20)
    }

    func testOpeningAtTheResumedPlaceSendsTheChoiceOnce() async throws {
        let server = ContractServer(clock: baseTime + 3_600_000)
        let theirs = ReadingProgress(assetId: "a", positionSeconds: 80, version: 3, clientMutationId: "B-1")
        server.seed(theirs)
        let a = Device("A", server: server, clock: baseTime + 5000)
        let sync = a.sync()
        await sync.chooseAtOpen(position: seconds(5), server: theirs, keepLocal: true)
        await sync.begin(position: seconds(5), baseVersion: 3, assets: ["a"])
        await sync.flush()
        XCTAssertEqual(server.received.count, 1)
        XCTAssertEqual(server.received.first?.resolveConflict, true)
        XCTAssertEqual(server.received.first?.expectedVersion, 3)
        XCTAssertEqual(server.stored?.positionSeconds, 5)
    }
}

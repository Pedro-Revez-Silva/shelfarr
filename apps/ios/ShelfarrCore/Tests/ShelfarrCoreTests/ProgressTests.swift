@testable import ShelfarrCore
import XCTest

private final class Remote: @unchecked Sendable {
    var calls: [ProgressUpdate] = []
    var failures: [Error] = []
    var version = 0
    var onCall: (@Sendable (ProgressUpdate) async -> Void)?

    func save(_: String, _ update: ProgressUpdate) async throws -> ReadingProgress {
        calls.append(update)
        await onCall?(update)
        if !failures.isEmpty { throw failures.removeFirst() }
        version += 1
        return ReadingProgress(assetId: update.assetId, locator: update.locator, positionSeconds: update.positionSeconds, version: version, clientMutationId: update.clientMutationId, observedAt: update.observedAt)
    }
}

final class ProgressTests: XCTestCase {
    private func at(_ seconds: Double) -> SavedPosition { SavedPosition(assetId: "a", positionSeconds: seconds) }

    private func makeSync(_ store: ProgressStore, _ remote: Remote, debounce: Duration = .seconds(60), clock: ManualClock = ManualClock(baseTime)) -> ProgressSync {
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        var timing = SyncTiming()
        timing.debounce = debounce
        timing.maxWait = .seconds(600)
        timing.firstRetry = .seconds(600)
        return ProgressSync(
            publicationId: "p",
            store: store,
            remote: { try await remote.save($0, $1) },
            timing: timing,
            now: { clock.now },
            newMutationId: {
                counter.value += 1
                return "m\(counter.value)"
            }
        )
    }

    func testSavesLocallyAtOnceAndSendsOnFlush() async {
        let store = MemoryProgressStore(), remote = Remote()
        let sync = makeSync(store, remote)
        await sync.update(at(1), observedAt: baseTime)
        let saved = try? await store.get("p")
        XCTAssertEqual(saved?.position, at(1))
        XCTAssertEqual(saved?.observedAt, baseTime, "the place and its activity time are on disk before any send")
        XCTAssertTrue(remote.calls.isEmpty)
        await sync.flush()
        XCTAssertEqual(remote.calls.map(\.expectedVersion), [0])
        XCTAssertEqual(remote.calls.first?.observedAt, "2026-11-07T09:00:00.000Z")
        XCTAssertNil(remote.calls.first?.resolveConflict)
        let status = await sync.status
        XCTAssertEqual(status, .saved)
    }

    func testDebounceFiresBySelf() async throws {
        let store = MemoryProgressStore(), remote = Remote()
        let sync = makeSync(store, remote, debounce: .milliseconds(20))
        await sync.update(at(1), observedAt: baseTime)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(remote.calls.count, 1)
    }

    func testStoppedSyncRetainsItsPlaceWithoutSendingOrWritingAgain() async throws {
        let store = MemoryProgressStore(), remote = Remote()
        let sync = makeSync(store, remote, debounce: .milliseconds(20))
        await sync.update(at(8), observedAt: baseTime)
        await sync.stop()
        await sync.update(at(9), observedAt: baseTime + 1000)
        await sync.flush()
        try await Task.sleep(for: .milliseconds(80))
        let local = try await store.get("p")
        XCTAssertEqual(local?.position, at(8))
        XCTAssertEqual(remote.calls.count, 0)
    }

    func testRepeatingTheSamePlaceSendsNothing() async {
        let store = MemoryProgressStore(), remote = Remote()
        let sync = makeSync(store, remote)
        await sync.begin(position: at(4), baseVersion: 2)
        await sync.update(at(4), observedAt: baseTime)
        await sync.flush()
        XCTAssertTrue(remote.calls.isEmpty)
    }

    func testRestoringASavedPlaceIsNotNewActivity() async throws {
        let store = MemoryProgressStore(), remote = Remote()
        let sync = makeSync(store, remote)
        await sync.begin(position: at(40), baseVersion: 3, observedAt: baseTime - 60000, assets: ["a"])
        // The player reports where it opened; the reader reports the restored page.
        await sync.update(at(40), observedAt: baseTime)
        await sync.flush()
        XCTAssertTrue(remote.calls.isEmpty)
        let record = try await store.get("p")
        XCTAssertEqual(record?.observedAt, baseTime - 60000, "opening keeps when the place was reached")
        XCTAssertEqual(record?.hasUnsyncedChanges, false)
    }

    func testAFailedSendKeepsTheSameMutationBodyAndActivityTime() async {
        let store = MemoryProgressStore(), remote = Remote(), clock = ManualClock(baseTime)
        remote.failures = [APIError.offline(certificate: false), APIError.server(502)]
        let sync = makeSync(store, remote, clock: clock)
        await sync.update(at(1), observedAt: baseTime)
        clock.advance(30000)
        await sync.flush()
        let waiting = await sync.status
        XCTAssertEqual(waiting, .waitingForServer)
        clock.advance(600_000)
        await sync.flush()
        await sync.flush()
        XCTAssertEqual(remote.calls.count, 3)
        XCTAssertEqual(remote.calls[0], remote.calls[1])
        XCTAssertEqual(remote.calls[1], remote.calls[2])
        XCTAssertEqual(remote.calls[2].observedAt, ActivityTime.format(baseTime), "the event time, not the send time")
    }

    func testAnAcknowledgementDoesNotChangeTheActivityTime() async throws {
        let store = MemoryProgressStore(), remote = Remote(), clock = ManualClock(baseTime)
        let sync = makeSync(store, remote, clock: clock)
        await sync.update(at(1), observedAt: baseTime)
        clock.advance(120_000)
        await sync.flush()
        let record = try await store.get("p")
        XCTAssertEqual(record?.observedAt, baseTime)
        XCTAssertEqual(record?.position, at(1))
    }

    func testNewerPlacesWaitBehindAnUnansweredWrite() async {
        let store = MemoryProgressStore(), remote = Remote()
        remote.failures = [APIError.server(503)]
        let sync = makeSync(store, remote)
        await sync.update(at(1), observedAt: baseTime)
        await sync.flush()
        await sync.update(at(2), observedAt: baseTime + 5000)
        await sync.flush()
        XCTAssertEqual(remote.calls.map(\.clientMutationId), ["m1", "m1", "m2"])
        XCTAssertEqual(remote.calls[1].observedAt, ActivityTime.format(baseTime), "the retry is unchanged")
        XCTAssertEqual(remote.calls[2].positionSeconds, 2)
        XCTAssertEqual(remote.calls[2].expectedVersion, 1)
        XCTAssertEqual(remote.calls[2].observedAt, ActivityTime.format(baseTime + 5000))
    }

    func testAClockSteppingBackDoesNotReorderThisDevicesOwnReading() async throws {
        let store = MemoryProgressStore(), remote = Remote()
        let sync = makeSync(store, remote)
        await sync.update(at(1), observedAt: baseTime)
        await sync.update(at(2), observedAt: baseTime - 2000)
        let record = try await store.get("p")
        XCTAssertEqual(record?.observedAt, baseTime + 1)
    }

    func testUnansweredWriteSurvivesARestart() async {
        let store = MemoryProgressStore(), remote = Remote()
        remote.failures = [APIError.offline(certificate: false)]
        let first = makeSync(store, remote)
        await first.update(at(1), observedAt: baseTime)
        await first.flush()
        let restored = makeSync(store, remote)
        await restored.flush()
        XCTAssertEqual(remote.calls.map(\.clientMutationId), ["m1", "m1"])
        XCTAssertEqual(remote.calls[0], remote.calls[1])
    }

    func testAConflictReportingOurOwnMutationCountsAsSaved() async throws {
        let store = MemoryProgressStore(), remote = Remote()
        remote.failures = [APIError.progressConflict(ReadingProgress(assetId: "a", positionSeconds: 1, version: 8, clientMutationId: "m1"))]
        let sync = makeSync(store, remote)
        await sync.update(at(1), observedAt: baseTime)
        await sync.flush()
        let record = try await store.get("p")
        XCTAssertEqual(record?.baseVersion, 8)
        XCTAssertEqual(record?.hasUnsyncedChanges, false)
    }

    func testAnUnorderableConflictStopsSendingAndAsks() async {
        let store = MemoryProgressStore(), remote = Remote()
        // An older server: no activity time on either side's stored copy.
        let theirs = ReadingProgress(assetId: "a", positionSeconds: 90, version: 8, clientMutationId: "other")
        remote.failures = [APIError.progressConflict(theirs)]
        let sync = makeSync(store, remote)
        await sync.update(at(1), observedAt: baseTime)
        await sync.flush()
        let status = await sync.status
        XCTAssertEqual(status, .conflict(local: at(1), server: theirs))
        await sync.update(at(2), observedAt: baseTime + 1000)
        await sync.flush()
        XCTAssertEqual(remote.calls.count, 1)
    }

    func testKeepingThisDeviceIsANewChoiceStampedAndSavedBeforeItIsSent() async throws {
        let store = MemoryProgressStore(), remote = Remote(), clock = ManualClock(baseTime)
        remote.failures = [APIError.progressConflict(ReadingProgress(assetId: "a", positionSeconds: 90, version: 8, clientMutationId: "o"))]
        remote.version = 8
        let sync = makeSync(store, remote, clock: clock)
        await sync.update(at(1), observedAt: baseTime)
        await sync.flush()
        clock.set(baseTime + 90000)
        final class Seen: @unchecked Sendable { var record: LocalProgress? }
        let seen = Seen()
        remote.onCall = { _ in seen.record = try? await store.get("p") }
        await sync.keepLocal()
        let choice = try XCTUnwrap(remote.calls.last)
        XCTAssertEqual(choice.expectedVersion, 8)
        XCTAssertEqual(choice.clientMutationId, "m2")
        XCTAssertEqual(choice.resolveConflict, true)
        XCTAssertEqual(choice.observedAt, ActivityTime.format(baseTime + 90000), "the time of the choice")
        XCTAssertEqual(seen.record?.pending?.resolveConflict, true, "the choice was on disk when it was sent")
        XCTAssertEqual(seen.record?.pending?.observedAt, baseTime + 90000)
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(choice), encoding: .utf8))
        XCTAssertTrue(encoded.contains("\"resolve_conflict\":true"))
    }

    func testUsingTheOtherDeviceAdoptsItsPlaceAndTime() async throws {
        let store = MemoryProgressStore(), remote = Remote()
        let theirs = ReadingProgress(assetId: "a", positionSeconds: 90, version: 8, clientMutationId: "o", observedAt: "2026-11-07T09:00:00Z")
        remote.failures = [APIError.progressConflict(theirs)]
        let sync = makeSync(store, remote)
        await sync.update(at(1), observedAt: baseTime)
        await sync.flush()
        let adopted = await sync.useServer()
        XCTAssertEqual(adopted, at(90))
        XCTAssertEqual(remote.calls.count, 1)
        let record = try await store.get("p")
        XCTAssertEqual(record?.hasUnsyncedChanges, false)
        XCTAssertEqual(record?.observedAt, baseTime)
    }

    func testARefusedPositionIsKeptButNotResentUntilReopened() async throws {
        let store = MemoryProgressStore(), remote = Remote()
        remote.failures = [APIError.rejected("invalid_observed_at")]
        let sync = makeSync(store, remote)
        await sync.update(at(1), observedAt: baseTime)
        await sync.flush()
        let status = await sync.status
        XCTAssertEqual(status, .rejected)
        var record = try await store.get("p")
        XCTAssertEqual(record?.position, at(1), "a validation error never erases the local place")
        XCTAssertEqual(record?.dirty, true)
        XCTAssertEqual(record?.isSendable, false)

        await sync.update(at(2), observedAt: baseTime + 1000)
        await sync.flush()
        XCTAssertEqual(remote.calls.count, 1, "nothing is resent automatically")
        record = try await store.get("p")
        XCTAssertEqual(record?.position, at(2), "later reading is still saved here")

        await sync.begin(position: at(2), baseVersion: 0)
        await sync.flush()
        XCTAssertEqual(remote.calls.count, 2, "opening the book again retries")
        XCTAssertEqual(remote.calls.last?.positionSeconds, 2)
    }

    func testAnUnreadableAnswerIsRetriedUnchanged() async {
        let store = MemoryProgressStore(), remote = Remote()
        remote.failures = [APIError.protocolError]
        let sync = makeSync(store, remote)
        await sync.update(at(1), observedAt: baseTime)
        await sync.flush()
        let status = await sync.status
        XCTAssertEqual(status, .waitingForServer)
        await sync.flush()
        XCTAssertEqual(remote.calls.count, 2)
        XCTAssertEqual(remote.calls[0], remote.calls[1])
    }

    func testALostSessionKeepsTheWrite() async throws {
        let store = MemoryProgressStore(), remote = Remote()
        remote.failures = [APIError.unauthorized]
        let sync = makeSync(store, remote)
        await sync.update(at(1), observedAt: baseTime)
        await sync.flush()
        let status = await sync.status
        XCTAssertEqual(status, .needsSignIn)
        let record = try await store.get("p")
        XCTAssertEqual(record?.hasUnsyncedChanges, true)
    }

    func testAFailedLocalWriteIsShownAndTheMemoryCopyStillSyncs() async throws {
        let store = MemoryProgressStore(), remote = Remote()
        await store.set(failWrites: true)
        let sync = makeSync(store, remote)
        await sync.update(at(12), observedAt: baseTime)
        let failed = await sync.status
        XCTAssertEqual(failed, .storageFailed)
        let held = await sync.snapshot()
        XCTAssertEqual(held.position, at(12), "the place is kept in memory")
        await sync.flush()
        XCTAssertEqual(remote.calls.map(\.positionSeconds), [12], "and still sent to the server")
        let stillFailed = await sync.status
        XCTAssertEqual(stillFailed, .storageFailed, "until a write succeeds")

        await store.set(failWrites: false)
        await sync.update(at(13), observedAt: baseTime + 1000)
        let recovered = await sync.status
        XCTAssertEqual(recovered, .pending)
        let record = try await store.get("p")
        XCTAssertEqual(record?.position, at(13))
    }

    func testAnUnreadableStoreIsShownAndRetriesNothing() async {
        let store = MemoryProgressStore(), remote = Remote()
        await store.seed(LocalProgress(publicationId: "p", position: at(5), dirty: true, observedAt: baseTime))
        await store.set(failReads: true)
        let registry = ProgressRegistry(store: store, remote: { try await remote.save($0, $1) })
        await registry.flushAll()
        XCTAssertTrue(remote.calls.isEmpty)
        let sync = makeSync(store, remote)
        _ = await sync.snapshot()
        let status = await sync.status
        XCTAssertEqual(status, .storageFailed)
    }

    func testFileStoreRoundTrips() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a/progress.json")
        let pending = PendingMutation(position: at(3), expectedVersion: 2, mutationId: "m", observedAt: baseTime, resolveConflict: true)
        let record = LocalProgress(publicationId: "p", position: at(3), baseVersion: 2, dirty: true, pending: pending, observedAt: baseTime, assetIds: ["a"], rejected: false)
        try await FileProgressStore(file: file).put(record)
        let again = try await FileProgressStore(file: file).get("p")
        XCTAssertEqual(again, record)
    }

    func testFileStoreOpensAnEarlierVersionsRecordsWithAnUnknownTime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("progress.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Exactly what the previous release wrote: no activity times, assets or refusal flag.
        let legacy = """
        {"p":{"publicationId":"p","position":{"assetId":"a","positionSeconds":42},"baseVersion":3,"dirty":false,\
        "pending":{"position":{"assetId":"a","positionSeconds":42},"expectedVersion":3,"mutationId":"old"},\
        "conflict":{"asset_id":"a","position_seconds":7,"version":9,"client_mutation_id":"x"},"touched":true}}
        """
        try Data(legacy.utf8).write(to: file)
        let loaded = try await FileProgressStore(file: file).get("p")
        let record = try XCTUnwrap(loaded)
        XCTAssertNil(record.observedAt)
        XCTAssertNil(record.pending?.observedAt)
        XCTAssertEqual(record.pending?.resolveConflict, false)
        XCTAssertNil(record.conflict?.observedAt)
        XCTAssertFalse(record.rejected)
        XCTAssertEqual(record.pending?.update.observedAt, nil, "an old queued write is retried exactly as it was")
        XCTAssertNil(record.pending?.update.resolveConflict)
    }

    func testFileStoreSetsADamagedFileAside() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("progress.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: file)
        let store = FileProgressStore(file: file)
        let missing = try await store.get("p")
        XCTAssertNil(missing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path + ".damaged"), "kept for diagnosis, not overwritten")
    }

    func testFileStoreReportsAFailedWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The parent "directory" is a plain file, so nothing can be written under it.
        let blocker = directory.appendingPathComponent("blocked")
        try Data().write(to: blocker)
        let store = FileProgressStore(file: blocker.appendingPathComponent("progress.json"))
        do {
            try await store.put(LocalProgress(publicationId: "p", position: at(1)))
            XCTFail("expected a write failure")
        } catch {
            XCTAssertEqual(error as? ProgressStoreError, .unwritable)
        }
    }

    func testTheWireBodyCarriesTheActivityTimeAndOmitsTheFlagUnlessChosen() throws {
        let automatic = PendingMutation(position: at(3), expectedVersion: 1, mutationId: "m", observedAt: baseTime + 123).update
        let text = try XCTUnwrap(String(data: JSONEncoder().encode(automatic), encoding: .utf8))
        XCTAssertTrue(text.contains("\"observed_at\":\"2026-11-07T09:00:00.123Z\""), text)
        XCTAssertFalse(text.contains("resolve_conflict"), text)
        let unknown = PendingMutation(position: at(3), expectedVersion: 1, mutationId: "m").update
        let bare = try XCTUnwrap(String(data: JSONEncoder().encode(unknown), encoding: .utf8))
        XCTAssertFalse(bare.contains("observed_at"), "an unknown time is omitted, never the send time")
    }

    func testResponsesReadTheActivityTimeAndIgnoreAMalformedOne() throws {
        let good = try JSONDecoder().decode(ReadingProgress.self, from: Data(#"{"asset_id":"a","version":2,"observed_at":"2026-11-07T10:00:00+01:00","updated_at":"2026-11-07T12:00:00Z"}"#.utf8))
        XCTAssertEqual(good.observedAtMillis, baseTime)
        let missing = try JSONDecoder().decode(ReadingProgress.self, from: Data(#"{"asset_id":"a","version":2,"updated_at":"2026-11-07T12:00:00Z"}"#.utf8))
        XCTAssertNil(missing.observedAtMillis, "updated_at is never activity time")
        let odd = try JSONDecoder().decode(ReadingProgress.self, from: Data(#"{"asset_id":"a","version":2,"observed_at":17}"#.utf8))
        XCTAssertNil(odd.observedAtMillis)
        let zoneless = try JSONDecoder().decode(ReadingProgress.self, from: Data(#"{"asset_id":"a","version":2,"observed_at":"2026-11-07T09:00:00"}"#.utf8))
        XCTAssertNil(zoneless.observedAtMillis)
    }
}

final class ResumeDecisionTests: XCTestCase {
    private let book = Publication(id: "p", title: "T", bookType: .ebook, assets: [Asset(id: "a1", format: "epub", contentUrl: "/c")])

    private func locator(_ total: Double) -> JSONValue {
        .object(["href": .string("c"), "locations": .object(["totalProgression": .number(total)])])
    }

    private func server(_ version: Int, asset: String = "a1", total: Double = 0.5, observed: Int64? = nil, mutation: String? = nil) -> ReadingProgress {
        ReadingProgress(assetId: asset, locator: locator(total), version: version, clientMutationId: mutation, observedAt: observed.map(ActivityTime.format))
    }

    private func local(dirty: Bool, base: Int, asset: String = "a1", total: Double = 0.2, observed: Int64? = nil, pending: PendingMutation? = nil, rejected: Bool = false) -> LocalProgress {
        LocalProgress(publicationId: "p", position: SavedPosition(assetId: asset, locator: locator(total)), baseVersion: base, dirty: dirty, pending: pending, observedAt: observed, rejected: rejected)
    }

    private func decide(_ server: ReadingProgress?, _ local: LocalProgress?, offline: Bool = false) -> ResumeDecision {
        ResumeDecision.decide(publication: book, server: server, local: local, offline: offline, now: baseTime)
    }

    func testOfflineUsesTheLatestLocalPlaceEvenAfterItWasSynced() {
        XCTAssertEqual(
            decide(server(2), local(dirty: false, base: 3, observed: baseTime - 10), offline: true),
            .resume(SavedPosition(assetId: "a1", locator: locator(0.2)), baseVersion: 3, observedAt: baseTime - 10)
        )
    }

    func testNothingSaved() {
        XCTAssertEqual(decide(nil, nil), .beginning)
    }

    func testServerWinsOverACleanLocalCopyAndKeepsItsTime() {
        XCTAssertEqual(
            decide(server(4, observed: baseTime - 5000), local(dirty: false, base: 3)),
            .resume(SavedPosition(assetId: "a1", locator: locator(0.5)), baseVersion: 4, observedAt: baseTime - 5000)
        )
    }

    func testUnsentReadingContinuesWhenTheServerHasNotMoved() {
        XCTAssertEqual(
            decide(server(3), local(dirty: true, base: 3, observed: baseTime - 1)),
            .resume(SavedPosition(assetId: "a1", locator: locator(0.2)), baseVersion: 3, observedAt: baseTime - 1)
        )
    }

    func testLaterUnsentReadingWinsEvenWhenItIsEarlierInTheBook() {
        XCTAssertEqual(
            decide(server(5, total: 0.9, observed: baseTime - 60000), local(dirty: true, base: 3, total: 0.2, observed: baseTime - 1000)),
            .resume(SavedPosition(assetId: "a1", locator: locator(0.2)), baseVersion: 5, observedAt: baseTime - 1000)
        )
    }

    func testLaterServerReadingWinsOverOlderUnsentReading() {
        XCTAssertEqual(
            decide(server(5, total: 0.1, observed: baseTime - 1000), local(dirty: true, base: 3, total: 0.8, observed: baseTime - 60000)),
            .resume(SavedPosition(assetId: "a1", locator: locator(0.1)), baseVersion: 5, observedAt: baseTime - 1000)
        )
    }

    func testUnorderableTimesAsk() {
        let cases: [(Int64?, Int64?)] = [
            (nil, baseTime - 1000), // a legacy local record
            (baseTime - 1000, nil), // an older server or row
            (baseTime - 1000, baseTime - 1000), // equal times, different places
            (baseTime - 1000, baseTime + 10 * 60000), // another device's clock is far ahead
            (baseTime + 10 * 60000, baseTime - 1000), // this device's stored time is implausible now
            (500, baseTime - 1000), // a clock that was never set
        ]
        for (mine, theirs) in cases {
            guard case .choose = decide(server(5, observed: theirs), local(dirty: true, base: 3, observed: mine)) else {
                return XCTFail("expected a choice for local \(String(describing: mine)) server \(String(describing: theirs))")
            }
        }
    }

    func testIdenticalPlacesNeverAsk() {
        guard case .resume = decide(server(5, total: 0.2), local(dirty: true, base: 3)) else {
            return XCTFail("expected resume")
        }
    }

    func testAQueuedWriteTheServerAlreadyHoldsIsNotAConflict() {
        let pending = PendingMutation(position: SavedPosition(assetId: "a1", locator: locator(0.2)), expectedVersion: 3, mutationId: "mine")
        XCTAssertEqual(
            decide(server(4, total: 0.2, mutation: "mine"), local(dirty: false, base: 3, pending: pending)),
            .resume(SavedPosition(assetId: "a1", locator: locator(0.2)), baseVersion: 4, observedAt: nil)
        )
    }

    func testAPlaceTheServerRefusedAlwaysAsks() {
        guard case .choose = decide(server(5, observed: baseTime - 60000), local(dirty: true, base: 3, observed: baseTime - 1000, rejected: true)) else {
            return XCTFail("expected a choice")
        }
    }

    func testAPositionOnAReplacedAssetIsNotApplied() {
        XCTAssertEqual(decide(server(5, asset: "old"), nil), .editionChanged(staleVersion: 5))
        XCTAssertEqual(decide(server(5, asset: "old"), local(dirty: true, base: 5, asset: "old")), .editionChanged(staleVersion: 5))
    }

    func testVersionZeroMeansNoSavedState() {
        XCTAssertEqual(decide(ReadingProgress(assetId: "a1", version: 0), nil), .beginning)
    }
}

@testable import ShelfarrCore
import XCTest

private final class Remote: @unchecked Sendable {
    var calls: [ProgressUpdate] = []
    var failures: [Error] = []
    var version = 0

    func save(_: String, _ update: ProgressUpdate) async throws -> ReadingProgress {
        calls.append(update)
        if !failures.isEmpty { throw failures.removeFirst() }
        version += 1
        return ReadingProgress(assetId: update.assetId, locator: update.locator, positionSeconds: update.positionSeconds, version: version, clientMutationId: update.clientMutationId)
    }
}

private actor MemoryStore: ProgressStore {
    var records: [String: LocalProgress] = [:]
    func get(_ id: String) -> LocalProgress? { records[id] }
    func put(_ record: LocalProgress) { records[record.publicationId] = record }
    func unsynced() -> [LocalProgress] { records.values.filter { $0.hasUnsyncedChanges && $0.conflict == nil } }
}

final class ProgressTests: XCTestCase {
    private func at(_ seconds: Double) -> SavedPosition { SavedPosition(assetId: "a", positionSeconds: seconds) }

    private func makeSync(_ store: ProgressStore, _ remote: Remote, debounce: Duration = .seconds(60)) -> ProgressSync {
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
            newMutationId: {
                counter.value += 1
                return "m\(counter.value)"
            }
        )
    }

    func testSavesLocallyAtOnceAndSendsOnFlush() async {
        let store = MemoryStore(), remote = Remote()
        let sync = makeSync(store, remote)
        await sync.update(at(1))
        let saved = await store.get("p")
        XCTAssertEqual(saved?.position, at(1))
        XCTAssertTrue(remote.calls.isEmpty)
        await sync.flush()
        XCTAssertEqual(remote.calls.map(\.expectedVersion), [0])
        let status = await sync.status
        XCTAssertEqual(status, .saved)
    }

    func testDebounceFiresBySelf() async throws {
        let store = MemoryStore(), remote = Remote()
        let sync = makeSync(store, remote, debounce: .milliseconds(20))
        await sync.update(at(1))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(remote.calls.count, 1)
    }

    func testRepeatingTheSamePlaceSendsNothing() async {
        let store = MemoryStore(), remote = Remote()
        let sync = makeSync(store, remote)
        await sync.begin(position: at(4), baseVersion: 2)
        await sync.update(at(4))
        await sync.flush()
        XCTAssertTrue(remote.calls.isEmpty)
    }

    func testAFailedSendKeepsTheSameMutationAndBody() async {
        let store = MemoryStore(), remote = Remote()
        remote.failures = [APIError.offline(certificate: false)]
        let sync = makeSync(store, remote)
        await sync.update(at(1))
        await sync.flush()
        let waiting = await sync.status
        XCTAssertEqual(waiting, .waitingForServer)
        await sync.flush()
        XCTAssertEqual(remote.calls.count, 2)
        XCTAssertEqual(remote.calls[0], remote.calls[1])
    }

    func testNewerPlacesWaitBehindAnUnansweredWrite() async {
        let store = MemoryStore(), remote = Remote()
        remote.failures = [APIError.server(503)]
        let sync = makeSync(store, remote)
        await sync.update(at(1))
        await sync.flush()
        await sync.update(at(2))
        await sync.flush()
        XCTAssertEqual(remote.calls.map(\.clientMutationId), ["m1", "m1", "m2"])
        XCTAssertEqual(remote.calls[2].positionSeconds, 2)
        XCTAssertEqual(remote.calls[2].expectedVersion, 1)
    }

    func testUnansweredWriteSurvivesARestart() async {
        let store = MemoryStore(), remote = Remote()
        remote.failures = [APIError.offline(certificate: false)]
        let first = makeSync(store, remote)
        await first.update(at(1))
        await first.flush()
        let restored = makeSync(store, remote)
        await restored.flush()
        XCTAssertEqual(remote.calls.map(\.clientMutationId), ["m1", "m1"])
    }

    func testAConflictReportingOurOwnMutationCountsAsSaved() async {
        let store = MemoryStore(), remote = Remote()
        remote.failures = [APIError.progressConflict(ReadingProgress(assetId: "a", positionSeconds: 1, version: 8, clientMutationId: "m1"))]
        let sync = makeSync(store, remote)
        await sync.update(at(1))
        await sync.flush()
        let record = await store.get("p")
        XCTAssertEqual(record?.baseVersion, 8)
        XCTAssertEqual(record?.hasUnsyncedChanges, false)
    }

    func testARealConflictStopsSendingAndAsks() async {
        let store = MemoryStore(), remote = Remote()
        let theirs = ReadingProgress(assetId: "a", positionSeconds: 90, version: 8, clientMutationId: "other")
        remote.failures = [APIError.progressConflict(theirs)]
        let sync = makeSync(store, remote)
        await sync.update(at(1))
        await sync.flush()
        let status = await sync.status
        XCTAssertEqual(status, .conflict(local: at(1), server: theirs))
        await sync.update(at(2))
        await sync.flush()
        XCTAssertEqual(remote.calls.count, 1)
    }

    func testKeepingThisDeviceWritesOnTopOfTheNewerVersion() async {
        let store = MemoryStore(), remote = Remote()
        remote.failures = [APIError.progressConflict(ReadingProgress(assetId: "a", positionSeconds: 90, version: 8, clientMutationId: "o"))]
        remote.version = 8
        let sync = makeSync(store, remote)
        await sync.update(at(1))
        await sync.flush()
        await sync.keepLocal()
        XCTAssertEqual(remote.calls.last?.expectedVersion, 8)
        XCTAssertEqual(remote.calls.last?.clientMutationId, "m2")
    }

    func testUsingTheOtherDeviceAdoptsItsPlace() async {
        let store = MemoryStore(), remote = Remote()
        remote.failures = [APIError.progressConflict(ReadingProgress(assetId: "a", positionSeconds: 90, version: 8, clientMutationId: "o"))]
        let sync = makeSync(store, remote)
        await sync.update(at(1))
        await sync.flush()
        let adopted = await sync.useServer()
        XCTAssertEqual(adopted, at(90))
        XCTAssertEqual(remote.calls.count, 1)
        let record = await store.get("p")
        XCTAssertEqual(record?.hasUnsyncedChanges, false)
    }

    func testAnInvalidPositionIsDropped() async {
        let store = MemoryStore(), remote = Remote()
        remote.failures = [APIError.rejected("invalid")]
        let sync = makeSync(store, remote)
        await sync.update(at(1))
        await sync.flush()
        let status = await sync.status
        XCTAssertEqual(status, .rejected)
    }

    func testALostSessionKeepsTheWrite() async {
        let store = MemoryStore(), remote = Remote()
        remote.failures = [APIError.unauthorized]
        let sync = makeSync(store, remote)
        await sync.update(at(1))
        await sync.flush()
        let status = await sync.status
        XCTAssertEqual(status, .needsSignIn)
        let record = await store.get("p")
        XCTAssertEqual(record?.hasUnsyncedChanges, true)
    }

    func testFileStoreRoundTrips() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a/progress.json")
        let record = LocalProgress(publicationId: "p", position: at(3), baseVersion: 2, dirty: true)
        await FileProgressStore(file: file).put(record)
        let again = await FileProgressStore(file: file).get("p")
        XCTAssertEqual(again, record)
    }
}

final class ResumeDecisionTests: XCTestCase {
    private let book = Publication(id: "p", title: "T", bookType: .ebook, assets: [Asset(id: "a1", format: "epub", contentUrl: "/c")])

    private func locator(_ total: Double) -> JSONValue {
        .object(["href": .string("c"), "locations": .object(["totalProgression": .number(total)])])
    }

    private func server(_ version: Int, asset: String = "a1", total: Double = 0.5) -> ReadingProgress {
        ReadingProgress(assetId: asset, locator: locator(total), version: version)
    }

    private func local(dirty: Bool, base: Int, asset: String = "a1", total: Double = 0.2) -> LocalProgress {
        LocalProgress(publicationId: "p", position: SavedPosition(assetId: asset, locator: locator(total)), baseVersion: base, dirty: dirty)
    }

    func testNothingSaved() {
        XCTAssertEqual(ResumeDecision.decide(publication: book, server: nil, local: nil), .beginning)
    }

    func testServerWinsOverACleanLocalCopy() {
        XCTAssertEqual(
            ResumeDecision.decide(publication: book, server: server(4), local: local(dirty: false, base: 3)),
            .resume(SavedPosition(assetId: "a1", locator: locator(0.5)), baseVersion: 4)
        )
    }

    func testUnsentReadingContinuesWhenTheServerHasNotMoved() {
        XCTAssertEqual(
            ResumeDecision.decide(publication: book, server: server(3), local: local(dirty: true, base: 3)),
            .resume(SavedPosition(assetId: "a1", locator: locator(0.2)), baseVersion: 3)
        )
    }

    func testNewerServerAgainstUnsentReadingAsks() {
        guard case .choose = ResumeDecision.decide(publication: book, server: server(5), local: local(dirty: true, base: 3)) else {
            return XCTFail("expected a choice")
        }
    }

    func testIdenticalPlacesNeverAsk() {
        guard case .resume = ResumeDecision.decide(publication: book, server: server(5, total: 0.2), local: local(dirty: true, base: 3)) else {
            return XCTFail("expected resume")
        }
    }

    func testAPositionOnAReplacedAssetIsNotApplied() {
        XCTAssertEqual(ResumeDecision.decide(publication: book, server: server(5, asset: "old"), local: nil), .editionChanged(staleVersion: 5))
        XCTAssertEqual(
            ResumeDecision.decide(publication: book, server: server(5, asset: "old"), local: local(dirty: true, base: 5, asset: "old")),
            .editionChanged(staleVersion: 5)
        )
    }

    func testVersionZeroMeansNoSavedState() {
        XCTAssertEqual(ResumeDecision.decide(publication: book, server: ReadingProgress(assetId: "a1", version: 0), local: nil), .beginning)
    }
}

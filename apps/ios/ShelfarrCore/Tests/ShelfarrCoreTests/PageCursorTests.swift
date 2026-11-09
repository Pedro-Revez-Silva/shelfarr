import Foundation
@testable import ShelfarrCore
import XCTest

/// What the page views report, in the orders they can report it: images decode one at a
/// time on a serial queue, layouts rebuild a spread without a turn, and the opening page
/// can arrive after the restore timeout. Only the reader turning to a drawn page is reading.
final class PageRestorationLifecycleTests: XCTestCase {
    func testAnOddPageStaysTheAnchorWhileALayoutRedrawsItsSpread() {
        var restoration = PageRestoration(opening: 5)
        XCTAssertEqual(restoration.observe(5), .settled)
        // Rotating into two pages rebuilds spread 4-5; page 4 decodes first.
        XCTAssertEqual(restoration.observe(visible: 4 ... 5, displayed: nil), .none, "nothing drawn yet")
        XCTAssertEqual(restoration.observe(visible: 4 ... 5, displayed: 4 ... 4), .none, "page 5 is still on screen, loading")
        XCTAssertEqual(restoration.observe(visible: 4 ... 5, displayed: 4 ... 5), .none)
        XCTAssertEqual(restoration.anchor, 5)
        // And with page 5 drawn first.
        XCTAssertEqual(restoration.observe(visible: 4 ... 5, displayed: 5 ... 5), .none)
        XCTAssertEqual(restoration.observe(5), .none, "back to one page")
        XCTAssertEqual(restoration.observe(visible: 6 ... 7, displayed: 6 ... 7), .record(6), "a real turn still records")
    }

    func testTheSavedPageFailingDuringALayoutIsNotATurn() {
        var restoration = PageRestoration(opening: 5)
        XCTAssertEqual(restoration.observe(5), .settled)
        XCTAssertEqual(restoration.couldNotShow(5), .none, "not restoring")
        XCTAssertEqual(restoration.observe(visible: 4 ... 5, displayed: 4 ... 4), .none, "its other half drew")
        XCTAssertEqual(restoration.anchor, 5)
    }

    func testANavigatedSpreadSavesItsDrawnHalfWhicheverFinishesOrFails() {
        func turned(_ reports: [ClosedRange<Int>?]) -> [PageRestoration.Action] {
            var restoration = PageRestoration(opening: 3)
            XCTAssertEqual(restoration.observe(2 ... 3), .settled)
            return reports.map { restoration.observe(visible: 4 ... 5, displayed: $0) }
        }
        XCTAssertEqual(turned([4 ... 4, 4 ... 4]), [.record(4), .none], "page 4 drew, then 5 failed")
        XCTAssertEqual(turned([nil, 4 ... 4]), [.none, .record(4)], "page 5 failed, then 4 drew")
        XCTAssertEqual(turned([nil, 5 ... 5]), [.none, .record(5)], "page 4 failed, then 5 drew")
        XCTAssertEqual(turned([5 ... 5, 4 ... 5]), [.record(5), .none], "page 5 drew first: the first drawn page is saved once")
        XCTAssertEqual(turned([nil, nil]), [.none, .none], "both failed: nothing is saved")
    }

    func testBackwardTurnsStillRecord() {
        var restoration = PageRestoration(opening: 6)
        XCTAssertEqual(restoration.observe(visible: 6 ... 7, displayed: 6 ... 7), .settled)
        XCTAssertEqual(restoration.observe(visible: 4 ... 5, displayed: 5 ... 5), .record(5))
        XCTAssertEqual(restoration.observe(visible: 2 ... 3, displayed: 2 ... 3), .record(2))
        XCTAssertEqual(restoration.observe(1), .record(1))
    }

    func testAnOpeningRightHalfWaitsForItsImageInsteadOfCorrecting() {
        var restoration = PageRestoration(opening: 5)
        XCTAssertEqual(restoration.observe(visible: 4 ... 5, displayed: 4 ... 4), .none, "page 5 is on screen, still decoding")
        XCTAssertTrue(restoration.isRestoring)
        XCTAssertEqual(restoration.observe(visible: 4 ... 5, displayed: 4 ... 5), .settled)
        XCTAssertEqual(restoration.anchor, 5)
    }

    func testABrokenOpeningPageKeepsThePlaceWhileItsOtherHalfDraws() {
        var restoration = PageRestoration(opening: 5)
        XCTAssertEqual(restoration.couldNotShow(5), .gaveUp)
        XCTAssertEqual(restoration.observe(visible: 4 ... 5, displayed: 4 ... 4), .none)
        XCTAssertEqual(restoration.observe(visible: 4 ... 5, displayed: 4 ... 4), .none, "rotations and redraws")
        XCTAssertTrue(restoration.readerNavigates(), "the reader skips it")
        XCTAssertEqual(restoration.observe(visible: 6 ... 7, displayed: 6 ... 7), .record(6))
    }

    func testRetryingABrokenOpeningPageIsNotATurn() {
        var restoration = PageRestoration(opening: 5)
        XCTAssertEqual(restoration.couldNotShow(5), .gaveUp)
        XCTAssertTrue(restoration.readerNavigates(), "Go to page 5 again")
        XCTAssertEqual(restoration.observe(5), .none, "it drew this time: still the saved place")
        XCTAssertEqual(restoration.observe(6), .record(6))
    }

    func testTheOpeningPageArrivingAfterTheTimeoutSettlesSilently() {
        var restoration = PageRestoration(opening: 1)
        XCTAssertEqual(restoration.timedOut(), .gaveUp)
        XCTAssertEqual(restoration.timedOut(), .none, "once")
        XCTAssertTrue(restoration.isRestoring, "still waiting for it, without holding input")
        XCTAssertEqual(restoration.observe(visible: 1 ... 1, displayed: nil), .none)
        XCTAssertEqual(restoration.observe(1), .settled, "late, but not reading")
        XCTAssertEqual(restoration.observe(2), .record(2))
    }

    func testAfterTheTimeoutTheViewMovingOnItsOwnIsNotReading() {
        var restoration = PageRestoration(opening: 5)
        XCTAssertEqual(restoration.timedOut(), .gaveUp)
        XCTAssertEqual(restoration.observe(1), .none, "no correction and no record once input is handed back")
        XCTAssertEqual(restoration.observe(2), .none)
        XCTAssertEqual(restoration.observe(5), .settled)
    }

    func testTheReaderTurningAfterTheTimeoutRecordsAndTheLateOpeningPageDoesnt() {
        var restoration = PageRestoration(opening: 1)
        XCTAssertEqual(restoration.timedOut(), .gaveUp)
        XCTAssertTrue(restoration.readerNavigates())
        XCTAssertFalse(restoration.isRestoring)
        XCTAssertEqual(restoration.observe(1), .none, "the opening page's late image, before the turn lands")
        XCTAssertEqual(restoration.observe(visible: 2 ... 2, displayed: nil), .none, "still loading")
        XCTAssertEqual(restoration.observe(2), .record(2))
        XCTAssertFalse(restoration.readerNavigates(), "not restoring")
    }

    func testAChosenPlaceIsRestoredSilentlyEvenLate() {
        var restoration = PageRestoration(opening: 2)
        XCTAssertEqual(restoration.observe(2), .settled)
        XCTAssertEqual(restoration.reopen(at: 7), .correct(7))
        XCTAssertEqual(restoration.timedOut(), .gaveUp)
        XCTAssertEqual(restoration.observe(2), .none, "the old page, before the jump")
        XCTAssertEqual(restoration.observe(7), .settled)
        XCTAssertEqual(restoration.observe(8), .record(8))
    }
}

/// The same reports through the reader's cursor into the real `ProgressSync` and
/// `FileProgressStore`: what ends up durable, and with which activity time.
final class PageCursorPersistenceTests: XCTestCase {
    private let savedAt: Int64 = 1_794_000_000_000
    private let order = ReadingOrder(assetId: "cbz", items: (1 ... 10).map { n in
        ReadingOrder.Item(position: n, href: "Issue%201/p\(n).png", mediaType: "image/png", sizeBytes: 1, compressedSize: 1, compressionMethod: 0, localHeaderOffset: Int64(n * 100), crc32: "00000000")
    })
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("page-cursor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A reading session's sync: nothing is sent during the test, so the durable outbox is
    /// exactly what the reader wrote.
    private func session(_ name: String, saved: SavedPosition?) async -> (ProgressSync, URL) {
        let file = folder.appendingPathComponent("\(name).json")
        var timing = SyncTiming()
        timing.debounce = .seconds(600)
        timing.maxWait = .seconds(600)
        let sync = ProgressSync(publicationId: "book", store: FileProgressStore(file: file), remote: { _, _ in throw APIError.offline(certificate: false) }, timing: timing)
        await sync.begin(position: saved, baseVersion: 3, observedAt: saved == nil ? nil : savedAt)
        return (sync, file)
    }

    /// The reader's handling of a report: write exactly the save it returns (ReaderModel).
    private func shows(_ cursor: inout PageCursor, _ sync: ProgressSync, _ visible: ClosedRange<Int>, _ displayed: ClosedRange<Int>?, at time: Int64) async -> PageRestoration.Action {
        let outcome = cursor.shows(visible: visible, displayed: displayed, observedAt: time)
        if let save = outcome.save { await sync.update(save.position, observedAt: save.observedAt) }
        return outcome.action
    }

    private func durable(_ sync: ProgressSync, _ file: URL) async throws -> LocalProgress? {
        await sync.stop()
        return try await FileProgressStore(file: file).get("book")
    }

    private func comic(_ page: Int) -> SavedPosition {
        SavedPosition(assetId: "cbz", locator: PageLocator.comic(page: page, order: order))
    }

    private func assertUnchanged(_ record: LocalProgress?, _ saved: SavedPosition?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(record?.position, saved, "the saved place", file: file, line: line)
        XCTAssertEqual(record?.dirty ?? false, false, "nothing to send", file: file, line: line)
        XCTAssertEqual(record?.touched ?? false, false, "no reading recorded", file: file, line: line)
        XCTAssertEqual(record?.observedAt, saved == nil ? nil : savedAt, "the time it was reached", file: file, line: line)
    }

    func testRotatingIntoASpreadAtAnOddPageWritesNothing() async throws {
        let saved = comic(5)
        let (sync, file) = await session("spread", saved: saved)
        var cursor = PageCursor(assetId: "cbz", pages: .comic(order), opening: 5)
        let settle = await shows(&cursor, sync, 5 ... 5, 5 ... 5, at: savedAt + 1000)
        XCTAssertEqual(settle, .settled)
        // The layout rebuilds spread 4-5 and page 4 decodes before page 5.
        for drawn: ClosedRange<Int>? in [nil, 4 ... 4, 4 ... 5] {
            let action = await shows(&cursor, sync, 4 ... 5, drawn, at: savedAt + 5001)
            XCTAssertEqual(action, .none)
        }
        assertUnchanged(try await durable(sync, file), saved)
    }

    func testTheSavedPageFailingInANewSpreadWritesNothing() async throws {
        let saved = comic(5)
        let (sync, file) = await session("spread-failed", saved: saved)
        var cursor = PageCursor(assetId: "cbz", pages: .comic(order), opening: 5)
        _ = await shows(&cursor, sync, 5 ... 5, 5 ... 5, at: savedAt + 1000)
        XCTAssertEqual(cursor.couldNotShow(5), .none)
        let action = await shows(&cursor, sync, 4 ... 5, 4 ... 4, at: savedAt + 5001)
        XCTAssertEqual(action, .none)
        assertUnchanged(try await durable(sync, file), saved)
    }

    func testABrokenOpeningPageWritesNothingUntilTheReaderSkipsIt() async throws {
        let saved = comic(5)
        let (sync, file) = await session("broken-opening", saved: saved)
        var cursor = PageCursor(assetId: "cbz", pages: .comic(order), opening: 5)
        XCTAssertEqual(cursor.couldNotShow(5), .gaveUp)
        let half = await shows(&cursor, sync, 4 ... 5, 4 ... 4, at: savedAt + 1000)
        XCTAssertEqual(half, .none, "the spread's other half drew")
        assertUnchanged(try await FileProgressStore(file: file).get("book"), saved)
        cursor.readerNavigates()
        let skipped = await shows(&cursor, sync, 6 ... 7, 6 ... 7, at: savedAt + 9000)
        XCTAssertEqual(skipped, .record(6))
        let record = try await durable(sync, file)
        XCTAssertEqual(record?.position, comic(6))
        XCTAssertEqual(record?.observedAt, savedAt + 9000)
    }

    func testATurnToASpreadWritesItsDrawnHalfWithTheTimeItWasDrawn() async throws {
        for (failed, drawn) in [(5, 4), (4, 5)] {
            let (sync, file) = await session("turn-\(failed)", saved: comic(3))
            var cursor = PageCursor(assetId: "cbz", pages: .comic(order), opening: 3)
            _ = await shows(&cursor, sync, 2 ... 3, 2 ... 3, at: savedAt + 1000)
            cursor.readerNavigates()
            // The failed half reports first, then the other half draws.
            XCTAssertEqual(cursor.couldNotShow(failed), .none)
            let pending = await shows(&cursor, sync, 4 ... 5, nil, at: savedAt + 2000)
            XCTAssertEqual(pending, .none)
            let turn = await shows(&cursor, sync, 4 ... 5, drawn ... drawn, at: savedAt + 2500)
            XCTAssertEqual(turn, .record(drawn))
            let record = try await durable(sync, file)
            XCTAssertEqual(record?.position, comic(drawn), "the page that drew, never the failed one")
            XCTAssertEqual(record?.observedAt, savedAt + 2500, "when it was drawn, unchanged")
            XCTAssertEqual(record?.dirty, true)
        }
    }

    func testALateOpeningPageAfterTheTimeoutKeepsTheOtherFormatsPlace() async throws {
        // The place is in the PDF; the comic opens at its beginning.
        let pdfPlace = SavedPosition(assetId: "pdf", locator: PageLocator.pdf(page: 99, pageCount: 100))
        let (sync, file) = await session("format-switch", saved: pdfPlace)
        var cursor = PageCursor(assetId: "cbz", pages: .comic(order), opening: 1)
        XCTAssertEqual(cursor.timedOut(), .gaveUp)
        let late = await shows(&cursor, sync, 1 ... 1, 1 ... 1, at: savedAt + 5001)
        XCTAssertEqual(late, .settled)
        assertUnchanged(try await durable(sync, file), pdfPlace)
    }

    func testAfterTheTimeoutOnlyTheReaderTurningMovesThePlace() async throws {
        let pdfPlace = SavedPosition(assetId: "pdf", locator: PageLocator.pdf(page: 99, pageCount: 100))
        let (sync, file) = await session("give-up-turn", saved: pdfPlace)
        var cursor = PageCursor(assetId: "cbz", pages: .comic(order), opening: 1)
        XCTAssertEqual(cursor.timedOut(), .gaveUp)
        XCTAssertTrue(cursor.readerNavigates())
        let lateOpening = await shows(&cursor, sync, 1 ... 1, 1 ... 1, at: savedAt + 5001)
        XCTAssertEqual(lateOpening, .none, "page 1's image landing before the turn")
        let turn = await shows(&cursor, sync, 2 ... 2, 2 ... 2, at: savedAt + 6000)
        XCTAssertEqual(turn, .record(2))
        let record = try await durable(sync, file)
        XCTAssertEqual(record?.position, comic(2))
        XCTAssertEqual(record?.observedAt, savedAt + 6000)
        XCTAssertEqual(record?.dirty, true)
    }

    func testALateFallbackPageKeepsTheInvalidPlace() async throws {
        // Page 40 of a ten-page comic: the reader chose where to start looking.
        let invalid = SavedPosition(assetId: "cbz", locator: .object([
            "href": .string("replaced/p40.png"), "type": .string("image/png"),
            "locations": .object(["position": .number(40)]),
        ]))
        XCTAssertNil(PageCursor.Pages.comic(order).page(invalid.locator))
        for start in [1, 10] {
            let (sync, file) = await session("invalid-\(start)", saved: invalid)
            var cursor = PageCursor(assetId: "cbz", pages: .comic(order), opening: start)
            XCTAssertEqual(cursor.timedOut(), .gaveUp)
            let late = await shows(&cursor, sync, start ... start, start ... start, at: savedAt + 5001)
            XCTAssertEqual(late, .settled)
            assertUnchanged(try await durable(sync, file), invalid)
        }
    }

    func testALateFirstPageWithNoSavedPlaceWritesNothing() async throws {
        let (sync, file) = await session("no-place", saved: nil)
        var cursor = PageCursor(assetId: "cbz", pages: .comic(order), opening: 1)
        XCTAssertEqual(cursor.timedOut(), .gaveUp)
        let late = await shows(&cursor, sync, 1 ... 1, 1 ... 1, at: savedAt + 5001)
        XCTAssertEqual(late, .settled)
        let record = try await durable(sync, file)
        XCTAssertNil(record?.position, "choosing a format is not reading")
        XCTAssertEqual(record?.dirty ?? false, false)
    }

    func testReopeningSilentlyEvenAfterTheTimeout() async throws {
        let saved = SavedPosition(assetId: "pdf", locator: PageLocator.pdf(page: 4, pageCount: 6))
        let (sync, file) = await session("reopen", saved: saved)
        var cursor = PageCursor(assetId: "pdf", pages: .pdf(count: 6), opening: 4)
        // The view starts on page 1; corrected, then the timeout hands input back.
        let first = await shows(&cursor, sync, 1 ... 1, 1 ... 1, at: savedAt + 100)
        XCTAssertEqual(first, .correct(4))
        XCTAssertEqual(cursor.timedOut(), .gaveUp)
        let drift = await shows(&cursor, sync, 2 ... 2, 2 ... 2, at: savedAt + 5001)
        XCTAssertEqual(drift, .none, "the view moving by itself")
        let late = await shows(&cursor, sync, 4 ... 4, 4 ... 4, at: savedAt + 5002)
        XCTAssertEqual(late, .settled)
        assertUnchanged(try await durable(sync, file), saved)
    }

    func testPlacesNameOnlyThisFilesPages() {
        let pdf = PageCursor.Pages.pdf(count: 6)
        XCTAssertEqual(pdf.locator(6), PageLocator.pdf(page: 6, pageCount: 6))
        XCTAssertNil(pdf.locator(7))
        XCTAssertNil(pdf.locator(0))
        XCTAssertNil(PageCursor.Pages.pdf(count: 0).locator(1))
        XCTAssertEqual(pdf.page(PageLocator.pdf(page: 3, pageCount: 6)), 3)
        let comic = PageCursor.Pages.comic(order)
        XCTAssertEqual(comic.count, 10)
        XCTAssertEqual(comic.page(comic.locator(10)), 10)
        XCTAssertNil(comic.locator(11))
        XCTAssertNil(comic.page(pdf.locator(1)), "a PDF place in a comic")
    }
}

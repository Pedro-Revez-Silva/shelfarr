import ShelfarrCore
import XCTest

final class ReadingRestorationTests: XCTestCase {
    private func place(_ href: String, _ progression: Double) -> JSONValue {
        .object(["href": .string(href), "locations": .object(["progression": .number(progression)])])
    }

    /// A navigator report of one page: its locator is the page start, as Readium's is.
    private func page(_ href: String, _ from: Double, _ to: Double) -> ReadingObservation {
        ReadingObservation(
            locator: place(href, from),
            viewport: ReadingViewport(resources: [.init(href: href, progression: from ... to)])
        )
    }

    private func correct(_ target: JSONValue, _ attempt: Int) -> ReadingRestoration.Action {
        .correct(target: target, attempt: attempt)
    }

    func testAReportShowingTheSavedPlaceRestoresItWithoutSaving() {
        var restoring = ReadingRestoration(opening: place("c0.xhtml", 0.15))
        XCTAssertEqual(restoring.observe(page("/c0.xhtml", 0.12, 0.18)), .settled)
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0.12, 0.18)), .none, "the same page reported again")
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0.18, 0.24)), .record, "a forward page turn is reading")
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0.12, 0.18)), .record, "after moving, coming back is reading too")
    }

    /// The CI failure: a cold, offline open reported the chapter start before the page was
    /// laid out at 15%. That report must not be saved, and the reader is sent back.
    func testAWrongFirstReportIsCorrectedAndNeverSaved() {
        let target = place("c0.xhtml", 0.5)
        var restoring = ReadingRestoration(opening: target)
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0, 0.06)), correct(target, 1))
        XCTAssertTrue(restoring.isCorrecting, "input stays disabled until the saved place shows")
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0, 0.06)), .none, "the jump finishing is not proof")
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0.3, 0.36)), .none, "nor is a page on the way")
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0.48, 0.54)), .settled)
        XCTAssertFalse(restoring.isCorrecting)
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0.48, 0.54)), .none)
    }

    func testAFirstReportInAnotherChapterIsCorrected() {
        let target = place("c1.xhtml", 0.3)
        var restoring = ReadingRestoration(opening: target)
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0, 0.06)), correct(target, 1))
        XCTAssertEqual(restoring.observe(page("c1.xhtml", 0.28, 0.33)), .settled)
    }

    /// Readium lands on the start of the page holding the saved progression, which can be
    /// more than 2% earlier on a large page or a different layout. That page is the place.
    func testAPageStartingWellBeforeTheSavedProgressionIsTheRestoredPage() {
        var restoring = ReadingRestoration(opening: place("c1.xhtml", 0.507))
        XCTAssertEqual(restoring.observe(page("c1.xhtml", 0.46, 0.53)), .settled)
        XCTAssertEqual(restoring.observe(page("c1.xhtml", 0.46, 0.53)), .none)
        XCTAssertEqual(restoring.observe(ReadingObservation(locator: place("c1.xhtml", 0.4600001), viewport: nil)), .none,
                       "the same page measured again with float noise")
    }

    func testAnImmediateBackwardTurnAfterRestorationIsReading() {
        var restoring = ReadingRestoration(opening: place("c0.xhtml", 0.5))
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0.48, 0.54)), .settled)
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0.42, 0.48)), .record)
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0.36, 0.42)), .record)
    }

    func testAnImmediateForwardTurnAfterACorrectionIsReading() {
        let target = place("c0.xhtml", 0.5)
        var restoring = ReadingRestoration(opening: target)
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0, 0.06)), correct(target, 1))
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0.48, 0.54)), .settled)
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0.54, 0.6)), .record, "the next page starts where this one ends")
    }

    func testAnotherChapterAfterRestorationIsReading() {
        var restoring = ReadingRestoration(opening: place("c0.xhtml", 0.97))
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0.95, 1)), .settled)
        XCTAssertEqual(restoring.observe(page("c1.xhtml", 0, 0.05)), .record)
    }

    func testATimeoutRetriesOnceThenGivesUpWithoutSavingTheWrongPage() {
        let target = place("c0.xhtml", 0.5)
        var restoring = ReadingRestoration(opening: target)
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0, 0.06)), correct(target, 1))
        XCTAssertEqual(restoring.timedOut(attempt: 1), correct(target, 2), "one retry, still at the saved place")
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0, 0.06)), .none)
        XCTAssertEqual(restoring.timedOut(attempt: 2), .gaveUp)
        XCTAssertFalse(restoring.isCorrecting, "input is enabled again; turns are not ignored forever")
        XCTAssertEqual(restoring.timedOut(attempt: 2), .none, "a finite number of attempts")
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0, 0.06)), .none, "the page left on screen is still not reading")
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0.06, 0.12)), .record, "the reader's own turn is")
    }

    func testTheSavedPlaceArrivingAfterGivingUpIsNotReading() {
        let target = place("c0.xhtml", 0.5)
        var restoring = ReadingRestoration(opening: target)
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0, 0.06)), correct(target, 1))
        XCTAssertEqual(restoring.timedOut(attempt: 1), correct(target, 2))
        XCTAssertEqual(restoring.timedOut(attempt: 2), .gaveUp)
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0.48, 0.54)), .settled)
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0.48, 0.54)), .none)
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0.54, 0.6)), .record)
    }

    func testGivingUpBeforeAnyReportAnchorsTheNextOne() {
        let target = place("c2.xhtml", 0.4)
        var restoring = ReadingRestoration(opening: nil)
        XCTAssertEqual(restoring.reopen(at: target), correct(target, 1))
        XCTAssertEqual(restoring.timedOut(attempt: 1), correct(target, 2))
        XCTAssertEqual(restoring.timedOut(attempt: 2), .gaveUp)
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0, 0.06)), .none)
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0.06, 0.12)), .record)
    }

    func testStaleTimeoutsChangeNothing() {
        let target = place("c0.xhtml", 0.5)
        var restoring = ReadingRestoration(opening: target)
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0, 0.06)), correct(target, 1))
        XCTAssertEqual(restoring.timedOut(attempt: 1), correct(target, 2))
        XCTAssertEqual(restoring.timedOut(attempt: 1), .none, "the first attempt's timer fired late")
        XCTAssertTrue(restoring.isCorrecting)
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0.48, 0.54)), .settled)
        XCTAssertEqual(restoring.timedOut(attempt: 2), .none, "restored before the timer fired")
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0.48, 0.54)), .none)
    }

    func testOpeningAtTheBeginningAnchorsTheFirstReport() {
        var restoring = ReadingRestoration(opening: nil)
        XCTAssertEqual(restoring.observe(page("cover.xhtml", 0, 1)), .none)
        XCTAssertEqual(restoring.observe(page("cover.xhtml", 0, 1)), .none)
        XCTAssertEqual(restoring.observe(page("c0.xhtml", 0, 0.06)), .record)
    }

    func testGoingToAChosenSavedPlaceIsNotReading() {
        var restoring = ReadingRestoration(opening: place("c1.xhtml", 0.1))
        XCTAssertEqual(restoring.observe(page("c1.xhtml", 0.08, 0.14)), .settled)
        XCTAssertEqual(restoring.observe(page("c1.xhtml", 0.5, 0.56)), .record)
        let chosen = place("c2.xhtml", 0.7)
        XCTAssertEqual(restoring.reopen(at: chosen), correct(chosen, 1))
        XCTAssertEqual(restoring.observe(page("c1.xhtml", 0.5, 0.56)), .none)
        XCTAssertEqual(restoring.observe(page("c2.xhtml", 0.68, 0.73)), .settled)
        XCTAssertEqual(restoring.observe(page("c2.xhtml", 0.73, 0.78)), .record)
    }

    func testAPlaceOnAPageBoundaryBelongsToThePageItStarts() {
        let target = place("c0.xhtml", 0.5)
        XCTAssertFalse(ReadingRestoration.shows(target, in: page("c0.xhtml", 0.45, 0.5)))
        XCTAssertTrue(ReadingRestoration.shows(target, in: page("c0.xhtml", 0.5, 0.55)))
        XCTAssertTrue(ReadingRestoration.shows(target, in: page("c0.xhtml", 0.4999999999, 0.55)))
        XCTAssertTrue(ReadingRestoration.shows(place("c0.xhtml", 1), in: page("c0.xhtml", 0.95, 1)), "a resource's end is inclusive")
        XCTAssertFalse(ReadingRestoration.shows(target, in: page("c1.xhtml", 0.45, 0.55)), "another resource")
    }

    func testHrefsCompareAsReadingOrderPaths() {
        XCTAssertTrue(ReadingRestoration.shows(place("OEBPS/c0.xhtml", 0.2), in: page("/OEBPS/c0.xhtml", 0.1, 0.3)))
        XCTAssertTrue(ReadingRestoration.shows(place("OEBPS/c0.xhtml#part", 0.2), in: page("OEBPS/c0.xhtml", 0.1, 0.3)))
        XCTAssertTrue(ReadingRestoration.shows(place("OEBPS/c%20one.xhtml", 0.2), in: page("OEBPS/c one.xhtml", 0.1, 0.3)))
        XCTAssertFalse(ReadingRestoration.shows(place("OEBPS/c0.xhtml", 0.2), in: page("OEBPS/c01.xhtml", 0.1, 0.3)))
    }

    func testWithoutAMeasuredViewportOnlyTheExactPlaceCounts() {
        let target = place("c0.xhtml", 0.5)
        var exact = ReadingRestoration(opening: target)
        XCTAssertEqual(exact.observe(ReadingObservation(locator: place("c0.xhtml", 0.5), viewport: nil)), .settled)
        var earlier = ReadingRestoration(opening: target)
        XCTAssertEqual(earlier.observe(ReadingObservation(locator: place("c0.xhtml", 0.49), viewport: nil)), correct(target, 1))
    }

    func testATwoResourceViewportShowsEither() {
        let viewport = ReadingViewport(resources: [
            .init(href: "c0.xhtml", progression: 0.9 ... 1),
            .init(href: "c1.xhtml", progression: 0 ... 0.1),
        ])
        let shown = ReadingObservation(locator: place("c0.xhtml", 0.9), viewport: viewport)
        XCTAssertTrue(ReadingRestoration.shows(place("c1.xhtml", 0.05), in: shown))
        XCTAssertTrue(ReadingRestoration.shows(place("c0.xhtml", 0.95), in: shown))
    }

    /// Whatever a restore reports before it settles, only the reader's own moves are saved.
    func testNoScriptedRestoreSavesBeforeTheReaderMoves() {
        let target = place("c0.xhtml", 0.5)
        let noise: [ReadingObservation] = [
            page("c0.xhtml", 0, 0.06), page("c1.xhtml", 0, 0.05), page("c0.xhtml", 0.06, 0.12),
            ReadingObservation(locator: place("c0.xhtml", 0), viewport: nil), page("c0.xhtml", 0.42, 0.48),
        ]
        for (rotation, count) in (0 ..< noise.count).flatMap({ r in (0 ... noise.count).map { (r, $0) } }) {
            let reports = Array(noise[rotation...] + noise[..<rotation])
            for outcome in 0 ..< 3 {
                var restoring = ReadingRestoration(opening: target)
                var attempt = 0
                var actions: [ReadingRestoration.Action] = []
                for report in reports.prefix(count) {
                    let action = restoring.observe(report)
                    if case let .correct(_, n) = action { attempt = n }
                    actions.append(action)
                }
                switch outcome {
                case 0: actions.append(restoring.observe(page("c0.xhtml", 0.48, 0.54)))
                case 1: if attempt > 0 { actions.append(restoring.timedOut(attempt: attempt)) }
                default:
                    if attempt > 0 {
                        actions.append(restoring.timedOut(attempt: attempt))
                        actions.append(restoring.timedOut(attempt: attempt + 1))
                    }
                }
                XCTAssertFalse(actions.contains(.record), "rotation \(rotation), \(count) reports, outcome \(outcome): \(actions)")
            }
        }
    }
}

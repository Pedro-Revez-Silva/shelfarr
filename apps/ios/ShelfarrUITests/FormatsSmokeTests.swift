import Network
import UIKit
import XCTest

/// PDFs and comics in the real app against `RuntimeSmoke/smoke_server.py`, on iPhone and
/// iPad: pages render (checked in the screen's pixels: every fixture page has its own
/// colour), page turns are saved with the time they were reached, rotation, zoom and
/// reopening write nothing, an impossible saved place is kept until a real turn, each
/// format downloads, and a comic reopens and turns offline, then syncs on reconnecting.
///
/// Slow pages are made deterministic with `SHELFARR_UITEST_COMIC_PAGE_DELAYS` (Debug,
/// UI test only): a comic page arriving after the restore timeout, and a spread whose
/// left half decodes before the saved right half, write nothing until the reader turns.
///
/// Fixture files (`build_pdf`, `build_cbz` in apps/scripts/mock_consumer_server.py):
/// `pdf-1` has six pages, `comic-1` ten PNG pages, `multi-1` an EPUB and a PDF. They are
/// listed only because the app declares PDF and CBZ.
final class FormatsSmokeTests: XCTestCase {
    private var port: UInt16 = 0
    private var controlPort: UInt16 = 0
    private var token = ""
    private var userId = ""
    private let wait: TimeInterval = 30

    /// `PAGE_COLOURS` in the mock server, in page order.
    private static let pageColours: [(Int, Int, Int)] = [
        (204, 64, 51), (51, 153, 77), (51, 89, 191), (230, 191, 38), (153, 64, 166),
        (38, 166, 179), (230, 115, 38), (115, 115, 115), (191, 51, 115), (89, 140, 38),
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let port = environment["SHELFARR_SMOKE_PORT"].flatMap(UInt16.init),
              let controlPort = environment["SHELFARR_SMOKE_CONTROL_PORT"].flatMap(UInt16.init)
        else {
            XCTFail("SHELFARR_SMOKE_PORT and SHELFARR_SMOKE_CONTROL_PORT must be set; run apps/scripts/ios-runtime-smoke.sh")
            throw SmokeError.unconfigured
        }
        self.port = port
        self.controlPort = controlPort
        try setOnline(true)
        try freshFixture()
        // A device-flow token from the fixture server; nothing here is a real credential.
        let grant = try json(request(port, "POST", "/api/consumer/v1/auth/device", body: ["client_name": "Shelfarr iOS formats smoke"]))
        let issued = try json(request(port, "POST", "/api/consumer/v1/auth/token", body: ["device_code": grant["device_code"] as? String ?? ""]))
        token = try XCTUnwrap(issued["access_token"] as? String)
        userId = try XCTUnwrap(json(request(port, "GET", "/api/consumer/v1/me", bearer: token))["id"] as? String)
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        if controlPort != 0 { try? setOnline(true) }
    }

    // MARK: PDF

    func testPDFPagesRenderTurnAndReopenWithoutWriting() throws {
        let app = launch(reset: true)
        let book = "pdf-1"
        try open(app, book)

        try step("The first page renders, quiet") {
            XCTAssertTrue(waitForPage(app, 1, of: 6), "the PDF opened at page 1: \(pageLabel(app) ?? "-")")
            XCTAssertTrue(waitFor { self.shownColour(app) == 0 }, "page 1's colour is on screen")
            XCTAssertFalse(app.buttons["Close book"].exists, "no controls until asked for")
            screenshot(app, "30-pdf-page-1")
        }

        try step("The page's external link is not followed") {
            // The fixture's link covers the bottom of page 1; a tap there is a middle tap.
            middleTap(app, y: isPad ? 0.80 : 0.72)
            XCTAssertTrue(app.buttons["Close book"].waitForExistence(timeout: 10), "the tap showed the controls")
            XCTAssertEqual(app.state, .runningForeground, "nothing left the app")
            screenshot(app, "31-pdf-controls")
            middleTap(app)
            XCTAssertTrue(waitForAbsence(app.buttons["Close book"]))
        }

        var turnedAt = Date()
        try step("Swipes and edge taps turn pages") {
            turnedAt = Date()
            reader(app).swipeLeft()
            XCTAssertTrue(waitForPage(app, 2, of: 6))
            XCTAssertTrue(waitFor { self.shownColour(app) == 1 }, "page 2 rendered")
            reader(app).coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            XCTAssertTrue(waitForPage(app, 3, of: 6))
            XCTAssertTrue(waitFor { self.shownColour(app) == 2 }, "page 3 rendered")
            screenshot(app, "32-pdf-page-3")
        }

        try step("Go to page") {
            middleTap(app)
            let pageButton = app.buttons["reader-page"]
            XCTAssertTrue(pageButton.waitForExistence(timeout: wait))
            pageButton.tap()
            // SwiftUI doesn't carry an identifier onto a text field inside an alert (the
            // hosted iOS 18.5 and 26 hierarchies show it without one), so the alert's own
            // field is typed into, by its placeholder.
            let alert = app.alerts["Go to page"]
            XCTAssertTrue(alert.waitForExistence(timeout: wait), "the Go to page alert opened")
            XCTAssertTrue(alert.staticTexts["Pages 1 to 6"].exists, "it names the range")
            let field = alert.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Page")).firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: wait), "the page field")
            field.typeText("5")
            alert.buttons["Go"].tap()
            XCTAssertTrue(waitForAbsence(alert))
            XCTAssertTrue(waitForPage(app, 5, of: 6))
            middleTap(app)
            XCTAssertTrue(waitForAbsence(app.buttons["Close book"]))
            XCTAssertTrue(waitFor { self.shownColour(app) == 4 }, "page 5 rendered")
        }

        var written = 0
        try step("Rotating keeps the page and writes nothing") {
            XCTAssertTrue(waitFor(timeout: 40) { (try? self.progressWrites(book))?.lastPage == 5 }, "the turns reached the server")
            let log = try progressWrites(book)
            written = log.count
            XCTAssertEqual(log.withoutObservedAt, 0)
            XCTAssertEqual(log.lastAsset, "pdf-1")
            XCTAssertEqual(log.lastHref, "document.pdf")
            let observed = try XCTUnwrap(log.lastObservedAt.flatMap(parseTime))
            XCTAssertGreaterThan(observed, turnedAt.addingTimeInterval(-5), "stamped when the page was reached")
            XCTAssertLessThan(observed, Date().addingTimeInterval(5))
            XCUIDevice.shared.orientation = .landscapeLeft
            XCTAssertTrue(waitForPage(app, 5, of: 6), "still page 5 in landscape")
            screenshot(app, "33-pdf-landscape")
            XCUIDevice.shared.orientation = .portrait
            XCTAssertTrue(waitForPage(app, 5, of: 6))
            sleep(7) // longer than the write debounce
            XCTAssertEqual(try progressWrites(book).count, written, "a rotation is not reading")
        }

        try step("Reopening restores page 5 and writes nothing") {
            closeReader(app)
            let saved = try savedPlace(book)
            XCTAssertEqual(saved.page, 5)
            button(app, startingWith: ["Continue reading", "Open book"]).tap()
            XCTAssertTrue(waitForPage(app, 5, of: 6), "the saved page, exactly")
            XCTAssertTrue(waitFor { self.shownColour(app) == 4 }, "page 5 rendered on reopening")
            let log = restoreLog(app)
            XCTAssertTrue(log.contains { $0.hasSuffix("-> settled") }, "\(log)")
            XCTAssertFalse(log.contains { $0.contains("-> record") }, "restoring is not reading: \(log)")
            attachTrace(app, "34-pdf-reopened-trace")
            screenshot(app, "34-pdf-reopened")
            closeReader(app)
            sleep(3)
            XCTAssertEqual(try progressWrites(book).count, written, "reopening wrote nothing")
            XCTAssertEqual(try savedPlace(book), saved, "the server keeps the place and its time")
        }
    }

    func testAnImpossibleSavedPageIsKeptUntilARealTurn() throws {
        // Another device saved page 40 of a six-page PDF (a replaced file, say).
        _ = try request(controlPort, "POST", "/place", json: ["publication": "pdf-1", "asset": "pdf-1", "page": 40])
        let app = launch(reset: true)
        let book = "pdf-1"
        let saved = try savedPlace(book)
        XCTAssertEqual(saved.page, 40)
        try open(app, book)

        try step("The reader asks where to start and keeps the place") {
            let first = app.buttons["invalid-place-first"]
            XCTAssertTrue(first.waitForExistence(timeout: 60), "the saved place this file can't show is explained")
            screenshot(app, "35-pdf-invalid-place")
            first.tap()
            XCTAssertTrue(waitForPage(app, 1, of: 6))
            XCTAssertTrue(waitFor { self.shownColour(app) == 0 })
            closeReader(app)
            sleep(7)
            XCTAssertEqual(try progressWrites(book).count, 0, "looking is not reading")
            XCTAssertEqual(try savedPlace(book), saved, "page 40 is still the saved place")
        }

        try step("A real turn replaces it") {
            button(app, startingWith: ["Continue reading", "Open book"]).tap()
            let last = app.buttons["invalid-place-last"]
            XCTAssertTrue(last.waitForExistence(timeout: 60), "still asked: the place is still saved")
            last.tap()
            XCTAssertTrue(waitForPage(app, 6, of: 6))
            reader(app).swipeRight()
            XCTAssertTrue(waitForPage(app, 5, of: 6))
            closeReader(app)
            XCTAssertTrue(waitFor { (try? self.savedPlace(book))?.page == 5 }, "the turned-to page replaced it")
            XCTAssertEqual(try progressWrites(book).count, 1)
        }
    }

    // MARK: Comics

    func testComicDownloadsReadsOfflineAndSyncsOnReconnecting() throws {
        let app = launch(reset: true)
        let book = "comic-1"
        try step("Downloading the comic") {
            XCTAssertTrue(tab(app, "Library").waitForExistence(timeout: wait))
            tab(app, "Library").tap()
            XCTAssertTrue(scroll(app, to: item(app, book)), "the library lists the comic")
            item(app, book).tap()
            XCTAssertTrue(app.staticTexts["A Test Comic"].waitForExistence(timeout: wait))
            tapDownload(app)
            XCTAssertTrue(app.staticTexts["Downloaded"].waitForExistence(timeout: 90), "the CBZ and its page list are on the device")
            screenshot(app, "40-comic-downloaded")
        }

        try step("Pages render and turn") {
            button(app, startingWith: ["Start reading", "Continue reading", "Open book"]).tap()
            XCTAssertTrue(waitForPage(app, 1, of: 10))
            XCTAssertTrue(waitFor { self.shownColour(app) == 0 }, "page 1's image is on screen")
            screenshot(app, "41-comic-page-1")
            reader(app).swipeLeft()
            XCTAssertTrue(waitForPage(app, 2, of: 10))
            XCTAssertTrue(waitFor { self.shownColour(app) == 1 }, "page 2 decoded from the archive")
        }

        try step("Zooming and turning the direction are not reading") {
            let page = app.descendants(matching: .any)["comic-page-2"].firstMatch
            XCTAssertTrue(page.waitForExistence(timeout: wait))
            page.doubleTap()
            sleep(1)
            page.swipeLeft() // pans the zoomed page
            XCTAssertTrue(waitForPage(app, 2, of: 10), "a drag while zoomed never turns")
            page.doubleTap()
            middleTap(app)
            app.buttons["Page layout"].tap()
            let direction = app.segmentedControls["reading-direction"]
            XCTAssertTrue(direction.waitForExistence(timeout: wait))
            direction.buttons["Right to left"].tap()
            if isPad { setSpreads(app, true) }
            screenshot(app, "42-comic-layout")
            app.buttons["Done"].tap()
            middleTap(app)
            XCTAssertTrue(waitForAbsence(app.buttons["Close book"]))
            XCTAssertTrue(waitForPage(app, 2, of: 10), "a layout change keeps the page")
        }

        if isPad {
            try step("A spread in landscape keeps the page") {
                XCUIDevice.shared.orientation = .landscapeLeft
                XCTAssertTrue(app.descendants(matching: .any)["comic-page-2"].waitForExistence(timeout: wait))
                XCTAssertTrue(waitFor { self.pageLabel(app) == "Page 2 of 10" })
                XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Pages 2 and 3 of 10")).firstMatch.waitForExistence(timeout: wait),
                              "pages 2 and 3 side by side")
                screenshot(app, "43-comic-spread")
                XCUIDevice.shared.orientation = .portrait
                XCTAssertTrue(waitForPage(app, 2, of: 10))
            }
        }

        var written = 0
        try step("Right to left: a swipe to the right is the next page") {
            reader(app).swipeRight()
            XCTAssertTrue(waitForPage(app, 3, of: 10))
            XCTAssertTrue(waitFor { self.shownColour(app) == 2 })
            closeReader(app)
            XCTAssertTrue(waitFor(timeout: 40) { (try? self.progressWrites(book))?.lastPage == 3 })
            let log = try progressWrites(book)
            XCTAssertEqual(log.lastHref, "Issue%201/p3.png", "item 3 of the reading order")
            XCTAssertEqual(log.withoutObservedAt, 0)
            written = log.count
        }

        var offlineTurn = Date()
        try step("Offline: the download reopens at its page and turns") {
            try setOnline(false)
            app.terminate()
            let offline = launch(reset: false)
            tab(offline, "Library").tap()
            XCTAssertTrue(scroll(offline, to: item(offline, book)))
            item(offline, book).tap()
            button(offline, startingWith: ["Continue reading", "Start reading", "Open book"]).tap()
            XCTAssertTrue(waitForPage(offline, 3, of: 10), "the saved page, offline")
            XCTAssertTrue(waitFor { self.shownColour(offline) == 2 }, "page 3 drawn from the local archive")
            XCTAssertFalse(restoreLog(offline).contains { $0.contains("-> record") })
            screenshot(offline, "44-comic-offline")
            offlineTurn = Date()
            reader(offline).swipeRight()
            XCTAssertTrue(waitForPage(offline, 4, of: 10))
            XCTAssertTrue(waitFor { self.shownColour(offline) == 3 })
            closeReader(offline)
            XCTAssertEqual(try progressWrites(book).count, written, "nothing reached the server while offline")
        }

        try step("Reconnecting sends the offline turn with its original time") {
            try setOnline(true)
            let app = XCUIApplication()
            XCUIDevice.shared.press(.home)
            sleep(2)
            app.activate()
            XCTAssertTrue(waitFor(timeout: 40) { (try? self.progressWrites(book))?.lastPage == 4 }, "the place synced")
            let observed = try XCTUnwrap(progressWrites(book).lastObservedAt.flatMap(parseTime))
            XCTAssertLessThan(abs(observed.timeIntervalSince(offlineTurn)), 10, "observed when turned offline, not when sent")
            XCTAssertEqual(try savedPlace(book).page, 4)
        }
    }

    // MARK: Slow pages

    func testSlowFallbackPageAfterTheTimeoutWritesNothingUntilAReadersTurn() throws {
        // Another device saved page 40 of the ten-page comic (a replaced archive, say).
        _ = try request(controlPort, "POST", "/place", json: ["publication": "comic-1", "asset": "cbz-1", "page": 40])
        let book = "comic-1"
        let saved = try savedPlace(book)
        XCTAssertEqual(saved.page, 40)
        let before = try progressWrites(book).count
        // Page 1 decodes after nine seconds: past the five-second restore timeout.
        let app = launch(reset: true, comicPageDelays: "1:9")
        try open(app, book)

        try step("Page 1 arrives after the timeout and writes nothing") {
            let first = app.buttons["invalid-place-first"]
            XCTAssertTrue(first.waitForExistence(timeout: 90), "the saved place this file can't show is explained")
            first.tap()
            XCTAssertTrue(app.descendants(matching: .any)["reader-notice"].waitForExistence(timeout: 12), "the timeout hands input back and says so")
            screenshot(app, "45-comic-slow-page-timeout")
            XCTAssertTrue(waitFor(timeout: 20) { self.shownColour(app) == 0 }, "page 1 drew, late")
            XCTAssertTrue(waitForPage(app, 1, of: 10))
            let log = restoreLog(app)
            XCTAssertTrue(log.contains { $0.contains("open timeout -> gave-up") }, "\(log)")
            XCTAssertTrue(log.contains { $0.hasSuffix("-> settled") }, "the late page settles the restore: \(log)")
            XCTAssertFalse(log.contains { $0.contains("-> record") }, "a late page is not reading: \(log)")
            attachTrace(app, "45-comic-slow-page-trace")
            sleep(7) // longer than the write debounce
            XCTAssertEqual(try progressWrites(book).count, before, "nothing was written")
            XCTAssertEqual(try savedPlace(book), saved, "page 40 is still the saved place, with its time")
        }

        try step("The reader's turn replaces it") {
            let turnedAt = Date()
            middleTap(app)
            let next = app.buttons["Next page"]
            XCTAssertTrue(next.waitForExistence(timeout: wait))
            next.tap()
            XCTAssertTrue(waitForPage(app, 2, of: 10))
            XCTAssertTrue(waitFor { self.shownColour(app) == 1 }, "page 2 drew")
            closeReader(app)
            // This case's own write, not a page an earlier write named.
            XCTAssertTrue(waitFor(timeout: 40) { ((try? self.progressWrites(book))?.count ?? 0) > before }, "the turn reached the server")
            let log = try progressWrites(book)
            XCTAssertEqual(log.count, before + 1, "one write: the turn")
            XCTAssertEqual(log.lastPage, 2)
            let observed = try XCTUnwrap(log.lastObservedAt.flatMap(parseTime))
            XCTAssertGreaterThan(observed, turnedAt.addingTimeInterval(-5), "stamped when page 2 was reached")
            XCTAssertEqual(try savedPlace(book).page, 2)
        }
    }

    func testRotatingIntoASpreadAtAnOddPageWritesNothing() throws {
        guard isPad else { throw XCTSkip("spreads are an iPad landscape layout") }
        _ = try request(controlPort, "POST", "/place", json: ["publication": "comic-1", "asset": "cbz-1", "page": 5])
        let book = "comic-1"
        let saved = try savedPlace(book)
        // Page 5, the right half of spread 4-5, decodes three seconds after page 4.
        let app = launch(reset: true, comicPageDelays: "5:3")
        try open(app, book)
        var before = 0

        try step("Page 5 restores, alone, in portrait") {
            XCTAssertTrue(waitForPage(app, 5, of: 10), "the saved page: \(pageLabel(app) ?? "-")")
            XCTAssertTrue(waitFor(timeout: 40) { self.shownColour(app) == 4 }, "page 5 drew")
            setPageLayout(app, rightToLeft: false, spreads: true)
            XCTAssertTrue(waitForPage(app, 5, of: 10))
            before = try progressWrites(book).count
        }

        try step("Rotating into spread 4-5 draws page 4 first and keeps page 5") {
            XCUIDevice.shared.orientation = .landscapeLeft
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Pages 4 and 5 of 10")).firstMatch.waitForExistence(timeout: wait),
                          "pages 4 and 5 side by side")
            XCTAssertTrue(waitFor(timeout: 20) { self.restoreLog(app).contains { $0.contains("drawn 4-5") } }, "both halves drew")
            screenshot(app, "46-comic-odd-page-spread")
            let log = restoreLog(app)
            XCTAssertTrue(log.contains { $0.contains("pages 4-5 drawn 4-4 -> none") }, "page 4 drew first: \(log)")
            XCTAssertFalse(log.contains { $0.contains("-> record") }, "a layout is not reading: \(log)")
            attachTrace(app, "46-comic-odd-page-spread-trace")
            XCTAssertEqual(pageLabel(app), "Page 5 of 10", "still page 5")
            XCUIDevice.shared.orientation = .portrait
            XCTAssertTrue(waitForPage(app, 5, of: 10), "back to page 5 alone")
            sleep(7) // longer than the write debounce
            XCTAssertEqual(try progressWrites(book).count, before, "rotating wrote nothing")
            XCTAssertEqual(try savedPlace(book), saved, "page 5 keeps its time")
        }

        try step("A real turn in a spread still records") {
            XCUIDevice.shared.orientation = .landscapeLeft
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Pages 4 and 5 of 10")).firstMatch.waitForExistence(timeout: wait))
            reader(app).swipeLeft()
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Pages 6 and 7 of 10")).firstMatch.waitForExistence(timeout: wait))
            XCTAssertTrue(waitFor { self.restoreLog(app).contains { $0.contains("-> record 6") } }, "\(restoreLog(app))")
            XCUIDevice.shared.orientation = .portrait
            XCTAssertTrue(waitForPage(app, 6, of: 10))
            // Back to the default layout, which is not reading either.
            setPageLayout(app, rightToLeft: false, spreads: false)
            closeReader(app)
            XCTAssertTrue(waitFor(timeout: 40) { (try? self.progressWrites(book))?.lastPage == 6 }, "the turn reached the server")
            sleep(7)
            XCTAssertEqual(try progressWrites(book).count, before + 1, "one write: the turn")
        }
    }

    // MARK: Several formats

    func testAChoiceOfFormatAndAnOfflineAlternative() throws {
        let app = launch(reset: true)
        let book = "multi-1"
        try step("With two formats and no place, the reader asks") {
            try openDetails(app, book)
            button(app, startingWith: ["Start reading"]).tap()
            let epub = app.buttons["format-choice-epub"]
            XCTAssertTrue(epub.waitForExistence(timeout: 60), "asked which format")
            XCTAssertTrue(app.buttons["format-choice-pdf"].exists)
            screenshot(app, "50-format-choice")
            // The EPUB, so the PDF has no reading copy on this device for the offline step.
            epub.tap()
            XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 60), "Readium opened the EPUB")
            sleep(2)
            closeReader(app)
            sleep(3)
            XCTAssertEqual(try progressWrites(book).count, 0, "choosing a format is not reading")
        }

        try step("Download asks which format") {
            tapDownload(app)
            let epub = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "EPUB")).firstMatch
            XCTAssertTrue(epub.waitForExistence(timeout: wait), "the format choice for downloading")
            screenshot(app, "51-download-format")
            epub.tap()
            XCTAssertTrue(app.staticTexts["Downloaded"].waitForExistence(timeout: 90))
        }

        try step("Offline, a place in the PDF offers the downloaded EPUB") {
            // Another device reads the PDF; the app sees it online, then loses the server.
            _ = try request(controlPort, "POST", "/place", json: ["publication": book, "asset": "pdf-m", "page": 3])
            app.navigationBars.buttons.firstMatch.tap()
            try openDetails(app, book)
            let saved = try savedPlace(book)
            try setOnline(false)
            app.terminate()
            let offline = launch(reset: false)
            try openDetails(offline, book)
            button(offline, startingWith: ["Continue reading", "Start reading"]).tap()
            let alternative = offline.buttons["format-alternative-epub"]
            XCTAssertTrue(alternative.waitForExistence(timeout: 60), "the downloaded EPUB is offered instead of a dead end")
            screenshot(offline, "52-format-offline-alternative")
            alternative.tap()
            XCTAssertTrue(offline.webViews.firstMatch.waitForExistence(timeout: 60), "the downloaded EPUB opened")
            XCTAssertTrue(offline.descendants(matching: .any)["reader-notice"].waitForExistence(timeout: wait), "it says the place stays in the PDF")
            screenshot(offline, "53-format-offline-epub")
            sleep(2)
            closeReader(offline)
            try setOnline(true)
            XCUIDevice.shared.press(.home)
            sleep(2)
            offline.activate()
            sleep(7)
            XCTAssertEqual(try progressWrites(book).count, 0, "opening another format wrote nothing")
            XCTAssertEqual(try savedPlace(book), saved, "the place stays in the PDF")
        }
    }

    // MARK: App helpers

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// `comicPageDelays`: `page:seconds` pairs a comic's pages wait before decoding.
    private func launch(reset: Bool, comicPageDelays: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-shelfarr-ui-test"] + (reset ? ["-shelfarr-ui-test-reset"] : [])
        app.launchEnvironment = [
            "SHELFARR_UITEST_SERVER": "http://localhost:\(port)",
            "SHELFARR_UITEST_TOKEN": token,
            "SHELFARR_UITEST_USER_ID": userId,
            "SHELFARR_UITEST_USER_NAME": "Mock Reader",
        ]
        if let comicPageDelays { app.launchEnvironment["SHELFARR_UITEST_COMIC_PAGE_DELAYS"] = comicPageDelays }
        app.launch()
        return app
    }

    /// Page layout choices are remembered on the device across launches: set them.
    private func setPageLayout(_ app: XCUIApplication, rightToLeft: Bool, spreads: Bool) {
        middleTap(app)
        let layoutButton = app.buttons["Page layout"]
        XCTAssertTrue(layoutButton.waitForExistence(timeout: wait))
        layoutButton.tap()
        let direction = app.segmentedControls["reading-direction"]
        XCTAssertTrue(direction.waitForExistence(timeout: wait))
        direction.buttons[rightToLeft ? "Right to left" : "Left to right"].tap()
        if isPad { setSpreads(app, spreads) }
        app.buttons["Done"].tap()
        middleTap(app)
        XCTAssertTrue(waitForAbsence(app.buttons["Close book"]))
    }

    /// The page layout sheet's spreads switch, set through the control. On iPad the
    /// choice must be offered; a SwiftUI form toggle spans its row, so the tap goes to the
    /// switch itself, and the new value is read back.
    private func setSpreads(_ app: XCUIApplication, _ on: Bool) {
        let toggle = app.switches["Two pages side by side"]
        XCTAssertTrue(toggle.waitForExistence(timeout: wait), "iPad offers two pages side by side")
        // The sheet opens at medium height on iPad; the choice may be below its fold.
        for _ in 0 ..< 3 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.isHittable, "the spreads switch scrolled into view")
        if isOn(toggle) != on {
            let control = toggle.switches.firstMatch
            if control.exists {
                control.tap()
            } else {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            }
        }
        XCTAssertTrue(waitFor(timeout: 5) { self.isOn(toggle) == on }, "two pages side by side \(on ? "on" : "off"): \(String(describing: toggle.value))")
    }

    private func isOn(_ toggle: XCUIElement) -> Bool {
        (toggle.value as? String) == "1"
    }

    private func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let bar = app.tabBars.buttons[name]
        return bar.exists ? bar : app.buttons.matching(identifier: name).firstMatch
    }

    private func item(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)["library-item-\(id)"].firstMatch
    }

    private func openDetails(_ app: XCUIApplication, _ book: String) throws {
        if !item(app, book).exists {
            XCTAssertTrue(tab(app, "Library").waitForExistence(timeout: wait))
            tab(app, "Library").tap()
        }
        XCTAssertTrue(scroll(app, to: item(app, book)), "the library lists \(book)")
        item(app, book).tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@", "Start reading", "Continue reading", "Open book")).firstMatch.waitForExistence(timeout: wait))
    }

    private func open(_ app: XCUIApplication, _ book: String) throws {
        try openDetails(app, book)
        button(app, startingWith: ["Start reading", "Continue reading", "Open book"]).tap()
    }

    private func button(_ app: XCUIApplication, startingWith labels: [String]) -> XCUIElement {
        let predicate = NSCompoundPredicate(orPredicateWithSubpredicates: labels.map { NSPredicate(format: "label BEGINSWITH %@", $0) })
        let found = app.buttons.matching(predicate).firstMatch
        XCTAssertTrue(found.waitForExistence(timeout: wait), "a button labelled \(labels)")
        return found
    }

    private func tapDownload(_ app: XCUIApplication) {
        let download = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Download")).firstMatch
        if !download.waitForExistence(timeout: wait) { app.swipeUp() }
        XCTAssertTrue(download.waitForExistence(timeout: wait), "the Download button")
        if !download.isHittable { app.swipeUp() }
        download.tap()
    }

    private func reader(_ app: XCUIApplication) -> XCUIElement {
        let element = app.descendants(matching: .any)["page-reader"].firstMatch
        return element.exists ? element : app.windows.firstMatch
    }

    private func middleTap(_ app: XCUIApplication, y: CGFloat = 0.5) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y)).tap()
    }

    private func closeReader(_ app: XCUIApplication) {
        let close = app.buttons["Close book"]
        for _ in 0 ..< 3 where !close.exists {
            middleTap(app)
            _ = close.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(close.exists, "the reader's controls open")
        close.tap()
    }

    /// "Page N of M", from the folio or the page button.
    private func pageLabel(_ app: XCUIApplication) -> String? {
        let element = app.descendants(matching: .any)["reader-page"].firstMatch
        return element.exists ? element.label : nil
    }

    private func waitForPage(_ app: XCUIApplication, _ page: Int, of count: Int) -> Bool {
        waitFor { self.pageLabel(app) == "Page \(page) of \(count)" }
    }

    /// Which fixture page colour is on screen, read from the pixels in the upper part of
    /// the page (clear of the "Page N" text and the comic's dark band).
    private func shownColour(_ app: XCUIApplication) -> Int? {
        guard let image = app.screenshot().image.cgImage else { return nil }
        var votes: [Int: Int] = [:]
        for (x, y) in [(0.5, 0.33), (0.4, 0.36), (0.6, 0.36), (0.5, 0.39)] {
            guard let (r, g, b) = pixel(image, x, y) else { continue }
            let distances = Self.pageColours.enumerated().map { index, colour in
                (index, (r - colour.0) * (r - colour.0) + (g - colour.1) * (g - colour.1) + (b - colour.2) * (b - colour.2))
            }
            if let best = distances.min(by: { $0.1 < $1.1 }), best.1 < 3 * 45 * 45 { votes[best.0, default: 0] += 1 }
        }
        return votes.max { $0.value < $1.value }.flatMap { $0.value >= 3 ? $0.key : nil }
    }

    private func pixel(_ image: CGImage, _ fx: Double, _ fy: Double) -> (Int, Int, Int)? {
        let x = Int(Double(image.width) * fx), y = Int(Double(image.height) * fy)
        var data = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    private func restoreLog(_ app: XCUIApplication) -> [String] {
        let element = app.descendants(matching: .any)["reader-restore-trace"].firstMatch
        guard element.exists else { return [] }
        let lines = element.label.components(separatedBy: "\n")
        guard let start = lines.lastIndex(where: { $0.hasPrefix("open ") }) else { return lines }
        return Array(lines[start...])
    }

    private func attachTrace(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(string: restoreLog(app).joined(separator: "\n"))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The library is sorted by recent activity, so a book another device just read moves
    /// to the top while the list may still be scrolled down: look down, then back up.
    private func scroll(_ app: XCUIApplication, to element: XCUIElement) -> Bool {
        if element.waitForExistence(timeout: 10) { return true }
        for _ in 0 ..< 12 {
            if element.exists { return true }
            app.swipeUp(velocity: .fast)
        }
        for _ in 0 ..< 16 {
            if element.exists { return true }
            app.swipeDown(velocity: .fast)
        }
        return element.waitForExistence(timeout: 5)
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        waitFor(timeout: timeout) { !element.exists }
    }

    private func waitFor(timeout: TimeInterval = 30, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    private func parseTime(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func step(_ name: String, _ body: () throws -> Void) throws {
        try XCTContext.runActivity(named: name) { _ in try body() }
    }

    // MARK: Fixture server

    private enum SmokeError: Error { case unconfigured, timeout, http(Int), malformed }

    /// The server's saved place: which write it came from, and its page.
    private struct SavedPlace: Equatable {
        let version: Int?
        let mutationId: String?
        let observedAt: String?
        let page: Int?
    }

    private func savedPlace(_ publication: String) throws -> SavedPlace {
        let body = try json(request(port, "GET", "/api/consumer/v1/library/\(publication)/progress", bearer: token))
        let progress = try XCTUnwrap(body["progress"] as? [String: Any], "the server has a saved place")
        let locations = (progress["locator"] as? [String: Any])?["locations"] as? [String: Any]
        return SavedPlace(
            version: progress["version"] as? Int,
            mutationId: progress["client_mutation_id"] as? String,
            observedAt: progress["observed_at"] as? String,
            page: locations?["position"] as? Int
        )
    }

    private struct ProgressWrites {
        let count: Int
        let withoutObservedAt: Int
        let lastObservedAt: String?
        let lastPage: Int?
        let lastAsset: String?
        let lastHref: String?
    }

    private func progressWrites(_ publication: String) throws -> ProgressWrites {
        let stats = try json(request(controlPort, "GET", "/stats"))
        let log = (stats["progress_writes"] as? [String: Any])?[publication] as? [String: Any]
        let last = log?["last"] as? [String: Any]
        return ProgressWrites(
            count: log?["count"] as? Int ?? 0,
            withoutObservedAt: log?["without_observed_at"] as? Int ?? 0,
            lastObservedAt: last?["observed_at"] as? String,
            lastPage: last?["page"] as? Int,
            lastAsset: last?["asset_id"] as? String,
            lastHref: last?["href"] as? String
        )
    }

    private func setOnline(_ online: Bool) throws {
        _ = try request(controlPort, "POST", online ? "/online" : "/offline")
    }

    /// Each case starts from the fixture as the server started: no places, writes,
    /// activity or counters from an earlier case (XCTest runs them in one server, by name).
    /// The previous case's app is stopped first, so nothing it still sends lands in this
    /// case's record. Within the case, places persist across relaunches and offline.
    private func freshFixture() throws {
        XCUIApplication().terminate()
        _ = try request(controlPort, "POST", "/reset")
    }

    /// Plain HTTP/1.1 over TCP; ATS doesn't govern Network framework connections.
    private func request(_ port: UInt16, _ method: String, _ path: String, body: [String: String]? = nil, json object: [String: Any]? = nil, bearer: String? = nil) throws -> Data {
        let payload: Data
        if let object {
            payload = try JSONSerialization.data(withJSONObject: object)
        } else {
            payload = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        }
        var head = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\nContent-Length: \(payload.count)\r\n"
        if body != nil || object != nil { head += "Content-Type: application/json\r\n" }
        if let bearer { head += "Authorization: Bearer \(bearer)\r\n" }
        let message = Data((head + "\r\n").utf8) + payload

        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let queue = DispatchQueue(label: "org.shelfarr.smoke.formats.http")
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var received = Data()
        var failure: Error?
        func finish(_ error: Error?) {
            lock.withLock { if failure == nil { failure = error } }
            done.signal()
        }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, complete, error in
                if let data { lock.withLock { received.append(data) } }
                if let error { finish(error) } else if complete { finish(nil) } else { receive() }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: message, completion: .contentProcessed { error in
                    if let error { finish(error) } else { receive() }
                })
            case let .failed(error), let .waiting(error):
                finish(error)
            default:
                break
            }
        }
        connection.start(queue: queue)
        defer { connection.cancel() }
        guard done.wait(timeout: .now() + 15) == .success else { throw SmokeError.timeout }
        if let failure = lock.withLock({ failure }) { throw failure }
        let response = lock.withLock { received }
        guard let split = response.range(of: Data("\r\n\r\n".utf8)),
              let status = String(data: response[..<split.lowerBound], encoding: .utf8)?
              .split(separator: " ").dropFirst().first.flatMap({ Int($0) })
        else { throw SmokeError.malformed }
        guard (200 ..< 300).contains(status) else { throw SmokeError.http(status) }
        return response[split.upperBound...]
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(data)) as? [String: Any])
    }
}

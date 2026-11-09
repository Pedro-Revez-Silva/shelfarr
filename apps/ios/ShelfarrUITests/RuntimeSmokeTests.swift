import Network
import UIKit
import XCTest

/// Drives the real app on a simulator against `RuntimeSmoke/smoke_server.py`: library
/// and search, details, a rendered EPUB, downloads through the background session, a
/// local audiobook, reopening everything with the server unreachable (a cold, offline
/// restore of a place inside a chapter that writes nothing), the activity time sent with
/// reading progress, a silent reopen, and the audiobook resume rewind. It runs on iPhone
/// and iPad simulators alike.
///
/// It needs `SHELFARR_SMOKE_PORT` and `SHELFARR_SMOKE_CONTROL_PORT` in the test runner's
/// environment (`TEST_RUNNER_` prefixed for xcodebuild); `apps/scripts/ios-runtime-smoke.sh`
/// sets them. Without them it fails rather than passing vacuously.
final class RuntimeSmokeTests: XCTestCase {
    private var port: UInt16 = 0
    private var controlPort: UInt16 = 0
    private var token = ""
    private var userId = ""
    private let wait: TimeInterval = 30

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
        // A real device-flow token from the fixture server; nothing here is a real credential.
        let grant = try json(request(port, "POST", "/api/consumer/v1/auth/device", body: ["client_name": "Shelfarr iOS smoke"]))
        let issued = try json(request(port, "POST", "/api/consumer/v1/auth/token", body: ["device_code": grant["device_code"] as? String ?? ""]))
        token = try XCTUnwrap(issued["access_token"] as? String)
        let me = try json(request(port, "GET", "/api/consumer/v1/me", bearer: token))
        userId = try XCTUnwrap(me["id"] as? String)
    }

    override func tearDownWithError() throws {
        if controlPort != 0 { try? setOnline(true) }
    }

    func testLibraryReaderDownloadsAndOfflineReopening() throws {
        let app = launch(reset: true)

        try step("Home and library") {
            XCTAssertTrue(tab(app, "Library").waitForExistence(timeout: wait), "the signed-in app shows its tabs")
            screenshot(app, "01-home")
            tab(app, "Library").tap()
            XCTAssertTrue(item(app, "book-1").waitForExistence(timeout: wait), "the library lists the fixture book")
            XCTAssertTrue(item(app, "audio-1").exists)
            screenshot(app, "02-library")
            // Load the second page online, so offline browsing has more than one page saved.
            XCTAssertTrue(scroll(app, to: item(app, "book-x34")), "the second library page loads")
            app.swipeDown(velocity: .fast)
            app.swipeDown(velocity: .fast)
            search(app, "Audiobook")
            XCTAssertTrue(item(app, "audio-1").waitForExistence(timeout: wait))
            XCTAssertTrue(waitForAbsence(item(app, "book-1")), "search narrows the server listing")
            clearSearch(app)
        }

        var place = ""
        var saved: SavedProgress?
        try step("Details, download and EPUB rendering") {
            XCTAssertTrue(item(app, "book-1").waitForExistence(timeout: wait))
            item(app, "book-1").tap()
            XCTAssertTrue(app.staticTexts["A Test Book"].waitForExistence(timeout: wait))
            screenshot(app, "03-details")
            tapDownload(app)
            XCTAssertTrue(app.staticTexts["Downloaded"].waitForExistence(timeout: 90), "the EPUB download completes")
            let stats = try json(request(controlPort, "GET", "/stats"))
            XCTAssertGreaterThan(stats["grant_requests"] as? Int ?? 0, 0, "the download ran on an asset grant in the background session")
            XCTAssertEqual(stats["grant_requests_with_bearer"] as? Int, 0, "no background request carried the bearer")
            screenshot(app, "04-downloaded")

            button(app, startingWith: ["Start reading", "Continue reading", "Open book"]).tap()
            XCTAssertTrue(bookText(app).waitForExistence(timeout: 60), "Readium rendered the chapter text")
            screenshot(app, "05-reader")
            let page = app.webViews.firstMatch
            page.swipeLeft()
            page.swipeLeft()
            sleep(2)
            turnPastAChapterStart(app)
            place = progress(app)
            XCTAssertNotEqual(place, "0%", "turning pages moved the reading position")
            attachTrace(app, "06-reader-turned-trace")
            screenshot(app, "06-reader-turned")
            closeReader(app)
            XCTAssertTrue(waitFor { (try? self.progressWrites("book-1"))?.count ?? 0 > 0 }, "closing the reader sent its place")
        }

        try step("Audiobook downloads while the app is in the background") {
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(item(app, "audio-1").waitForExistence(timeout: wait))
            item(app, "audio-1").tap()
            XCTAssertTrue(app.staticTexts["A Test Audiobook"].waitForExistence(timeout: wait))
            tapDownload(app)
            XCUIDevice.shared.press(.home)
            sleep(5)
            app.activate()
            XCTAssertTrue(app.staticTexts["Downloaded"].waitForExistence(timeout: 120), "every track is on the device")
            screenshot(app, "07-audiobook-downloaded")
            button(app, startingWith: ["Start listening", "Continue listening", "Play audiobook"]).tap()
            XCTAssertTrue(app.staticTexts["Playing the download on this device"].waitForExistence(timeout: wait), "audio uses the local files")
            let position = app.sliders["Position"]
            XCTAssertTrue(position.waitForExistence(timeout: wait))
            XCTAssertTrue(waitFor { (position.value as? String)?.hasSuffix("of 0:45") == true }, "the local track's duration loaded: \(position.value ?? "")")
            screenshot(app, "08-player")
            press(app, "Close player")
        }

        try step("Offline relaunch") {
            saved = try savedProgress("book-1")
            try setOnline(false)
            app.terminate()
            let offline = launch(reset: false)
            XCTAssertTrue(offline.staticTexts["Offline. Showing downloads on this device."].waitForExistence(timeout: wait))
            screenshot(offline, "09-home-offline")

            tab(offline, "Library").tap()
            XCTAssertTrue(offline.otherElements["library-offline-banner"].waitForExistence(timeout: wait), "the library says it shows saved titles")
            XCTAssertTrue(item(offline, "book-1").waitForExistence(timeout: wait))
            XCTAssertTrue(item(offline, "audio-1").exists)
            screenshot(offline, "10-library-offline")
            search(offline, "Mock Book 034")
            XCTAssertTrue(item(offline, "book-x34").waitForExistence(timeout: wait), "offline search finds a title saved from the second page")
            XCTAssertTrue(waitForAbsence(item(offline, "book-1")))
            clearSearch(offline)

            XCTAssertTrue(item(offline, "book-1").waitForExistence(timeout: wait))
            item(offline, "book-1").tap()
            XCTAssertTrue(offline.staticTexts["Offline. Opening the download on this device."].waitForExistence(timeout: wait))
            XCTAssertTrue(offline.staticTexts["Connect to your server to change the status."].exists, "status changes still need the server")
            screenshot(offline, "11-details-offline")
            button(offline, startingWith: ["Continue reading", "Start reading", "Open book"]).tap()
            XCTAssertTrue(bookText(offline).waitForExistence(timeout: 60), "the downloaded EPUB renders offline")
            expectRestored(offline, place, "12-reader-offline")
            closeReader(offline)
        }

        try step("Reconnecting sends nothing for the restored place") {
            let app = XCUIApplication()
            let writes = try progressWrites("book-1").count
            try setOnline(true)
            // Coming to the foreground retries every unsynced place at once.
            XCUIDevice.shared.press(.home)
            sleep(2)
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: wait))
            XCTAssertFalse(waitFor(timeout: 10) { (try? self.progressWrites("book-1"))?.count ?? 0 > writes },
                           "opening at the saved place offline queued no new activity")
            XCTAssertEqual(try savedProgress("book-1"), saved, "the server keeps the place and time last read")
        }
    }

    /// Reading sends the time each page was reached; reopening at the saved page and
    /// closing again is not reading, so nothing more is written.
    func testReaderSendsActivityTimeAndReopensSilently() throws {
        let app = launch(reset: true)
        let book = "book-x1"
        var place = ""
        var written = 0

        try step("Reading records when the page was reached") {
            XCTAssertTrue(tab(app, "Library").waitForExistence(timeout: wait))
            tab(app, "Library").tap()
            XCTAssertTrue(item(app, book).waitForExistence(timeout: wait))
            item(app, book).tap()
            button(app, startingWith: ["Start reading", "Continue reading", "Open book"]).tap()
            XCTAssertTrue(bookText(app).waitForExistence(timeout: 60), "Readium rendered the chapter text")
            let page = app.webViews.firstMatch
            let before = Date()
            page.swipeLeft()
            page.swipeLeft()
            sleep(2)
            turnPastAChapterStart(app)
            place = progress(app)
            closeReader(app)
            XCTAssertTrue(waitFor { (try? self.progressWrites(book))?.count ?? 0 > 0 }, "closing the reader sent its place")
            let log = try progressWrites(book)
            written = log.count
            XCTAssertEqual(log.withoutObservedAt, 0, "every write carries observed_at")
            XCTAssertEqual(log.resolving, 0, "only an explicit choice sends resolve_conflict")
            let observed = try XCTUnwrap(log.lastObservedAt.flatMap(parseTime), "observed_at is a zoned ISO-8601 time: \(log.lastObservedAt ?? "-")")
            XCTAssertGreaterThan(observed, before.addingTimeInterval(-5), "stamped when the page was reached")
            XCTAssertLessThan(observed, Date().addingTimeInterval(5), "and never in the future")
            screenshot(app, "13-reader-activity-time")
        }

        try step("Reopening the saved page writes nothing") {
            button(app, startingWith: ["Continue reading", "Start reading", "Open book"]).tap()
            XCTAssertTrue(bookText(app).waitForExistence(timeout: 60))
            expectRestored(app, place, "14-reader-reopened-trace")
            closeReader(app)
            sleep(3)
            XCTAssertEqual(try progressWrites(book).count, written, "restoring a place is not new reading")
            screenshot(app, "14-reader-reopened")
        }
    }

    /// A paused restart replays five seconds once and keeps the paused place saved; a
    /// deliberate move plays from exactly where it was put.
    func testAudiobookResumeRewindsOnceAndKeepsTheSavedPlace() throws {
        let app = launch(reset: true)
        let book = "audio-1"
        XCTAssertTrue(tab(app, "Library").waitForExistence(timeout: wait))
        tab(app, "Library").tap()
        XCTAssertTrue(item(app, book).waitForExistence(timeout: wait))
        item(app, book).tap()
        button(app, startingWith: ["Start listening", "Continue listening", "Play audiobook"]).tap()
        let slider = app.sliders["Position"]
        XCTAssertTrue(slider.waitForExistence(timeout: wait))
        XCTAssertTrue(waitFor { (slider.value as? String)?.hasSuffix("of 0:45") == true }, "the streamed track's duration loaded")
        guard toggle(app, "Pause").waitForExistence(timeout: 15) else {
            screenshot(app, "15-player-not-playing")
            throw XCTSkip("The simulator did not start audio playback, so the rewind cannot be observed here")
        }

        var paused = 0.0
        try step("Pausing after a deliberate move saves that place at once") {
            press(app, "Forward 30 seconds")
            toggle(app, "Pause").tap()
            XCTAssertTrue(toggle(app, "Play").waitForExistence(timeout: wait))
            paused = try XCTUnwrap(elapsed(slider))
            XCTAssertGreaterThanOrEqual(paused, 29, "skipping forward is not rewound")
            XCTAssertTrue(waitFor {
                guard let saved = try? self.savedSeconds(book) else { return false }
                return abs(saved - paused) <= 1.5
            }, "the pause checkpoint reached the server")
            let log = try progressWrites(book)
            XCTAssertEqual(log.withoutObservedAt, 0)
            XCTAssertEqual(log.resolving, 0)
            screenshot(app, "15-player-paused")
        }

        try step("Playing again replays five seconds, once") {
            toggle(app, "Play").tap()
            let restarted = try XCTUnwrap(elapsed(slider))
            XCTAssertTrue((paused - 6.5 ... paused - 2.5).contains(restarted), "resumed at \(restarted) after pausing at \(paused)")
            toggle(app, "Pause").tap()
            XCTAssertTrue(toggle(app, "Play").waitForExistence(timeout: wait))
            sleep(2)
            let saved = try savedSeconds(book)
            XCTAssertLessThanOrEqual(abs(saved - paused), 1.5, "pausing in the replayed seconds keeps the original place: \(saved) vs \(paused)")
            screenshot(app, "16-player-rewound")
        }

        try step("A deliberate move while paused is not rewound") {
            press(app, "Back 15 seconds")
            let chosen = try XCTUnwrap(elapsed(slider))
            toggle(app, "Play").tap()
            let playing = try XCTUnwrap(elapsed(slider))
            XCTAssertGreaterThanOrEqual(playing, chosen - 1, "played from the chosen place: \(playing) vs \(chosen)")
            toggle(app, "Pause").tap()
            press(app, "Close player")
        }
    }

    // MARK: App

    /// Find → allow requesting through the real browser approval → search → choose a
    /// format → request (with repeated taps) → follow it → listen. The fixture server
    /// approves in the browser by itself and moves the request one stage per poll;
    /// nothing is searched for, bought or acquired.
    func testFindRequestFollowAndOpen() throws {
        let app = launch(reset: true)

        try step("A read-only connection asks first") {
            XCTAssertTrue(tab(app, "Find").waitForExistence(timeout: wait))
            tab(app, "Find").tap()
            let allow = app.buttons["find-explainer-action"]
            XCTAssertTrue(allow.waitForExistence(timeout: wait), "Find explains requesting before anything else")
            XCTAssertEqual(allow.label, "Allow requesting")
            screenshot(app, "20-find-allow-requesting")
            allow.tap()
            // The approval page opens in the browser; the fixture approves it.
            app.activate()
            XCTAssertTrue(app.textFields["find-query"].waitForExistence(timeout: 60), "approval adds requesting to this connection in place")
            screenshot(app, "21-find-allowed")
        }

        try step("Find, choose a format and request it once") {
            let field = app.textFields["find-query"]
            field.tap()
            field.typeText("lighthouse\n")
            let result = app.buttons["result:mock:work-lighthouse"]
            XCTAssertTrue(result.waitForExistence(timeout: wait))
            screenshot(app, "22-find-results")
            result.tap()
            app.buttons["format:audiobook"].tap()
            let submit = app.buttons["request-submit"]
            XCTAssertTrue(submit.waitForExistence(timeout: wait))
            screenshot(app, "23-find-choose-format")
            submit.tap()
            if submit.exists && submit.isHittable { submit.tap() }
            XCTAssertTrue(app.descendants(matching: .any)["request-stage"].waitForExistence(timeout: wait))
        }

        try step("Follow it until it can be opened") {
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Downloading")).firstMatch.waitForExistence(timeout: 90))
            screenshot(app, "24-request-downloading")
            let listen = app.buttons["request-open"]
            XCTAssertTrue(listen.waitForExistence(timeout: 90), "the request becomes ready")
            XCTAssertEqual(listen.label, "Listen now")
            screenshot(app, "25-request-ready")
            listen.tap()
            XCTAssertTrue(toggle(app, "Pause").waitForExistence(timeout: wait) || toggle(app, "Play").waitForExistence(timeout: wait), "the acquired audiobook opens in the player")
            screenshot(app, "26-request-opened")
            press(app, "Close player")
        }

        try step("The request is listed once, as ready") {
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.buttons["request:r1"].waitForExistence(timeout: wait))
            XCTAssertFalse(app.buttons["request:r2"].exists, "repeated taps made one request")
        }
    }

    private func launch(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-shelfarr-ui-test"] + (reset ? ["-shelfarr-ui-test-reset"] : [])
        app.launchEnvironment = [
            // localhost: the Debug build's local-networking exception covers it.
            "SHELFARR_UITEST_SERVER": "http://localhost:\(port)",
            "SHELFARR_UITEST_TOKEN": token,
            "SHELFARR_UITEST_USER_ID": userId,
            "SHELFARR_UITEST_USER_NAME": "Mock Reader",
        ]
        app.launch()
        return app
    }

    /// A tab: in the bottom bar on iPhone, and in the top bar or sidebar on iPad.
    private func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let bar = app.tabBars.buttons[name]
        return bar.exists ? bar : app.buttons.matching(identifier: name).firstMatch
    }

    private func item(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)["library-item-\(id)"].firstMatch
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

    /// Prose from each chapter of the fixture EPUB (`build_epub` in
    /// apps/scripts/mock_consumer_server.py): a restored place can be in any of them.
    private static let chapterProse = [
        "The rain had stopped by the time she reached the harbour.",
        "Nothing in the valley was quite where the old maps put it.",
        "By the third evening the house had begun to feel familiar.",
    ]

    private func bookText(_ app: XCUIApplication) -> XCUIElement {
        let prose = NSCompoundPredicate(orPredicateWithSubpredicates: Self.chapterProse.map {
            NSPredicate(format: "label CONTAINS %@", $0)
        })
        return app.webViews.staticTexts.matching(prose).firstMatch
    }

    /// The saved place is back on screen, restored rather than read: the shown position
    /// reaches it, and since opening nothing was recorded as reading. The navigator may
    /// report a wrong page first and be sent back, so this waits for the restore to finish;
    /// the app gives up after two bounded attempts.
    private func expectRestored(_ app: XCUIApplication, _ place: String, _ name: String) {
        let restoring = waitFor(timeout: 25) {
            self.restoreLog(app).contains { $0.hasSuffix("-> settled") } && self.close(self.shownProgress(app) ?? "", place)
        }
        attachTrace(app, name)
        screenshot(app, name)
        let log = restoreLog(app)
        XCTAssertTrue(restoring, "the reading place was restored: \(progress(app)) vs \(place)")
        XCTAssertFalse(log.contains { $0.hasSuffix("-> record") }, "restoring a place is not reading: \(log)")
        XCTAssertFalse(log.contains { $0.hasSuffix("-> gave-up") }, "the saved place showed: \(log)")
    }

    /// Turns on while the reader is at the very start of a chapter, so the saved place is
    /// inside one, which a cold open has to lay out before it can show.
    private func turnPastAChapterStart(_ app: XCUIApplication) {
        for _ in 0 ..< 3 where (lastReportedProgression(app) ?? 0) <= 0 {
            app.webViews.firstMatch.swipeLeft()
            sleep(2)
        }
        XCTAssertGreaterThan(lastReportedProgression(app) ?? 0, 0, "the saved place is inside a chapter: \(restoreLog(app))")
    }

    /// The fixture-only restore trace the Debug reader exposes under the UI test argument.
    private func restoreTrace(_ app: XCUIApplication) -> [String] {
        let element = app.descendants(matching: .any)["reader-restore-trace"].firstMatch
        guard element.exists else { return [] }
        return element.label.components(separatedBy: "\n")
    }

    /// Trace lines since the reader last opened a place.
    private func restoreLog(_ app: XCUIApplication) -> [String] {
        let lines = restoreTrace(app)
        guard let start = lines.lastIndex(where: { $0.hasPrefix("open ") }) else { return lines }
        return Array(lines[start...])
    }

    /// The progression inside its chapter of the navigator's latest report.
    private func lastReportedProgression(_ app: XCUIApplication) -> Double? {
        guard let line = restoreTrace(app).last(where: { $0.hasPrefix("report ") }),
              let at = line.split(separator: " ").dropFirst().first?.split(separator: "@").last
        else { return nil }
        return Double(at)
    }

    private func attachTrace(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(string: restoreTrace(app).joined(separator: "\n"))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func progress(_ app: XCUIApplication) -> String {
        let label = app.staticTexts["reader-progress"]
        XCTAssertTrue(label.waitForExistence(timeout: wait), "the reader shows its position")
        return label.label
    }

    /// The position shown right now, without waiting for it.
    private func shownProgress(_ app: XCUIApplication) -> String? {
        let label = app.staticTexts["reader-progress"]
        return label.exists ? label.label : nil
    }

    private func close(_ a: String, _ b: String) -> Bool {
        guard let x = Int(a.dropLast()), let y = Int(b.dropLast()) else { return false }
        return abs(x - y) <= 1
    }

    private func closeReader(_ app: XCUIApplication) {
        let close = app.buttons["Close book"]
        for _ in 0 ..< 3 where !close.exists {
            app.webViews.firstMatch.tap()
            _ = close.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(close.exists, "the reader's chrome opens")
        close.tap()
    }

    private func search(_ app: XCUIApplication, _ text: String) {
        let field = app.searchFields.firstMatch
        if !field.waitForExistence(timeout: 5) { app.swipeDown() }
        XCTAssertTrue(field.waitForExistence(timeout: wait), "the library search field")
        field.tap()
        field.typeText(text)
        XCTAssertEqual(searchText(field), text, "the library search field took the query")
    }

    /// Empties the library search and leaves search mode, failing if either doesn't happen.
    ///
    /// The search bar changed on iOS 26: its "Cancel" text button became a round
    /// xmark button labelled "Close" (CI accessibility snapshot, iPhone 17 Pro, iOS 26.5),
    /// so looking only for "Cancel" left the query in place. The field's own clear
    /// button is the one button inside the field on iOS 18 and 26 alike, and deleting
    /// the text is the fallback when it isn't offered.
    private func clearSearch(_ app: XCUIApplication) {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: wait), "the library search field")
        let typed = searchText(field)
        let clear = field.buttons.firstMatch
        if clear.exists, clear.isHittable {
            clear.tap()
        } else if !typed.isEmpty {
            // Put the caret after the text before deleting it, unless the keyboard is still up from typing.
            if !app.keyboards.firstMatch.exists { field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap() }
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: typed.count))
        }
        XCTAssertTrue(waitFor(timeout: 10) { self.searchText(field).isEmpty },
                      "the library search query was cleared, not left as “\(searchText(field))”")

        // iPhone always offers a way out of search mode; iPad's toolbar field may not.
        let leave = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Close"])).firstMatch
        if leave.exists {
            leave.tap()
            XCTAssertTrue(waitForAbsence(leave), "search mode ended")
        } else {
            XCTAssertNotEqual(UIDevice.current.userInterfaceIdiom, .phone, "the iPhone search bar offers Cancel or Close")
        }
        XCTAssertTrue(searchText(field).isEmpty, "leaving search kept the query empty")
    }

    /// What is typed in a search field: its value, minus the placeholder an empty field reports.
    private func searchText(_ field: XCUIElement) -> String {
        guard field.exists, let value = field.value as? String else { return "" }
        return value == field.placeholderValue ? "" : value
    }

    /// The full player's play/pause button, when it reads `label`. The mini player has its own.
    private func toggle(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let found = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", "player-toggle", label)).firstMatch
        _ = found.waitForExistence(timeout: wait)
        return found
    }

    private func press(_ app: XCUIApplication, _ label: String) {
        let found = app.buttons[label]
        XCTAssertTrue(found.waitForExistence(timeout: wait), "a button labelled \(label)")
        found.tap()
    }

    /// Seconds into the track, from the scrubber's "m:ss of m:ss".
    private func elapsed(_ slider: XCUIElement) -> Double? {
        guard let value = slider.value as? String, let shown = value.components(separatedBy: " of ").first else { return nil }
        let parts = shown.split(separator: ":").compactMap { Double($0) }
        guard parts.count >= 2 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private func parseTime(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private func scroll(_ app: XCUIApplication, to element: XCUIElement) -> Bool {
        for _ in 0 ..< 12 {
            if element.exists { return true }
            app.swipeUp(velocity: .fast)
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

    /// The server's saved place for one publication: which write it came from.
    private struct SavedProgress: Equatable {
        let version: Int?
        let mutationId: String?
        let observedAt: String?
    }

    private func savedProgress(_ publication: String) throws -> SavedProgress {
        let body = try json(request(port, "GET", "/api/consumer/v1/library/\(publication)/progress", bearer: token))
        let progress = try XCTUnwrap(body["progress"] as? [String: Any], "the server has a saved place")
        return SavedProgress(
            version: progress["version"] as? Int,
            mutationId: progress["client_mutation_id"] as? String,
            observedAt: progress["observed_at"] as? String
        )
    }

    private struct ProgressWrites {
        let count: Int
        let resolving: Int
        let withoutObservedAt: Int
        let lastObservedAt: String?
    }

    /// What the app has sent for one publication, as the fixture server recorded it.
    private func progressWrites(_ publication: String) throws -> ProgressWrites {
        let stats = try json(request(controlPort, "GET", "/stats"))
        let log = (stats["progress_writes"] as? [String: Any])?[publication] as? [String: Any]
        let last = log?["last"] as? [String: Any]
        return ProgressWrites(
            count: log?["count"] as? Int ?? 0,
            resolving: log?["resolving"] as? Int ?? 0,
            withoutObservedAt: log?["without_observed_at"] as? Int ?? 0,
            lastObservedAt: last?["observed_at"] as? String
        )
    }

    /// The server's saved audio place for one publication.
    private func savedSeconds(_ publication: String) throws -> Double {
        let body = try json(request(port, "GET", "/api/consumer/v1/library/\(publication)/progress", bearer: token))
        return try XCTUnwrap((body["progress"] as? [String: Any])?["position_seconds"] as? Double)
    }

    private func setOnline(_ online: Bool) throws {
        _ = try request(controlPort, "POST", online ? "/online" : "/offline")
    }

    /// Plain HTTP/1.1 over a TCP connection. The runner's generated Info.plist has no ATS
    /// exception, and ATS doesn't govern Network framework connections.
    private func request(_ port: UInt16, _ method: String, _ path: String, body: [String: String]? = nil, bearer: String? = nil) throws -> Data {
        let payload = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        var head = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\nContent-Length: \(payload.count)\r\n"
        if body != nil { head += "Content-Type: application/json\r\n" }
        if let bearer { head += "Authorization: Bearer \(bearer)\r\n" }
        let message = Data((head + "\r\n").utf8) + payload

        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let queue = DispatchQueue(label: "org.shelfarr.smoke.http")
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

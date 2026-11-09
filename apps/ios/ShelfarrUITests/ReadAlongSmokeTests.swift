import Network
import UIKit
import XCTest

/// Read-along on a simulator against `RuntimeSmoke/smoke_server.py`, whose books have
/// known alignment (`read_along_fixture.py`): every cue is a two-second tone, then 600 ms
/// of silence. Chapter 1's cues p1…p6 start at 0, 2.6, 5.2, 7.8, 10.4 and 13 s of its
/// narration, and p4 starts pages after p3.
///
/// What is checked comes from the fixture server's record of every progress write and,
/// in Debug UI-test builds, the reader's `read-along-trace` (cue ids, offsets and flags of
/// the synthetic fixture only). Where the simulator never starts audio, the steps that
/// need narration to advance are skipped visibly, never passed.
final class ReadAlongSmokeTests: XCTestCase {
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
        // The fixture as the server started (see `FormatsSmokeTests.freshFixture`), after
        // the previous case's app has stopped sending.
        XCUIApplication().terminate()
        _ = try request(controlPort, "POST", "/reset")
        let grant = try json(request(port, "POST", "/api/consumer/v1/auth/device", body: ["client_name": "Shelfarr iOS read-along smoke"]))
        let issued = try json(request(port, "POST", "/api/consumer/v1/auth/token", body: ["device_code": grant["device_code"] as? String ?? ""]))
        token = try XCTUnwrap(issued["access_token"] as? String)
        let me = try json(request(port, "GET", "/api/consumer/v1/me", bearer: token))
        userId = try XCTUnwrap(me["id"] as? String)
    }

    override func tearDownWithError() throws {
        guard controlPort != 0 else { return }
        try? setOnline(true)
    }

    func testNarrationHighlightsFollowsAndSavesOnlyWhatWasHeard() throws {
        let app = launch(reset: true)
        let book = "narrated-1"
        try openDetails(app, search: "Narrated Fixture", book)
        XCTAssertTrue(text(app, containing: "Read along with the narration in this book.").waitForExistence(timeout: wait))
        screenshot(app, "ra-01-details")
        button(app, startingWith: ["Start reading", "Continue reading", "Open book"]).tap()

        try step("The page opens quiet") {
            XCTAssertTrue(prose(app, "The river was high that spring").waitForExistence(timeout: 60), "Readium rendered the narrated book")
            XCTAssertTrue(waitFor { self.trace(app)["source"] == "media_overlay" }, "narration is available: \(self.traceLine(app))")
            XCTAssertEqual(trace(app)["started"], "0")
            XCTAssertEqual(trace(app)["cue"], "-", "nothing is highlighted before playing")
            XCTAssertFalse(app.buttons["read-along-pill"].exists, "no pill before narration has played")
            screenshot(app, "ra-02-quiet")
        }

        try startNarration(app)

        try step("The heard cue is highlighted, gaps show nothing, and pages follow only out-of-view cues") {
            showChrome(app, false)
            XCTAssertTrue(app.buttons["read-along-pill"].waitForExistence(timeout: wait), "the pill appears once narration plays")
            // A cue lasts two seconds, about as long as reaching this point takes on a
            // hosted simulator, so the order comes from the controller's record of every
            // highlight change since Play (Debug UI tests only), not from sampling.
            XCTAssertTrue(waitFor(timeout: 15) { self.shown(app).count >= 5 }, "p1, its silence, p2, its silence, p3: \(traceLine(app))")
            let heard = Array(shown(app).prefix(5))
            XCTAssertEqual(heard.map { $0.cue }, ["p1", "-", "p2", "-", "p3"], "p1 is heard first, and each silence highlights nothing: \(traceLine(app))")
            XCTAssertEqual(heard.map { $0.follows }, [0, 0, 0, 0, 0], "p1, p2 and p3 were already on screen: no page moved")
            screenshot(app, "ra-03-heard")
            XCTAssertTrue(waitFor(timeout: 20) { self.shown(app).contains { $0.cue == "p4" } }, traceLine(app))
            XCTAssertTrue(waitFor(timeout: 10) { Int(self.trace(app)["follows"] ?? "0") ?? 0 >= 1 }, "p4 starts on a later page, so the page followed")
            screenshot(app, "ra-04-followed")
            let writes = try progressWrites(book)
            XCTAssertGreaterThan(writes.heard, 0, "listening checkpoints were written")
            XCTAssertEqual(writes.reading, 0, "following wrote no reading place")
        }

        try step("Turning pages while narration plays is browsing") {
            let before = try progressWrites(book)
            app.webViews.firstMatch.swipeLeft()
            XCTAssertTrue(waitFor(timeout: 10) { self.trace(app)["suspended"] == "1" }, "following paused: \(traceLine(app))")
            XCTAssertTrue(app.buttons["read-along-return"].waitForExistence(timeout: wait), "Back to the narration")
            sleep(2)
            XCTAssertEqual(try progressWrites(book).reading, before.reading, "a page browsed while playing wrote nothing")
            screenshot(app, "ra-05-browsing")
            app.buttons["read-along-return"].tap()
            XCTAssertTrue(waitFor(timeout: 10) { self.trace(app)["suspended"] == "0" })
        }

        var paused = 0
        var pausedAudio = 0
        try step("Pausing saves the element heard and its exact offset at once") {
            app.buttons["read-along-pill"].tap()
            XCTAssertTrue(waitFor(timeout: 10) { self.trace(app)["playing"] == "0" })
            // The pause's own checkpoint, not an earlier one already on the server: no more
            // are made while paused, so the last one recorded is the pause's.
            let heard = try XCTUnwrap(place(trace(app)["heard"]), traceLine(app))
            let saved = try XCTUnwrap(place(trace(app)["saved"]), traceLine(app))
            XCTAssertEqual(saved.audio, heard.audio, "saved in the file paused in: \(traceLine(app))")
            XCTAssertLessThanOrEqual(abs(saved.ms - heard.ms), 150, "saved where playback paused, not where the file started: \(traceLine(app))")
            XCTAssertTrue(waitFor {
                guard let point = (try? self.progressWrites(book))?.lastReadAlong else { return false }
                return point["audio"] as? Int == saved.audio && point["offset_ms"] as? Int == saved.ms
            }, "the pause checkpoint \(saved) reached the server")
            let last = try progressWrites(book)
            let point = try XCTUnwrap(last.lastReadAlong)
            paused = try XCTUnwrap(point["offset_ms"] as? Int)
            XCTAssertEqual((point["generation"] as? String)?.count, 64)
            let audio = try XCTUnwrap(point["audio"] as? Int)
            pausedAudio = audio
            XCTAssertEqual(last.lastFragments, [expectedFragment(audio: audio, ms: paused)], "the element reached at that offset")
            XCTAssertEqual(last.withoutObservedAt, 0)
            XCTAssertEqual(last.resolving, 0)
            screenshot(app, "ra-06-paused")
            closeReader(app)
        }

        try step("Reopening restores the heard place silently") {
            let before = try progressWrites(book).count
            button(app, startingWith: ["Continue reading", "Start reading", "Open book"]).tap()
            XCTAssertTrue(waitFor { self.trace(app)["source"] == "media_overlay" })
            XCTAssertTrue(waitFor(timeout: 25) { self.restoreTrace(app).contains { $0.hasSuffix("-> settled") } }, restoreTrace(app).joined(separator: "\n"))
            XCTAssertEqual(trace(app)["started"], "0", "the page is quiet again")
            sleep(5)
            XCTAssertEqual(try progressWrites(book).count, before, "restoring wrote nothing")
            XCTAssertFalse(restoreTrace(app).contains { $0.hasSuffix("-> record") })
            screenshot(app, "ra-07-reopened")
        }

        try step("Playing again replays five seconds once; pausing in the replay keeps the saved place") {
            let before = try progressWrites(book).count
            showChrome(app, true)
            app.buttons["read-along-play"].tap()
            XCTAssertTrue(waitFor(timeout: 10) { self.trace(app)["playing"] == "1" })
            // The first ticks played come from five seconds before the saved place, clamped
            // to the start of its file (ListeningCheckpoints.rewind).
            let resumeAt = max(0, paused - 5000)
            XCTAssertTrue(waitFor(timeout: 5) {
                guard let heard = self.place(self.trace(app)["heard"]), heard.audio == pausedAudio else { return false }
                return (max(0, resumeAt - 1500) ... resumeAt + 1500).contains(heard.ms)
            }, "resumed five seconds before \(pausedAudio):\(paused): \(traceLine(app))")
            app.buttons["read-along-play"].tap()
            XCTAssertTrue(waitFor(timeout: 10) { self.trace(app)["playing"] == "0" })
            sleep(2)
            let after = try progressWrites(book)
            XCTAssertEqual(after.count, before, "the replayed seconds wrote nothing")
            XCTAssertEqual(after.lastReadAlong?["offset_ms"] as? Int, paused)
            closeReader(app)
        }
    }

    func testPagesReadAfterPausingSurviveBackgroundingAndClosingNarration() throws {
        let app = launch(reset: true)
        let book = "narrated-1"
        try openDetails(app, search: "Narrated Fixture", book)
        button(app, startingWith: ["Start reading", "Continue reading", "Open book"]).tap()
        XCTAssertTrue(prose(app, "The river was high that spring").waitForExistence(timeout: 60))
        try startNarration(app)
        XCTAssertTrue(waitFor(timeout: 20) { (self.heardMs(app) ?? 0) >= 3000 }, traceLine(app))
        app.buttons["read-along-play"].tap()
        XCTAssertTrue(waitFor { self.trace(app)["playing"] == "0" })
        XCTAssertTrue(waitFor { (try? self.progressWrites(book))?.lastReadAlong != nil }, "pause saved the heard place")

        showChrome(app, false)
        // On iPad hiding the controls hides the status bar. Only the safe area changes,
        // not the page: it must not make the next turn an anchor.
        XCTAssertFalse(restoreTrace(app).contains { $0.hasPrefix("layout") }, "showing and hiding the controls is not a layout: \(restoreTrace(app).joined(separator: "\n"))")
        app.webViews.firstMatch.swipeLeft()
        XCTAssertTrue(waitFor { ((try? self.progressWrites(book))?.reading ?? 0) > 0 }, "a turn while paused saved a reading place: \(restoreTrace(app).joined(separator: "\n"))")
        let read = try progressWrites(book)
        XCTAssertNil(read.lastReadAlong)
        let time = try XCTUnwrap(read.lastObservedAt)
        screenshot(app, "ra-08-read-after-pause")

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(waitFor { self.trace(app)["playing"] == "0" }, traceLine(app))
        closeReader(app)
        button(app, startingWith: ["Continue reading", "Start reading", "Open book"]).tap()
        XCTAssertTrue(waitFor { self.trace(app)["source"] == "media_overlay" })
        XCTAssertTrue(waitFor(timeout: 25) { self.restoreTrace(app).contains { $0.hasSuffix("-> settled") } }, restoreTrace(app).joined(separator: "\n"))

        let reopened = try progressWrites(book)
        XCTAssertNil(reopened.lastReadAlong, "background and close never re-observe the paused audio over the page read")
        XCTAssertEqual(reopened.lastObservedAt, time, "the reading time survives lifecycle flushes and restore")
        XCTAssertEqual(reopened.count, read.count)
        XCTAssertEqual(trace(app)["started"], "0")
        XCTAssertFalse(restoreTrace(app).contains { $0.hasSuffix("-> record") })
        screenshot(app, "ra-09-read-page-reopened")
        closeReader(app)
    }

    func testAnImportedPairSavesBothPlacesAndOffersALaterAudiobookPlace() throws {
        // The audiobook was heard on its own player five seconds ago, into the second chapter.
        _ = try request(controlPort, "POST", "/audio-place", body: ["publication": "paired-audio", "asset": "track-p2", "seconds": "3.0", "ago": "5"])
        let app = launch(reset: true)
        try openDetails(app, search: "Paired Fixture", "paired-1")
        XCTAssertTrue(text(app, containing: "Read along with “Paired Fixture Narration”.").waitForExistence(timeout: wait))
        button(app, startingWith: ["Start reading", "Continue reading", "Open book"]).tap()
        XCTAssertTrue(prose(app, "The lighthouse stood at the end").waitForExistence(timeout: 60))

        try step("A later audiobook place is offered, and accepting it writes nothing") {
            XCTAssertTrue(app.otherElements["read-along-offer"].waitForExistence(timeout: wait), "the offer shows: \(traceLine(app))")
            screenshot(app, "ra-10-offer")
            app.buttons["read-along-offer-accept"].tap()
            XCTAssertTrue(waitFor { self.trace(app)["offer"] == "0" })
            XCTAssertEqual(trace(app)["heard"], "1:3000", "narration will start at the audiobook's place")
            XCTAssertTrue(waitFor(timeout: 15) { self.prose(app, "Ships answered the horn").exists }, "the page shows its element")
            sleep(2)
            XCTAssertEqual(try progressWrites("paired-1").count, 0, "showing it is not reading")
            XCTAssertEqual(try progressWrites("paired-audio").count, 0, "nor listening")
        }

        try startNarration(app)

        try step("A checkpoint writes the ebook element and the audiobook's own place, with one time") {
            sleep(4)
            showChrome(app, true)
            app.buttons["read-along-play"].tap()
            XCTAssertTrue(waitFor(timeout: 10) { self.trace(app)["playing"] == "0" })
            XCTAssertTrue(waitFor { ((try? self.progressWrites("paired-audio"))?.count ?? 0) > 0 && (try? self.progressWrites("paired-1"))?.lastReadAlong != nil })
            let ebook = try progressWrites("paired-1"), audiobook = try progressWrites("paired-audio")
            let point = try XCTUnwrap(ebook.lastReadAlong)
            XCTAssertEqual(point["audio"] as? Int, 1)
            let offset = try XCTUnwrap(point["offset_ms"] as? Int)
            XCTAssertGreaterThanOrEqual(offset, 3000, "from the adopted place, not rewound")
            XCTAssertEqual(audiobook.lastAsset, "track-p2")
            XCTAssertEqual(try XCTUnwrap(audiobook.lastSeconds), Double(offset) / 1000, accuracy: 0.002)
            XCTAssertEqual(audiobook.lastObservedAt, ebook.lastObservedAt, "the same observed_at for both")
            screenshot(app, "ra-11-coupled")
            closeReader(app)
        }
    }

    func testDownloadedNarrationReopensOfflineAndAStaleAlignmentReadsAsUsual() throws {
        let app = launch(reset: true)
        try step("Downloading the book keeps its narration") {
            try openDetails(app, search: "Narrated Fixture", "narrated-1")
            tapDownload(app)
            XCTAssertTrue(app.staticTexts["Downloaded"].waitForExistence(timeout: 90), "the EPUB download completes")
            XCTAssertTrue(app.staticTexts["narration-status"].waitForExistence(timeout: wait))
            XCTAssertTrue(waitFor(timeout: 60) { app.staticTexts["narration-status"].label == "Narration is on this device too." },
                          "the narration was copied out of the EPUB: \(app.staticTexts["narration-status"].label)")
            let stats = try json(request(controlPort, "GET", "/stats"))
            XCTAssertEqual(stats["grant_requests_with_bearer"] as? Int, 0, "no background request carried the bearer")
            screenshot(app, "ra-20-downloaded")
        }

        try step("Offline, the downloaded narration plays from this device") {
            try setOnline(false)
            app.terminate()
            let offline = launch(reset: false)
            XCTAssertTrue(tab(offline, "Library").waitForExistence(timeout: wait))
            tab(offline, "Library").tap()
            XCTAssertTrue(item(offline, "narrated-1").waitForExistence(timeout: wait) || scroll(offline, to: item(offline, "narrated-1")))
            item(offline, "narrated-1").tap()
            button(offline, startingWith: ["Start reading", "Continue reading", "Open book"]).tap()
            XCTAssertTrue(prose(offline, "The river was high that spring").waitForExistence(timeout: 60), "the download renders offline")
            XCTAssertTrue(waitFor { self.trace(offline)["audio"] == "device" }, "narration from this device: \(self.traceLine(offline))")
            screenshot(offline, "ra-21-offline")
            showChrome(offline, true)
            offline.buttons["read-along-play"].tap()
            if waitFor(timeout: 15, { self.trace(offline)["playing"] == "1" }) {
                XCTAssertTrue(waitFor(timeout: 15) { self.trace(offline)["cue"] == "p1" }, traceLine(offline))
                offline.buttons["read-along-play"].tap()
            } else {
                screenshot(offline, "ra-21-not-playing")
                XCTContext.runActivity(named: "The simulator did not start local audio; offline highlighting not observed") { _ in }
            }
            closeReader(offline)
            offline.terminate()
            try setOnline(true)
        }

        try step("A stale alignment reads as an ordinary EPUB") {
            _ = try request(controlPort, "POST", "/read-along/stale")
            let online = launch(reset: false)
            try openDetails(online, search: "Paired Fixture", "paired-1")
            XCTAssertTrue(text(online, containing: "Read-along isn't available").waitForExistence(timeout: wait))
            button(online, startingWith: ["Start reading", "Continue reading", "Open book"]).tap()
            XCTAssertTrue(prose(online, "The lighthouse stood at the end").waitForExistence(timeout: 60))
            showChrome(online, true)
            XCTAssertTrue(online.staticTexts["read-along-note"].waitForExistence(timeout: wait))
            XCTAssertTrue(online.staticTexts["read-along-note"].label.hasSuffix("Reading works as usual."))
            XCTAssertFalse(online.buttons["read-along-play"].exists, "no narration controls")
            showChrome(online, false)
            online.webViews.firstMatch.swipeLeft()
            XCTAssertTrue(waitFor(timeout: 15) { ((try? self.progressWrites("paired-1"))?.reading ?? 0) > 0 }, "a turn is an ordinary reading place")
            XCTAssertNil(try progressWrites("paired-1").lastReadAlong)
            screenshot(online, "ra-22-stale")
            closeReader(online)
        }
    }

    // MARK: Steps

    private func startNarration(_ app: XCUIApplication) throws {
        showChrome(app, true)
        XCTAssertTrue(app.buttons["read-along-play"].waitForExistence(timeout: wait), "the narration controls are in the reading overlay")
        screenshot(app, "ra-controls")
        app.buttons["read-along-play"].tap()
        guard waitFor(timeout: 15, { self.trace(app)["playing"] == "1" }) else {
            screenshot(app, "ra-not-playing")
            throw XCTSkip("The simulator did not start narration playback, so highlighting and checkpoints cannot be observed here")
        }
    }

    private func openDetails(_ app: XCUIApplication, search query: String, _ id: String) throws {
        XCTAssertTrue(tab(app, "Library").waitForExistence(timeout: wait))
        tab(app, "Library").tap()
        search(app, query)
        XCTAssertTrue(item(app, id).waitForExistence(timeout: wait), "the library finds \(query)")
        item(app, id).tap()
    }

    /// Shows or hides the reading controls with a tap in the middle of the page.
    private func showChrome(_ app: XCUIApplication, _ visible: Bool) {
        let close = app.buttons["Close book"]
        for _ in 0 ..< 3 where close.exists != visible {
            app.webViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = visible ? close.waitForExistence(timeout: 3) : waitForAbsence(close, timeout: 3)
        }
    }

    private func closeReader(_ app: XCUIApplication) {
        showChrome(app, true)
        XCTAssertTrue(app.buttons["Close book"].exists, "the reader's chrome opens")
        app.buttons["Close book"].tap()
    }

    /// The fixture's chapter 1 cue at `ms`: the last one started (gaps belong to it).
    private func expectedFragment(audio: Int, ms: Int) -> String {
        let index = min(ms / 2600, audio == 0 ? 5 : 2)
        return audio == 0 ? "p\(index + 1)" : "q\(index + 1)"
    }

    // MARK: Trace

    private func traceLine(_ app: XCUIApplication) -> String {
        let element = app.descendants(matching: .any)["read-along-trace"].firstMatch
        return element.exists ? element.label : ""
    }

    private func trace(_ app: XCUIApplication) -> [String: String] {
        var fields: [String: String] = [:]
        for part in traceLine(app).split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
        }
        return fields
    }

    /// The highlight changes since narration last began, oldest first (`shown=` in the trace).
    private struct Shown {
        let cue: String
        /// Pages followed to when this highlight began.
        let follows: Int
    }

    private func shown(_ app: XCUIApplication) -> [Shown] {
        guard let value = trace(app)["shown"], value != "-" else { return [] }
        return value.split(separator: ",").compactMap { entry -> Shown? in
            let parts = entry.split(separator: "/")
            guard parts.count == 2, let follows = Int(parts[1]) else { return nil }
            return Shown(cue: String(parts[0]), follows: follows)
        }
    }

    private func heardMs(_ app: XCUIApplication) -> Int? {
        trace(app)["heard"]?.split(separator: ":").last.flatMap { Int($0) }
    }

    /// An "audio:ms" trace field.
    private func place(_ field: String?) -> (audio: Int, ms: Int)? {
        guard let parts = field?.split(separator: ":"), parts.count == 2, let audio = Int(parts[0]), let ms = Int(parts[1]) else { return nil }
        return (audio, ms)
    }

    private func restoreTrace(_ app: XCUIApplication) -> [String] {
        let element = app.descendants(matching: .any)["reader-restore-trace"].firstMatch
        return element.exists ? element.label.components(separatedBy: "\n") : []
    }

    // MARK: App

    private func launch(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-shelfarr-ui-test"] + (reset ? ["-shelfarr-ui-test-reset"] : [])
        app.launchEnvironment = [
            "SHELFARR_UITEST_SERVER": "http://localhost:\(port)",
            "SHELFARR_UITEST_TOKEN": token,
            "SHELFARR_UITEST_USER_ID": userId,
            "SHELFARR_UITEST_USER_NAME": "Mock Reader",
        ]
        app.launch()
        return app
    }

    private func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let bar = app.tabBars.buttons[name]
        return bar.exists ? bar : app.buttons.matching(identifier: name).firstMatch
    }

    private func item(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)["library-item-\(id)"].firstMatch
    }

    private func text(_ app: XCUIApplication, containing value: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    private func prose(_ app: XCUIApplication, _ value: String) -> XCUIElement {
        app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
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

    /// As `RuntimeSmokeTests.search`: iPhone hides the field above the list, iPad may
    /// collapse it into a Search bar button.
    private func search(_ app: XCUIApplication, _ query: String) {
        let field = app.searchFields.firstMatch
        if !field.waitForExistence(timeout: 5) {
            let collapsed = app.navigationBars.buttons["Search"]
            if collapsed.exists, collapsed.isHittable { collapsed.tap() } else { app.swipeDown() }
        }
        XCTAssertTrue(field.waitForExistence(timeout: wait), "the library search field")
        field.tap()
        field.typeText(query)
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
        let trace = XCTAttachment(string: traceLine(app) + "\n" + restoreTrace(app).joined(separator: "\n"))
        trace.name = name + "-trace"
        trace.lifetime = .keepAlways
        add(trace)
    }

    private func step(_ name: String, _ body: () throws -> Void) throws {
        try XCTContext.runActivity(named: name) { _ in try body() }
    }

    // MARK: Fixture server

    private enum SmokeError: Error { case unconfigured, timeout, http(Int), malformed }

    private struct ProgressWrites {
        let count: Int
        let resolving: Int
        let withoutObservedAt: Int
        /// Places with a locator and `readAlong` (heard), or without it (read).
        let heard: Int
        let reading: Int
        let lastObservedAt: String?
        let lastReadAlong: [String: Any]?
        let lastFragments: [String]?
        let lastAsset: String?
        let lastSeconds: Double?
    }

    private func progressWrites(_ publication: String) throws -> ProgressWrites {
        let stats = try json(request(controlPort, "GET", "/stats"))
        let log = (stats["progress_writes"] as? [String: Any])?[publication] as? [String: Any]
        let last = log?["last"] as? [String: Any]
        return ProgressWrites(
            count: log?["count"] as? Int ?? 0,
            resolving: log?["resolving"] as? Int ?? 0,
            withoutObservedAt: log?["without_observed_at"] as? Int ?? 0,
            heard: log?["heard_places"] as? Int ?? 0,
            reading: log?["reading_places"] as? Int ?? 0,
            lastObservedAt: last?["observed_at"] as? String,
            lastReadAlong: last?["read_along"] as? [String: Any],
            lastFragments: last?["fragments"] as? [String],
            lastAsset: last?["asset_id"] as? String,
            lastSeconds: last?["position_seconds"] as? Double
        )
    }

    private func setOnline(_ online: Bool) throws {
        _ = try request(controlPort, "POST", online ? "/online" : "/offline")
    }

    /// Plain HTTP/1.1 over a TCP connection, as `RuntimeSmokeTests.request`.
    private func request(_ port: UInt16, _ method: String, _ path: String, body: [String: String]? = nil, bearer: String? = nil) throws -> Data {
        let payload = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        var head = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\nContent-Length: \(payload.count)\r\n"
        if body != nil { head += "Content-Type: application/json\r\n" }
        if let bearer { head += "Authorization: Bearer \(bearer)\r\n" }
        let message = Data((head + "\r\n").utf8) + payload

        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let queue = DispatchQueue(label: "org.shelfarr.smoke.read-along.http")
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

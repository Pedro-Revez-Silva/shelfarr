@testable import ShelfarrCore
import XCTest

final class ActivityTimeTests: XCTestCase {
    func testFormatsUTCWithMilliseconds() {
        XCTAssertEqual(ActivityTime.format(baseTime), "2026-11-07T09:00:00.000Z")
        XCTAssertEqual(ActivityTime.format(baseTime + 30_123), "2026-11-07T09:00:30.123Z")
        XCTAssertEqual(ActivityTime.format(951_782_400_000), "2000-02-29T00:00:00.000Z")
        XCTAssertEqual(ActivityTime.format(0), "1970-01-01T00:00:00.000Z")
    }

    func testRoundTripsAcrossYears() {
        var value: Int64 = ActivityTime.earliest
        while value < 4_102_444_800_000 {
            XCTAssertEqual(ActivityTime.parse(ActivityTime.format(value)), value)
            value += 86_399_999 * 37
        }
    }

    func testParsesZonedTimes() {
        XCTAssertEqual(ActivityTime.parse("2026-11-07T09:00:00Z"), baseTime)
        XCTAssertEqual(ActivityTime.parse("2026-11-07T10:30:00+01:30"), baseTime)
        XCTAssertEqual(ActivityTime.parse("2026-11-07T04:00:00-05:00"), baseTime)
        XCTAssertEqual(ActivityTime.parse("2026-11-07T09:00:00.5Z"), baseTime + 500)
        XCTAssertEqual(ActivityTime.parse("2026-11-07T09:00:00.123456789Z"), baseTime + 123, "beyond milliseconds is truncated")
    }

    func testRejectsAnythingThatIsNotAZonedTimeWithSeconds() {
        for value in [
            nil, "", "2026-11-07", "2026-11-07T09:00Z", "2026-11-07T09:00:00", "2026-11-07 09:00:00Z",
            "2026-02-29T09:00:00Z", "2026-13-01T00:00:00Z", "2026-11-31T00:00:00Z", "2026-11-07T24:00:00Z",
            "2026-11-07T09:60:00Z", "2026-11-07T09:00:00.Z", "2026-11-07T09:00:00+0100", "2026-11-07T09:00:00Zjunk",
            "２０２６-11-07T09:00:00Z",
        ] {
            XCTAssertNil(ActivityTime.parse(value), String(describing: value))
        }
    }

    func testPlausibility() {
        XCTAssertTrue(ActivityTime.isPlausible(baseTime, now: baseTime))
        XCTAssertTrue(ActivityTime.isPlausible(baseTime + ActivityTime.futureTolerance, now: baseTime))
        XCTAssertFalse(ActivityTime.isPlausible(baseTime + ActivityTime.futureTolerance + 1, now: baseTime))
        XCTAssertFalse(ActivityTime.isPlausible(1000, now: baseTime), "a clock that was never set")
        XCTAssertFalse(ActivityTime.isPlausible(nil, now: baseTime))
    }

    func testANewObservationNeverLooksOlderThanTheLastOneHere() {
        XCTAssertEqual(ActivityTime.next(baseTime, after: nil), baseTime)
        XCTAssertEqual(ActivityTime.next(baseTime, after: baseTime - 1), baseTime)
        XCTAssertEqual(ActivityTime.next(baseTime, after: baseTime), baseTime + 1)
        XCTAssertEqual(ActivityTime.next(baseTime, after: baseTime + 2000), baseTime + 2001)
        // A previous time far ahead was a wrong clock; it does not drag new reading with it.
        XCTAssertEqual(ActivityTime.next(baseTime, after: baseTime + 3_600_000), baseTime)
    }
}

final class ListeningCheckpointsTests: XCTestCase {
    private func at(_ seconds: Double, _ track: String = "t1") -> SavedPosition {
        SavedPosition(assetId: track, positionSeconds: seconds)
    }

    func testOpeningASavedPlaceRewindsFiveSecondsWithinTheTrack() {
        var rules = ListeningCheckpoints()
        XCTAssertEqual(rules.open(at(100), firstTrack: "t1"), 95)
        XCTAssertEqual(rules.open(at(3, "t2"), firstTrack: "t1"), 0, "clamped to the start of the current track")
        XCTAssertEqual(rules.open(nil, firstTrack: "t1"), 0)
    }

    func testTheOpenedPlaceStaysSavedThroughThePreRoll() {
        var rules = ListeningCheckpoints()
        _ = rules.open(at(100), firstTrack: "t1")
        XCTAssertFalse(rules.isActivity(at(95)))
        XCTAssertFalse(rules.isActivity(at(99.9)))
        XCTAssertFalse(rules.isActivity(at(100)))
        XCTAssertTrue(rules.isActivity(at(100.5)), "playback passed the saved place")
        XCTAssertTrue(rules.isActivity(at(96)), "once passed, any place is activity")
    }

    func testOpeningAtTheBeginningIsNotActivityUntilPlaybackMoves() {
        var rules = ListeningCheckpoints()
        _ = rules.open(nil, firstTrack: "t1")
        XCTAssertFalse(rules.isActivity(at(0)))
        XCTAssertTrue(rules.isActivity(at(0.5)))
    }

    func testAPausedRestartRewindsOnce() {
        var rules = ListeningCheckpoints()
        _ = rules.open(nil, firstTrack: "t1")
        XCTAssertTrue(rules.isActivity(at(60)))
        XCTAssertNil(rules.resumed(at: at(60)), "playing without a pause first is not a resume")
        rules.paused()
        XCTAssertEqual(rules.resumed(at: at(60)), 55)
        XCTAssertNil(rules.resumed(at: at(55)), "once per resume")
        XCTAssertFalse(rules.isActivity(at(58)), "the paused place stays saved through the pre-roll")
        rules.paused()
        XCTAssertNil(rules.resumed(at: at(58)), "pausing during the replay must not rewind again")
        rules.paused()
        XCTAssertNil(rules.resumed(at: at(58.1)), "repeated pauses cannot walk backwards")
        XCTAssertFalse(rules.isActivity(at(59)), "pausing inside the pre-roll keeps the original place")
        XCTAssertTrue(rules.isActivity(at(60.5)))
    }

    func testAPausedRestartNearTheTrackStartClampsToIt() {
        var rules = ListeningCheckpoints()
        _ = rules.open(nil, firstTrack: "t1")
        rules.paused()
        XCTAssertEqual(rules.resumed(at: at(2, "t2")), 0)
        rules.paused()
        XCTAssertNil(rules.resumed(at: at(0, "t2")), "nothing earlier in this track")
    }

    /// The hosted iPhone resume smoke (Xcode 26): paused at 35.327 s after skipping forward,
    /// replayed from 30.327, but the next pause came 45 s later, after track 1 ended and
    /// track 2 had played to 15.008 s. Only the replay holds the saved place; the next
    /// track is listening, whatever its seconds.
    func testAReplayThatRunsIntoTheNextTrackIsListening() {
        var rules = ListeningCheckpoints()
        _ = rules.open(nil, firstTrack: "track-1")
        rules.movedDeliberately()
        XCTAssertTrue(rules.isActivity(at(35.327, "track-1")))
        rules.paused()
        XCTAssertEqual(rules.resumed(at: at(35.327, "track-1")) ?? -1, 30.327, accuracy: 0.0005)
        for heard in [30.327, 31, 35, 35.327] {
            XCTAssertFalse(rules.isActivity(at(heard, "track-1")), "\(heard) s is the replay")
        }
        rules.carriedOn()
        XCTAssertTrue(rules.isActivity(at(0, "track-2")), "the next track is new listening")
        XCTAssertTrue(rules.isActivity(at(15.008, "track-2")))
    }

    func testDeliberateMovesAndNaturalTransitionsNeverRewind() {
        var rules = ListeningCheckpoints()
        _ = rules.open(at(100), firstTrack: "t1")
        rules.paused()
        rules.movedDeliberately()
        XCTAssertNil(rules.resumed(at: at(30)), "a seek or track choice while paused plays from where it was put")
        XCTAssertTrue(rules.isActivity(at(30)), "a deliberate move is real activity")
        rules.paused()
        rules.carriedOn()
        XCTAssertNil(rules.resumed(at: at(0, "t2")), "a natural track change or an interruption ending carries on")
    }

    func testHoldingAnAdoptedPlaceIsNotActivity() {
        var rules = ListeningCheckpoints()
        _ = rules.open(nil, firstTrack: "t1")
        rules.paused()
        rules.hold(at(300))
        XCTAssertNil(rules.resumed(at: at(300)))
        XCTAssertFalse(rules.isActivity(at(300)))
    }

    /// Ticks every half second, some late, over ten minutes of playback.
    func testCheckpointsTrailPlaybackByAtMostFiveSeconds() {
        var rules = ListeningCheckpoints()
        _ = rules.open(nil, firstTrack: "t1")
        var elapsed = 0.0
        var last: Double?
        var largestGap = 0.0
        var generator = SystemRandomNumberGenerator()
        while elapsed < 600 {
            elapsed += 0.5 + Double(UInt64.random(in: 0 ... 400, using: &generator)) / 1000
            if rules.due(at: elapsed) {
                if let last { largestGap = max(largestGap, elapsed - last) }
                rules.checkpointed(at: elapsed)
                last = elapsed
            }
        }
        XCTAssertGreaterThan(largestGap, 3.9)
        XCTAssertLessThanOrEqual(largestGap, 5.0)
    }
}

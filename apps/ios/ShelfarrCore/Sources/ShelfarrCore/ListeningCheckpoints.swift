import Foundation

/// When listening becomes a saved checkpoint, and where a resume restarts.
///
/// Pure state, driven by the app's playback engine so it can be tested without a player:
/// - While playing, a checkpoint is due at most every `interval` seconds of elapsed time.
/// - A genuine resume (opening a saved place, or playing again after a pause) restarts
///   `rewind` seconds earlier, clamped to the start of the current track. It applies
///   once per resume, never after a deliberate seek or track choice.
/// - The rewound pre-roll is not new activity: the place resumed from stays the saved
///   checkpoint until playback passes it or the listener deliberately moves.
public struct ListeningCheckpoints: Sendable {
    public static let rewind = 5.0
    /// Ticks come every half second, so checking at four seconds keeps the gap between
    /// checkpoints under five seconds even when a tick runs late.
    public static let interval = 4.0

    private let interval: Double
    private var held: SavedPosition?
    private var lastCheckpointAt: Double?
    private var rewindArmed = false

    public init(interval: Double = ListeningCheckpoints.interval) {
        self.interval = interval
    }

    /// A saved place, or the start of `firstTrack` when there is none, is being opened.
    /// Returns where to start in its track. Opening is not activity, so the place itself
    /// is held until playback moves beyond it.
    public mutating func open(_ saved: SavedPosition?, firstTrack: String) -> Double {
        held = saved ?? SavedPosition(assetId: firstTrack, positionSeconds: 0)
        rewindArmed = false
        lastCheckpointAt = nil
        return Self.rewound(saved?.positionSeconds ?? 0)
    }

    /// Moving to a place that is already saved (another device's, chosen by the
    /// listener) without making it new activity or rewinding it.
    public mutating func hold(_ saved: SavedPosition) {
        held = saved
        rewindArmed = false
    }

    /// Playback was paused, by anyone: the next requested play is a resume.
    public mutating func paused() {
        rewindArmed = true
    }

    /// Playback carried on without a resume (an interruption ending, a natural track change).
    public mutating func carriedOn() {
        rewindArmed = false
    }

    /// The listener chose a place or track: no rewind for it, and it is real activity.
    public mutating func movedDeliberately() {
        rewindArmed = false
        held = nil
    }

    /// Someone asked to play at `current` while not playing. Returns the earlier place to
    /// restart from when this resumes paused playback, or nil to carry on where it is.
    public mutating func resumed(at current: SavedPosition) -> Double? {
        guard rewindArmed else { return nil }
        rewindArmed = false
        let seconds = current.positionSeconds ?? 0
        let target = Self.rewound(seconds)
        guard millis(target) < millis(seconds) else { return nil }
        // Keep the place it was paused at until playback passes it again.
        if let place = held, place.assetId == current.assetId, millis(place.positionSeconds ?? 0) >= millis(seconds) {
            return target
        }
        held = current
        return target
    }

    /// False while `position` is only the opened place or the replayed pre-roll before it.
    public mutating func isActivity(_ position: SavedPosition) -> Bool {
        guard let place = held else { return true }
        if position.assetId == place.assetId, millis(position.positionSeconds ?? 0) <= millis(place.positionSeconds ?? 0) {
            return false
        }
        held = nil
        return true
    }

    /// Whether a periodic checkpoint is due at `elapsed` seconds of a monotonic clock.
    public func due(at elapsed: Double) -> Bool {
        guard let lastCheckpointAt else { return true }
        return elapsed - lastCheckpointAt >= interval
    }

    public mutating func checkpointed(at elapsed: Double) {
        lastCheckpointAt = elapsed
    }

    /// Five seconds earlier, never before the start of the track.
    public static func rewound(_ seconds: Double) -> Double {
        max(0, seconds - rewind)
    }

    private func millis(_ seconds: Double) -> Int64 {
        max(0, Int64((seconds * 1000).rounded()))
    }
}

/// Tells Readium restoring a place apart from the reader moving.
///
/// Readium lands on the start of the page holding a saved progression, so a restored
/// report can be up to a page earlier, never later. Any forward page turn is reading.
/// Restoring a place is not reading, so it must not become a new checkpoint.
public struct ReadingRestoration: Sendable {
    static let before = 0.02
    static let after = 0.0005

    private enum Anchor: Sendable {
        case none
        /// Opened at the beginning: the first report says where that is.
        case beginning
        case place(JSONValue)
        /// The actual page reported after restoration; subsequent movement is reading.
        case restored(JSONValue)
    }

    private var anchor: Anchor

    /// A session opening at `locator`, or at the beginning when nil.
    public init(opening locator: JSONValue?) {
        anchor = locator.map(Anchor.place) ?? .beginning
    }

    /// The reader is being sent to a saved place it chose (another device's). Arriving
    /// there is not reading either.
    public mutating func reopen(at locator: JSONValue?) {
        anchor = locator.map(Anchor.place) ?? .beginning
    }

    /// True when `current` is a place the reader moved to; false while it is only the
    /// restored place.
    public mutating func isReading(_ current: JSONValue) -> Bool {
        switch anchor {
        case .none:
            return true
        case .beginning:
            anchor = .restored(current)
            return false
        case let .place(start):
            if Self.isRestored(start: start, current: current) {
                anchor = .restored(current)
                return false
            }
            anchor = .none
            return true
        case let .restored(start):
            if Self.samePage(start, current) { return false }
            anchor = .none
            return true
        }
    }

    public static func isRestored(start: JSONValue, current: JSONValue) -> Bool {
        guard let href = current["href"]?.stringValue,
              let opened = start["href"]?.stringValue,
              trimmed(href) == trimmed(opened)
        else { return false }
        let from = start["locations"]?["progression"]?.doubleValue ?? 0
        let now = current["locations"]?["progression"]?.doubleValue ?? 0
        return now >= from - before && now <= from + after
    }

    private static func trimmed(_ href: String) -> Substring {
        href.drop { $0 == "/" }
    }

    private static func samePage(_ start: JSONValue, _ current: JSONValue) -> Bool {
        guard let href = current["href"]?.stringValue, let opened = start["href"]?.stringValue,
              trimmed(href) == trimmed(opened) else { return false }
        return current["locations"]?["progression"]?.doubleValue == start["locations"]?["progression"]?.doubleValue
    }
}

extension JSONValue {
    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }
}

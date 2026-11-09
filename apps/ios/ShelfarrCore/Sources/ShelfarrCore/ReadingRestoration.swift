import Foundation

/// The part of a publication on screen, as the navigator measured it.
///
/// Each resource is a reading order item with the range of its own progression (0–1)
/// that is visible. A paginated page is `[page start, page end]`.
public struct ReadingViewport: Sendable, Equatable {
    public struct Resource: Sendable, Equatable {
        public let href: String
        public let progression: ClosedRange<Double>

        public init(href: String, progression: ClosedRange<Double>) {
            self.href = href
            self.progression = progression
        }
    }

    public let resources: [Resource]

    public init(resources: [Resource]) {
        self.resources = resources
    }
}

/// One location report from the navigator: its locator and what it measured on screen.
public struct ReadingObservation: Sendable, Equatable {
    public let locator: JSONValue
    public let viewport: ReadingViewport?

    public init(locator: JSONValue, viewport: ReadingViewport?) {
        self.locator = locator
        self.viewport = viewport
    }
}

/// Tells restoring a saved reading place apart from the reader moving.
///
/// Opening a book at its saved place is not reading, so it must never become a new
/// checkpoint. The navigator's first report is not proof of where it landed: on a cold
/// start it can report the start of the chapter before the page has been laid out. So:
///
/// - The saved place is restored once a report's measured viewport contains it (its
///   resource, and its progression inside the visible range). That page becomes the
///   anchor even when it starts well before the saved progression.
/// - A report that misses it is not saved. The reader is sent to the saved place again,
///   with input disabled, and waits for a report that shows it. `go` finishing is not
///   enough, because the navigator reports the settled page later.
/// - Each attempt has a finite timeout; after `attempts` the reader gives up, input is
///   enabled and the page on screen becomes the anchor. The saved place stays the
///   durable checkpoint until the reader actually moves.
/// - Once anchored, any report of another page, forward or back, is reading. A place
///   heard is the exception while its element confirmed the anchor: the page answers
///   about the document as it is when asked, which can be after the navigator scrolled
///   but before it reported that scroll. A later report of that document is reading only
///   once the page says the element has left the screen.
public struct ReadingRestoration: Sendable {
    /// Correcting attempts before giving up: one corrective jump and one retry.
    public static let attempts = 2
    /// How long one attempt waits for a report showing the saved place.
    public static let attemptTimeout: TimeInterval = 5
    /// Float slack when comparing progressions measured at different times.
    static let epsilon = 1e-6

    public enum Action: Sendable, Equatable {
        /// Not reading: nothing to save.
        case none
        /// The reader moved: save this place.
        case record
        /// The saved place is not on screen: disable input, go to `target`, and call
        /// `timedOut(attempt:)` if nothing shows it within `attemptTimeout`.
        case correct(target: JSONValue, attempt: Int)
        /// The saved place is on screen: enable input.
        case settled
        /// The saved place could not be shown: enable input. It stays saved until the
        /// reader moves.
        case gaveUp
        /// The saved place names an element (a place reached by listening has no
        /// progression) and its document is on screen: check whether the element itself
        /// is, then call `elementShown(_:for:)` with the observation this answered.
        /// After restoring, the answer can be `.record`: that observation is reading.
        case confirm(target: JSONValue)
    }

    private enum Phase: Sendable {
        /// Opened at the beginning: the first report says where that is.
        case beginning
        /// Opened at `target`, waiting for the navigator's first report.
        case awaiting(target: JSONValue)
        /// Sent to `target` again; input is disabled.
        case correcting(target: JSONValue, attempt: Int, last: ReadingObservation?)
        /// The page restoration ended on. `failed` when it is not the saved place.
        case anchored(ReadingObservation, target: JSONValue?, failed: Bool)
        /// Gave up before any report: the next one anchors.
        case unanchored(target: JSONValue)
        /// Waiting for the app to say whether the saved element is on screen in `current`.
        /// `attempt` is the correcting attempt under way (0 before any), `afterGivingUp`
        /// when restoring already gave up.
        case confirming(target: JSONValue, attempt: Int, current: ReadingObservation, last: ReadingObservation?, afterGivingUp: Bool)
        /// Restored at `anchor` because the page showed the saved element, and the
        /// navigator has since reported `current`, another page of that document. Whether
        /// the element is still shown tells a late report of the restore from a turn.
        case verifying(anchor: ReadingObservation, target: JSONValue, current: ReadingObservation)
        /// The reader has moved; every report is reading.
        case reading
    }

    private var phase: Phase

    /// A session opening at `locator`, or at the beginning when nil.
    public init(opening locator: JSONValue?) {
        phase = locator.map { .awaiting(target: $0) } ?? .beginning
    }

    /// True while the reader is being sent back to the saved place.
    public var isCorrecting: Bool {
        switch phase {
        case .correcting: return true
        case let .confirming(_, attempt, _, _, _): return attempt > 0
        default: return false
        }
    }

    /// The reader is being sent to a saved place it chose (another device's). Arriving
    /// there is not reading either; the caller performs the returned jump.
    public mutating func reopen(at locator: JSONValue?) -> Action {
        guard let locator else { return .none }
        phase = .correcting(target: locator, attempt: 1, last: nil)
        return .correct(target: locator, attempt: 1)
    }

    /// Classifies one navigator report.
    public mutating func observe(_ current: ReadingObservation) -> Action {
        switch phase {
        case .reading:
            return .record
        case .beginning:
            phase = .anchored(current, target: nil, failed: false)
            return .none
        case let .awaiting(target):
            if Self.isElementTarget(target) {
                if Self.documentShown(target, in: current) {
                    phase = .confirming(target: target, attempt: 0, current: current, last: current, afterGivingUp: false)
                    return .confirm(target: target)
                }
                phase = .correcting(target: target, attempt: 1, last: current)
                return .correct(target: target, attempt: 1)
            }
            if Self.shows(target, in: current) {
                phase = .anchored(current, target: target, failed: false)
                return .settled
            }
            phase = .correcting(target: target, attempt: 1, last: current)
            return .correct(target: target, attempt: 1)
        case let .confirming(target, attempt, _, last, afterGivingUp):
            // A newer report replaces the one being checked; its answer is what counts.
            if Self.documentShown(target, in: current) {
                phase = .confirming(target: target, attempt: attempt, current: current, last: last, afterGivingUp: afterGivingUp)
                return .confirm(target: target)
            }
            if afterGivingUp {
                phase = .anchored(current, target: target, failed: true)
                return .none
            }
            phase = .correcting(target: target, attempt: max(attempt, 1), last: current)
            return attempt == 0 ? .correct(target: target, attempt: 1) : .none
        case let .correcting(target, attempt, _):
            if Self.isElementTarget(target) {
                if Self.documentShown(target, in: current) {
                    phase = .confirming(target: target, attempt: attempt, current: current, last: current, afterGivingUp: false)
                    return .confirm(target: target)
                }
                phase = .correcting(target: target, attempt: attempt, last: current)
                return .none
            }
            if Self.shows(target, in: current) {
                phase = .anchored(current, target: target, failed: false)
                return .settled
            }
            // Input is disabled: this is the navigator still moving, not the reader.
            phase = .correcting(target: target, attempt: attempt, last: current)
            return .none
        case let .unanchored(target):
            if Self.isElementTarget(target), Self.documentShown(target, in: current) {
                phase = .confirming(target: target, attempt: 0, current: current, last: current, afterGivingUp: true)
                return .confirm(target: target)
            }
            let shown = Self.shows(target, in: current)
            phase = .anchored(current, target: target, failed: !shown)
            return shown ? .settled : .none
        case let .verifying(anchor, target, _):
            if Self.samePage(anchor, current) {
                // Back on the restored page before the answer: nothing has moved.
                phase = .anchored(anchor, target: target, failed: false)
                return .none
            }
            if Self.documentShown(target, in: current) {
                phase = .verifying(anchor: anchor, target: target, current: current)
                return .confirm(target: target)
            }
            phase = .reading
            return .record
        case let .anchored(anchor, target, failed):
            if Self.samePage(anchor, current) { return .none }
            if let target, Self.isElementTarget(target), !failed, Self.documentShown(target, in: current) {
                // The element was shown when asked; this report may be the same restore,
                // measured late. Ask again about this report before calling it reading.
                phase = .verifying(anchor: anchor, target: target, current: current)
                return .confirm(target: target)
            }
            if let target, !Self.isElementTarget(target), Self.shows(target, in: current) {
                // The saved place arrived late; still not reading.
                phase = .anchored(current, target: target, failed: false)
                return failed ? .settled : .none
            }
            phase = .reading
            return .record
        }
    }

    /// The app's answer to `.confirm` for the report `observation`: whether the saved
    /// element is on screen. An answer about an older report changes nothing.
    public mutating func elementShown(_ visible: Bool, for observation: ReadingObservation) -> Action {
        if case let .verifying(_, target, current) = phase {
            guard current == observation else { return .none }
            if visible {
                // The report the restore caused, measured after the page scrolled.
                phase = .anchored(current, target: target, failed: false)
                return .none
            }
            phase = .reading
            return .record
        }
        guard case let .confirming(target, attempt, current, _, afterGivingUp) = phase, current == observation else { return .none }
        if visible {
            phase = .anchored(current, target: target, failed: false)
            return .settled
        }
        if afterGivingUp {
            phase = .anchored(current, target: target, failed: true)
            return .none
        }
        if attempt == 0 {
            phase = .correcting(target: target, attempt: 1, last: current)
            return .correct(target: target, attempt: 1)
        }
        // Input is disabled and the jump is under way: wait for the next report or the timeout.
        phase = .correcting(target: target, attempt: attempt, last: current)
        return .none
    }

    /// The attempt's timeout elapsed without a report showing the saved place.
    public mutating func timedOut(attempt: Int) -> Action {
        if case let .confirming(target, current, observation, _, false) = phase, current == attempt, current > 0 {
            phase = .correcting(target: target, attempt: current, last: observation)
        }
        guard case let .correcting(target, current, last) = phase, current == attempt else { return .none }
        if attempt < Self.attempts {
            phase = .correcting(target: target, attempt: attempt + 1, last: last)
            return .correct(target: target, attempt: attempt + 1)
        }
        if let last {
            phase = .anchored(last, target: target, failed: true)
        } else {
            // Nothing was reported: the first report after this anchors.
            phase = .unanchored(target: target)
        }
        return .gaveUp
    }

    // MARK: Geometry

    /// A place that names an element and no progression, as a place reached by listening
    /// does: only the app can tell whether that element is on screen.
    public static func isElementTarget(_ target: JSONValue) -> Bool {
        guard target["locations"]?["progression"]?.doubleValue == nil,
              case let .array(fragments)? = target["locations"]?["fragments"],
              case let .string(first)? = fragments.first
        else { return false }
        return !first.isEmpty && !first.contains("=")
    }

    /// Whether the target's document is on screen at all.
    static func documentShown(_ target: JSONValue, in current: ReadingObservation) -> Bool {
        guard let href = target["href"]?.stringValue else { return false }
        if let viewport = current.viewport {
            return viewport.resources.contains { same($0.href, href) }
        }
        return current.locator["href"]?.stringValue.map { same($0, href) } ?? false
    }

    /// True when `current` puts `target` on screen: same resource, and the target's
    /// progression inside the measured visible range. Without a measured viewport only the
    /// exact place counts.
    public static func shows(_ target: JSONValue, in current: ReadingObservation) -> Bool {
        guard let href = target["href"]?.stringValue else { return false }
        let progression = target["locations"]?["progression"]?.doubleValue ?? 0
        if let viewport = current.viewport {
            return viewport.resources.contains { resource in
                same(resource.href, href) && within(progression, resource.progression)
            }
        }
        guard let shown = current.locator["href"]?.stringValue, same(shown, href) else { return false }
        let at = current.locator["locations"]?["progression"]?.doubleValue ?? 0
        return abs(at - progression) <= epsilon
    }

    /// Half-open, so a place exactly at a page boundary belongs to the page it starts,
    /// not the one before; the end of a resource is inclusive.
    static func within(_ progression: Double, _ range: ClosedRange<Double>) -> Bool {
        guard progression >= range.lowerBound - epsilon else { return false }
        if range.upperBound >= 1 - epsilon { return progression <= 1 + epsilon }
        return progression < range.upperBound - epsilon
    }

    /// Whether `current` reports the anchored page again, rather than another page.
    static func samePage(_ anchor: ReadingObservation, _ current: ReadingObservation) -> Bool {
        guard let href = current.locator["href"]?.stringValue,
              let anchored = anchor.locator["href"]?.stringValue,
              same(href, anchored)
        else { return false }
        let at = current.locator["locations"]?["progression"]?.doubleValue ?? 0
        let start = anchor.locator["locations"]?["progression"]?.doubleValue ?? 0
        // Readium initially reports an empty viewport before layout. Measuring the
        // same location afterwards is still restoration, not a page turn.
        if abs(at - start) <= epsilon { return true }
        if let range = anchor.viewport?.resources.first(where: { same($0.href, href) })?.progression {
            return within(at, range)
        }
        return false
    }

    /// Reading order hrefs compare without a leading slash, fragment, query or escaping.
    public static func same(_ a: String, _ b: String) -> Bool {
        normalized(a) == normalized(b)
    }

    private static func normalized(_ href: String) -> String {
        var path = Substring(href)
        if let cut = path.firstIndex(where: { $0 == "#" || $0 == "?" }) { path = path[..<cut] }
        let trimmed = String(path.drop { $0 == "/" })
        return trimmed.removingPercentEncoding ?? trimmed
    }
}

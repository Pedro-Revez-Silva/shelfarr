import Foundation
import os
import ShelfarrCore

/// How a reading place was restored, for the simulator smoke test only.
///
/// Exists only in Debug builds launched with the UI test argument, where the book is the
/// fixture server's synthetic EPUB. It records reading order paths, progressions and the
/// restoration's decisions, nothing else: no titles, text, server, account or credentials.
/// The reader shows it as a hidden accessibility element the test attaches, and it goes to
/// the unified log for the smoke script's device log.
@MainActor
final class RestoreTrace {
    private var lines: [String] = []
    private let logger = Logger(subsystem: "org.shelfarr.app", category: "reader-restore")

    static func make() -> RestoreTrace? {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains(UITestFixture.argument) ? RestoreTrace() : nil
        #else
        nil
        #endif
    }

    /// Adds a line and returns the trace so far.
    func note(_ line: String) -> String {
        lines.append(line)
        if lines.count > 60 { lines.removeFirst(lines.count - 60) }
        logger.notice("\(line, privacy: .public)")
        return lines.joined(separator: "\n")
    }

    static func describe(_ locator: JSONValue?) -> String {
        guard let locator else { return "beginning" }
        let href = locator["href"]?.stringValue.map(path) ?? "?"
        let progression = locator["locations"]?["progression"]?.doubleValue
        let total = locator["locations"]?["totalProgression"]?.doubleValue
        return "\(href)@\(number(progression)) total=\(number(total))"
    }

    static func describe(_ viewport: ReadingViewport?) -> String {
        guard let viewport else { return "none" }
        return viewport.resources
            .map { "\(path($0.href))[\(number($0.progression.lowerBound))...\(number($0.progression.upperBound))]" }
            .joined(separator: " ")
    }

    static func describe(_ action: ReadingRestoration.Action) -> String {
        switch action {
        case .none: return "none"
        case .record: return "record"
        case let .correct(_, attempt): return "correct#\(attempt)"
        case .settled: return "settled"
        case .gaveUp: return "gave-up"
        }
    }

    static func describe(_ action: PageRestoration.Action) -> String {
        switch action {
        case .none: return "none"
        case let .record(page): return "record \(page)"
        case let .correct(page): return "correct \(page)"
        case .settled: return "settled"
        case .gaveUp: return "gave-up"
        }
    }

    /// Only the file name of a reading order path.
    private static func path(_ href: String) -> String {
        let name = href.split(separator: "/").last.map(String.init) ?? href
        return String(name.prefix(48))
    }

    private static func number(_ value: Double?) -> String {
        value.map { String(format: "%.4f", $0) } ?? "-"
    }
}

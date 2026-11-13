import Foundation

/// Places in PDFs and comics: the page locators the server accepts and the checks a
/// reader applies before restoring one.
///
/// PDF: `{"href":"document.pdf","type":"application/pdf","locations":{"position":N,
/// "totalProgression":(N-1)/count,"fragments":["page=N"]}}`, N one-based.
///
/// CBZ: `href` and `type` of item N in this generation's reading order, `position` N and
/// `totalProgression` (N-1)/count. No fragments.
///
/// Neither carries a CFI or any other text position: an EPUB place never applies to a
/// page, and a page place never applies to another file.
public enum PageLocator {
    public static let pdfHref = "document.pdf"
    /// The server's bound on PDF pages.
    public static let maxPages = 100_000

    private static let locatorKeys: Set<String> = ["href", "type", "title", "text", "locations"]
    private static let locationKeys: Set<String> = ["position", "progression", "totalProgression", "fragments"]

    public static func pdf(page: Int, pageCount: Int) -> JSONValue {
        .object([
            "href": .string(pdfHref),
            "type": .string(ReaderFormat.pdfMediaType),
            "locations": .object([
                "position": .number(Double(page)),
                "totalProgression": .number(progression(page, pageCount)),
                "fragments": .array([.string("page=\(page)")]),
            ]),
        ])
    }

    /// The place of page `page` (one-based) of `order`. Nil when the order has no such page.
    public static func comic(page: Int, order: ReadingOrder) -> JSONValue? {
        guard order.items.indices.contains(page - 1) else { return nil }
        let item = order.items[page - 1]
        return .object([
            "href": .string(item.href),
            "type": .string(item.mediaType),
            "locations": .object([
                "position": .number(Double(page)),
                "totalProgression": .number(progression(page, order.items.count)),
            ]),
        ])
    }

    /// The page a saved PDF place names, when this document has it. Nil for anything this
    /// file can't show: another file's place, a text position, a fraction, a page past the end.
    public static func pdfPage(_ locator: JSONValue?, pageCount: Int) -> Int? {
        guard let (position, locations) = shape(locator, fragmentsAllowed: true),
              locator?["href"]?.stringValue == pdfHref,
              locator?["type"].map({ $0.stringValue == ReaderFormat.pdfMediaType }) ?? true,
              position <= pageCount
        else { return nil }
        if let fragments = locations["fragments"], fragments != .array([.string("page=\(position)")]) { return nil }
        return position
    }

    /// The page a saved comic place names, when it is exactly that page of this order.
    public static func comicPage(_ locator: JSONValue?, order: ReadingOrder) -> Int? {
        guard let (position, _) = shape(locator, fragmentsAllowed: false),
              order.items.indices.contains(position - 1)
        else { return nil }
        let item = order.items[position - 1]
        guard locator?["href"]?.stringValue == item.href,
              locator?["type"].map({ $0.stringValue == item.mediaType }) ?? true
        else { return nil }
        return position
    }

    /// The one-based page in `locations.position`, when the locator has only page-place keys.
    private static func shape(_ locator: JSONValue?, fragmentsAllowed: Bool) -> (Int, [String: JSONValue])? {
        guard case let .object(fields)? = locator, Set(fields.keys).isSubset(of: locatorKeys),
              case let .object(locations)? = fields["locations"], Set(locations.keys).isSubset(of: locationKeys),
              fragmentsAllowed || locations["fragments"] == nil,
              let value = locations["position"]?.doubleValue, value.rounded() == value,
              value >= 1, value <= Double(maxPages)
        else { return nil }
        for key in ["progression", "totalProgression"] {
            if let fraction = locations[key] {
                guard let number = fraction.doubleValue, (0 ... 1).contains(number) else { return nil }
            }
        }
        return (Int(value), locations)
    }

    private static func progression(_ page: Int, _ count: Int) -> Double {
        guard count > 1 else { return 0 }
        return min(1, max(0, Double(page - 1) / Double(count)))
    }
}

/// Tells a page reader settling on the restored page apart from the reader turning one.
///
/// Opening, restoring, rotating, zooming, re-rendering, decoding and changing between one
/// and two pages are not reading. The view reports what it shows whenever that changes or
/// is laid out again: the pages it is showing (`visible`, one page or a spread) and those
/// of them that are drawn (`displayed`). Images decode one at a time, so a spread can be
/// half drawn; a half that fails never draws.
///
/// The page being read is the anchor. It stays the anchor while it is visible, drawn yet
/// or not, so a new layout or a half-decoded spread never moves it. Only a report whose
/// visible pages leave the anchor is a turn, and the first drawn page becomes the one
/// saved: a page that is still loading, or failed, is never saved.
///
/// While a page is being restored, nothing is reading until the view shows it. Waiting is
/// bounded (a timeout, a page that can't be drawn, a view that won't go there): then input
/// is handed back, but the restore stays pending. A late report of the restored page
/// settles it silently, and the view drifting elsewhere on its own records nothing. Only
/// the reader asking for another page (`readerNavigates()`) ends the restore, and the
/// saved place moves when a page they reach is drawn.
public struct PageRestoration: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case none
        /// A real page turn: save this page.
        case record(Int)
        /// The view settled somewhere else while opening: go to this page again.
        case correct(Int)
        /// The opening page is on screen.
        case settled
        /// Stopped holding input for the opening page. It stays the saved place, and is
        /// still settled silently if it shows; only the reader turning moves the place.
        case gaveUp
    }

    public static let maxCorrections = 2

    /// The page being restored, until the view shows it or the reader turns away.
    public private(set) var target: Int?
    /// The page being read once restored: what the reader saves and comes back to.
    public private(set) var anchor: Int?
    /// Input was handed back while `target` is still pending.
    public private(set) var stalled = false
    private var corrections = 0

    public init(opening page: Int) {
        target = page
    }

    public var isRestoring: Bool { target != nil }

    /// One page, shown and drawn.
    public mutating func observe(_ page: Int) -> Action { observe(page ... page) }

    /// Pages shown and all drawn at once (a PDF page or spread).
    public mutating func observe(_ pages: ClosedRange<Int>) -> Action { observe(visible: pages, displayed: pages) }

    /// What the view shows, and the part of it that is drawn (nil while none is).
    public mutating func observe(visible: ClosedRange<Int>, displayed: ClosedRange<Int>?) -> Action {
        if let target {
            if displayed?.contains(target) == true {
                // On time or late, the restored page is on screen: nothing was read.
                self.target = nil
                anchor = target
                stalled = false
                return .settled
            }
            // Still at the restored page (loading, or its other half drawn first), or no
            // longer holding input: the view moving on its own is not the reader turning.
            if visible.contains(target) || stalled { return .none }
            // An empty view elsewhere is a layout pass, not the view settling there.
            guard displayed != nil else { return .none }
            guard corrections < Self.maxCorrections else {
                stalled = true
                return .gaveUp
            }
            corrections += 1
            return .correct(target)
        }
        if let anchor, visible.contains(anchor) { return .none }
        guard let displayed else { return .none }
        anchor = displayed.lowerBound
        return .record(displayed.lowerBound)
    }

    /// The opening page took too long to show: hand input back. It stays pending, so its
    /// late arrival is still not reading.
    public mutating func timedOut() -> Action {
        guard target != nil, !stalled else { return .none }
        stalled = true
        return .gaveUp
    }

    /// A page couldn't be drawn. When it is the one being restored, stop holding input for
    /// it; the saved place stays, and its other half drawing is still not a turn.
    public mutating func couldNotShow(_ page: Int) -> Action {
        guard page == target, !stalled else { return .none }
        stalled = true
        return .gaveUp
    }

    /// The reader asked for a page (a tap, swipe, key, VoiceOver, the controls). While
    /// restoring, the restored page stays the anchor, and the next drawn page elsewhere is
    /// a turn. True when this ended a restore.
    @discardableResult
    public mutating func readerNavigates() -> Bool {
        guard let target else { return false }
        anchor = target
        self.target = nil
        stalled = false
        corrections = 0
        return true
    }

    /// Going to a chosen saved place (another device's) is restoring too, not reading.
    public mutating func reopen(at page: Int) -> Action {
        target = page
        corrections = 0
        stalled = false
        return .correct(page)
    }
}

/// Pages grouped for display: one at a time, or as two-page spreads with the first page
/// (the cover) on its own, as printed books and comics are bound. Purely a layout: which
/// spread shows never changes the page being read.
public enum PageSpreads {
    public static func layout(pageCount: Int, paired: Bool) -> [ClosedRange<Int>] {
        guard pageCount > 0 else { return [] }
        guard paired, pageCount > 1 else { return (1 ... pageCount).map { $0 ... $0 } }
        var spreads: [ClosedRange<Int>] = [1 ... 1]
        var page = 2
        while page <= pageCount {
            spreads.append(page ... min(page + 1, pageCount))
            page += 2
        }
        return spreads
    }

    /// The index of the spread showing `page`, clamped to the layout.
    public static func index(of page: Int, in spreads: [ClosedRange<Int>]) -> Int {
        guard let last = spreads.indices.last else { return 0 }
        return spreads.firstIndex { $0.contains(page) } ?? (page < 1 ? 0 : last)
    }
}

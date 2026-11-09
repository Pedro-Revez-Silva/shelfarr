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
/// Opening, restoring, rotating, zooming, re-rendering and changing between one and two
/// pages are not reading. The view reports the page it shows whenever it changes or is
/// laid out again; only a report of a page other than the one already shown, after the
/// opening page has been seen, is a page turn to save.
public struct PageRestoration: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case none
        /// A real page turn: save this page.
        case record(Int)
        /// The view settled somewhere else while opening: go to this page again.
        case correct(Int)
        /// The opening page is on screen.
        case settled
        /// The opening page could not be shown; reading carries on from where the view is.
        case gaveUp
    }

    public static let maxCorrections = 2

    /// The page being restored, until the view shows it.
    public private(set) var target: Int?
    /// The page on screen once restored.
    public private(set) var shown: Int?
    private var corrections = 0

    public init(opening page: Int) {
        target = page
    }

    public var isRestoring: Bool { target != nil }

    public mutating func observe(_ page: Int) -> Action {
        if let target {
            if page == target {
                self.target = nil
                shown = page
                return .settled
            }
            guard corrections < Self.maxCorrections else {
                self.target = nil
                shown = page
                return .gaveUp
            }
            corrections += 1
            return .correct(target)
        }
        guard page != shown else { return .none }
        shown = page
        return .record(page)
    }

    /// Going to a chosen saved place (another device's) is restoring too, not reading.
    public mutating func reopen(at page: Int) -> Action {
        target = page
        corrections = 0
        return .correct(page)
    }
}

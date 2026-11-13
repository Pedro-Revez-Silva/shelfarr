import Foundation

/// A page reader's saved place: what the view reports, decided by `PageRestoration`, and
/// the place and activity time to write when that is reading.
///
/// The PDF and comic readers hand every report here and write exactly the `Save` it
/// returns to `ProgressSync.update`, with the time captured when the view reported the
/// page, before anything waited. Restoring, a timeout, a layout, a half-drawn spread and a
/// failed page return no save, so they never change the place or its time.
public struct PageCursor: Equatable, Sendable {
    /// The file's pages, which name the places.
    public enum Pages: Equatable, Sendable {
        case pdf(count: Int)
        case comic(ReadingOrder)

        public var count: Int {
            switch self {
            case let .pdf(count): return count
            case let .comic(order): return order.items.count
            }
        }

        /// The place of `page` in this file. Nil when the file has no such page.
        public func locator(_ page: Int) -> JSONValue? {
            switch self {
            case let .pdf(count): return count > 0 && (1 ... count).contains(page) ? PageLocator.pdf(page: page, pageCount: count) : nil
            case let .comic(order): return PageLocator.comic(page: page, order: order)
            }
        }

        /// The page a saved place names in this file, when it is one of its pages.
        public func page(_ locator: JSONValue?) -> Int? {
            switch self {
            case let .pdf(count): return PageLocator.pdfPage(locator, pageCount: count)
            case let .comic(order): return PageLocator.comicPage(locator, order: order)
            }
        }
    }

    /// A page the reader reached, and when it was drawn.
    public struct Save: Equatable, Sendable {
        public let page: Int
        public let position: SavedPosition
        public let observedAt: Int64
    }

    public struct Outcome: Equatable, Sendable {
        public let action: PageRestoration.Action
        /// Set only for a real turn.
        public let save: Save?
    }

    public let assetId: String
    public let pages: Pages
    public private(set) var restoration: PageRestoration

    public init(assetId: String, pages: Pages, opening page: Int) {
        self.assetId = assetId
        self.pages = pages
        restoration = PageRestoration(opening: page)
    }

    public var isRestoring: Bool { restoration.isRestoring }

    /// The view shows `visible`, of which `displayed` is drawn, reported at `observedAt`.
    public mutating func shows(visible: ClosedRange<Int>, displayed: ClosedRange<Int>?, observedAt: Int64) -> Outcome {
        let action = restoration.observe(visible: visible, displayed: displayed)
        guard case let .record(page) = action, let locator = pages.locator(page) else {
            return Outcome(action: action, save: nil)
        }
        let position = SavedPosition(assetId: assetId, locator: locator)
        return Outcome(action: action, save: Save(page: page, position: position, observedAt: observedAt))
    }

    public mutating func timedOut() -> PageRestoration.Action { restoration.timedOut() }

    public mutating func couldNotShow(_ page: Int) -> PageRestoration.Action { restoration.couldNotShow(page) }

    @discardableResult
    public mutating func readerNavigates() -> Bool { restoration.readerNavigates() }

    public mutating func reopen(at page: Int) -> PageRestoration.Action { restoration.reopen(at: page) }
}

import Foundation
import ReadiumNavigator
import ReadiumShared
import ReadiumStreamer
import UIKit

/// One entry of the flattened table of contents.
struct ContentsEntry: Identifiable {
    let id: Int
    let title: String
    let depth: Int
    fileprivate let link: ReadiumShared.Link
}

/// A reading order resource on screen, and the part of its progression (0–1) visible.
struct VisibleResource {
    let href: String
    let from: Double
    let to: Double
}

/// A place reported by the navigator, in plain values.
struct ReadingLocation {
    let locatorJSON: String
    let fraction: Double
    let position: Int?
    let chapter: String?
    /// What the navigator measured on screen with this report; nil when it had not.
    let visible: [VisibleResource]?
}

extension FontFamily {
    static let newsreader: FontFamily = "Newsreader"
}

/// The only file that touches Readium. Its `Publication`, `Link`, `Color` and
/// `JSONValue` would otherwise collide with the app's own and SwiftUI's types.
@MainActor
final class ReadiumBook: NSObject {
    private let publication: ReadiumShared.Publication
    private var navigator: EPUBNavigatorViewController?
    private var adapter: DirectionalNavigationAdapter?
    private var onLocation: ((ReadingLocation) -> Void)?

    private(set) var contents: [ContentsEntry] = []
    private(set) var positionCount = 0
    /// Reading order hrefs (archive paths), in spine order.
    private(set) var spine: [String] = []
    /// Where each reading order resource starts in the whole book (0–1), from Readium's positions.
    private var resourceStarts: [String: Double] = [:]
    private static let readAlongGroup = "read-along"

    private init(publication: ReadiumShared.Publication) {
        self.publication = publication
    }

    /// Opens a local EPUB. Fails for unreadable files; no DRM is supported.
    static func open(file: URL) async -> ReadiumBook? {
        let http = DefaultHTTPClient()
        let retriever = AssetRetriever(httpClient: http)
        let opener = PublicationOpener(parser: DefaultPublicationParser(
            httpClient: http,
            assetRetriever: retriever,
            pdfFactory: DefaultPDFDocumentFactory()
        ))
        guard let url = file.anyURL.absoluteURL,
              case let .success(asset) = await retriever.retrieve(url: url),
              case let .success(publication) = await opener.open(asset: asset, allowUserInteraction: false)
        else { return nil }

        let book = ReadiumBook(publication: publication)
        if case let .success(links) = await publication.tableOfContents() {
            book.contents = book.flatten(links, depth: 0)
        }
        if case let .success(positions) = await publication.positions() {
            book.positionCount = positions.count
            for locator in positions where book.resourceStarts[locator.href.string] == nil {
                book.resourceStarts[locator.href.string] = locator.locations.totalProgression
            }
        }
        book.spine = publication.readingOrder.map(\.href)
        return book
    }

    private func flatten(_ links: [ReadiumShared.Link], depth: Int) -> [ContentsEntry] {
        links.flatMap { link -> [ContentsEntry] in
            let title = link.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
            return [ContentsEntry(id: contentsCounter(), title: title, depth: depth, link: link)]
                + flatten(link.children, depth: depth + 1)
        }
    }

    private var nextContentsId = 0

    private func contentsCounter() -> Int {
        nextContentsId += 1
        return nextContentsId
    }

    /// Builds the navigator at `locatorJSON`, or the beginning when nil.
    func makeNavigator(
        locatorJSON: String?,
        settings: ReaderSettings,
        onLocation: @escaping (ReadingLocation) -> Void,
        onTap: @escaping () -> Void
    ) throws -> UIViewController {
        self.onLocation = onLocation
        let start = locatorJSON.flatMap { Self.locator(json: $0) }
        let fonts = Bundle.main.resourceURL.flatMap { FileURL(url: $0) }
        let declarations: [AnyHTMLFontFamilyDeclaration] = fonts.map { base in
            [
                CSSFontFamilyDeclaration(
                    fontFamily: .newsreader,
                    fontFaces: [
                        CSSFontFace(file: base.appendingPath("fonts/Newsreader-Regular.ttf", isDirectory: false), style: .normal, weight: .standard(.normal)),
                        CSSFontFace(file: base.appendingPath("fonts/Newsreader-Italic.ttf", isDirectory: false), style: .italic, weight: .standard(.normal)),
                        CSSFontFace(file: base.appendingPath("fonts/Newsreader-SemiBold.ttf", isDirectory: false), style: .normal, weight: .standard(.bold)),
                    ]
                ).eraseToAnyHTMLFontFamilyDeclaration(),
            ]
        } ?? []

        let navigator = try EPUBNavigatorViewController(
            publication: publication,
            initialLocation: start,
            config: EPUBNavigatorViewController.Configuration(
                preferences: Self.preferences(settings),
                fontFamilyDeclarations: declarations
            )
        )
        navigator.delegate = self

        let adapter = DirectionalNavigationAdapter(pointerPolicy: .init(types: [.mouse, .touch]), animatedTransition: true)
        adapter.bind(to: navigator)
        self.adapter = adapter
        navigator.addObserver(.activate { _ in
            onTap()
            return true
        })
        self.navigator = navigator
        return navigator
    }

    func apply(_ settings: ReaderSettings) {
        navigator?.submitPreferences(Self.preferences(settings))
    }

    func go(to entry: ContentsEntry) {
        Task { _ = await navigator?.go(to: entry.link) }
    }

    func go(toFraction fraction: Double) {
        Task {
            guard let locator = await publication.locate(progression: fraction) else { return }
            _ = await navigator?.go(to: locator)
        }
    }

    /// Sends the navigator to a saved place. True when the jump was accepted; that is not
    /// proof it settled there, which only a later location report shows.
    func go(toLocatorJSON json: String) async -> Bool {
        guard let navigator, let locator = Self.locator(json: json) else { return false }
        return await navigator.go(to: locator, options: .none)
    }

    /// Asks Readium to measure the page it shows now and report it if that is new.
    ///
    /// Readium 3.11 reports a place only after its page script posts `progressionChanged`,
    /// which it does on a scroll or resize event, never while the document has no width,
    /// and the native side ignores it until the resource counts as loaded. A jump to the
    /// offset the page already shows scrolls nothing, so it reports nothing: a hosted cold
    /// offline open drew the saved page while Readium had only reported an empty viewport
    /// at 0%, and both corrective jumps were accepted without a report. Running Readium's
    /// own scroll handler makes it measure and report the page as it is.
    func remeasure() async {
        guard let navigator else { return }
        _ = await navigator.evaluateJavaScript("window.dispatchEvent(new Event('scroll')); true")
    }

    /// Page turns, taps and selection on the book, off while it is being sent back to the
    /// saved place.
    func setInputEnabled(_ enabled: Bool) {
        navigator?.view.isUserInteractionEnabled = enabled
    }

    // MARK: Read-along

    /// Where a reading order resource starts in the book, as Readium measured it.
    func startProgression(ofHref href: String) -> Double? {
        if let exact = resourceStarts[href] { return exact }
        return resourceStarts.first { Self.sameHref($0.key, href) }?.value
    }

    /// The href of the resource on screen now.
    var currentHref: String? {
        navigator?.currentLocation?.href.string
    }

    /// Highlights exactly one element (the cue being heard) with a Readium decoration, or
    /// clears it with nil. Decorations follow the element across pages and layouts.
    func highlight(href: String?, fragment: String?, tint: UIColor) {
        guard let navigator else { return }
        guard let href, let fragment, let locator = Self.elementLocator(href: href, fragment: fragment) else {
            navigator.apply(decorations: [], in: Self.readAlongGroup)
            return
        }
        let decoration = Decoration(id: "read-along-cue", locator: locator, style: .highlight(tint: tint, isActive: false))
        navigator.apply(decorations: [decoration], in: Self.readAlongGroup)
    }

    /// Whether the start of element `fragment` of `href` is on screen. Nil when that
    /// document isn't the one shown, or the page couldn't answer.
    func isElementVisible(href: String, fragment: String) async -> Bool? {
        guard let navigator, let current = currentHref, Self.sameHref(current, href) else { return currentHref == nil ? nil : false }
        let script = """
        (function (id) {
          var element = document.getElementById(id);
          if (!element) { return "missing"; }
          var rects = element.getClientRects();
          var first = rects.length ? rects[0] : element.getBoundingClientRect();
          var width = window.innerWidth, height = window.innerHeight;
          return (first.left >= -1 && first.left < width - 1 && first.top >= -1 && first.top < height - 1) ? "visible" : "hidden";
        })(\(Self.jsString(fragment)))
        """
        guard case let .success(value) = await navigator.evaluateJavaScript(script), let answer = value as? String else { return nil }
        return answer == "visible"
    }

    /// Of `fragments` (one document's cue elements in reading order), the first that
    /// starts on the page shown, else the last that started before it (the narration the
    /// page continues). Nil when the page shows another document or none of them.
    func firstVisibleElement(href: String, fragments: [String]) async -> String? {
        guard let navigator, !fragments.isEmpty, let current = currentHref, Self.sameHref(current, href),
              let ids = String(data: (try? JSONEncoder().encode(fragments)) ?? Data(), encoding: .utf8)
        else { return nil }
        let script = """
        (function (ids) {
          var width = window.innerWidth, height = window.innerHeight, before = null;
          for (var i = 0; i < ids.length; i++) {
            var element = document.getElementById(ids[i]);
            if (!element) { continue; }
            var rects = element.getClientRects();
            if (!rects.length) { continue; }
            var first = rects[0];
            if (first.left >= -1 && first.left < width - 1 && first.top >= -1 && first.top < height - 1) { return ids[i]; }
            if (first.left < -1 || first.top < -1) { before = ids[i]; }
          }
          return before;
        })(\(ids))
        """
        guard case let .success(value) = await navigator.evaluateJavaScript(script) else { return nil }
        return value as? String
    }

    /// Brings element `fragment` of `href` into view: Readium scrolls to the element's page.
    /// Display only; the reader treats the report it causes as not reading.
    func go(toElement fragment: String, href: String, animated: Bool) async -> Bool {
        guard let navigator, let locator = Self.elementLocator(href: href, fragment: fragment) else { return false }
        return await navigator.go(to: locator, options: NavigatorGoOptions(animated: animated))
    }

    private static func elementLocator(href: String, fragment: String) -> ReadiumShared.Locator? {
        let value: [String: Any] = ["href": href, "type": "application/xhtml+xml", "locations": ["fragments": [fragment]]]
        guard let data = try? JSONSerialization.data(withJSONObject: value), let json = String(data: data, encoding: .utf8) else { return nil }
        return locator(json: json)
    }

    /// Reading order hrefs compare without a leading slash, fragment, query or escaping
    /// (as `ReadingRestoration.same` does).
    static func sameHref(_ a: String, _ b: String) -> Bool {
        func normalized(_ href: String) -> String {
            var path = Substring(href)
            if let cut = path.firstIndex(where: { $0 == "#" || $0 == "?" }) { path = path[..<cut] }
            let trimmed = String(path.drop { $0 == "/" })
            return trimmed.removingPercentEncoding ?? trimmed
        }
        return normalized(a) == normalized(b)
    }

    /// A JavaScript string literal for any text.
    private static func jsString(_ text: String) -> String {
        let data = (try? JSONEncoder().encode([text])) ?? Data("[\"\"]".utf8)
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    private static func locator(json: String) -> ReadiumShared.Locator? {
        guard let value = try? ReadiumShared.JSONValue(jsonString: json, warnings: nil) else { return nil }
        return (try? ReadiumShared.Locator(json: value, warnings: nil)).flatMap { $0 }
    }

    private static func preferences(_ settings: ReaderSettings) -> EPUBPreferences {
        let original = settings.font == .original
        let family: FontFamily?
        switch settings.font {
        case .newsreader: family = .newsreader
        case .sans: family = .sansSerif
        case .original: family = nil
        }
        let theme: Theme
        switch settings.theme {
        case .paper: theme = .light
        case .sepia: theme = .sepia
        case .night: theme = .dark
        }
        return EPUBPreferences(
            backgroundColor: ReadiumNavigator.Color(hex: String(format: "#%06X", settings.theme.pageHex)),
            fontFamily: family,
            fontSize: settings.fontSize,
            hyphens: original ? nil : settings.justify,
            imageFilter: settings.theme == .night ? .darken : nil,
            lineHeight: original ? nil : settings.lineHeight,
            pageMargins: settings.margins,
            publisherStyles: original,
            scroll: settings.scroll,
            textAlign: original ? nil : (settings.justify ? .justify : .start),
            textColor: ReadiumNavigator.Color(hex: String(format: "#%06X", settings.theme.textHex)),
            theme: theme
        )
    }
}

extension ReadiumBook: EPUBNavigatorDelegate {
    func navigator(_ navigator: Navigator, locationDidChange locator: ReadiumShared.Locator) {
        guard let json = try? locator.jsonString() else { return }
        // Readium 3.11 assigns the viewport in the same step, just before this callback,
        // so it measures the page this locator reports. The locator alone carries no
        // proof of where the page settled.
        let viewport = (navigator as? ViewportObservingNavigator)?.viewport
        onLocation?(ReadingLocation(
            locatorJSON: json,
            fraction: locator.locations.totalProgression ?? locator.locations.progression ?? 0,
            position: locator.locations.position,
            chapter: locator.title,
            visible: viewport.map { viewport in
                viewport.resources.map {
                    VisibleResource(href: $0.href.string, from: $0.progression.lowerBound, to: $0.progression.upperBound)
                }
            }
        ))
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {}
}

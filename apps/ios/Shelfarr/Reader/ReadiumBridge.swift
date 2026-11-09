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
        }
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

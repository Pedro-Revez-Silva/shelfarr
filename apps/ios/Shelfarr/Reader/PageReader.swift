import ImageIO
import PDFKit
import ShelfarrCore
import UIKit

/// How fixed pages are laid out. Display preferences only: changing them is never reading.
struct PageLayout: Codable, Equatable {
    enum Fit: String, Codable, CaseIterable, Identifiable {
        case page, width
        var id: String { rawValue }
        var label: String { self == .page ? "Whole page" : "Page width" }
    }

    var fit = Fit.page
    /// Manga and other right-to-left books. Chosen per book, never guessed.
    var rightToLeft = false
    /// Two pages side by side when the reader is wide enough (iPad landscape).
    var spreads = false
}

@MainActor
protocol PageReaderDelegate: AnyObject {
    /// The pages actually displayed after a turn, a jump or a new layout. Only the model
    /// decides whether that is reading. A page still loading, or one that failed, is
    /// never reported here.
    func pageReader(_ reader: PageReaderController, shows displayed: ClosedRange<Int>)
    /// A page the reader navigated to couldn't be drawn. It must never become the saved place.
    func pageReader(_ reader: PageReaderController, couldNotShow page: Int)
    /// Where the reader is now, displayed or not: for the page number and slider.
    func pageReader(_ reader: PageReaderController, navigatedTo page: Int)
    func pageReaderToggleControls(_ reader: PageReaderController)
}

/// A full-screen page reader: a PDF or a comic. Taps on the outer quarters and swipes
/// turn pages in the reading direction, a tap in the middle shows or hides the controls,
/// pinch and double tap zoom, and hardware keys turn pages. Input is off while the saved
/// page is being restored.
@MainActor
class PageReaderController: UIViewController {
    weak var delegate: PageReaderDelegate?
    let pageCount: Int
    var layout: PageLayout {
        didSet { if layout != oldValue { layoutChanged() } }
    }
    var theme: ReaderTheme {
        didSet { view.backgroundColor = UIColor(hex: theme.pageHex) }
    }
    /// The navigation target: the page the reader is on, kept on screen when the layout
    /// changes. It moves past a page that can't be drawn; the saved place doesn't.
    var anchor: Int
    private(set) var inputEnabled = true

    init(pageCount: Int, opening page: Int, layout: PageLayout, theme: ReaderTheme) {
        self.pageCount = pageCount
        anchor = min(max(page, 1), max(pageCount, 1))
        self.layout = layout
        self.theme = theme
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(hex: theme.pageHex)
        view.accessibilityIdentifier = "page-reader"
        view.isUserInteractionEnabled = inputEnabled
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    /// Spreads only when asked for and the reader is wide: iPad in landscape.
    var spreadsActive: Bool {
        layout.spreads && view.bounds.width > view.bounds.height && traitCollection.horizontalSizeClass == .regular
    }

    // MARK: For subclasses

    func go(to page: Int, animated: Bool) {}
    func turn(forward: Bool) {}
    var visiblePages: ClosedRange<Int> { anchor ... anchor }
    /// The visible pages that are drawn; nil while none is.
    var displayedPages: ClosedRange<Int>? { visiblePages }
    func layoutChanged() {}

    func setInputEnabled(_ enabled: Bool) {
        inputEnabled = enabled
        if isViewLoaded { view.isUserInteractionEnabled = enabled }
    }

    /// The screen's left or right edge, mapped to the reading direction.
    func turn(towardsRight: Bool) {
        turn(forward: towardsRight != layout.rightToLeft)
    }

    /// Moves the navigation target with what is on screen, then reports what is drawn.
    func report() {
        let visible = visiblePages
        if !visible.contains(anchor) { anchor = visible.lowerBound }
        delegate?.pageReader(self, navigatedTo: anchor)
        if let displayed = displayedPages { delegate?.pageReader(self, shows: displayed) }
    }

    /// Edge taps turn; a tap in the middle toggles the controls.
    func handleTap(at x: CGFloat, width: CGFloat) {
        guard inputEnabled, width > 0 else { return }
        let fraction = x / width
        if fraction < 0.25 {
            turn(towardsRight: false)
        } else if fraction > 0.75 {
            turn(towardsRight: true)
        } else {
            delegate?.pageReaderToggleControls(self)
        }
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(keyRight)),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(keyLeft)),
            UIKeyCommand(input: UIKeyCommand.inputPageDown, modifierFlags: [], action: #selector(keyNext)),
            UIKeyCommand(input: UIKeyCommand.inputPageUp, modifierFlags: [], action: #selector(keyPrevious)),
            UIKeyCommand(input: " ", modifierFlags: [], action: #selector(keyNext)),
            UIKeyCommand(input: " ", modifierFlags: .shift, action: #selector(keyPrevious)),
        ]
        for command in commands { command.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    @objc private func keyRight() { if inputEnabled { turn(towardsRight: true) } }
    @objc private func keyLeft() { if inputEnabled { turn(towardsRight: false) } }
    @objc private func keyNext() { if inputEnabled { turn(forward: true) } }
    @objc private func keyPrevious() { if inputEnabled { turn(forward: false) } }

    // MARK: Accessibility

    /// VoiceOver: next and previous page, and the controls, as actions; three-finger
    /// swipes scroll by page.
    func accessibilityActions() -> [UIAccessibilityCustomAction] {
        [
            UIAccessibilityCustomAction(name: "Next page") { [weak self] _ in
                self?.turn(forward: true)
                return true
            },
            UIAccessibilityCustomAction(name: "Previous page") { [weak self] _ in
                self?.turn(forward: false)
                return true
            },
            UIAccessibilityCustomAction(name: "Show reading controls") { [weak self] _ in
                guard let self else { return false }
                self.delegate?.pageReaderToggleControls(self)
                return true
            },
        ]
    }

    func pageDescription(_ pages: ClosedRange<Int>) -> String {
        pages.count > 1
            ? "Pages \(pages.lowerBound) and \(pages.upperBound) of \(pageCount)"
            : "Page \(pages.lowerBound) of \(pageCount)"
    }
}

// MARK: - PDF

/// A PDF drawn by PDFKit, one page (or a spread) at a time, with its own text selection.
///
/// Nothing in the file can act on its own: links to anything but another page of the
/// same document, launch and remote actions are removed from each page before it is
/// shown, form fields are read-only and their actions dropped, and the delegate refuses
/// any URL a link still asks to open. PDFKit runs no document JavaScript.
final class PDFPageReader: PageReaderController, PDFViewDelegate, UIGestureRecognizerDelegate {
    private let document: PDFDocument
    private let pdfView = PDFView()
    private var sanitized: Set<Int> = []
    private var lastSize: CGSize = .zero
    private var lastSpreads: Bool?
    private var observers: [NSObjectProtocol] = []
    /// The scale the current fit rests at; above it the page is zoomed and swipes pan.
    private var restingScale: CGFloat = 0

    init(document: PDFDocument, opening page: Int, layout: PageLayout, theme: ReaderTheme) {
        self.document = document
        super.init(pageCount: document.pageCount, opening: page, layout: layout, theme: theme)
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        pdfView.frame = view.bounds
        pdfView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pdfView.backgroundColor = UIColor(hex: theme.pageHex)
        pdfView.displayDirection = .horizontal
        pdfView.displaysPageBreaks = true
        pdfView.displaysAsBook = true
        pdfView.pageShadowsEnabled = false
        pdfView.delegate = self
        applyDisplayMode()
        sanitize(around: anchor)
        pdfView.document = document
        view.addSubview(pdfView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        pdfView.addGestureRecognizer(tap)
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            swipe.delegate = self
            pdfView.addGestureRecognizer(swipe)
        }
        pdfView.isAccessibilityElement = false
        pdfView.accessibilityCustomActions = accessibilityActions()

        let center = NotificationCenter.default
        for name in [Notification.Name.PDFViewPageChanged, .PDFViewVisiblePagesChanged] {
            observers.append(center.addObserver(forName: name, object: pdfView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pagesChanged() }
            })
        }
        if let page = document.page(at: anchor - 1) { pdfView.go(to: page) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // A double tap is PDFKit's zoom; a single tap waits for it so it doesn't toggle twice.
        let tap = pdfView.gestureRecognizers?.first { $0 is UITapGestureRecognizer && $0.delegate === self }
        for recognizer in Self.recognizers(in: pdfView) where recognizer !== tap {
            if let double = recognizer as? UITapGestureRecognizer, double.numberOfTapsRequired == 2 {
                tap?.require(toFail: double)
            }
        }
        report()
    }

    private static func recognizers(in view: UIView) -> [UIGestureRecognizer] {
        (view.gestureRecognizers ?? []) + view.subviews.flatMap(recognizers)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.size != lastSize else { return }
        lastSize = view.bounds.size
        // Rotation or resizing refits the page being read. It is not a page turn.
        applyDisplayMode()
        applyFit()
        if let page = document.page(at: anchor - 1), !visiblePages.contains(anchor) { pdfView.go(to: page) }
    }

    override func layoutChanged() {
        pdfView.displaysRTL = layout.rightToLeft
        applyDisplayMode()
        applyFit()
        if let page = document.page(at: anchor - 1) { pdfView.go(to: page) }
        DispatchQueue.main.async { [weak self] in self?.report() }
    }

    override var theme: ReaderTheme {
        didSet { pdfView.backgroundColor = UIColor(hex: theme.pageHex) }
    }

    private func applyDisplayMode() {
        let spreads = spreadsActive
        guard spreads != lastSpreads else { return }
        lastSpreads = spreads
        pdfView.displaysRTL = layout.rightToLeft
        pdfView.displayMode = spreads ? .twoUp : .singlePage
    }

    private func applyFit() {
        guard pdfView.bounds.width > 0 else { return }
        pdfView.autoScales = true
        let fitPage = pdfView.scaleFactorForSizeToFit
        guard fitPage > 0 else { return }
        pdfView.minScaleFactor = fitPage
        pdfView.maxScaleFactor = fitPage * 5
        restingScale = fitPage
        if layout.fit == .width, let page = document.page(at: anchor - 1) {
            let box = page.bounds(for: pdfView.displayBox)
            let width = page.rotation % 180 == 0 ? box.width : box.height
            let across = width * (spreadsActive ? 2 : 1)
            if across > 0 {
                pdfView.autoScales = false
                pdfView.scaleFactor = min(pdfView.maxScaleFactor, max(fitPage, pdfView.bounds.width / across))
                restingScale = pdfView.scaleFactor
            }
        }
    }

    private var atFitScale: Bool {
        restingScale <= 0 || pdfView.scaleFactor <= restingScale * 1.02
    }

    // MARK: Pages

    override var visiblePages: ClosedRange<Int> {
        var indexes = pdfView.visiblePages.map { document.index(for: $0) + 1 }
        if let current = pdfView.currentPage { indexes.append(document.index(for: current) + 1) }
        let valid = indexes.filter { (1 ... pageCount).contains($0) }
        guard let low = valid.min(), let high = valid.max() else { return anchor ... anchor }
        return low ... high
    }

    override func go(to page: Int, animated: Bool) {
        let target = min(max(page, 1), pageCount)
        guard let destination = document.page(at: target - 1) else { return }
        anchor = target
        sanitize(around: target)
        if animated {
            UIView.transition(with: pdfView, duration: 0.15, options: .transitionCrossDissolve) {
                self.pdfView.go(to: destination)
            }
        } else {
            pdfView.go(to: destination)
        }
        // PDFKit posts no change for the page already shown: report what's there either way.
        DispatchQueue.main.async { [weak self] in self?.report() }
    }

    override func turn(forward: Bool) {
        let shown = visiblePages
        let target = forward ? shown.upperBound + 1 : shown.lowerBound - (spreadsActive ? 2 : 1)
        guard (1 ... pageCount).contains(target) || (!forward && shown.lowerBound > 1) else { return }
        go(to: max(1, target), animated: true)
    }

    private func pagesChanged() {
        sanitize(around: visiblePages.lowerBound)
        report()
        UIAccessibility.post(notification: .pageScrolled, argument: pageDescription(visiblePages))
    }

    /// Strips what could act without the reader: external and launch links, remote
    /// go-to actions, form actions. Pages are sanitized just before they can be shown.
    private func sanitize(around page: Int) {
        for index in max(0, page - 3) ..< min(pageCount, page + 3) where !sanitized.contains(index) {
            sanitized.insert(index)
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                let kind = (annotation.type ?? "").lowercased()
                // A link to another page of this document, by action or by destination.
                let internalLink = annotation.url == nil
                    && (annotation.action is PDFActionGoTo || (annotation.action == nil && annotation.destination != nil))
                if kind.contains("widget") {
                    annotation.isReadOnly = true
                    annotation.action = nil
                } else if kind.contains("link"), !internalLink {
                    page.removeAnnotation(annotation)
                } else if annotation.action != nil, !internalLink {
                    annotation.action = nil
                }
            }
        }
    }

    // MARK: Gestures

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: pdfView)
        // A tap that ends a text selection, or lands on an internal link, is PDFKit's.
        if let selection = pdfView.currentSelection, !(selection.string ?? "").isEmpty { return }
        if let page = pdfView.page(for: point, nearest: false),
           let link = page.annotation(at: pdfView.convert(point, to: page)),
           link.action != nil || link.destination != nil {
            return
        }
        handleTap(at: point.x, width: pdfView.bounds.width)
    }

    @objc private func swiped(_ recognizer: UISwipeGestureRecognizer) {
        guard inputEnabled, atFitScale else { return }
        // A finger moving left brings in the page on the right.
        turn(towardsRight: recognizer.direction == .left)
    }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    // MARK: PDFViewDelegate

    /// Implementing this keeps PDFKit from opening the URL itself. Nothing leaves the reader.
    nonisolated func pdfViewWillClick(onLink sender: PDFView, with url: URL) {}
}

/// Opens a PDF off the main thread. Nil when PDFKit can't read it.
enum PDFLoader {
    private final class Box: @unchecked Sendable {
        let document: PDFDocument?
        init(_ document: PDFDocument?) { self.document = document }
    }

    static func load(_ file: URL) async -> PDFDocument? {
        await Task.detached(priority: .userInitiated) { Box(PDFDocument(url: file)) }.value.document
    }
}

// MARK: - Comics

/// Decodes one comic page at a time from the verified archive on this device.
///
/// Pages come out of `ComicArchive`, which inflates only up to the declared size and
/// checks the CRC and image header first. ImageIO then decodes straight to the size
/// the screen needs (`kCGImageSourceThumbnailMaxPixelSize`), so a large scan never sits
/// in memory at full size. Decoding is serial, and decoded pages are cached up to a
/// bounded cost.
final class ComicPageLoader: @unchecked Sendable {
    private let archive: ComicArchive
    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "org.shelfarr.comic-pages", qos: .userInitiated)

    init(archive: ComicArchive) {
        self.archive = archive
        let memory = ProcessInfo.processInfo.physicalMemory
        cache.totalCostLimit = Int(min(max(memory / 48, 32 << 20), 128 << 20))
    }

    func close() {
        cache.removeAllObjects()
        archive.close()
    }

    func image(page: Int, maxPixel: Int) async throws -> UIImage {
        let key = "\(page)@\(maxPixel)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [archive, cache] in
                do {
                    if let cached = cache.object(forKey: key) { return continuation.resume(returning: cached) }
                    let data = try archive.page(page)
                    let image = try Self.decode(data, page: page, maxPixel: maxPixel)
                    let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
                    cache.setObject(image, forKey: key, cost: cost)
                    continuation.resume(returning: image)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func decode(_ data: Data, page: Int, maxPixel: Int) throws -> UIImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              ImageProbe.withinLimits(width: width, height: height)
        else { throw ComicArchiveError.unsupportedImage(page) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(maxPixel, max(width, height))),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ComicArchiveError.unsupportedImage(page)
        }
        return UIImage(cgImage: image)
    }
}

/// A comic's pages in a horizontal pager, one page or one spread per screen.
final class ComicPageReader: PageReaderController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    private let loader: ComicPageLoader
    private let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal, options: [.interPageSpacing: 16])
    private var spreads: [ClosedRange<Int>] = []
    private var lastSize: CGSize = .zero
    private var zoomed = false

    init(loader: ComicPageLoader, pageCount: Int, opening page: Int, layout: PageLayout, theme: ReaderTheme) {
        self.loader = loader
        super.init(pageCount: pageCount, opening: page, layout: layout, theme: theme)
    }

    deinit { loader.close() }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(pager)
        pager.view.frame = view.bounds
        pager.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pager.view)
        pager.didMove(toParent: self)
        pager.dataSource = self
        pager.delegate = self
        rebuild()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        report()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.size != lastSize else { return }
        lastSize = view.bounds.size
        // A rotation may change between one page and two; the page being read stays.
        let paired = PageSpreads.layout(pageCount: pageCount, paired: spreadsActive)
        if paired != spreads { rebuild() }
    }

    override func layoutChanged() {
        rebuild()
    }

    override var theme: ReaderTheme {
        didSet { current?.theme = theme }
    }

    private var current: ComicSpreadController? { pager.viewControllers?.first as? ComicSpreadController }

    override var visiblePages: ClosedRange<Int> { current?.pages ?? anchor ... anchor }

    /// Only pages whose image is on screen. A spread with one broken page reports the other.
    override var displayedPages: ClosedRange<Int>? {
        guard let current else { return nil }
        let drawn = current.pages.filter(current.displayed.contains)
        guard let low = drawn.min(), let high = drawn.max() else { return nil }
        return low ... high
    }

    private func rebuild() {
        guard isViewLoaded else { return }
        spreads = PageSpreads.layout(pageCount: pageCount, paired: spreadsActive)
        let index = PageSpreads.index(of: anchor, in: spreads)
        guard spreads.indices.contains(index) else { return }
        pager.setViewControllers([spread(index)], direction: .forward, animated: false)
        setZoomed(false)
        DispatchQueue.main.async { [weak self] in self?.report() }
    }

    private func spread(_ index: Int) -> ComicSpreadController {
        let controller = ComicSpreadController(
            index: index, pages: spreads[index], pageCount: pageCount, loader: loader,
            fit: layout.fit, rightToLeft: layout.rightToLeft, theme: theme
        )
        controller.onTap = { [weak self] x, width in self?.handleTap(at: x, width: width) }
        controller.onDisplayed = { [weak self, weak controller] _ in
            guard let self, let controller, controller === self.current else { return }
            self.report()
        }
        controller.onFailed = { [weak self, weak controller] page in
            guard let self, let controller, controller === self.current else { return }
            self.delegate?.pageReader(self, couldNotShow: page)
            self.report()
        }
        controller.onZoom = { [weak self] zoomed in self?.setZoomed(zoomed) }
        controller.onAccessibilityScroll = { [weak self] direction in
            guard let self else { return false }
            switch direction {
            // Swiping left brings in the page on the right.
            case .left: self.turn(towardsRight: true)
            case .right: self.turn(towardsRight: false)
            case .next: self.turn(forward: true)
            case .previous: self.turn(forward: false)
            default: return false
            }
            return true
        }
        controller.view.accessibilityCustomActions = accessibilityActions()
        return controller
    }

    /// While zoomed, a drag pans the page and never turns it.
    private func setZoomed(_ zoomed: Bool) {
        self.zoomed = zoomed
        pager.dataSource = zoomed ? nil : self
    }

    /// In right-to-left books the next spread is on the left.
    private func neighbour(of controller: UIViewController, towardsRight: Bool) -> UIViewController? {
        guard let shown = controller as? ComicSpreadController else { return nil }
        let index = shown.index + (towardsRight != layout.rightToLeft ? 1 : -1)
        return spreads.indices.contains(index) ? spread(index) : nil
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        neighbour(of: viewController, towardsRight: false)
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        neighbour(of: viewController, towardsRight: true)
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed else { return }
        settled()
    }

    private func settled() {
        report()
        UIAccessibility.post(notification: .pageScrolled, argument: pageDescription(visiblePages))
        prefetch()
    }

    override func go(to page: Int, animated: Bool) {
        let target = min(max(page, 1), pageCount)
        let index = PageSpreads.index(of: target, in: spreads)
        guard spreads.indices.contains(index) else { return }
        anchor = target
        let from = current?.index ?? index
        let forward = index >= from
        let direction: UIPageViewController.NavigationDirection = forward != layout.rightToLeft ? .forward : .reverse
        let target = spread(index)
        setZoomed(false)
        pager.setViewControllers([target], direction: direction, animated: animated && index != from) { [weak self] _ in
            guard let self else { return }
            // UIPageViewController can keep stale neighbours after an animated jump.
            if animated { DispatchQueue.main.async { self.pager.setViewControllers([target], direction: direction, animated: false) } }
            self.settled()
        }
        if !animated || index == from { DispatchQueue.main.async { [weak self] in self?.settled() } }
    }

    override func turn(forward: Bool) {
        guard let shown = current else { return }
        let index = shown.index + (forward ? 1 : -1)
        guard spreads.indices.contains(index) else { return }
        go(to: spreads[index].lowerBound, animated: true)
    }

    /// Decodes the next spread ahead of time; nothing further.
    private func prefetch() {
        guard let shown = current, spreads.indices.contains(shown.index + 1) else { return }
        let size = ComicSpreadController.decodeSize(for: view.bounds.size, scale: traitCollection.displayScale, zoom: 1)
        for page in spreads[shown.index + 1] {
            Task { [loader] in _ = try? await loader.image(page: page, maxPixel: size) }
        }
    }
}

/// One page or one spread, zoomable from 1× to 5×.
final class ComicSpreadController: UIViewController, UIScrollViewDelegate {
    let index: Int
    let pages: ClosedRange<Int>
    var onTap: ((CGFloat, CGFloat) -> Void)?
    var onZoom: ((Bool) -> Void)?
    /// A page's image is on screen.
    var onDisplayed: ((Int) -> Void)?
    /// A page's image couldn't be decoded or verified.
    var onFailed: ((Int) -> Void)?
    private(set) var displayed: Set<Int> = []
    var theme: ReaderTheme {
        didSet { applyTheme() }
    }

    private let pageCount: Int
    private let loader: ComicPageLoader
    private let fit: PageLayout.Fit
    private let rightToLeft: Bool
    private let scroll = UIScrollView()
    private let content = UIView()
    private var imageViews: [Int: UIImageView] = [:]
    private var failures: [Int: UILabel] = [:]
    private var lastSize: CGSize = .zero
    private var sharp = false
    private var loaded = false

    init(index: Int, pages: ClosedRange<Int>, pageCount: Int, loader: ComicPageLoader, fit: PageLayout.Fit, rightToLeft: Bool, theme: ReaderTheme) {
        self.index = index
        self.pages = pages
        self.pageCount = pageCount
        self.loader = loader
        self.fit = fit
        self.rightToLeft = rightToLeft
        self.theme = theme
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The longest side to decode at: the screen at its scale, more when zoomed, at most 4096.
    static func decodeSize(for bounds: CGSize, scale: CGFloat, zoom: CGFloat) -> Int {
        Int(min(4096, max(bounds.width, bounds.height) * max(scale, 1) * zoom).rounded(.up))
    }

    override func loadView() {
        let page = AccessiblePageView()
        page.onScroll = { [weak self] direction in self?.onAccessibilityScroll?(direction) ?? false }
        view = page
    }

    /// VoiceOver's three-finger swipes, passed to the reader.
    var onAccessibilityScroll: ((UIAccessibilityScrollDirection) -> Bool)?

    override func viewDidLoad() {
        super.viewDidLoad()
        scroll.frame = view.bounds
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.delegate = self
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.addSubview(content)
        view.addSubview(scroll)
        for page in pages {
            let image = UIImageView()
            image.contentMode = .scaleAspectFit
            image.isAccessibilityElement = false
            content.addSubview(image)
            imageViews[page] = image
        }
        applyTheme()

        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: self, action: #selector(singleTapped(_:)))
        single.require(toFail: double)
        view.addGestureRecognizer(double)
        view.addGestureRecognizer(single)

        view.isAccessibilityElement = true
        view.accessibilityTraits = [.image]
        view.accessibilityLabel = pages.count > 1
            ? "Pages \(pages.lowerBound) and \(pages.upperBound) of \(pageCount)"
            : "Page \(pages.lowerBound) of \(pageCount)"
        view.accessibilityIdentifier = "comic-page-\(pages.lowerBound)"
    }

    private func applyTheme() {
        guard isViewLoaded else { return }
        view.backgroundColor = UIColor(hex: theme.pageHex)
        failures.values.forEach { $0.textColor = UIColor(hex: theme.textHex) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.size != lastSize else { return }
        lastSize = view.bounds.size
        scroll.zoomScale = 1
        layoutPages()
        // Decoded at the size it is shown at, once that is known.
        if !loaded {
            loaded = true
            load(zoom: 1)
        }
    }

    private func load(zoom: CGFloat) {
        let size = Self.decodeSize(for: view.bounds.size, scale: traitCollection.displayScale, zoom: zoom)
        for page in pages {
            Task { [weak self, loader] in
                do {
                    let image = try await loader.image(page: page, maxPixel: size)
                    guard let self else { return }
                    let first = self.imageViews[page]?.image == nil
                    self.imageViews[page]?.image = image
                    self.failures.removeValue(forKey: page)?.removeFromSuperview()
                    if first { self.layoutPages() }
                    if self.displayed.insert(page).inserted { self.onDisplayed?(page) }
                } catch {
                    // A sharper copy failing keeps the copy already shown.
                    guard let self, !self.displayed.contains(page) else { return }
                    self.showFailure(page)
                    self.onFailed?(page)
                }
            }
        }
    }

    /// A page that can't be shown says so, rather than leaving another page on screen.
    private func showFailure(_ page: Int) {
        imageViews[page]?.image = nil
        guard failures[page] == nil else { return }
        let label = UILabel()
        label.text = "Page \(page) couldn't be shown. Its image is damaged or in a form Shelfarr doesn't read."
        label.numberOfLines = 0
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = true
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = UIColor(hex: theme.textHex)
        content.addSubview(label)
        failures[page] = label
        view.accessibilityLabel = "Page \(page) of \(pageCount) couldn't be shown"
        layoutPages()
    }

    /// Lays the pages side by side (right to left when the book reads that way), fitted
    /// to the whole page or to the width.
    private func layoutPages() {
        let bounds = view.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        let ordered = rightToLeft ? pages.reversed() : Array(pages)
        // Until a page is decoded, assume the screen's own proportions.
        let ratios: [CGFloat] = ordered.map { page in
            guard let size = imageViews[page]?.image?.size, size.height > 0 else { return 2.0 / 3.0 }
            return size.width / size.height
        }
        let totalRatio = ratios.reduce(0, +)
        var height: CGFloat
        switch fit {
        case .page: height = min(bounds.height, bounds.width / totalRatio)
        case .width: height = bounds.width / totalRatio
        }
        height = max(1, height)
        let width = height * totalRatio
        var x: CGFloat = 0
        for (page, ratio) in zip(ordered, ratios) {
            let frame = CGRect(x: x, y: 0, width: height * ratio, height: height)
            imageViews[page]?.frame = frame
            failures[page]?.frame = frame.insetBy(dx: 24, dy: 24)
            x += frame.width
        }
        content.frame = CGRect(x: 0, y: 0, width: width, height: height)
        scroll.contentSize = content.frame.size
        center()
    }

    private func center() {
        let bounds = scroll.bounds.size
        let size = content.frame.size
        scroll.contentInset = UIEdgeInsets(
            top: max(0, (bounds.height - size.height) / 2), left: max(0, (bounds.width - size.width) / 2),
            bottom: 0, right: 0
        )
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        center()
        onZoom?(scrollView.zoomScale > 1.01)
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        // Zooming isn't reading; a sharper copy is drawn for the page being looked at.
        if scale > 1.5, !sharp {
            sharp = true
            load(zoom: min(scale, 3))
        }
    }

    @objc private func singleTapped(_ recognizer: UITapGestureRecognizer) {
        onTap?(recognizer.location(in: view).x, view.bounds.width)
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        if scroll.zoomScale > 1.01 {
            scroll.setZoomScale(1, animated: true)
        } else {
            let point = recognizer.location(in: content)
            let scale: CGFloat = 2.5
            let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
            scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }

}

/// A page view that hands VoiceOver's page scrolling to the reader.
final class AccessiblePageView: UIView {
    var onScroll: ((UIAccessibilityScrollDirection) -> Bool)?

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        onScroll?(direction) ?? false
    }
}

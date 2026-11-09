import Combine
import Foundation
import PDFKit
import ShelfarrCore
import UIKit

@MainActor
final class ReaderModel: ObservableObject {
    enum State {
        case preparing(Double?)
        case chooseResume(local: SavedPosition, server: ReadingProgress)
        /// Several formats and nothing to choose by: the reader picks. Suggested first.
        case chooseFormat([FormatOption])
        /// Offline, the saved place is in a format that isn't on this device; these are.
        case formatUnavailable(saved: ReaderFormat, alternatives: [ReaderFormat])
        /// The saved place names a page this file doesn't have. It stays saved; the reader
        /// chooses where to start looking.
        case invalidPlace(format: ReaderFormat, pageCount: Int)
        case ready(title: String, navigator: UIViewController)
        case pages(title: String, reader: PageReaderController)
        case failed(Error)
        case unreadable(title: String, message: String)
    }

    struct FormatOption: Identifiable, Equatable {
        let format: ReaderFormat
        let sizeBytes: Int64
        let onDevice: Bool
        var id: String { format.rawValue }
    }

    @Published private(set) var state = State.preparing(nil)
    @Published private(set) var fraction = 0.0
    @Published private(set) var position: Int?
    @Published private(set) var chapter: String?
    @Published private(set) var syncStatus = SyncStatus.idle
    @Published private(set) var notice: String?
    @Published var chromeVisible = false
    /// How the place was restored, for the simulator smoke only (synthetic fixture places).
    @Published private(set) var restoreTrace: String?
    /// The format open now, and the formats this book has.
    @Published private(set) var format: ReaderFormat?
    @Published private(set) var formats: [ReaderFormat] = []
    /// The page the reader is on (one-based), and how many there are, for PDFs and comics.
    @Published private(set) var page = 0
    @Published private(set) var pageCount = 0
    @Published var layout = PageLayout() {
        didSet {
            guard layout != oldValue else { return }
            pageReader?.layout = layout
            if let session = owner { app.pageLayouts.save(layout, accountKey: session.accountKey, publicationId: publicationId) }
        }
    }

    private(set) var book: ReadiumBook?
    private let app: AppModel
    private let owner: Session?
    private let publicationId: String
    private let sync: ProgressSync?
    private var asset: ShelfarrCore.Asset?
    private var assetIds: [String] = []
    private var title = ""
    private var observer: UUID?
    /// Tells Readium reporting the opened place apart from the reader moving on.
    private var restoration = ReadingRestoration(opening: nil)
    /// Bounds one attempt to bring the saved place back on screen.
    private var correctionTimer: Task<Void, Never>?
    private let trace = RestoreTrace.make()
    /// Local writes run in the order the pages were reached.
    private var lastWrite: Task<Void, Never>?

    // What this open decided, kept while the reader is asked which format or page.
    private var publication: ShelfarrCore.Publication?
    private var download: DownloadRecord?
    private var useDownload = false
    private var offline = false
    /// The saved place this session restores or keeps, in whichever format it is.
    private var place: SavedPosition?
    private var baseVersion = 0
    private var observedAt: Int64?
    private var editionNotice: String?
    /// A format asked for (a choice, a switch); otherwise the decision picks one.
    private var requestedFormat: ReaderFormat?

    // Pages.
    private var pageReader: PageReaderController?
    private var pendingReader: PageReaderController?
    private var comicOrder: ReadingOrder?
    private var pageRestoration: PageRestoration?

    init(app: AppModel, publicationId: String) {
        self.app = app
        owner = app.session
        self.publicationId = publicationId
        sync = app.progressRegistry()?.sync(for: publicationId)
        if let session = app.session {
            layout = app.pageLayouts.layout(accountKey: session.accountKey, publicationId: publicationId)
        }
    }

    func open() async {
        await open(requested: nil)
    }

    /// Loads the publication, decides the place, then the format.
    private func open(requested: ReaderFormat?) async {
        guard let session = owner, app.isCurrent(session), let sync else {
            state = .failed(APIError.unauthorized)
            return
        }
        state = .preparing(nil)
        closeReaders()
        requestedFormat = requested
        if observer == nil {
            observer = await sync.observe { [weak self] status in
                Task { @MainActor in self?.syncStatus = status }
            }
        }
        do {
            let api = app.api(for: session)
            let downloads = app.downloadsForSession()
            offline = false
            var metadata: PublicationMetadata?
            do {
                metadata = try await app.publications(for: session).load(id: publicationId, server: session.server, api: api)
                offline = metadata?.unverified == true
            } catch let error as APIError where error.isPlainOffline {
                offline = true
            }
            guard app.isCurrent(session) else { throw CancellationError() }
            download = await downloads?.ready(publicationId)
            // A download pins one edition. Online, it is used only while it is still the server's edition.
            useDownload = false
            if let download {
                useDownload = offline || (metadata.map { download.matches($0.publication) } ?? false)
            }
            guard let publication = (useDownload ? download?.publication : nil) ?? metadata?.publication ?? download?.publication else {
                throw APIError.offline(certificate: false)
            }
            self.publication = publication
            formats = publication.readerFormats
            guard !formats.isEmpty else {
                state = .unreadable(title: "Can't open this book", message: "There's no EPUB, PDF or comic file here the app can open.")
                return
            }
            assetIds = publication.playableAssets.map(\.id)
            title = publication.title

            let local = await sync.snapshot()
            editionNotice = nil
            // A download's details are as old as the download. The last details seen may
            // know a newer place (another device's, perhaps in another format); it applies
            // when it is a place in this edition.
            let editionAssets = Set(publication.playableAssets.map(\.id))
            let seen = metadata?.publication.progress.flatMap { editionAssets.contains($0.assetId) ? $0 : nil }
            let serverPlace = [seen, publication.progress].compactMap { $0 }.max { $0.version < $1.version }
            switch ResumeDecision.decide(publication: publication, server: serverPlace, local: local, offline: offline) {
            case .beginning:
                place = nil
                baseVersion = 0
                observedAt = nil
            case let .resume(position, version, time):
                place = position
                baseVersion = version
                observedAt = time
            case let .choose(local, server):
                state = .chooseResume(local: local, server: server)
                return
            case let .editionChanged(staleVersion):
                place = nil
                baseVersion = staleVersion
                observedAt = nil
                editionNotice = "This book's file was replaced, so your old place doesn't apply. Starting from the beginning."
            }
            await chooseFormat()
        } catch is CancellationError {
            return
        } catch {
            state = .failed(error)
        }
    }

    func chooseResume(keepLocal: Bool) async {
        guard case let .chooseResume(local, server) = state else { return }
        let position = keepLocal ? local : SavedPosition(server)
        await sync?.chooseAtOpen(position: position, server: server, keepLocal: keepLocal)
        place = position
        baseVersion = server.version
        observedAt = nil
        await chooseFormat()
    }

    /// The formats with a complete copy on this device, for opening offline.
    private func localFormats(_ publication: ShelfarrCore.Publication) async -> Set<ReaderFormat> {
        var found: Set<ReaderFormat> = []
        if useDownload, let format = download?.readerFormat { found.insert(format) }
        guard let session = owner else { return found }
        for asset in publication.readableAssets {
            if let format = asset.readerFormat, await app.epubCache.hasCopy(accountKey: session.accountKey, asset: asset) {
                found.insert(format)
            }
        }
        return found
    }

    private func chooseFormat() async {
        guard let publication else { return }
        if let requested = requestedFormat, formats.contains(requested) {
            requestedFormat = nil
            return await openFormat(requested)
        }
        let local = await localFormats(publication)
        switch FormatDecision.decide(
            publication: publication, placeAssetId: place?.assetId,
            readyDownload: useDownload ? download?.readerFormat : nil, local: local, offline: offline
        ) {
        case nil:
            state = .unreadable(title: "Can't open this book", message: "There's no EPUB, PDF or comic file here the app can open.")
        case let .open(format):
            await openFormat(format)
        case let .ask(options):
            state = .chooseFormat(options.map { format in
                FormatOption(format: format, sizeBytes: publication.asset(for: format)?.sizeBytes ?? 0, onDevice: local.contains(format))
            })
        case let .savedFormatUnavailable(saved, alternatives):
            state = .formatUnavailable(saved: saved, alternatives: alternatives)
        }
    }

    /// The reader picked a format: from the choice, the offline alternatives or the menu.
    func pick(_ format: ReaderFormat) async {
        await openFormat(format)
    }

    /// Opens another format of this book. Its beginning is not a place: the saved one
    /// stays until a page is turned there.
    func switchFormat(_ format: ReaderFormat) async {
        guard format != self.format, formats.contains(format) else { return }
        flush()
        await lastWrite?.value
        await open(requested: format)
    }

    private func openFormat(_ format: ReaderFormat) async {
        guard let publication, let session = owner, app.isCurrent(session), let asset = publication.asset(for: format) else {
            state = .unreadable(title: "Can't open this book", message: "That format isn't available for this book.")
            return
        }
        self.format = format
        self.asset = asset
        let placeHere = place.flatMap { $0.assetId == asset.id ? $0 : nil }
        notice = editionNotice
        if let place, placeHere == nil, let saved = publication.readableAssets.first(where: { $0.id == place.assetId })?.readerFormat {
            notice = "Opened the \(format.label) at its beginning. Your place stays in the \(saved.label) until you turn a page here."
        }
        state = .preparing(nil)
        do {
            let api = app.api(for: session)
            let downloads = app.downloadsForSession()
            var file: URL?
            var order: ReadingOrder?
            if useDownload, let download, let local = await downloads?.fileURL(download, assetId: asset.id) {
                order = format == .cbz ? await downloads?.readingOrder(download, assetId: asset.id) : nil
                if format != .cbz || order != nil {
                    file = local
                    if offline { notice = notice ?? "Reading the download on this device. Your place will sync when you're back online." }
                }
            }
            if file == nil {
                let cache = app.epubCache
                let cached = try await app.followingHandover(session) {
                    try await cache.obtain(accountKey: session.accountKey, server: session.server, asset: asset, authorize: { api.authorized($0) }) { [weak self] fraction in
                        Task { @MainActor in self?.state = .preparing(fraction) }
                    }
                }
                guard app.isCurrent(session) else { throw CancellationError() }
                if cached.unverified || offline {
                    notice = notice ?? "Reading the copy on this device. Your place will sync when you're back online."
                }
                file = cached.file
                order = cached.readingOrder
            }
            guard let file else { throw APIError.protocolError }
            note("source \(useDownload ? "download" : "cache") offline=\(offline) format=\(format.rawValue)")
            switch format {
            case .epub: await openEPUB(file, at: placeHere)
            case .pdf, .cbz: await openPages(file, order: order, at: placeHere)
            }
        } catch is CancellationError {
            return
        } catch {
            state = .failed(error)
        }
    }

    // MARK: EPUB

    private func openEPUB(_ file: URL, at position: SavedPosition?) async {
        guard let opened = await ReadiumBook.open(file: file) else {
            state = .unreadable(title: "Can't open this book", message: "This file isn't a readable EPUB, or it's protected by DRM.")
            return
        }
        book = opened
        await start(position)
    }

    /// Anchors the session on the saved place (in whichever format it is) and opens the
    /// EPUB at `position`, its place in this file, or at the beginning.
    private func start(_ position: SavedPosition?) async {
        guard let book, app.isCurrent(owner) else { return }
        // Opening at the saved place is not reading: it keeps the time it was reached.
        await sync?.begin(position: place, baseVersion: baseVersion, observedAt: observedAt, assets: assetIds)
        correctionTimer?.cancel()
        restoration = ReadingRestoration(opening: position?.locator)
        note("open \(RestoreTrace.describe(position?.locator))")
        do {
            let navigator = try book.makeNavigator(
                locatorJSON: position?.locator?.jsonString(),
                settings: app.readerSettings.settings,
                onLocation: { [weak self] in self?.record($0) },
                onTap: { [weak self] in self?.chromeVisible.toggle() }
            )
            state = .ready(title: title, navigator: navigator)
        } catch {
            state = .unreadable(title: "Can't open this book", message: "This file isn't a readable EPUB, or it's protected by DRM.")
        }
    }

    private func record(_ location: ReadingLocation) {
        // Captured before anything waits: this is when the page was reached.
        let observedAt = ActivityTime.now()
        fraction = location.fraction
        position = location.position
        if let chapter = location.chapter { self.chapter = chapter }
        guard let asset, let sync, let locator = JSONValue.parse(jsonString: location.locatorJSON) else { return }
        let viewport = location.visible.map { visible in
            ReadingViewport(resources: visible
                .filter { $0.from.isFinite && $0.to.isFinite }
                .map { ReadingViewport.Resource(href: $0.href, progression: $0.from ... max($0.from, $0.to)) })
        }
        let action = restoration.observe(ReadingObservation(locator: locator, viewport: viewport))
        note("report \(RestoreTrace.describe(locator)) viewport \(RestoreTrace.describe(viewport)) -> \(RestoreTrace.describe(action))")
        guard action == .record else {
            // Restoring is not reading: the saved place and its time stay as they were.
            apply(action)
            return
        }
        let saved = SavedPosition(assetId: asset.id, locator: locator)
        enqueue { await sync.update(saved, observedAt: observedAt) }
    }

    private static let restoreFailed = "Couldn't show your saved page. It stays your saved place until you turn a page."

    private func apply(_ action: ReadingRestoration.Action) {
        switch action {
        case .none, .record:
            return
        case let .correct(target, attempt):
            correct(to: target, attempt: attempt)
        case .settled:
            correctionTimer?.cancel()
            book?.setInputEnabled(true)
            if notice == Self.restoreFailed { notice = nil }
        case .gaveUp:
            correctionTimer?.cancel()
            book?.setInputEnabled(true)
            notice = Self.restoreFailed
        }
    }

    /// Sends the reader back to the saved place and waits for a report showing it. The
    /// jump finishing proves nothing; the timeout only bounds a failure.
    private func correct(to target: JSONValue, attempt: Int) {
        book?.setInputEnabled(false)
        correctionTimer?.cancel()
        correctionTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ReadingRestoration.attemptTimeout * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            let next = self.restoration.timedOut(attempt: attempt)
            self.note("timeout #\(attempt) -> \(RestoreTrace.describe(next))")
            self.apply(next)
        }
        guard let book, let json = target.jsonString() else { return }
        Task { [weak self] in
            let accepted = await book.go(toLocatorJSON: json)
            self?.note("go #\(attempt) accepted=\(accepted)")
        }
    }

    // MARK: Pages

    private func openPages(_ file: URL, order: ReadingOrder?, at position: SavedPosition?) async {
        let reader: PageReaderController
        let count: Int
        var target: Int? = 1
        switch format {
        case .pdf:
            guard let document = await PDFLoader.load(file) else {
                state = .unreadable(title: "Can't open this PDF", message: "The file is damaged or isn't a PDF this device can read.")
                return
            }
            if document.isLocked {
                state = .unreadable(title: "This PDF is locked", message: "It's protected with a password, which Shelfarr can't open.")
                return
            }
            count = document.pageCount
            guard count > 0 else {
                state = .unreadable(title: "Can't open this PDF", message: "It has no pages.")
                return
            }
            if let position { target = PageLocator.pdfPage(position.locator, pageCount: count) }
            reader = PDFPageReader(document: document, opening: target ?? 1, layout: layout, theme: app.readerSettings.settings.theme)
        default:
            guard let order else {
                state = .unreadable(title: "Can't open this comic", message: "Its page list is missing. Connect to your server and try again.")
                return
            }
            let archive: ComicArchive
            do {
                archive = try await Task.detached(priority: .userInitiated) { try ComicArchive.open(file, order: order) }.value
            } catch {
                state = .unreadable(
                    title: "Can't open this comic",
                    message: "Its archive doesn't match the page list your server sent, or it uses features Shelfarr doesn't read."
                )
                return
            }
            count = order.items.count
            if let position { target = PageLocator.comicPage(position.locator, order: order) }
            reader = ComicPageReader(loader: ComicPageLoader(archive: archive), pageCount: count, opening: target ?? 1, layout: layout, theme: app.readerSettings.settings.theme)
        }
        comicOrder = order
        pageCount = count
        reader.delegate = self
        // The session keeps the saved place, whichever page this file then shows.
        await sync?.begin(position: place, baseVersion: baseVersion, observedAt: observedAt, assets: assetIds)
        guard let target else {
            // A place this file can't show is never replaced by an invented page one.
            note("invalid place \(RestoreTrace.describe(position?.locator)) pages=\(count)")
            pendingReader = reader
            state = .invalidPlace(format: format ?? .pdf, pageCount: count)
            return
        }
        show(reader, at: target)
    }

    /// From the invalid-place choice: where to start looking. Looking is not reading.
    func startLooking(atLastPage: Bool) {
        guard case let .invalidPlace(_, count) = state, let reader = pendingReader else { return }
        pendingReader = nil
        let target = atLastPage ? count : 1
        reader.anchor = target
        show(reader, at: target)
    }

    private func show(_ reader: PageReaderController, at target: Int) {
        pageRestoration = PageRestoration(opening: target)
        page = target
        fraction = pageFraction(target)
        note("open page \(target) of \(pageCount)")
        reader.setInputEnabled(false)
        pageReader = reader
        state = .pages(title: title, reader: reader)
        // Bounds the wait for the opening page; giving up records nothing.
        correctionTimer?.cancel()
        correctionTimer = Task { [weak self, weak reader] in
            try? await Task.sleep(nanoseconds: UInt64(ReadingRestoration.attemptTimeout * 1_000_000_000))
            guard !Task.isCancelled, let self, let reader, reader === self.pageReader,
                  var restoration = self.pageRestoration, restoration.isRestoring
            else { return }
            restoration.abandonTarget()
            self.pageRestoration = restoration
            reader.setInputEnabled(true)
            self.notice = Self.pageRestoreFailed
            self.note("open timeout -> gave-up")
        }
    }

    private func pageFraction(_ page: Int) -> Double {
        pageCount > 1 ? Double(page - 1) / Double(pageCount - 1) : 0
    }

    func goToPage(_ target: Int) {
        guard let pageReader, (1 ... max(pageCount, 1)).contains(target) else { return }
        pageReader.go(to: target, animated: true)
    }

    func turnPage(forward: Bool) {
        pageReader?.turn(forward: forward)
    }

    private func save(page: Int, observedAt: Int64) {
        guard let asset, let sync else { return }
        let locator: JSONValue?
        switch format {
        case .pdf: locator = PageLocator.pdf(page: page, pageCount: pageCount)
        case .cbz: locator = comicOrder.flatMap { PageLocator.comic(page: page, order: $0) }
        default: locator = nil
        }
        guard let locator else { return }
        let saved = SavedPosition(assetId: asset.id, locator: locator)
        enqueue { await sync.update(saved, observedAt: observedAt) }
    }

    private static let pageRestoreFailed = "Couldn't show your saved page. It stays your saved place until you turn to a page that shows."

    private func closeReaders() {
        correctionTimer?.cancel()
        pageReader = nil
        pendingReader = nil
        pageRestoration = nil
        comicOrder = nil
        book = nil
    }

    // MARK: Shared

    private func note(_ line: String) {
        guard let trace else { return }
        restoreTrace = trace.note(line)
    }

    func flush() {
        guard let sync else { return }
        enqueue { await sync.requestFlush() }
    }

    private func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = lastWrite
        lastWrite = Task {
            await previous?.value
            await work()
        }
    }

    func keepThisPlace() {
        guard let sync else { return }
        Task { await sync.keepLocal() }
    }

    func useOtherPlace() {
        guard let sync else { return }
        Task {
            guard let position = await sync.useServer() else { return }
            note("reopen \(RestoreTrace.describe(position.locator))")
            // Going to the chosen saved place is not new reading. A place in another file
            // opens that file.
            guard position.assetId == asset?.id else {
                await open(requested: nil)
                return
            }
            if let pageReader, var restoration = pageRestoration {
                let target = format == .pdf
                    ? PageLocator.pdfPage(position.locator, pageCount: pageCount)
                    : comicOrder.flatMap { PageLocator.comicPage(position.locator, order: $0) }
                guard let target else { return await open(requested: nil) }
                let action = restoration.reopen(at: target)
                pageRestoration = restoration
                pageReader.setInputEnabled(false)
                if case let .correct(page) = action { pageReader.go(to: page, animated: false) }
            } else {
                apply(restoration.reopen(at: position.locator))
            }
        }
    }

    func clearNotice() {
        notice = nil
    }

    func applyTheme(_ theme: ReaderTheme) {
        pageReader?.theme = theme
    }
}

extension ReaderModel: PageReaderDelegate {
    func pageReader(_ reader: PageReaderController, navigatedTo page: Int) {
        guard reader === pageReader, pageRestoration?.isRestoring == false else { return }
        // Where the reader is, drawn or not; the saved place only moves with a drawn page.
        self.page = page
        fraction = pageFraction(page)
    }

    func pageReader(_ reader: PageReaderController, shows displayed: ClosedRange<Int>) {
        // Captured before anything waits: this is when the page was reached.
        let observedAt = ActivityTime.now()
        guard reader === pageReader, var restoration = pageRestoration else { return }
        let action = restoration.observe(displayed)
        pageRestoration = restoration
        note("pages \(displayed.lowerBound)-\(displayed.upperBound) -> \(RestoreTrace.describe(action))")
        switch action {
        case .none:
            return
        case let .correct(target):
            reader.go(to: target, animated: false)
        case .settled:
            correctionTimer?.cancel()
            reader.setInputEnabled(true)
            if let anchor = restoration.anchor { page = anchor }
            if notice == Self.pageRestoreFailed { notice = nil }
        case .gaveUp:
            reader.setInputEnabled(true)
            notice = Self.pageRestoreFailed
        case let .record(turned):
            page = turned
            save(page: turned, observedAt: observedAt)
        }
        fraction = pageFraction(page)
    }

    func pageReader(_ reader: PageReaderController, couldNotShow failed: Int) {
        guard reader === pageReader else { return }
        note("page \(failed) failed")
        // A page that can't be drawn is never saved. If it was the one being restored,
        // stop waiting for it; the saved place stays until a page that shows is turned to.
        if var restoration = pageRestoration, restoration.target == failed {
            restoration.abandonTarget()
            pageRestoration = restoration
            reader.setInputEnabled(true)
            notice = Self.pageRestoreFailed
        }
    }

    func pageReaderToggleControls(_ reader: PageReaderController) {
        chromeVisible.toggle()
    }
}

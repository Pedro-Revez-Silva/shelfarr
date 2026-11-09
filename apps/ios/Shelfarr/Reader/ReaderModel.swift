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
    /// Narration for this EPUB, when real alignment for it can be played now.
    @Published private(set) var readAlong: ReadAlongController?
    /// Why this EPUB has no narration here, when there is something worth saying.
    @Published private(set) var readAlongNote: String?
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
    /// The place `restoration` is restoring.
    private var restorationTarget: JSONValue?
    /// Bounds one attempt to bring the saved place back on screen.
    private var correctionTimer: Task<Void, Never>?
    private let trace = RestoreTrace.make()
    /// Local writes run in the order the pages were reached.
    private var lastWrite: Task<Void, Never>?
    /// The last place Readium reported, so a layout change can be restored rather than read.
    private var lastLocator: JSONValue?

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
    /// The open file's pages, and the saved place decided from what its view reports.
    private var pages: PageCursor.Pages?
    private var cursor: PageCursor?

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
        await startReadAlong(at: position)
    }

    /// Opens the narration of a read-along EPUB, when there is one this device can play.
    /// The book reads exactly as before when there isn't: older servers, unaligned, stale
    /// or invalid alignments, or offline without its narration downloaded.
    private func startReadAlong(at position: SavedPosition?) async {
        await readAlong?.close()
        readAlong = nil
        readAlongNote = nil
        guard let session = owner, let publication, let asset, asset.isEpub, let book, let sync, app.isCurrent(session) else { return }
        switch await app.readAlong.setup(publication: publication, asset: asset, offline: offline, session: session) {
        case .none:
            return
        case let .note(text):
            readAlongNote = text
        case let .ready(narration):
            guard app.isCurrent(session), self.book === book else { return }
            let audiobookId = narration.manifest.audiobookPublicationId
            let audiobookSync = audiobookId.flatMap { app.progressRegistry()?.sync(for: $0) }
            let controller = ReadAlongController(
                narration: narration, title: publication.title, author: publication.author, book: book, engine: app.playback,
                ebook: sync, audiobook: audiobookSync, server: session.server, api: app.api(for: session), theme: app.readerSettings.settings.theme
            )
            controller.restored(position?.locator)
            readAlong = controller
            note("read-along \(narration.manifest.source.rawValue) \(narration.fromDevice ? "device" : "stream")")
            if let audiobookId, let audiobookSync {
                // A later place heard on the audiobook's own player is offered, never written here.
                let local = await audiobookSync.snapshot()
                let remote = try? await app.publications(for: session).load(id: audiobookId, server: session.server, api: app.api(for: session))
                guard readAlong === controller else { return }
                controller.consider(audiobook: remote?.publication.progress, local: local, ebookObservedAt: observedAt)
            }
        }
    }

    /// Anchors the session on the saved place (in whichever format it is) and opens the
    /// EPUB at `position`, its place in this file, or at the beginning.
    private func start(_ position: SavedPosition?) async {
        guard let book, app.isCurrent(owner) else { return }
        // Opening at the saved place is not reading: it keeps the time it was reached.
        await sync?.begin(position: place, baseVersion: baseVersion, observedAt: observedAt, assets: assetIds)
        correctionTimer?.cancel()
        restoration = ReadingRestoration(opening: position?.locator)
        restorationTarget = position?.locator
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
        guard asset != nil, sync != nil, let locator = JSONValue.parse(jsonString: location.locatorJSON) else { return }
        lastLocator = locator
        let viewport = location.visible.map { visible in
            ReadingViewport(resources: visible
                .filter { $0.from.isFinite && $0.to.isFinite }
                .map { ReadingViewport.Resource(href: $0.href, progression: $0.from ... max($0.from, $0.to)) })
        }
        let observation = ReadingObservation(locator: locator, viewport: viewport)
        let action = restoration.observe(observation)
        note("report \(RestoreTrace.describe(locator)) viewport \(RestoreTrace.describe(viewport)) -> \(RestoreTrace.describe(action))")
        guard action == .record else {
            // Restoring is not reading: the saved place and its time stay as they were.
            apply(action, for: observation, observedAt: observedAt)
            return
        }
        save(observation, observedAt: observedAt)
    }

    /// The reader moved to `observation`: save it with the time it was reported.
    private func save(_ observation: ReadingObservation, observedAt: Int64) {
        guard let asset, let sync else { return }
        let locator = observation.locator
        // Read-along: a page followed to, or turned while narration plays, is not reading.
        let saved = SavedPosition(assetId: asset.id, locator: locator)
        if let readAlong {
            guard readAlong.readerMoved(href: locator["href"]?.stringValue) else {
                note("read-along report not written")
                return
            }
            readAlong.recordReading(saved, observedAt: observedAt)
        } else {
            enqueue { await sync.update(saved, observedAt: observedAt) }
        }
    }

    private static let restoreFailed = "Couldn't show your saved page. It stays your saved place until you turn a page."

    private func apply(_ action: ReadingRestoration.Action, for observation: ReadingObservation? = nil, observedAt: Int64? = nil) {
        switch action {
        case .none:
            return
        case .record:
            // Only an element answer about a report already classified arrives here.
            guard let observation, let observedAt else { return }
            save(observation, observedAt: observedAt)
        case .confirm:
            // A place heard names its element: ask the page whether that element is shown.
            guard let observation, let book, let href = observation.locator["href"]?.stringValue,
                  case let .array(fragments)? = restorationTarget?["locations"]?["fragments"], case let .string(fragment)? = fragments.first
            else { return }
            let target = restorationTarget?["href"]?.stringValue ?? href
            Task { [weak self] in
                let visible = await book.isElementVisible(href: target, fragment: fragment) ?? false
                guard let self, self.book === book else { return }
                let next = self.restoration.elementShown(visible, for: observation)
                self.note("element \(fragment) visible=\(visible) -> \(RestoreTrace.describe(next))")
                self.apply(next, for: observation, observedAt: observedAt)
            }
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
            // A jump to where the page already is reports nothing; have Readium measure it.
            guard accepted else { return }
            await book.remeasure()
            self?.note("remeasure #\(attempt)")
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
            #if DEBUG
            let delays = UITestFixture.comicPageDelays()
            #else
            let delays: [Int: TimeInterval] = [:]
            #endif
            reader = ComicPageReader(loader: ComicPageLoader(archive: archive, delays: delays), pageCount: count, opening: target ?? 1, layout: layout, theme: app.readerSettings.settings.theme)
        }
        pages = format == .pdf ? PageCursor.Pages.pdf(count: count) : order.map(PageCursor.Pages.comic)
        pageCount = count
        reader.delegate = self
        if trace != nil { reader.trace = { [weak self] in self?.note($0) } }
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
        guard let asset, let pages else { return }
        cursor = PageCursor(assetId: asset.id, pages: pages, opening: target)
        page = target
        fraction = pageFraction(target)
        note("open page \(target) of \(pageCount)")
        reader.setInputEnabled(false)
        pageReader = reader
        state = .pages(title: title, reader: reader)
        waitForRestoredPage(reader)
    }

    /// Bounds how long input waits for the page being restored. Giving up hands input back
    /// and records nothing; the page stays pending, so if it shows late that is still not
    /// reading, and only the reader turning moves the place.
    private func waitForRestoredPage(_ reader: PageReaderController) {
        correctionTimer?.cancel()
        correctionTimer = Task { [weak self, weak reader] in
            try? await Task.sleep(nanoseconds: UInt64(ReadingRestoration.attemptTimeout * 1_000_000_000))
            guard !Task.isCancelled, let self, let reader, reader === self.pageReader, var cursor = self.cursor else { return }
            let action = cursor.timedOut()
            self.cursor = cursor
            guard action == .gaveUp else { return }
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
        pageReader.readerGo(to: target)
    }

    func turnPage(forward: Bool) {
        pageReader?.readerTurn(forward: forward)
    }

    /// A real turn, written with the time its page was drawn.
    private func save(_ save: PageCursor.Save) {
        guard let sync else { return }
        enqueue { await sync.update(save.position, observedAt: save.observedAt) }
    }

    private static let pageRestoreFailed = "Couldn't show your saved page. It stays your saved place until you turn to a page that shows."

    private func closeReaders() {
        correctionTimer?.cancel()
        if let readAlong { Task { await readAlong.close() } }
        readAlong = nil
        readAlongNote = nil
        pageReader = nil
        pendingReader = nil
        cursor = nil
        pages = nil
        book = nil
    }

    // MARK: Shared

    private func note(_ line: String) {
        guard let trace else { return }
        restoreTrace = trace.note(line)
    }

    func flush() {
        readAlong?.checkpointNow()
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
        Task {
            await readAlong?.finishWrites()
            await sync.keepLocal()
        }
    }

    func useOtherPlace() {
        guard let sync else { return }
        Task {
            await readAlong?.finishWrites()
            guard let position = await sync.useServer() else { return }
            note("reopen \(RestoreTrace.describe(position.locator))")
            // Going to the chosen saved place is not new reading. A place in another file
            // opens that file.
            guard position.assetId == asset?.id else {
                await open(requested: nil)
                return
            }
            if let pageReader, var cursor {
                guard let target = cursor.pages.page(position.locator) else { return await open(requested: nil) }
                let action = cursor.reopen(at: target)
                self.cursor = cursor
                pageReader.setInputEnabled(false)
                waitForRestoredPage(pageReader)
                if case let .correct(page) = action { pageReader.go(to: page, animated: false) }
            } else {
                restorationTarget = position.locator
                apply(restoration.reopen(at: position.locator))
                // The other device's place is where narration starts, as it is.
                readAlong?.restored(position.locator, arrival: .adopted)
            }
        }
    }

    /// Text size, page colours or the window changed. With narration, the report the new
    /// layout causes anchors the page rather than being saved as reading; turns after it are.
    func layoutChanged() {
        guard readAlong != nil, lastLocator != nil, case .ready = state, !restoration.isCorrecting else { return }
        restoration = ReadingRestoration(opening: nil)
        restorationTarget = nil
        note("layout")
    }

    /// The reader is closing: save the place heard and unload the narration.
    func leave() {
        flush()
        guard let readAlong else { return }
        Task { await readAlong.close() }
    }

    func clearNotice() {
        notice = nil
    }

    func applyTheme(_ theme: ReaderTheme) {
        pageReader?.theme = theme
        readAlong?.applyTheme(theme)
    }
}

extension ReaderModel: PageReaderDelegate {
    func pageReader(_ reader: PageReaderController, navigatedTo page: Int) {
        guard reader === pageReader, cursor?.isRestoring == false else { return }
        // Where the reader is, drawn or not; the saved place only moves with a drawn page.
        self.page = page
        fraction = pageFraction(page)
    }

    func pageReader(_ reader: PageReaderController, shows visible: ClosedRange<Int>, drawn displayed: ClosedRange<Int>?) {
        // Captured before anything waits: this is when the page was reached.
        let observedAt = ActivityTime.now()
        guard reader === pageReader, var cursor else { return }
        let outcome = cursor.shows(visible: visible, displayed: displayed, observedAt: observedAt)
        self.cursor = cursor
        let drawn = displayed.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "none"
        note("pages \(visible.lowerBound)-\(visible.upperBound) drawn \(drawn) -> \(RestoreTrace.describe(outcome.action))")
        switch outcome.action {
        case .none:
            return
        case let .correct(target):
            reader.go(to: target, animated: false)
        case .settled:
            correctionTimer?.cancel()
            reader.setInputEnabled(true)
            if let anchor = cursor.restoration.anchor { page = anchor }
            if notice == Self.pageRestoreFailed { notice = nil }
        case .gaveUp:
            correctionTimer?.cancel()
            reader.setInputEnabled(true)
            notice = Self.pageRestoreFailed
        case let .record(turned):
            page = turned
            // A layout keeps this page on screen: the view's target follows the saved page.
            reader.anchor = turned
            if notice == Self.pageRestoreFailed { notice = nil }
            if let save = outcome.save { self.save(save) }
        }
        fraction = pageFraction(page)
    }

    func pageReader(_ reader: PageReaderController, couldNotShow failed: Int) {
        guard reader === pageReader, var cursor else { return }
        // A page that can't be drawn is never saved. If it was the one being restored,
        // stop holding input for it; the saved place stays until the reader turns to a
        // page that shows.
        let action = cursor.couldNotShow(failed)
        self.cursor = cursor
        note("page \(failed) failed -> \(RestoreTrace.describe(action))")
        guard action == .gaveUp else { return }
        correctionTimer?.cancel()
        reader.setInputEnabled(true)
        notice = Self.pageRestoreFailed
    }

    func pageReaderNavigates(_ reader: PageReaderController) {
        guard reader === pageReader, var cursor else { return }
        let endedRestore = cursor.readerNavigates()
        self.cursor = cursor
        guard endedRestore else { return }
        // The reader chose to move on: the restored page stays saved until a page they
        // reach is drawn.
        note("reader navigates while restoring")
        correctionTimer?.cancel()
        reader.setInputEnabled(true)
    }

    func pageReaderToggleControls(_ reader: PageReaderController) {
        chromeVisible.toggle()
    }
}

import Combine
import Foundation
import ShelfarrCore
import UIKit

@MainActor
final class ReaderModel: ObservableObject {
    enum State {
        case preparing(Double?)
        case chooseResume(local: SavedPosition, server: ReadingProgress)
        case ready(title: String, navigator: UIViewController)
        case failed(Error)
        case unreadable
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

    init(app: AppModel, publicationId: String) {
        self.app = app
        owner = app.session
        self.publicationId = publicationId
        sync = app.progressRegistry()?.sync(for: publicationId)
    }

    func open() async {
        guard let session = owner, app.session == session, let sync else {
            state = .failed(APIError.unauthorized)
            return
        }
        state = .preparing(nil)
        observer = await sync.observe { [weak self] status in
            Task { @MainActor in self?.syncStatus = status }
        }
        do {
            let api = app.api(for: session)
            let downloads = app.downloadsForSession()
            var offline = false
            var metadata: PublicationMetadata?
            do {
                metadata = try await app.publications(for: session).load(id: publicationId, server: session.server, api: api)
                offline = metadata?.unverified == true
            } catch let error as APIError where error.isPlainOffline {
                offline = true
            }
            guard app.session == session else { throw CancellationError() }
            let download = await downloads?.ready(publicationId)
            // A download pins one edition. Online, it is used only while it is still the server's edition.
            var useDownload = false
            if let download {
                useDownload = offline || (metadata.map { download.matches($0.publication) } ?? false)
            }
            guard let publication = (useDownload ? download?.publication : nil) ?? metadata?.publication ?? download?.publication else {
                throw APIError.offline(certificate: false)
            }
            guard let epub = publication.epubAsset else {
                state = .unreadable
                return
            }
            asset = epub
            assetIds = publication.playableAssets.map(\.id)
            title = publication.title

            let file: URL
            if useDownload, let download, let local = await downloads?.fileURL(download, assetId: epub.id) {
                file = local
                if offline { notice = "Reading the download on this device. Your place will sync when you're back online." }
            } else {
                let cached = try await app.epubCache.obtain(accountKey: session.accountKey, server: session.server, asset: epub, authorize: { api.authorized($0) }) { [weak self] fraction in
                    Task { @MainActor in self?.state = .preparing(fraction) }
                }
                guard app.session == session else { throw CancellationError() }
                if cached.unverified || offline {
                    notice = "Reading the copy on this device. Your place will sync when you're back online."
                }
                file = cached.file
            }
            note("source \(useDownload ? "download" : "cache") offline=\(offline)")
            guard let opened = await ReadiumBook.open(file: file) else {
                state = .unreadable
                return
            }
            book = opened

            let local = await sync.snapshot()
            switch ResumeDecision.decide(publication: publication, server: publication.progress, local: local, offline: offline) {
            case .beginning:
                await start(nil, baseVersion: 0)
            case let .resume(position, baseVersion, observedAt):
                await start(position, baseVersion: baseVersion, observedAt: observedAt)
            case let .choose(local, server):
                state = .chooseResume(local: local, server: server)
            case let .editionChanged(staleVersion):
                notice = "This book's file was replaced, so your old place doesn't apply. Starting from the beginning."
                await start(nil, baseVersion: staleVersion)
            }
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
        await start(position, baseVersion: server.version)
    }

    private func start(_ position: SavedPosition?, baseVersion: Int, observedAt: Int64? = nil) async {
        guard let book, app.session == owner else { return }
        // Opening at the saved place is not reading: it keeps the time it was reached.
        await sync?.begin(position: position, baseVersion: baseVersion, observedAt: observedAt, assets: assetIds)
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
            state = .unreadable
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
            // Going to the chosen saved place is not new reading.
            note("reopen \(RestoreTrace.describe(position.locator))")
            apply(restoration.reopen(at: position.locator))
        }
    }

    func clearNotice() {
        notice = nil
    }
}

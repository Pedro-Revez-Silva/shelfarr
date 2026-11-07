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

    private(set) var book: ReadiumBook?
    private let app: AppModel
    private let owner: Session?
    private let publicationId: String
    private let sync: ProgressSync?
    private var asset: ShelfarrCore.Asset?
    private var title = ""
    private var observer: UUID?

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
            guard let opened = await ReadiumBook.open(file: file) else {
                state = .unreadable
                return
            }
            book = opened

            let local = await sync.snapshot()
            switch ResumeDecision.decide(publication: publication, server: publication.progress, local: local, offline: offline) {
            case .beginning:
                await start(nil, baseVersion: 0)
            case let .resume(position, baseVersion):
                await start(position, baseVersion: baseVersion)
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
        await sync?.chooseAtOpen(position: position, serverVersion: server.version, keepLocal: keepLocal)
        await start(position, baseVersion: server.version)
    }

    private func start(_ position: SavedPosition?, baseVersion: Int) async {
        guard let book, app.session == owner else { return }
        await sync?.begin(position: position, baseVersion: baseVersion)
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
        fraction = location.fraction
        position = location.position
        if let chapter = location.chapter { self.chapter = chapter }
        guard let asset, let sync, let locator = JSONValue.parse(jsonString: location.locatorJSON) else { return }
        let saved = SavedPosition(assetId: asset.id, locator: locator)
        Task { await sync.update(saved) }
    }

    func flush() {
        guard let sync else { return }
        Task { await sync.flush() }
    }

    func keepThisPlace() {
        guard let sync else { return }
        Task { await sync.keepLocal() }
    }

    func useOtherPlace() {
        guard let sync else { return }
        Task {
            if let json = await sync.useServer()?.locator?.jsonString() {
                book?.go(toLocatorJSON: json)
            }
        }
    }

    func clearNotice() {
        notice = nil
    }
}

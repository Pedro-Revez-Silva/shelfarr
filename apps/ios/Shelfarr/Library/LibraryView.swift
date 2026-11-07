import ShelfarrCore
import SwiftUI

@MainActor
final class LibraryModel: ObservableObject {
    @Published var filter: LibraryFilter = .all
    @Published var query = ""
    /// Nil shows every status.
    @Published var status: ReadingStatus?
    @Published var sort: LibrarySort = .recent
    @Published private(set) var items: [ShelfarrCore.Publication] = []
    @Published private(set) var loading = true
    @Published private(set) var loadingMore = false
    @Published private(set) var error: Error?
    @Published private(set) var pageFailed = false
    /// Set while the list shows titles saved on this device because the server is unreachable.
    @Published private(set) var offline: LibraryCoverage?

    private var next: LibraryCursor?
    private var request: Task<Void, Never>?
    private var pageRequest: Task<Void, Never>?
    private var generation = 0

    private var listing: LibraryQuery {
        LibraryQuery(filter: filter, text: query, status: status, sort: sort)
    }

    private func source(_ app: AppModel, _ session: Session) -> LibrarySource {
        let server = session.server, api = app.api(for: session)
        return LibrarySource(cache: app.libraryCache(for: session)) { query, cursor in
            try await api.library(server: server, query: query, cursor: cursor)
        }
    }

    /// Every downloaded title is browsable offline, from its own record.
    private func saved(_ app: AppModel) -> [ShelfarrCore.Publication] {
        app.downloads.records.values.map(\.publication)
    }

    func reload(_ app: AppModel, debounce: Bool = false) {
        guard let session = app.session else { return }
        let source = source(app, session), cache = app.libraryCache(for: session)
        request?.cancel()
        pageRequest?.cancel()
        generation += 1
        let generation = self.generation
        let listing = self.listing
        let downloads = saved(app)
        loading = true
        loadingMore = false
        next = nil
        request = Task {
            if debounce { try? await Task.sleep(nanoseconds: 350_000_000) }
            if Task.isCancelled { return }
            loading = true
            error = nil
            pageFailed = false
            await cache.pin(Set(downloads.map(\.id)))
            do {
                let page = try await source.load(listing, downloads: downloads)
                // A response for an older query or account never replaces the current one.
                guard !Task.isCancelled, self.generation == generation, app.session == session else { return }
                apply(page, append: false)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.generation == generation, app.session == session else { return }
                self.error = error
                items = []
                next = nil
                offline = nil
            }
            loading = false
        }
    }

    private func apply(_ page: LibraryListing, append: Bool) {
        items = append ? items + page.items : page.items
        next = page.next
        if case let .device(coverage) = page.source { offline = coverage } else { offline = nil }
    }

    func loadMoreIfNeeded(_ app: AppModel, after publication: ShelfarrCore.Publication) {
        guard let session = app.session, let cursor = next, !loading, !loadingMore,
              items.suffix(6).contains(where: { $0.id == publication.id })
        else { return }
        let generation = self.generation
        // The cursor is bound to the query that produced it.
        let listing = self.listing
        let source = source(app, session), shown = items.count, downloads = saved(app)
        loadingMore = true
        pageFailed = false
        pageRequest = Task {
            do {
                let page = try await source.load(listing, after: cursor, shown: shown, downloads: downloads)
                guard !Task.isCancelled, self.generation == generation, app.session == session else { return }
                apply(page, append: true)
            } catch {
                guard !Task.isCancelled, self.generation == generation, app.session == session else { return }
                pageFailed = true
            }
            loadingMore = false
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model = LibraryModel()
    let open: (ShelfarrCore.Publication) -> Void

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 14, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Show", selection: $model.filter) {
                Text("All").tag(LibraryFilter.all)
                Text("Books").tag(LibraryFilter.ebook)
                Text("Audiobooks").tag(LibraryFilter.audiobook)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            HStack(spacing: 8) {
                // Menus rather than a scrolling chip row, so the active choice is always on screen.
                Menu {
                    Picker("Status", selection: $model.status) {
                        Text("Any status").tag(ReadingStatus?.none)
                        ForEach(ReadingStatus.allCases, id: \.self) { Text($0.label).tag(ReadingStatus?.some($0)) }
                    }
                } label: {
                    menuLabel("Status: \(model.status?.label ?? "Any")", active: model.status != nil)
                }
                Menu {
                    Picker("Sort", selection: $model.sort) {
                        Text("Recently added").tag(LibrarySort.recent)
                        Text("Title A–Z").tag(LibrarySort.title)
                    }
                } label: {
                    menuLabel("Sort: \(model.sort == .title ? "Title" : "Recent")", active: false, systemImage: "arrow.up.arrow.down")
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            content
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Library")
        .searchable(text: $model.query, prompt: "Title or author")
        .navigationDestination(for: PublicationRoute.self) { DetailsView(publicationId: $0.id, open: open) }
        .onChange(of: model.filter) { _ in model.reload(app) }
        .onChange(of: model.status) { _ in model.reload(app) }
        .onChange(of: model.sort) { _ in model.reload(app) }
        .onChange(of: model.query) { _ in model.reload(app, debounce: true) }
        .task(id: app.libraryGeneration) { model.reload(app) }
    }

    private func menuLabel(_ text: String, active: Bool, systemImage: String? = nil) -> some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage).font(.footnote) }
            Text(text).font(.subheadline.weight(.medium))
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(active ? Palette.accentSoft : Palette.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Palette.hairline))
        .accessibilityLabel("\(text). Change")
    }

    @ViewBuilder
    private var content: some View {
        if let coverage = model.offline {
            OfflineLibraryBanner(coverage: coverage, host: app.session?.server.host) { model.reload(app) }
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
        }
        list
    }

    @ViewBuilder
    private var list: some View {
        if model.loading, model.items.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.error {
            let copy = errorCopy(error, host: app.session?.server.host)
            MessageState(title: copy.title, message: copy.message, systemImage: "wifi.slash", action: "Try again") {
                model.reload(app)
            }
        } else if model.items.isEmpty, let coverage = model.offline {
            MessageState(
                title: coverage.isEmpty ? "Nothing saved on this device" : "No saved titles match",
                message: coverage.isEmpty
                    ? "Titles you browse or download appear here when you're offline."
                    : "Only titles saved on this device can be searched offline. Your server may have more.",
                systemImage: "wifi.slash"
            )
        } else if model.items.isEmpty, let status = model.status, model.query.isEmpty {
            MessageState(
                title: status == .finished ? "Nothing finished yet" : "Nothing \(status.label.lowercased())",
                message: "Change the status filter to see the rest of your library.",
                action: "Show all"
            ) {
                model.status = nil
            }
        } else if model.items.isEmpty {
            if model.query.isEmpty {
                MessageState(title: "Nothing here yet", message: "Acquired books and audiobooks appear here.")
            } else {
                MessageState(title: "No matches", message: "Nothing in your library matches “\(model.query)”.")
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(model.items) { publication in
                        NavigationLink(value: PublicationRoute(id: publication.id)) {
                            ShelfItem(publication: publication, square: model.filter == .audiobook)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("library-item-\(publication.id)")
                        .onAppear { model.loadMoreIfNeeded(app, after: publication) }
                    }
                }
                .padding(20)
                if model.loadingMore { ProgressView().padding() }
                if model.pageFailed {
                    Button("Couldn't load more. Try again") {
                        if let last = model.items.last { model.loadMoreIfNeeded(app, after: last) }
                    }
                    .padding()
                }
            }
        }
    }
}

/// Says plainly that the list is what this device saved, and how fresh it is.
struct OfflineLibraryBanner: View {
    let coverage: LibraryCoverage
    let host: String?
    let retry: () -> Void

    private var detail: String {
        var parts = ["\(coverage.titles) saved on this device"]
        if coverage.downloaded > 0 { parts.append("\(coverage.downloaded) downloaded") }
        var line = parts.joined(separator: " · ")
        if let newest = coverage.newest {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            line += ". Last updated \(formatter.localizedString(for: newest, relativeTo: Date()))"
        }
        return line + ". Your full library on \(host ?? "your server") may have more, and statuses are as last seen."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wifi.slash").foregroundStyle(Palette.inkMuted).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Offline. Showing saved titles").font(.footnote.weight(.medium)).foregroundStyle(Palette.ink)
                Text(detail).font(.footnote).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Retry", action: retry).font(.footnote.weight(.medium)).tint(Palette.accent)
        }
        .padding(12)
        .background(Palette.sunken, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library-offline-banner")
    }
}

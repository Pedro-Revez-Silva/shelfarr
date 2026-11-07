import ShelfarrCore
import SwiftUI

@MainActor
final class LibraryModel: ObservableObject {
    @Published var filter: LibraryFilter = .all
    @Published var query = ""
    @Published private(set) var items: [ShelfarrCore.Publication] = []
    @Published private(set) var loading = true
    @Published private(set) var loadingMore = false
    @Published private(set) var error: Error?
    @Published private(set) var pageFailed = false

    private var nextCursor: String?
    private var request: Task<Void, Never>?
    private var pageRequest: Task<Void, Never>?
    private var generation = 0

    func reload(_ app: AppModel, debounce: Bool = false) {
        guard let session = app.session else { return }
        let server = session.server, api = app.api(for: session)
        request?.cancel()
        pageRequest?.cancel()
        generation += 1
        let generation = self.generation, filter = self.filter, query = self.query
        loading = true
        loadingMore = false
        nextCursor = nil
        request = Task {
            if debounce { try? await Task.sleep(nanoseconds: 350_000_000) }
            if Task.isCancelled { return }
            loading = true
            error = nil
            pageFailed = false
            do {
                let page = try await api.library(server: server, filter: filter, query: query)
                guard !Task.isCancelled, self.generation == generation, app.session == session else { return }
                items = page.items
                nextCursor = page.nextCursor
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.generation == generation, app.session == session else { return }
                self.error = error
                items = []
                nextCursor = nil
            }
            loading = false
        }
    }

    func loadMoreIfNeeded(_ app: AppModel, after publication: ShelfarrCore.Publication) {
        guard let session = app.session, let cursor = nextCursor, !loading, !loadingMore,
              items.suffix(6).contains(where: { $0.id == publication.id })
        else { return }
        let generation = self.generation, filter = self.filter, query = self.query
        let server = session.server, api = app.api(for: session)
        loadingMore = true
        pageFailed = false
        pageRequest = Task {
            do {
                let page = try await api.library(server: server, filter: filter, query: query, cursor: cursor)
                guard !Task.isCancelled, self.generation == generation, app.session == session else { return }
                items += page.items
                nextCursor = page.nextCursor
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
            .padding(.vertical, 8)
            content
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Library")
        .searchable(text: $model.query, prompt: "Title or author")
        .navigationDestination(for: PublicationRoute.self) { DetailsView(publicationId: $0.id, open: open) }
        .onChange(of: model.filter) { _ in model.reload(app) }
        .onChange(of: model.query) { _ in model.reload(app, debounce: true) }
        .task { if model.items.isEmpty { model.reload(app) } }
    }

    @ViewBuilder
    private var content: some View {
        if model.loading, model.items.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.error {
            let copy = errorCopy(error, host: app.session?.server.host)
            MessageState(title: copy.title, message: copy.message, systemImage: "wifi.slash", action: "Try again") {
                model.reload(app)
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

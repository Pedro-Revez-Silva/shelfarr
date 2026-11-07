import ShelfarrCore
import SwiftUI

@MainActor
final class HomeModel: ObservableObject {
    enum State {
        case loading
        case failed(Error)
        case loaded(inProgress: [ShelfarrCore.Publication], books: [ShelfarrCore.Publication], audiobooks: [ShelfarrCore.Publication])
    }

    @Published private(set) var state = State.loading

    /// Reloads quietly, keeping what's on screen if the refresh fails.
    func refresh(_ app: AppModel) async {
        guard let server = app.session?.server else { return }
        do {
            let items = try await app.api.library(server: server).items
            state = .loaded(
                inProgress: items
                    .filter { $0.progress?.isUsable == true }
                    .sorted { ($0.progress?.updatedAt ?? "") > ($1.progress?.updatedAt ?? "") },
                books: items.filter { $0.bookType == .ebook },
                audiobooks: items.filter { $0.bookType == .audiobook }
            )
        } catch is CancellationError {
            return
        } catch {
            if case .loaded = state { return }
            state = .failed(error)
        }
    }

    func retry(_ app: AppModel) async {
        state = .loading
        await refresh(app)
    }
}

struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model = HomeModel()
    let open: (ShelfarrCore.Publication) -> Void

    var body: some View {
        content
            .background(Palette.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: PublicationRoute.self) { DetailsView(publicationId: $0.id, open: open) }
            .task { await model.refresh(app) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(error):
            let copy = errorCopy(error, host: app.session?.server.host)
            MessageState(title: copy.title, message: copy.message, systemImage: "wifi.slash", action: "Try again") {
                Task { await model.retry(app) }
            }
        case let .loaded(inProgress, books, audiobooks):
            if inProgress.isEmpty, books.isEmpty, audiobooks.isEmpty {
                VStack(alignment: .leading) {
                    wordmark
                    MessageState(
                        title: "Nothing on the shelf yet",
                        message: "Books and audiobooks appear here once Shelfarr has acquired them for your library."
                    )
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        wordmark
                        if let current = inProgress.first {
                            Button { open(current) } label: { ContinueCard(publication: current) }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 4)
                        }
                        if inProgress.count > 1 { Shelf(title: "Also in progress", items: Array(inProgress.dropFirst())) }
                        if !books.isEmpty { Shelf(title: "Books", items: books) }
                        if !audiobooks.isEmpty { Shelf(title: "Audiobooks", items: audiobooks) }
                    }
                    .padding(.bottom, 24)
                }
                .refreshable { await model.refresh(app) }
            }
        }
    }

    private var wordmark: some View {
        Text("Shelfarr")
            .font(Typeface.display(26))
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
    }
}

struct PublicationRoute: Hashable {
    let id: String
}

private struct ContinueCard: View {
    let publication: ShelfarrCore.Publication

    var body: some View {
        HStack(spacing: 16) {
            BookCover(publication: publication).frame(width: 84)
            VStack(alignment: .leading, spacing: 0) {
                Text(publication.bookType == .ebook ? "Continue reading" : "Continue listening")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Palette.accent)
                Text(publication.title)
                    .font(Typeface.display(20))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                    .padding(.top, 6)
                if let author = publication.author {
                    Text(author).font(.footnote).foregroundStyle(Palette.inkMuted).lineLimit(1)
                }
                if let fraction = publication.progressFraction {
                    ProgressRule(fraction: fraction).padding(.top, 12)
                }
                if let label = publication.progressLabel {
                    Text(label).font(.caption2.weight(.medium)).foregroundStyle(Palette.inkMuted).padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Palette.hairline))
        .accessibilityElement(children: .combine)
    }
}

private struct Shelf: View {
    let title: String
    let items: [ShelfarrCore.Publication]

    var body: some View {
        let square = items.allSatisfy { $0.bookType == .audiobook }
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(Typeface.display(20))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 20)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { publication in
                        NavigationLink(value: PublicationRoute(id: publication.id)) {
                            ShelfItem(publication: publication, square: square).frame(width: square ? 128 : 112)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.top, 20)
    }
}

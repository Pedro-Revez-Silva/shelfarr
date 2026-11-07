import ShelfarrCore
import SwiftUI

@MainActor
final class DetailsModel: ObservableObject {
    enum State {
        case loading
        case loaded(ShelfarrCore.Publication)
        case failed(Error)
    }

    @Published private(set) var state = State.loading

    func load(_ app: AppModel, id: String) async {
        guard let server = app.session?.server else { return }
        do {
            state = .loaded(try await app.api.publication(server: server, id: id))
        } catch is CancellationError {
            return
        } catch {
            if case .loaded = state { return }
            state = .failed(error)
        }
    }
}

struct DetailsView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model = DetailsModel()
    let publicationId: String
    let open: (ShelfarrCore.Publication) -> Void

    var body: some View {
        content
            .background(Palette.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.load(app, id: publicationId) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(error):
            let copy = errorCopy(error, host: app.session?.server.host)
            MessageState(title: copy.title, message: copy.message, systemImage: "wifi.slash", action: copy.retryable ? "Try again" : nil) {
                Task { await model.load(app, id: publicationId) }
            }
        case let .loaded(publication):
            ScrollView {
                VStack(spacing: 0) {
                    BookCover(publication: publication, corner: 6)
                        .frame(maxWidth: publication.bookType == .audiobook ? 220 : 188)
                    Text(publication.title)
                        .font(Typeface.display(30, relativeTo: .largeTitle))
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.center)
                        .padding(.top, 24)
                        .accessibilityAddTraits(.isHeader)
                    if let author = publication.author {
                        Text(author).font(.subheadline).foregroundStyle(Palette.inkMuted).padding(.top, 6)
                    }
                    action(publication).padding(.top, 24)
                    if let description = publication.description, !description.isEmpty {
                        Text(description)
                            .font(Typeface.serif(18))
                            .foregroundStyle(Palette.ink)
                            .lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 28)
                    }
                    files(publication).padding(.top, 28)
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func action(_ publication: ShelfarrCore.Publication) -> some View {
        if publication.isReadableHere {
            VStack(spacing: 6) {
                Button(publication.primaryActionLabel) { open(publication) }
                    .buttonStyle(PrimaryButtonStyle())
                if let label = publication.progressLabel {
                    if let fraction = publication.progressFraction {
                        ProgressRule(fraction: fraction).padding(.top, 6)
                    }
                    Text(label).font(.caption2.weight(.medium)).foregroundStyle(Palette.inkMuted)
                }
            }
        } else {
            Text("This format can't be opened in the app yet.")
                .font(.subheadline)
                .foregroundStyle(Palette.inkMuted)
                .multilineTextAlignment(.center)
        }
    }

    private func files(_ publication: ShelfarrCore.Publication) -> some View {
        let assets = publication.orderedAssets
        let total = assets.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let formats = Array(Set(assets.map { $0.format.uppercased() })).sorted().joined(separator: ", ")
        return VStack(spacing: 10) {
            Divider().overlay(Palette.hairline)
            row("Format", formats.isEmpty ? "Unknown" : formats)
            if assets.count > 1 { row("Files", String(assets.count)) }
            if total > 0 { row("Size", ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) }
            row("Availability", publication.bookType == .audiobook ? "Streams from your server" : "Opens from your server")
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Palette.inkMuted)
            Spacer()
            Text(value).foregroundStyle(Palette.ink)
        }
        .font(.footnote)
    }
}

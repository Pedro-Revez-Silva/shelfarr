import ShelfarrCore
import SwiftUI

@MainActor
final class DetailsModel: ObservableObject {
    enum State {
        case loading
        /// `offline` means these are the last details seen on this device, not the server's.
        case loaded(ShelfarrCore.Publication, offline: Bool)
        case failed(Error)
    }

    @Published private(set) var state = State.loading
    @Published private(set) var statusSaving: ReadingStatus?
    @Published private(set) var statusError: Error?

    func load(_ app: AppModel, id: String) async {
        guard let session = app.session else { return }
        let server = session.server, api = app.api(for: session)
        do {
            let metadata = try await app.publications(for: session).load(id: id, server: server, api: api)
            guard app.isCurrent(session) else { return }
            state = .loaded(metadata.publication, offline: metadata.unverified)
        } catch is CancellationError {
            return
        } catch {
            guard app.isCurrent(session) else { return }
            if case .loaded = state { return }
            // Offline, a download still knows its book. Sign-in and certificate errors stay visible.
            if (error as? APIError)?.isPlainOffline == true, let record = await app.downloadsForSession()?.record(id) {
                state = .loaded(record.publication, offline: true)
                return
            }
            state = .failed(error)
        }
    }

    /// Needs the server: nothing changes on screen until it has accepted the status.
    func setStatus(_ app: AppModel, _ status: ReadingStatus) async {
        guard let session = app.session, case let .loaded(publication, offline) = state,
              !offline, statusSaving == nil, publication.status != status
        else { return }
        statusSaving = status
        statusError = nil
        do {
            let updated = try await app.api(for: session).setReadingStatus(server: session.server, publicationId: publication.id, status: status)
            guard app.isCurrent(session) else { return }
            app.remember(updated, for: session)
            state = .loaded(updated, offline: false)
            app.libraryGeneration += 1
        } catch {
            statusError = error
        }
        statusSaving = nil
    }
}

struct DetailsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var downloads: DownloadsModel
    @StateObject private var model = DetailsModel()
    let publicationId: String
    let open: (ShelfarrCore.Publication) -> Void

    var body: some View {
        content
            .background(Palette.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .task(id: app.libraryGeneration) { await model.load(app, id: publicationId) }
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
        case let .loaded(publication, offline):
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
                    if offline {
                        Text(downloads.records[publication.id]?.isReady == true
                            ? "Offline. Opening the download on this device."
                            : "Offline. These are the last details seen on this device.")
                            .font(.footnote)
                            .foregroundStyle(Palette.inkMuted)
                            .multilineTextAlignment(.center)
                            .padding(.top, 10)
                    }
                    if publication.isReadableHere {
                        DownloadPanel(downloads: downloads, publication: publication, offline: offline).padding(.top, 20)
                    }
                    StatusPicker(
                        publication: publication,
                        offline: offline,
                        saving: model.statusSaving,
                        error: model.statusError,
                        host: app.session?.server.host
                    ) { status in
                        Task { await model.setStatus(app, status) }
                    }
                    .padding(.top, 24)
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
            if let pages = publication.asset(for: .cbz)?.pageCount, pages > 0 { row("Pages", String(pages)) }
            if total > 0 { row("Size", ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) }
            row("Availability", downloads.records[publication.id].flatMap { record -> String? in
                record.isReady ? "Downloaded to this device" + (publication.readerFormats.count > 1 ? (record.readerFormat.map { " (\($0.label))" } ?? "") : "") : nil
            } ?? (publication.bookType == .audiobook ? "Streams from your server" : "Opens from your server"))
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

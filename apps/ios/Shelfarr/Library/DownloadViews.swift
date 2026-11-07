import ShelfarrCore
import SwiftUI

/// What a download is doing, in words. Partial downloads never read as ready.
struct DownloadCopy {
    let title: String
    let detail: String
    var canRetry = false
}

private func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
}

func downloadCopy(_ record: DownloadRecord) -> DownloadCopy {
    let amount = record.bytesTotal.map { "\(bytes(record.bytesDone)) of \(bytes($0))" } ?? "\(bytes(record.bytesDone)) so far"
    let kept = record.bytesDone > 0 ? " \(bytes(record.bytesDone)) kept." : ""
    switch record.state {
    case .queued:
        return DownloadCopy(title: "Waiting to download", detail: amount)
    case .downloading:
        var detail = amount
        if record.files.count > 1 {
            let done = record.files.filter(\.complete).count
            detail += " · file \(min(done + 1, record.files.count)) of \(record.files.count)"
        }
        let title = record.fraction.map { "Downloading \(Int($0 * 100))%" } ?? "Downloading"
        return DownloadCopy(title: title, detail: detail)
    case .ready:
        return DownloadCopy(title: "Downloaded", detail: "\(bytes(record.bytesDone)) on this device. Opens without a connection.")
    case .cancelled:
        return DownloadCopy(title: "Download cancelled", detail: "Nothing is kept on this device.", canRetry: true)
    case .failed:
        switch record.problem {
        case .offline: return DownloadCopy(title: "Paused: no connection", detail: "Continues when Shelfarr is open and online.\(kept)", canRetry: true)
        case .certificate: return DownloadCopy(title: "Stopped: can't verify your server", detail: "Its security certificate couldn't be trusted.", canRetry: true)
        case .signIn: return DownloadCopy(title: "Stopped: signed out", detail: "Sign in to this account again to continue.\(kept)")
        case .forbidden: return DownloadCopy(title: "Not allowed", detail: "This account can't download that file.", canRetry: true)
        case .notFound: return DownloadCopy(title: "No longer on your server", detail: "The file couldn't be found.", canRetry: true)
        case .server: return DownloadCopy(title: "Your server had a problem", detail: "Tries again when you come back to Shelfarr.\(kept)", canRetry: true)
        case .redirect: return DownloadCopy(title: "Server moved", detail: "Your server redirected elsewhere, so Shelfarr stopped.", canRetry: true)
        case .changed: return DownloadCopy(title: "Changed on your server", detail: "The file was replaced while downloading. Download again for the new edition.", canRetry: true)
        case .storage: return DownloadCopy(title: "Not enough space", detail: "Free some space on this device, then try again.\(kept)", canRetry: true)
        case .missing: return DownloadCopy(title: "Files missing", detail: "Some downloaded files are no longer on this device.", canRetry: true)
        case .unsupported: return DownloadCopy(title: "Can't be downloaded", detail: "There's no file here the app can open.")
        case .invalid, .none: return DownloadCopy(title: "Download failed", detail: "Your server sent an unexpected file.", canRetry: true)
        }
    }
}

/// The download controls on a publication's page.
struct DownloadPanel: View {
    @ObservedObject var downloads: DownloadsModel
    let publication: ShelfarrCore.Publication
    let offline: Bool
    @State private var confirmRemove = false

    var body: some View {
        let record = downloads.records[publication.id]
        VStack(alignment: .leading, spacing: 4) {
            if let record {
                let copy = downloadCopy(record)
                HStack {
                    if record.isReady {
                        Image(systemName: "checkmark.circle").foregroundStyle(Palette.accent)
                    }
                    Text(copy.title).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink)
                    Spacer()
                    if record.isActive {
                        Button("Cancel") { downloads.cancel(publication.id) }.tint(Palette.accent)
                    } else {
                        Button("Remove") { confirmRemove = true }.tint(Palette.accent)
                    }
                }
                if record.isActive { ProgressRule(fraction: record.fraction ?? 0).padding(.vertical, 4) }
                caption(copy.detail)
                if record.isReady, !offline, !record.matches(publication) {
                    caption("A newer edition is on your server. Reading and listening use the server's copy until you update.")
                    Button("Update download") { downloads.enqueue(publication) }.tint(Palette.accent).padding(.top, 4)
                } else if copy.canRetry, !offline {
                    Button(record.state == .cancelled ? "Download again" : "Try again") {
                        if record.state == .cancelled { downloads.enqueue(publication) } else { downloads.retry(publication.id) }
                    }
                    .tint(Palette.accent)
                    .padding(.top, 4)
                }
            } else {
                let size = publication.playableAssets.reduce(Int64(0)) { $0 + $1.sizeBytes }
                Button {
                    downloads.enqueue(publication)
                } label: {
                    Label(size > 0 ? "Download · \(bytes(size))" : "Download", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(Palette.accent)
                .disabled(offline)
                if offline { caption("Connect to your server to download.") }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog("Remove download?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { downloads.remove(publication.id) }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("This deletes the files from this device. Your saved place and status stay, and you can download it again.")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
    }
}

/// Explicit status, which needs a connection and keeps the saved place.
struct StatusPicker: View {
    let publication: ShelfarrCore.Publication
    let offline: Bool
    let saving: ReadingStatus?
    let error: Error?
    let host: String?
    let select: (ReadingStatus) -> Void

    var body: some View {
        let current = saving ?? publication.status
        VStack(alignment: .leading, spacing: 8) {
            Text("Status").font(.footnote.weight(.medium)).foregroundStyle(Palette.inkMuted).accessibilityAddTraits(.isHeader)
            Picker("Status", selection: Binding(get: { current }, set: { select($0) })) {
                ForEach(ReadingStatus.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(offline || saving != nil)
            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(error == nil ? Palette.inkMuted : Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var note: String? {
        if offline { return "Connect to your server to change the status." }
        if saving != nil { return "Saving…" }
        if let error { return "Couldn't change the status. \(errorCopy(error, host: host).title)." }
        if publication.progress?.isUsable == true { return "Changing the status keeps your saved place." }
        return nil
    }
}

/// Everything this account keeps on the device, with what each download is doing.
struct DownloadsView: View {
    @ObservedObject var downloads: DownloadsModel
    @State private var removing: DownloadRecord?

    var body: some View {
        let records = downloads.records.values.sorted { $0.updatedAt > $1.updatedAt }
        Group {
            if records.isEmpty {
                MessageState(
                    title: "Nothing downloaded",
                    message: "Download a book or audiobook from its page to read or listen without a connection.",
                    systemImage: "arrow.down.circle"
                )
            } else {
                List {
                    Section {
                        ForEach(records) { record in
                            row(record)
                        }
                    } footer: {
                        let used = records.reduce(Int64(0)) { $0 + $1.bytesDone }
                        Text("\(bytes(used)) used on this device. Downloads continue while Shelfarr is open, and pick up where they stopped next time.")
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Downloads")
        .confirmationDialog(
            "Remove download?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { record in
            Button("Remove", role: .destructive) { downloads.remove(record.publicationId) }
            Button("Keep", role: .cancel) {}
        } message: { record in
            Text("“\(record.publication.title)” will be deleted from this device. Your saved place and status stay.")
        }
    }

    private func row(_ record: DownloadRecord) -> some View {
        let copy = downloadCopy(record)
        return HStack(alignment: .top, spacing: 12) {
            BookCover(publication: record.publication).frame(width: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.publication.title).font(Typeface.serifBold(16)).foregroundStyle(Palette.ink).lineLimit(2)
                Label(copy.title, systemImage: record.isReady ? "checkmark.circle" : "arrow.down.circle")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Palette.ink)
                if record.isActive { ProgressRule(fraction: record.fraction ?? 0) }
                Text(copy.detail).font(.footnote).foregroundStyle(Palette.inkMuted)
                HStack(spacing: 16) {
                    if record.isActive {
                        Button("Cancel") { downloads.cancel(record.publicationId) }
                    } else {
                        if copy.canRetry {
                            Button(record.state == .cancelled ? "Download again" : "Try again") {
                                if record.state == .cancelled { downloads.enqueue(record.publication) } else { downloads.retry(record.publicationId) }
                            }
                        }
                        Button("Remove") { removing = record }
                    }
                }
                .buttonStyle(.borderless)
                .tint(Palette.accent)
                .font(.footnote.weight(.medium))
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }
}

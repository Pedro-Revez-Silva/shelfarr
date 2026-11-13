import ShelfarrCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var downloads: DownloadsModel
    @State private var confirming = false
    @State private var disconnecting = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private var downloadsSummary: String {
        let records = Array(downloads.records.values)
        if records.isEmpty { return "Nothing downloaded" }
        let ready = records.filter(\.isReady)
        let active = records.filter(\.isActive).count
        var parts: [String] = []
        if !ready.isEmpty {
            let size = ByteCountFormatter.string(fromByteCount: ready.reduce(Int64(0)) { $0 + $1.bytesDone }, countStyle: .file)
            parts.append("\(ready.count) on this device · \(size)")
        }
        if active > 0 { parts.append("\(active) downloading") }
        if parts.isEmpty { parts.append("\(records.count) stopped") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        List {
            if let session = app.session {
                Section("Account") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.user.displayName).font(Typeface.serifBold(17))
                        if let username = session.user.username {
                            Text("@\(username)").font(.footnote).foregroundStyle(Palette.inkMuted)
                        }
                        Text(session.server.display).font(.footnote).foregroundStyle(Palette.inkMuted).padding(.top, 4)
                    }
                }
            }
            Section("Appearance") {
                Picker("Appearance", selection: $app.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section {
                NavigationLink {
                    DownloadsView(downloads: downloads)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Downloads")
                        Text(downloadsSummary).font(.footnote).foregroundStyle(Palette.inkMuted)
                    }
                }
            } header: {
                Text("On this device")
            } footer: {
                Text("Downloads stay until you remove them. They transfer in the background when your server allows it, otherwise while Shelfarr is open. Other books open from a temporary copy that iOS may clear, and other audio streams from your server. Your reading place is kept here and syncs when you're connected.")
            }
            Section {
                Button(disconnecting ? "Disconnecting…" : "Disconnect this device", role: .destructive) {
                    confirming = true
                }
                .disabled(disconnecting)
            } footer: {
                Text("Shelfarr \(version)")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Settings")
        .confirmationDialog(
            "Disconnect this device?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                disconnecting = true
                Task { await app.disconnect() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This signs out, stops playback and downloads, and removes downloads, book copies and saved places from this device. Your library stays on your server.")
        }
    }
}

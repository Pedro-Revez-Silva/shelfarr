import ShelfarrCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var confirming = false
    @State private var disconnecting = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
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
            Section("On this device") {
                Text("Books open from a temporary copy that iOS may clear, and audio streams from your server. Downloads for offline use aren't available yet. Your reading place is kept here and syncs when you're connected.")
                    .font(.footnote)
                    .foregroundStyle(Palette.inkMuted)
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
            Text("This signs out, stops playback and removes book copies and saved places from this device. Your library stays on your server.")
        }
    }
}

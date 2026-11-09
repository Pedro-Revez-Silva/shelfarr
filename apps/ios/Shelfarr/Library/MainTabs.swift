import ShelfarrCore
import SwiftUI

/// Bottom navigation with the now-playing strip above it.
struct MainTabs: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playback: PlaybackEngine
    @State private var showPlayer = false
    @State private var reading: ShelfarrCore.Publication?
    @State private var listening: ShelfarrCore.Publication?

    var body: some View {
        TabView {
            NavigationStack { HomeView(open: start) }
                .tabItem { Label("Home", systemImage: "book") }
            NavigationStack { LibraryView(open: start) }
                .tabItem { Label("Library", systemImage: "books.vertical") }
            FindTab(app: model, open: start)
                .tabItem { Label("Find", systemImage: "magnifyingglass") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if playback.publication != nil {
                MiniPlayer { showPlayer = true }.padding(.bottom, 49)
            }
        }
        .fullScreenCover(item: $reading, onDismiss: refresh) { ReaderView(publicationId: $0.id, app: model) }
        .fullScreenCover(item: $listening, onDismiss: refresh) { PlayerView(publicationId: $0.id, app: model) }
        .fullScreenCover(isPresented: $showPlayer, onDismiss: refresh) {
            if let publication = playback.publication {
                PlayerView(publicationId: publication.id, app: model)
            }
        }
    }

    private func refresh() {
        model.libraryGeneration += 1
    }

    private func start(_ publication: ShelfarrCore.Publication) {
        // An explicit Read or Listen may mark an unread book in progress; it never blocks opening.
        model.markStarted(publication)
        switch publication.bookType {
        case .ebook: reading = publication
        case .audiobook: listening = publication
        }
    }
}

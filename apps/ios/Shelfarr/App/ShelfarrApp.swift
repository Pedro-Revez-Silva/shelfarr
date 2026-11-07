import ShelfarrCore
import SwiftUI

@main
struct ShelfarrApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.playback)
                .environmentObject(model.downloads)
                .preferredColorScheme(model.appearance.colorScheme)
                .tint(Palette.accent)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active: model.onForeground()
            case .background: model.onBackground()
            default: break
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if let session = model.session {
                MainTabs().id(session.accountKey)
            } else {
                SetupFlow()
            }
        }
        .background(Palette.background.ignoresSafeArea())
    }
}

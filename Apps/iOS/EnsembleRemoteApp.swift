import EnsembleKit
import SwiftUI

@main
struct EnsembleRemoteApp: App {
    @State private var model = RemoteAppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        RemoteTheme.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .remoteThemeEnvironment()
                .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
        }
    }
}

struct RootView: View {
    @Environment(RemoteAppModel.self) private var model

    var body: some View {
        if let client = model.client {
            MainTabView(client: client)
                .id(ObjectIdentifier(client))
        } else {
            PairingView()
        }
    }
}

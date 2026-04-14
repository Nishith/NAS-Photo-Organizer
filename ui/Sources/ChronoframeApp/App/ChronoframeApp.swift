import SwiftUI

@main
struct ChronoframeApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("Chronoframe") {
            RootSplitView(appState: appState)
                .frame(minWidth: 860, idealWidth: 1_160, minHeight: 680, idealHeight: 800)
        }
        .commands {
            AppCommands(appState: appState)
        }

        Settings {
            SettingsView(appState: appState)
                .frame(minWidth: 420, idealWidth: 460, minHeight: 280)
                .padding()
        }
    }
}

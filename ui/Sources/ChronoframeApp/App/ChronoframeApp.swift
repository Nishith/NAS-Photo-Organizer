import SwiftUI
#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif

@main
struct ChronoframeApp: App {
    @StateObject private var appState = AppState()

    init() {
        RunSessionStore.requestNotificationPermission()
    }

    var body: some Scene {
        WindowGroup("Chronoframe") {
            RootSplitView(appState: appState)
                .frame(
                    minWidth: DesignTokens.Window.mainMinWidth,
                    idealWidth: DesignTokens.Window.mainIdealWidth,
                    minHeight: DesignTokens.Window.mainMinHeight,
                    idealHeight: DesignTokens.Window.mainIdealHeight
                )
        }
        .commands {
            AppCommands(appState: appState)
        }

        Settings {
            SettingsView(appState: appState)
                .frame(
                    minWidth: DesignTokens.Window.settingsMinWidth,
                    idealWidth: DesignTokens.Window.settingsIdealWidth,
                    minHeight: DesignTokens.Window.settingsMinHeight
                )
                .padding()
        }
    }
}

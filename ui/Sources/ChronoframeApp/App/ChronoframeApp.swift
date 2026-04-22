import SwiftUI
#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif

@main
struct ChronoframeApp: App {
    @StateObject private var appState: AppState
    @State private var didOpenScenarioSettings = false
    private let uiTestScenario: UITestScenario?

    init() {
        let scenario = UITestScenario.current()
        self.uiTestScenario = scenario
        self._appState = StateObject(
            wrappedValue: scenario.map { UITestAppStateFactory.make(scenario: $0) } ?? AppState()
        )
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
                .task {
                    guard uiTestScenario?.opensSettingsOnLaunch == true, !didOpenScenarioSettings else { return }
                    didOpenScenarioSettings = true
                    appState.openSettingsWindow()
                }
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

        Window("Chronoframe Help", id: HelpWindowID) {
            HelpView()
        }
        .windowResizability(.contentMinSize)
    }
}

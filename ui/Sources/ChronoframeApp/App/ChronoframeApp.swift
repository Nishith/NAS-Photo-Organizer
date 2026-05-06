import AppKit
import SwiftUI
@preconcurrency import UserNotifications
#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif

@main
struct ChronoframeApp: App {
    @NSApplicationDelegateAdaptor(ChronoframeAppDelegate.self) private var appDelegate
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
        Window("Chronoframe", id: ChronoframeApp.mainWindowID) {
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
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(appState: appState)
                .frame(
                    minWidth: DesignTokens.Window.settingsMinWidth,
                    idealWidth: DesignTokens.Window.settingsIdealWidth,
                    minHeight: DesignTokens.Window.settingsMinHeight
                )
                .padding()
        }

        Window("Chronoframe Help", id: ChronoframeApp.helpWindowID) {
            HelpView()
        }
        .windowResizability(.contentMinSize)
    }

    static let mainWindowID = "chronoframe-main"
    static let helpWindowID = "chronoframe-help"
}

@MainActor
final class ChronoframeAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        if let existingApplication = Self.alreadyRunningApplication() {
            existingApplication.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            self.activateMainWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            activateMainWindow()
        }
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await activateFromNotification()
    }

    private func activateMainWindow() {
        let mainWindow = NSApp.windows.first { $0.title == "Chronoframe" } ?? NSApp.windows.first
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func alreadyRunningApplication() -> NSRunningApplication? {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return nil }
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { application in
                application.processIdentifier != currentProcessIdentifier && !application.isTerminated
            }
            .min { lhs, rhs in
                lhs.processIdentifier < rhs.processIdentifier
            }
    }

    private nonisolated func activateFromNotification() async {
        await MainActor.run {
            activateMainWindow()
        }
    }
}

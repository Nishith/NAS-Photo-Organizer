#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

struct AppCommands: Commands {
    let appState: AppState
    @ObservedObject private var setupStore: SetupStore
    @ObservedObject private var runSessionStore: RunSessionStore

    init(appState: AppState) {
        self.appState = appState
        self._setupStore = ObservedObject(wrappedValue: appState.setupStore)
        self._runSessionStore = ObservedObject(wrappedValue: appState.runSessionStore)
    }

    var body: some Commands {
        CommandMenu("Library") {
            Button("Choose Source…") {
                Task { await appState.chooseSourceFolder() }
            }
            .keyboardShortcut("o", modifiers: [.command])

            Button("Choose Destination…") {
                Task { await appState.chooseDestinationFolder() }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Divider()

            Button("Refresh Profiles") {
                appState.refreshProfiles()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
        }

        CommandMenu("Run") {
            Button("Preview") {
                Task { await appState.startPreview() }
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(!canStartRun || runSessionStore.isRunning)

            Button("Transfer") {
                Task { await appState.startTransfer() }
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!canStartRun || runSessionStore.isRunning)

            Divider()

            Button("Cancel Run") {
                appState.cancelRun()
            }
            .disabled(!runSessionStore.isRunning)
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                appState.openSettingsWindow()
            }
            .keyboardShortcut(",", modifiers: [.command])
        }
    }

    private var canStartRun: Bool {
        setupStore.usingProfile || (!setupStore.sourcePath.isEmpty && !setupStore.destinationPath.isEmpty)
    }
}

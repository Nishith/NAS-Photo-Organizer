#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

struct AppCommands: Commands {
    @ObservedObject var appState: AppState

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
            .disabled(!appState.canStartRun || appState.runSessionStore.isRunning)

            Button("Transfer") {
                Task { await appState.startTransfer() }
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!appState.canStartRun || appState.runSessionStore.isRunning)

            Divider()

            Button("Cancel Run") {
                appState.cancelRun()
            }
            .disabled(!appState.runSessionStore.isRunning)
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                appState.openSettingsWindow()
            }
            .keyboardShortcut(",", modifiers: [.command])
        }
    }
}

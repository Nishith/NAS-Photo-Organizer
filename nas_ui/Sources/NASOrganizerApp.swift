import SwiftUI
import Foundation

extension Notification.Name {
    static let chooseSourceFolder = Notification.Name("nasOrganizer.chooseSourceFolder")
    static let chooseDestinationFolder = Notification.Name("nasOrganizer.chooseDestinationFolder")
    static let activateProfileField = Notification.Name("nasOrganizer.activateProfileField")
    static let triggerPreviewRun = Notification.Name("nasOrganizer.triggerPreviewRun")
    static let triggerTransferRun = Notification.Name("nasOrganizer.triggerTransferRun")
    static let toggleActivityPane = Notification.Name("nasOrganizer.toggleActivityPane")
}

@main
struct NASOrganizerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 980, minHeight: 700)
        }
        .windowStyle(HiddenTitleBarWindowStyle())
        .commands {
            CommandMenu("Library") {
                Button("Choose Source…") {
                    NotificationCenter.default.post(name: .chooseSourceFolder, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Choose Destination…") {
                    NotificationCenter.default.post(name: .chooseDestinationFolder, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                Button("Reveal Saved Profile") {
                    NotificationCenter.default.post(name: .activateProfileField, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }

            CommandMenu("Run") {
                Button("Preview") {
                    NotificationCenter.default.post(name: .triggerPreviewRun, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Transfer") {
                    NotificationCenter.default.post(name: .triggerTransferRun, object: nil)
                }
                .keyboardShortcut(.return, modifiers: [.command])
            }

            CommandMenu("Workspace") {
                Button("Toggle Activity Pane") {
                    NotificationCenter.default.post(name: .toggleActivityPane, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command])
            }
        }
    }
}

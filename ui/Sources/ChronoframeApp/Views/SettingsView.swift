#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Stepper(value: $appState.preferencesStore.workerCount, in: 1...32) {
                LabeledContent("Worker Threads") {
                    Text("\(appState.preferencesStore.workerCount)")
                        .monospacedDigit()
                }
            }

            Toggle("Use Cached Destination Scan", isOn: $appState.preferencesStore.useFastDestinationScan)
            Toggle("Verify Completed Copies", isOn: $appState.preferencesStore.verifyCopies)

            Stepper(value: $appState.preferencesStore.logBufferCapacity, in: PreferencesStore.minimumLogCapacity...PreferencesStore.maximumLogCapacity, step: 250) {
                LabeledContent("In-Memory Log Buffer") {
                    Text("\(appState.preferencesStore.logBufferCapacity)")
                        .monospacedDigit()
                }
            }
        }
        .onChange(of: appState.preferencesStore.logBufferCapacity) { newValue in
            appState.runLogStore.capacity = newValue
        }
        .navigationTitle("Settings")
    }
}

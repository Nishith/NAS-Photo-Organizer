#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

struct SettingsView: View {
    let appState: AppState
    @ObservedObject private var preferencesStore: PreferencesStore

    init(appState: AppState) {
        self.appState = appState
        self._preferencesStore = ObservedObject(wrappedValue: appState.preferencesStore)
    }

    var body: some View {
        Form {
            Stepper(value: $preferencesStore.workerCount, in: 1...32) {
                LabeledContent("Worker Threads") {
                    Text("\(preferencesStore.workerCount)")
                        .monospacedDigit()
                }
            }

            Toggle("Use Cached Destination Scan", isOn: $preferencesStore.useFastDestinationScan)
            Toggle("Verify Completed Copies", isOn: $preferencesStore.verifyCopies)

            Stepper(
                value: $preferencesStore.logBufferCapacity,
                in: PreferencesStore.minimumLogCapacity...PreferencesStore.maximumLogCapacity,
                step: 250
            ) {
                LabeledContent("In-Memory Log Buffer") {
                    Text("\(preferencesStore.logBufferCapacity)")
                        .monospacedDigit()
                }
            }
        }
        .onChange(of: preferencesStore.logBufferCapacity) { newValue in
            appState.runLogStore.capacity = newValue
        }
        .navigationTitle("Settings")
    }
}

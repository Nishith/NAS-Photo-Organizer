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
            Section {
                Text("Tune how Chronoframe balances speed, safety, and diagnostics. These settings affect future previews and transfers without changing the organizer’s core guarantees.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Stepper(value: $preferencesStore.workerCount, in: 1...32) {
                    LabeledContent("Worker Threads") {
                        Text("\(preferencesStore.workerCount)")
                            .monospacedDigit()
                    }
                }

                Toggle("Use Cached Destination Scan", isOn: $preferencesStore.useFastDestinationScan)
            } header: {
                Text("Performance")
            } footer: {
                Text("More worker threads can improve throughput on faster storage. Cached destination scanning speeds up repeated runs by reading the existing index instead of rebuilding it every time.")
            }

            Section {
                Toggle("Verify Completed Copies", isOn: $preferencesStore.verifyCopies)
            } header: {
                Text("Safety")
            } footer: {
                Text("Verification re-hashes copied files after transfer. It adds work, but it provides stronger confidence that destination files match the originals.")
            }

            Section {
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
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("A larger buffer keeps more recent console history in memory for the Run workspace. Lower values use less memory but trim older log lines sooner.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: preferencesStore.logBufferCapacity) { newValue in
            appState.runLogStore.capacity = newValue
        }
        .navigationTitle("Settings")
    }
}

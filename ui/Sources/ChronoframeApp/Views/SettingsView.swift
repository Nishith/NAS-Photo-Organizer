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
        TabView {
            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            LayoutSettingsTab(appState: appState, preferencesStore: preferencesStore)
                .tabItem {
                    Label("Layout", systemImage: "rectangle.3.offgrid")
                }

            PerformanceSettingsTab(preferencesStore: preferencesStore)
                .tabItem {
                    Label("Performance", systemImage: "speedometer")
                }

            DeduplicateSettingsTab(preferencesStore: preferencesStore)
                .tabItem {
                    Label("Deduplicate", systemImage: "rectangle.on.rectangle.angled")
                }

            DiagnosticsSettingsTab(appState: appState, preferencesStore: preferencesStore)
                .tabItem {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 360)
        .onAppear {
            UITestScenario.configureCurrentWindow(for: UITestScenario.current(), isSettings: true)
        }
        .navigationTitle("Settings")
    }
}

private struct LayoutSettingsTab: View {
    let appState: AppState
    @ObservedObject var preferencesStore: PreferencesStore
    @State private var showingReorganizeConfirmation = false

    var body: some View {
        Form {
            Section {
                Picker("Folder Structure", selection: $preferencesStore.folderStructure) {
                    ForEach(FolderStructure.allCases, id: \.self) { structure in
                        Text(structure.rawValue).tag(structure)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("folderStructurePicker")
            } header: {
                Text("Default Layout")
            } footer: {
                Text("Future previews and transfers organize files into this directory layout. Existing files in the destination keep their current location until you reorganize.")
            }

            Section {
                Button {
                    showingReorganizeConfirmation = true
                } label: {
                    Label("Reorganize Destination Now", systemImage: "rectangle.3.offgrid.fill")
                }
                .accessibilityIdentifier("reorganizeDestinationButton")
            } header: {
                Text("Reorganize")
            } footer: {
                Text("Move every file already in the destination into the layout selected above. Files are moved on the same volume (instant — no copy), originals are never deleted, and an existing file at the new location is never overwritten.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Reorganize destination?",
            isPresented: $showingReorganizeConfirmation
        ) {
            Button("Reorganize", role: .destructive) {
                appState.reorganizeDestination(targetStructure: preferencesStore.folderStructure)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Chronoframe will move every recognised file in the destination into the \(preferencesStore.folderStructure.rawValue) layout. Originals are not deleted, but files will appear at new paths. Open the Run workspace to track progress.")
        }
    }
}

private struct GeneralSettingsTab: View {
    var body: some View {
        Form {
            Section {
                Text("Tune how Chronoframe balances speed, safety, and diagnostics. These settings affect future previews and transfers without changing the organizer's core guarantees.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PerformanceSettingsTab: View {
    @ObservedObject var preferencesStore: PreferencesStore

    var body: some View {
        Form {
            Section {
                Stepper(value: $preferencesStore.workerCount, in: 1...32) {
                    LabeledContent("Worker Threads") {
                        Text("\(preferencesStore.workerCount)")
                            .monospacedDigit()
                    }
                }

                Toggle("Use Cached Destination Scan", isOn: $preferencesStore.useFastDestinationScan)
                Toggle("Parallel Transfers", isOn: $preferencesStore.parallelTransferEnabled)
            } header: {
                Text("Throughput")
            } footer: {
                Text("More worker threads can improve throughput on faster storage. Cached destination scanning speeds up repeated runs by reading the existing index. Parallel transfers are off by default and only affect future transfer runs.")
            }

            Section {
                Toggle("Verify Completed Copies", isOn: $preferencesStore.verifyCopies)
            } header: {
                Text("Safety")
            } footer: {
                Text("Verification re-hashes copied files after transfer. It adds work, but it provides stronger confidence that destination files match the originals.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct DeduplicateSettingsTab: View {
    @ObservedObject var preferencesStore: PreferencesStore
    @State private var pendingHardDeleteToggle = false

    var body: some View {
        Form {
            Section {
                Picker("Similarity", selection: $preferencesStore.dedupeSimilarityPreset) {
                    ForEach(DedupeSimilarityPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)

                Text(preferencesStore.dedupeSimilarityPreset.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Stepper(value: $preferencesStore.dedupeTimeWindowSeconds, in: 5...600, step: 5) {
                    LabeledContent("Time Window") {
                        Text("\(preferencesStore.dedupeTimeWindowSeconds)s")
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("Detection")
            } footer: {
                Text("Photos taken within the time window are compared for similarity. Stricter presets reduce false positives; looser presets surface more potential duplicates.")
            }

            Section {
                Toggle("Treat RAW + JPEG as a unit", isOn: $preferencesStore.dedupeTreatRawJpegPairsAsUnit)
                Toggle("Treat Live Photo (HEIC + MOV) as a unit", isOn: $preferencesStore.dedupeTreatLivePhotoPairsAsUnit)
                Toggle("Surface exact duplicates separately", isOn: $preferencesStore.dedupeIncludeExactDuplicates)
            } header: {
                Text("Pairing")
            } footer: {
                Text("Paired files are always kept or deleted together. Exact duplicates use the existing file-identity hash and are surfaced as their own group.")
            }

            Section {
                Toggle("Allow hard delete (skip Trash)", isOn: Binding(
                    get: { preferencesStore.dedupeAllowHardDelete },
                    set: { newValue in
                        if newValue {
                            pendingHardDeleteToggle = true
                        } else {
                            preferencesStore.dedupeAllowHardDelete = false
                        }
                    }
                ))
            } header: {
                Text("Deletion")
            } footer: {
                Text("By default, Deduplicate moves files to the Trash so you can recover them. Hard delete unlinks files immediately and cannot be undone.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Allow hard delete?",
            isPresented: $pendingHardDeleteToggle
        ) {
            Button("Allow", role: .destructive) {
                preferencesStore.dedupeAllowHardDelete = true
            }
            Button("Cancel", role: .cancel) {
                pendingHardDeleteToggle = false
            }
        } message: {
            Text("Files removed by Deduplicate will bypass the Trash and cannot be recovered. The dedupe receipt in Run History will still record what was deleted but the Revert action will not be able to restore the files.")
        }
    }
}

private struct DiagnosticsSettingsTab: View {
    let appState: AppState
    @ObservedObject var preferencesStore: PreferencesStore

    var body: some View {
        Form {
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
                .accessibilityIdentifier("diagnosticsLogBufferStepper")
            } header: {
                Text("Log Buffer")
            } footer: {
                Text("A larger buffer keeps more recent console history in memory for the Run workspace. Lower values use less memory but trim older log lines sooner.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: preferencesStore.logBufferCapacity) { newValue in
            appState.runLogStore.capacity = newValue
        }
    }
}

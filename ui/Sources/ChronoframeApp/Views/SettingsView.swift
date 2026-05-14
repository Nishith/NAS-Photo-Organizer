#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

enum SettingsTab: String, Hashable {
    case general
    case profiles
    case layout
    case performance
    case deduplicate
    case diagnostics
}

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var preferencesStore: PreferencesStore

    init(appState: AppState) {
        self._appState = ObservedObject(wrappedValue: appState)
        self._preferencesStore = ObservedObject(wrappedValue: appState.preferencesStore)
    }

    var body: some View {
        TabView(selection: $appState.settingsSelection) {
            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(SettingsTab.general)

            ProfilesView(appState: appState, displayMode: .settings)
                .tabItem {
                    Label("Profiles", systemImage: "person.crop.rectangle.stack")
                }
                .tag(SettingsTab.profiles)

            LayoutSettingsTab(appState: appState, preferencesStore: preferencesStore)
                .tabItem {
                    Label("Layout", systemImage: "rectangle.3.offgrid")
                }
                .tag(SettingsTab.layout)

            PerformanceSettingsTab(preferencesStore: preferencesStore)
                .tabItem {
                    Label("Performance", systemImage: "speedometer")
                }
                .tag(SettingsTab.performance)

            DeduplicateSettingsTab(preferencesStore: preferencesStore)
                .tabItem {
                    Label("Deduplicate", systemImage: "rectangle.on.rectangle.angled")
                }
                .tag(SettingsTab.deduplicate)

            DiagnosticsSettingsTab(appState: appState, preferencesStore: preferencesStore)
                .tabItem {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
                .tag(SettingsTab.diagnostics)
        }
        .frame(minWidth: 620, idealWidth: 760, minHeight: 520)
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

                Toggle("Suggest Smart Events During Preview", isOn: $preferencesStore.smartEventSuggestionsEnabled)
                    .accessibilityIdentifier("smartEventSuggestionsToggle")
            } header: {
                Text("Default Layout")
            } footer: {
                Text("Future previews and transfers organize files into this directory layout. Smart Events suggest editable groups in Preview; they are only applied after you accept them and rebuild the preview.")
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

private enum SafetyPerformancePreset: String, CaseIterable, Identifiable {
    case safest
    case balanced
    case fastRepeat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .safest:
            return "Safest"
        case .balanced:
            return "Balanced"
        case .fastRepeat:
            return "Fast Repeat Runs"
        }
    }

    var summary: String {
        switch self {
        case .safest:
            return "Verification on, full destination scan, serial transfer."
        case .balanced:
            return "Verification on with cached destination scanning."
        case .fastRepeat:
            return "Cached scanning and parallel transfer for familiar destinations."
        }
    }

    func apply(to preferencesStore: PreferencesStore) {
        switch self {
        case .safest:
            preferencesStore.verifyCopies = true
            preferencesStore.useFastDestinationScan = false
            preferencesStore.parallelTransferEnabled = false
            preferencesStore.workerCount = min(preferencesStore.workerCount, 8)
        case .balanced:
            preferencesStore.verifyCopies = true
            preferencesStore.useFastDestinationScan = true
            preferencesStore.parallelTransferEnabled = false
            preferencesStore.workerCount = max(4, min(preferencesStore.workerCount, 12))
        case .fastRepeat:
            preferencesStore.verifyCopies = true
            preferencesStore.useFastDestinationScan = true
            preferencesStore.parallelTransferEnabled = true
            preferencesStore.workerCount = max(preferencesStore.workerCount, 12)
        }
    }
}

private struct PerformanceSettingsTab: View {
    @ObservedObject var preferencesStore: PreferencesStore

    var body: some View {
        Form {
            Section {
                ForEach(SafetyPerformancePreset.allCases) { preset in
                    Button {
                        preset.apply(to: preferencesStore)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.title)
                                Text(preset.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(DesignTokens.ColorSystem.accentAction)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Presets")
            } footer: {
                Text("Presets adjust the advanced controls below without weakening Chronoframe's source-folder safety guarantees.")
            }

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

    var body: some View {
        Form {
            Section {
                Toggle("Burst mode", isOn: $preferencesStore.dedupeBurstModeEnabled)

                Picker("Similarity", selection: $preferencesStore.dedupeSimilarityPreset) {
                    ForEach(DedupeSimilarityPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)

                Text(preferencesStore.dedupeSimilarityPreset.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if preferencesStore.dedupeBurstModeEnabled {
                    Stepper(value: $preferencesStore.dedupeTimeWindowSeconds, in: 5...600, step: 5) {
                        LabeledContent("Time Window") {
                            Text("\(preferencesStore.dedupeTimeWindowSeconds)s")
                                .monospacedDigit()
                        }
                    }
                }
            } header: {
                Text("Detection")
            } footer: {
                Text(preferencesStore.dedupeBurstModeEnabled
                    ? "Burst mode only compares photos taken within the time window — fast, ideal for catching burst sequences and rapid retakes. Stricter similarity presets reduce false positives; looser presets surface more potential duplicates."
                    : "Without burst mode, every photo in the destination is compared against every other. Slower on large libraries, but catches duplicates that don't share a capture time.")
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
        }
        .formStyle(.grouped)
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

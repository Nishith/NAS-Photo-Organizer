#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

struct SetupView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Setup")
                        .font(.largeTitle.weight(.bold))
                    Text("Choose a source and destination, or reuse a saved profile. Preview remains the recommended first move.")
                        .foregroundStyle(.secondary)
                }

                GroupBox("Run Mode") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker(
                            "Use Profile",
                            selection: Binding(
                                get: { appState.setupStore.selectedProfileName },
                                set: { selection in
                                    if selection.isEmpty {
                                        appState.clearSelectedProfile()
                                    } else {
                                        appState.useProfile(named: selection)
                                    }
                                }
                            )
                        ) {
                            Text("Manual Paths").tag("")
                            ForEach(appState.setupStore.profiles) { profile in
                                Text(profile.name).tag(profile.name)
                            }
                        }
                        .pickerStyle(.menu)

                        HStack {
                            Text("Profiles file")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(RuntimePaths.profilesFileURL().path)
                                .font(.callout.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        HStack {
                            Button("Refresh Profiles") {
                                appState.refreshProfiles()
                            }
                            if appState.setupStore.usingProfile {
                                Button("Clear Profile") {
                                    appState.clearSelectedProfile()
                                }
                            }
                        }
                    }
                }

                GroupBox("Folders") {
                    VStack(alignment: .leading, spacing: 16) {
                        pathRow(
                            title: "Source",
                            value: appState.setupStore.sourcePath,
                            helper: "The organizer never mutates this library.",
                            actionTitle: "Choose Source…"
                        ) {
                            Task { await appState.chooseSourceFolder() }
                        }

                        pathRow(
                            title: "Destination",
                            value: appState.setupStore.destinationPath,
                            helper: "Chronoframe writes queue state, logs, and reports here.",
                            actionTitle: "Choose Destination…"
                        ) {
                            Task { await appState.chooseDestinationFolder() }
                        }
                    }
                }

                GroupBox("Run") {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("Workers") {
                            Text("\(appState.preferencesStore.workerCount)")
                                .monospacedDigit()
                        }
                        LabeledContent("Fast Destination Scan") {
                            Text(appState.preferencesStore.useFastDestinationScan ? "On" : "Off")
                        }
                        LabeledContent("Verify Copies") {
                            Text(appState.preferencesStore.verifyCopies ? "On" : "Off")
                        }

                        HStack(spacing: 12) {
                            Button {
                                Task { await appState.startPreview() }
                            } label: {
                                Label("Preview", systemImage: "eye")
                            }
                            .buttonStyle(.bordered)
                            .disabled(!appState.canStartRun || appState.runSessionStore.isRunning)

                            Button {
                                Task { await appState.startTransfer() }
                            } label: {
                                Label("Transfer", systemImage: "arrow.right.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!appState.canStartRun || appState.runSessionStore.isRunning)

                            Spacer()

                            Button {
                                appState.openSettingsWindow()
                            } label: {
                                Label("Settings", systemImage: "gearshape")
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Setup")
    }

    private func pathRow(title: String, value: String, helper: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button(actionTitle, action: action)
            }

            Text(value.isEmpty ? "Not set" : value)
                .foregroundStyle(value.isEmpty ? .secondary : .primary)
                .lineLimit(2)
                .truncationMode(.middle)

            Text(helper)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

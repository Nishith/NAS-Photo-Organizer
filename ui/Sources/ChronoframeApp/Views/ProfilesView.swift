#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

struct ProfilesView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Profiles")
                    .font(.largeTitle.weight(.bold))
                Text("Profiles remain compatible with `profiles.yaml` so the CLI and app can reuse the same source/destination pairs.")
                    .foregroundStyle(.secondary)
            }

            GroupBox("Save Current Paths") {
                HStack(spacing: 12) {
                    TextField("Profile name", text: $appState.setupStore.newProfileName)
                    Button("Save Current Paths") {
                        appState.saveCurrentPathsAsProfile()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if appState.setupStore.profiles.isEmpty {
                EmptyStateView(
                    title: "No Saved Profiles",
                    message: "Save the current source and destination to create a reusable setup.",
                    systemImage: "person.crop.rectangle.stack"
                )
            } else {
                List(appState.setupStore.profiles) { profile in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(profile.name)
                                .font(.headline)
                            if profile.name == appState.setupStore.selectedProfileName {
                                Text("Active")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.thinMaterial, in: Capsule())
                            }
                            Spacer()
                            Button("Use") {
                                appState.useProfile(named: profile.name)
                                appState.selection = .setup
                            }
                            Button("Overwrite") {
                                appState.overwriteProfile(named: profile.name)
                            }
                            Button("Delete", role: .destructive) {
                                appState.deleteProfile(named: profile.name)
                            }
                        }

                        Text("Source: \(profile.sourcePath)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("Destination: \(profile.destinationPath)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
        .padding(24)
        .navigationTitle("Profiles")
    }
}

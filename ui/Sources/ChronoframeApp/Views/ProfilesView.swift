#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

struct ProfilesView: View {
    let appState: AppState
    @ObservedObject private var setupStore: SetupStore

    init(appState: AppState) {
        self.appState = appState
        self._setupStore = ObservedObject(wrappedValue: appState.setupStore)
    }

    var body: some View {
        List {
            Section("Save Current Paths") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        TextField("Profile name", text: $setupStore.newProfileName)
                        Button("Save Current Paths") {
                            appState.saveCurrentPathsAsProfile()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Profile name", text: $setupStore.newProfileName)
                        Button("Save Current Paths") {
                            appState.saveCurrentPathsAsProfile()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                Text("Profiles stay compatible with `profiles.yaml` so the app and CLI can share the same saved source and destination.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Saved Profiles") {
                if setupStore.profiles.isEmpty {
                    EmptyStateView(
                        title: "No Saved Profiles",
                        message: "Save the current source and destination to create a reusable setup.",
                        systemImage: "person.crop.rectangle.stack"
                    )
                    .listRowInsets(EdgeInsets())
                } else {
                    ForEach(setupStore.profiles) { profile in
                        profileRow(for: profile)
                            .padding(.vertical, 4)
                    }
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle("Profiles")
    }

    private func profileRow(for profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(profile.name)
                    .font(.headline)

                if profile.name == setupStore.selectedProfileName {
                    Text("Active")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.thinMaterial, in: Capsule())
                }

                Spacer(minLength: 12)

                profileActions(for: profile)
            }

            Text(profile.sourcePath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(profile.destinationPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func profileActions(for profile: Profile) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
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

            Menu("Actions") {
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
        }
    }
}

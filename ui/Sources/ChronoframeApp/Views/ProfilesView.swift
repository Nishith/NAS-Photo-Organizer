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
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.sectionSpacing) {
                heroCard
                saveCurrentPathsCard
                savedProfilesCard
            }
            .padding(DesignTokens.Layout.contentPadding)
            .frame(maxWidth: DesignTokens.Layout.archiveMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Profiles")
    }

    private var heroCard: some View {
        DetailHeroCard(
            eyebrow: "Saved Setup",
            title: "Reuse the Same Library Configuration",
            message: "Profiles preserve a trusted source and destination pair so repeated runs feel instant and stay compatible with the CLI.",
            badgeTitle: setupStore.usingProfile ? "Active Profile" : "Manual Paths",
            badgeSystemImage: setupStore.usingProfile ? "bookmark.fill" : "square.and.pencil",
            tint: setupStore.usingProfile ? DesignTokens.Color.sky : DesignTokens.Color.inkMuted,
            systemImage: "person.crop.rectangle.stack"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                SummaryLine(title: "Saved Profiles", value: "\(setupStore.profiles.count)")
                SummaryLine(title: "Current Mode", value: setupStore.usingProfile ? "Using \(setupStore.selectedProfileName)" : "Manual source and destination")
                SummaryLine(title: "Next Step", value: setupStore.profiles.isEmpty ? "Save the current paths to create your first profile" : "Activate a profile and return to Setup")
            }
        } actions: {
            Button("Return to Setup") {
                appState.selection = .setup
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var saveCurrentPathsCard: some View {
        MeridianSurfaceCard {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.cardSpacing) {
                SectionHeading(
                    eyebrow: "Save Current Paths",
                    title: "Create a Reusable Setup",
                    message: "Capture the source and destination that are currently configured so you can recall them in one step later."
                )

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        TextField("Profile name", text: $setupStore.newProfileName)
                            .textFieldStyle(.roundedBorder)

                        Button("Save Current Paths") {
                            appState.saveCurrentPathsAsProfile()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Profile name", text: $setupStore.newProfileName)
                            .textFieldStyle(.roundedBorder)

                        Button("Save Current Paths") {
                            appState.saveCurrentPathsAsProfile()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                MeridianSurfaceCard(style: .inner, tint: DesignTokens.Color.aqua) {
                    VStack(alignment: .leading, spacing: 12) {
                        SummaryLine(title: "Source", value: setupStore.sourcePath.isEmpty ? "Not set" : setupStore.sourcePath)
                        SummaryLine(title: "Destination", value: setupStore.destinationPath.isEmpty ? "Not set" : setupStore.destinationPath)
                    }
                }
            }
        }
    }

    private var savedProfilesCard: some View {
        MeridianSurfaceCard {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.cardSpacing) {
                SectionHeading(
                    eyebrow: "Saved Profiles",
                    title: "Choose the Setup You Want to Reuse",
                    message: "Use makes a profile active, overwrite refreshes it with the current paths, and delete removes it from the shared profiles file."
                )

                if setupStore.profiles.isEmpty {
                    EmptyStateView(
                        title: "No Saved Profiles",
                        message: "Save the current source and destination to create a reusable setup that works in both the app and the CLI.",
                        systemImage: "bookmark"
                    )
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(setupStore.profiles) { profile in
                            profileRow(for: profile)
                        }
                    }
                }
            }
        }
    }

    private func profileRow(for profile: Profile) -> some View {
        let isActive = profile.name == setupStore.selectedProfileName

        return MeridianSurfaceCard(style: .inner, tint: isActive ? DesignTokens.Color.sky : DesignTokens.Color.cloud) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(profile.name)
                            .font(DesignTokens.Typography.cardTitle)
                            .foregroundStyle(DesignTokens.Color.inkPrimary)

                        Text(isActive ? "Active in Setup right now" : "Ready to activate")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    if isActive {
                        MeridianStatusBadge(
                            title: "Active",
                            systemImage: "checkmark.circle.fill",
                            tint: DesignTokens.Color.success
                        )
                    }
                }

                SummaryLine(title: "Source", value: profile.sourcePath)
                SummaryLine(title: "Destination", value: profile.destinationPath)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Button("Use") {
                            appState.useProfile(named: profile.name)
                            appState.selection = .setup
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Overwrite") {
                            appState.overwriteProfile(named: profile.name)
                        }

                        Menu("More") {
                            Button("Delete", role: .destructive) {
                                appState.deleteProfile(named: profile.name)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Button("Use") {
                            appState.useProfile(named: profile.name)
                            appState.selection = .setup
                        }
                        .buttonStyle(.borderedProminent)

                        HStack(spacing: 8) {
                            Button("Overwrite") {
                                appState.overwriteProfile(named: profile.name)
                            }

                            Menu("More") {
                                Button("Delete", role: .destructive) {
                                    appState.deleteProfile(named: profile.name)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

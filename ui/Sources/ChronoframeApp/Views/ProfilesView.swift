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
                headerStrip
                saveCurrentPaths
                savedProfilesGrid
            }
            .padding(DesignTokens.Layout.contentPadding)
            .frame(maxWidth: DesignTokens.Layout.archiveMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .darkroom()
        .navigationTitle("Profiles")
    }

    // MARK: - Header strip (replaces hero card)

    private var headerStrip: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Profiles")
                    .font(DesignTokens.Typography.title)
                    .foregroundStyle(DesignTokens.ColorSystem.inkPrimary)

                Text(summaryMessage)
                    .font(DesignTokens.Typography.subtitle)
                    .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)
            }

            Spacer(minLength: DesignTokens.Spacing.md)

            Button("Return to Setup") {
                appState.selection = .setup
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var summaryMessage: String {
        if setupStore.profiles.isEmpty {
            return "Save the current source and destination to create your first reusable profile."
        }
        if setupStore.usingProfile {
            return "Active profile: \(setupStore.selectedProfileName)."
        }
        return "\(setupStore.profiles.count) saved · manual paths in use."
    }

    // MARK: - Save current paths

    private var saveCurrentPaths: some View {
        DarkroomPanel(variant: .panel) {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.cardSpacing) {
                SectionHeading(
                    title: "Save Current Paths",
                    message: "Capture the source and destination configured in Setup."
                )

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DesignTokens.Spacing.md) {
                        TextField("Profile name", text: $setupStore.newProfileName)
                            .textFieldStyle(.roundedBorder)

                        Button("Save") {
                            appState.saveCurrentPathsAsProfile()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                        TextField("Profile name", text: $setupStore.newProfileName)
                            .textFieldStyle(.roundedBorder)

                        Button("Save") {
                            appState.saveCurrentPathsAsProfile()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    currentPathRow(label: "Source", value: setupStore.sourcePath)
                    Rectangle()
                        .fill(DesignTokens.ColorSystem.hairline)
                        .frame(height: 0.5)
                    currentPathRow(label: "Destination", value: setupStore.destinationPath)
                }
            }
        }
    }

    private func currentPathRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.md) {
            Text(label)
                .font(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
                .tracking(0.6)
                .frame(width: 96, alignment: .leading)

            Text(value.isEmpty ? "Not set" : value)
                .font(DesignTokens.Typography.mono)
                .foregroundStyle(value.isEmpty ? DesignTokens.ColorSystem.inkMuted : DesignTokens.ColorSystem.inkPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, DesignTokens.Spacing.sm)
    }

    // MARK: - Saved profiles grid

    private var savedProfilesGrid: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Layout.cardSpacing) {
            SectionHeading(
                title: "Saved Profiles",
                message: setupStore.profiles.isEmpty
                    ? "No profiles yet — save one above to reuse it later."
                    : "Use activates a profile in Setup. Overwrite refreshes it with the current paths."
            )

            if setupStore.profiles.isEmpty {
                EmptyStateView(
                    title: "No Saved Profiles",
                    message: "Save the current source and destination to create a reusable setup that works in both the app and the CLI.",
                    systemImage: "bookmark"
                )
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 280, maximum: 380), spacing: DesignTokens.Layout.cardSpacing, alignment: .top)
                    ],
                    alignment: .leading,
                    spacing: DesignTokens.Layout.cardSpacing
                ) {
                    ForEach(setupStore.profiles) { profile in
                        ProfileTile(
                            profile: profile,
                            isActive: profile.name == setupStore.selectedProfileName && setupStore.usingProfile,
                            onUse: {
                                appState.useProfile(named: profile.name)
                                appState.selection = .setup
                            },
                            onOverwrite: { appState.overwriteProfile(named: profile.name) },
                            onDelete: { appState.deleteProfile(named: profile.name) }
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Profile tile

private struct ProfileTile: View {
    let profile: Profile
    let isActive: Bool
    let onUse: () -> Void
    let onOverwrite: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        DarkroomPanel(variant: .panel) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                    Text(profile.name)
                        .font(DesignTokens.Typography.cardTitle)
                        .foregroundStyle(DesignTokens.ColorSystem.inkPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("profileName-\(profile.name)")

                    Spacer(minLength: DesignTokens.Spacing.sm)

                    if isActive {
                        Circle()
                            .fill(DesignTokens.ColorSystem.statusActive)
                            .frame(width: 7, height: 7)
                            .accessibilityIdentifier("activeProfileBadge")
                            .accessibilityLabel("Active")
                    }

                    Menu {
                        Button("Overwrite with Current Paths", action: onOverwrite)
                        Divider()
                        Button("Delete", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
                            .frame(width: 22, height: 22)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .opacity(isHovering || isActive ? 1 : 0.5)
                    .accessibilityLabel("More actions for \(profile.name)")
                }

                VStack(alignment: .leading, spacing: 0) {
                    pathRow(icon: "arrow.up.forward", label: "From", value: profile.sourcePath)
                    Rectangle()
                        .fill(DesignTokens.ColorSystem.hairline)
                        .frame(height: 0.5)
                    pathRow(icon: "arrow.down.forward", label: "To", value: profile.destinationPath)
                }

                Button(action: onUse) {
                    Text(isActive ? "Open in Setup" : "Use")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
    }

    private func pathRow(icon: String, label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
                .frame(width: 14)

            Text(label)
                .font(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
                .tracking(0.6)
                .frame(width: 36, alignment: .leading)

            Text(value)
                .font(DesignTokens.Typography.mono)
                .foregroundStyle(DesignTokens.ColorSystem.inkPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
    }
}

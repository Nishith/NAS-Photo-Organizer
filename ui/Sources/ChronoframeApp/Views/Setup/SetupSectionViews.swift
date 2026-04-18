import SwiftUI
#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import UniformTypeIdentifiers

struct SetupHeroSection: View {
    let model: SetupScreenModel
    let primaryAction: () -> Void

    var body: some View {
        DetailHeroCard(
            title: "Setup",
            message: "",
            badgeTitle: model.heroBadgeTitle,
            badgeSystemImage: model.heroBadgeSymbol,
            tint: model.heroTone.color,
            systemImage: "photo.on.rectangle.angled",
            usesBrandMark: true
        ) {
            VStack(alignment: .leading, spacing: 12) {
                SummaryLine(title: "Source", value: model.sourceSummaryValue, valueColor: model.sourceStepState.tone.color)
                SummaryLine(title: "Destination", value: model.destinationSummaryValue, valueColor: model.destinationStepState.tone.color)
                SummaryLine(title: "Mode", value: model.modeSummaryValue)
                SummaryLine(title: "Next", value: model.nextStepSummary, valueColor: model.heroTone.color)
            }
        } actions: {
            Button(action: primaryAction) {
                Label(model.primaryAction.title, systemImage: model.primaryAction.systemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.primaryActionDisabled)
            .accessibilityLabel(model.primaryAction.title)
            .accessibilityHint(model.primaryActionDisabled ? "Choose both folders to continue" : "Continues to the next setup step")
        }
    }
}

struct SetupContactSheetSection: View {
    let sourcePath: String

    var body: some View {
        MeridianSurfaceCard {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.cardSpacing) {
                SectionHeading(
                    title: "Preview",
                    message: sourcePath.isEmpty
                        ? "A contact sheet of the first frames will appear here once you choose a source."
                        : "The first twelve frames discovered in your source, in Finder order."
                )

                ContactSheetView(sourcePath: sourcePath)
            }
        }
    }
}

struct SetupSavedSetupSection: View {
    let model: SetupScreenModel
    @ObservedObject var setupStore: SetupStore
    let refreshProfiles: () -> Void
    let clearSelectedProfile: () -> Void
    let openProfiles: () -> Void
    let onProfileSelection: (String) -> Void

    var body: some View {
        MeridianSurfaceCard {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.cardSpacing) {
                HStack(alignment: .top, spacing: 12) {
                    SectionHeading(
                        eyebrow: "Saved Setup",
                        title: "Profiles for Repeatable Runs",
                        message: "Use a saved source and destination pair when you want the app and CLI to stay in sync."
                    )

                    Spacer(minLength: 12)

                    MeridianStatusBadge(
                        title: model.savedSetupBadgeTitle,
                        systemImage: model.savedSetupBadgeSymbol,
                        tint: model.savedSetupTone.color
                    )
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        profilePickerSection
                        Spacer(minLength: 12)
                        profileActions
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        profilePickerSection
                        profileActions
                    }
                }

                if setupStore.usingProfile, let profile = setupStore.activeProfile {
                    MeridianSurfaceCard(style: .inner, tint: DesignTokens.Color.sky) {
                        VStack(alignment: .leading, spacing: 12) {
                            SummaryLine(title: "Selected", value: profile.name)
                            SummaryLine(title: "Source", value: profile.sourcePath)
                            SummaryLine(title: "Destination", value: profile.destinationPath)
                        }
                    }
                }
            }
        }
    }

    private var profilePickerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Selected Profile")
                .font(.subheadline.weight(.semibold))

            Picker(
                "Profile",
                selection: Binding(
                    get: { setupStore.selectedProfileName },
                    set: { selection in
                        onProfileSelection(selection)
                    }
                )
            ) {
                Text("Manual Paths").tag("")
                ForEach(setupStore.profiles) { profile in
                    Text(profile.name).tag(profile.name)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityIdentifier("profilePicker")
            .accessibilityLabel("Profile")
        }
    }

    private var profileActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Button("Refresh Profiles", action: refreshProfiles)
                Button("Manage Profiles", action: openProfiles)

                if setupStore.usingProfile {
                    Button("Clear Selection", action: clearSelectedProfile)
                }
            }

            Menu("Profile Actions") {
                Button("Refresh Profiles", action: refreshProfiles)
                Button("Manage Profiles", action: openProfiles)

                if setupStore.usingProfile {
                    Button("Clear Selection", action: clearSelectedProfile)
                }
            }
        }
    }
}

struct SetupSourceStepSection: View {
    let model: SetupScreenModel
    let dropZone: SetupDropZone
    let chooseSource: () -> Void

    var body: some View {
        setupStepCard(
            stepTitle: "1. Source",
            message: "The library Chronoframe should organize.",
            stepState: model.sourceStepState
        ) {
            VStack(alignment: .leading, spacing: 12) {
                dropZone

                MeridianSurfaceCard(style: .inner, tint: model.sourceStepState.tone.color) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            PathValueView(
                                title: "Manual Folder Source",
                                value: model.displayedSourcePath,
                                helper: model.sourcePathHelper
                            )

                            Spacer(minLength: 12)

                            Button("Choose Source…", action: chooseSource)
                                .accessibilityHint("Opens a folder picker to choose the source library")
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            PathValueView(
                                title: "Manual Folder Source",
                                value: model.displayedSourcePath,
                                helper: model.sourcePathHelper
                            )

                            Button("Choose Source…", action: chooseSource)
                                .accessibilityHint("Opens a folder picker to choose the source library")
                        }
                    }
                }
            }
        }
    }

    private func setupStepCard<Content: View>(
        stepTitle: String,
        message: String,
        stepState: SetupStepState,
        @ViewBuilder content: () -> Content
    ) -> some View {
        MeridianSurfaceCard {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.cardSpacing) {
                HStack(alignment: .top, spacing: 12) {
                    SectionHeading(title: stepTitle, message: message)
                    Spacer(minLength: 12)
                    MeridianStatusBadge(title: stepState.title, tint: stepState.tone.color)
                }

                content()
            }
        }
    }
}

struct SetupDestinationStepSection: View {
    let model: SetupScreenModel
    let chooseDestination: () -> Void

    var body: some View {
        MeridianSurfaceCard {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.cardSpacing) {
                HStack(alignment: .top, spacing: 12) {
                    SectionHeading(
                        title: "2. Destination",
                        message: "Where organized copies and receipts are written."
                    )
                    Spacer(minLength: 12)
                    MeridianStatusBadge(title: model.destinationStepState.title, tint: model.destinationStepState.tone.color)
                }

                MeridianSurfaceCard(style: .inner, tint: model.destinationStepState.tone.color) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            PathValueView(
                                title: "Destination Folder",
                                value: model.context.destinationPath,
                                helper: model.destinationPathHelper
                            )

                            Spacer(minLength: 12)

                            Button("Choose Destination…", action: chooseDestination)
                                .accessibilityHint("Opens a folder picker to choose where organized copies will be written")
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            PathValueView(
                                title: "Destination Folder",
                                value: model.context.destinationPath,
                                helper: model.destinationPathHelper
                            )

                            Button("Choose Destination…", action: chooseDestination)
                                .accessibilityHint("Opens a folder picker to choose where organized copies will be written")
                        }
                    }
                }
            }
        }
    }
}

struct SetupReadinessSection: View {
    let model: SetupScreenModel
    let preview: () -> Void
    let transfer: () -> Void
    let openSettings: () -> Void
    let isRunInProgress: Bool

    var body: some View {
        MeridianSurfaceCard {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.cardSpacing) {
                HStack(alignment: .top, spacing: 12) {
                    SectionHeading(
                        title: "Run",
                        message: "Preview to inspect the plan. Transfer when ready."
                    )

                    Spacer(minLength: 12)

                    MeridianStatusBadge(
                        title: model.readinessBadgeTitle,
                        systemImage: model.readinessBadgeSymbol,
                        tint: model.readinessTone.color
                    )
                }

                MeridianSurfaceCard(style: .inner, tint: DesignTokens.Color.amber) {
                    VStack(alignment: .leading, spacing: 12) {
                        SummaryLine(title: "Configuration", value: model.configurationSummary)
                        SummaryLine(title: "Performance", value: model.performanceSummary)
                        SummaryLine(title: "Safety", value: model.safetySummary)
                    }
                }

                Text(model.readinessMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        previewButton
                        transferButton
                        Button("Adjust Settings…", action: openSettings)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        previewButton
                        transferButton
                        Button("Adjust Settings…", action: openSettings)
                    }
                }
            }
        }
    }

    private var previewButton: some View {
        Button(action: preview) {
            Label("Preview", systemImage: "eye")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canStartRun || isRunInProgress)
        .accessibilityIdentifier("previewButton")
        .accessibilityLabel("Preview")
        .accessibilityHint(model.canStartRun ? "Generates a copy plan without moving any files" : "Choose both folders or a saved profile first")
    }

    private var transferButton: some View {
        Button(action: transfer) {
            Label("Transfer", systemImage: "arrow.right.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!model.canStartRun || isRunInProgress)
        .accessibilityIdentifier("transferButton")
        .accessibilityLabel("Transfer")
        .accessibilityHint(model.canStartRun ? "Copies files from the source to the destination after confirmation" : "Choose both folders or a saved profile first")
    }
}

struct SetupDropZone: View {
    let isActive: Bool
    let droppedSourceLabel: String?
    @Binding var isTargeted: Bool
    let onDrop: ([NSItemProvider]) -> Bool

    var body: some View {
        MeridianSurfaceCard(style: .inner, tint: isTargeted ? DesignTokens.Color.sky : DesignTokens.Color.cloud) {
            VStack(spacing: 10) {
                MeridianLeadIcon(
                    systemImage: isActive ? "photo.on.rectangle.angled" : "square.and.arrow.down.on.square",
                    tint: isTargeted ? DesignTokens.Color.sky : DesignTokens.Color.inkMuted
                )

                if isActive {
                    Text(droppedSourceLabel ?? "Dropped items ready")
                        .font(.headline)
                        .foregroundStyle(DesignTokens.Color.inkPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(isTargeted ? "Release to use as source" : "Drop a folder to begin")
                        .font(.headline)
                        .foregroundStyle(isTargeted ? DesignTokens.Color.sky : DesignTokens.Color.inkPrimary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Corner.innerCard, style: .continuous)
                    .strokeBorder(
                        isTargeted ? DesignTokens.Color.sky : DesignTokens.Color.inkMuted.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
            )
        }
        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.innerCard, style: .continuous))
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            onDrop(providers)
        }
        .accessibilityLabel("Drop photos, videos, or folders to use as source")
        .accessibilityIdentifier("dropZone")
    }
}

import SwiftUI
#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif

struct RunHeroSection: View {
    let model: RunWorkspaceModel
    @Binding var workspaceTab: RunWorkspaceTab
    let appState: AppState

    var body: some View {
        DetailHeroCard(
            title: model.heroState.title,
            message: model.heroState.message,
            badgeTitle: model.heroState.badgeTitle,
            badgeSystemImage: model.heroState.badgeSymbol,
            tint: model.heroState.tone.color,
            systemImage: model.heroState.heroSymbol
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if model.showsProgressSurface {
                    RunProgressSurface(model: model)
                }

                SummaryLine(title: "Mode", value: model.context.currentMode?.title ?? "Idle")
                SummaryLine(title: "Current Focus", value: model.context.currentTaskTitle)
                SummaryLine(title: "Issues", value: model.issueSummaryValue, valueColor: model.issueTone.color)
                SummaryLine(title: "Destination", value: model.destinationSummaryValue)
            }
        } actions: {
            if let action = model.heroState.primaryAction {
                heroPrimaryButton(for: action)
            }
        }
    }

    @ViewBuilder
    private func heroPrimaryButton(for action: RunHeroPrimaryAction) -> some View {
        switch action {
        case .setup:
            Button {
                appState.selection = .setup
            } label: {
                Label("Return to Setup", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Opens the Setup workspace to adjust source, destination, or profile")

        case .preview:
            Button {
                Task { await appState.startPreview() }
            } label: {
                Label("Preview Plan", systemImage: "eye")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!appState.canStartRun)
            .accessibilityHint(appState.canStartRun ? "Generates a copy plan without moving any files" : "Choose both folders or a saved profile in Setup first")

        case .transfer:
            Button {
                Task { await appState.startTransfer() }
            } label: {
                Label("Start Transfer", systemImage: "arrow.right.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canStartTransferFromPreview)
            .accessibilityHint(model.canStartTransferFromPreview ? "Copies files from the source to the destination" : "Run a preview first")

        case .cancel:
            Button(role: .destructive) {
                appState.cancelRun()
            } label: {
                Label("Cancel Run", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Stops the current run. Already-copied files remain in place")

        case .openDestination:
            Button {
                appState.openDestination()
            } label: {
                Label("Open Destination", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.destinationRoot == nil)
            .accessibilityHint("Reveals the destination folder in Finder")

        case .showIssues:
            Button {
                workspaceTab = .issues
            } label: {
                Label("Review Issues", systemImage: "exclamationmark.triangle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Opens the issues tab below to review warnings and errors")
        }
    }
}

struct RunProgressSurface: View {
    let model: RunWorkspaceModel

    var body: some View {
        MeridianSurfaceCard(style: .inner, tint: model.heroState.tone.color) {
            VStack(alignment: .leading, spacing: 12) {
                progressView
                    .accessibilityLabel("Run progress")
                    .accessibilityValue(model.progressAccessibilityValue)

                RunPhaseStrip(model: model)
            }
        }
    }

    @ViewBuilder
    private var progressView: some View {
        if model.context.status == .running
            && model.context.progress == 0
            && model.context.currentPhase != nil
            && model.context.currentPhase != .copy {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(model.heroState.tone.color)
        } else {
            ProgressView(value: model.context.progress)
                .progressViewStyle(.linear)
                .tint(model.heroState.tone.color)
        }
    }
}

struct RunPreviewReviewSection: View {
    let model: RunWorkspaceModel
    let startTransfer: () -> Void

    var body: some View {
        MeridianSurfaceCard(tint: DesignTokens.Color.sky) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    reviewSummary
                    Spacer(minLength: 12)
                    transferButton
                }

                VStack(alignment: .leading, spacing: 12) {
                    reviewSummary
                    transferButton
                }
            }
        }
    }

    private var reviewSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview Review")
                .font(DesignTokens.Typography.cardTitle)
                .foregroundStyle(DesignTokens.Color.inkPrimary)

            Text(model.previewReviewMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var transferButton: some View {
        Button(action: startTransfer) {
            Label("Start Transfer", systemImage: "arrow.right.circle.fill")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!model.canStartTransferFromPreview)
        .accessibilityLabel("Start transfer now")
        .accessibilityIdentifier("startTransferFromPreviewButton")
    }
}

struct RunMetricsGridSection: View {
    let model: RunWorkspaceModel

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: DesignTokens.Layout.metricMinWidth, maximum: 240), spacing: 12)],
            spacing: 12
        ) {
            ForEach(model.metrics) { metric in
                MetricTile(
                    title: metric.title,
                    value: metric.value,
                    caption: metric.caption,
                    tint: metric.tone.color
                )
            }
        }
    }
}

struct RunTickerSection: View {
    let model: RunWorkspaceModel

    var body: some View {
        TickerRow(entries: entries)
    }

    private var entries: [TickerRow.Entry] {
        let metrics = model.context.metrics
        return [
            TickerRow.Entry(
                id: "discovered",
                value: metrics.discoveredCount.formatted(),
                label: "discovered",
                tone: .neutral
            ),
            TickerRow.Entry(
                id: "planned",
                value: metrics.plannedCount.formatted(),
                label: "planned",
                tone: .neutral
            ),
            TickerRow.Entry(
                id: "copied",
                value: metrics.copiedCount.formatted(),
                label: "copied",
                tone: .success
            ),
            TickerRow.Entry(
                id: "already",
                value: metrics.alreadyInDestinationCount.formatted(),
                label: "already there",
                tone: .neutral
            ),
            TickerRow.Entry(
                id: "duplicates",
                value: metrics.duplicateCount.formatted(),
                label: "duplicates",
                tone: metrics.duplicateCount > 0 ? .warning : .neutral
            ),
            TickerRow.Entry(
                id: "issues",
                value: "\(model.context.issueCount)",
                label: "issues",
                tone: model.context.issueCount > 0 ? .danger : .neutral
            ),
        ]
    }
}

struct RunWorkspaceShell: View {
    let model: RunWorkspaceModel
    @Binding var workspaceTab: RunWorkspaceTab
    let appState: AppState

    var body: some View {
        MeridianSurfaceCard {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.cardSpacing) {
                HStack(alignment: .top, spacing: 12) {
                    SectionHeading(
                        eyebrow: "Inspect",
                        title: "Progress, Issues, and Artifacts",
                        message: "Use the workspace to understand what happened, where the run stands now, and what to inspect next."
                    )

                    Spacer(minLength: 12)

                    Picker("Workspace", selection: $workspaceTab) {
                        ForEach(RunWorkspaceTab.allCases) { tab in
                            Text(model.tabTitle(tab)).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 340)
                    .accessibilityIdentifier("runWorkspaceTabs")
                }

                workspaceContent
            }
        }
    }

    @ViewBuilder
    private var workspaceContent: some View {
        switch workspaceTab {
        case .overview:
            VStack(alignment: .leading, spacing: 16) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        RunSnapshotPanel(model: model)
                        RunArtifactsPanel(model: model, appState: appState)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        RunSnapshotPanel(model: model)
                        RunArtifactsPanel(model: model, appState: appState)
                    }
                }
            }
        case .issues:
            RunIssuesPanel(model: model)
        case .console:
            RunConsolePanel(model: model)
        }
    }
}

struct RunSnapshotPanel: View {
    let model: RunWorkspaceModel

    var body: some View {
        MeridianSurfaceCard(style: .inner, tint: model.heroState.tone.color) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Run Snapshot")
                    .font(DesignTokens.Typography.cardTitle)

                SummaryLine(title: "Status", value: model.heroState.badgeTitle)
                SummaryLine(title: "Speed", value: model.speedSummaryValue)
                SummaryLine(title: "ETA", value: model.etaSummaryValue)
                SummaryLine(title: "Warnings", value: "\(model.context.warningCount)", valueColor: model.warningTone.color)
                SummaryLine(title: "Errors", value: "\(max(model.context.errorCount, model.context.issueCount))", valueColor: model.errorTone.color)
            }
        }
    }
}

struct RunArtifactsPanel: View {
    let model: RunWorkspaceModel
    let appState: AppState

    var body: some View {
        MeridianSurfaceCard(style: .inner, tint: DesignTokens.Color.amber) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Artifacts")
                    .font(DesignTokens.Typography.cardTitle)

                Text(model.destinationSummaryValue)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(model.destinationRoot == nil ? .secondary : DesignTokens.Color.inkPrimary)
                    .lineLimit(3)
                    .truncationMode(.middle)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        artifactButtons
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        artifactButtons
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var artifactButtons: some View {
        Button("Open Destination") {
            appState.openDestination()
        }
        .disabled(model.destinationRoot == nil)
        .accessibilityLabel("Open destination folder in Finder")
        .accessibilityIdentifier("openDestinationButton")

        Button("Open Report") {
            appState.openReport()
        }
        .disabled(model.reportPath == nil)
        .accessibilityLabel("Open dry-run report")
        .accessibilityIdentifier("openReportButton")

        Button("Open Logs") {
            appState.openLogsDirectory()
        }
        .disabled(model.logsDirectoryPath == nil)
        .accessibilityLabel("Open logs directory in Finder")
        .accessibilityIdentifier("openLogsButton")
    }
}

private func accessibilityPrefix(for tone: RunWorkspaceTone) -> String {
    switch tone {
    case .danger:
        return "Error"
    case .warning:
        return "Warning"
    default:
        return "Notice"
    }
}

struct RunIssuesPanel: View {
    let model: RunWorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MeridianSurfaceCard(style: .inner, tint: model.issueTone.color) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Issues")
                        .font(DesignTokens.Typography.cardTitle)

                    SummaryLine(title: "Warnings", value: "\(model.context.warningCount)", valueColor: model.warningTone.color)
                    SummaryLine(title: "Errors", value: "\(model.context.errorCount)", valueColor: model.errorTone.color)
                    SummaryLine(title: "Engine Issues", value: "\(model.context.issueCount)", valueColor: model.issueTone.color)
                }
            }

            if model.issueEntries.isEmpty {
                EmptyStateView(
                    title: "No Issues Reported",
                    message: "Warnings and errors will be collected here.",
                    systemImage: "checkmark.shield"
                )
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.issueEntries) { entry in
                        MeridianSurfaceCard(style: .inner, tint: entry.tone.color) {
                            Text(entry.text)
                                .font(.system(size: DesignTokens.Layout.consoleFontSize, weight: .regular, design: .monospaced))
                                .foregroundStyle(entry.tone.color)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(accessibilityPrefix(for: entry.tone)): \(entry.text)")
                    }
                }
                .accessibilityRotor("Issues") {
                    ForEach(model.issueEntries) { entry in
                        AccessibilityRotorEntry(entry.text, id: entry.id)
                    }
                }
            }
        }
    }
}

struct RunConsolePanel: View {
    let model: RunWorkspaceModel

    var body: some View {
        MeridianSurfaceCard(style: .inner, tint: DesignTokens.Color.inkMuted) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Console")
                    .font(DesignTokens.Typography.cardTitle)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if model.consoleEntries.isEmpty {
                            Text("No activity yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(model.consoleEntries, id: \.id) { entry in
                                Text(entry.text)
                                    .font(.system(size: DesignTokens.Layout.consoleFontSize, weight: .regular, design: .monospaced))
                                    .foregroundStyle(model.lineTone(for: entry.text).color)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .frame(minHeight: DesignTokens.Layout.consoleMinHeight, idealHeight: DesignTokens.Layout.consoleIdealHeight)
                .accessibilityLabel("Run log")
                .accessibilityIdentifier("consoleScrollView")
            }
        }
    }
}


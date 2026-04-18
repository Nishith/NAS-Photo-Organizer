#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

private enum RunWorkspaceTab: String, CaseIterable, Identifiable {
    case overview
    case issues
    case console

    var id: String { rawValue }
}

private enum RunHeroPrimaryAction {
    case setup
    case preview
    case transfer
    case cancel
    case openDestination
    case showIssues
}

private struct RunHeroState {
    let title: String
    let message: String
    let badgeTitle: String
    let badgeSymbol: String
    let heroSymbol: String
    let tint: SwiftUI.Color
    let primaryAction: RunHeroPrimaryAction?
}

struct CurrentRunView: View {
    let appState: AppState
    @ObservedObject private var runSessionStore: RunSessionStore
    @ObservedObject private var runLogStore: RunLogStore
    @ObservedObject private var historyStore: HistoryStore
    @State private var workspaceTab: RunWorkspaceTab = .overview

    init(appState: AppState) {
        self.appState = appState
        self._runSessionStore = ObservedObject(wrappedValue: appState.runSessionStore)
        self._runLogStore = ObservedObject(wrappedValue: appState.runLogStore)
        self._historyStore = ObservedObject(wrappedValue: appState.historyStore)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.sectionSpacing) {
                heroCard

                if runSessionStore.status == .dryRunFinished {
                    previewReviewCard
                }

                metricsGrid
                workspaceCard
            }
            .padding(DesignTokens.Layout.contentPadding)
            .frame(maxWidth: DesignTokens.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Run")
    }

    private var heroCard: some View {
        DetailHeroCard(
            eyebrow: "Run Workspace",
            title: heroState.title,
            message: heroState.message,
            badgeTitle: heroState.badgeTitle,
            badgeSystemImage: heroState.badgeSymbol,
            tint: heroState.tint,
            systemImage: heroState.heroSymbol
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if showsProgressSurface {
                    progressSurface
                }

                SummaryLine(title: "Mode", value: runSessionStore.currentMode?.title ?? "Idle")
                SummaryLine(title: "Current Focus", value: runSessionStore.currentTaskTitle)
                SummaryLine(title: "Issues", value: issueSummaryValue, valueColor: issueSummaryColor)
                SummaryLine(title: "Destination", value: destinationSummaryValue)
            }
        } actions: {
            if let action = heroState.primaryAction {
                heroPrimaryButton(for: action)
            }
        }
    }

    private var progressSurface: some View {
        MeridianSurfaceCard(style: .inner, tint: heroState.tint) {
            VStack(alignment: .leading, spacing: 12) {
                progressView
                    .accessibilityLabel("Run progress")
                    .accessibilityValue(progressAccessibilityValue)

                phaseView
            }
        }
    }

    @ViewBuilder
    private var progressView: some View {
        if runSessionStore.isRunning
            && runSessionStore.progress == 0
            && runSessionStore.currentPhase != nil
            && runSessionStore.currentPhase != .copy {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(heroState.tint)
        } else {
            ProgressView(value: runSessionStore.progress)
                .progressViewStyle(.linear)
                .tint(heroState.tint)
        }
    }

    private var previewReviewCard: some View {
        MeridianSurfaceCard(tint: DesignTokens.Color.sky) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    reviewSummary
                    Spacer(minLength: 12)
                    transferFromPreviewButton
                }

                VStack(alignment: .leading, spacing: 12) {
                    reviewSummary
                    transferFromPreviewButton
                }
            }
        }
    }

    private var reviewSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview Review")
                .font(DesignTokens.Typography.cardTitle)
                .foregroundStyle(DesignTokens.Color.inkPrimary)

            Text(runSessionStore.metrics.plannedCount > 0
                 ? "Nothing has been copied yet. \(runSessionStore.metrics.plannedCount.formatted()) files are ready to transfer once the plan looks right."
                 : "The preview found nothing new to copy. The destination already contains everything needed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var transferFromPreviewButton: some View {
        Button {
            Task { await appState.startTransfer() }
        } label: {
            Label("Start Transfer", systemImage: "arrow.right.circle.fill")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(runSessionStore.metrics.plannedCount == 0 || !appState.canStartRun)
        .accessibilityLabel("Start transfer now")
        .accessibilityIdentifier("startTransferFromPreviewButton")
    }

    private var metricsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: DesignTokens.Layout.metricMinWidth, maximum: 240), spacing: 12)],
            spacing: 12
        ) {
            MetricTile(
                title: "Discovered",
                value: abbreviated(runSessionStore.metrics.discoveredCount),
                caption: "Items found in the source library.",
                tint: DesignTokens.Color.aqua
            )
            MetricTile(
                title: "Planned",
                value: abbreviated(runSessionStore.metrics.plannedCount),
                caption: "Files queued for review or transfer.",
                tint: DesignTokens.Color.sky
            )
            MetricTile(
                title: "Already There",
                value: abbreviated(runSessionStore.metrics.alreadyInDestinationCount),
                caption: "Skipped because matching copies already exist.",
                tint: DesignTokens.Color.success
            )
            MetricTile(
                title: "Duplicates",
                value: abbreviated(runSessionStore.metrics.duplicateCount),
                caption: "Exact duplicates routed away from the main transfer.",
                tint: DesignTokens.Color.amber
            )
            MetricTile(
                title: "Issues",
                value: abbreviated(runSessionStore.issueCount),
                caption: "Warnings, failed copies, or hash errors to review.",
                tint: issueSummaryColor
            )
            MetricTile(
                title: "Copied",
                value: abbreviated(runSessionStore.metrics.copiedCount),
                caption: "Files successfully copied during transfer.",
                tint: DesignTokens.Color.success
            )
        }
    }

    private var workspaceCard: some View {
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
                            Text(tabTitle(tab)).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 340)
                }

                workspaceContent
            }
        }
    }

    @ViewBuilder
    private var workspaceContent: some View {
        switch workspaceTab {
        case .overview:
            overviewWorkspace
        case .issues:
            issuesWorkspace
        case .console:
            consoleWorkspace
        }
    }

    private var overviewWorkspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    snapshotPanel
                    artifactsPanel
                }

                VStack(alignment: .leading, spacing: 16) {
                    snapshotPanel
                    artifactsPanel
                }
            }
        }
    }

    private var snapshotPanel: some View {
        MeridianSurfaceCard(style: .inner, tint: heroState.tint) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Run Snapshot")
                    .font(DesignTokens.Typography.cardTitle)

                SummaryLine(title: "Status", value: heroState.badgeTitle)
                SummaryLine(title: "Speed", value: speedSummaryValue)
                SummaryLine(title: "ETA", value: formattedETA(runSessionStore.metrics.etaSeconds))
                SummaryLine(title: "Warnings", value: "\(runLogStore.warningCount)", valueColor: warningCountColor)
                SummaryLine(title: "Errors", value: "\(runLogStore.errorCount)", valueColor: errorCountColor)
            }
        }
    }

    private var artifactsPanel: some View {
        MeridianSurfaceCard(style: .inner, tint: DesignTokens.Color.amber) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Artifacts")
                    .font(DesignTokens.Typography.cardTitle)

                Text(destinationSummaryValue)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(destinationRoot == nil ? .secondary : DesignTokens.Color.inkPrimary)
                    .lineLimit(3)
                    .truncationMode(.middle)

                Text("Open the destination, dry-run report, or logs to inspect what Chronoframe produced.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

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

    private var issuesWorkspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            MeridianSurfaceCard(style: .inner, tint: issueSummaryColor) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Issue Review")
                        .font(DesignTokens.Typography.cardTitle)

                    Text(issueWorkspaceSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    SummaryLine(title: "Warnings", value: "\(runLogStore.warningCount)", valueColor: warningCountColor)
                    SummaryLine(title: "Errors", value: "\(runLogStore.errorCount)", valueColor: errorCountColor)
                    SummaryLine(title: "Engine Issues", value: "\(runSessionStore.issueCount)", valueColor: issueSummaryColor)
                }
            }

            if issueLogEntries.isEmpty {
                EmptyStateView(
                    title: "No Issues Reported",
                    message: "Warnings and errors will be collected here so you can review them without scanning the full console.",
                    systemImage: "checkmark.shield"
                )
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(issueLogEntries.enumerated()), id: \.element.id) { _, entry in
                        MeridianSurfaceCard(style: .inner, tint: tint(for: entry.text)) {
                            Text(entry.text)
                                .font(.system(size: DesignTokens.Layout.consoleFontSize, weight: .regular, design: .monospaced))
                                .foregroundStyle(lineColor(for: entry.text))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private var consoleWorkspace: some View {
        MeridianSurfaceCard(style: .inner, tint: DesignTokens.Color.inkMuted) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Console")
                    .font(DesignTokens.Typography.cardTitle)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if runLogStore.entries.isEmpty {
                            Text("The full backend console will appear here once the organizer starts emitting activity.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(runLogStore.entries), id: \.id) { entry in
                                Text(entry.text)
                                    .font(.system(size: DesignTokens.Layout.consoleFontSize, weight: .regular, design: .monospaced))
                                    .foregroundStyle(lineColor(for: entry.text))
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

    @ViewBuilder
    private var artifactButtons: some View {
        Button("Open Destination") {
            appState.openDestination()
        }
        .disabled(destinationRoot == nil)
        .accessibilityLabel("Open destination folder in Finder")
        .accessibilityIdentifier("openDestinationButton")

        Button("Open Report") {
            appState.openReport()
        }
        .disabled(runSessionStore.summary?.artifacts.reportPath == nil)
        .accessibilityLabel("Open dry-run report")
        .accessibilityIdentifier("openReportButton")

        Button("Open Logs") {
            appState.openLogsDirectory()
        }
        .disabled(runSessionStore.summary?.artifacts.logsDirectoryPath == nil)
        .accessibilityLabel("Open logs directory in Finder")
        .accessibilityIdentifier("openLogsButton")
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

        case .preview:
            Button {
                Task { await appState.startPreview() }
            } label: {
                Label("Preview Plan", systemImage: "eye")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!appState.canStartRun)

        case .transfer:
            Button {
                Task { await appState.startTransfer() }
            } label: {
                Label("Start Transfer", systemImage: "arrow.right.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(runSessionStore.metrics.plannedCount == 0 || !appState.canStartRun)

        case .cancel:
            Button(role: .destructive) {
                appState.cancelRun()
            } label: {
                Label("Cancel Run", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

        case .openDestination:
            Button {
                appState.openDestination()
            } label: {
                Label("Open Destination", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(destinationRoot == nil)

        case .showIssues:
            Button {
                workspaceTab = .issues
            } label: {
                Label("Review Issues", systemImage: "exclamationmark.triangle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var heroState: RunHeroState {
        switch runSessionStore.status {
        case .idle:
            return RunHeroState(
                title: appState.canStartRun ? "Preview Before You Commit" : "This Workspace Activates After Setup",
                message: appState.canStartRun
                    ? "Run a non-destructive preview to inspect what will be copied, what will be skipped, and where the destination will be updated."
                    : "Choose a source and destination first, then use this workspace to review progress, issues, and artifacts through the entire run.",
                badgeTitle: "Idle",
                badgeSymbol: "circle.dashed",
                heroSymbol: "eye",
                tint: appState.canStartRun ? DesignTokens.Status.ready : DesignTokens.Status.idle,
                primaryAction: appState.canStartRun ? .preview : .setup
            )

        case .preflighting:
            return RunHeroState(
                title: "Checking the Next Run",
                message: "Chronoframe is validating the configuration, resolving bookmarks, and preparing a safe next step before the backend starts.",
                badgeTitle: "Preparing",
                badgeSymbol: "clock.arrow.circlepath",
                heroSymbol: "clock.arrow.circlepath",
                tint: DesignTokens.Status.ready,
                primaryAction: nil
            )

        case .running:
            let mode = runSessionStore.currentMode ?? .transfer
            return RunHeroState(
                title: mode == .preview ? "Preview in Progress" : "Transfer in Progress",
                message: "This workspace updates live as Chronoframe moves through each phase, tracks issues, and keeps the destination artifacts ready to inspect.",
                badgeTitle: mode == .preview ? "Preview Running" : "Transfer Running",
                badgeSymbol: "arrow.triangle.2.circlepath",
                heroSymbol: "bolt.horizontal.circle",
                tint: DesignTokens.Status.active,
                primaryAction: .cancel
            )

        case .dryRunFinished:
            return RunHeroState(
                title: "Preview Ready for Review",
                message: "Nothing has been copied. Inspect the planned work, any issues, and the destination before starting the transfer.",
                badgeTitle: "Preview Complete",
                badgeSymbol: "checkmark.circle.fill",
                heroSymbol: "doc.text.magnifyingglass",
                tint: DesignTokens.Status.ready,
                primaryAction: .transfer
            )

        case .finished:
            return RunHeroState(
                title: "Transfer Complete",
                message: "Organized files, logs, and receipts are ready to inspect. Open the destination to verify the result in Finder.",
                badgeTitle: "Finished",
                badgeSymbol: "checkmark.circle.fill",
                heroSymbol: "checkmark.circle.fill",
                tint: DesignTokens.Status.success,
                primaryAction: .openDestination
            )

        case .nothingToCopy:
            return RunHeroState(
                title: "Destination Already Up To Date",
                message: "Chronoframe did not find any new files to copy for this configuration. The destination already contains everything it needs.",
                badgeTitle: "Up to Date",
                badgeSymbol: "checkmark.seal.fill",
                heroSymbol: "checkmark.seal.fill",
                tint: DesignTokens.Status.success,
                primaryAction: .openDestination
            )

        case .cancelled:
            return RunHeroState(
                title: "Run Cancelled",
                message: "The run stopped before completion. Review the current state, inspect any partial artifacts, and start again when you are ready.",
                badgeTitle: "Cancelled",
                badgeSymbol: "pause.circle.fill",
                heroSymbol: "pause.circle.fill",
                tint: DesignTokens.Status.warning,
                primaryAction: appState.canStartRun ? .preview : .setup
            )

        case .failed:
            return RunHeroState(
                title: "Run Needs Attention",
                message: runSessionStore.lastErrorMessage ?? "Chronoframe reported a failure. Review issues and the console stream to understand what happened.",
                badgeTitle: "Failed",
                badgeSymbol: "exclamationmark.octagon.fill",
                heroSymbol: "exclamationmark.triangle.fill",
                tint: DesignTokens.Status.danger,
                primaryAction: .showIssues
            )
        }
    }

    private var showsProgressSurface: Bool {
        runSessionStore.currentPhase != nil || runSessionStore.isRunning
    }

    private var progressAccessibilityValue: String {
        if runSessionStore.isRunning
            && runSessionStore.progress == 0
            && runSessionStore.currentPhase != nil
            && runSessionStore.currentPhase != .copy {
            return "Scanning"
        }
        return "\(Int(runSessionStore.progress * 100))%"
    }

    private var phaseView: some View {
        ViewThatFits(in: .horizontal) {
            phaseRow(showLabels: true)
            phaseRow(showLabels: false)
        }
    }

    private func phaseRow(showLabels: Bool) -> some View {
        HStack(spacing: 10) {
            ForEach(RunPhase.allCases, id: \.self) { phase in
                VStack(spacing: 8) {
                    Circle()
                        .fill(fill(for: phase))
                        .frame(width: DesignTokens.Layout.phaseIndicatorSize, height: DesignTokens.Layout.phaseIndicatorSize)
                        .accessibilityLabel(phaseAccessibilityLabel(for: phase))

                    if showLabels {
                        Text(phase.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if phase != RunPhase.allCases.last {
                    Capsule()
                        .fill(connectorFill(after: phase))
                        .frame(height: DesignTokens.Layout.phaseConnectorHeight)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func tabTitle(_ tab: RunWorkspaceTab) -> String {
        switch tab {
        case .overview:
            return "Overview"
        case .issues:
            let count = max(runLogStore.warningCount + runLogStore.errorCount, runSessionStore.issueCount)
            return count > 0 ? "Issues (\(count))" : "Issues"
        case .console:
            return "Console"
        }
    }

    private var issueLogEntries: [RunLogEntry] {
        Array(runLogStore.entries.filter { isIssueLine($0.text) })
    }

    private var issueWorkspaceSummary: String {
        if issueLogEntries.isEmpty {
            return "No warning or error lines have been emitted yet. If something changes, this view will pull the high-signal items out of the full console."
        }
        return "Warnings and errors are separated here so you can review the highest-signal problems without scanning the entire console feed."
    }

    private var destinationRoot: String? {
        let destination = runSessionStore.summary?.artifacts.destinationRoot ?? historyStore.destinationRoot
        return destination.isEmpty ? nil : destination
    }

    private var destinationSummaryValue: String {
        destinationRoot ?? "Destination will appear here once a run is configured"
    }

    private var speedSummaryValue: String {
        runSessionStore.metrics.speedMBps > 0
            ? String(format: "%.1f MB/s", runSessionStore.metrics.speedMBps)
            : "—"
    }

    private var issueSummaryValue: String {
        let warningCount = runLogStore.warningCount
        let errorCount = max(runLogStore.errorCount, runSessionStore.issueCount)
        if warningCount == 0 && errorCount == 0 {
            return "No issues reported"
        }
        return "\(warningCount) warning\(warningCount == 1 ? "" : "s"), \(errorCount) error\(errorCount == 1 ? "" : "s")"
    }

    private var issueSummaryColor: SwiftUI.Color {
        if max(runLogStore.errorCount, runSessionStore.issueCount) > 0 {
            return DesignTokens.Color.danger
        }
        if runLogStore.warningCount > 0 {
            return DesignTokens.Color.warning
        }
        return DesignTokens.Color.success
    }

    private var warningCountColor: SwiftUI.Color {
        runLogStore.warningCount > 0 ? DesignTokens.Color.warning : DesignTokens.Color.inkPrimary
    }

    private var errorCountColor: SwiftUI.Color {
        max(runLogStore.errorCount, runSessionStore.issueCount) > 0 ? DesignTokens.Color.danger : DesignTokens.Color.inkPrimary
    }

    private func fill(for phase: RunPhase) -> SwiftUI.Color {
        guard let currentPhase = runSessionStore.currentPhase else {
            return DesignTokens.Color.inkMuted.opacity(0.25)
        }
        if phase == currentPhase {
            return heroState.tint
        }
        if RunPhase.allCases.firstIndex(of: phase) ?? 0 < RunPhase.allCases.firstIndex(of: currentPhase) ?? 0 {
            return DesignTokens.Color.success
        }
        return DesignTokens.Color.inkMuted.opacity(0.25)
    }

    private func connectorFill(after phase: RunPhase) -> SwiftUI.Color {
        guard let currentPhase = runSessionStore.currentPhase else {
            return DesignTokens.Color.inkMuted.opacity(0.15)
        }
        return (RunPhase.allCases.firstIndex(of: phase) ?? 0 < RunPhase.allCases.firstIndex(of: currentPhase) ?? 0)
            ? DesignTokens.Color.success
            : DesignTokens.Color.inkMuted.opacity(0.15)
    }

    private func phaseAccessibilityLabel(for phase: RunPhase) -> String {
        guard let currentPhase = runSessionStore.currentPhase else {
            return "Phase \(phase.title): not started"
        }
        let currentIndex = RunPhase.allCases.firstIndex(of: currentPhase) ?? 0
        let phaseIndex = RunPhase.allCases.firstIndex(of: phase) ?? 0
        if phaseIndex < currentIndex {
            return "Phase \(phase.title): complete"
        } else if phase == currentPhase {
            return "Phase \(phase.title): in progress"
        } else {
            return "Phase \(phase.title): pending"
        }
    }

    private func isIssueLine(_ line: String) -> Bool {
        line.hasPrefix("ERROR:") || line.hasPrefix("WARNING:") || line.hasPrefix("⚠")
    }

    private func tint(for line: String) -> SwiftUI.Color {
        if line.hasPrefix("ERROR:") {
            return DesignTokens.Color.danger
        }
        if isIssueLine(line) {
            return DesignTokens.Color.warning
        }
        return DesignTokens.Color.inkMuted
    }

    private func lineColor(for line: String) -> SwiftUI.Color {
        if line.hasPrefix("ERROR:") {
            return DesignTokens.Color.danger
        }
        if isIssueLine(line) {
            return DesignTokens.Color.warning
        }
        return DesignTokens.Color.inkPrimary
    }

    private func abbreviated(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }

    private func formattedETA(_ eta: Double?) -> String {
        guard let eta, eta > 0 else { return "—" }
        let totalSeconds = Int(eta.rounded())
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        if totalSeconds < 3_600 {
            return "\(totalSeconds / 60)m \(totalSeconds % 60)s"
        }
        return "\(totalSeconds / 3_600)h \((totalSeconds % 3_600) / 60)m"
    }
}

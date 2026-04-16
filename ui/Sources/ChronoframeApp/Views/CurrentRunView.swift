#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

struct CurrentRunView: View {
    let appState: AppState
    @ObservedObject private var runSessionStore: RunSessionStore
    @ObservedObject private var runLogStore: RunLogStore
    @ObservedObject private var historyStore: HistoryStore

    init(appState: AppState) {
        self.appState = appState
        self._runSessionStore = ObservedObject(wrappedValue: appState.runSessionStore)
        self._runLogStore = ObservedObject(wrappedValue: appState.runLogStore)
        self._historyStore = ObservedObject(wrappedValue: appState.historyStore)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(runSessionStore.currentTaskTitle)
                                    .font(.title2.weight(.semibold))

                                Text(statusSubtitle)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                            statusBadge
                        }

                        // Show an indeterminate spinner during planning phases where we
                        // don't yet know the total file count; deterministic bar otherwise.
                        if runSessionStore.isRunning
                            && runSessionStore.progress == 0
                            && runSessionStore.currentPhase != nil
                            && runSessionStore.currentPhase != .copy {
                            ProgressView()
                                .progressViewStyle(.linear)
                                .tint(.accentColor)
                                .accessibilityLabel("Run progress")
                                .accessibilityValue("Scanning…")
                        } else {
                            ProgressView(value: runSessionStore.progress)
                                .tint(.accentColor)
                                .accessibilityLabel("Run progress")
                                .accessibilityValue("\(Int(runSessionStore.progress * 100))%")
                        }

                        phaseView
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)], spacing: 12) {
                    metricCard(title: "Discovered", value: abbreviated(runSessionStore.metrics.discoveredCount))
                    metricCard(title: "Planned", value: abbreviated(runSessionStore.metrics.plannedCount))
                    metricCard(title: "Already There", value: abbreviated(runSessionStore.metrics.alreadyInDestinationCount))
                    metricCard(title: "Duplicates", value: abbreviated(runSessionStore.metrics.duplicateCount))
                    metricCard(title: "Issues", value: abbreviated(runSessionStore.issueCount))
                    metricCard(title: "Copied", value: abbreviated(runSessionStore.metrics.copiedCount))
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        overviewPanel
                            .frame(minWidth: 300, maxWidth: .infinity, alignment: .leading)

                        consolePanel
                            .frame(minWidth: 340, maxWidth: .infinity, alignment: .leading)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        overviewPanel
                        consolePanel
                    }
                }
            }
            .padding(DesignTokens.Layout.contentPadding)
            .frame(maxWidth: DesignTokens.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Current Run")
    }

    private var overviewPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Overview")
                    .font(.headline)

                summaryRow("Mode", runSessionStore.currentMode?.title ?? "Idle")
                summaryRow(
                    "Speed",
                    runSessionStore.metrics.speedMBps > 0
                        ? String(format: "%.1f MB/s", runSessionStore.metrics.speedMBps)
                        : "—"
                )
                summaryRow("ETA", formattedETA(runSessionStore.metrics.etaSeconds))
                summaryRow("Warnings", "\(runLogStore.warningCount)")
                summaryRow("Errors", "\(runLogStore.errorCount)")

                if let destination = destinationRoot, !destination.isEmpty {
                    Divider()

                    Text(destination)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
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
    }

    private var consolePanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Console")
                    .font(.headline)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if runLogStore.entries.isEmpty {
                            Text("The console will appear here once the backend emits activity.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(runLogStore.entries) { entry in
                                Text(entry.text)
                                    .font(.system(size: DesignTokens.Layout.consoleFontSize, weight: .regular, design: .monospaced))
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

    private var statusSubtitle: String {
        switch runSessionStore.status {
        case .idle:
            return "Preview first, then transfer when the plan looks right."
        case .preflighting:
            return "Checking the current configuration and backend readiness."
        case .running:
            return "Chronoframe is streaming live phase progress into the macOS workspace."
        case .dryRunFinished:
            return "The preview completed without copying files."
        case .finished:
            return "The transfer finished and artifacts are ready to inspect."
        case .nothingToCopy:
            return "The destination already contains everything this run needs."
        case .cancelled:
            return "The run stopped before completion."
        case .failed:
            return runSessionStore.lastErrorMessage ?? "The run failed."
        }
    }

    private var statusBadge: some View {
        Text(statusTitle)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            .accessibilityLabel("Status: \(statusTitle)")
            .accessibilityIdentifier("statusBadge")
    }

    private var phaseView: some View {
        ViewThatFits(in: .horizontal) {
            phaseRow(showLabels: true)
            compactPhaseRow
        }
    }

    private var compactPhaseRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let currentPhase = runSessionStore.currentPhase {
                Text(currentPhase.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

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

    private func phaseAccessibilityLabel(for phase: RunPhase) -> String {
        guard let currentPhase = runSessionStore.currentPhase else {
            return "Phase \(phase.title): not started"
        }
        let currentIndex = RunPhase.allCases.firstIndex(of: currentPhase) ?? 0
        let phaseIndex   = RunPhase.allCases.firstIndex(of: phase)        ?? 0
        if phaseIndex < currentIndex {
            return "Phase \(phase.title): complete"
        } else if phase == currentPhase {
            return "Phase \(phase.title): in progress"
        } else {
            return "Phase \(phase.title): pending"
        }
    }

    private var artifactButtons: some View {
        Group {
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
    }

    private var destinationRoot: String? {
        let destination = runSessionStore.summary?.artifacts.destinationRoot ?? historyStore.destinationRoot
        return destination.isEmpty ? nil : destination
    }

    private var statusTitle: String {
        switch runSessionStore.status {
        case .idle:
            return "Idle"
        case .preflighting:
            return "Preparing"
        case .running:
            return "Running"
        case .dryRunFinished:
            return "Preview Complete"
        case .finished:
            return "Finished"
        case .nothingToCopy:
            return "Up to Date"
        case .cancelled:
            return "Cancelled"
        case .failed:
            return "Failed"
        }
    }

    private func fill(for phase: RunPhase) -> Color {
        guard let currentPhase = runSessionStore.currentPhase else {
            return Color.secondary.opacity(0.2)
        }
        if phase == currentPhase {
            return .accentColor
        }
        if RunPhase.allCases.firstIndex(of: phase) ?? 0 < RunPhase.allCases.firstIndex(of: currentPhase) ?? 0 {
            return .green
        }
        return Color.secondary.opacity(0.2)
    }

    private func connectorFill(after phase: RunPhase) -> Color {
        guard let currentPhase = runSessionStore.currentPhase else {
            return Color.secondary.opacity(0.15)
        }
        return (RunPhase.allCases.firstIndex(of: phase) ?? 0 < RunPhase.allCases.firstIndex(of: currentPhase) ?? 0)
            ? .green
            : Color.secondary.opacity(0.15)
    }

    private func metricCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }

    private func summaryRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
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

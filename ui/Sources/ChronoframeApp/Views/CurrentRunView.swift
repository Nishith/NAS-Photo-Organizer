#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

private enum ActivityPane: String, CaseIterable, Identifiable {
    case summary = "Summary"
    case console = "Console"

    var id: String { rawValue }
}

struct CurrentRunView: View {
    @ObservedObject var appState: AppState
    @State private var activityPane: ActivityPane = .summary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current Run")
                        .font(.largeTitle.weight(.bold))
                    Text(statusSubtitle)
                        .foregroundStyle(.secondary)
                }

                GroupBox("Status") {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(appState.runSessionStore.currentTaskTitle)
                                .font(.title2.weight(.semibold))
                            Spacer()
                            statusBadge
                        }

                        ProgressView(value: appState.runSessionStore.progress)
                            .tint(.accentColor)

                        phaseRow
                    }
                }

                GroupBox("Metrics") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        metricCard(title: "Discovered", value: abbreviated(appState.runSessionStore.metrics.discoveredCount))
                        metricCard(title: "Planned", value: abbreviated(appState.runSessionStore.metrics.plannedCount))
                        metricCard(title: "Already There", value: abbreviated(appState.runSessionStore.metrics.alreadyInDestinationCount))
                        metricCard(title: "Duplicates", value: abbreviated(appState.runSessionStore.metrics.duplicateCount))
                        metricCard(title: "Issues", value: abbreviated(appState.runSessionStore.issueCount))
                        metricCard(title: "Copied", value: abbreviated(appState.runSessionStore.metrics.copiedCount))
                    }
                }

                GroupBox("Artifacts") {
                    HStack(spacing: 12) {
                        Button("Open Destination") {
                            appState.openDestination()
                        }
                        .disabled((appState.runSessionStore.summary?.artifacts.destinationRoot ?? "").isEmpty)

                        Button("Open Report") {
                            appState.openReport()
                        }
                        .disabled(appState.runSessionStore.summary?.artifacts.reportPath == nil)

                        Button("Open Logs") {
                            appState.openLogsDirectory()
                        }
                        .disabled(appState.runSessionStore.summary?.artifacts.logsDirectoryPath == nil)

                        Spacer()
                    }
                }

                GroupBox("Activity") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Activity", selection: $activityPane) {
                            ForEach(ActivityPane.allCases) { pane in
                                Text(pane.rawValue).tag(pane)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)

                        if activityPane == .summary {
                            VStack(alignment: .leading, spacing: 8) {
                                summaryRow("Mode", appState.runSessionStore.currentMode?.title ?? "Idle")
                                summaryRow("Speed", appState.runSessionStore.metrics.speedMBps > 0 ? String(format: "%.1f MB/s", appState.runSessionStore.metrics.speedMBps) : "—")
                                summaryRow("ETA", formattedETA(appState.runSessionStore.metrics.etaSeconds))
                                summaryRow("Warnings", "\(appState.runLogStore.warningCount)")
                                summaryRow("Errors", "\(appState.runLogStore.errorCount)")
                            }
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    if appState.runSessionStore.logLines.isEmpty {
                                        Text("The console will appear here once the backend emits activity.")
                                            .foregroundStyle(.secondary)
                                    } else {
                                        ForEach(Array(appState.runSessionStore.logLines.enumerated()), id: \.offset) { _, line in
                                            Text(line)
                                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .textSelection(.enabled)
                                        }
                                    }
                                }
                            }
                            .frame(minHeight: 240)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Current Run")
    }

    private var statusSubtitle: String {
        switch appState.runSessionStore.status {
        case .idle:
            return "Preview first, then transfer when the plan looks right."
        case .preflighting:
            return "Checking the current configuration and backend readiness."
        case .running:
            return "The Python organizer is streaming live phase progress into the macOS workspace."
        case .dryRunFinished:
            return "The preview completed without copying files."
        case .finished:
            return "The transfer finished and artifacts are ready to inspect."
        case .nothingToCopy:
            return "The destination already contains everything this run needs."
        case .cancelled:
            return "The run stopped before completion."
        case .failed:
            return appState.runSessionStore.lastErrorMessage ?? "The run failed."
        }
    }

    private var statusBadge: some View {
        Text(appState.runSessionStore.status.rawValue.capitalized)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
    }

    private var phaseRow: some View {
        HStack(spacing: 10) {
            ForEach(RunPhase.allCases, id: \.self) { phase in
                VStack(spacing: 8) {
                    Circle()
                        .fill(fill(for: phase))
                        .frame(width: 20, height: 20)
                    Text(phase.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if phase != RunPhase.allCases.last {
                    Capsule()
                        .fill(connectorFill(after: phase))
                        .frame(height: 4)
                }
            }
        }
    }

    private func fill(for phase: RunPhase) -> Color {
        guard let currentPhase = appState.runSessionStore.currentPhase else {
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
        guard let currentPhase = appState.runSessionStore.currentPhase else {
            return Color.secondary.opacity(0.15)
        }
        return (RunPhase.allCases.firstIndex(of: phase) ?? 0 < RunPhase.allCases.firstIndex(of: currentPhase) ?? 0) ? .green : Color.secondary.opacity(0.15)
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

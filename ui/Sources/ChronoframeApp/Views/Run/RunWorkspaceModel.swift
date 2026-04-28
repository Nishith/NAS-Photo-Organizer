import Foundation
import SwiftUI
#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif

enum RunWorkspaceTab: String, CaseIterable, Identifiable {
    case overview
    case issues
    case console

    var id: String { rawValue }
}

enum RunWorkspaceTone: String, Equatable {
    case idle
    case ready
    case active
    case success
    case warning
    case danger
    case accent
    case muted

    var color: SwiftUI.Color {
        switch self {
        case .idle:
            return DesignTokens.Status.idle
        case .ready:
            return DesignTokens.Status.ready
        case .active:
            return DesignTokens.Status.active
        case .success:
            return DesignTokens.Status.success
        case .warning:
            return DesignTokens.Color.warning
        case .danger:
            return DesignTokens.Color.danger
        case .accent:
            return DesignTokens.Color.sky
        case .muted:
            return DesignTokens.Color.inkMuted
        }
    }
}

enum RunHeroPrimaryAction: Equatable {
    case setup
    case preview
    case transfer
    case cancel
    case openDestination
    case showIssues
}

struct RunHeroState: Equatable {
    let title: String
    let message: String
    let badgeTitle: String
    let badgeSymbol: String
    let heroSymbol: String
    let tone: RunWorkspaceTone
    let primaryAction: RunHeroPrimaryAction?
}

struct RunMetricTileModel: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String
    let caption: String
    let tone: RunWorkspaceTone
}

struct RunIssueLineModel: Identifiable, Equatable {
    let id: Int
    let text: String
    let tone: RunWorkspaceTone
}

struct RunWorkspaceLogLine: Identifiable, Equatable {
    let id: Int
    let text: String
}

struct RunPhaseTimelineEntry: Identifiable, Equatable {
    enum State: Equatable {
        case pending
        case current
        case complete
    }

    let phase: RunPhase
    let state: State

    var id: RunPhase { phase }
}

struct RunWorkspaceContext {
    var status: RunStatus
    var currentMode: RunMode?
    var currentTaskTitle: String
    var currentPhase: RunPhase?
    var progress: Double
    var metrics: RunMetrics
    var summary: RunSummary?
    var lastErrorMessage: String?
    var warningCount: Int
    var errorCount: Int
    var issueCount: Int
    var logEntries: [RunWorkspaceLogLine]
    var historyDestinationRoot: String
    var currentSourceRoot: String
    var canStartRun: Bool
}

struct RunWorkspaceModel {
    let context: RunWorkspaceContext

    @MainActor
    init(
        runSessionStore: RunSessionStore,
        runLogStore: RunLogStore,
        historyStore: HistoryStore,
        canStartRun: Bool
    ) {
        self.init(
            context: RunWorkspaceContext(
                status: runSessionStore.status,
                currentMode: runSessionStore.currentMode,
                currentTaskTitle: runSessionStore.currentTaskTitle,
                currentPhase: runSessionStore.currentPhase,
                progress: runSessionStore.progress,
                metrics: runSessionStore.metrics,
                summary: runSessionStore.summary,
                lastErrorMessage: runSessionStore.lastErrorMessage,
                warningCount: runLogStore.warningCount,
                errorCount: runLogStore.errorCount,
                issueCount: runSessionStore.issueCount,
                logEntries: Array(runLogStore.entries).map { entry in
                    RunWorkspaceLogLine(id: entry.id, text: entry.text)
                },
                historyDestinationRoot: historyStore.destinationRoot,
                currentSourceRoot: runSessionStore.lastPreflight?.resolvedSourcePath
                    ?? runSessionStore.lastPreflight?.configuration.sourcePath
                    ?? "",
                canStartRun: canStartRun
            )
        )
    }

    init(context: RunWorkspaceContext) {
        self.context = context
    }

    var heroState: RunHeroState {
        switch context.status {
        case .idle:
            return RunHeroState(
                title: context.canStartRun ? "Preview Before You Commit" : "This Workspace Activates After Setup",
                message: context.canStartRun
                    ? "Run a non-destructive preview to inspect what will be copied, what will be skipped, and where the destination will be updated."
                    : "Choose a source and destination first, then use this workspace to review progress, issues, and artifacts through the entire run.",
                badgeTitle: "Idle",
                badgeSymbol: "circle.dashed",
                heroSymbol: "eye",
                tone: context.canStartRun ? .ready : .idle,
                primaryAction: context.canStartRun ? .preview : .setup
            )

        case .preflighting:
            return RunHeroState(
                title: "Checking the Next Run",
                message: "Chronoframe is validating the configuration, resolving bookmarks, and preparing a safe next step before the backend starts.",
                badgeTitle: "Preparing",
                badgeSymbol: "clock.arrow.circlepath",
                heroSymbol: "clock.arrow.circlepath",
                tone: .ready,
                primaryAction: nil
            )

        case .running:
            let mode = context.currentMode ?? .transfer
            return RunHeroState(
                title: mode == .preview ? "Preview in Progress" : "Transfer in Progress",
                message: "This workspace updates live as Chronoframe moves through each phase, tracks issues, and keeps the destination artifacts ready to inspect.",
                badgeTitle: mode == .preview ? "Preview Running" : "Transfer Running",
                badgeSymbol: "arrow.triangle.2.circlepath",
                heroSymbol: "bolt.horizontal.circle",
                tone: .active,
                primaryAction: .cancel
            )

        case .dryRunFinished:
            return RunHeroState(
                title: "Preview Ready for Review",
                message: "Nothing has been copied. Inspect the planned work, any issues, and the destination before starting the transfer.",
                badgeTitle: "Preview Complete",
                badgeSymbol: "checkmark.circle.fill",
                heroSymbol: "doc.text.magnifyingglass",
                tone: .ready,
                primaryAction: .transfer
            )

        case .finished:
            return RunHeroState(
                title: "Transfer Complete",
                message: "Organized files, logs, and receipts are ready to inspect. Open the destination to verify the result in Finder.",
                badgeTitle: "Finished",
                badgeSymbol: "checkmark.circle.fill",
                heroSymbol: "checkmark.circle.fill",
                tone: .success,
                primaryAction: .openDestination
            )

        case .nothingToCopy:
            return RunHeroState(
                title: "Destination Already Up To Date",
                message: "Chronoframe did not find any new files to copy for this configuration. The destination already contains everything it needs.",
                badgeTitle: "Up to Date",
                badgeSymbol: "checkmark.seal.fill",
                heroSymbol: "checkmark.seal.fill",
                tone: .success,
                primaryAction: .openDestination
            )

        case .cancelled:
            return RunHeroState(
                title: "Run Cancelled",
                message: "The run stopped before completion. Review the current state, inspect any partial artifacts, and start again when you are ready.",
                badgeTitle: "Cancelled",
                badgeSymbol: "pause.circle.fill",
                heroSymbol: "pause.circle.fill",
                tone: .warning,
                primaryAction: context.canStartRun ? .preview : .setup
            )

        case .failed:
            return RunHeroState(
                title: "Run Needs Attention",
                message: context.lastErrorMessage ?? "Chronoframe could not finish this run. Your source files were left untouched. Check that both folders are available, then try again.",
                badgeTitle: "Failed",
                badgeSymbol: "exclamationmark.octagon.fill",
                heroSymbol: "exclamationmark.triangle.fill",
                tone: .danger,
                primaryAction: .showIssues
            )

        case .reverted:
            return RunHeroState(
                title: "Revert Complete",
                message: "Chronoframe removed the files restored by this audit receipt. Files modified after the original copy were preserved.",
                badgeTitle: "Reverted",
                badgeSymbol: "arrow.uturn.backward.circle.fill",
                heroSymbol: "arrow.uturn.backward.circle.fill",
                tone: .success,
                primaryAction: .openDestination
            )

        case .revertEmpty:
            return RunHeroState(
                title: "Nothing to Revert",
                message: "This audit receipt has no transfers to undo.",
                badgeTitle: "Empty",
                badgeSymbol: "tray",
                heroSymbol: "tray",
                tone: .ready,
                primaryAction: .openDestination
            )

        case .reorganized:
            return RunHeroState(
                title: "Reorganize Complete",
                message: "Chronoframe restructured the destination to match the new folder layout. Open Finder to verify the result.",
                badgeTitle: "Reorganized",
                badgeSymbol: "rectangle.3.offgrid.fill",
                heroSymbol: "rectangle.3.offgrid.fill",
                tone: .success,
                primaryAction: .openDestination
            )

        case .nothingToReorganize:
            return RunHeroState(
                title: "Layout Already Correct",
                message: "Every file in the destination is already in the requested layout — no moves required.",
                badgeTitle: "Up to Date",
                badgeSymbol: "checkmark.seal.fill",
                heroSymbol: "checkmark.seal.fill",
                tone: .success,
                primaryAction: .openDestination
            )
        }
    }

    var showsProgressSurface: Bool {
        context.currentPhase != nil || context.status == .running
    }

    var progressAccessibilityValue: String {
        if context.status == .running
            && context.progress == 0
            && context.currentPhase != nil
            && context.currentPhase != .copy {
            return "Scanning"
        }
        return "\(Int(context.progress * 100))%"
    }

    var destinationRoot: String? {
        let destination = context.summary?.artifacts.destinationRoot ?? context.historyDestinationRoot
        return destination.isEmpty ? nil : destination
    }

    var destinationSummaryValue: String {
        destinationRoot ?? "Destination will appear here once a run is configured"
    }

    var sourceRoot: String? {
        context.currentSourceRoot.isEmpty ? nil : context.currentSourceRoot
    }

    var sourceSummaryValue: String {
        sourceRoot ?? "Source will appear here once a run is configured"
    }

    var issueSummaryValue: String {
        let warningCount = context.warningCount
        let errorCount = max(context.errorCount, context.issueCount)
        if warningCount == 0 && errorCount == 0 {
            return "No issues reported"
        }
        return "\(warningCount) warning\(warningCount == 1 ? "" : "s"), \(errorCount) error\(errorCount == 1 ? "" : "s")"
    }

    var issueTone: RunWorkspaceTone {
        if max(context.errorCount, context.issueCount) > 0 {
            return .danger
        }
        if context.warningCount > 0 {
            return .warning
        }
        return .success
    }

    var warningTone: RunWorkspaceTone {
        context.warningCount > 0 ? .warning : .muted
    }

    var errorTone: RunWorkspaceTone {
        max(context.errorCount, context.issueCount) > 0 ? .danger : .muted
    }

    var speedSummaryValue: String {
        context.metrics.speedMBps > 0 ? String(format: "%.1f MB/s", context.metrics.speedMBps) : "—"
    }

    var etaSummaryValue: String {
        formattedETA(context.metrics.etaSeconds)
    }

    var showsCopyProgressDetails: Bool {
        context.currentPhase == .copy || context.metrics.copiedCount > 0
    }

    var fileProgressSummaryValue: String {
        let total = max(context.metrics.plannedCount, 0)
        let copied = max(context.metrics.copiedCount, 0)
        guard total > 0 else {
            return copied > 0 ? "\(copied.formatted()) files copied" : "Preparing copy queue"
        }

        let percent = min(100, max(0, Int((Double(copied) / Double(total) * 100).rounded())))
        return "\(copied.formatted()) of \(total.formatted()) files · \(percent)%"
    }

    var byteProgressSummaryValue: String {
        guard context.metrics.bytesTotal > 0 else {
            return "Measuring"
        }

        return "\(formattedBytes(context.metrics.bytesCopied)) of \(formattedBytes(context.metrics.bytesTotal))"
    }

    var throughputSummaryValue: String {
        let speed = speedSummaryValue
        let eta = etaSummaryValue
        if speed == "—", eta == "—" {
            return "Waiting for next file"
        }
        if eta == "—" {
            return speed
        }
        return "\(speed) · \(eta)"
    }

    var phaseEntries: [RunPhaseTimelineEntry] {
        RunPhase.allCases.map { phase in
            let state: RunPhaseTimelineEntry.State
            guard let currentPhase = context.currentPhase else {
                state = .pending
                return RunPhaseTimelineEntry(phase: phase, state: state)
            }

            let currentIndex = RunPhase.allCases.firstIndex(of: currentPhase) ?? 0
            let phaseIndex = RunPhase.allCases.firstIndex(of: phase) ?? 0
            if phaseIndex < currentIndex {
                state = .complete
            } else if phase == currentPhase {
                state = .current
            } else {
                state = .pending
            }
            return RunPhaseTimelineEntry(phase: phase, state: state)
        }
    }

    var phaseStripTooltip: String {
        let entries = phaseEntries
        let complete = entries.filter { $0.state == .complete }.map { $0.phase.title }
        let current = entries.filter { $0.state == .current }.map { $0.phase.title }
        let pending = entries.filter { $0.state == .pending }.map { $0.phase.title }

        func line(color: String, label: String, names: [String]) -> String {
            let joined = names.isEmpty ? "none" : names.joined(separator: ", ")
            return "\(color) · \(label) (\(names.count)): \(joined)"
        }

        return [
            "Phase progress",
            line(color: "Green", label: "Complete", names: complete),
            line(color: "Yellow", label: "Current", names: current),
            line(color: "Gray", label: "Pending", names: pending),
        ].joined(separator: "\n")
    }

    var showsPreviewReview: Bool {
        context.status == .dryRunFinished
    }

    var previewReviewMessage: String {
        context.metrics.plannedCount > 0
            ? "Nothing has been copied yet. \(context.metrics.plannedCount.formatted()) files are ready to transfer once the plan looks right."
            : "The preview found nothing new to copy. The destination already contains everything needed."
    }

    var canStartTransferFromPreview: Bool {
        context.metrics.plannedCount > 0 && context.canStartRun
    }

    var metrics: [RunMetricTileModel] {
        [
            RunMetricTileModel(
                id: "discovered",
                title: "Discovered",
                value: abbreviated(context.metrics.discoveredCount),
                caption: "Items found in the source library.",
                tone: .accent
            ),
            RunMetricTileModel(
                id: "planned",
                title: "Planned",
                value: abbreviated(context.metrics.plannedCount),
                caption: "Files queued for review or transfer.",
                tone: .ready
            ),
            RunMetricTileModel(
                id: "already",
                title: "Already There",
                value: abbreviated(context.metrics.alreadyInDestinationCount),
                caption: "Skipped because matching copies already exist.",
                tone: .success
            ),
            RunMetricTileModel(
                id: "duplicates",
                title: "Duplicates",
                value: abbreviated(context.metrics.duplicateCount),
                caption: "Exact duplicates routed away from the main transfer.",
                tone: .warning
            ),
            RunMetricTileModel(
                id: "issues",
                title: "Issues",
                value: abbreviated(context.issueCount),
                caption: "Warnings, failed copies, or hash errors to review.",
                tone: issueTone
            ),
            RunMetricTileModel(
                id: "copied",
                title: "Copied",
                value: abbreviated(context.metrics.copiedCount),
                caption: "Files successfully copied during transfer.",
                tone: .success
            ),
        ]
    }

    var issueEntries: [RunIssueLineModel] {
        context.logEntries
            .filter { isIssueLine($0.text) }
            .map { entry in
                RunIssueLineModel(id: entry.id, text: entry.text, tone: tone(for: entry.text))
            }
    }

    var issueWorkspaceSummary: String {
        issueEntries.isEmpty
            ? "No warnings or errors have been reported yet. If something changes, this view will pull the high-signal items out of the full activity log."
            : "Warnings and errors are separated here so you can review the highest-signal problems without scanning the entire activity log."
    }

    var reportPath: String? {
        context.summary?.artifacts.reportPath
    }

    var logsDirectoryPath: String? {
        context.summary?.artifacts.logsDirectoryPath
    }

    var consoleEntries: [RunWorkspaceLogLine] {
        context.logEntries
    }

    func tabTitle(_ tab: RunWorkspaceTab) -> String {
        switch tab {
        case .overview:
            return "Overview"
        case .issues:
            let count = max(context.warningCount + context.errorCount, context.issueCount)
            return count > 0 ? "Issues (\(count))" : "Issues"
        case .console:
            return "Console"
        }
    }

    func lineTone(for line: String) -> RunWorkspaceTone {
        tone(for: line)
    }

    func phaseAccessibilityLabel(for phase: RunPhase) -> String {
        guard let currentPhase = context.currentPhase else {
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

    private func tone(for line: String) -> RunWorkspaceTone {
        if line.hasPrefix("ERROR:") {
            return .danger
        }
        if isIssueLine(line) {
            return .warning
        }
        return .muted
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

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

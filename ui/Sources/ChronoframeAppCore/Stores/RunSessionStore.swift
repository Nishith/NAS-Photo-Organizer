#if canImport(ChronoframeCore)
import ChronoframeCore
#endif
import Foundation
import Combine

@MainActor
public final class RunSessionStore: ObservableObject {
    @Published public private(set) var status: RunStatus
    @Published public private(set) var currentMode: RunMode?
    @Published public private(set) var currentTaskTitle: String
    @Published public private(set) var currentPhase: RunPhase?
    @Published public private(set) var progress: Double
    @Published public private(set) var metrics: RunMetrics
    @Published public private(set) var artifacts: RunArtifactPaths
    @Published public private(set) var summary: RunSummary?
    @Published public private(set) var prompt: RunPrompt?
    @Published public private(set) var lastPreflight: RunPreflight?
    @Published public private(set) var lastErrorMessage: String?

    private let engine: any OrganizerEngine
    private let logStore: RunLogStore
    private let historyStore: HistoryStore
    private var streamTask: Task<Void, Never>?
    private var copySpeedLastSampleDate = Date()
    private var copySpeedLastBytes = 0

    public init(engine: any OrganizerEngine, logStore: RunLogStore, historyStore: HistoryStore) {
        self.engine = engine
        self.logStore = logStore
        self.historyStore = historyStore
        self.status = .idle
        self.currentMode = nil
        self.currentTaskTitle = "Idle"
        self.currentPhase = nil
        self.progress = 0
        self.metrics = RunMetrics()
        self.artifacts = RunArtifactPaths()
        self.summary = nil
        self.prompt = nil
        self.lastPreflight = nil
        self.lastErrorMessage = nil
    }

    public var isRunning: Bool {
        status == .running
    }

    public var logLines: [String] {
        logStore.lines
    }

    public var issueCount: Int {
        max(metrics.errorCount, metrics.hashErrorCount + metrics.failedCount)
    }

    public func requestRun(mode: RunMode, configuration: RunConfiguration) async {
        resetSessionState(mode: mode)
        status = .preflighting
        currentTaskTitle = "Preparing \(mode.title)..."

        do {
            let preflight = try await engine.preflight(configuration)
            lastPreflight = preflight

            if !preflight.missingDependencies.isEmpty {
                prompt = RunPrompt(
                    kind: .blockingError,
                    title: "Missing Python Dependencies",
                    message: "Install these packages for the backend before running Chronoframe: \(preflight.missingDependencies.joined(separator: ", ")).",
                    preflight: preflight
                )
                return
            }

            if mode == .transfer {
                let promptKind: RunPromptKind = preflight.pendingJobCount > 0 ? .resumePendingJobs : .confirmTransfer
                let message: String
                if preflight.pendingJobCount > 0 {
                    message = "Chronoframe found \(preflight.pendingJobCount) pending copy jobs in the destination queue. Continue by resuming the persisted transfer?"
                } else {
                    message = "Chronoframe will leave the source untouched and transfer into \(preflight.resolvedDestinationPath). Continue?"
                }

                prompt = RunPrompt(
                    kind: promptKind,
                    title: preflight.pendingJobCount > 0 ? "Resume Pending Transfer" : "Start Transfer",
                    message: message,
                    preflight: preflight
                )
                return
            }

            beginStream(using: preflight, resumePendingJobs: false)
        } catch {
            handleFailure(message: error.localizedDescription)
        }
    }

    public func confirmPrompt() {
        guard let prompt else { return }

        switch prompt.kind {
        case .blockingError:
            dismissPrompt()
        case .confirmTransfer:
            guard let preflight = prompt.preflight else {
                dismissPrompt()
                return
            }
            beginStream(using: preflight, resumePendingJobs: false)
        case .resumePendingJobs:
            guard let preflight = prompt.preflight else {
                dismissPrompt()
                return
            }
            beginStream(using: preflight, resumePendingJobs: true)
        }
    }

    public func dismissPrompt() {
        prompt = nil
        if status == .preflighting {
            status = .idle
            currentTaskTitle = "Idle"
        }
    }

    public func cancelCurrentRun() {
        engine.cancelCurrentRun()
        streamTask?.cancel()
        streamTask = nil

        if isRunning {
            status = .cancelled
            currentTaskTitle = "Cancelled"
            metrics.speedMBps = 0
            metrics.etaSeconds = nil
            summary = RunSummary(
                status: .cancelled,
                title: "Cancelled",
                metrics: metrics,
                artifacts: artifacts
            )
        }
    }

    private func resetSessionState(mode: RunMode) {
        streamTask?.cancel()
        streamTask = nil
        currentMode = mode
        currentPhase = nil
        currentTaskTitle = "Idle"
        progress = 0
        metrics = RunMetrics()
        artifacts = RunArtifactPaths()
        summary = nil
        prompt = nil
        lastPreflight = nil
        lastErrorMessage = nil
        logStore.clear()
        copySpeedLastSampleDate = Date()
        copySpeedLastBytes = 0
    }

    private func beginStream(using preflight: RunPreflight, resumePendingJobs: Bool) {
        prompt = nil
        status = .running
        currentMode = preflight.configuration.mode
        currentTaskTitle = resumePendingJobs ? "Resuming transfer..." : "Starting \(preflight.configuration.mode.title.lowercased())..."
        artifacts = RunArtifactPaths(
            destinationRoot: preflight.resolvedDestinationPath,
            reportPath: nil,
            logFilePath: URL(fileURLWithPath: preflight.resolvedDestinationPath).appendingPathComponent(".organize_log.txt").path,
            logsDirectoryPath: URL(fileURLWithPath: preflight.resolvedDestinationPath).appendingPathComponent(".organize_logs", isDirectory: true).path
        )

        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let stream = try resumePendingJobs
                    ? engine.resume(preflight.configuration)
                    : engine.start(preflight.configuration)

                for try await event in stream {
                    self.consume(event)
                }
            } catch {
                self.handleFailure(message: error.localizedDescription)
            }
        }
    }

    private func consume(_ event: RunEvent) {
        switch event {
        case .startup:
            currentTaskTitle = "Initializing..."
            logStore.append("Engine started.")

        case let .phaseStarted(phase, _):
            currentPhase = phase
            currentTaskTitle = phase.runningTitle
            progress = 0
            metrics.speedMBps = 0
            metrics.etaSeconds = nil
            if phase == .copy {
                copySpeedLastBytes = 0
                copySpeedLastSampleDate = Date()
            }

        case let .phaseProgress(phase, completed, total, bytesCopied, bytesTotal):
            if total > 0 {
                progress = Double(completed) / Double(total)
            }

            guard phase == .copy, let bytesCopied, let bytesTotal, bytesTotal > 0 else { return }
            let now = Date()
            let elapsed = now.timeIntervalSince(copySpeedLastSampleDate)
            if elapsed >= 0.5 {
                let delta = bytesCopied - copySpeedLastBytes
                metrics.speedMBps = Double(delta) / elapsed / 1_000_000
                if metrics.speedMBps > 0 {
                    metrics.etaSeconds = Double(bytesTotal - bytesCopied) / (metrics.speedMBps * 1_000_000)
                }
                copySpeedLastBytes = bytesCopied
                copySpeedLastSampleDate = now
            }

        case let .phaseCompleted(phase, result):
            progress = 1
            metrics.speedMBps = 0
            metrics.etaSeconds = nil

            switch phase {
            case .discovery:
                metrics.discoveredCount = result.found ?? metrics.discoveredCount
            case .classification:
                metrics.alreadyInDestinationCount = result.alreadyInDestinationCount ?? metrics.alreadyInDestinationCount
                metrics.duplicateCount = result.duplicateCount ?? metrics.duplicateCount
                metrics.hashErrorCount = result.hashErrorCount ?? metrics.hashErrorCount
                logStore.append("Classification complete:")
                logStore.append("  New files:        \(result.newCount ?? 0)")
                logStore.append("  Already in dest:  \(result.alreadyInDestinationCount ?? 0)")
                logStore.append("  Duplicates:       \(result.duplicateCount ?? 0)")
                if let hashErrors = result.hashErrorCount, hashErrors > 0 {
                    logStore.append("  Hash errors:      \(hashErrors)")
                }
            case .copy:
                metrics.copiedCount = result.copiedCount ?? metrics.copiedCount
                metrics.failedCount = result.failedCount ?? metrics.failedCount
                logStore.append("Copy complete: \(result.copiedCount ?? 0) succeeded, \(result.failedCount ?? 0) failed.")
            case .sourceHashing, .destinationIndexing:
                break
            }

        case let .copyPlanReady(count):
            metrics.plannedCount = count
            logStore.append("Plan ready: \(count) files queued for copy.")

        case let .issue(issue):
            if issue.severity == .error {
                metrics.errorCount += 1
            }
            logStore.append(issue: issue)

        case let .prompt(message):
            prompt = RunPrompt(kind: .blockingError, title: "Backend Prompt", message: message)

        case let .complete(summary):
            status = summary.status
            currentTaskTitle = summary.title
            metrics = summary.metrics
            artifacts = summary.artifacts
            self.summary = summary
            historyStore.refresh(destinationRoot: summary.artifacts.destinationRoot)
            logStore.append("Finished: \(summary.title)")
        }
    }

    private func handleFailure(message: String) {
        status = .failed
        currentTaskTitle = "Failed"
        metrics.speedMBps = 0
        metrics.etaSeconds = nil
        lastErrorMessage = message
        logStore.append("ERROR: \(message)")
        summary = RunSummary(status: .failed, title: "Failed", metrics: metrics, artifacts: artifacts)
    }
}

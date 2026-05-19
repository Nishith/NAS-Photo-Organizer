#if canImport(ChronoframeCore)
import ChronoframeCore
#endif
import Foundation
import Combine
import UserNotifications
#if canImport(AppKit)
import AppKit
#endif

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
    @Published public private(set) var latestPreviewReviewPath: String?
    /// Source URL of the file currently being copied, surfaced by the
    /// transfer phase. UI uses it to render a live QuickLook thumbnail in
    /// the Now-Copying card. `nil` outside of the copy phase or when the
    /// engine has not yet reported a file (e.g. between phases).
    @Published public private(set) var currentFileURL: URL?

    private let engine: any OrganizerEngine
    private let logStore: RunLogStore
    private let historyStore: HistoryStore
    private var streamTask: Task<Void, Never>?
    private var securityScope: SecurityScopedFolderAccess?
    private var copySpeedLastSampleDate = Date()
    private var copySpeedLastBytes = 0
    private var currentPhaseStartDate: Date?
    /// Monotonic token used to drop events from cancelled or replaced
    /// stream tasks. A long-running engine task may yield one more event
    /// after `cancel()` is called but before its `for try await` loop
    /// reaches the next checkpoint, and that yield can race with a new
    /// run the user has just started. Each `streamTask` captures the
    /// epoch value at start; `consumeIfCurrent` drops events whose epoch
    /// no longer matches.
    private var currentRunEpoch: UInt64 = 0

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
        self.latestPreviewReviewPath = nil
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

    public func requestRun(
        mode: RunMode,
        configuration: RunConfiguration,
        securityScope: SecurityScopedFolderAccess? = nil
    ) async {
        resetSessionState(mode: mode)
        self.securityScope = securityScope
        status = .preflighting
        currentTaskTitle = "Preparing \(mode.title)..."

        do {
            let preflight = try await engine.preflight(configuration)
            lastPreflight = preflight

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
            handleFailure(error: error)
        }
    }

    /// Run a revert against the audit receipt at `receiptURL`. Streams the
    /// engine's `RunEvent`s into this store so the standard Run workspace
    /// renders progress, issues, and the final summary.
    public func requestRevert(
        receiptURL: URL,
        destinationRoot: String,
        securityScope: SecurityScopedFolderAccess? = nil
    ) {
        resetSessionState(mode: .revert)
        self.securityScope = securityScope
        status = .running
        currentTaskTitle = "Reverting…"
        artifacts = RunArtifactPaths(
            destinationRoot: destinationRoot,
            reportPath: receiptURL.path,
            logFilePath: nil,
            logsDirectoryPath: URL(fileURLWithPath: destinationRoot)
                .appendingPathComponent(".organize_logs", isDirectory: true).path
        )

        let epoch = currentRunEpoch
        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let stream = try engine.revert(receiptURL: receiptURL, destinationRoot: destinationRoot)
                for try await event in stream {
                    guard self.currentRunEpoch == epoch else { return }
                    self.consume(event)
                }
            } catch {
                guard self.currentRunEpoch == epoch else { return }
                self.handleFailure(error: error)
            }
        }
    }

    /// Reorganize the destination layout to match `targetStructure`. Streams
    /// engine events into this store identically to `requestRun` so the same
    /// UI surface renders progress.
    public func requestReorganize(
        destinationRoot: String,
        targetStructure: FolderStructure,
        securityScope: SecurityScopedFolderAccess? = nil
    ) {
        resetSessionState(mode: .reorganize)
        self.securityScope = securityScope
        status = .running
        currentTaskTitle = "Reorganizing…"
        artifacts = RunArtifactPaths(destinationRoot: destinationRoot)

        let epoch = currentRunEpoch
        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let stream = try engine.reorganize(
                    destinationRoot: destinationRoot,
                    targetStructure: targetStructure
                )
                for try await event in stream {
                    guard self.currentRunEpoch == epoch else { return }
                    self.consume(event)
                }
            } catch {
                guard self.currentRunEpoch == epoch else { return }
                self.handleFailure(error: error)
            }
        }
    }

    public func requestReorganizeRevert(
        receiptURL: URL,
        destinationRoot: String,
        securityScope: SecurityScopedFolderAccess? = nil
    ) {
        resetSessionState(mode: .reorganize)
        self.securityScope = securityScope
        status = .running
        currentTaskTitle = "Undoing Reorganize…"
        artifacts = RunArtifactPaths(
            destinationRoot: destinationRoot,
            reportPath: receiptURL.path,
            logFilePath: nil,
            logsDirectoryPath: URL(fileURLWithPath: destinationRoot)
                .appendingPathComponent(".organize_logs", isDirectory: true).path
        )

        let epoch = currentRunEpoch
        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let executor = ReorganizeExecutor()
                let observer = ReorganizeExecutionObserver(
                    onTaskStart: { total in
                        Task { @MainActor [weak self] in
                            guard let self, self.currentRunEpoch == epoch else { return }
                            self.consume(.phaseStarted(phase: .reorganize, total: total))
                        }
                    },
                    onTaskProgress: { completed, total in
                        Task { @MainActor [weak self] in
                            guard let self, self.currentRunEpoch == epoch else { return }
                            self.consume(.phaseProgress(
                                phase: .reorganize,
                                completed: completed,
                                total: total,
                                bytesCopied: nil,
                                bytesTotal: nil,
                                currentFilePath: nil
                            ))
                        }
                    },
                    onIssue: { issue in
                        Task { @MainActor [weak self] in
                            guard let self, self.currentRunEpoch == epoch else { return }
                            self.consume(.issue(issue))
                        }
                    }
                )
                let result = try executor.revert(receiptURL: receiptURL, observer: observer)
                guard self.currentRunEpoch == epoch else { return }
                consume(.phaseCompleted(
                    phase: .reorganize,
                    result: RunPhaseResult(
                        failedCount: result.failedCount,
                        skippedCount: result.skippedCount,
                        movedCount: result.movedCount
                    )
                ))
                consume(.complete(RunSummary(
                    status: .reorganized,
                    title: "Reorganize undone",
                    metrics: RunMetrics(
                        plannedCount: result.totalMoves,
                        failedCount: result.failedCount,
                        skippedCount: result.skippedCount,
                        movedCount: result.movedCount
                    ),
                    artifacts: artifacts
                )))
            } catch {
                guard self.currentRunEpoch == epoch else { return }
                self.handleFailure(error: error)
            }
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

    /// Discards the stale pending queue at the destination and starts a full
    /// re-plan + transfer, identical to a first-time transfer run.
    public func confirmPromptStartFresh() {
        guard let prompt, let preflight = prompt.preflight else {
            dismissPrompt()
            return
        }
        clearAllJobs(at: preflight.resolvedDestinationPath)
        beginStream(using: preflight, resumePendingJobs: false)
    }

    public func dismissPrompt() {
        prompt = nil
        if status == .preflighting {
            status = .idle
            currentTaskTitle = "Idle"
            closeSecurityScope()
        }
    }

    public func cancelCurrentRun() {
        engine.cancelCurrentRun()
        streamTask?.cancel()
        streamTask = nil
        currentRunEpoch &+= 1

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
        // Phase 1: a pending confirm-prompt was previously left in
        // place when the user cancelled from the Run workspace, so the
        // confirm dialog would stay modal over an already-cancelled
        // run. Clear it so the UI resets cleanly. Also drop the
        // preflight status if we were sitting on it — the prior path
        // only cleared status when `isRunning` was already true.
        prompt = nil
        if status == .preflighting {
            status = .idle
            currentTaskTitle = ""
        }
        closeSecurityScope()
    }

    private func resetSessionState(mode: RunMode) {
        if streamTask != nil || status == .running {
            engine.cancelCurrentRun()
        }
        streamTask?.cancel()
        streamTask = nil
        currentRunEpoch &+= 1
        closeSecurityScope()
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
        latestPreviewReviewPath = nil
        currentFileURL = nil
        logStore.clear()
        copySpeedLastSampleDate = Date()
        copySpeedLastBytes = 0
        currentPhaseStartDate = nil
    }

    private func clearAllJobs(at destinationPath: String) {
        let dbURL = URL(fileURLWithPath: destinationPath)
            .appendingPathComponent(".organize_cache.db")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return }
        do {
            let database = try OrganizerDatabase(url: dbURL)
            defer { database.close() }
            try database.clearAllJobs()
        } catch {
            // Non-fatal: if we can't clear the old queue the fresh plan will
            // still run; some jobs may be skipped by INSERT OR IGNORE but the
            // transfer will proceed as best it can.
        }
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

        let epoch = currentRunEpoch
        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let stream = try resumePendingJobs
                    ? engine.resume(preflight.configuration)
                    : engine.start(preflight.configuration)

                for try await event in stream {
                    guard self.currentRunEpoch == epoch else { return }
                    self.consume(event)
                }
            } catch {
                guard self.currentRunEpoch == epoch else { return }
                self.handleFailure(error: error)
            }
        }
    }

    private func consume(_ event: RunEvent) {
        switch event {
        case .startup:
            currentTaskTitle = "Initializing..."
            logStore.append("Engine started.")

        case let .phaseStarted(phase, total):
            currentPhase = phase
            currentPhaseStartDate = Date()
            if Self.usesFileCountETA(phase), let total, total > 0 {
                currentTaskTitle = Self.formattedFileProgressTitle(
                    phase: phase,
                    completed: 0,
                    total: total,
                    etaSeconds: nil
                )
            } else {
                currentTaskTitle = phase.runningTitle
            }
            progress = 0
            metrics.speedMBps = 0
            metrics.etaSeconds = nil
            if phase == .copy {
                if let total {
                    metrics.plannedCount = max(metrics.plannedCount, total)
                }
                metrics.bytesCopied = 0
                metrics.bytesTotal = 0
                copySpeedLastBytes = 0
                copySpeedLastSampleDate = Date()
            }

        case let .phaseProgress(phase, completed, total, bytesCopied, bytesTotal, currentFilePath):
            if phase == .copy {
                if let path = currentFilePath, !path.isEmpty {
                    currentFileURL = URL(fileURLWithPath: path)
                }
            } else {
                currentFileURL = nil
            }
            if total > 0 {
                progress = Double(completed) / Double(total)
                if phase == .copy {
                    currentTaskTitle = "\(phase.runningTitle) \(completed.formatted()) of \(total.formatted()) files…"
                } else if Self.usesFileCountETA(phase) {
                    let etaSeconds = estimatedFileETA(completed: completed, total: total)
                    metrics.etaSeconds = etaSeconds
                    currentTaskTitle = Self.formattedFileProgressTitle(
                        phase: phase,
                        completed: completed,
                        total: total,
                        etaSeconds: etaSeconds
                    )
                }
            } else {
                // total == 0 means indeterminate (count is known, total is not).
                // Show the running count in the title so the user sees forward progress.
                currentTaskTitle = "\(phase.runningTitle) \(completed.formatted()) files…"
                if Self.usesFileCountETA(phase) {
                    metrics.etaSeconds = nil
                }
            }

            // Keep the Copied metric card updated live during the copy phase
            // so the user sees forward progress rather than "0" the whole time.
            if phase == .copy {
                metrics.copiedCount = completed
            }

            guard phase == .copy, let bytesCopied, let bytesTotal, bytesTotal > 0 else { return }
            metrics.bytesCopied = Int64(bytesCopied)
            metrics.bytesTotal = Int64(bytesTotal)
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
                currentFileURL = nil
                logStore.append("Copy complete: \(result.copiedCount ?? 0) succeeded, \(result.failedCount ?? 0) failed.")
            case .sourceHashing:
                // The planner carries the final discovered count in the sourceHashing
                // phaseCompleted. Propagate it so the Discovered metric card updates
                // as soon as the walk finishes (before the discovery summary fires).
                if let found = result.found {
                    metrics.discoveredCount = found
                }
            case .destinationIndexing:
                break
            case .revert:
                metrics.revertedCount = result.revertedCount ?? metrics.revertedCount
                metrics.skippedCount = result.skippedCount ?? metrics.skippedCount
                metrics.missingCount = result.missingCount ?? metrics.missingCount
                logStore.append(
                    "Revert complete: \(result.revertedCount ?? 0) reverted, "
                    + "\(result.skippedCount ?? 0) preserved, "
                    + "\(result.missingCount ?? 0) already missing."
                )
            case .reorganize:
                metrics.movedCount = result.movedCount ?? metrics.movedCount
                metrics.skippedCount = result.skippedCount ?? metrics.skippedCount
                metrics.failedCount = result.failedCount ?? metrics.failedCount
                logStore.append(
                    "Reorganize complete: \(result.movedCount ?? 0) moved, "
                    + "\(result.skippedCount ?? 0) skipped, "
                    + "\(result.failedCount ?? 0) failed."
                )
            }

        case let .copyPlanReady(count):
            metrics.plannedCount = count
            logStore.append("Plan ready: \(count) files queued for copy.")

        case let .dateHistogram(buckets):
            metrics.dateHistogram = buckets

        case let .issue(issue):
            if issue.severity == .error {
                metrics.errorCount += 1
            }
            logStore.append(issue: issue)

        case let .prompt(message):
            prompt = RunPrompt(
                kind: .blockingError,
                title: "Organizer Needs Attention",
                message: UserFacingErrorMessage.backendPrompt(message)
            )

        case let .complete(summary):
            status = summary.status
            currentTaskTitle = summary.title
            var finalMetrics = summary.metrics
            if finalMetrics.dateHistogram.isEmpty, !metrics.dateHistogram.isEmpty {
                finalMetrics.dateHistogram = metrics.dateHistogram
            }
            let finalSummary = RunSummary(
                status: summary.status,
                title: summary.title,
                metrics: finalMetrics,
                artifacts: summary.artifacts
            )
            metrics = finalMetrics
            artifacts = summary.artifacts
            self.summary = finalSummary
            if finalSummary.status == .dryRunFinished {
                latestPreviewReviewPath = finalSummary.artifacts.previewReviewPath
            }
            // Record this source path in the per-destination "completed sources" log
            // before refreshing, so the refresh re-reads the updated file.
            if finalSummary.status == .finished || finalSummary.status == .nothingToCopy {
                let sourcePath = lastPreflight?.resolvedSourcePath
                    ?? lastPreflight?.configuration.sourcePath
                    ?? ""
                // Don't record drag-and-drop staging dirs: their paths are
                // ephemeral (cleared on next launch) so "Use as source
                // again" would be broken and the entry would look like gibberish.
                if !DroppedItemStager.isStagingPath(sourcePath) {
                    historyStore.recordSuccessfulTransfer(
                        sourcePath: sourcePath,
                        destinationRoot: finalSummary.artifacts.destinationRoot,
                        copiedCount: finalSummary.metrics.copiedCount
                    )
                }
            }
            historyStore.refresh(destinationRoot: finalSummary.artifacts.destinationRoot)
            logStore.append("Finished: \(finalSummary.title)")
            postRunCompletionNotification(summary: finalSummary)
            closeSecurityScope()
        }
    }

    // MARK: - Run completion notifications

    /// Requests permission to display macOS notifications. Call once during app startup.
    public static func requestNotificationPermission() {
        guard isRunningInAppBundle, !notificationsDisabledForUITest else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `UNUserNotificationCenter.current()` raises an NSException when the host
    /// process isn't a proper `.app` bundle (xctest runners, CLI tools), so skip
    /// the call in those contexts.
    private static var isRunningInAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private static var notificationsDisabledForUITest: Bool {
        ProcessInfo.processInfo.environment["CHRONOFRAME_UI_TEST_DISABLE_NOTIFICATIONS"] == "1"
    }

    private func postRunCompletionNotification(summary: RunSummary) {
        guard Self.isRunningInAppBundle, !Self.notificationsDisabledForUITest else { return }
        let content = UNMutableNotificationContent()
        switch summary.status {
        case .finished:
            content.title = "Transfer complete"
            content.body = "\(summary.metrics.copiedCount) file\(summary.metrics.copiedCount == 1 ? "" : "s") copied"
        case .dryRunFinished:
            content.title = "Preview complete"
            content.body = "\(summary.metrics.plannedCount) file\(summary.metrics.plannedCount == 1 ? "" : "s") planned"
        case .nothingToCopy:
            content.title = "Already up to date"
            content.body = "All source files are already in the destination."
        case .failed:
            content.title = "Transfer failed"
            content.body = summary.title
        case .cancelled:
            return  // user-initiated, no notification needed
        default:
            return
        }

        // Attach the app icon as the notification's hero image so it visibly
        // matches what the user sees in the Dock and the in-app brand mark.
        // macOS also uses this to pick the small badge icon in Notification
        // Center when the cached Launch Services icon is stale.
        if let iconURL = Self.notificationAppIconURL(),
           let attachment = try? UNNotificationAttachment(
                identifier: "chronoframe.app-icon",
                url: iconURL,
                options: [UNNotificationAttachmentOptionsThumbnailHiddenKey: false]
           ) {
            content.attachments = [attachment]
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// Returns a stable file URL pointing at a PNG of the app icon, suitable
    /// for `UNNotificationAttachment`. Written once per launch to the caches
    /// directory; cached in memory afterward.
    private static var cachedNotificationIconURL: URL?
    private static func notificationAppIconURL() -> URL? {
        #if canImport(AppKit)
        if let cached = cachedNotificationIconURL,
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        guard let caches = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let url = caches.appendingPathComponent("Chronoframe-NotificationIcon.png")

        guard let icon = NSImage(named: NSImage.applicationIconName) else { return nil }
        // Render at a fixed point size so the attachment always looks crisp;
        // the bundle icon itself is multi-resolution and `tiffRepresentation`
        // picks a representation based on current size.
        icon.size = NSSize(width: 512, height: 512)
        guard let tiff = icon.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        do {
            try png.write(to: url, options: .atomic)
            cachedNotificationIconURL = url
            return url
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    private func handleFailure(error: Error) {
        handleFailure(message: UserFacingErrorMessage.message(for: error, context: .run))
    }

    private func handleFailure(message: String) {
        status = .failed
        currentTaskTitle = "Failed"
        metrics.speedMBps = 0
        metrics.etaSeconds = nil
        lastErrorMessage = message
        logStore.append("ERROR: \(message)")
        summary = RunSummary(status: .failed, title: "Failed", metrics: metrics, artifacts: artifacts)
        closeSecurityScope()
    }

    private func closeSecurityScope() {
        securityScope?.close()
        securityScope = nil
    }

    private func estimatedFileETA(completed: Int, total: Int) -> Double? {
        guard completed > 0, total > completed, let currentPhaseStartDate else {
            return nil
        }

        let elapsed = max(Date().timeIntervalSince(currentPhaseStartDate), 0.001)
        let averageSecondsPerFile = elapsed / Double(completed)
        return averageSecondsPerFile * Double(total - completed)
    }

    private static func usesFileCountETA(_ phase: RunPhase) -> Bool {
        phase == .sourceHashing || phase == .destinationIndexing
    }

    private static func formattedFileProgressTitle(
        phase: RunPhase,
        completed: Int,
        total: Int,
        etaSeconds: Double?
    ) -> String {
        let progress = "\(completed.formatted()) of \(total.formatted()) files"
        guard let etaSeconds, etaSeconds > 0 else {
            return "\(phase.runningTitle) \(progress)"
        }
        return "\(phase.runningTitle) \(progress) · \(formattedRemainingTime(etaSeconds))"
    }

    private static func formattedRemainingTime(_ seconds: Double) -> String {
        let totalSeconds = max(1, Int(seconds.rounded()))
        if totalSeconds < 60 {
            return "less than 1m remaining"
        }
        if totalSeconds < 3_600 {
            return "\(totalSeconds / 60)m remaining"
        }
        return "\(totalSeconds / 3_600)h \((totalSeconds % 3_600) / 60)m remaining"
    }
}

#if canImport(ChronoframeCore)
import ChronoframeCore
#endif
import Foundation

@MainActor
public final class SwiftOrganizerEngine: OrganizerEngine {
    private let profilesRepository: any ProfilesRepositorying
    private let planner: DryRunPlanner
    private let transferExecutor: TransferExecutor
    private var activeTask: Task<Void, Never>?

    public init(
        profilesRepository: any ProfilesRepositorying = ProfilesRepository(),
        planner: DryRunPlanner = DryRunPlanner(),
        transferExecutor: TransferExecutor = TransferExecutor()
    ) {
        self.profilesRepository = profilesRepository
        self.planner = planner
        self.transferExecutor = transferExecutor
    }

    public func preflight(_ configuration: RunConfiguration) async throws -> RunPreflight {
        let resolvedConfiguration = try resolvedConfiguration(for: configuration)
        let pendingJobs = pendingJobCount(destinationRoot: resolvedConfiguration.destinationPath)

        return RunPreflight(
            configuration: resolvedConfiguration,
            resolvedSourcePath: resolvedConfiguration.sourcePath,
            resolvedDestinationPath: resolvedConfiguration.destinationPath,
            pendingJobCount: pendingJobs,
            profilesFilePath: profilesRepository.profilesFileURL().path,
            missingDependencies: []
        )
    }

    public func start(_ configuration: RunConfiguration) throws -> AsyncThrowingStream<RunEvent, Error> {
        let resolvedConfiguration = try resolvedConfiguration(for: configuration)

        switch resolvedConfiguration.mode {
        case .preview:
            return makePreviewStream(configuration: resolvedConfiguration)
        case .transfer:
            return makeTransferStream(configuration: resolvedConfiguration, resumePendingJobs: false)
        }
    }

    public func resume(_ configuration: RunConfiguration) throws -> AsyncThrowingStream<RunEvent, Error> {
        let resolvedConfiguration = try resolvedConfiguration(for: configuration)

        switch resolvedConfiguration.mode {
        case .preview:
            return makePreviewStream(configuration: resolvedConfiguration)
        case .transfer:
            return makeTransferStream(configuration: resolvedConfiguration, resumePendingJobs: true)
        }
    }

    public func cancelCurrentRun() {
        activeTask?.cancel()
        activeTask = nil
    }

    private func resolvedConfiguration(for configuration: RunConfiguration) throws -> RunConfiguration {
        let profiles = try profilesRepository.loadProfiles()
        let resolvedConfiguration: RunConfiguration

        if let profileName = configuration.profileName, !profileName.isEmpty {
            guard let profile = profiles.first(where: { $0.name == profileName }) else {
                throw OrganizerEngineError.profileNotFound(profileName)
            }

            resolvedConfiguration = RunConfiguration(
                mode: configuration.mode,
                sourcePath: profile.sourcePath,
                destinationPath: profile.destinationPath,
                profileName: profileName,
                useFastDestinationScan: configuration.useFastDestinationScan,
                verifyCopies: configuration.verifyCopies,
                workerCount: configuration.workerCount
            )
        } else {
            resolvedConfiguration = configuration
        }

        guard FileManager.default.fileExists(atPath: resolvedConfiguration.sourcePath) else {
            throw OrganizerEngineError.sourceDoesNotExist(resolvedConfiguration.sourcePath)
        }

        guard !resolvedConfiguration.destinationPath.isEmpty else {
            throw OrganizerEngineError.destinationMissing
        }

        return resolvedConfiguration
    }

    private func makePreviewStream(configuration: RunConfiguration) -> AsyncThrowingStream<RunEvent, Error> {
        AsyncThrowingStream { continuation in
            let planner = self.planner
            let task = Task.detached(priority: .userInitiated) {
                do {
                    // Yield startup immediately so the UI transitions out of "Preparing…"
                    // before the (potentially long) planning walk begins.
                    continuation.yield(.startup)

                    let result = try planner.plan(
                        sourceRoot: URL(fileURLWithPath: configuration.sourcePath, isDirectory: true),
                        destinationRoot: URL(fileURLWithPath: configuration.destinationPath, isDirectory: true),
                        fastDestination: configuration.useFastDestinationScan,
                        onEvent: { continuation.yield($0) }
                    )

                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }

                    let artifacts = try Self.writeDryRunArtifacts(
                        result: result,
                        destinationRoot: configuration.destinationPath
                    )
                    let metrics = RunMetrics(
                        discoveredCount: result.discoveredSourceCount,
                        plannedCount: result.transferCount,
                        alreadyInDestinationCount: result.counts.alreadyInDestinationCount,
                        duplicateCount: result.counts.duplicateCount,
                        hashErrorCount: result.counts.hashErrorCount
                    )

                    Self.emitPostPlanningEvents(for: result, into: continuation)
                    continuation.yield(
                        .complete(
                            RunSummary(
                                status: .dryRunFinished,
                                title: "Preview complete",
                                metrics: metrics,
                                artifacts: artifacts
                            )
                        )
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }

                Task { @MainActor in
                    self.activeTask = nil
                }
            }

            self.activeTask = task
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func makeTransferStream(
        configuration: RunConfiguration,
        resumePendingJobs: Bool
    ) -> AsyncThrowingStream<RunEvent, Error> {
        AsyncThrowingStream { continuation in
            let planner = self.planner
            let transferExecutor = self.transferExecutor
            let task = Task.detached(priority: .userInitiated) {
                let destinationURL = URL(fileURLWithPath: configuration.destinationPath, isDirectory: true)
                let databaseURL = destinationURL.appendingPathComponent(EngineArtifactLayout.pythonReference.queueDatabaseFilename)
                let logURL = destinationURL.appendingPathComponent(EngineArtifactLayout.pythonReference.runLogFilename)
                let runLogger = PersistentRunLogger(logURL: logURL)

                do {
                    try runLogger.open()

                    let database = try OrganizerDatabase(url: databaseURL)
                    defer {
                        database.close()
                        runLogger.close()
                    }

                    runLogger.log(
                        "=== Run started: src=\(configuration.sourcePath) dst=\(configuration.destinationPath) dry_run=False workers=\(max(1, configuration.workerCount)) ==="
                    )

                    let cleanedTemporaryFiles = transferExecutor.cleanupTemporaryFiles(at: destinationURL)
                    if cleanedTemporaryFiles > 0 {
                        runLogger.warn("Cleaned up \(cleanedTemporaryFiles) orphaned .tmp files from previous interrupted run")
                        continuation.yield(
                            .issue(
                                RunIssue(
                                    severity: .info,
                                    message: "Cleaned \(cleanedTemporaryFiles) orphaned .tmp files"
                                )
                            )
                        )
                    }

                    continuation.yield(.startup)

                    if resumePendingJobs {
                        try Self.resumeTransfer(
                            configuration: configuration,
                            database: database,
                            destinationURL: destinationURL,
                            transferExecutor: transferExecutor,
                            runLogger: runLogger,
                            continuation: continuation
                        )
                    } else {
                        try Self.startTransfer(
                            configuration: configuration,
                            planner: planner,
                            database: database,
                            destinationURL: destinationURL,
                            transferExecutor: transferExecutor,
                            runLogger: runLogger,
                            continuation: continuation
                        )
                    }
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }

                Task { @MainActor in
                    self.activeTask = nil
                }
            }

            self.activeTask = task
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func pendingJobCount(destinationRoot: String) -> Int {
        let dbURL = URL(fileURLWithPath: destinationRoot).appendingPathComponent(".organize_cache.db")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return 0 }

        do {
            let database = try OrganizerDatabase(url: dbURL, readOnly: true)
            defer { database.close() }
            return try database.pendingJobCount()
        } catch {
            return 0
        }
    }

    private nonisolated static func startTransfer(
        configuration: RunConfiguration,
        planner: DryRunPlanner,
        database: OrganizerDatabase,
        destinationURL: URL,
        transferExecutor: TransferExecutor,
        runLogger: PersistentRunLogger,
        continuation: AsyncThrowingStream<RunEvent, Error>.Continuation
    ) throws {
        let result = try planner.plan(
            sourceRoot: URL(fileURLWithPath: configuration.sourcePath, isDirectory: true),
            destinationRoot: destinationURL,
            fastDestination: configuration.useFastDestinationScan,
            onEvent: { continuation.yield($0) }
        )

        if Task.isCancelled {
            continuation.finish()
            return
        }

        emitPostPlanningEvents(for: result, into: continuation)
        runLogger.log(
            "Classification: \(result.counts.alreadyInDestinationCount) already in dest, \(result.counts.newCount) new, \(result.counts.duplicateCount) internal dups, \(result.counts.hashErrorCount) hash errors"
        )

        for warning in result.warningMessages {
            runLogger.warn(warning)
        }

        if result.transferCount == 0 {
            runLogger.log("Nothing to copy — all files already in destination")
            continuation.yield(
                .complete(
                    RunSummary(
                        status: .nothingToCopy,
                        title: "Already up to date",
                        metrics: RunMetrics(
                            discoveredCount: result.discoveredSourceCount,
                            plannedCount: 0,
                            alreadyInDestinationCount: result.counts.alreadyInDestinationCount,
                            duplicateCount: result.counts.duplicateCount,
                            hashErrorCount: result.counts.hashErrorCount
                        ),
                        artifacts: transferExecutor.artifactPaths(destinationRoot: destinationURL)
                    )
                )
            )
            continuation.finish()
            return
        }

        try database.enqueuePlannedTransfers(result.transfers)
        let errorCounter = IssueCounter()
        let executionResult = try transferExecutor.executeQueuedJobs(
            database: database,
            destinationRoot: destinationURL,
            verifyCopies: configuration.verifyCopies,
            runLogger: runLogger,
            status: .pending,
            orderByInsertion: true,
            observer: TransferExecutionObserver(
                onPhaseStarted: { total, _ in
                    continuation.yield(.phaseStarted(phase: .copy, total: total))
                },
                onPhaseProgress: { completed, total, bytesCopied, bytesTotal in
                    continuation.yield(
                        .phaseProgress(
                            phase: .copy,
                            completed: completed,
                            total: total,
                            bytesCopied: Int(bytesCopied),
                            bytesTotal: Int(bytesTotal)
                        )
                    )
                },
                onIssue: { issue in
                    if issue.severity == .error {
                        errorCounter.increment()
                    }
                    continuation.yield(.issue(issue))
                }
            ),
            isCancelled: { Task.isCancelled }
        )

        if Task.isCancelled {
            continuation.finish()
            return
        }

        continuation.yield(
            .phaseCompleted(
                phase: .copy,
                result: RunPhaseResult(
                    copiedCount: executionResult.copiedCount,
                    failedCount: executionResult.failedCount
                )
            )
        )
        runLogger.log("Run complete")
        continuation.yield(
            .complete(
                RunSummary(
                    status: .finished,
                    title: "Done",
                    metrics: RunMetrics(
                        discoveredCount: result.discoveredSourceCount,
                        plannedCount: result.transferCount,
                        alreadyInDestinationCount: result.counts.alreadyInDestinationCount,
                        duplicateCount: result.counts.duplicateCount,
                        hashErrorCount: result.counts.hashErrorCount,
                        copiedCount: executionResult.copiedCount,
                        failedCount: executionResult.failedCount,
                        errorCount: errorCounter.value
                    ),
                    artifacts: executionResult.artifacts
                )
            )
        )
        continuation.finish()
    }

    private nonisolated static func resumeTransfer(
        configuration: RunConfiguration,
        database: OrganizerDatabase,
        destinationURL: URL,
        transferExecutor: TransferExecutor,
        runLogger: PersistentRunLogger,
        continuation: AsyncThrowingStream<RunEvent, Error>.Continuation
    ) throws {
        let pendingJobCount = try database.pendingJobCount()
        runLogger.log("Found \(pendingJobCount) pending jobs from interrupted session")

        if pendingJobCount == 0 {
            continuation.yield(
                .complete(
                    RunSummary(
                        status: .nothingToCopy,
                        title: "Already up to date",
                        metrics: RunMetrics(),
                        artifacts: transferExecutor.artifactPaths(destinationRoot: destinationURL)
                    )
                )
            )
            continuation.finish()
            return
        }

        let errorCounter = IssueCounter()
        let executionResult = try transferExecutor.executeQueuedJobs(
            database: database,
            destinationRoot: destinationURL,
            verifyCopies: configuration.verifyCopies,
            runLogger: runLogger,
            status: .pending,
            orderByInsertion: true,
            observer: TransferExecutionObserver(
                onPhaseStarted: { total, _ in
                    continuation.yield(.phaseStarted(phase: .copy, total: total))
                },
                onPhaseProgress: { completed, total, bytesCopied, bytesTotal in
                    continuation.yield(
                        .phaseProgress(
                            phase: .copy,
                            completed: completed,
                            total: total,
                            bytesCopied: Int(bytesCopied),
                            bytesTotal: Int(bytesTotal)
                        )
                    )
                },
                onIssue: { issue in
                    if issue.severity == .error {
                        errorCounter.increment()
                    }
                    continuation.yield(.issue(issue))
                }
            ),
            isCancelled: { Task.isCancelled }
        )

        if Task.isCancelled {
            continuation.finish()
            return
        }

        continuation.yield(
            .phaseCompleted(
                phase: .copy,
                result: RunPhaseResult(
                    copiedCount: executionResult.copiedCount,
                    failedCount: executionResult.failedCount
                )
            )
        )
        runLogger.log("Resumed session complete")
        continuation.yield(
            .complete(
                RunSummary(
                    status: .finished,
                    title: "Done",
                    metrics: RunMetrics(
                        plannedCount: pendingJobCount,
                        copiedCount: executionResult.copiedCount,
                        failedCount: executionResult.failedCount,
                        errorCount: errorCounter.value
                    ),
                    artifacts: executionResult.artifacts
                )
            )
        )
        continuation.finish()
    }

    /// Emits the summary events that follow the planner walk.
    /// `destinationIndexing` and `sourceHashing` are already streamed live by the
    /// planner via `onEvent`; this method emits the classification summary and the
    /// final `copyPlanReady` event after `plan()` returns.
    private nonisolated static func emitPostPlanningEvents(
        for result: DryRunPlanningResult,
        into continuation: AsyncThrowingStream<RunEvent, Error>.Continuation
    ) {
        // discovery summary — feeds metrics.discoveredCount in the UI
        continuation.yield(.phaseStarted(phase: .discovery, total: result.discoveredSourceCount))
        continuation.yield(.phaseCompleted(phase: .discovery, result: RunPhaseResult(found: result.discoveredSourceCount)))

        continuation.yield(.phaseStarted(phase: .classification, total: result.counts.newCount))
        continuation.yield(
            .phaseCompleted(
                phase: .classification,
                result: RunPhaseResult(
                    newCount: result.counts.newCount,
                    alreadyInDestinationCount: result.counts.alreadyInDestinationCount,
                    duplicateCount: result.counts.duplicateCount,
                    hashErrorCount: result.counts.hashErrorCount
                )
            )
        )

        for warning in result.warningMessages {
            continuation.yield(.issue(RunIssue(severity: .warning, message: warning)))
        }

        continuation.yield(.copyPlanReady(count: result.transferCount))
    }

    nonisolated private static func writeDryRunArtifacts(
        result: DryRunPlanningResult,
        destinationRoot: String
    ) throws -> RunArtifactPaths {
        let destinationURL = URL(fileURLWithPath: destinationRoot, isDirectory: true)
        let logsDirectoryURL = destinationURL.appendingPathComponent(".organize_logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)

        let timestamp = Self.timestampFormatter.string(from: Date())
        let reportURL = logsDirectoryURL.appendingPathComponent("dry_run_report_\(timestamp).csv")
        let logURL = destinationURL.appendingPathComponent(".organize_log.txt")

        try writeReport(result.transfers, to: reportURL)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            try Data().write(to: logURL)
        }

        return RunArtifactPaths(
            destinationRoot: destinationRoot,
            reportPath: reportURL.path,
            logFilePath: logURL.path,
            logsDirectoryPath: logsDirectoryURL.path
        )
    }

    nonisolated private static func writeReport(_ transfers: [PlannedTransfer], to reportURL: URL) throws {
        let temporaryReportURL = reportURL.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: temporaryReportURL.path, contents: Data())
        let handle = try FileHandle(forWritingTo: temporaryReportURL)

        do {
            try handle.write(contentsOf: Data("Source,Destination,Hash,Status\n".utf8))
            for transfer in transfers {
                let row = [
                    csvField(transfer.sourcePath),
                    csvField(transfer.destinationPath),
                    csvField(transfer.identity.rawValue),
                    csvField(CopyJobStatus.pending.rawValue),
                ]
                .joined(separator: ",") + "\n"
                try handle.write(contentsOf: Data(row.utf8))
            }
            try handle.close()

            if FileManager.default.fileExists(atPath: reportURL.path) {
                try FileManager.default.removeItem(at: reportURL)
            }
            try FileManager.default.moveItem(at: temporaryReportURL, to: reportURL)
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporaryReportURL)
            throw error
        }
    }

    nonisolated private static func csvField(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    nonisolated private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()
}

private final class IssueCounter: @unchecked Sendable {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

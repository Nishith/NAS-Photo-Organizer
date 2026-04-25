#if canImport(ChronoframeCore)
import ChronoframeCore
#endif
import Foundation

public struct DependencyStatus: Decodable, Equatable, Sendable {
    public var ok: Bool
    public var missing: [String]
}

public struct PythonEventDecoder: Sendable {
    private struct RawEvent: Decodable {
        var type: String?
        var status: String?
        var task: String?
        var completed: Int?
        var total: Int?
        var found: Int?
        var message: String?
        var count: Int?
        var already_in_dst: Int?
        var new: Int?
        var dups: Int?
        var errors: Int?
        var bytes_copied: Int?
        var bytes_total: Int?
        var dest: String?
        var report: String?
        var copied: Int?
        var failed: Int?
        var buckets: [String: Int]?
    }

    public init() {}

    public func decode(line: String, currentMetrics: RunMetrics, currentArtifacts: RunArtifactPaths) -> RunEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard
            let data = trimmed.data(using: .utf8),
            let rawEvent = try? JSONDecoder().decode(RawEvent.self, from: data)
        else {
            return .issue(issue(from: trimmed))
        }

        switch rawEvent.type {
        case "startup":
            return .startup

        case "task_start":
            guard let task = rawEvent.task, let phase = RunPhase(rawValue: task) else { return nil }
            return .phaseStarted(phase: phase, total: rawEvent.total)

        case "task_progress":
            guard
                let task = rawEvent.task,
                let phase = RunPhase(rawValue: task),
                let completed = rawEvent.completed,
                let total = rawEvent.total
            else {
                return nil
            }
            return .phaseProgress(
                phase: phase,
                completed: completed,
                total: total,
                bytesCopied: rawEvent.bytes_copied,
                bytesTotal: rawEvent.bytes_total
            )

        case "task_complete":
            guard let task = rawEvent.task, let phase = RunPhase(rawValue: task) else { return nil }
            let result = RunPhaseResult(
                found: rawEvent.found,
                newCount: rawEvent.new,
                alreadyInDestinationCount: rawEvent.already_in_dst,
                duplicateCount: rawEvent.dups,
                hashErrorCount: rawEvent.errors,
                copiedCount: rawEvent.copied,
                failedCount: rawEvent.failed
            )
            return .phaseCompleted(phase: phase, result: result)

        case "copy_plan_ready":
            return .copyPlanReady(count: rawEvent.count ?? 0)

        case "date_histogram":
            let raw = rawEvent.buckets ?? [:]
            // Sort by key so "Unknown" lands at the end and dated buckets stay
            // chronological — the view relies on this order for left-to-right fill.
            let buckets = raw
                .map { DateHistogramBucket(key: $0.key, plannedCount: $0.value) }
                .sorted { lhs, rhs in
                    if lhs.key == "Unknown" { return false }
                    if rhs.key == "Unknown" { return true }
                    return lhs.key < rhs.key
                }
            return .dateHistogram(buckets: buckets)

        case "info":
            return .issue(RunIssue(severity: .info, message: rawEvent.message ?? ""))

        case "warning":
            return .issue(RunIssue(severity: .warning, message: rawEvent.message ?? ""))

        case "error":
            return .issue(RunIssue(severity: .error, message: rawEvent.message ?? ""))

        case "prompt":
            return .prompt(message: rawEvent.message ?? "Are you sure?")

        case "complete":
            let status = RunStatus(backendStatus: rawEvent.status)
            let title: String
            switch status {
            case .finished:
                title = "Done"
            case .dryRunFinished:
                title = "Preview complete"
            case .nothingToCopy:
                title = "Already up to date"
            case .cancelled:
                title = "Cancelled"
            case .reverted:
                title = "Revert complete"
            case .revertEmpty:
                title = "Nothing to revert"
            case .reorganized:
                title = "Reorganize complete"
            case .nothingToReorganize:
                title = "Nothing to reorganize"
            case .idle, .preflighting, .running, .failed:
                title = rawEvent.status ?? "Done"
            }

            let destinationRoot = rawEvent.dest ?? currentArtifacts.destinationRoot
            let artifacts = RunArtifactPaths(
                destinationRoot: destinationRoot,
                reportPath: rawEvent.report ?? currentArtifacts.reportPath,
                logFilePath: destinationRoot.isEmpty ? currentArtifacts.logFilePath : URL(fileURLWithPath: destinationRoot).appendingPathComponent(".organize_log.txt").path,
                logsDirectoryPath: destinationRoot.isEmpty ? currentArtifacts.logsDirectoryPath : URL(fileURLWithPath: destinationRoot).appendingPathComponent(".organize_logs", isDirectory: true).path
            )

            return .complete(
                RunSummary(
                    status: status,
                    title: title,
                    metrics: currentMetrics,
                    artifacts: artifacts
                )
            )

        default:
            return nil
        }
    }

    private func issue(from line: String) -> RunIssue {
        if line.hasPrefix("ERROR:") {
            return RunIssue(severity: .error, message: String(line.dropFirst("ERROR:".count)).trimmingCharacters(in: .whitespaces))
        }
        if line.hasPrefix("⚠") || line.hasPrefix("WARNING:") {
            let message = line
                .replacingOccurrences(of: "⚠", with: "")
                .replacingOccurrences(of: "WARNING:", with: "")
                .trimmingCharacters(in: .whitespaces)
            return RunIssue(severity: .warning, message: message)
        }
        if line.hasPrefix("ℹ") {
            return RunIssue(severity: .info, message: String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
        }
        return RunIssue(severity: .info, message: line)
    }
}

@MainActor
public final class PythonOrganizerEngine: OrganizerEngine {
    private let profilesRepository: ProfilesRepository
    private let decoder: PythonEventDecoder
    private var activeProcess: Process?

    public init(
        profilesRepository: ProfilesRepository = ProfilesRepository(),
        decoder: PythonEventDecoder = PythonEventDecoder()
    ) {
        self.profilesRepository = profilesRepository
        self.decoder = decoder
    }

    public func preflight(_ configuration: RunConfiguration) async throws -> RunPreflight {
        guard let backendScriptURL = RuntimePaths.backendScriptURL() else {
            throw OrganizerEngineError.backendUnavailable
        }

        let profiles = try profilesRepository.loadProfiles()
        let resolvedConfiguration = try resolveConfiguration(configuration, profiles: profiles)

        guard FileManager.default.fileExists(atPath: resolvedConfiguration.sourcePath) else {
            throw OrganizerEngineError.sourceDoesNotExist(resolvedConfiguration.sourcePath)
        }

        guard !resolvedConfiguration.destinationPath.isEmpty else {
            throw OrganizerEngineError.destinationMissing
        }

        let dependencyStatus = try await dependencyStatus(backendScriptURL: backendScriptURL)
        let pendingJobs = pendingJobCount(destinationRoot: resolvedConfiguration.destinationPath)

        return RunPreflight(
            configuration: resolvedConfiguration,
            resolvedSourcePath: resolvedConfiguration.sourcePath,
            resolvedDestinationPath: resolvedConfiguration.destinationPath,
            pendingJobCount: pendingJobs,
            profilesFilePath: profilesRepository.profilesFileURL().path,
            missingDependencies: dependencyStatus.missing
        )
    }

    public func start(_ configuration: RunConfiguration) throws -> AsyncThrowingStream<RunEvent, Error> {
        try makeStream(configuration: configuration)
    }

    public func resume(_ configuration: RunConfiguration) throws -> AsyncThrowingStream<RunEvent, Error> {
        try makeStream(configuration: configuration)
    }

    public func cancelCurrentRun() {
        activeProcess?.terminate()
        activeProcess = nil
    }

    private func resolveConfiguration(_ configuration: RunConfiguration, profiles: [Profile]) throws -> RunConfiguration {
        if let profileName = configuration.profileName, !profileName.isEmpty {
            guard let profile = profiles.first(where: { $0.name == profileName }) else {
                throw OrganizerEngineError.profileNotFound(profileName)
            }

            return configuration.resolving(profile: profile)
        }

        return configuration
    }

    private func dependencyStatus(backendScriptURL: URL) async throws -> DependencyStatus {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", backendScriptURL.path, "--check-deps-json"]
        process.standardOutput = output
        process.standardError = output
        process.environment = backendEnvironment()

        try process.run()
        process.waitUntilExit()
        let data = try output.fileHandleForReading.readToEnd() ?? Data()

        guard let status = try? JSONDecoder().decode(DependencyStatus.self, from: data) else {
            throw OrganizerEngineError.pythonUnavailable
        }

        return status
    }

    private func makeStream(configuration: RunConfiguration) throws -> AsyncThrowingStream<RunEvent, Error> {
        guard let backendScriptURL = RuntimePaths.backendScriptURL() else {
            throw OrganizerEngineError.backendUnavailable
        }

        let process = Process()
        let output = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = pythonArguments(scriptURL: backendScriptURL, configuration: configuration)
        process.environment = backendEnvironment()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
        } catch {
            throw OrganizerEngineError.failedToLaunch(error.localizedDescription)
        }

        activeProcess = process

        let outputHandle = output.fileHandleForReading

        return AsyncThrowingStream { continuation in
            let readerTask = Task { @MainActor in
                var metrics = RunMetrics()
                var artifacts = RunArtifactPaths(destinationRoot: configuration.destinationPath)

                do {
                    for try await line in outputHandle.bytes.lines {
                        guard let event = decoder.decode(line: line, currentMetrics: metrics, currentArtifacts: artifacts) else {
                            continue
                        }

                        switch event {
                        case let .phaseCompleted(phase, result):
                            switch phase {
                            case .discovery:
                                metrics.discoveredCount = result.found ?? metrics.discoveredCount
                            case .classification:
                                metrics.alreadyInDestinationCount = result.alreadyInDestinationCount ?? metrics.alreadyInDestinationCount
                                metrics.duplicateCount = result.duplicateCount ?? metrics.duplicateCount
                                metrics.hashErrorCount = result.hashErrorCount ?? metrics.hashErrorCount
                            case .copy:
                                metrics.copiedCount = result.copiedCount ?? metrics.copiedCount
                                metrics.failedCount = result.failedCount ?? metrics.failedCount
                            case .sourceHashing, .destinationIndexing:
                                break
                            case .revert:
                                metrics.revertedCount = result.revertedCount ?? metrics.revertedCount
                                metrics.skippedCount = result.skippedCount ?? metrics.skippedCount
                                metrics.missingCount = result.missingCount ?? metrics.missingCount
                            case .reorganize:
                                metrics.movedCount = result.movedCount ?? metrics.movedCount
                                metrics.skippedCount = result.skippedCount ?? metrics.skippedCount
                                metrics.failedCount = result.failedCount ?? metrics.failedCount
                            }
                        case let .copyPlanReady(count):
                            metrics.plannedCount = count
                        case let .dateHistogram(buckets):
                            metrics.dateHistogram = buckets
                        case let .issue(issue):
                            if issue.severity == .error {
                                metrics.errorCount += 1
                            }
                        case let .complete(summary):
                            metrics = summary.metrics
                            artifacts = summary.artifacts
                        case .startup, .phaseStarted, .phaseProgress, .prompt:
                            break
                        }

                        continuation.yield(event)
                    }

                    process.waitUntilExit()
                    if process.terminationStatus != 0 && !Task.isCancelled {
                        continuation.finish(throwing: OrganizerEngineError.failedToLaunch("The helper exited with status \(process.terminationStatus)."))
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }

                self.activeProcess = nil
            }

            continuation.onTermination = { @Sendable _ in
                readerTask.cancel()
                if process.isRunning {
                    process.terminate()
                }
                Task { @MainActor in
                    self.activeProcess = nil
                }
            }
        }
    }

    private func pythonArguments(scriptURL: URL, configuration: RunConfiguration) -> [String] {
        var arguments = [
            "python3",
            scriptURL.path,
            "--json",
            "--yes",
            "--workers",
            "\(max(1, configuration.workerCount))",
        ]

        if configuration.mode == .preview {
            arguments.append("--dry-run")
        }

        if configuration.useFastDestinationScan {
            arguments.append("--fast-dest")
        }

        if configuration.verifyCopies {
            arguments.append("--verify")
        }

        arguments.append(contentsOf: ["--folder-structure", configuration.folderStructure.rawValue])

        if let profileName = configuration.profileName, !profileName.isEmpty {
            arguments.append(contentsOf: ["--profile", profileName])
        } else {
            arguments.append(contentsOf: ["--source", configuration.sourcePath, "--dest", configuration.destinationPath])
        }

        return arguments
    }

    private func backendEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CHRONOFRAME_NONINTERACTIVE"] = "1"
        environment["CHRONOFRAME_PROFILES_PATH"] = profilesRepository.profilesFileURL().path

        if let backendRoot = RuntimePaths.backendRootURL() {
            environment["PYTHONPATH"] = [backendRoot.path, environment["PYTHONPATH"]].compactMap { $0 }.joined(separator: ":")
        }

        return environment
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
}

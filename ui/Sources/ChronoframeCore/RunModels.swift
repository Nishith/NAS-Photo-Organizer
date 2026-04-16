import Foundation

public enum RunMode: String, Codable, Sendable {
    case preview
    case transfer

    public var title: String {
        switch self {
        case .preview:
            return "Preview"
        case .transfer:
            return "Transfer"
        }
    }
}

public enum RunPhase: String, CaseIterable, Codable, Sendable {
    case discovery = "discovery"
    case sourceHashing = "src_hash"
    case destinationIndexing = "dest_hash"
    case classification = "classification"
    case copy = "copy"

    public var title: String {
        switch self {
        case .discovery:
            return "Discover"
        case .sourceHashing:
            return "Hash Source"
        case .destinationIndexing:
            return "Index Destination"
        case .classification:
            return "Classify"
        case .copy:
            return "Transfer"
        }
    }

    public var runningTitle: String {
        switch self {
        case .discovery:
            return "Discovering files..."
        case .sourceHashing:
            return "Hashing source..."
        case .destinationIndexing:
            return "Indexing destination..."
        case .classification:
            return "Classifying by date..."
        case .copy:
            return "Copying files..."
        }
    }
}

public enum RunStatus: String, Codable, Sendable {
    case idle
    case preflighting
    case running
    case dryRunFinished
    case finished
    case nothingToCopy
    case cancelled
    case failed

    public init(backendStatus: String?) {
        switch backendStatus {
        case "dry_run_finished":
            self = .dryRunFinished
        case "finished":
            self = .finished
        case "nothing_to_copy":
            self = .nothingToCopy
        case "cancelled":
            self = .cancelled
        case "running":
            self = .running
        case "preflighting":
            self = .preflighting
        case "idle", nil:
            self = .idle
        default:
            self = .failed
        }
    }
}

public enum RunSeverity: String, Codable, Sendable {
    case info
    case warning
    case error

    public var prefix: String {
        switch self {
        case .info:
            return "INFO"
        case .warning:
            return "WARNING"
        case .error:
            return "ERROR"
        }
    }
}

public struct RunIssue: Identifiable, Sendable {
    public let id: UUID
    public let severity: RunSeverity
    public let message: String

    public init(id: UUID = UUID(), severity: RunSeverity, message: String) {
        self.id = id
        self.severity = severity
        self.message = message
    }

    public var renderedLine: String {
        switch severity {
        case .info:
            return "ℹ \(message)"
        case .warning:
            return "⚠ \(message)"
        case .error:
            return "ERROR: \(message)"
        }
    }
}

public struct RunMetrics: Equatable, Codable, Sendable {
    public var discoveredCount: Int
    public var plannedCount: Int
    public var alreadyInDestinationCount: Int
    public var duplicateCount: Int
    public var hashErrorCount: Int
    public var copiedCount: Int
    public var failedCount: Int
    public var errorCount: Int
    public var speedMBps: Double
    public var etaSeconds: Double?

    public init(
        discoveredCount: Int = 0,
        plannedCount: Int = 0,
        alreadyInDestinationCount: Int = 0,
        duplicateCount: Int = 0,
        hashErrorCount: Int = 0,
        copiedCount: Int = 0,
        failedCount: Int = 0,
        errorCount: Int = 0,
        speedMBps: Double = 0,
        etaSeconds: Double? = nil
    ) {
        self.discoveredCount = discoveredCount
        self.plannedCount = plannedCount
        self.alreadyInDestinationCount = alreadyInDestinationCount
        self.duplicateCount = duplicateCount
        self.hashErrorCount = hashErrorCount
        self.copiedCount = copiedCount
        self.failedCount = failedCount
        self.errorCount = errorCount
        self.speedMBps = speedMBps
        self.etaSeconds = etaSeconds
    }
}

public struct RunArtifactPaths: Equatable, Codable, Sendable {
    public var destinationRoot: String
    public var reportPath: String?
    public var logFilePath: String?
    public var logsDirectoryPath: String?

    public init(
        destinationRoot: String = "",
        reportPath: String? = nil,
        logFilePath: String? = nil,
        logsDirectoryPath: String? = nil
    ) {
        self.destinationRoot = destinationRoot
        self.reportPath = reportPath
        self.logFilePath = logFilePath
        self.logsDirectoryPath = logsDirectoryPath
    }
}

public struct RunConfiguration: Equatable, Codable, Sendable {
    public var mode: RunMode
    public var sourcePath: String
    public var destinationPath: String
    public var profileName: String?
    public var useFastDestinationScan: Bool
    public var verifyCopies: Bool
    public var workerCount: Int

    public init(
        mode: RunMode,
        sourcePath: String = "",
        destinationPath: String = "",
        profileName: String? = nil,
        useFastDestinationScan: Bool = false,
        verifyCopies: Bool = false,
        workerCount: Int = 8
    ) {
        self.mode = mode
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.profileName = profileName
        self.useFastDestinationScan = useFastDestinationScan
        self.verifyCopies = verifyCopies
        self.workerCount = workerCount
    }
}

public struct RunPreflight: Equatable, Codable, Sendable {
    public var configuration: RunConfiguration
    public var resolvedSourcePath: String
    public var resolvedDestinationPath: String
    public var pendingJobCount: Int
    public var profilesFilePath: String?
    public var missingDependencies: [String]

    public init(
        configuration: RunConfiguration,
        resolvedSourcePath: String,
        resolvedDestinationPath: String,
        pendingJobCount: Int = 0,
        profilesFilePath: String? = nil,
        missingDependencies: [String] = []
    ) {
        self.configuration = configuration
        self.resolvedSourcePath = resolvedSourcePath
        self.resolvedDestinationPath = resolvedDestinationPath
        self.pendingJobCount = pendingJobCount
        self.profilesFilePath = profilesFilePath
        self.missingDependencies = missingDependencies
    }
}

public struct RunPhaseResult: Equatable, Codable, Sendable {
    public var found: Int?
    public var newCount: Int?
    public var alreadyInDestinationCount: Int?
    public var duplicateCount: Int?
    public var hashErrorCount: Int?
    public var copiedCount: Int?
    public var failedCount: Int?

    public init(
        found: Int? = nil,
        newCount: Int? = nil,
        alreadyInDestinationCount: Int? = nil,
        duplicateCount: Int? = nil,
        hashErrorCount: Int? = nil,
        copiedCount: Int? = nil,
        failedCount: Int? = nil
    ) {
        self.found = found
        self.newCount = newCount
        self.alreadyInDestinationCount = alreadyInDestinationCount
        self.duplicateCount = duplicateCount
        self.hashErrorCount = hashErrorCount
        self.copiedCount = copiedCount
        self.failedCount = failedCount
    }
}

public struct RunSummary: Equatable, Codable, Sendable {
    public var status: RunStatus
    public var title: String
    public var metrics: RunMetrics
    public var artifacts: RunArtifactPaths

    public init(
        status: RunStatus,
        title: String,
        metrics: RunMetrics,
        artifacts: RunArtifactPaths
    ) {
        self.status = status
        self.title = title
        self.metrics = metrics
        self.artifacts = artifacts
    }
}

public enum RunEvent: Sendable {
    case startup
    case phaseStarted(phase: RunPhase, total: Int?)
    case phaseProgress(phase: RunPhase, completed: Int, total: Int, bytesCopied: Int?, bytesTotal: Int?)
    case phaseCompleted(phase: RunPhase, result: RunPhaseResult)
    case copyPlanReady(count: Int)
    case issue(RunIssue)
    case prompt(message: String)
    case complete(RunSummary)
}

public enum RunPromptKind: String, Sendable {
    case confirmTransfer
    case resumePendingJobs
    case blockingError
}

public struct RunPrompt: Identifiable, Sendable {
    public let id: UUID
    public let kind: RunPromptKind
    public let title: String
    public let message: String
    public let preflight: RunPreflight?

    public init(
        id: UUID = UUID(),
        kind: RunPromptKind,
        title: String,
        message: String,
        preflight: RunPreflight? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.message = message
        self.preflight = preflight
    }
}

import Foundation

public enum RunMode: String, Codable, Sendable {
    case preview
    case transfer
    case revert
    case reorganize

    public var title: String {
        switch self {
        case .preview:
            return "Preview"
        case .transfer:
            return "Transfer"
        case .revert:
            return "Revert"
        case .reorganize:
            return "Reorganize"
        }
    }
}

public enum RunPhase: String, CaseIterable, Codable, Sendable {
    case discovery = "discovery"
    case sourceHashing = "src_hash"
    case destinationIndexing = "dest_hash"
    case classification = "classification"
    case copy = "copy"
    case revert = "revert"
    case reorganize = "reorganize"

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
        case .revert:
            return "Revert"
        case .reorganize:
            return "Reorganize"
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
        case .revert:
            return "Reverting files..."
        case .reorganize:
            return "Reorganizing files..."
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
    case reverted
    case revertEmpty
    case reorganized
    case nothingToReorganize

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
        case "reverted":
            self = .reverted
        case "revert_empty":
            self = .revertEmpty
        case "reorganized":
            self = .reorganized
        case "nothing_to_reorganize":
            self = .nothingToReorganize
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

/// One bucket in the source-date histogram. `key` is `"YYYY-MM"` for dated
/// files or `"Unknown"` for files whose date could not be extracted.
public struct DateHistogramBucket: Equatable, Codable, Sendable, Identifiable {
    public var key: String
    public var plannedCount: Int

    public var id: String { key }

    public init(key: String, plannedCount: Int) {
        self.key = key
        self.plannedCount = plannedCount
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
    public var bytesCopied: Int64
    public var bytesTotal: Int64
    public var speedMBps: Double
    public var etaSeconds: Double?
    public var revertedCount: Int
    public var skippedCount: Int
    public var missingCount: Int
    public var movedCount: Int
    public var dateHistogram: [DateHistogramBucket]

    public init(
        discoveredCount: Int = 0,
        plannedCount: Int = 0,
        alreadyInDestinationCount: Int = 0,
        duplicateCount: Int = 0,
        hashErrorCount: Int = 0,
        copiedCount: Int = 0,
        failedCount: Int = 0,
        errorCount: Int = 0,
        bytesCopied: Int64 = 0,
        bytesTotal: Int64 = 0,
        speedMBps: Double = 0,
        etaSeconds: Double? = nil,
        revertedCount: Int = 0,
        skippedCount: Int = 0,
        missingCount: Int = 0,
        movedCount: Int = 0,
        dateHistogram: [DateHistogramBucket] = []
    ) {
        self.discoveredCount = discoveredCount
        self.plannedCount = plannedCount
        self.alreadyInDestinationCount = alreadyInDestinationCount
        self.duplicateCount = duplicateCount
        self.hashErrorCount = hashErrorCount
        self.copiedCount = copiedCount
        self.failedCount = failedCount
        self.errorCount = errorCount
        self.bytesCopied = bytesCopied
        self.bytesTotal = bytesTotal
        self.speedMBps = speedMBps
        self.etaSeconds = etaSeconds
        self.revertedCount = revertedCount
        self.skippedCount = skippedCount
        self.missingCount = missingCount
        self.movedCount = movedCount
        self.dateHistogram = dateHistogram
    }

    private enum CodingKeys: String, CodingKey {
        case discoveredCount, plannedCount, alreadyInDestinationCount, duplicateCount,
             hashErrorCount, copiedCount, failedCount, errorCount, bytesCopied, bytesTotal,
             speedMBps, etaSeconds,
             revertedCount, skippedCount, missingCount, movedCount,
             dateHistogram
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.discoveredCount = try c.decodeIfPresent(Int.self, forKey: .discoveredCount) ?? 0
        self.plannedCount = try c.decodeIfPresent(Int.self, forKey: .plannedCount) ?? 0
        self.alreadyInDestinationCount = try c.decodeIfPresent(Int.self, forKey: .alreadyInDestinationCount) ?? 0
        self.duplicateCount = try c.decodeIfPresent(Int.self, forKey: .duplicateCount) ?? 0
        self.hashErrorCount = try c.decodeIfPresent(Int.self, forKey: .hashErrorCount) ?? 0
        self.copiedCount = try c.decodeIfPresent(Int.self, forKey: .copiedCount) ?? 0
        self.failedCount = try c.decodeIfPresent(Int.self, forKey: .failedCount) ?? 0
        self.errorCount = try c.decodeIfPresent(Int.self, forKey: .errorCount) ?? 0
        self.bytesCopied = try c.decodeIfPresent(Int64.self, forKey: .bytesCopied) ?? 0
        self.bytesTotal = try c.decodeIfPresent(Int64.self, forKey: .bytesTotal) ?? 0
        self.speedMBps = try c.decodeIfPresent(Double.self, forKey: .speedMBps) ?? 0
        self.etaSeconds = try c.decodeIfPresent(Double.self, forKey: .etaSeconds)
        self.revertedCount = try c.decodeIfPresent(Int.self, forKey: .revertedCount) ?? 0
        self.skippedCount = try c.decodeIfPresent(Int.self, forKey: .skippedCount) ?? 0
        self.missingCount = try c.decodeIfPresent(Int.self, forKey: .missingCount) ?? 0
        self.movedCount = try c.decodeIfPresent(Int.self, forKey: .movedCount) ?? 0
        self.dateHistogram = try c.decodeIfPresent([DateHistogramBucket].self, forKey: .dateHistogram) ?? []
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
    public var folderStructure: FolderStructure

    public init(
        mode: RunMode,
        sourcePath: String = "",
        destinationPath: String = "",
        profileName: String? = nil,
        useFastDestinationScan: Bool = false,
        verifyCopies: Bool = false,
        workerCount: Int = 8,
        folderStructure: FolderStructure = .yyyyMMDD
    ) {
        self.mode = mode
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.profileName = profileName
        self.useFastDestinationScan = useFastDestinationScan
        self.verifyCopies = verifyCopies
        self.workerCount = workerCount
        self.folderStructure = folderStructure
    }

    private enum CodingKeys: String, CodingKey {
        case mode, sourcePath, destinationPath, profileName, useFastDestinationScan, verifyCopies, workerCount, folderStructure
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try container.decode(RunMode.self, forKey: .mode)
        self.sourcePath = try container.decodeIfPresent(String.self, forKey: .sourcePath) ?? ""
        self.destinationPath = try container.decodeIfPresent(String.self, forKey: .destinationPath) ?? ""
        self.profileName = try container.decodeIfPresent(String.self, forKey: .profileName)
        self.useFastDestinationScan = try container.decodeIfPresent(Bool.self, forKey: .useFastDestinationScan) ?? false
        self.verifyCopies = try container.decodeIfPresent(Bool.self, forKey: .verifyCopies) ?? false
        self.workerCount = try container.decodeIfPresent(Int.self, forKey: .workerCount) ?? 8
        self.folderStructure = try container.decodeIfPresent(FolderStructure.self, forKey: .folderStructure) ?? .yyyyMMDD
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
    public var revertedCount: Int?
    public var skippedCount: Int?
    public var missingCount: Int?
    public var movedCount: Int?

    public init(
        found: Int? = nil,
        newCount: Int? = nil,
        alreadyInDestinationCount: Int? = nil,
        duplicateCount: Int? = nil,
        hashErrorCount: Int? = nil,
        copiedCount: Int? = nil,
        failedCount: Int? = nil,
        revertedCount: Int? = nil,
        skippedCount: Int? = nil,
        missingCount: Int? = nil,
        movedCount: Int? = nil
    ) {
        self.found = found
        self.newCount = newCount
        self.alreadyInDestinationCount = alreadyInDestinationCount
        self.duplicateCount = duplicateCount
        self.hashErrorCount = hashErrorCount
        self.copiedCount = copiedCount
        self.failedCount = failedCount
        self.revertedCount = revertedCount
        self.skippedCount = skippedCount
        self.missingCount = missingCount
        self.movedCount = movedCount
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
    case dateHistogram(buckets: [DateHistogramBucket])
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

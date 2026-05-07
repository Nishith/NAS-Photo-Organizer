import Foundation

// MARK: - Settings presets

/// Three named tradeoffs between scan strictness and recall. The settings UI
/// exposes these as a segmented control instead of two raw numeric sliders.
public enum DedupeSimilarityPreset: String, CaseIterable, Sendable, Codable, Identifiable {
    case strict
    case balanced
    case loose

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .strict: return "Strict"
        case .balanced: return "Balanced"
        case .loose: return "Loose"
        }
    }

    public var subtitle: String {
        switch self {
        case .strict: return "Fewer groups, only very close matches"
        case .balanced: return "Recommended for most libraries"
        case .loose: return "More groups, including looser matches"
        }
    }

    public var similarityThreshold: Double {
        switch self {
        case .strict: return 0.20
        case .balanced: return 0.35
        case .loose: return 0.55
        }
    }

    public var dhashHammingThreshold: Int {
        switch self {
        case .strict: return 6
        case .balanced: return 10
        case .loose: return 16
        }
    }
}

// MARK: - Configuration

// MARK: - Cross-folder source (Feature 5)

public struct CrossFolderSource: Sendable, Equatable, Identifiable, Codable {
    public var id: String { path }
    public var path: String
    /// Lower number = higher priority. Files in higher-priority folders are
    /// preferred as keepers when quality is otherwise equal.
    public var priority: Int
    public var label: String?

    public init(path: String, priority: Int = 0, label: String? = nil) {
        self.path = path
        self.priority = priority
        self.label = label
    }
}

/// Settings that drive a single dedupe scan + commit cycle.
public struct DeduplicateConfiguration: Equatable, Sendable {
    public var destinationPath: String
    /// Photos must be taken within this many seconds of each other to be
    /// considered for the same near-duplicate cluster. Only consulted when
    /// `burstModeEnabled` is true.
    public var timeWindowSeconds: Int
    /// When true, only candidates within `timeWindowSeconds` of each other
    /// are compared (today's behavior — fast, focused on burst sequences).
    /// When false, every candidate in the destination is compared against
    /// every other candidate, ignoring capture-date proximity.
    public var burstModeEnabled: Bool
    /// Vision feature-print distance threshold. Lower = stricter (more similar
    /// required to cluster). VNFeaturePrintObservation distances are
    /// unbounded but typically fall in 0.0–2.0 for natural photos.
    public var similarityThreshold: Double
    /// Pre-filter: dHash Hamming distance. Pairs whose dHash differs by more
    /// than this are rejected before paying for the Vision distance check.
    public var dhashHammingThreshold: Int
    public var treatRawJpegPairsAsUnit: Bool
    public var treatLivePhotoPairsAsUnit: Bool
    public var enableExactDuplicateGroup: Bool
    public var workerCount: Int

    // MARK: Feature flags (Phase 2+)

    /// Automatically accept high-confidence clusters without manual review.
    public var autoAcceptHighConfidence: Bool
    /// Run edit-variant detection on near-duplicate clusters to distinguish
    /// intentional edits (crops, exposure adjustments) from true duplicates.
    public var detectEditVariants: Bool
    /// Additional folders to scan alongside the destination (cross-folder
    /// dedup). Empty by default for single-folder behavior.
    public var additionalSources: [CrossFolderSource]

    public init(
        destinationPath: String,
        timeWindowSeconds: Int = 30,
        burstModeEnabled: Bool = true,
        similarityThreshold: Double = 0.35,
        dhashHammingThreshold: Int = 10,
        treatRawJpegPairsAsUnit: Bool = true,
        treatLivePhotoPairsAsUnit: Bool = true,
        enableExactDuplicateGroup: Bool = true,
        workerCount: Int = 4,
        autoAcceptHighConfidence: Bool = false,
        detectEditVariants: Bool = true,
        additionalSources: [CrossFolderSource] = []
    ) {
        self.destinationPath = destinationPath
        self.timeWindowSeconds = timeWindowSeconds
        self.burstModeEnabled = burstModeEnabled
        self.similarityThreshold = similarityThreshold
        self.dhashHammingThreshold = dhashHammingThreshold
        self.treatRawJpegPairsAsUnit = treatRawJpegPairsAsUnit
        self.treatLivePhotoPairsAsUnit = treatLivePhotoPairsAsUnit
        self.enableExactDuplicateGroup = enableExactDuplicateGroup
        self.workerCount = workerCount
        self.autoAcceptHighConfidence = autoAcceptHighConfidence
        self.detectEditVariants = detectEditVariants
        self.additionalSources = additionalSources
    }
}

// MARK: - Phases

public enum DeduplicatePhase: String, CaseIterable, Sendable {
    case discovery
    case identityHashing
    case featureExtraction
    case clustering

    public var title: String {
        switch self {
        case .discovery: return "Discovering files"
        case .identityHashing: return "Hashing for exact duplicates"
        case .featureExtraction: return "Analyzing photo similarity"
        case .clustering: return "Grouping similar shots"
        }
    }
}

public enum ClusterKind: String, Sendable, Codable {
    /// Byte-identical files (matched via the existing BLAKE2b file identity).
    case exactDuplicate
    /// Visually similar shots that span more than ~10s — same scene, different
    /// composition or lighting.
    case nearDuplicate
    /// Visually similar shots taken within ~10s of each other — likely a
    /// burst sequence.
    case burst
    /// Photos that are intentional edits of each other (crops, exposure
    /// adjustments, filters) rather than accidental duplicates.
    case editedVariant

    public var title: String {
        switch self {
        case .exactDuplicate: return "Exact duplicates"
        case .nearDuplicate: return "Near duplicates"
        case .burst: return "Bursts"
        case .editedVariant: return "Edited variants"
        }
    }
}

// MARK: - Photo candidates

/// Per-file analysis output produced by the scanner. Drives both clustering
/// and the keeper-quality scoring shown in the review UI.
public struct PhotoCandidate: Sendable, Identifiable, Equatable {
    public var id: String { path }
    public var path: String
    public var size: Int64
    public var modificationTime: TimeInterval
    public var captureDate: Date?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var dhash: UInt64?
    /// Opaque NSSecureCoding-archived `VNFeaturePrintObservation`. Stored as
    /// raw bytes so the cache layer doesn't drag Vision into ChronoframeCore.
    public var featurePrintData: Data?
    public var qualityScore: Double
    public var sharpness: Double
    public var faceScore: Double?
    public var isRaw: Bool
    public var isLivePhotoStill: Bool
    /// Path of the partner file in a RAW+JPEG or Live Photo pair, if any.
    /// The pair member is always carried alongside this candidate when
    /// keep/delete decisions are committed.
    public var pairedPath: String?

    // MARK: Expression analysis (Phase 1 — Feature 2)

    /// Confidence that all detected faces have open eyes (0-1).
    public var eyesOpenScore: Double?
    /// Confidence that detected faces are smiling (0-1).
    public var smileScore: Double?
    /// Laplacian sharpness within the face bounding box (subject-focused).
    public var subjectSharpness: Double?
    /// Motion blur on the subject (0=sharp, 1=heavy blur).
    public var subjectMotionBlur: Double?

    // MARK: Cross-folder (Phase 3 — Feature 5)

    /// Root folder this candidate was discovered in, for cross-folder dedup.
    public var folderRoot: String?

    public init(
        path: String,
        size: Int64,
        modificationTime: TimeInterval,
        captureDate: Date? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        dhash: UInt64? = nil,
        featurePrintData: Data? = nil,
        qualityScore: Double = 0,
        sharpness: Double = 0,
        faceScore: Double? = nil,
        isRaw: Bool = false,
        isLivePhotoStill: Bool = false,
        pairedPath: String? = nil,
        eyesOpenScore: Double? = nil,
        smileScore: Double? = nil,
        subjectSharpness: Double? = nil,
        subjectMotionBlur: Double? = nil,
        folderRoot: String? = nil
    ) {
        self.path = path
        self.size = size
        self.modificationTime = modificationTime
        self.captureDate = captureDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.dhash = dhash
        self.featurePrintData = featurePrintData
        self.qualityScore = qualityScore
        self.sharpness = sharpness
        self.faceScore = faceScore
        self.isRaw = isRaw
        self.isLivePhotoStill = isLivePhotoStill
        self.pairedPath = pairedPath
        self.eyesOpenScore = eyesOpenScore
        self.smileScore = smileScore
        self.subjectSharpness = subjectSharpness
        self.subjectMotionBlur = subjectMotionBlur
        self.folderRoot = folderRoot
    }
}

// MARK: - Clusters

public struct DuplicateCluster: Sendable, Identifiable, Equatable {
    public var id: UUID
    public var kind: ClusterKind
    public var members: [PhotoCandidate]
    /// Subset of `members.id` — currently at most one primary suggested
    /// keeper. UI pre-selects it as Keep and pre-marks the rest as Delete,
    /// with pair-as-unit safety applied later by the planner/session store.
    public var suggestedKeeperIDs: [String]
    /// Bytes that would be reclaimed if the user accepts the suggestion
    /// (sum of non-keeper sizes including paired partners).
    public var bytesIfPruned: Int64
    /// Confidence, match reasoning, keeper reasoning, and safety warnings.
    /// `nil` for clusters produced by older scan sessions (backwards-compat).
    public var annotation: ClusterAnnotation?

    public init(
        id: UUID = UUID(),
        kind: ClusterKind,
        members: [PhotoCandidate],
        suggestedKeeperIDs: [String],
        bytesIfPruned: Int64,
        annotation: ClusterAnnotation? = nil
    ) {
        self.id = id
        self.kind = kind
        self.members = members
        self.suggestedKeeperIDs = suggestedKeeperIDs
        self.bytesIfPruned = bytesIfPruned
        self.annotation = annotation
    }
}

// MARK: - Events

public enum DeduplicateEvent: Sendable {
    case startup
    case phaseStarted(phase: DeduplicatePhase, total: Int?)
    case phaseProgress(phase: DeduplicatePhase, completed: Int, total: Int)
    case phaseCompleted(phase: DeduplicatePhase)
    case clusterDiscovered(DuplicateCluster)
    case issue(DeduplicateIssue)
    case complete(DeduplicateSummary)
}

public struct DeduplicateIssue: Sendable, Equatable {
    public enum Severity: String, Sendable, Equatable {
        case info
        case warning
        case error
    }

    public var severity: Severity
    public var path: String?
    public var message: String

    public init(severity: Severity, path: String? = nil, message: String) {
        self.severity = severity
        self.path = path
        self.message = message
    }
}

public struct DeduplicateSummary: Sendable, Equatable {
    public var clusterCounts: [ClusterKind: Int]
    public var totalRecoverableBytes: Int64
    public var totalCandidatesScanned: Int
    public var scanDuration: TimeInterval

    public init(
        clusterCounts: [ClusterKind: Int] = [:],
        totalRecoverableBytes: Int64 = 0,
        totalCandidatesScanned: Int = 0,
        scanDuration: TimeInterval = 0
    ) {
        self.clusterCounts = clusterCounts
        self.totalRecoverableBytes = totalRecoverableBytes
        self.totalCandidatesScanned = totalCandidatesScanned
        self.scanDuration = scanDuration
    }
}

// MARK: - Decisions and commit

public enum DedupeDecision: String, Sendable, Codable {
    case keep
    case delete
}

/// User-supplied keep/delete map handed to the executor at commit time.
public struct DedupeDecisions: Sendable, Equatable {
    public var byPath: [String: DedupeDecision]
    /// Whether to bypass the Trash and unlink directly. Default `false`. The
    /// UI gates this behind an explicit Settings toggle + confirm dialog.
    public var hardDelete: Bool

    public init(byPath: [String: DedupeDecision] = [:], hardDelete: Bool = false) {
        self.byPath = byPath
        self.hardDelete = hardDelete
    }

    public func decision(for path: String) -> DedupeDecision? {
        byPath[path]
    }
}

public enum DeduplicateCommitEvent: Sendable {
    case started(totalToDelete: Int)
    case itemTrashed(originalPath: String, trashURL: URL?, sizeBytes: Int64)
    case itemFailed(originalPath: String, errorMessage: String)
    case complete(DeduplicateCommitSummary)
}

public struct DeduplicateCommitSummary: Sendable, Equatable {
    public var deletedCount: Int
    public var failedCount: Int
    public var bytesReclaimed: Int64
    public var receiptPath: String?
    public var hardDelete: Bool

    public init(
        deletedCount: Int,
        failedCount: Int,
        bytesReclaimed: Int64,
        receiptPath: String?,
        hardDelete: Bool
    ) {
        self.deletedCount = deletedCount
        self.failedCount = failedCount
        self.bytesReclaimed = bytesReclaimed
        self.receiptPath = receiptPath
        self.hardDelete = hardDelete
    }
}

// MARK: - Deletion plan

/// Explicit, fully-resolved description of every filesystem mutation the
/// executor will perform. Built once by `DeduplicationPlanner.plan` and
/// consumed by both the commit footer (so previewed counts/bytes match
/// reality) and the executor (so the audit receipt records every mutation
/// — including paired partners that aren't cluster members on their own,
/// like Live Photo MOV halves).
public struct DeduplicationPlan: Sendable, Equatable {
    public enum PairOrigin: String, Sendable, Codable, Equatable {
        case rawJpeg
        case livePhoto
    }

    public struct Item: Sendable, Equatable {
        public let path: String
        public let sizeBytes: Int64
        public let owningClusterID: UUID
        public let owningClusterKind: ClusterKind
        /// `nil` for direct cluster-member deletions; otherwise the kind of
        /// pair-as-unit expansion that pulled this path into the plan.
        public let pairOrigin: PairOrigin?

        public init(
            path: String,
            sizeBytes: Int64,
            owningClusterID: UUID,
            owningClusterKind: ClusterKind,
            pairOrigin: PairOrigin? = nil
        ) {
            self.path = path
            self.sizeBytes = sizeBytes
            self.owningClusterID = owningClusterID
            self.owningClusterKind = owningClusterKind
            self.pairOrigin = pairOrigin
        }
    }

    public let items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    public var pathsToDelete: [String] { items.map(\.path) }
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }
    public var count: Int { items.count }
}

// MARK: - Audit receipt (revertible)

public struct DeduplicateAuditReceipt: Codable, Sendable, Equatable {
    public enum Method: String, Codable, Sendable, Equatable {
        case trash
        case hardDelete
    }

    public struct Item: Codable, Sendable, Equatable {
        public var originalPath: String
        public var sizeBytes: Int64
        public var trashURL: String?
        public var method: Method
        public var clusterID: UUID
        public var clusterKind: ClusterKind

        public init(
            originalPath: String,
            sizeBytes: Int64,
            trashURL: String?,
            method: Method,
            clusterID: UUID,
            clusterKind: ClusterKind
        ) {
            self.originalPath = originalPath
            self.sizeBytes = sizeBytes
            self.trashURL = trashURL
            self.method = method
            self.clusterID = clusterID
            self.clusterKind = clusterKind
        }
    }

    public var kind: String
    public var createdAt: Date
    public var destinationRoot: String
    public var items: [Item]
    public var bytesReclaimed: Int64

    public init(
        createdAt: Date,
        destinationRoot: String,
        items: [Item],
        bytesReclaimed: Int64
    ) {
        self.kind = "dedupe"
        self.createdAt = createdAt
        self.destinationRoot = destinationRoot
        self.items = items
        self.bytesReclaimed = bytesReclaimed
    }
}

import Foundation

// MARK: - Confidence

public enum ConfidenceLevel: String, Sendable, Codable, CaseIterable {
    case high
    case medium
    case low

    public var title: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }
}

// MARK: - Match reason

public struct MatchReason: Sendable, Equatable {
    public var timeDeltaSeconds: TimeInterval?
    public var averageVisionDistance: Double?
    public var minVisionDistance: Double?
    public var averageDhashDistance: Int?
    public var kind: ClusterKind

    public init(
        timeDeltaSeconds: TimeInterval? = nil,
        averageVisionDistance: Double? = nil,
        minVisionDistance: Double? = nil,
        averageDhashDistance: Int? = nil,
        kind: ClusterKind
    ) {
        self.timeDeltaSeconds = timeDeltaSeconds
        self.averageVisionDistance = averageVisionDistance
        self.minVisionDistance = minVisionDistance
        self.averageDhashDistance = averageDhashDistance
        self.kind = kind
    }
}

// MARK: - Keeper reason

public enum KeeperFactor: Sendable, Equatable {
    case sharperFaces(delta: Double)
    case higherResolution(factor: Double)
    case isRaw
    case largerFile(delta: Int64)
    case betterSharpness(delta: Double)
    case eyesOpen
    case betterExpression(delta: Double)
    case betterOverallQuality(delta: Double)
}

public struct KeeperReason: Sendable, Equatable {
    public var factors: [KeeperFactor]

    public init(factors: [KeeperFactor] = []) {
        self.factors = factors
    }
}

// MARK: - Safety warnings

public enum SafetyWarning: Sendable, Equatable {
    case differentPeople(faceCountDelta: Int)
    case differentFraming(cropDelta: Double)
    case largeTimeGap(seconds: TimeInterval)
    case textOverlayDetected
    case significantExposureDifference
}

// MARK: - Pairwise match (captured during clustering)

public struct PairwiseMatch: Sendable, Equatable {
    public var lhsPath: String
    public var rhsPath: String
    public var visionDistance: Double?
    public var dhashDistance: Int?
    public var timeDeltaSeconds: TimeInterval?

    public init(
        lhsPath: String,
        rhsPath: String,
        visionDistance: Double? = nil,
        dhashDistance: Int? = nil,
        timeDeltaSeconds: TimeInterval? = nil
    ) {
        self.lhsPath = lhsPath
        self.rhsPath = rhsPath
        self.visionDistance = visionDistance
        self.dhashDistance = dhashDistance
        self.timeDeltaSeconds = timeDeltaSeconds
    }
}

// MARK: - Cluster annotation (composite)

public struct ClusterAnnotation: Sendable, Equatable {
    public var confidence: ConfidenceLevel
    public var matchReason: MatchReason
    public var keeperReason: KeeperReason?
    public var warnings: [SafetyWarning]

    public init(
        confidence: ConfidenceLevel = .medium,
        matchReason: MatchReason,
        keeperReason: KeeperReason? = nil,
        warnings: [SafetyWarning] = []
    ) {
        self.confidence = confidence
        self.matchReason = matchReason
        self.keeperReason = keeperReason
        self.warnings = warnings
    }
}

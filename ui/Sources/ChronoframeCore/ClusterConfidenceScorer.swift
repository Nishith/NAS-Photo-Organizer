import Foundation

/// Assigns a confidence level to a cluster based on how obvious the
/// duplication is. High-confidence clusters can be auto-accepted;
/// low-confidence ones require careful manual review.
public enum ClusterConfidenceScorer {
    public static func score(
        cluster: DuplicateCluster,
        matchReason: MatchReason,
        warnings: [SafetyWarning]
    ) -> ConfidenceLevel {
        if !warnings.isEmpty { return .low }

        if cluster.kind == .exactDuplicate { return .high }

        let visionDist = matchReason.averageVisionDistance ?? 1.0
        let timeDelta = matchReason.timeDeltaSeconds ?? .greatestFiniteMagnitude

        if visionDist < 0.10, timeDelta < 5.0 {
            return .high
        }

        if cluster.kind == .editedVariant {
            return .low
        }

        if visionDist > 0.30 {
            return .low
        }

        return .medium
    }
}

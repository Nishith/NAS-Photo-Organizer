import Foundation

/// Produces a `ClusterAnnotation` for a finished cluster by analyzing the
/// pairwise distances captured during clustering and the keeper selection
/// outcome. Confidence scoring and safety-warning detection are delegated to
/// `ClusterConfidenceScorer` and `SafetyWarningDetector` (Phase 2).
public enum ClusterAnnotator {
    public static func annotate(
        cluster: DuplicateCluster,
        pairwiseMatches: [PairwiseMatch],
        configuration: DeduplicateConfiguration
    ) -> ClusterAnnotation {
        let matchReason = buildMatchReason(
            cluster: cluster,
            pairwiseMatches: pairwiseMatches
        )
        let keeperReason = buildKeeperReason(cluster: cluster)
        let warnings = SafetyWarningDetector.detect(
            cluster: cluster,
            pairwiseMatches: pairwiseMatches
        )
        let confidence = ClusterConfidenceScorer.score(
            cluster: cluster,
            matchReason: matchReason,
            warnings: warnings
        )

        return ClusterAnnotation(
            confidence: confidence,
            matchReason: matchReason,
            keeperReason: keeperReason,
            warnings: warnings
        )
    }

    // MARK: - Match reason

    static func buildMatchReason(
        cluster: DuplicateCluster,
        pairwiseMatches: [PairwiseMatch]
    ) -> MatchReason {
        let memberPaths = Set(cluster.members.map(\.path))
        let relevant = pairwiseMatches.filter {
            memberPaths.contains($0.lhsPath) && memberPaths.contains($0.rhsPath)
        }

        let visionDistances = relevant.compactMap(\.visionDistance)
        let dhashDistances = relevant.compactMap(\.dhashDistance)
        let timeDeltas = relevant.compactMap(\.timeDeltaSeconds)

        let avgVision = visionDistances.isEmpty
            ? nil
            : visionDistances.reduce(0, +) / Double(visionDistances.count)
        let minVision = visionDistances.min()
        let avgDhash = dhashDistances.isEmpty
            ? nil
            : dhashDistances.reduce(0, +) / dhashDistances.count

        let dates = cluster.members.compactMap(\.captureDate)
        let timeSpan: TimeInterval? = if let first = dates.min(), let last = dates.max() {
            last.timeIntervalSince(first)
        } else if let maxDelta = timeDeltas.max() {
            maxDelta
        } else {
            nil
        }

        return MatchReason(
            timeDeltaSeconds: timeSpan,
            averageVisionDistance: avgVision,
            minVisionDistance: minVision,
            averageDhashDistance: avgDhash,
            kind: cluster.kind
        )
    }

    // MARK: - Keeper reason

    static func buildKeeperReason(cluster: DuplicateCluster) -> KeeperReason? {
        guard let keeperID = cluster.suggestedKeeperIDs.first else { return nil }
        guard let keeper = cluster.members.first(where: { $0.id == keeperID }) else { return nil }

        let others = cluster.members.filter { $0.id != keeperID && $0.pairedPath != keeperID }
        guard let runnerUp = others.max(by: { $0.qualityScore < $1.qualityScore }) else {
            return nil
        }

        var factors: [KeeperFactor] = []

        let qualityDelta = keeper.qualityScore - runnerUp.qualityScore
        if qualityDelta > 0.01 {
            factors.append(.betterOverallQuality(delta: qualityDelta))
        }

        let sharpnessDelta = keeper.sharpness - runnerUp.sharpness
        if sharpnessDelta > 0.05 {
            factors.append(.betterSharpness(delta: sharpnessDelta))
        }

        if let kFace = keeper.faceScore, let rFace = runnerUp.faceScore, kFace - rFace > 0.05 {
            factors.append(.sharperFaces(delta: kFace - rFace))
        }

        if let kEyes = keeper.eyesOpenScore, let rEyes = runnerUp.eyesOpenScore,
           kEyes > 0.7, rEyes < 0.5 {
            factors.append(.eyesOpen)
        }

        if let kSmile = keeper.smileScore, let rSmile = runnerUp.smileScore,
           kSmile - rSmile > 0.15 {
            factors.append(.betterExpression(delta: kSmile - rSmile))
        }

        let keeperArea = Int64(keeper.pixelWidth ?? 0) * Int64(keeper.pixelHeight ?? 0)
        let runnerArea = Int64(runnerUp.pixelWidth ?? 0) * Int64(runnerUp.pixelHeight ?? 0)
        if keeperArea > 0, runnerArea > 0, keeperArea > runnerArea {
            let factor = Double(keeperArea) / Double(runnerArea)
            if factor > 1.1 {
                factors.append(.higherResolution(factor: factor))
            }
        }

        if keeper.size > runnerUp.size {
            let delta = keeper.size - runnerUp.size
            if delta > 100_000 {
                factors.append(.largerFile(delta: delta))
            }
        }

        if keeper.isRaw, !runnerUp.isRaw {
            factors.append(.isRaw)
        }

        return KeeperReason(factors: factors)
    }
}

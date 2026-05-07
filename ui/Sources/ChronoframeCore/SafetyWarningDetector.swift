import Foundation

/// Detects characteristics suggesting a cluster's photos may be
/// *intentionally* different rather than accidental duplicates.
public enum SafetyWarningDetector {
    public static func detect(
        cluster: DuplicateCluster,
        pairwiseMatches: [PairwiseMatch]
    ) -> [SafetyWarning] {
        if cluster.kind == .exactDuplicate { return [] }

        var warnings: [SafetyWarning] = []

        if let warning = checkDifferentPeople(cluster: cluster) {
            warnings.append(warning)
        }
        if let warning = checkDifferentFraming(cluster: cluster) {
            warnings.append(warning)
        }
        if let warning = checkLargeTimeGap(cluster: cluster) {
            warnings.append(warning)
        }
        if let warning = checkExposureDifference(cluster: cluster) {
            warnings.append(warning)
        }

        return warnings
    }

    // MARK: - Individual checks

    static func checkDifferentPeople(cluster: DuplicateCluster) -> SafetyWarning? {
        let faceCounts = cluster.members.compactMap { member -> Int? in
            guard let score = member.faceScore else { return nil }
            if score > 0.8 { return 2 }
            if score > 0.3 { return 1 }
            return 0
        }
        guard let maxFaces = faceCounts.max(), let minFaces = faceCounts.min() else {
            return nil
        }
        let delta = maxFaces - minFaces
        if delta >= 1 {
            return .differentPeople(faceCountDelta: delta)
        }
        return nil
    }

    static func checkDifferentFraming(cluster: DuplicateCluster) -> SafetyWarning? {
        let aspectRatios: [Double] = cluster.members.compactMap { member in
            guard let w = member.pixelWidth, let h = member.pixelHeight, h > 0, w > 0 else {
                return nil
            }
            return Double(w) / Double(h)
        }
        guard aspectRatios.count >= 2 else { return nil }

        for i in 0..<aspectRatios.count {
            for j in (i + 1)..<aspectRatios.count {
                let ratio = max(aspectRatios[i], aspectRatios[j]) /
                    max(min(aspectRatios[i], aspectRatios[j]), 0.001)
                if ratio > 1.10 {
                    return .differentFraming(cropDelta: ratio - 1.0)
                }
            }
        }

        let areas = cluster.members.compactMap { member -> Int64? in
            guard let w = member.pixelWidth, let h = member.pixelHeight else { return nil }
            return Int64(w) * Int64(h)
        }
        if let maxArea = areas.max(), let minArea = areas.min(), minArea > 0 {
            let areaRatio = Double(maxArea) / Double(minArea)
            if areaRatio > 2.0 {
                return .differentFraming(cropDelta: areaRatio - 1.0)
            }
        }

        return nil
    }

    static func checkLargeTimeGap(cluster: DuplicateCluster) -> SafetyWarning? {
        guard cluster.kind == .nearDuplicate else { return nil }
        let dates = cluster.members.compactMap(\.captureDate)
        guard let first = dates.min(), let last = dates.max() else { return nil }
        let gap = last.timeIntervalSince(first)
        if gap > 300 {
            return .largeTimeGap(seconds: gap)
        }
        return nil
    }

    static func checkExposureDifference(cluster: DuplicateCluster) -> SafetyWarning? {
        let sharpnessValues = cluster.members.map(\.sharpness)
        guard sharpnessValues.count >= 2 else { return nil }
        guard let maxSharp = sharpnessValues.max(), let minSharp = sharpnessValues.min() else {
            return nil
        }
        if maxSharp > 0.01, minSharp > 0.01 {
            let ratio = maxSharp / minSharp
            if ratio > 2.5 {
                return .significantExposureDifference
            }
        }
        return nil
    }
}

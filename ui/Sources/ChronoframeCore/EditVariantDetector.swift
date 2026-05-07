import Foundation
import CoreGraphics
import ImageIO

/// Distinguishes intentional edits (crops, exposure adjustments, filters)
/// from true duplicates by comparing aspect ratios, pixel dimensions, and
/// EXIF editing software tags.
public enum EditVariantDetector {
    public struct EditSignal: Sendable, Equatable {
        public var kind: EditKind
        public var confidence: Double

        public init(kind: EditKind, confidence: Double) {
            self.kind = kind
            self.confidence = confidence
        }
    }

    public enum EditKind: String, Sendable, Codable {
        case crop
        case exposureAdjustment
        case colorFilter
        case whiteBalanceShift
    }

    /// Detect whether two candidates are edited variants of each other.
    /// Returns edit signals with confidence when edits are detected.
    public static func detect(
        lhs: PhotoCandidate,
        rhs: PhotoCandidate,
        lhsURL: URL? = nil,
        rhsURL: URL? = nil
    ) -> [EditSignal] {
        var signals: [EditSignal] = []

        if let signal = detectCrop(lhs: lhs, rhs: rhs) {
            signals.append(signal)
        }

        if let signal = detectExposureFromSharpness(lhs: lhs, rhs: rhs) {
            signals.append(signal)
        }

        if let lURL = lhsURL, let rURL = rhsURL {
            signals.append(contentsOf: detectFromEXIF(lhsURL: lURL, rhsURL: rURL))
        }

        return signals
    }

    /// Check whether a near-duplicate cluster should be reclassified as
    /// an edited variant. Returns true if high-confidence edit signals are
    /// detected between the quality-best member and at least one other.
    public static func shouldReclassify(
        cluster: DuplicateCluster,
        visionDistance: Double?
    ) -> Bool {
        guard cluster.kind == .nearDuplicate else { return false }
        guard let visionDist = visionDistance, visionDist >= 0.05, visionDist <= 0.40 else {
            return false
        }

        let sorted = cluster.members.sorted { $0.qualityScore > $1.qualityScore }
        guard sorted.count >= 2 else { return false }
        let best = sorted[0]

        for other in sorted.dropFirst() {
            let signals = detect(lhs: best, rhs: other)
            let maxConf = signals.map(\.confidence).max() ?? 0
            if maxConf > 0.7 { return true }
        }

        return false
    }

    // MARK: - Crop detection

    static func detectCrop(lhs: PhotoCandidate, rhs: PhotoCandidate) -> EditSignal? {
        guard let lw = lhs.pixelWidth, let lh = lhs.pixelHeight,
              let rw = rhs.pixelWidth, let rh = rhs.pixelHeight,
              lw > 0, lh > 0, rw > 0, rh > 0 else {
            return nil
        }

        let lhsAspect = Double(lw) / Double(lh)
        let rhsAspect = Double(rw) / Double(rh)
        let aspectDiff = abs(lhsAspect - rhsAspect)

        let lhsArea = lw * lh
        let rhsArea = rw * rh
        let areaRatio = Double(max(lhsArea, rhsArea)) / Double(max(min(lhsArea, rhsArea), 1))

        if aspectDiff > 0.05 && areaRatio > 1.1 {
            let confidence = min(1.0, aspectDiff * 2.0 + (areaRatio - 1.0) * 0.5)
            return EditSignal(kind: .crop, confidence: confidence)
        }

        if areaRatio > 1.5 && aspectDiff < 0.05 {
            return EditSignal(kind: .crop, confidence: min(1.0, (areaRatio - 1.0) * 0.8))
        }

        return nil
    }

    // MARK: - Exposure difference heuristic

    static func detectExposureFromSharpness(lhs: PhotoCandidate, rhs: PhotoCandidate) -> EditSignal? {
        let sharpDiff = abs(lhs.sharpness - rhs.sharpness)
        guard sharpDiff > 0.3 else { return nil }

        let sizeRatio = Double(max(lhs.size, rhs.size)) / Double(max(min(lhs.size, rhs.size), 1))
        if sizeRatio > 1.3 && sharpDiff > 0.25 {
            return EditSignal(kind: .exposureAdjustment, confidence: min(0.8, sharpDiff))
        }

        return nil
    }

    // MARK: - EXIF editing software detection

    static func detectFromEXIF(lhsURL: URL, rhsURL: URL) -> [EditSignal] {
        let lhsSoftware = editingSoftware(at: lhsURL)
        let rhsSoftware = editingSoftware(at: rhsURL)

        if lhsSoftware != nil && rhsSoftware == nil {
            return [EditSignal(kind: .exposureAdjustment, confidence: 0.85)]
        }
        if rhsSoftware != nil && lhsSoftware == nil {
            return [EditSignal(kind: .exposureAdjustment, confidence: 0.85)]
        }

        return []
    }

    static func editingSoftware(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return nil
        }

        if let software = properties[kCGImagePropertyTIFFSoftware as String] as? String {
            let editors = ["lightroom", "photoshop", "capture one", "darktable",
                          "rawtherapee", "luminar", "affinity", "gimp", "snapseed"]
            if editors.contains(where: { software.lowercased().contains($0) }) {
                return software
            }
        }

        if let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
           let software = tiff[kCGImagePropertyTIFFSoftware as String] as? String {
            return software
        }

        return nil
    }
}

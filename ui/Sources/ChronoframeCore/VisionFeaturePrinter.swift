import Foundation
import Vision

/// Wraps `VNGenerateImageFeaturePrintRequest` so the rest of the pipeline can
/// store and compare feature prints as opaque `Data` blobs without dragging
/// Vision types into the cache schema. Distances between two prints are
/// scaled by Vision into a non-negative `Float`; smaller = more similar.
public enum VisionFeaturePrinter {
    public enum Error: LocalizedError {
        case generationFailed(String)
        case decodeFailed
        case distanceFailed(String)

        public var errorDescription: String? {
            switch self {
            case let .generationFailed(message):
                return "Vision feature print failed: \(message)"
            case .decodeFailed:
                return "Could not decode the cached Vision feature print."
            case let .distanceFailed(message):
                return "Vision feature-print distance failed: \(message)"
            }
        }
    }

    /// Generate a Vision feature print for the image at `url` and return it
    /// as an NSSecureCoding-archived `Data` blob suitable for caching.
    public static func featurePrintData(at url: URL) throws -> Data {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(url: url, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw Error.generationFailed(error.localizedDescription)
        }
        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            throw Error.generationFailed("no observation produced")
        }
        return try NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
    }

    /// Compute Vision's distance between two archived feature-print blobs.
    /// Returns `Double` in the typical 0.0–2.0 range; lower = more similar.
    public static func distance(_ lhsData: Data, _ rhsData: Data) throws -> Double {
        guard let lhs = try unarchive(lhsData) else { throw Error.decodeFailed }
        guard let rhs = try unarchive(rhsData) else { throw Error.decodeFailed }
        var distance: Float = 0
        do {
            try lhs.computeDistance(&distance, to: rhs)
        } catch {
            throw Error.distanceFailed(error.localizedDescription)
        }
        return Double(distance)
    }

    private static func unarchive(_ data: Data) throws -> VNFeaturePrintObservation? {
        try NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }
}

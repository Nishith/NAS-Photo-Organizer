import CoreImage
import Foundation
import Vision

/// Heuristic per-photo quality score used to suggest a "keeper" inside each
/// near-duplicate cluster. The composite weighs sharpness (Laplacian
/// variance), face quality (Vision face landmarks → open eyes proxy),
/// resolution, and file size.
public struct PhotoQualityScore: Sendable, Equatable {
    public var composite: Double
    public var sharpness: Double
    public var faceScore: Double?

    public init(composite: Double, sharpness: Double, faceScore: Double?) {
        self.composite = composite
        self.sharpness = sharpness
        self.faceScore = faceScore
    }
}

public enum PhotoQualityScorer {
    /// Compute sharpness, face score, and a normalized composite for the
    /// image at `url`. Failures fall back to a low (but non-zero) sharpness
    /// reading so the candidate still participates in clustering.
    public static func score(
        at url: URL,
        sizeBytes: Int64,
        pixelWidth: Int?,
        pixelHeight: Int?
    ) -> PhotoQualityScore {
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let sharpness = sharpnessLaplacian(at: url, ciContext: context) ?? 0.05
        return score(
            sharpness: sharpness,
            faceScore: detectFaceScore(at: url),
            sizeBytes: sizeBytes,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    static func score(
        at url: URL,
        sizeBytes: Int64,
        pixelWidth: Int?,
        pixelHeight: Int?,
        ciContext: CIContext,
        faceScore: Double?
    ) -> PhotoQualityScore {
        let sharpness = sharpnessLaplacian(at: url, ciContext: ciContext) ?? 0.05
        return score(
            sharpness: sharpness,
            faceScore: faceScore,
            sizeBytes: sizeBytes,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    private static func score(
        sharpness: Double,
        faceScore: Double?,
        sizeBytes: Int64,
        pixelWidth: Int?,
        pixelHeight: Int?
    ) -> PhotoQualityScore {
        let resolution = Double(max(0, (pixelWidth ?? 0) * (pixelHeight ?? 0)))
        let resolutionScore = resolution > 0 ? min(1.0, log2(resolution) / 24.0) : 0.3
        let sizeScore = sizeBytes > 0 ? min(1.0, log2(Double(sizeBytes)) / 26.0) : 0.3

        var composite = 0.5 * sharpness + 0.15 * resolutionScore + 0.10 * sizeScore
        if let faceScore {
            composite += 0.25 * faceScore
        } else {
            // No detected face — redistribute the face weight back into
            // sharpness so face-free shots aren't unfairly penalized.
            composite += 0.25 * sharpness
        }
        return PhotoQualityScore(composite: composite, sharpness: sharpness, faceScore: faceScore)
    }

    /// Variance of a Laplacian-filtered grayscale downscale, normalized into
    /// 0…1. Higher = sharper. Uses a short-side downscale to bound work for
    /// very large RAWs.
    public static func sharpnessLaplacian(at url: URL) -> Double? {
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return sharpnessLaplacian(at: url, ciContext: context)
    }

    static func sharpnessLaplacian(at url: URL, ciContext: CIContext) -> Double? {
        guard let source = CIImage(contentsOf: url) else { return nil }

        // Downscale so the Laplacian pass runs in tens of milliseconds even
        // on 50-megapixel inputs. We retain enough detail to discriminate
        // blurry vs sharp at the scoring thresholds we care about.
        let extent = source.extent
        let shortSide = min(extent.width, extent.height)
        let scale = min(1.0, 256.0 / shortSide)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard
            let grayscale = CIFilter(name: "CIPhotoEffectMono", parameters: [kCIInputImageKey: scaled])?.outputImage,
            let laplacianFilter = CIFilter(name: "CIConvolution3X3"),
            let zero = CIVector(values: [0, 1, 0, 1, -4, 1, 0, 1, 0], count: 9) as CIVector?
        else {
            return nil
        }
        laplacianFilter.setValue(grayscale, forKey: kCIInputImageKey)
        laplacianFilter.setValue(zero, forKey: "inputWeights")
        guard let edges = laplacianFilter.outputImage else { return nil }

        guard
            let varianceFilter = CIFilter(name: "CIAreaAverage", parameters: [
                kCIInputImageKey: edges.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                ]).applyingFilter("CIMultiplyCompositing", parameters: [
                    kCIInputBackgroundImageKey: edges,
                ]),
                kCIInputExtentKey: CIVector(cgRect: edges.extent),
            ])?.outputImage
        else {
            return nil
        }

        var bitmap: [UInt8] = [0, 0, 0, 0]
        ciContext.render(
            varianceFilter,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        let raw = Double(bitmap[0]) / 255.0
        // Empirically log-flatten so blurry photos sit < 0.3 and sharp shots
        // approach 1.0. The exact constant doesn't matter — only the relative
        // ordering across cluster members.
        return min(1.0, max(0.0, log10(1 + raw * 20.0) / log10(21.0)))
    }

    /// Returns a 0…1 score per photo based on Vision face detection: faces
    /// that include landmarks (open-eye proxy) score higher. Returns nil if
    /// no faces are present.
    public static func detectFaceScore(at url: URL) -> Double? {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(url: url, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        return faceScore(from: request.results)
    }

    static func faceScore(from faces: [VNFaceObservation]?) -> Double? {
        guard let faces, !faces.isEmpty else { return nil }
        var total: Double = 0
        for face in faces {
            // Confidence is 0…1; landmarked faces get a +0.2 boost up to a
            // ceiling of 1.0, since landmarks imply the eyes were resolvable.
            let base = Double(face.confidence)
            let landmarkBoost = face.landmarks?.leftEye != nil && face.landmarks?.rightEye != nil ? 0.2 : 0.0
            total += min(1.0, base + landmarkBoost)
        }
        return min(1.0, total / Double(faces.count))
    }
}

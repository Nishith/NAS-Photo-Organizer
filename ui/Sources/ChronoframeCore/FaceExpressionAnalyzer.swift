import CoreGraphics
import CoreImage
import Vision

/// Analyzes face landmarks to detect eyes-open state, smile confidence,
/// subject-focused sharpness, and motion blur on the subject.
public enum FaceExpressionAnalyzer {
    public struct Result: Sendable, Equatable {
        public var eyesOpenConfidence: Double
        public var smileConfidence: Double
        public var subjectSharpness: Double
        public var subjectMotionBlur: Double

        public init(
            eyesOpenConfidence: Double = 0,
            smileConfidence: Double = 0,
            subjectSharpness: Double = 0,
            subjectMotionBlur: Double = 0
        ) {
            self.eyesOpenConfidence = eyesOpenConfidence
            self.smileConfidence = smileConfidence
            self.subjectSharpness = subjectSharpness
            self.subjectMotionBlur = subjectMotionBlur
        }
    }

    /// Analyze expression traits from existing face observations.
    /// Returns `nil` if no faces have usable landmarks.
    public static func analyze(
        cgImage: CGImage,
        faceObservations: [VNFaceObservation]
    ) -> Result? {
        let facesWithLandmarks = faceObservations.filter { $0.landmarks != nil }
        guard !facesWithLandmarks.isEmpty else { return nil }

        var totalEyesOpen = 0.0
        var totalSmile = 0.0
        var totalSubjectSharpness = 0.0
        var count = 0

        for face in facesWithLandmarks {
            guard let landmarks = face.landmarks else { continue }
            count += 1

            totalEyesOpen += eyesOpenScore(landmarks: landmarks)
            totalSmile += smileScore(landmarks: landmarks, boundingBox: face.boundingBox)

            let bbox = face.boundingBox
            let faceSharpness = regionSharpness(
                cgImage: cgImage,
                normalizedRect: bbox
            )
            totalSubjectSharpness += faceSharpness
        }

        guard count > 0 else { return nil }

        let avgSubjectSharpness = totalSubjectSharpness / Double(count)
        let globalSharpness = globalImageSharpness(cgImage: cgImage)
        let motionBlur: Double = if globalSharpness > 0.01 {
            max(0, 1.0 - avgSubjectSharpness / globalSharpness) * 0.5
        } else {
            0
        }

        return Result(
            eyesOpenConfidence: totalEyesOpen / Double(count),
            smileConfidence: totalSmile / Double(count),
            subjectSharpness: avgSubjectSharpness,
            subjectMotionBlur: min(1.0, motionBlur)
        )
    }

    // MARK: - Eyes-open detection

    static func eyesOpenScore(landmarks: VNFaceLandmarks2D) -> Double {
        guard let leftEye = landmarks.leftEye, let rightEye = landmarks.rightEye else {
            return 0.5
        }
        return eyesOpenScore(leftPoints: leftEye.normalizedPoints, rightPoints: rightEye.normalizedPoints)
    }

    static func eyesOpenScore(leftPoints: [CGPoint], rightPoints: [CGPoint]) -> Double {
        let leftOpenness = eyeOpenness(points: leftPoints)
        let rightOpenness = eyeOpenness(points: rightPoints)
        return (leftOpenness + rightOpenness) / 2.0
    }

    static func eyeOpenness(points: [CGPoint]) -> Double {
        guard points.count >= 6 else { return 0.5 }

        let ys = points.map(\.y)
        guard let minY = ys.min(), let maxY = ys.max() else { return 0.5 }
        let height = maxY - minY

        let xs = points.map(\.x)
        guard let minX = xs.min(), let maxX = xs.max() else { return 0.5 }
        let width = maxX - minX

        guard width > 0.001 else { return 0.5 }
        let aspectRatio = height / width

        return min(1.0, max(0.0, aspectRatio / 0.5))
    }

    // MARK: - Smile detection

    static func smileScore(landmarks: VNFaceLandmarks2D, boundingBox: CGRect) -> Double {
        guard let outerLips = landmarks.outerLips else { return 0.0 }
        return smileScore(points: outerLips.normalizedPoints)
    }

    static func smileScore(points: [CGPoint]) -> Double {
        guard points.count >= 6 else { return 0.0 }

        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return 0.0 }

        let mouthWidth = maxX - minX
        let mouthHeight = maxY - minY

        guard mouthHeight > 0.001 else { return 0.0 }
        let widthToHeight = mouthWidth / mouthHeight

        return min(1.0, max(0.0, (widthToHeight - 1.5) / 3.0))
    }

    // MARK: - Region sharpness (Laplacian)

    static func regionSharpness(cgImage: CGImage, normalizedRect: CGRect) -> Double {
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        let pixelRect = CGRect(
            x: normalizedRect.origin.x * imgW,
            y: (1.0 - normalizedRect.origin.y - normalizedRect.height) * imgH,
            width: normalizedRect.width * imgW,
            height: normalizedRect.height * imgH
        )
        .insetBy(dx: -10, dy: -10)
        .intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))

        guard pixelRect.width > 8, pixelRect.height > 8,
              let cropped = cgImage.cropping(to: pixelRect) else {
            return 0
        }

        return laplacianVariance(cgImage: cropped)
    }

    static func globalImageSharpness(cgImage: CGImage) -> Double {
        let maxDim = 128
        let scale = min(1.0, Double(maxDim) / Double(max(cgImage.width, cgImage.height)))
        let w = max(8, Int(Double(cgImage.width) * scale))
        let h = max(8, Int(Double(cgImage.height) * scale))

        var pixels = [UInt8](repeating: 0, count: w * h)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        return laplacianVarianceFromGray(pixels: pixels, width: w, height: h)
    }

    // MARK: - Laplacian variance

    static func laplacianVariance(cgImage: CGImage) -> Double {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 2, h > 2 else { return 0 }

        var pixels = [UInt8](repeating: 0, count: w * h)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }
        ctx.interpolationQuality = .none
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        return laplacianVarianceFromGray(pixels: pixels, width: w, height: h)
    }

    static func laplacianVarianceFromGray(pixels: [UInt8], width w: Int, height h: Int) -> Double {
        guard w > 2, h > 2 else { return 0 }
        var sum = 0.0
        var sumSq = 0.0
        var count = 0.0

        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let center = Double(pixels[y * w + x])
                let top = Double(pixels[(y - 1) * w + x])
                let bottom = Double(pixels[(y + 1) * w + x])
                let left = Double(pixels[y * w + (x - 1)])
                let right = Double(pixels[y * w + (x + 1)])
                let lap = top + bottom + left + right - 4.0 * center
                sum += lap
                sumSq += lap * lap
                count += 1.0
            }
        }

        guard count > 0 else { return 0 }
        let mean = sum / count
        let variance = sumSq / count - mean * mean
        return Foundation.log10(1.0 + max(0, variance) * 20.0) / Foundation.log10(21.0)
    }
}

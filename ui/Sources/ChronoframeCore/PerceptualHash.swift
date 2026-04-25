import Accelerate
import CoreGraphics
import Foundation
import ImageIO

/// dHash — difference hash. Converts an image to a 9×8 grayscale grid and
/// emits one bit per row for each (left < right) pixel comparison, producing
/// a 64-bit fingerprint. Hamming distance between two dHashes is a fast,
/// crop-tolerant similarity proxy used as a pre-filter before paying for
/// Vision's feature-print distance.
public enum PerceptualHash {
    /// Compute the dHash for the image at `url`. Returns nil if the file is
    /// not decodable as an image (CGImageSource refusal).
    public static func dhash(at url: URL) -> UInt64? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return dhash(from: cgImage)
    }

    public static func dhash(from cgImage: CGImage) -> UInt64? {
        let targetWidth = 9
        let targetHeight = 8
        let bytesPerRow = targetWidth
        var pixelBuffer = [UInt8](repeating: 0, count: targetWidth * targetHeight)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: &pixelBuffer,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        var hash: UInt64 = 0
        var bitIndex = 0
        for row in 0..<targetHeight {
            let rowOffset = row * bytesPerRow
            for col in 0..<(targetWidth - 1) {
                let left = pixelBuffer[rowOffset + col]
                let right = pixelBuffer[rowOffset + col + 1]
                if left < right {
                    hash |= (UInt64(1) << bitIndex)
                }
                bitIndex += 1
            }
        }
        return hash
    }

    /// Hamming distance between two 64-bit dHashes (number of differing
    /// bits). Lower = more similar; identical images return 0.
    @inlinable
    public static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        Int((a ^ b).nonzeroBitCount)
    }
}

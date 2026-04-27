import AppKit
import CoreGraphics
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Single source of truth for QuickLook-backed thumbnail rendering.
///
/// Two consumers feed off this:
///   * `ContactSheetThumbnailPipeline` (Setup screen contact sheet) uses
///     `pngData(for:size:scale:)` because its tests inject a mock at the
///     `Data` layer.
///   * `DedupeThumbnailLoader` uses `cgImage(for:size:scale:)` to skip
///     the PNG round-trip — `CGImage` is Sendable, so the result can
///     cross the actor boundary directly.
///
/// Keeping both paths in one file means the QuickLook request shape and
/// the PNG encoder live in exactly one place.
enum ThumbnailRenderer {
    nonisolated static func cgImage(for url: URL, size: CGSize, scale: CGFloat) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                continuation.resume(returning: rep?.cgImage)
            }
        }
    }

    nonisolated static func pngData(for url: URL, size: CGSize, scale: CGFloat) async -> Data? {
        guard let cgImage = await cgImage(for: url, size: size, scale: scale) else {
            return nil
        }
        return encodePNG(cgImage)
    }

    nonisolated static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }
}

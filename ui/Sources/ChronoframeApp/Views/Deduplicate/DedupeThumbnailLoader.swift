#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import AppKit
import ImageIO
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Tiny reusable loader for QuickLook thumbnails, keyed by path. Backs the
/// strip thumbnails and the large preview in the dedupe review UI. We keep
/// it in-memory only — the SwiftUI views own one loader each and discard
/// it when their view goes away.
@MainActor
final class DedupeThumbnailLoader: ObservableObject {
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

    func image(for path: String) -> NSImage? {
        thumbnails[path]
    }

    func request(path: String, size: CGSize) {
        guard thumbnails[path] == nil, !inFlight.contains(path) else { return }
        inFlight.insert(path)
        let url = URL(fileURLWithPath: path)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        Task { [weak self] in
            let imageData = await Self.thumbnailData(for: url, size: size, scale: scale)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.inFlight.remove(path)
                if let imageData, let image = NSImage(data: imageData) {
                    self.thumbnails[path] = image
                }
            }
        }
    }

    nonisolated static func thumbnailData(for url: URL, size: CGSize, scale: CGFloat) async -> Data? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                guard let cgImage = rep?.cgImage else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: pngData(for: cgImage))
            }
        }
    }

    nonisolated private static func pngData(for image: CGImage) -> Data? {
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

struct DedupeThumbnailView: View {
    let path: String
    let size: CGSize
    @ObservedObject var loader: DedupeThumbnailLoader

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(DesignTokens.ColorSystem.panel)
            if let image = loader.image(for: path) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
            }
        }
        .frame(width: size.width, height: size.height)
        .onAppear { loader.request(path: path, size: size) }
    }
}

#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import AppKit
import QuickLookThumbnailing
import SwiftUI

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
        Task { [weak self] in
            let image = await Self.generate(url: url, size: size, scale: NSScreen.main?.backingScaleFactor ?? 2.0)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.inFlight.remove(path)
                if let image {
                    self.thumbnails[path] = image
                }
            }
        }
    }

    nonisolated private static func generate(url: URL, size: CGSize, scale: CGFloat) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                continuation.resume(returning: rep?.nsImage)
            }
        }
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

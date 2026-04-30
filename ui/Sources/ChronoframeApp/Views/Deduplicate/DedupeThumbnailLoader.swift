#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import AppKit
import SwiftUI

/// QuickLook thumbnail cache for the Deduplicate review UI. Keyed by
/// path; backed by `NSCache` (auto-eviction under memory pressure +
/// `countLimit` for steady-state memory).
@MainActor
final class DedupeThumbnailLoader: ObservableObject {
    typealias Renderer = @Sendable (URL, CGSize, CGFloat) async -> CGImage?
    typealias ScaleProvider = @Sendable () -> CGFloat

    private let cache: NSCache<NSString, NSImage>
    private let renderer: Renderer
    private let scaleProvider: ScaleProvider

    init(
        countLimit: Int = 256,
        renderer: @escaping Renderer = { url, size, scale in
            await ThumbnailRenderer.cgImage(for: url, size: size, scale: scale)
        },
        scaleProvider: @escaping ScaleProvider = {
            NSScreen.main?.backingScaleFactor ?? 2.0
        }
    ) {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = countLimit
        self.cache = cache
        self.renderer = renderer
        self.scaleProvider = scaleProvider
    }

    func currentScale() -> CGFloat {
        scaleProvider()
    }

    private func cacheKey(for path: String, size: CGSize, scale: CGFloat) -> NSString {
        let widthKey = Int((size.width * 1_000).rounded())
        let heightKey = Int((size.height * 1_000).rounded())
        let scaleKey = Int((scale * 1_000).rounded())
        return "\(path)|\(widthKey)x\(heightKey)@\(scaleKey)" as NSString
    }

    func cachedImage(for path: String, size: CGSize, scale: CGFloat? = nil) -> NSImage? {
        let resolvedScale = scale ?? currentScale()
        return cache.object(forKey: cacheKey(for: path, size: size, scale: resolvedScale))
    }

    func image(for path: String, size: CGSize, scale: CGFloat? = nil) async -> NSImage? {
        let resolvedScale = scale ?? currentScale()
        let key = cacheKey(for: path, size: size, scale: resolvedScale)
        if let cached = cache.object(forKey: key) { return cached }
        let url = URL(fileURLWithPath: path)
        let cgImage = await renderer(url, size, resolvedScale)

        guard let cgImage, !Task.isCancelled else { return nil }

        let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        let image = NSImage(cgImage: cgImage, size: pixelSize)
        cache.setObject(image, forKey: key)
        return image
    }

    /// Drop every cached thumbnail. Intended for tests + memory-pressure
    /// recovery; not used in the normal UI flow.
    func purgeCache() {
        cache.removeAllObjects()
    }
}

struct DedupeThumbnailView: View {
    let path: String
    let size: CGSize
    @ObservedObject var loader: DedupeThumbnailLoader
    @State private var loadedState: (identity: TaskIdentity, image: NSImage)?

    private func currentImage(for identity: TaskIdentity) -> NSImage? {
        if let loaded = loadedState, loaded.identity == identity {
            return loaded.image
        }
        return loader.cachedImage(for: path, size: size, scale: identity.scale)
    }

    var body: some View {
        let identity = TaskIdentity(path: path, size: size, scale: loader.currentScale())

        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(DesignTokens.ColorSystem.panel)
            if let image = currentImage(for: identity) {
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
        .task(id: identity) {
            loadedState = nil
            if let image = await loader.image(for: path, size: size, scale: identity.scale) {
                loadedState = (identity: identity, image: image)
            }
        }
    }

    private struct TaskIdentity: Equatable {
        var path: String
        var size: CGSize
        var scale: CGFloat
    }
}

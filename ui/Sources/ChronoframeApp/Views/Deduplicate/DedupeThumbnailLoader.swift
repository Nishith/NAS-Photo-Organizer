#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import AppKit
import SwiftUI

/// QuickLook thumbnail cache for the Deduplicate review UI. Keyed by
/// path; backed by `NSCache` (auto-eviction under memory pressure +
/// `countLimit` for steady-state memory). The cache is process-shared via
/// `NSCache`'s thread safety, but UI invalidation is driven through the
/// `@Published version` counter on the @MainActor — SwiftUI re-renders
/// whenever the loader bumps `version`.
///
/// Cancellation: each in-flight render is tracked so `cancelAll()` (or
/// requesting the same path again) can stop wasted work when the user
/// navigates away from the Deduplicate workspace.
@MainActor
final class DedupeThumbnailLoader: ObservableObject {
    /// Bumps after every successful cache insert. Views observing this
    /// loader redraw whenever `version` changes.
    @Published private(set) var version: Int = 0

    private let cache: NSCache<NSString, NSImage>
    private var inFlight: [String: Task<Void, Never>] = [:]

    init(countLimit: Int = 256) {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = countLimit
        self.cache = cache
    }

    func image(for path: String) -> NSImage? {
        cache.object(forKey: path as NSString)
    }

    func request(path: String, size: CGSize) {
        if cache.object(forKey: path as NSString) != nil { return }
        if inFlight[path] != nil { return }
        let url = URL(fileURLWithPath: path)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let task = Task { [weak self] in
            let cgImage = await ThumbnailRenderer.cgImage(for: url, size: size, scale: scale)
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.inFlight.removeValue(forKey: path)
                if let cgImage {
                    let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
                    let image = NSImage(cgImage: cgImage, size: pixelSize)
                    self.cache.setObject(image, forKey: path as NSString)
                    self.version &+= 1
                }
            }
        }
        inFlight[path] = task
    }

    /// Cancel every in-flight render and discard its task handle. Called
    /// when the Deduplicate workspace disappears so we don't keep
    /// rendering thumbnails for clusters the user is no longer looking
    /// at. The cache is preserved so re-entering the workspace is fast.
    func cancelAll() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }

    /// Drop every cached thumbnail. Intended for tests + memory-pressure
    /// recovery; not used in the normal UI flow.
    func purgeCache() {
        cache.removeAllObjects()
        version &+= 1
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

import AppKit
import ImageIO
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// A small "contact sheet" that shows the first N images/videos in a folder
/// as thumbnails. Purpose: make the Setup screen *visual*, not just textual —
/// the user sees what they're about to organize.
///
/// Design notes:
/// - Pulls up to ``cellCount`` files (default 12) from ``sourcePath``.
/// - Uses `QLThumbnailGenerator` — works for all native media types.
/// - Cells fade in on appear with a 40ms stagger per Motion tokens.
/// - Empty state is a dimmed placeholder grid, not a blank rectangle.
/// - No filesystem work happens if ``sourcePath`` is empty.
struct ContactSheetView: View {
    let sourcePath: String
    var cellCount: Int = 12
    var cellSize: CGFloat = 80

    @StateObject private var loader = ContactSheetLoader()

    var body: some View {
        // Fixed cell width keeps the grid's intrinsic footprint predictable —
        // `.adaptive` packs as many columns as fit in the available width and
        // wraps the rest, so the contact sheet never extends past the panel.
        let columns = [GridItem(.adaptive(minimum: cellSize, maximum: cellSize), spacing: 8)]

        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(0..<cellCount, id: \.self) { index in
                cell(at: index)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: sourcePath) {
            await loader.load(sourcePath: sourcePath, count: cellCount, cellSize: cellSize)
        }
        .accessibilityLabel(accessibilityLabelText)
    }

    @ViewBuilder
    private func cell(at index: Int) -> some View {
        let thumb = loader.thumbnails[safe: index] ?? nil

        ContactSheetThumbnailCell(thumbnail: thumb, cellSize: cellSize)
            .motion(.easeOut(duration: Motion.Duration.reveal).delay(0.04 * Double(index)), value: thumb != nil)
    }

    private var accessibilityLabelText: String {
        if sourcePath.isEmpty {
            return "Contact sheet preview — no source selected."
        }
        return "Contact sheet showing \(loader.thumbnails.count) of \(cellCount) preview frames from the source."
    }
}

struct ContactSheetThumbnailCell: View {
    let thumbnail: NSImage?
    let cellSize: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(DesignTokens.ColorSystem.hairline.opacity(thumbnail == nil ? 0.5 : 0))
            .overlay {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: cellSize, height: cellSize)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .transition(.opacity)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(DesignTokens.ColorSystem.hairline, lineWidth: 0.5)
            }
            .frame(width: cellSize, height: cellSize)
            .clipped()
    }
}

enum ContactSheetThumbnailPipeline {
    static func candidateLimit(for count: Int) -> Int {
        max(count, count * 4)
    }

    static func loadThumbnailData(
        from urls: [URL],
        count: Int,
        size: CGSize,
        scale: CGFloat,
        thumbnailData: @escaping @Sendable (URL, CGSize, CGFloat) async -> Data? = Self.thumbnailData(for:size:scale:)
    ) async -> [Data] {
        guard count > 0 else { return [] }

        let candidates = Array(urls.prefix(candidateLimit(for: count)))
        var byIndex: [Int: Data] = [:]
        await withTaskGroup(of: ThumbnailResult.self) { group in
            for (index, url) in candidates.enumerated() {
                group.addTask {
                    let imageData = await thumbnailData(url, size, scale)
                    return ThumbnailResult(index: index, imageData: imageData)
                }
            }

            for await result in group {
                if let imageData = result.imageData {
                    byIndex[result.index] = imageData
                }
            }
        }

        return candidates.indices.compactMap { byIndex[$0] }.prefix(count).map { $0 }
    }

    private static func thumbnailData(for url: URL, size: CGSize, scale: CGFloat) async -> Data? {
        await ThumbnailRenderer.pngData(for: url, size: size, scale: scale)
    }
}

// MARK: - Loader

@MainActor
private final class ContactSheetLoader: ObservableObject {
    @Published var thumbnails: [NSImage?] = []

    private var lastSource: String = ""

    func load(sourcePath: String, count: Int, cellSize: CGFloat) async {
        let trimmed = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == lastSource { return }
        lastSource = trimmed

        guard !trimmed.isEmpty else {
            thumbnails = []
            return
        }

        let urls = await Self.findMediaFiles(in: trimmed, limit: ContactSheetThumbnailPipeline.candidateLimit(for: count))
        thumbnails = Array(repeating: nil, count: count)

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let size = CGSize(width: cellSize * 2, height: cellSize * 2)
        let imageData = await ContactSheetThumbnailPipeline.loadThumbnailData(
            from: urls,
            count: count,
            size: size,
            scale: scale
        )

        for (index, data) in imageData.prefix(count).enumerated() {
            if let image = NSImage(data: data) {
                thumbnails[index] = image
            }
        }
    }

    nonisolated private static func findMediaFiles(in path: String, limit: Int) async -> [URL] {
        await Task.detached(priority: .userInitiated) {
            let root = URL(fileURLWithPath: path, isDirectory: true)
            let keys: [URLResourceKey] = [.isRegularFileKey, .typeIdentifierKey, .creationDateKey]
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                return []
            }

            var results: [URL] = []
            while let next = enumerator.nextObject() {
                guard results.count < limit else { break }
                guard let url = next as? URL else { continue }
                if Self.isLikelyMedia(url) {
                    results.append(url)
                }
            }
            return results
        }.value
    }

    nonisolated private static let mediaExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp",
        "mp4", "mov", "m4v", "avi", "mkv", "3gp", "hevc",
        "cr2", "cr3", "nef", "arw", "raf", "rw2", "dng", "orf"
    ]

    nonisolated private static func isLikelyMedia(_ url: URL) -> Bool {
        mediaExtensions.contains(url.pathExtension.lowercased())
    }

}

private struct ThumbnailResult: Sendable {
    let index: Int
    let imageData: Data?
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

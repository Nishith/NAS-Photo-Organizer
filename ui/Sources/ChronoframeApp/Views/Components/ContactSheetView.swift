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
    var cellCount: Int = 18
    var cellSize: CGFloat = 92

    @StateObject private var loader = ContactSheetLoader()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if shouldShowHeroCell {
                heroCell
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: [GridItem(.fixed(cellSize))], spacing: 8) {
                    ForEach(gridRange, id: \.self) { index in
                        cell(at: index)
                    }
                }
                .padding(.horizontal, 1)
            }
            .frame(height: cellSize)
        }
        .padding(10)
        .background(DesignTokens.ColorSystem.imageStage, in: RoundedRectangle(cornerRadius: DesignTokens.Corner.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Corner.card, style: .continuous)
                .strokeBorder(DesignTokens.ColorSystem.hairline, lineWidth: 0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: sourcePath) {
            await loader.load(sourcePath: sourcePath, count: cellCount, cellSize: cellSize)
        }
        .accessibilityLabel(accessibilityLabelText)
    }

    private var gridRange: Range<Int> {
        let lowerBound = sourcePath.isEmpty ? 0 : min(1, cellCount)
        return lowerBound..<cellCount
    }

    @ViewBuilder
    private var heroCell: some View {
        let thumb = loader.thumbnails[safe: 0] ?? nil

        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.black.opacity(0.24))
            .overlay {
                if let thumb {
                    Image(nsImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 168)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .transition(.opacity)
                } else if loader.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    ContactSheetHeroPlaceholder()
                }
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(DesignTokens.ColorSystem.accentWaypoint)
                        .frame(width: 6, height: 6)
                    Text(URL(fileURLWithPath: sourcePath).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.black.opacity(0.46), in: Capsule())
                .padding(10)
            }
            .frame(maxWidth: .infinity, minHeight: 168, maxHeight: 168)
            .clipped()
            .motion(Motion.reveal, value: thumb != nil)
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
        if loader.didFinishLoading && loader.loadedThumbnailCount == 0 {
            return "Contact sheet preview — no previewable media found in the source."
        }
        return "Contact sheet showing \(loader.thumbnails.count) of \(cellCount) preview frames from the source."
    }

    private var shouldShowHeroCell: Bool {
        !sourcePath.isEmpty
    }
}

private struct ContactSheetHeroPlaceholder: View {
    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.45))
            Text("No previewable frames")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            EmptyFilmstripPattern()
                .opacity(0.55)
        }
    }
}

private struct EmptyFilmstripPattern: View {
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<6, id: \.self) { index in
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(index == 2 ? 0.18 : 0.10), lineWidth: 0.5)
                    .background(Color.white.opacity(index == 2 ? 0.06 : 0.03), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .frame(width: index == 2 ? 74 : 52, height: index == 2 ? 96 : 78)
            }
        }
    }
}

struct ContactSheetThumbnailCell: View {
    let thumbnail: NSImage?
    let cellSize: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(thumbnail == nil ? Color.white.opacity(0.06) : Color.clear)
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
                    .strokeBorder(DesignTokens.ColorSystem.imageStageHairline, lineWidth: 0.5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(DesignTokens.ColorSystem.photoEdgeHighlight, lineWidth: thumbnail == nil ? 0 : 0.5)
                    .blendMode(.screen)
            }
            .frame(width: cellSize, height: cellSize)
            .clipped()
            .shadow(color: .black.opacity(thumbnail == nil ? 0 : 0.18), radius: 4, x: 0, y: 2)
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
    @Published private(set) var phase: Phase = .idle

    private var lastSource: String = ""

    enum Phase: Equatable {
        case idle
        case loading
        case finished
    }

    var isLoading: Bool {
        phase == .loading
    }

    var didFinishLoading: Bool {
        phase == .finished
    }

    var loadedThumbnailCount: Int {
        thumbnails.compactMap { $0 }.count
    }

    func load(sourcePath: String, count: Int, cellSize: CGFloat) async {
        let trimmed = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == lastSource { return }
        lastSource = trimmed

        guard !trimmed.isEmpty else {
            thumbnails = []
            phase = .idle
            return
        }

        thumbnails = Array(repeating: nil, count: count)
        phase = .loading
        let urls = await Self.findMediaFiles(in: trimmed, limit: ContactSheetThumbnailPipeline.candidateLimit(for: count))

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
        phase = .finished
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

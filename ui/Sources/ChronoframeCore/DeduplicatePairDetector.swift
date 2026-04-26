import AVFoundation
import Foundation
import ImageIO

/// Detects two kinds of file pairs that must be treated as a single unit
/// during deduplicate keep/delete decisions:
///
/// 1. RAW + JPEG sidecars — same parent dir + same basename, one extension
///    in `MediaLibraryRules.rawExtensions`, the other in `{jpg, jpeg, heic}`.
/// 2. Live Photo pairs — HEIC still + sibling MOV that share the same
///    Apple Content Identifier (ImageIO key 17 in maker-Apple, QuickTime
///    `com.apple.quicktime.content.identifier` in the movie).
public enum DeduplicatePairDetector {
    public static let rawExtensions: Set<String> = [
        ".dng", ".nef", ".cr2", ".cr3", ".arw", ".raf", ".orf", ".rw2",
    ]
    public static let companionablePhotoExtensions: Set<String> = [
        ".jpg", ".jpeg", ".heic",
    ]

    public struct Pair: Sendable, Equatable {
        public var primaryPath: String
        public var secondaryPath: String
        public var kind: Kind

        public enum Kind: String, Sendable, Equatable {
            case rawJpeg
            case livePhoto
        }
    }

    /// Scan the given paths and return a map from path → partner path for
    /// every detected pair. Paths that have no partner are absent from the
    /// map. Each pair's two members both appear as keys (mutual link).
    public static func detectPairs(in paths: [String]) -> [String: Pair] {
        var pairs: [String: Pair] = [:]

        let rawJpegByBasename = groupByBasename(paths)
        for (_, group) in rawJpegByBasename where group.count > 1 {
            // Partition into RAW vs companion image; ignore everything else.
            var rawPath: String?
            var companionPath: String?
            for entry in group {
                let ext = MediaLibraryRules.normalizedExtension(for: entry)
                if rawExtensions.contains(ext) { rawPath = entry }
                else if companionablePhotoExtensions.contains(ext) { companionPath = entry }
            }
            if let rawPath, let companionPath {
                let pair = Pair(primaryPath: rawPath, secondaryPath: companionPath, kind: .rawJpeg)
                pairs[rawPath] = pair
                pairs[companionPath] = pair
            }
        }

        // Live Photo: read content identifier from each HEIC and from each
        // sibling MOV; match within the same parent directory.
        let heicByDirectory = groupByDirectory(paths.filter { $0.lowercased().hasSuffix(".heic") })
        let movByDirectory = groupByDirectory(paths.filter {
            let ext = MediaLibraryRules.normalizedExtension(for: $0)
            return ext == ".mov" || ext == ".m4v"
        })

        for (directory, heics) in heicByDirectory {
            guard let movs = movByDirectory[directory] else { continue }
            let movByIdentifier = movs.reduce(into: [String: String]()) { acc, path in
                if let id = livePhotoIdentifier(forMovieAt: URL(fileURLWithPath: path)) {
                    acc[id] = path
                }
            }
            guard !movByIdentifier.isEmpty else { continue }

            for heic in heics {
                guard let id = livePhotoIdentifier(forImageAt: URL(fileURLWithPath: heic)) else { continue }
                guard let movPath = movByIdentifier[id] else { continue }
                let pair = Pair(primaryPath: heic, secondaryPath: movPath, kind: .livePhoto)
                pairs[heic] = pair
                pairs[movPath] = pair
            }
        }

        return pairs
    }

    static func groupByBasename(_ paths: [String]) -> [String: [String]] {
        var buckets: [String: [String]] = [:]
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let base = url.deletingPathExtension().path
            buckets[base, default: []].append(path)
        }
        return buckets
    }

    static func groupByDirectory(_ paths: [String]) -> [String: [String]] {
        var buckets: [String: [String]] = [:]
        for path in paths {
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            buckets[parent, default: []].append(path)
        }
        return buckets
    }

    /// Read the Apple Content Identifier from a HEIC's maker-Apple
    /// dictionary. Returns nil if the file is not a Live Photo still.
    public static func livePhotoIdentifier(forImageAt url: URL) -> String? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let makerApple = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any]
        else {
            return nil
        }
        // Key "17" is Apple's documented Content Identifier slot.
        return makerApple["17"] as? String
    }

    /// Read the Apple Content Identifier from a QuickTime movie's metadata.
    /// Returns nil if the file is not the .mov half of a Live Photo.
    public static func livePhotoIdentifier(forMovieAt url: URL) -> String? {
        let asset = AVURLAsset(url: url)
        for item in asset.metadata {
            if item.identifier?.rawValue == "mdta/com.apple.quicktime.content.identifier",
               let value = item.value as? String {
                return value
            }
        }
        return nil
    }
}

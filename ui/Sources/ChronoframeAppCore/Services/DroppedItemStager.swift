import Foundation

/// Result of staging dropped items for use as a Chronoframe source.
///
/// - If the user dropped exactly one directory, we use it directly and no
///   staging work is needed (`stagingDirectory == originalFolder`).
/// - Otherwise we build a synthetic "source" directory with a private manifest
///   of dropped items so discovery can safely resolve exactly those paths
///   without enabling arbitrary symlink traversal.
public struct StagedDrop: Equatable {
    public var sourceDirectory: URL
    public var wasSingleFolder: Bool
    public var itemCount: Int
    public var displayLabel: String

    public init(sourceDirectory: URL, wasSingleFolder: Bool, itemCount: Int, displayLabel: String) {
        self.sourceDirectory = sourceDirectory
        self.wasSingleFolder = wasSingleFolder
        self.itemCount = itemCount
        self.displayLabel = displayLabel
    }
}

public enum DroppedItemStagerError: Error, LocalizedError {
    case noItems
    case stagingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noItems:
            return "Chronoframe could not use the dropped items. Drag files or folders from Finder, or choose a source folder instead."
        case .stagingFailed(let reason):
            return UserFacingErrorMessage.withDetails(
                "Chronoframe could not prepare those dropped items. Choose the source folder with the picker instead.",
                details: reason
            )
        }
    }
}

/// Stages dropped files/folders into a temporary manifest directory so
/// Chronoframe's normal source-folder discovery can process them. For a
/// single-folder drop we skip staging entirely and hand the folder back.
public struct DroppedItemStager {
    private struct Manifest: Codable {
        var items: [Item]

        struct Item: Codable {
            var path: String
            var isDirectory: Bool
        }
    }

    public static let manifestFilename = ".chronoframe_drop_manifest.json"

    private let fileManager: FileManager
    private let stagingRootURL: URL

    public init(fileManager: FileManager = .default, stagingRoot: URL? = nil) {
        self.fileManager = fileManager
        self.stagingRootURL = stagingRoot ?? Self.stagingRoot
    }

    /// Root directory that holds all drag-and-drop staging folders. Used
    /// both for cleanup and for identifying "this source is a drop" in
    /// downstream code.
    public static var stagingRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return caches.appendingPathComponent("Chronoframe/drops", isDirectory: true)
    }

    /// Returns `true` if `path` lives under the staging root. Used by the
    /// history recorder so drag-and-drop paths aren't saved as reusable
    /// source entries (the temp folder won't exist next launch).
    public static func isStagingPath(_ path: String) -> Bool {
        isStagingPath(path, under: stagingRoot)
    }

    public func isStagingPath(_ path: String) -> Bool {
        Self.isStagingPath(path, under: stagingRootURL)
    }

    private static func isStagingPath(_ path: String, under rootURL: URL) -> Bool {
        let root = rootURL.standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    /// Stages a set of dropped URLs into a fresh symlink directory. If
    /// exactly one directory was dropped, returns it directly without
    /// creating a staging directory.
    ///
    /// The caller is responsible for passing the result to `setupStore`
    /// (and optionally calling `cleanupExistingStagingDirectories()` on
    /// app launch to reclaim disk space from previous sessions).
    public func stage(urls: [URL], at date: Date = Date()) throws -> StagedDrop {
        let unique = dedupedResolved(urls: urls)
        guard !unique.isEmpty else { throw DroppedItemStagerError.noItems }

        // Single-folder drop: use it directly, no staging needed.
        if unique.count == 1, isDirectory(unique[0]) {
            let folder = unique[0]
            return StagedDrop(
                sourceDirectory: folder,
                wasSingleFolder: true,
                itemCount: 1,
                displayLabel: folder.path
            )
        }

        // Multi-item or file drop: build a fresh staging directory with a
        // manifest. This avoids broad symlink following while still letting
        // dropped individual files participate in the regular pipeline.
        let stagingDir = try createFreshStagingDirectory(at: date)

        let items = unique.map { url in
            Manifest.Item(path: url.path, isDirectory: isDirectory(url))
        }
        let manifest = Manifest(items: items)
        let manifestURL = stagingDir.appendingPathComponent(Self.manifestFilename)
        let encoder = JSONEncoder()
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
        let staged = items.count

        guard staged > 0 else {
            throw DroppedItemStagerError.stagingFailed("no droppable items after staging")
        }

        let label = humanLabel(itemCount: staged, date: date)
        return StagedDrop(
            sourceDirectory: stagingDir,
            wasSingleFolder: false,
            itemCount: staged,
            displayLabel: label
        )
    }

    /// Removes *all* previous staging directories. Safe to call on app
    /// launch; leftover staging symlink dirs are never needed across
    /// sessions (the source transfers already happened, or were never
    /// committed).
    public func cleanupAllStagingDirectories() {
        let root = stagingRootURL
        guard fileManager.fileExists(atPath: root.path) else { return }
        try? fileManager.removeItem(at: root)
    }

    /// Removes a specific staging directory. Tolerant of missing paths.
    public func cleanup(stagingDirectory url: URL) {
        guard isStagingPath(url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    // MARK: - Helpers

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        return isDir.boolValue
    }

    /// Expands a list of URLs, resolving aliases, filtering out duplicates
    /// and entries that don't exist on disk.
    private func dedupedResolved(urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        for url in urls {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard fileManager.fileExists(atPath: resolved.path) else { continue }
            if seen.insert(resolved.path).inserted {
                result.append(resolved)
            }
        }
        return result
    }

    private func createFreshStagingDirectory(at date: Date) throws -> URL {
        let root = stagingRootURL
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let stamp = Self.timestampFormatter.string(from: date)
        let name = "drop-\(stamp)-\(UUID().uuidString.prefix(6))"
        let dir = root.appendingPathComponent(name, isDirectory: true)

        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw DroppedItemStagerError.stagingFailed(error.localizedDescription)
        }
        return dir
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private static let humanDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func humanLabel(itemCount: Int, date: Date) -> String {
        let ds = Self.humanDateFormatter.string(from: date)
        return "Drag-and-drop · \(itemCount) item\(itemCount == 1 ? "" : "s") · \(ds)"
    }
}

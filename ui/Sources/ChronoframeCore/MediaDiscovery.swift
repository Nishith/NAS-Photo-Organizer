import Foundation

public struct MediaDiscoveryEntry: Equatable, Sendable {
    public var path: String
    public var isDirectory: Bool

    public init(path: String, isDirectory: Bool) {
        self.path = path
        self.isDirectory = isDirectory
    }
}

public enum MediaDiscovery {
    public struct DirectoryIssue: Equatable, Sendable {
        public var path: String
        public var message: String

        public init(path: String, message: String) {
            self.path = path
            self.message = message
        }
    }

    private struct DropManifest: Decodable {
        var items: [Item]

        struct Item: Decodable {
            var path: String
            var isDirectory: Bool
        }
    }

    private static let dropManifestFilename = ".chronoframe_drop_manifest.json"

    public static func discoverMediaFiles(
        at rootURL: URL,
        isCancelled: @Sendable () -> Bool = { false },
        onDirectoryIssue: (@Sendable (DirectoryIssue) -> Void)? = nil
    ) throws -> [String] {
        var results: [String] = []
        try enumerateMediaFiles(at: rootURL, isCancelled: isCancelled, onDirectoryIssue: onDirectoryIssue) { path in
            results.append(path)
        }
        return results
    }

    public static func enumerateMediaFiles(
        at rootURL: URL,
        isCancelled: @Sendable () -> Bool = { false },
        onDirectoryIssue: (@Sendable (DirectoryIssue) -> Void)? = nil,
        _ body: (String) throws -> Void
    ) throws {
        if let manifest = dropManifest(at: rootURL) {
            try enumerateManifest(manifest, isCancelled: isCancelled, onDirectoryIssue: onDirectoryIssue, visitFilePath: body)
            return
        }
        try walk(directoryURL: rootURL, isCancelled: isCancelled, onDirectoryIssue: onDirectoryIssue, visitFilePath: body)
    }

    public static func walkEntries(
        at rootURL: URL,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> [MediaDiscoveryEntry] {
        var entries: [MediaDiscoveryEntry] = []
        try walkEntries(directoryURL: rootURL, isCancelled: isCancelled, entries: &entries)
        return entries
    }

    private static func walk(
        directoryURL: URL,
        isCancelled: @Sendable () -> Bool,
        onDirectoryIssue: (@Sendable (DirectoryIssue) -> Void)?,
        visitFilePath: (String) throws -> Void
    ) throws {
        try throwIfCancelled(isCancelled)
        let partition = try partitionedChildren(of: directoryURL, onDirectoryIssue: onDirectoryIssue)

        for child in partition.files {
            try throwIfCancelled(isCancelled)
            // Drain Foundation autoreleased temporaries (URL/NSString/NSDictionary bridges,
            // FileHandle, NSRegularExpression results) per-iteration. Without this, the
            // pool only drains when plan()/executeQueuedJobs() returns, which on large
            // trees (10k+ files) can pin hundreds of MB of otherwise-dead NSObjects.
            try autoreleasepool {
                let name = child.lastPathComponent
                if name.hasPrefix(".") {
                    return
                }

                if MediaLibraryRules.shouldSkipDiscoveredFile(named: name) {
                    return
                }

                if MediaLibraryRules.isSupportedMediaFile(path: child.path) {
                    try visitFilePath(child.path)
                }
            }
        }

        for child in partition.directories {
            try throwIfCancelled(isCancelled)
            try walk(directoryURL: child, isCancelled: isCancelled, onDirectoryIssue: onDirectoryIssue, visitFilePath: visitFilePath)
        }
    }

    private static func walkEntries(
        directoryURL: URL,
        isCancelled: @Sendable () -> Bool,
        entries: inout [MediaDiscoveryEntry]
    ) throws {
        try throwIfCancelled(isCancelled)
        let children = try sortedChildren(of: directoryURL, onDirectoryIssue: nil)
        for child in children {
            try throwIfCancelled(isCancelled)
            let name = child.lastPathComponent
            if name.hasPrefix(".") {
                continue
            }

            let resourceValues = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
            if resourceValues.isSymbolicLink == true || resourceValues.isPackage == true {
                continue
            }
            let isDirectory = resourceValues.isDirectory == true
            entries.append(MediaDiscoveryEntry(path: child.path, isDirectory: isDirectory))

            if isDirectory {
                try walkEntries(directoryURL: child, isCancelled: isCancelled, entries: &entries)
            }
        }
    }

    private static func throwIfCancelled(_ isCancelled: @Sendable () -> Bool) throws {
        if isCancelled() {
            throw CancellationError()
        }
    }

    private static func partitionedChildren(
        of directoryURL: URL,
        onDirectoryIssue: (@Sendable (DirectoryIssue) -> Void)?
    ) throws -> (directories: [URL], files: [URL]) {
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
                options: []
            )
        } catch {
            onDirectoryIssue?(
                DirectoryIssue(
                    path: directoryURL.path,
                    message: "Chronoframe could not read this folder, so it was skipped: \(directoryURL.path)"
                )
            )
            return ([], [])
        }

        var directories: [URL] = []
        var files: [URL] = []

        for child in children {
            let name = child.lastPathComponent
            if name.hasPrefix(".") {
                continue
            }

            let isDirectory: Bool
            do {
                let resourceValues = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
                if resourceValues.isSymbolicLink == true || resourceValues.isPackage == true {
                    continue
                }
                isDirectory = resourceValues.isDirectory == true
            } catch {
                continue
            }

            if isDirectory {
                directories.append(child)
            } else {
                files.append(child)
            }
        }

        let sorter: (URL, URL) -> Bool = {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        return (directories.sorted(by: sorter), files.sorted(by: sorter))
    }

    private static func sortedChildren(
        of directoryURL: URL,
        onDirectoryIssue: (@Sendable (DirectoryIssue) -> Void)?
    ) throws -> [URL] {
        let partition = try partitionedChildren(of: directoryURL, onDirectoryIssue: onDirectoryIssue)
        return partition.directories + partition.files
    }

    private static func dropManifest(at rootURL: URL) -> DropManifest? {
        let manifestURL = rootURL.appendingPathComponent(dropManifestFilename)
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(DropManifest.self, from: data)
    }

    private static func enumerateManifest(
        _ manifest: DropManifest,
        isCancelled: @Sendable () -> Bool,
        onDirectoryIssue: (@Sendable (DirectoryIssue) -> Void)?,
        visitFilePath: (String) throws -> Void
    ) throws {
        var seen = Set<String>()
        for item in manifest.items {
            try throwIfCancelled(isCancelled)
            let url = URL(fileURLWithPath: item.path).standardizedFileURL
            guard seen.insert(url.path).inserted else { continue }
            if item.isDirectory {
                try walk(directoryURL: url, isCancelled: isCancelled, onDirectoryIssue: onDirectoryIssue, visitFilePath: visitFilePath)
            } else if !url.lastPathComponent.hasPrefix("."),
                      MediaLibraryRules.isSupportedMediaFile(path: url.path) {
                try visitFilePath(url.path)
            }
        }
    }
}

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
    public static func discoverMediaFiles(
        at rootURL: URL,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> [String] {
        var results: [String] = []
        try enumerateMediaFiles(at: rootURL, isCancelled: isCancelled) { path in
            results.append(path)
        }
        return results
    }

    public static func enumerateMediaFiles(
        at rootURL: URL,
        isCancelled: @Sendable () -> Bool = { false },
        _ body: (String) throws -> Void
    ) throws {
        try walk(directoryURL: rootURL, isCancelled: isCancelled, visitFilePath: body)
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
        visitFilePath: (String) throws -> Void
    ) throws {
        try throwIfCancelled(isCancelled)
        let partition = try partitionedChildren(of: directoryURL)

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
            try walk(directoryURL: child, isCancelled: isCancelled, visitFilePath: visitFilePath)
        }
    }

    private static func walkEntries(
        directoryURL: URL,
        isCancelled: @Sendable () -> Bool,
        entries: inout [MediaDiscoveryEntry]
    ) throws {
        try throwIfCancelled(isCancelled)
        let children = try sortedChildren(of: directoryURL)
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

    private static func partitionedChildren(of directoryURL: URL) throws -> (directories: [URL], files: [URL]) {
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
                options: []
            )
        } catch {
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

    private static func sortedChildren(of directoryURL: URL) throws -> [URL] {
        let partition = try partitionedChildren(of: directoryURL)
        return partition.directories + partition.files
    }
}

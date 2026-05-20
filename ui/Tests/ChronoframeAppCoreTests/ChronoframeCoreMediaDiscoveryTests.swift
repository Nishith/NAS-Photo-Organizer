import Foundation
import XCTest
@testable import ChronoframeCore

final class ChronoframeCoreMediaDiscoveryTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChronoframeCoreMediaDiscoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        try super.tearDownWithError()
    }

    func testDiscoverMediaFilesUsesSortedTraversalAndSupportedExtensionsOnly() throws {
        try writeFile("zeta/IMG_20240102_111111.jpg")
        try writeFile("alpha/VID_20240101_010101.mov")
        try writeFile("alpha/notes.txt")
        try writeFile("alpha/beta/PANO_20231225_090000.jpg")

        let discovered = try MediaDiscovery.discoverMediaFiles(at: temporaryDirectoryURL)

        XCTAssertEqual(
            normalize(discovered),
            [
                "alpha/VID_20240101_010101.mov",
                "alpha/beta/PANO_20231225_090000.jpg",
                "zeta/IMG_20240102_111111.jpg",
            ]
        )
    }

    func testDiscoverMediaFilesSkipsHiddenEntriesAndSkipFiles() throws {
        try writeFile(".hidden/IMG_20240101_010101.jpg")
        try writeFile("visible/.ignored.mov")
        try writeFile("visible/profiles.yaml")
        try writeFile("visible/README.md")
        try writeFile("visible/IMG_20240101_010101.jpg")

        let discovered = try MediaDiscovery.discoverMediaFiles(at: temporaryDirectoryURL)

        XCTAssertEqual(normalize(discovered), ["visible/IMG_20240101_010101.jpg"])
    }

    func testWalkEntriesIncludesVisibleDirectoriesInDeterministicOrder() throws {
        try writeFile("b-dir/IMG_20240102_111111.jpg")
        try writeFile("a-dir/nested/VID_20240101_010101.mov")

        let entries = try MediaDiscovery.walkEntries(at: temporaryDirectoryURL)

        XCTAssertEqual(
            entries.map { "\(normalize($0.path)):\($0.isDirectory ? "dir" : "file")" },
            [
                "a-dir:dir",
                "a-dir/nested:dir",
                "a-dir/nested/VID_20240101_010101.mov:file",
                "b-dir:dir",
                "b-dir/IMG_20240102_111111.jpg:file",
            ]
        )
    }

    func testDirectoryIssueInitializerKeepsPathAndMessage() {
        let issue = MediaDiscovery.DirectoryIssue(path: "/photos/raw", message: "Skipped unreadable folder")

        XCTAssertEqual(issue.path, "/photos/raw")
        XCTAssertEqual(issue.message, "Skipped unreadable folder")
    }

    private func writeFile(_ relativePath: String) throws {
        let url = temporaryDirectoryURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("chronoframe".utf8).write(to: url)
    }

    private func normalize(_ paths: [String]) -> [String] {
        paths.map(normalize)
    }

    /// Phase 1 finding #9 regression: the drop-manifest path used to
    /// descend into any directory the manifest named — including
    /// symbolic links, app bundles, and `.photoslibrary` packages —
    /// because `walk()` only filtered the children, not the root it
    /// was given. The fix applies the same symlink/package screen to
    /// each manifest entry and emits a `DirectoryIssue` for skipped
    /// ones.
    func testDropManifestSkipsPackageDirectoriesAndEmitsDirectoryIssue() throws {
        // Build a fake `.photoslibrary` package containing a JPEG that
        // would be discovered if the manifest were honored blindly.
        let library = temporaryDirectoryURL.appendingPathComponent("Fake Library.photoslibrary", isDirectory: true)
        let originals = library.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try Data("payload".utf8).write(
            to: originals.appendingPathComponent("IMG_20240101_010101.jpg")
        )

        // Stage a manifest pointing at the package as a directory.
        let stagingDir = temporaryDirectoryURL.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "items": [
                ["path": library.path, "isDirectory": true]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest)
        try data.write(to: stagingDir.appendingPathComponent(".chronoframe_drop_manifest.json"))

        let discovered = try MediaDiscovery.discoverMediaFiles(
            at: stagingDir,
            onDirectoryIssue: { issue in
                Task { @MainActor in /* keep signature sendable; no-op store */ }
                _ = issue
            }
        )
        XCTAssertTrue(discovered.isEmpty,
            "Package entries in the drop manifest must not produce discovered files")

        // Re-run with a synchronous collector to verify the issue is emitted.
        let collected = LockedIssues()
        _ = try MediaDiscovery.discoverMediaFiles(
            at: stagingDir,
            onDirectoryIssue: { collected.append($0) }
        )
        let issuePaths = collected.values.map(\.path)
        XCTAssertTrue(
            issuePaths.contains { $0.hasSuffix("Fake Library.photoslibrary") },
            "Expected a DirectoryIssue for the skipped .photoslibrary; got \(issuePaths)"
        )
        XCTAssertTrue(
            collected.values.allSatisfy { $0.message.contains("package") || $0.message.contains("symlink") || $0.message.contains("photo libraries") },
            "Issue message should explain why the entry was skipped"
        )
    }

    private func normalize(_ path: String) -> String {
        let absolute = URL(fileURLWithPath: path).standardizedFileURL.path
        let root = temporaryDirectoryURL.standardizedFileURL.path + "/"
        return absolute.replacingOccurrences(of: root, with: "")
    }
}

/// Thread-safe issue collector for the @Sendable callback boundary.
private final class LockedIssues: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MediaDiscovery.DirectoryIssue] = []

    var values: [MediaDiscovery.DirectoryIssue] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ issue: MediaDiscovery.DirectoryIssue) {
        lock.lock()
        storage.append(issue)
        lock.unlock()
    }
}

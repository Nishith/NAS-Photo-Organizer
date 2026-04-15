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

    private func writeFile(_ relativePath: String) throws {
        let url = temporaryDirectoryURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("chronoframe".utf8).write(to: url)
    }

    private func normalize(_ paths: [String]) -> [String] {
        paths.map(normalize)
    }

    private func normalize(_ path: String) -> String {
        let absolute = URL(fileURLWithPath: path).standardizedFileURL.path
        let root = temporaryDirectoryURL.standardizedFileURL.path + "/"
        return absolute.replacingOccurrences(of: root, with: "")
    }
}

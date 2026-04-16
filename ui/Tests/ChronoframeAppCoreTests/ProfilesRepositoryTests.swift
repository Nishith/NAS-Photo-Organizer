import Foundation
import XCTest
@testable import ChronoframeAppCore

final class ProfilesRepositoryTests: XCTestCase {
    private var temporaryDirectoryURL: URL!
    private var originalProfilesPath: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChronoframeAppCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
        originalProfilesPath = ProcessInfo.processInfo.environment["CHRONOFRAME_PROFILES_PATH"]
    }

    override func tearDownWithError() throws {
        if let originalProfilesPath {
            setenv("CHRONOFRAME_PROFILES_PATH", originalProfilesPath, 1)
        } else {
            unsetenv("CHRONOFRAME_PROFILES_PATH")
        }

        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        try super.tearDownWithError()
    }

    func testSaveAndLoadRoundTrip() throws {
        let profilesURL = temporaryDirectoryURL.appendingPathComponent("profiles.yaml")
        setenv("CHRONOFRAME_PROFILES_PATH", profilesURL.path, 1)

        let repository = ProfilesRepository()
        try repository.save(profile: Profile(name: "default", sourcePath: "/Volumes/Ingest", destinationPath: "/Volumes/Archive"))
        try repository.save(profile: Profile(name: "travel", sourcePath: "/Volumes/Card", destinationPath: "/Volumes/Trips"))

        let profiles = try repository.loadProfiles()

        XCTAssertEqual(
            profiles,
            [
                Profile(name: "default", sourcePath: "/Volumes/Ingest", destinationPath: "/Volumes/Archive"),
                Profile(name: "travel", sourcePath: "/Volumes/Card", destinationPath: "/Volumes/Trips"),
            ]
        )
    }

    func testWritesDefaultProfileFirstForCliCompatibility() throws {
        let profilesURL = temporaryDirectoryURL.appendingPathComponent("profiles.yaml")
        setenv("CHRONOFRAME_PROFILES_PATH", profilesURL.path, 1)

        let repository = ProfilesRepository()
        try repository.save(profile: Profile(name: "z-last", sourcePath: "/tmp/z-src", destinationPath: "/tmp/z-dst"))
        try repository.save(profile: Profile(name: "default", sourcePath: "/tmp/default-src", destinationPath: "/tmp/default-dst"))
        try repository.save(profile: Profile(name: "alpha", sourcePath: "/tmp/a-src", destinationPath: "/tmp/a-dst"))

        let contents = try String(contentsOf: profilesURL, encoding: .utf8)
        let paragraphs = contents
            .split(separator: "\n\n")
            .map(String.init)

        XCTAssertEqual(paragraphs.first?.components(separatedBy: .newlines).first, "default:")
        XCTAssertTrue(contents.contains("alpha:\n  source: \"/tmp/a-src\"\n  dest: \"/tmp/a-dst\""))
        XCTAssertTrue(contents.contains("z-last:\n  source: \"/tmp/z-src\"\n  dest: \"/tmp/z-dst\""))
    }
}

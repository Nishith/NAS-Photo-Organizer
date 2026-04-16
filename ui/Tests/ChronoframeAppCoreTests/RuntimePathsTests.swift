import Foundation
import XCTest
@testable import ChronoframeAppCore

final class RuntimePathsTests: XCTestCase {
    private var originalProfilesPath: String?
    private var originalRepositoryRoot: String?
    private var originalAppEngine: String?
    private var originalCurrentDirectory: String!
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalProfilesPath = ProcessInfo.processInfo.environment["CHRONOFRAME_PROFILES_PATH"]
        originalRepositoryRoot = ProcessInfo.processInfo.environment["CHRONOFRAME_REPOSITORY_ROOT"]
        originalAppEngine = ProcessInfo.processInfo.environment["CHRONOFRAME_APP_ENGINE"]
        originalCurrentDirectory = FileManager.default.currentDirectoryPath
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuntimePathsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        restoreEnvironment()
        FileManager.default.changeCurrentDirectoryPath(originalCurrentDirectory)
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        try super.tearDownWithError()
    }

    func testProfilesFileUsesEnvironmentOverride() {
        let overridePath = temporaryDirectoryURL.appendingPathComponent("profiles.yaml").path
        setenv("CHRONOFRAME_PROFILES_PATH", overridePath, 1)

        XCTAssertEqual(RuntimePaths.profilesFileURL().path, overridePath)
    }

    func testBackendRootUsesRepositoryOverride() throws {
        let repoRoot = temporaryDirectoryURL.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoRoot.appendingPathComponent("chronoframe", isDirectory: true), withIntermediateDirectories: true)
        try "".write(to: repoRoot.appendingPathComponent("chronoframe.py"), atomically: true, encoding: .utf8)

        setenv("CHRONOFRAME_REPOSITORY_ROOT", repoRoot.path, 1)

        XCTAssertEqual(
            RuntimePaths.backendRootURL()?.resolvingSymlinksInPath().path,
            repoRoot.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(RuntimePaths.backendScriptURL()?.path, repoRoot.appendingPathComponent("chronoframe.py").path)
    }

    func testProfilesFallbackUsesApplicationSupportOutsideRepository() {
        unsetenv("CHRONOFRAME_PROFILES_PATH")
        unsetenv("CHRONOFRAME_REPOSITORY_ROOT")

        let outsideRoot = temporaryDirectoryURL.appendingPathComponent("outside", isDirectory: true)
        try? FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        FileManager.default.changeCurrentDirectoryPath(outsideRoot.path)

        let expected = RuntimePaths.applicationSupportDirectory().appendingPathComponent("profiles.yaml").path
        XCTAssertEqual(RuntimePaths.profilesFileURL().path, expected)
    }

    func testBackendRootScansUpwardFromCurrentDirectory() throws {
        unsetenv("CHRONOFRAME_REPOSITORY_ROOT")
        let repoRoot = temporaryDirectoryURL.appendingPathComponent("nested-repo", isDirectory: true)
        let packageDirectory = repoRoot.appendingPathComponent("chronoframe", isDirectory: true)
        let nestedWorkingDirectory = repoRoot.appendingPathComponent("a/b/c", isDirectory: true)

        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nestedWorkingDirectory, withIntermediateDirectories: true)
        try "".write(to: repoRoot.appendingPathComponent("chronoframe.py"), atomically: true, encoding: .utf8)
        FileManager.default.changeCurrentDirectoryPath(nestedWorkingDirectory.path)

        XCTAssertEqual(
            RuntimePaths.backendRootURL()?.resolvingSymlinksInPath().path,
            repoRoot.resolvingSymlinksInPath().path
        )
    }

    func testAppEnginePreferenceDefaultsToSwiftAndSupportsPythonKillSwitch() {
        unsetenv("CHRONOFRAME_APP_ENGINE")
        XCTAssertEqual(RuntimePaths.appEnginePreference(), .swift)

        setenv("CHRONOFRAME_APP_ENGINE", "python", 1)
        XCTAssertEqual(RuntimePaths.appEnginePreference(), .python)

        setenv("CHRONOFRAME_APP_ENGINE", "unexpected", 1)
        XCTAssertEqual(RuntimePaths.appEnginePreference(), .swift)
    }

    private func restoreEnvironment() {
        if let originalProfilesPath {
            setenv("CHRONOFRAME_PROFILES_PATH", originalProfilesPath, 1)
        } else {
            unsetenv("CHRONOFRAME_PROFILES_PATH")
        }

        if let originalRepositoryRoot {
            setenv("CHRONOFRAME_REPOSITORY_ROOT", originalRepositoryRoot, 1)
        } else {
            unsetenv("CHRONOFRAME_REPOSITORY_ROOT")
        }

        if let originalAppEngine {
            setenv("CHRONOFRAME_APP_ENGINE", originalAppEngine, 1)
        } else {
            unsetenv("CHRONOFRAME_APP_ENGINE")
        }
    }
}

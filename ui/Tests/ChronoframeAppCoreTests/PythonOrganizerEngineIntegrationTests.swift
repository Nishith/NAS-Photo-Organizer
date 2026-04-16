import Foundation
import XCTest
@testable import ChronoframeAppCore
@testable import ChronoframeCore

final class PythonOrganizerEngineIntegrationTests: XCTestCase {
    private var tempRootURL: URL!
    private var profilesURL: URL!
    private var originalProfilesPath: String?
    private var originalRepositoryRoot: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PythonOrganizerEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRootURL, withIntermediateDirectories: true)
        profilesURL = tempRootURL.appendingPathComponent("profiles.yaml")
        originalProfilesPath = ProcessInfo.processInfo.environment["CHRONOFRAME_PROFILES_PATH"]
        originalRepositoryRoot = ProcessInfo.processInfo.environment["CHRONOFRAME_REPOSITORY_ROOT"]

        setenv("CHRONOFRAME_PROFILES_PATH", profilesURL.path, 1)
        setenv("CHRONOFRAME_REPOSITORY_ROOT", Self.repositoryRootURL().path, 1)
    }

    override func tearDownWithError() throws {
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

        if let tempRootURL {
            try? FileManager.default.removeItem(at: tempRootURL)
        }
        tempRootURL = nil
        profilesURL = nil
        try super.tearDownWithError()
    }

    @MainActor
    func testPreflightResolvesProfileAndCountsPendingJobs() async throws {
        let sourceURL = tempRootURL.appendingPathComponent("source", isDirectory: true)
        let destinationURL = tempRootURL.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try """
        travel:
          source: "\(sourceURL.path)"
          dest: "\(destinationURL.path)"
        """.write(to: profilesURL, atomically: true, encoding: .utf8)
        try seedPendingJobsDatabase(at: destinationURL.appendingPathComponent(".organize_cache.db"), count: 3)

        let engine = PythonOrganizerEngine()
        let preflight = try await engine.preflight(
            RunConfiguration(
                mode: .transfer,
                profileName: "travel",
                useFastDestinationScan: true,
                verifyCopies: true,
                workerCount: 4
            )
        )

        XCTAssertEqual(preflight.configuration.sourcePath, sourceURL.path)
        XCTAssertEqual(preflight.configuration.destinationPath, destinationURL.path)
        XCTAssertEqual(preflight.configuration.profileName, "travel")
        XCTAssertEqual(preflight.pendingJobCount, 3)
        XCTAssertEqual(preflight.profilesFilePath, profilesURL.path)
        XCTAssertTrue(preflight.missingDependencies.isEmpty)
    }

    @MainActor
    func testPreflightThrowsWhenSourceIsMissing() async {
        let engine = PythonOrganizerEngine()
        let configuration = RunConfiguration(
            mode: .preview,
            sourcePath: tempRootURL.appendingPathComponent("missing-source").path,
            destinationPath: tempRootURL.appendingPathComponent("dest").path
        )

        do {
            _ = try await engine.preflight(configuration)
            XCTFail("Expected missing source error")
        } catch let error as OrganizerEngineError {
            guard case let .sourceDoesNotExist(path) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(path.contains("missing-source"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    @MainActor
    func testStartPreviewStreamsRealBackendEvents() async throws {
        let sourceURL = tempRootURL.appendingPathComponent("preview-source", isDirectory: true)
        let destinationURL = tempRootURL.appendingPathComponent("preview-dest", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let mediaURL = sourceURL.appendingPathComponent("VID_20240101_010101.mov")
        try Data("chronoframe".utf8).write(to: mediaURL)

        let engine = PythonOrganizerEngine()
        let stream = try engine.start(
            RunConfiguration(
                mode: .preview,
                sourcePath: sourceURL.path,
                destinationPath: destinationURL.path,
                useFastDestinationScan: true,
                verifyCopies: true,
                workerCount: 2
            )
        )

        var events: [RunEvent] = []
        for try await event in stream {
            events.append(event)
        }

        XCTAssertTrue(events.contains(where: {
            if case .startup = $0 { return true }
            return false
        }))
        XCTAssertTrue(events.contains(where: {
            if case let .copyPlanReady(count) = $0 { return count == 1 }
            return false
        }))

        guard let summary = events.compactMap({ event -> RunSummary? in
            if case let .complete(summary) = event {
                return summary
            }
            return nil
        }).last else {
            return XCTFail("Expected a completion summary")
        }

        XCTAssertEqual(summary.status, .dryRunFinished)
        XCTAssertEqual(summary.artifacts.destinationRoot, destinationURL.path)
        XCTAssertNotNil(summary.artifacts.reportPath)
    }

    private static func repositoryRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func seedPendingJobsDatabase(at url: URL, count: Int) throws {
        let database = try OrganizerDatabase(url: url)
        defer { database.close() }

        var jobs: [CopyJobRecord] = []
        for index in 0..<count {
            jobs.append(
                CopyJobRecord(
                    sourcePath: "/src/\(index)",
                    destinationPath: "/dst/\(index)",
                    identity: FileIdentity(size: Int64(index + 1), digest: "hash\(index)"),
                    status: .pending
                )
            )
        }
        try database.enqueueJobs(jobs)
    }
}

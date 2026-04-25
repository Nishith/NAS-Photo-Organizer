import Foundation
import XCTest
@testable import ChronoframeAppCore

final class SwiftOrganizerEngineIntegrationTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftOrganizerEngineIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        try super.tearDownWithError()
    }

    @MainActor
    func testPreflightResolvesProfileAndCountsPendingJobs() async throws {
        let sourceURL = temporaryDirectoryURL.appendingPathComponent("source", isDirectory: true)
        let destinationURL = temporaryDirectoryURL.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let database = try OrganizerDatabase(url: destinationURL.appendingPathComponent(".organize_cache.db"))
        try database.enqueueJobs([
            CopyJobRecord(
                sourcePath: "/tmp/a.jpg",
                destinationPath: "/tmp/b.jpg",
                identity: FileIdentity(size: 1, digest: "pending"),
                status: .pending
            )
        ])
        database.close()

        let repository = TestProfilesRepository(
            profiles: [
                Profile(name: "camera", sourcePath: sourceURL.path, destinationPath: destinationURL.path),
            ],
            profilesFileURL: temporaryDirectoryURL.appendingPathComponent("profiles.yaml")
        )
        let engine = SwiftOrganizerEngine(profilesRepository: repository)

        let preflight = try await engine.preflight(
            RunConfiguration(mode: .preview, profileName: "camera", useFastDestinationScan: true)
        )

        XCTAssertEqual(preflight.resolvedSourcePath, sourceURL.path)
        XCTAssertEqual(preflight.resolvedDestinationPath, destinationURL.path)
        XCTAssertEqual(preflight.pendingJobCount, 1)
        XCTAssertEqual(preflight.missingDependencies, [])
        XCTAssertEqual(preflight.profilesFilePath, repository.profilesFileURL().path)
    }

    @MainActor
    func testStartPreviewStreamsPlannerEventsAndWritesArtifacts() async throws {
        let sourceURL = temporaryDirectoryURL.appendingPathComponent("source", isDirectory: true)
        let destinationURL = temporaryDirectoryURL.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let fileURL = sourceURL.appendingPathComponent("camera/IMG_20240102_101010.jpg")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: fileURL)

        let engine = SwiftOrganizerEngine(
            profilesRepository: TestProfilesRepository(
                profiles: [],
                profilesFileURL: temporaryDirectoryURL.appendingPathComponent("profiles.yaml")
            )
        )

        let stream = try engine.start(
            RunConfiguration(
                mode: .preview,
                sourcePath: sourceURL.path,
                destinationPath: destinationURL.path,
                useFastDestinationScan: false
            )
        )
        let events = try await Self.collect(stream)

        // dest_hash and src_hash are streamed live from the planner during the walk;
        // discovery summary and classification are emitted after plan() returns.
        XCTAssertEqual(Self.render(events), [
            "startup",
            "phaseStarted:dest_hash",
            "phaseCompleted:dest_hash",
            "phaseStarted:src_hash",
            "phaseCompleted:src_hash",
            "phaseStarted:discovery",
            "phaseCompleted:discovery",
            "phaseStarted:classification",
            "phaseCompleted:classification",
            "copyPlanReady:1",
            "complete:dryRunFinished",
        ])

        guard case let .complete(summary)? = events.last else {
            return XCTFail("Expected complete event")
        }

        XCTAssertEqual(summary.metrics.discoveredCount, 1)
        XCTAssertEqual(summary.metrics.plannedCount, 1)
        XCTAssertEqual(summary.status, .dryRunFinished)
        XCTAssertEqual(summary.title, "Preview complete")
        XCTAssertEqual(summary.artifacts.destinationRoot, destinationURL.path)

        guard let reportPath = summary.artifacts.reportPath else {
            return XCTFail("Missing report path")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportPath))
        let reportContents = try String(contentsOfFile: reportPath, encoding: .utf8)
        XCTAssertTrue(reportContents.contains("Source,Destination,Hash,Status"))
        XCTAssertTrue(reportContents.contains(fileURL.path))
        XCTAssertTrue(reportContents.contains("PENDING"))

        XCTAssertEqual(
            summary.artifacts.logsDirectoryPath,
            destinationURL.appendingPathComponent(".organize_logs", isDirectory: true).path
        )
        XCTAssertEqual(
            summary.artifacts.logFilePath,
            destinationURL.appendingPathComponent(".organize_log.txt").path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: summary.artifacts.logFilePath ?? ""))
    }

    @MainActor
    func testStartTransferExecutesNativeCopyAndWritesExecutionArtifacts() async throws {
        let sourceURL = temporaryDirectoryURL.appendingPathComponent("source", isDirectory: true)
        let destinationURL = temporaryDirectoryURL.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let fileURL = sourceURL.appendingPathComponent("camera/IMG_20240102_101010.jpg")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: fileURL)

        let engine = SwiftOrganizerEngine(
            profilesRepository: TestProfilesRepository(
                profiles: [],
                profilesFileURL: temporaryDirectoryURL.appendingPathComponent("profiles.yaml")
            )
        )

        let stream = try engine.start(
            RunConfiguration(
                mode: .transfer,
                sourcePath: sourceURL.path,
                destinationPath: destinationURL.path,
                useFastDestinationScan: false
            )
        )
        let events = try await Self.collect(stream)

        XCTAssertEqual(Self.render(events), [
            "startup",
            "phaseStarted:dest_hash",
            "phaseCompleted:dest_hash",
            "phaseStarted:src_hash",
            "phaseCompleted:src_hash",
            "phaseStarted:discovery",
            "phaseCompleted:discovery",
            "phaseStarted:classification",
            "phaseCompleted:classification",
            "copyPlanReady:1",
            "phaseStarted:copy",
            "phaseProgress:copy:1/1",
            "phaseCompleted:copy",
            "complete:finished",
        ])

        guard case let .complete(summary)? = events.last else {
            return XCTFail("Expected completion summary")
        }

        XCTAssertEqual(summary.status, .finished)
        XCTAssertEqual(summary.title, "Done")
        XCTAssertEqual(summary.metrics.discoveredCount, 1)
        XCTAssertEqual(summary.metrics.plannedCount, 1)
        XCTAssertEqual(summary.metrics.copiedCount, 1)
        XCTAssertEqual(summary.metrics.failedCount, 0)

        let copiedFileURL = destinationURL.appendingPathComponent("2024/01/02/2024-01-02_001.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedFileURL.path))

        let copiedJobCount = try Self.withDatabaseWhenReady(at: destinationURL.appendingPathComponent(".organize_cache.db")) { database in
            try database.loadQueuedJobs(status: .copied).count
        }
        XCTAssertEqual(copiedJobCount, 1)

        let destinationCachePaths = try Self.withDatabaseWhenReady(
            at: destinationURL.appendingPathComponent(".organize_cache.db")
        ) { database in
            try database.loadRawCacheRecords(namespace: .destination).map(\.path)
        }
        XCTAssertEqual(destinationCachePaths, [copiedFileURL.path])

        let logsDirectoryPath = try XCTUnwrap(summary.artifacts.logsDirectoryPath)
        let logsDirectoryURL = URL(fileURLWithPath: logsDirectoryPath, isDirectory: true)
        let receipts = try FileManager.default.contentsOfDirectory(at: logsDirectoryURL, includingPropertiesForKeys: nil)
        XCTAssertEqual(receipts.filter { $0.lastPathComponent.hasPrefix("audit_receipt_") }.count, 1)

        let logContents = try String(
            contentsOfFile: try XCTUnwrap(summary.artifacts.logFilePath),
            encoding: .utf8
        )
        XCTAssertTrue(logContents.contains("Run complete"))
    }

    @MainActor
    func testResumeTransferUsesPersistedRawQueueAndEmitsCopyOnlyEvents() async throws {
        let sourceURL = temporaryDirectoryURL.appendingPathComponent("source", isDirectory: true)
        let destinationURL = temporaryDirectoryURL.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let fileURL = sourceURL.appendingPathComponent("incoming/photo.jpg")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("resume-data".utf8).write(to: fileURL)

        let database = try OrganizerDatabase(url: destinationURL.appendingPathComponent(".organize_cache.db"))
        try database.enqueueQueuedJobs([
            QueuedCopyJob(
                sourcePath: fileURL.path,
                destinationPath: destinationURL.appendingPathComponent("2023/06/15/2023-06-15_001.jpg").path,
                hash: "h1",
                status: .pending
            ),
        ])
        database.close()

        let engine = SwiftOrganizerEngine(
            profilesRepository: TestProfilesRepository(
                profiles: [],
                profilesFileURL: temporaryDirectoryURL.appendingPathComponent("profiles.yaml")
            )
        )

        let stream = try engine.resume(
            RunConfiguration(
                mode: .transfer,
                sourcePath: sourceURL.path,
                destinationPath: destinationURL.path,
                useFastDestinationScan: false
            )
        )
        let events = try await Self.collect(stream)

        XCTAssertEqual(Self.render(events), [
            "startup",
            "phaseStarted:copy",
            "phaseProgress:copy:1/1",
            "phaseCompleted:copy",
            "complete:finished",
        ])

        guard case let .complete(summary)? = events.last else {
            return XCTFail("Expected completion summary")
        }

        XCTAssertEqual(summary.status, .finished)
        XCTAssertEqual(summary.metrics.plannedCount, 1)
        XCTAssertEqual(summary.metrics.copiedCount, 1)
        XCTAssertEqual(summary.metrics.failedCount, 0)

        let resumedFileURL = destinationURL.appendingPathComponent("2023/06/15/2023-06-15_001.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: resumedFileURL.path))

        let resumedStatuses = try Self.withDatabaseWhenReady(at: destinationURL.appendingPathComponent(".organize_cache.db")) { database in
            try database.loadQueuedJobs().map(\.status)
        }
        XCTAssertEqual(resumedStatuses, [.copied])

        let resumedHashes = try Self.withDatabaseWhenReady(at: destinationURL.appendingPathComponent(".organize_cache.db")) { database in
            try database.loadRawCacheRecords(namespace: .destination).map(\.hash)
        }
        XCTAssertEqual(resumedHashes, ["h1"])

        let logContents = try String(
            contentsOfFile: try XCTUnwrap(summary.artifacts.logFilePath),
            encoding: .utf8
        )
        XCTAssertTrue(logContents.contains("Found 1 pending jobs from interrupted session"))
        XCTAssertTrue(logContents.contains("Resumed session complete"))
    }

    private static func collect(_ stream: AsyncThrowingStream<RunEvent, Error>) async throws -> [RunEvent] {
        var events: [RunEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    private static func withDatabaseWhenReady<T>(
        at url: URL,
        attempts: Int = 50,
        delayNanoseconds: UInt64 = 20_000_000,
        body: (OrganizerDatabase) throws -> T
    ) throws -> T {
        var lastError: Error?

        for attempt in 0..<attempts {
            do {
                let database = try OrganizerDatabase(url: url, readOnly: true)
                defer { database.close() }
                return try body(database)
            } catch {
                lastError = error
                if attempt + 1 < attempts {
                    Thread.sleep(forTimeInterval: TimeInterval(delayNanoseconds) / 1_000_000_000)
                }
            }
        }

        throw lastError ?? TestFailure.expectedFailure("Timed out waiting for database access")
    }

    private static func render(_ events: [RunEvent]) -> [String] {
        events.map {
            switch $0 {
            case .startup:
                return "startup"
            case let .phaseStarted(phase, _):
                return "phaseStarted:\(phase.rawValue)"
            case let .phaseCompleted(phase, _):
                return "phaseCompleted:\(phase.rawValue)"
            case let .copyPlanReady(count):
                return "copyPlanReady:\(count)"
            case let .complete(summary):
                return "complete:\(summary.status.rawValue)"
            case let .issue(issue):
                return "issue:\(issue.message)"
            case let .phaseProgress(phase, completed, total, _, _):
                return "phaseProgress:\(phase.rawValue):\(completed)/\(total)"
            case let .prompt(message):
                return "prompt:\(message)"
            case let .dateHistogram(buckets):
                return "dateHistogram:\(buckets.count)"
            }
        }
    }
}

extension SwiftOrganizerEngineIntegrationTests {
    @MainActor
    func testRevertStreamsProgressAndCompletesWithRevertedStatus() async throws {
        let destinationURL = temporaryDirectoryURL.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        // Drop a real file in the destination, hash it, and synthesize a receipt
        // that points at it with the matching hash.
        let photoURL = destinationURL.appendingPathComponent("2024/04/08/2024-04-08_001.HEIC", isDirectory: false)
        try FileManager.default.createDirectory(
            at: photoURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("photo-bytes".utf8).write(to: photoURL)
        let identity = try FileIdentityHasher().hashIdentity(at: photoURL)

        let receiptURL = destinationURL.appendingPathComponent("audit_receipt_test.json")
        let receiptJSON = """
        {
            "timestamp": "2026-04-24T10:00:00",
            "total_jobs": 1,
            "status": "COMPLETED",
            "transfers": [
                { "source": "/src/photo.HEIC", "dest": "\(photoURL.path)", "hash": "\(identity.rawValue)" }
            ]
        }
        """
        try Data(receiptJSON.utf8).write(to: receiptURL)

        let engine = SwiftOrganizerEngine(
            profilesRepository: TestProfilesRepository(profiles: [], profilesFileURL: temporaryDirectoryURL.appendingPathComponent("profiles.yaml"))
        )

        let stream = try engine.revert(receiptURL: receiptURL, destinationRoot: destinationURL.path)

        var sawStartup = false
        var sawPhaseStarted = false
        var sawPhaseProgress = false
        var sawPhaseCompleted = false
        var summary: RunSummary?

        for try await event in stream {
            switch event {
            case .startup: sawStartup = true
            case .phaseStarted(let phase, _) where phase == .revert: sawPhaseStarted = true
            case .phaseProgress(let phase, _, _, _, _) where phase == .revert: sawPhaseProgress = true
            case .phaseCompleted(let phase, _) where phase == .revert: sawPhaseCompleted = true
            case let .complete(s): summary = s
            default: break
            }
        }

        XCTAssertTrue(sawStartup)
        XCTAssertTrue(sawPhaseStarted)
        XCTAssertTrue(sawPhaseProgress)
        XCTAssertTrue(sawPhaseCompleted)
        XCTAssertEqual(summary?.status, .reverted)
        XCTAssertEqual(summary?.metrics.revertedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: photoURL.path))
    }

    @MainActor
    func testReorganizeStreamsMovesAndCompletesWithReorganizedStatus() async throws {
        let destinationURL = temporaryDirectoryURL.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        // Three flat files; reorganize → YYYY/MM/DD.
        for name in ["2024-04-08_001.HEIC", "2024-04-08_002.HEIC", "2024-04-09_001.HEIC"] {
            try Data("x".utf8).write(to: destinationURL.appendingPathComponent(name))
        }

        let engine = SwiftOrganizerEngine(
            profilesRepository: TestProfilesRepository(profiles: [], profilesFileURL: temporaryDirectoryURL.appendingPathComponent("profiles.yaml"))
        )

        let stream = try engine.reorganize(
            destinationRoot: destinationURL.path,
            targetStructure: .yyyyMMDD
        )

        var planReadyCount = 0
        var summary: RunSummary?
        var phaseProgressCount = 0
        for try await event in stream {
            switch event {
            case let .copyPlanReady(count): planReadyCount = count
            case .phaseProgress(let phase, _, _, _, _) where phase == .reorganize: phaseProgressCount += 1
            case let .complete(s): summary = s
            default: break
            }
        }

        XCTAssertEqual(planReadyCount, 3)
        XCTAssertEqual(phaseProgressCount, 3)
        XCTAssertEqual(summary?.status, .reorganized)
        XCTAssertEqual(summary?.metrics.movedCount, 3)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destinationURL.appendingPathComponent("2024/04/08/2024-04-08_001.HEIC").path
        ))
    }

    @MainActor
    func testReorganizeReportsNothingToReorganizeForAlreadyConformantLayout() async throws {
        let destinationURL = temporaryDirectoryURL.appendingPathComponent("dest", isDirectory: true)
        let nestedDir = destinationURL.appendingPathComponent("2024/04/08", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: nestedDir.appendingPathComponent("2024-04-08_001.HEIC"))

        let engine = SwiftOrganizerEngine(
            profilesRepository: TestProfilesRepository(profiles: [], profilesFileURL: temporaryDirectoryURL.appendingPathComponent("profiles.yaml"))
        )

        let stream = try engine.reorganize(
            destinationRoot: destinationURL.path,
            targetStructure: .yyyyMMDD
        )

        var summary: RunSummary?
        for try await event in stream {
            if case let .complete(s) = event { summary = s }
        }

        XCTAssertEqual(summary?.status, .nothingToReorganize)
        XCTAssertEqual(summary?.metrics.movedCount, 0)
    }

    @MainActor
    func testRevertThrowsForMissingReceipt() throws {
        let destinationURL = temporaryDirectoryURL.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        let missingReceipt = destinationURL.appendingPathComponent("does-not-exist.json")

        let engine = SwiftOrganizerEngine(
            profilesRepository: TestProfilesRepository(profiles: [], profilesFileURL: temporaryDirectoryURL.appendingPathComponent("profiles.yaml"))
        )

        XCTAssertThrowsError(try engine.revert(receiptURL: missingReceipt, destinationRoot: destinationURL.path))
    }
}

private final class TestProfilesRepository: ProfilesRepositorying {
    private var profiles: [Profile]
    private let storedProfilesFileURL: URL

    init(profiles: [Profile], profilesFileURL: URL) {
        self.profiles = profiles
        self.storedProfilesFileURL = profilesFileURL
    }

    func profilesFileURL() -> URL {
        storedProfilesFileURL
    }

    func loadProfiles() throws -> [Profile] {
        profiles
    }

    func save(profile: Profile) throws {
        profiles.removeAll { $0.name == profile.name }
        profiles.append(profile)
    }

    func deleteProfile(named name: String) throws {
        profiles.removeAll { $0.name == name }
    }
}

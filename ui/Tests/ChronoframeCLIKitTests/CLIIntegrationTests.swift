import ChronoframeCLIKit
import ChronoframeCore
import Foundation
import XCTest

final class CLIIntegrationTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var originalProfilesPath: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalProfilesPath = ProcessInfo.processInfo.environment["CHRONOFRAME_PROFILES_PATH"]
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let originalProfilesPath {
            setenv("CHRONOFRAME_PROFILES_PATH", originalProfilesPath, 1)
        } else {
            unsetenv("CHRONOFRAME_PROFILES_PATH")
        }
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    @MainActor
    func testDryRunJSONWritesReportAndCompleteArtifacts() async throws {
        let source = try makeDirectory("source")
        let destination = try makeDirectory("destination")
        let sourceFile = source.appendingPathComponent("camera/IMG_20240501_120000.jpg")
        try writeFile(sourceFile, contents: "dry-run")

        let recorder = LineRecorder()
        let exitCode = await ChronoframeCLI.run(
            arguments: [
                "--source", source.path,
                "--dest", destination.path,
                "--dry-run",
                "--json",
                "--workers", "1",
            ],
            output: recorder.append
        )

        XCTAssertEqual(exitCode, 0)
        let complete = try lastJSONPayload(ofType: "complete", in: recorder.lines)
        XCTAssertEqual(complete["status"] as? String, "dry_run_finished")

        let artifacts = try XCTUnwrap(complete["artifacts"] as? [String: Any])
        XCTAssertEqual(artifacts["destination"] as? String, destination.path)
        let reportPath = try XCTUnwrap(artifacts["report"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportPath))
        let report = try String(contentsOfFile: reportPath, encoding: .utf8)
        XCTAssertTrue(report.contains("Source,Destination,Hash,Status"))
        XCTAssertTrue(report.contains(sourceFile.path))
        XCTAssertTrue(report.contains("PENDING"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts["log"] as? String ?? ""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts["logs_directory"] as? String ?? ""))
    }

    @MainActor
    func testTransferCopiesByDefaultAndWritesReceipt() async throws {
        let source = try makeDirectory("source")
        let destination = try makeDirectory("destination")
        try writeFile(source.appendingPathComponent("camera/IMG_20240501_120000.jpg"), contents: "transfer")

        let recorder = LineRecorder()
        let exitCode = await ChronoframeCLI.run(
            arguments: [
                "--source", source.path,
                "--dest", destination.path,
                "--yes",
                "--workers", "1",
            ],
            output: recorder.append
        )

        XCTAssertEqual(exitCode, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("2024/05/01/2024-05-01_001.jpg").path
        ))

        let logsDirectory = destination.appendingPathComponent(".organize_logs", isDirectory: true)
        let receiptURLs = try FileManager.default.contentsOfDirectory(at: logsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("audit_receipt_") && $0.pathExtension == "json" }
        XCTAssertEqual(receiptURLs.count, 1)
        let receiptData = try Data(contentsOf: receiptURLs[0])
        let receipt = try JSONSerialization.jsonObject(with: receiptData) as? [String: Any]
        XCTAssertEqual(receipt?["status"] as? String, "COMPLETED")
        XCTAssertEqual(receipt?["total_jobs"] as? Int, 1)
    }

    @MainActor
    func testProfileResolutionUsesProfilesPathEnvironmentOverride() async throws {
        let source = try makeDirectory("profile-source")
        let destination = try makeDirectory("profile-destination")
        try writeFile(source.appendingPathComponent("IMG_20240602_080000.jpg"), contents: "profile")

        let profilesURL = temporaryDirectory.appendingPathComponent("profiles.yaml")
        try """
        camera:
          source: "\(source.path)"
          dest: "\(destination.path)"

        """.write(to: profilesURL, atomically: true, encoding: .utf8)
        setenv("CHRONOFRAME_PROFILES_PATH", profilesURL.path, 1)

        let recorder = LineRecorder()
        let exitCode = await ChronoframeCLI.run(
            arguments: ["--profile", "camera", "--dry-run", "--json", "--workers", "1"],
            output: recorder.append
        )

        XCTAssertEqual(exitCode, 0)
        let complete = try lastJSONPayload(ofType: "complete", in: recorder.lines)
        let artifacts = try XCTUnwrap(complete["artifacts"] as? [String: Any])
        XCTAssertEqual(artifacts["destination"] as? String, destination.path)
    }

    @MainActor
    func testAssumeYesResumesPendingQueue() async throws {
        let source = try makeDirectory("source")
        let destination = try makeDirectory("destination")
        let sourceFile = source.appendingPathComponent("incoming/photo.jpg")
        try writeFile(sourceFile, contents: "resume")
        let identity = try FileIdentityHasher().hashIdentity(at: sourceFile)

        let resumedDestination = destination.appendingPathComponent("2024/05/03/2024-05-03_001.jpg")
        let database = try OrganizerDatabase(url: destination.appendingPathComponent(".organize_cache.db"))
        try database.enqueueQueuedJobs([
            QueuedCopyJob(
                sourcePath: sourceFile.path,
                destinationPath: resumedDestination.path,
                hash: identity.rawValue,
                status: .pending
            ),
        ])
        database.close()

        let recorder = LineRecorder()
        let exitCode = await ChronoframeCLI.run(
            arguments: ["--source", source.path, "--dest", destination.path, "--yes", "--json", "--workers", "1"],
            output: recorder.append
        )

        XCTAssertEqual(exitCode, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resumedDestination.path))
        let complete = try lastJSONPayload(ofType: "complete", in: recorder.lines)
        let metrics = try XCTUnwrap(complete["metrics"] as? [String: Any])
        XCTAssertEqual(metrics["planned"] as? Int, 1)
        XCTAssertEqual(metrics["copied"] as? Int, 1)
    }

    @MainActor
    func testStartFreshClearsPendingQueueAndReplans() async throws {
        let source = try makeDirectory("source")
        let destination = try makeDirectory("destination")
        let sourceFile = source.appendingPathComponent("IMG_20240704_090000.jpg")
        try writeFile(sourceFile, contents: "fresh")

        let staleSource = temporaryDirectory.appendingPathComponent("stale.jpg")
        try writeFile(staleSource, contents: "stale")
        let staleIdentity = try FileIdentityHasher().hashIdentity(at: staleSource)
        let staleDestination = destination.appendingPathComponent("stale/should-not-copy.jpg")
        let database = try OrganizerDatabase(url: destination.appendingPathComponent(".organize_cache.db"))
        try database.enqueueQueuedJobs([
            QueuedCopyJob(
                sourcePath: staleSource.path,
                destinationPath: staleDestination.path,
                hash: staleIdentity.rawValue,
                status: .pending
            ),
        ])
        database.close()

        let recorder = LineRecorder()
        let exitCode = await ChronoframeCLI.run(
            arguments: [
                "--source", source.path,
                "--dest", destination.path,
                "--yes",
                "--start-fresh",
                "--json",
                "--workers", "1",
            ],
            output: recorder.append
        )

        XCTAssertEqual(exitCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleDestination.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("2024/07/04/2024-07-04_001.jpg").path
        ))

        let copiedJobs = try withDatabase(at: destination.appendingPathComponent(".organize_cache.db")) { database in
            try database.loadQueuedJobs(status: .copied).map(\.sourcePath)
        }
        XCTAssertEqual(copiedJobs.map(resolvedPath), [resolvedPath(sourceFile.path)])
    }

    @MainActor
    func testRevertAcceptsArbitraryReceiptPathWithDestinationOverride() async throws {
        let destination = try makeDirectory("destination")
        let copiedFile = destination.appendingPathComponent("2024/08/05/2024-08-05_001.jpg")
        try writeFile(copiedFile, contents: "copied")
        let identity = try FileIdentityHasher().hashIdentity(at: copiedFile)
        let receipt = RevertReceipt(
            timestamp: "2026-05-16T12:00:00",
            status: "COMPLETED",
            totalJobs: 1,
            transfers: [
                RevertReceiptTransfer(source: "/source/photo.jpg", dest: copiedFile.path, hash: identity.rawValue),
            ]
        )
        let receiptURL = temporaryDirectory.appendingPathComponent("moved-receipt.json")
        try JSONEncoder().encode(receipt).write(to: receiptURL)

        let recorder = LineRecorder()
        let exitCode = await ChronoframeCLI.run(
            arguments: ["--revert", receiptURL.path, "--dest", destination.path, "--json"],
            output: recorder.append
        )

        XCTAssertEqual(exitCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copiedFile.path))
        let complete = try lastJSONPayload(ofType: "complete", in: recorder.lines)
        XCTAssertEqual(complete["status"] as? String, "reverted")
        let metrics = try XCTUnwrap(complete["metrics"] as? [String: Any])
        XCTAssertEqual(metrics["reverted"] as? Int, 1)
    }

    @MainActor
    func testRebuildCacheClearsStaleRowsAndPreservesQueuedJobs() async throws {
        let source = try makeDirectory("source")
        let destination = try makeDirectory("destination")
        let sourceFile = source.appendingPathComponent("IMG_20240906_100000.jpg")
        try writeFile(sourceFile, contents: "rebuild")

        let databaseURL = destination.appendingPathComponent(".organize_cache.db")
        let database = try OrganizerDatabase(url: databaseURL)
        try database.saveRawCacheRecords([
            RawFileCacheRecord(namespace: .source, path: "/stale/source.jpg", hash: "1_stale", size: 1, modificationTime: 1),
            RawFileCacheRecord(namespace: .destination, path: "/stale/dest.jpg", hash: "1_stale", size: 1, modificationTime: 1),
        ])
        try database.enqueueQueuedJobs([
            QueuedCopyJob(sourcePath: "/queued/source.jpg", destinationPath: "/queued/dest.jpg", hash: "1_queued", status: .pending),
        ])
        database.close()

        let recorder = LineRecorder()
        let exitCode = await ChronoframeCLI.run(
            arguments: [
                "--source", source.path,
                "--dest", destination.path,
                "--dry-run",
                "--rebuild-cache",
                "--json",
                "--workers", "1",
            ],
            output: recorder.append
        )

        XCTAssertEqual(exitCode, 0)
        let cacheRows = try withDatabase(at: databaseURL) { database in
            try database.loadRawCacheRecords(namespace: .source) + database.loadRawCacheRecords(namespace: .destination)
        }
        XCTAssertFalse(cacheRows.contains { $0.path == "/stale/source.jpg" || $0.path == "/stale/dest.jpg" })
        XCTAssertTrue(cacheRows.contains { resolvedPath($0.path) == resolvedPath(sourceFile.path) })
        let pendingCount = try withDatabase(at: databaseURL) { database in
            try database.pendingJobCount()
        }
        XCTAssertEqual(pendingCount, 1)
    }

    /// Regression for PHASE2_FINDINGS.md NEW2 — when `--json` is set
    /// without `--yes`, the CLI used to write a human-language prompt
    /// onto stdout (corrupting any pipeline consumer) and then block
    /// indefinitely on stdin. The fix turns this into a fast usage
    /// error (exit 2) before any prompt is written.
    @MainActor
    func testJSONWithoutAssumeYesFailsFastInsteadOfHangingOnAPrompt() async throws {
        let source = try makeDirectory("json-no-yes-source")
        let destination = try makeDirectory("json-no-yes-dest")
        try writeFile(source.appendingPathComponent("camera/IMG_20240501_120000.jpg"), contents: "no-yes")

        let recorder = LineRecorder()
        // `input` must NOT be invoked. If the fix regressed and the CLI
        // tried to prompt, the test would deadlock — fail it deterministically.
        let exitCode = await ChronoframeCLI.run(
            arguments: [
                "--source", source.path,
                "--dest", destination.path,
                "--json",
                "--workers", "1",
            ],
            output: recorder.append,
            input: {
                XCTFail("CLI must not read stdin when --json is set without --yes")
                return nil
            }
        )
        XCTAssertEqual(exitCode, 2, "Usage errors must exit 2, not 0 or 1")
        let joined = recorder.lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("--json"), "Error message should reference --json")
        XCTAssertTrue(joined.contains("--yes"), "Error message should reference --yes")
        XCTAssertFalse(joined.contains("Resume them?"),
            "Stdout must NOT contain a human-language prompt")
        XCTAssertFalse(joined.contains("Continue?"),
            "Stdout must NOT contain a human-language prompt")
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeFile(_ url: URL, contents: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func lastJSONPayload(ofType type: String, in lines: [String]) throws -> [String: Any] {
        let payloads = try lines.map { line -> [String: Any] in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        return try XCTUnwrap(payloads.last { $0["type"] as? String == type })
    }

    private func withDatabase<T>(at url: URL, _ body: (OrganizerDatabase) throws -> T) throws -> T {
        let database = try OrganizerDatabase(url: url)
        defer { database.close() }
        return try body(database)
    }

    private func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

private final class LineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }
}

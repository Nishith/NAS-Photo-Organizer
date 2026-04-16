import Foundation
import XCTest
@testable import ChronoframeCore

final class ChronoframeCoreTransferExecutorParityTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChronoframeCoreTransferExecutorParityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        try super.tearDownWithError()
    }

    func testExecutionFixturesMatchPythonGoldenOutputs() throws {
        for scenario in [
            "execution_collision_receipt",
            "execution_missing_source_abort",
            "execution_verify_cleanup",
        ] {
            try assertScenario(named: scenario)
        }
    }

    private func assertScenario(named scenario: String) throws {
        let scenarioRoot = fixtureRoot.appendingPathComponent(scenario, isDirectory: true)
        let manifest = try decode(ExecutionManifest.self, from: scenarioRoot.appendingPathComponent("manifest.json"))
        let expected = try decode(ExecutionExpectedOutput.self, from: scenarioRoot.appendingPathComponent("expected.json"))

        let scenarioTempRoot = temporaryDirectoryURL.appendingPathComponent(scenario, isDirectory: true)
        let sourceRoot = scenarioTempRoot.appendingPathComponent("source", isDirectory: true)
        let destinationRoot = scenarioTempRoot.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        for file in manifest.files {
            let root = file.root == "source" ? sourceRoot : destinationRoot
            let fileURL = root.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((file.contentText ?? "").utf8).write(to: fileURL)

            if let mtimeEpoch = file.mtimeEpoch {
                let timestamp = Date(timeIntervalSince1970: mtimeEpoch)
                try FileManager.default.setAttributes(
                    [.modificationDate: timestamp, .creationDate: timestamp],
                    ofItemAtPath: fileURL.path
                )
            }
        }

        let databaseURL = destinationRoot.appendingPathComponent(EngineArtifactLayout.pythonReference.queueDatabaseFilename)
        let database = try OrganizerDatabase(url: databaseURL)
        defer { database.close() }

        var seededJobs: [QueuedCopyJob] = []
        for job in manifest.seedCopyJobs {
            seededJobs.append(
                QueuedCopyJob(
                    sourcePath: resolveFixturePath(job.source, sourceRoot: sourceRoot, destinationRoot: destinationRoot).path,
                    destinationPath: resolveFixturePath(job.destination, sourceRoot: sourceRoot, destinationRoot: destinationRoot).path,
                    hash: try resolveHash(job.hash, sourceRoot: sourceRoot, destinationRoot: destinationRoot),
                    status: CopyJobStatus(rawValue: job.status) ?? .pending
                )
            )
        }
        try database.enqueueQueuedJobs(seededJobs)

        let logger = PersistentRunLogger(
            logURL: destinationRoot.appendingPathComponent(EngineArtifactLayout.pythonReference.runLogFilename)
        )
        try logger.open()
        defer { logger.close() }

        let queuedJobs = try database.loadQueuedJobs(status: .pending, orderByInsertion: true)
        _ = try TransferExecutor().execute(
            queuedJobs: queuedJobs,
            database: database,
            destinationRoot: destinationRoot,
            verifyCopies: manifest.verify,
            runLogger: logger
        )

        XCTAssertEqual(
            normalizeQueueRows(try database.loadQueuedJobs(), sourceRoot: sourceRoot, destinationRoot: destinationRoot),
            expected.queueRows,
            scenario
        )
        XCTAssertEqual(
            normalizeCacheRows(
                try database.loadRawCacheRecords(namespace: .destination),
                sourceRoot: sourceRoot,
                destinationRoot: destinationRoot
            ),
            expected.destinationCacheRows,
            scenario
        )
        XCTAssertEqual(listDestinationFiles(destinationRoot: destinationRoot, sourceRoot: sourceRoot), expected.destinationFiles, scenario)
        XCTAssertEqual(readAuditReceipt(destinationRoot: destinationRoot, sourceRoot: sourceRoot), expected.auditReceipt, scenario)
        XCTAssertEqual(loadLogMarkers(destinationRoot: destinationRoot, markers: manifest.logMarkers), expected.logMarkers, scenario)
    }

    private func resolveHash(
        _ spec: String,
        sourceRoot: URL,
        destinationRoot: URL
    ) throws -> String {
        if spec.hasPrefix("actual:") {
            let resolvedPath = resolveFixturePath(
                String(spec.dropFirst("actual:".count)),
                sourceRoot: sourceRoot,
                destinationRoot: destinationRoot
            )
            return try FileIdentityHasher().hashIdentity(at: resolvedPath).rawValue
        }

        return spec
    }

    private func resolveFixturePath(_ spec: String, sourceRoot: URL, destinationRoot: URL) -> URL {
        if spec.hasPrefix("source/") {
            return sourceRoot.appendingPathComponent(String(spec.dropFirst("source/".count)))
        }
        if spec.hasPrefix("dest/") {
            return destinationRoot.appendingPathComponent(String(spec.dropFirst("dest/".count)))
        }
        return destinationRoot.appendingPathComponent(spec)
    }

    private func normalizeQueueRows(
        _ rows: [QueuedCopyJob],
        sourceRoot: URL,
        destinationRoot: URL
    ) -> [ExecutionQueueRow] {
        rows
            .map {
                ExecutionQueueRow(
                    source: normalizePath($0.sourcePath, sourceRoot: sourceRoot, destinationRoot: destinationRoot),
                    destination: normalizePath($0.destinationPath, sourceRoot: sourceRoot, destinationRoot: destinationRoot),
                    hash: $0.hash,
                    status: $0.status.rawValue
                )
            }
            .sorted {
                ($0.source, $0.destination) < ($1.source, $1.destination)
            }
    }

    private func normalizeCacheRows(
        _ rows: [RawFileCacheRecord],
        sourceRoot: URL,
        destinationRoot: URL
    ) -> [ExecutionDestinationCacheRow] {
        rows
            .map {
                ExecutionDestinationCacheRow(
                    path: normalizePath($0.path, sourceRoot: sourceRoot, destinationRoot: destinationRoot),
                    hash: $0.hash,
                    size: $0.size
                )
            }
            .sorted { $0.path < $1.path }
    }

    private func listDestinationFiles(destinationRoot: URL, sourceRoot: URL) -> [String] {
        let enumerator = FileManager.default.enumerator(
            at: destinationRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var files: [String] = []
        while let nextObject = enumerator?.nextObject() as? URL {
            guard !nextObject.path.contains("/.organize") else {
                continue
            }
            var isRegularFile: AnyObject?
            try? (nextObject as NSURL).getResourceValue(&isRegularFile, forKey: .isRegularFileKey)
            guard (isRegularFile as? Bool) == true else {
                continue
            }
            files.append(normalizePath(nextObject.path, sourceRoot: sourceRoot, destinationRoot: destinationRoot))
        }

        return files.sorted()
    }

    private func readAuditReceipt(destinationRoot: URL, sourceRoot: URL) -> ExecutionAuditReceipt {
        let receipts = (try? FileManager.default.contentsOfDirectory(
            at: destinationRoot.appendingPathComponent(".organize_logs", isDirectory: true),
            includingPropertiesForKeys: nil
        )) ?? []
        let receiptURL = receipts
            .filter { $0.lastPathComponent.hasPrefix("audit_receipt_") && $0.pathExtension == "json" }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .last

        guard
            let receiptURL,
            let data = try? Data(contentsOf: receiptURL),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ExecutionAuditReceipt(present: false, totalJobs: 0, status: nil, transfers: [])
        }

        let transfers = (payload["transfers"] as? [[String: Any]] ?? []).map {
            ExecutionTransferRow(
                source: normalizePath($0["source"] as? String ?? "", sourceRoot: sourceRoot, destinationRoot: destinationRoot),
                destination: normalizePath($0["dest"] as? String ?? "", sourceRoot: sourceRoot, destinationRoot: destinationRoot),
                hash: $0["hash"] as? String ?? ""
            )
        }

        return ExecutionAuditReceipt(
            present: true,
            totalJobs: payload["total_jobs"] as? Int ?? 0,
            status: payload["status"] as? String,
            transfers: transfers
        )
    }

    private func loadLogMarkers(destinationRoot: URL, markers: [String]) -> [String: Bool] {
        let logURL = destinationRoot.appendingPathComponent(".organize_log.txt")
        let contents = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let strippedContents = contents
            .split(separator: "\n")
            .map { stripTimestampPrefix(String($0)) }
            .joined(separator: "\n")

        return Dictionary(uniqueKeysWithValues: markers.map { ($0, strippedContents.contains($0)) })
    }

    private func stripTimestampPrefix(_ line: String) -> String {
        line.replacingOccurrences(
            of: #"^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] "#,
            with: "",
            options: .regularExpression
        )
    }

    private func normalizePath(_ path: String, sourceRoot: URL, destinationRoot: URL) -> String {
        let resolvedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let sourcePrefix = sourceRoot.standardizedFileURL.path + "/"
        if resolvedPath.hasPrefix(sourcePrefix) {
            return "source/" + String(resolvedPath.dropFirst(sourcePrefix.count))
        }

        let destinationPrefix = destinationRoot.standardizedFileURL.path + "/"
        if resolvedPath.hasPrefix(destinationPrefix) {
            return "dest/" + String(resolvedPath.dropFirst(destinationPrefix.count))
        }

        return path
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(type, from: data)
    }

    // MARK: - Crash recovery: resume from PENDING jobs

    /// Simulates a mid-run crash by cancelling execution after the first job, then
    /// verifies that re-running against the same DB completes the remaining jobs.
    func testResumePendingJobsAfterSimulatedCrash() throws {
        let sourceDir = temporaryDirectoryURL.appendingPathComponent("resume_source", isDirectory: true)
        let destDir   = temporaryDirectoryURL.appendingPathComponent("resume_dest",   isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir,   withIntermediateDirectories: true)

        // Create 3 small source files.
        var sourceURLs: [URL] = []
        for i in 1...3 {
            let url = sourceDir.appendingPathComponent("photo_\(i).jpg")
            try Data("content \(i)".utf8).write(to: url)
            sourceURLs.append(url)
        }

        let databaseURL = destDir.appendingPathComponent(".organize_cache.db")
        let database = try OrganizerDatabase(url: databaseURL)
        defer { database.close() }

        // Seed all three jobs as PENDING.
        let jobs = try sourceURLs.map { src -> QueuedCopyJob in
            let hash = try FileIdentityHasher().hashIdentity(at: src).rawValue
            let dest = destDir.appendingPathComponent("2024/01/01/\(src.lastPathComponent)")
            return QueuedCopyJob(sourcePath: src.path, destinationPath: dest.path, hash: hash, status: .pending)
        }
        try database.enqueueQueuedJobs(jobs)

        let logger = PersistentRunLogger(
            logURL: destDir.appendingPathComponent(".organize_log.txt")
        )
        try logger.open()
        defer { logger.close() }

        // First execution: cancel after the first successfully copied job.
        // Using a Sendable class-based counter because `isCancelled` is @Sendable.
        let cancelAfterFirst = CancelAfterFirstJob()
        _ = try TransferExecutor().executeQueuedJobs(
            database: database,
            destinationRoot: destDir,
            verifyCopies: false,
            runLogger: logger,
            status: .pending,
            orderByInsertion: true,
            isCancelled: { cancelAfterFirst.shouldCancel() }
        )

        // At least 1 job should be COPIED and at least 1 should still be PENDING.
        let afterFirst = try database.loadQueuedJobs()
        let copiedAfterFirst  = afterFirst.filter { $0.status == .copied  }.count
        let pendingAfterFirst = afterFirst.filter { $0.status == .pending }.count
        XCTAssertGreaterThanOrEqual(copiedAfterFirst,  1, "At least one job should be copied before cancellation")
        XCTAssertGreaterThanOrEqual(pendingAfterFirst, 1, "At least one job should remain pending after cancellation")

        // Second execution: resume remaining PENDING jobs.
        _ = try TransferExecutor().executeQueuedJobs(
            database: database,
            destinationRoot: destDir,
            verifyCopies: false,
            runLogger: logger,
            status: .pending,
            orderByInsertion: true
        )

        // All 3 jobs should now be COPIED and 0 PENDING.
        let afterResume = try database.loadQueuedJobs()
        XCTAssertEqual(afterResume.filter { $0.status == .copied  }.count, 3, "All jobs should be copied after resume")
        XCTAssertEqual(afterResume.filter { $0.status == .pending }.count, 0, "No pending jobs should remain after resume")
        XCTAssertEqual(afterResume.filter { $0.status == .failed  }.count, 0, "No jobs should have failed")

        // All destination files should exist on disk.
        for job in afterResume {
            XCTAssertTrue(FileManager.default.fileExists(atPath: job.destinationPath),
                          "Destination file should exist: \(job.destinationPath)")
        }
    }

    private var fixtureRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures/parity", isDirectory: true)
    }
}

/// Sendable counter used by the crash-recovery test. Cancels after the first
/// poll returns false (i.e. after the first job is processed).
private final class CancelAfterFirstJob: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func shouldCancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return calls > 1
    }
}

private struct ExecutionManifest: Decodable {
    var verify: Bool
    var files: [ExecutionFixtureFile]
    var seedCopyJobs: [ExecutionSeedJob]
    var logMarkers: [String]

    private enum CodingKeys: String, CodingKey {
        case verify
        case files
        case seedCopyJobs = "seed_copy_jobs"
        case logMarkers = "log_markers"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        verify = try container.decodeIfPresent(Bool.self, forKey: .verify) ?? false
        files = try container.decodeIfPresent([ExecutionFixtureFile].self, forKey: .files) ?? []
        seedCopyJobs = try container.decodeIfPresent([ExecutionSeedJob].self, forKey: .seedCopyJobs) ?? []
        logMarkers = try container.decodeIfPresent([String].self, forKey: .logMarkers) ?? []
    }
}

private struct ExecutionFixtureFile: Decodable {
    var root: String
    var path: String
    var contentText: String?
    var mtimeEpoch: Double?

    private enum CodingKeys: String, CodingKey {
        case root
        case path
        case contentText = "content_text"
        case mtimeEpoch = "mtime_epoch"
    }
}

private struct ExecutionSeedJob: Decodable {
    var source: String
    var destination: String
    var hash: String
    var status: String

    private enum CodingKeys: String, CodingKey {
        case source = "src"
        case destination = "dst"
        case hash
        case status
    }
}

private struct ExecutionExpectedOutput: Decodable, Equatable {
    var queueRows: [ExecutionQueueRow]
    var destinationCacheRows: [ExecutionDestinationCacheRow]
    var destinationFiles: [String]
    var auditReceipt: ExecutionAuditReceipt
    var logMarkers: [String: Bool]

    private enum CodingKeys: String, CodingKey {
        case queueRows = "queue_rows"
        case destinationCacheRows = "dest_cache_rows"
        case destinationFiles = "dest_files"
        case auditReceipt = "audit_receipt"
        case logMarkers = "log_markers"
    }
}

private struct ExecutionQueueRow: Decodable, Equatable {
    var source: String
    var destination: String
    var hash: String
    var status: String

    private enum CodingKeys: String, CodingKey {
        case source = "src"
        case destination = "dst"
        case hash
        case status
    }
}

private struct ExecutionDestinationCacheRow: Decodable, Equatable {
    var path: String
    var hash: String
    var size: Int64
}

private struct ExecutionAuditReceipt: Decodable, Equatable {
    var present: Bool
    var totalJobs: Int
    var status: String?
    var transfers: [ExecutionTransferRow]

    private enum CodingKeys: String, CodingKey {
        case present
        case totalJobs = "total_jobs"
        case status
        case transfers
    }
}

private struct ExecutionTransferRow: Decodable, Equatable {
    var source: String
    var destination: String
    var hash: String

    private enum CodingKeys: String, CodingKey {
        case source
        case destination = "dest"
        case hash
    }
}

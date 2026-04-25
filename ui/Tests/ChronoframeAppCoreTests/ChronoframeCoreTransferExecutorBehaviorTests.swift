import Foundation
import XCTest
@testable import ChronoframeCore

/// Behavioral coverage for `TransferExecutor` that complements the golden-fixture
/// parity tests. These tests target individual responsibilities of the executor —
/// atomic copy lifecycle, failure-threshold abort, byte tracking, verify cleanup,
/// orphan `.tmp` cleanup, audit receipt structure, and retry-policy data shape —
/// so that the Python reference implementation can eventually be retired without
/// loss of confidence.
final class ChronoframeCoreTransferExecutorBehaviorTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ChronoframeCoreTransferExecutorBehaviorTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        try super.tearDownWithError()
    }

    // MARK: - Atomic copy & .tmp lifecycle

    /// A successful run must leave behind real destination files and zero `.tmp`
    /// stragglers — the staging file must always be renamed or removed.
    func testSuccessfulCopyLeavesNoTemporaryFiles() throws {
        let env = try makeEnvironment(jobCount: 3)
        _ = try TransferExecutor().execute(
            queuedJobs: env.jobs,
            database: env.database,
            destinationRoot: env.destinationRoot,
            verifyCopies: false,
            runLogger: env.logger
        )

        for job in env.jobs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: job.destinationPath))
            XCTAssertFalse(FileManager.default.fileExists(atPath: job.destinationPath + ".tmp"))
        }
    }

    /// Copies whose source path doesn't exist must fail without leaving an
    /// orphaned `.tmp` file in the destination directory.
    func testFailedCopyCleansUpTemporaryFile() throws {
        let destinationRoot = temporaryDirectoryURL.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let database = try OrganizerDatabase(url: destinationRoot.appendingPathComponent(".organize_cache.db"))
        defer { database.close() }

        let bogusSource = temporaryDirectoryURL.appendingPathComponent("does_not_exist.jpg").path
        let plannedDestination = destinationRoot.appendingPathComponent("2024/01/01/photo.jpg").path
        let job = QueuedCopyJob(
            sourcePath: bogusSource,
            destinationPath: plannedDestination,
            hash: "0_missing",
            status: .pending
        )
        try database.enqueueQueuedJobs([job])

        let logger = PersistentRunLogger(logURL: destinationRoot.appendingPathComponent(".organize_log.txt"))
        try logger.open()
        defer { logger.close() }

        let result = try TransferExecutor().execute(
            queuedJobs: [job],
            database: database,
            destinationRoot: destinationRoot,
            verifyCopies: false,
            runLogger: logger
        )

        XCTAssertEqual(result.copiedCount, 0)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plannedDestination + ".tmp"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plannedDestination))
    }

    /// When the requested destination already holds a different file, the
    /// executor must keep the existing file and route the new copy to a
    /// `_collision_N` suffix.
    func testCopyAppliesCollisionSuffixWhenDestinationExists() throws {
        let env = try makeEnvironment(jobCount: 1)
        let job = env.jobs[0]
        let preexisting = "preexisting bytes"
        let destinationURL = URL(fileURLWithPath: job.destinationPath)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(preexisting.utf8).write(to: destinationURL)

        let result = try TransferExecutor().execute(
            queuedJobs: [job],
            database: env.database,
            destinationRoot: env.destinationRoot,
            verifyCopies: false,
            runLogger: env.logger
        )

        XCTAssertEqual(result.copiedCount, 1)
        let preserved = try String(contentsOfFile: job.destinationPath, encoding: .utf8)
        XCTAssertEqual(preserved, preexisting)

        let directory = URL(fileURLWithPath: job.destinationPath).deletingLastPathComponent()
        let neighbours = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(
            neighbours.contains(where: { $0.contains("_collision_") }),
            "expected a _collision_ neighbour next to \(job.destinationPath); found \(neighbours)"
        )
    }

    // MARK: - cleanupTemporaryFiles

    /// Pre-existing `.tmp` files from a previous interrupted run should be
    /// removed by `cleanupTemporaryFiles`, while real files stay intact.
    func testCleanupTemporaryFilesRemovesOrphansAndPreservesRealFiles() throws {
        let destinationRoot = temporaryDirectoryURL.appendingPathComponent("cleanup", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationRoot.appendingPathComponent("2024/01/01"),
            withIntermediateDirectories: true
        )

        let realFile = destinationRoot.appendingPathComponent("2024/01/01/keeper.jpg")
        let orphan1 = destinationRoot.appendingPathComponent("2024/01/01/orphan.jpg.tmp")
        let orphan2 = destinationRoot.appendingPathComponent("2024/01/01/another.mov.tmp")
        try Data("real".utf8).write(to: realFile)
        try Data("orphan1".utf8).write(to: orphan1)
        try Data("orphan2".utf8).write(to: orphan2)

        let cleaned = TransferExecutor().cleanupTemporaryFiles(at: destinationRoot)

        XCTAssertEqual(cleaned, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: realFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan1.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan2.path))
    }

    func testCleanupTemporaryFilesReturnsZeroForCleanDestination() throws {
        let destinationRoot = temporaryDirectoryURL.appendingPathComponent("clean", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let realFile = destinationRoot.appendingPathComponent("photo.jpg")
        try Data("bytes".utf8).write(to: realFile)

        XCTAssertEqual(TransferExecutor().cleanupTemporaryFiles(at: destinationRoot), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: realFile.path))
    }

    // MARK: - Failure thresholds

    /// A run of repeated failures must abort once the configured *consecutive*
    /// limit is hit, even if the *total* limit is far higher. The remaining
    /// jobs in the queue must stay PENDING so the user can retry.
    func testRunAbortsAfterConsecutiveFailureThreshold() throws {
        let destinationRoot = temporaryDirectoryURL.appendingPathComponent("consecutive", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let database = try OrganizerDatabase(url: destinationRoot.appendingPathComponent(".organize_cache.db"))
        defer { database.close() }

        // 5 jobs with non-existent sources → every copy will fail with ENOENT.
        let jobs: [QueuedCopyJob] = (0..<5).map { index in
            QueuedCopyJob(
                sourcePath: temporaryDirectoryURL.appendingPathComponent("missing_\(index).jpg").path,
                destinationPath: destinationRoot.appendingPathComponent("2024/01/01/file_\(index).jpg").path,
                hash: "0_missing_\(index)",
                status: .pending
            )
        }
        try database.enqueueQueuedJobs(jobs)

        let logger = PersistentRunLogger(logURL: destinationRoot.appendingPathComponent(".organize_log.txt"))
        try logger.open()
        defer { logger.close() }

        let executor = TransferExecutor(
            failureThresholds: FailureThresholds(consecutive: 2, total: 100)
        )
        let result = try executor.execute(
            queuedJobs: jobs,
            database: database,
            destinationRoot: destinationRoot,
            verifyCopies: false,
            runLogger: logger
        )

        XCTAssertEqual(result.copiedCount, 0)
        XCTAssertEqual(result.failedCount, 2, "executor must stop processing once consecutive=2 is reached")

        let queueAfterAbort = try database.loadQueuedJobs(orderByInsertion: true)
        let failedRows = queueAfterAbort.filter { $0.status == .failed }
        let pendingRows = queueAfterAbort.filter { $0.status == .pending }
        XCTAssertEqual(failedRows.count, 2)
        XCTAssertEqual(pendingRows.count, 3, "remaining jobs must stay PENDING for resume")
    }

    /// Repeated successes must reset the *consecutive* counter, so a high
    /// total-failure budget is honored across flapping success/fail patterns.
    /// We exercise this by using a `total=2` threshold with `consecutive` set
    /// high — execution stops at the second total failure even though no two
    /// failures are adjacent.
    func testRunAbortsAfterTotalFailureThresholdAcrossSuccessfulCopies() throws {
        let destinationRoot = temporaryDirectoryURL.appendingPathComponent("total", isDirectory: true)
        let sourceRoot = temporaryDirectoryURL.appendingPathComponent("total_src", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)

        let database = try OrganizerDatabase(url: destinationRoot.appendingPathComponent(".organize_cache.db"))
        defer { database.close() }

        // Alternating: good, bad, good, bad, good, bad, good. Total failures = 3.
        var jobs: [QueuedCopyJob] = []
        for index in 0..<7 {
            if index.isMultiple(of: 2) {
                let src = sourceRoot.appendingPathComponent("good_\(index).jpg")
                try Data("payload-\(index)".utf8).write(to: src)
                let hash = try FileIdentityHasher().hashIdentity(at: src).rawValue
                jobs.append(QueuedCopyJob(
                    sourcePath: src.path,
                    destinationPath: destinationRoot.appendingPathComponent("2024/01/01/good_\(index).jpg").path,
                    hash: hash,
                    status: .pending
                ))
            } else {
                jobs.append(QueuedCopyJob(
                    sourcePath: sourceRoot.appendingPathComponent("missing_\(index).jpg").path,
                    destinationPath: destinationRoot.appendingPathComponent("2024/01/01/missing_\(index).jpg").path,
                    hash: "0_missing_\(index)",
                    status: .pending
                ))
            }
        }
        try database.enqueueQueuedJobs(jobs)

        let logger = PersistentRunLogger(logURL: destinationRoot.appendingPathComponent(".organize_log.txt"))
        try logger.open()
        defer { logger.close() }

        let executor = TransferExecutor(
            failureThresholds: FailureThresholds(consecutive: 999, total: 2)
        )
        let result = try executor.execute(
            queuedJobs: jobs,
            database: database,
            destinationRoot: destinationRoot,
            verifyCopies: false,
            runLogger: logger
        )

        XCTAssertEqual(result.failedCount, 2, "executor must stop processing at the 2nd total failure")
        XCTAssertGreaterThanOrEqual(result.copiedCount, 1)
        XCTAssertLessThanOrEqual(result.copiedCount, 2)
    }

    // MARK: - Bytes tracking

    /// `bytesCopied` and `bytesTotal` must equal the sum of source file sizes,
    /// not anything derived from the destination after copy.
    func testBytesTrackingMatchesSourceFileSizes() throws {
        let env = try makeEnvironment(jobCount: 4, payloadStride: 17)
        let result = try TransferExecutor().execute(
            queuedJobs: env.jobs,
            database: env.database,
            destinationRoot: env.destinationRoot,
            verifyCopies: false,
            runLogger: env.logger
        )

        let expectedTotalBytes = env.jobs.reduce(into: Int64(0)) { running, job in
            let attributes = try? FileManager.default.attributesOfItem(atPath: job.sourcePath)
            running += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }

        XCTAssertEqual(result.copiedCount, env.jobs.count)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.bytesTotal, expectedTotalBytes)
        XCTAssertEqual(result.bytesCopied, expectedTotalBytes)
    }

    // MARK: - Verify cleanup

    /// When `verifyCopies` is true and the queued hash doesn't match the
    /// post-copy file's hash, the executor must remove the bad copy and mark
    /// the job FAILED — protecting against silent corruption on flaky NAS.
    func testVerifyCopiesRemovesFileWhenHashMismatchAndMarksJobFailed() throws {
        let env = try makeEnvironment(jobCount: 1)
        var job = env.jobs[0]
        // Tamper with the queued hash so verify fails.
        job = QueuedCopyJob(
            sourcePath: job.sourcePath,
            destinationPath: job.destinationPath,
            hash: "0_definitely_not_the_real_hash",
            status: .pending
        )
        try env.database.updateJobStatus(sourcePath: job.sourcePath, status: .pending)

        let result = try TransferExecutor().execute(
            queuedJobs: [job],
            database: env.database,
            destinationRoot: env.destinationRoot,
            verifyCopies: true,
            runLogger: env.logger
        )

        XCTAssertEqual(result.copiedCount, 0)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: job.destinationPath),
            "verify must delete the unverified copy"
        )

        let queue = try env.database.loadQueuedJobs()
        XCTAssertEqual(queue.first(where: { $0.sourcePath == job.sourcePath })?.status, .failed)
    }

    // MARK: - Audit receipt

    /// Every completed run must produce exactly one `audit_receipt_*.json` in
    /// `.organize_logs/`, and the JSON must carry the structural keys we
    /// promise downstream consumers (status, total_jobs, transfers).
    func testCompletedRunWritesAuditReceiptWithExpectedStructure() throws {
        let env = try makeEnvironment(jobCount: 2)
        _ = try TransferExecutor().execute(
            queuedJobs: env.jobs,
            database: env.database,
            destinationRoot: env.destinationRoot,
            verifyCopies: false,
            runLogger: env.logger
        )

        let logsDirectory = env.destinationRoot.appendingPathComponent(".organize_logs", isDirectory: true)
        let receipts = try FileManager.default
            .contentsOfDirectory(atPath: logsDirectory.path)
            .filter { $0.hasPrefix("audit_receipt_") && $0.hasSuffix(".json") }

        XCTAssertEqual(receipts.count, 1, "exactly one receipt should be written per run")

        let receiptURL = logsDirectory.appendingPathComponent(receipts[0])
        let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any]
        XCTAssertEqual(payload?["status"] as? String, "COMPLETED")
        XCTAssertEqual(payload?["total_jobs"] as? Int, env.jobs.count)
        XCTAssertNotNil(payload?["timestamp"] as? String)

        let transfers = payload?["transfers"] as? [[String: Any]] ?? []
        XCTAssertEqual(transfers.count, env.jobs.count)
        for transfer in transfers {
            XCTAssertNotNil(transfer["source"] as? String)
            XCTAssertNotNil(transfer["dest"] as? String)
            XCTAssertNotNil(transfer["hash"] as? String)
        }

        // The temporary spool used while building the receipt must not survive.
        let leftoverSpools = try FileManager.default
            .contentsOfDirectory(atPath: logsDirectory.path)
            .filter { $0.hasSuffix(".transfers.tmp") || $0.hasSuffix(".json.tmp") }
        XCTAssertEqual(leftoverSpools, [], "spool/temp files must be removed once the receipt is finalized")
    }

    // MARK: - Retry policy data shape

    /// The default `RetryPolicy.pythonReference` and `FailureThresholds.pythonReference`
    /// values are load-bearing — they encode the Python implementation's
    /// historical behavior. Pin them here so accidental constant changes get
    /// caught instead of silently changing field behavior.
    func testPythonReferenceRetryPolicyIsStable() {
        XCTAssertEqual(RetryPolicy.pythonReference.maxAttempts, 5)
        XCTAssertEqual(RetryPolicy.pythonReference.minimumBackoffSeconds, 1, accuracy: 0.001)
        XCTAssertEqual(RetryPolicy.pythonReference.maximumBackoffSeconds, 10, accuracy: 0.001)

        let nonRetryable = Set(RetryPolicy.pythonReference.nonRetryableErrnos)
        XCTAssertTrue(nonRetryable.contains(Int32(ENOSPC)))
        XCTAssertTrue(nonRetryable.contains(Int32(ENOENT)))
        XCTAssertTrue(nonRetryable.contains(Int32(ENOTDIR)))
        XCTAssertTrue(nonRetryable.contains(Int32(EISDIR)))
        XCTAssertTrue(nonRetryable.contains(Int32(EINVAL)))
        XCTAssertTrue(nonRetryable.contains(Int32(EACCES)))
        XCTAssertTrue(nonRetryable.contains(Int32(EPERM)))
    }

    func testPythonReferenceFailureThresholdsAreStable() {
        XCTAssertEqual(FailureThresholds.pythonReference.consecutive, 5)
        XCTAssertEqual(FailureThresholds.pythonReference.total, 20)
    }

    // MARK: - Helpers

    private struct PreparedEnvironment {
        var sourceRoot: URL
        var destinationRoot: URL
        var database: OrganizerDatabase
        var logger: PersistentRunLogger
        var jobs: [QueuedCopyJob]
    }

    /// Creates a fresh source/destination pair, a SQLite cache, and N seeded
    /// PENDING jobs whose source files exist on disk with deterministic content.
    /// `payloadStride` lets a test vary the file sizes (useful for byte tracking).
    private func makeEnvironment(jobCount: Int, payloadStride: Int = 1) throws -> PreparedEnvironment {
        let testRoot = temporaryDirectoryURL.appendingPathComponent("env-\(UUID().uuidString)", isDirectory: true)
        let sourceRoot = testRoot.appendingPathComponent("source", isDirectory: true)
        let destinationRoot = testRoot.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let database = try OrganizerDatabase(url: destinationRoot.appendingPathComponent(".organize_cache.db"))

        var jobs: [QueuedCopyJob] = []
        for index in 0..<jobCount {
            let sourceURL = sourceRoot.appendingPathComponent("photo_\(index).jpg")
            let payload = String(repeating: "abc-\(index)-", count: max(1, payloadStride * (index + 1)))
            try Data(payload.utf8).write(to: sourceURL)
            let hash = try FileIdentityHasher().hashIdentity(at: sourceURL).rawValue
            let destinationURL = destinationRoot.appendingPathComponent("2024/01/01/photo_\(index).jpg")
            jobs.append(QueuedCopyJob(
                sourcePath: sourceURL.path,
                destinationPath: destinationURL.path,
                hash: hash,
                status: .pending
            ))
        }
        try database.enqueueQueuedJobs(jobs)

        let logger = PersistentRunLogger(logURL: destinationRoot.appendingPathComponent(".organize_log.txt"))
        try logger.open()

        return PreparedEnvironment(
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            database: database,
            logger: logger,
            jobs: jobs
        )
    }
}

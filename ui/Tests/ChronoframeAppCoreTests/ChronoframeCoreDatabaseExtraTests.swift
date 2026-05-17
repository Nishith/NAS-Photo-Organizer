import Foundation
import SQLite3
import XCTest
@testable import ChronoframeCore

final class ChronoframeCoreDatabaseExtraTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChronoframeCoreDatabaseExtraTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        try super.tearDownWithError()
    }

    private func makeDatabase(_ name: String = "queue.db") throws -> OrganizerDatabase {
        let url = temporaryDirectoryURL.appendingPathComponent(name)
        return try OrganizerDatabase(url: url)
    }

    // MARK: - OrganizerDatabaseError descriptions

    func testEveryOrganizerDatabaseErrorRendersAUserFacingMessage() {
        let cases: [OrganizerDatabaseError] = [
            .openFailed("disk gone"),
            .executionFailed("write blocked"),
            .prepareFailed("bad sql"),
            .stepFailed("row failed"),
            .invalidIdentity("garbage"),
            .databaseClosed,
        ]
        for error in cases {
            let description = error.errorDescription ?? ""
            XCTAssertFalse(description.isEmpty, "errorDescription empty for \(error)")
            XCTAssertTrue(
                description.lowercased().contains("chronoframe"),
                "errorDescription should mention Chronoframe for \(error)"
            )
        }
    }

    // MARK: - DestinationIndexSnapshot regex / typed-record entry

    func testDestinationIndexSnapshotIgnoresFilenamesThatDoNotMatchTheSequencePattern() {
        let records = [
            FileCacheRecord(
                namespace: .destination,
                path: "/dest/2024/01/01/photo_without_sequence.jpg",
                identity: FileIdentity(size: 1, digest: "a"),
                size: 1,
                modificationTime: 0
            ),
            FileCacheRecord(
                namespace: .destination,
                path: "/dest/2024/01/01/2024-01-01_007_canon.jpg",
                identity: FileIdentity(size: 2, digest: "b"),
                size: 2,
                modificationTime: 0
            ),
            FileCacheRecord(
                namespace: .destination,
                path: "/dest/Unknown_Date/Duplicate/Unknown_042_canon.jpg",
                identity: FileIdentity(size: 3, digest: "c"),
                size: 3,
                modificationTime: 0
            ),
        ]
        let snapshot = DestinationIndexSnapshot.fromCacheRecords(records)
        XCTAssertEqual(snapshot.pathsByIdentity.count, 3)
        XCTAssertEqual(snapshot.sequenceState.primaryByDate["2024-01-01"], 7)
        XCTAssertEqual(snapshot.sequenceState.duplicatesByDate["Unknown_Date"], 42)
    }

    func testDestinationIndexSnapshotIgnoresSourceNamespaceRecords() {
        let records = [
            FileCacheRecord(
                namespace: .source,
                path: "/src/2024-01-01_001.jpg",
                identity: FileIdentity(size: 1, digest: "a"),
                size: 1,
                modificationTime: 0
            )
        ]
        let snapshot = DestinationIndexSnapshot.fromCacheRecords(records)
        XCTAssertTrue(snapshot.pathsByIdentity.isEmpty)
        XCTAssertTrue(snapshot.sequenceState.primaryByDate.isEmpty)
    }

    // MARK: - openFailed / readOnly

    func testReadOnlyOpenFailsWhenDatabaseFileMissing() {
        let missing = temporaryDirectoryURL.appendingPathComponent("no-such.db")
        XCTAssertThrowsError(try OrganizerDatabase(url: missing, readOnly: true)) { error in
            guard case OrganizerDatabaseError.openFailed = error else {
                XCTFail("Expected openFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - Operations on a closed database

    func testClosedDatabaseThrowsForEveryMethodThatTouchesSQLite() throws {
        let db = try makeDatabase("closed.db")
        db.close()

        XCTAssertThrowsError(try db.checkpoint()) { error in
            guard case OrganizerDatabaseError.databaseClosed = error else { XCTFail(); return }
        }
        XCTAssertThrowsError(try db.clearAllJobs()) { error in
            guard case OrganizerDatabaseError.databaseClosed = error else { XCTFail(); return }
        }
        XCTAssertThrowsError(try db.clearPendingJobs()) { error in
            guard case OrganizerDatabaseError.databaseClosed = error else { XCTFail(); return }
        }
        XCTAssertThrowsError(try db.updateJobStatus(sourcePath: "/x", status: .copied)) { error in
            guard case OrganizerDatabaseError.databaseClosed = error else { XCTFail(); return }
        }
        XCTAssertThrowsError(try db.schemaVersion()) { error in
            guard case OrganizerDatabaseError.databaseClosed = error else { XCTFail(); return }
        }
    }

    // MARK: - clearPendingJobs / clearAllJobs / updateJobStatus / deleteCacheRecord / clearCache

    func testJobLifecycleMethodsExecuteAgainstFreshDatabase() throws {
        let db = try makeDatabase()
        try db.enqueueQueuedJobs([
            QueuedCopyJob(sourcePath: "/s/a", destinationPath: "/d/a", hash: "10_abc", status: .pending),
            QueuedCopyJob(sourcePath: "/s/b", destinationPath: "/d/b", hash: "20_def", status: .pending),
        ] as [QueuedCopyJob])

        try db.updateJobStatus(sourcePath: "/s/a", status: .copied)
        XCTAssertEqual(try db.queuedJobCount(status: .copied), 1)
        XCTAssertEqual(try db.queuedJobCount(status: .pending), 1)

        try db.clearPendingJobs()
        XCTAssertEqual(try db.queuedJobCount(status: .pending), 0)
        XCTAssertEqual(try db.queuedJobCount(status: .copied), 1)

        try db.clearAllJobs()
        XCTAssertEqual(try db.queuedJobCount(), 0)
    }

    func testDeleteCacheRecordAndClearCacheRespectNamespace() throws {
        let db = try makeDatabase()
        try db.saveCacheRecords([
            FileCacheRecord(
                namespace: .source,
                path: "/src/a.jpg",
                identity: FileIdentity(size: 1, digest: "a"),
                size: 1,
                modificationTime: 0
            ),
            FileCacheRecord(
                namespace: .destination,
                path: "/dst/a.jpg",
                identity: FileIdentity(size: 1, digest: "a"),
                size: 1,
                modificationTime: 0
            ),
        ])

        try db.deleteCacheRecord(namespace: .source, path: "/src/a.jpg")
        XCTAssertEqual(try db.cacheRecordCount(namespace: .source), 0)
        XCTAssertEqual(try db.cacheRecordCount(namespace: .destination), 1)

        try db.clearCache(namespace: .destination)
        XCTAssertEqual(try db.cacheRecordCount(namespace: .destination), 0)

        try db.saveCacheRecords([
            FileCacheRecord(
                namespace: .source,
                path: "/src/b.jpg",
                identity: FileIdentity(size: 2, digest: "b"),
                size: 2,
                modificationTime: 0
            )
        ])
        try db.clearCache()
        XCTAssertEqual(try db.cacheRecordCount(namespace: .source), 0)
    }

    // MARK: - PRAGMA accessors and checkpoint

    func testJournalModeSynchronousAndCheckpointAreCallableOnLiveDatabase() throws {
        let db = try makeDatabase()
        let journal = try db.journalMode()
        XCTAssertEqual(journal.lowercased(), "wal")
        let sync = try db.synchronousMode()
        XCTAssertEqual(sync, 1) // NORMAL
        // checkpoint should succeed on an empty WAL.
        try db.checkpoint()
    }

    // MARK: - schemaVersion

    func testSchemaVersionReturnsCurrentTargetAfterMigrations() throws {
        let db = try makeDatabase()
        XCTAssertGreaterThanOrEqual(try db.schemaVersion(), 1)
    }

    // MARK: - invalidIdentity flowed through loadCacheRecords

    func testLoadCacheRecordsThrowsInvalidIdentityForCorruptHash() throws {
        let dbURL = temporaryDirectoryURL.appendingPathComponent("invalid-id.db")
        let db = try OrganizerDatabase(url: dbURL)

        // Insert a record with a malformed hash bypassing the typed API.
        try db.saveRawCacheRecords([
            RawFileCacheRecord(
                namespace: .source,
                path: "/src/bad.jpg",
                hash: "not-a-valid-identity-string",
                size: 9,
                modificationTime: 0
            )
        ])

        XCTAssertThrowsError(try db.loadCacheRecords(namespace: .source)) { error in
            guard case let OrganizerDatabaseError.invalidIdentity(value) = error else {
                XCTFail("Expected invalidIdentity, got \(error)")
                return
            }
            XCTAssertEqual(value, "not-a-valid-identity-string")
        }
    }

    // MARK: - ReviewOverride lifecycle (covers loadReviewOverride + nil branches)

    func testReviewOverrideSaveLoadAndDelete() throws {
        let db = try makeDatabase("reviews.db")
        let identity = FileIdentity(size: 100, digest: "rev1")
        let dated = ReviewOverride(
            identity: identity,
            sourcePath: "/src/a.jpg",
            captureDate: Date(timeIntervalSince1970: 1_700_000_000),
            eventName: "Trip",
            updatedAt: Date(timeIntervalSince1970: 1_700_001_000)
        )
        try db.saveReviewOverride(dated)

        let loaded = try XCTUnwrap(try db.loadReviewOverride(identity: identity, sourcePath: "/src/a.jpg"))
        XCTAssertEqual(loaded.eventName, "Trip")
        XCTAssertEqual(loaded.captureDate?.timeIntervalSince1970, 1_700_000_000)

        // Save with nil captureDate AND non-nil eventName → covers NULL column branch on read.
        let onlyEvent = ReviewOverride(
            identity: identity,
            sourcePath: "/src/a.jpg",
            captureDate: nil,
            eventName: "Updated",
            updatedAt: Date(timeIntervalSince1970: 1_700_002_000)
        )
        try db.saveReviewOverride(onlyEvent)

        let updated = try XCTUnwrap(try db.loadReviewOverride(identity: identity, sourcePath: "/src/a.jpg"))
        XCTAssertNil(updated.captureDate)
        XCTAssertEqual(updated.eventName, "Updated")

        // loadReviewOverrides (plural) also covers NULL column branch.
        let all = try db.loadReviewOverrides()
        XCTAssertEqual(all.count, 1)
        XCTAssertNil(all[0].captureDate)

        // Saving an override with both fields nil deletes it.
        let empty = ReviewOverride(
            identity: identity,
            sourcePath: "/src/a.jpg",
            captureDate: nil,
            eventName: nil,
            updatedAt: Date()
        )
        try db.saveReviewOverride(empty)
        XCTAssertNil(try db.loadReviewOverride(identity: identity, sourcePath: "/src/a.jpg"))
        XCTAssertTrue(try db.loadReviewOverrides().isEmpty)
    }

    func testLoadReviewOverrideReturnsNilForMissingRow() throws {
        let db = try makeDatabase()
        let identity = FileIdentity(size: 1, digest: "a")
        XCTAssertNil(try db.loadReviewOverride(identity: identity, sourcePath: "/no/such"))
    }

    // MARK: - destinationIndexSnapshot via database

    // MARK: - Typed-array entry points and remaining error branches

    func testTypedArrayEntryPointsForSaveAndEnqueue() throws {
        let db = try makeDatabase("typed-arrays.db")

        let cacheRecords: [RawFileCacheRecord] = [
            RawFileCacheRecord(
                namespace: .source,
                path: "/src/typed.jpg",
                hash: "11_typed",
                size: 11,
                modificationTime: 0
            )
        ]
        // Force selection of the public `[RawFileCacheRecord]` entry point.
        try db.saveRawCacheRecords(cacheRecords)
        XCTAssertEqual(try db.cacheRecordCount(namespace: .source), 1)

        let queued: [QueuedCopyJob] = [
            QueuedCopyJob(sourcePath: "/s/typed", destinationPath: "/d/typed", hash: "11_typed", status: .pending)
        ]
        try db.enqueueQueuedJobs(queued)
        XCTAssertEqual(try db.queuedJobCount(), 1)
    }

    func testLoadCopyJobsThrowsInvalidIdentityForBrokenHash() throws {
        let db = try makeDatabase("bad-copy-job.db")
        try db.enqueueQueuedJobs([
            QueuedCopyJob(sourcePath: "/s/x", destinationPath: "/d/x", hash: "garbage", status: .pending)
        ] as [QueuedCopyJob])

        XCTAssertThrowsError(try db.loadCopyJobs()) { error in
            guard case let OrganizerDatabaseError.invalidIdentity(value) = error else {
                XCTFail("Expected invalidIdentity, got \(error)")
                return
            }
            XCTAssertEqual(value, "garbage")
        }
    }

    func testPendingJobCountMatchesQueuedJobCountWithPendingFilter() throws {
        let db = try makeDatabase("pending-count.db")
        try db.enqueueQueuedJobs([
            QueuedCopyJob(sourcePath: "/s/a", destinationPath: "/d/a", hash: "1_a", status: .pending),
            QueuedCopyJob(sourcePath: "/s/b", destinationPath: "/d/b", hash: "2_b", status: .copied),
        ] as [QueuedCopyJob])
        XCTAssertEqual(try db.pendingJobCount(), 1)
    }

    func testReviewOverrideLoadersFallBackForNullUpdatedAtColumn() throws {
        let dbURL = temporaryDirectoryURL.appendingPathComponent("null-updated.db")
        let db = try OrganizerDatabase(url: dbURL)
        db.close()

        // Inject a ReviewOverrides row with NULL capture_date and NULL updated_at.
        var raw: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(dbURL.path, &raw, SQLITE_OPEN_READWRITE, nil),
            SQLITE_OK
        )
        let inject = """
        INSERT INTO ReviewOverrides(identity, source_path, capture_date, event_name, updated_at)
        VALUES ('1_null', '/src/null.jpg', NULL, 'EventX', NULL);
        """
        XCTAssertEqual(sqlite3_exec(raw, inject, nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        let reopened = try OrganizerDatabase(url: dbURL)
        let identity = try XCTUnwrap(FileIdentity(rawValue: "1_null"))
        let single = try XCTUnwrap(try reopened.loadReviewOverride(identity: identity, sourcePath: "/src/null.jpg"))
        XCTAssertNil(single.captureDate)
        XCTAssertEqual(single.updatedAt.timeIntervalSince1970, 0)

        let all = try reopened.loadReviewOverrides()
        XCTAssertEqual(all.count, 1)
        XCTAssertNil(all[0].captureDate)
        XCTAssertEqual(all[0].updatedAt.timeIntervalSince1970, 0)
    }

    func testEnumerateQueuedJobBatchesThrowsInvalidIdentityForUnknownStatus() throws {
        let dbURL = temporaryDirectoryURL.appendingPathComponent("bad-status.db")
        let db = try OrganizerDatabase(url: dbURL)
        db.close()

        var raw: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(dbURL.path, &raw, SQLITE_OPEN_READWRITE, nil),
            SQLITE_OK
        )
        let inject = "INSERT INTO CopyJobs(src_path, dst_path, hash, status) VALUES ('/s', '/d', '1_a', 'UFO');"
        XCTAssertEqual(sqlite3_exec(raw, inject, nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        let reopened = try OrganizerDatabase(url: dbURL)
        XCTAssertThrowsError(try reopened.loadQueuedJobs()) { error in
            guard case OrganizerDatabaseError.invalidIdentity = error else {
                XCTFail("Expected invalidIdentity, got \(error)")
                return
            }
        }
    }

    func testDatabaseDestinationIndexSnapshotMirrorsLoadedRecords() throws {
        let db = try makeDatabase()
        try db.saveCacheRecords([
            FileCacheRecord(
                namespace: .destination,
                path: "/dst/2024-01-01_003_x.jpg",
                identity: FileIdentity(size: 1, digest: "x"),
                size: 1,
                modificationTime: 0
            )
        ])

        let snapshot = try db.destinationIndexSnapshot()
        XCTAssertEqual(snapshot.sequenceState.primaryByDate["2024-01-01"], 3)
    }
}

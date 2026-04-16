import Foundation
import SQLite3
import XCTest
@testable import ChronoframeCore

final class ChronoframeCoreDatabaseTests: XCTestCase {
    private struct SchemaColumn: Equatable {
        var name: String
        var type: String
        var primaryKeyPosition: Int32
    }

    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChronoframeCoreDatabaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        try super.tearDownWithError()
    }

    func testOrganizerDatabaseMatchesPythonPragmasAndSchema() throws {
        let databaseURL = temporaryDirectoryURL.appendingPathComponent(".organize_cache.db")
        let database = try OrganizerDatabase(url: databaseURL)
        defer { database.close() }

        XCTAssertEqual(try database.journalMode().lowercased(), "wal")
        XCTAssertEqual(try database.synchronousMode(), 1)

        var rawDatabase: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &rawDatabase, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(rawDatabase) }

        XCTAssertEqual(
            try schemaColumns(table: "FileCache", database: rawDatabase),
            [
                SchemaColumn(name: "id", type: "INTEGER", primaryKeyPosition: 1),
                SchemaColumn(name: "path", type: "TEXT", primaryKeyPosition: 2),
                SchemaColumn(name: "hash", type: "TEXT", primaryKeyPosition: 0),
                SchemaColumn(name: "size", type: "INTEGER", primaryKeyPosition: 0),
                SchemaColumn(name: "mtime", type: "REAL", primaryKeyPosition: 0),
            ]
        )
        XCTAssertEqual(
            try schemaColumns(table: "CopyJobs", database: rawDatabase),
            [
                SchemaColumn(name: "src_path", type: "TEXT", primaryKeyPosition: 1),
                SchemaColumn(name: "dst_path", type: "TEXT", primaryKeyPosition: 0),
                SchemaColumn(name: "hash", type: "TEXT", primaryKeyPosition: 0),
                SchemaColumn(name: "status", type: "TEXT", primaryKeyPosition: 0),
            ]
        )
    }

    func testSaveAndLoadCacheRecordsRoundTrip() throws {
        let database = try OrganizerDatabase(url: temporaryDirectoryURL.appendingPathComponent(".organize_cache.db"))
        defer { database.close() }

        try database.saveCacheRecords(
            [
                FileCacheRecord(
                    namespace: .destination,
                    path: "/dest/2024/02/14/2024-02-14_001.jpg",
                    identity: FileIdentity(size: 7, digest: "hash-a"),
                    size: 7,
                    modificationTime: 1_700_000_000
                ),
                FileCacheRecord(
                    namespace: .destination,
                    path: "/dest/Duplicate/2024/02/14/2024-02-14_003.jpg",
                    identity: FileIdentity(size: 8, digest: "hash-b"),
                    size: 8,
                    modificationTime: 1_700_000_001
                ),
            ]
        )

        let records = try database.loadCacheRecords(namespace: .destination)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.path), [
            "/dest/2024/02/14/2024-02-14_001.jpg",
            "/dest/Duplicate/2024/02/14/2024-02-14_003.jpg",
        ])
    }

    func testEnqueueLoadAndUpdateJobsRoundTrip() throws {
        let database = try OrganizerDatabase(url: temporaryDirectoryURL.appendingPathComponent(".organize_cache.db"))
        defer { database.close() }

        try database.enqueueJobs(
            [
                CopyJobRecord(
                    sourcePath: "/src/a.jpg",
                    destinationPath: "/dst/a.jpg",
                    identity: FileIdentity(size: 4, digest: "job-a"),
                    status: .pending
                ),
                CopyJobRecord(
                    sourcePath: "/src/b.jpg",
                    destinationPath: "/dst/b.jpg",
                    identity: FileIdentity(size: 5, digest: "job-b"),
                    status: .pending
                ),
            ]
        )

        XCTAssertEqual(try database.pendingJobCount(), 2)
        XCTAssertEqual(try database.loadCopyJobs(status: .pending).count, 2)

        try database.updateJobStatus(sourcePath: "/src/a.jpg", status: .copied)

        XCTAssertEqual(try database.pendingJobCount(), 1)
        XCTAssertEqual(try database.loadCopyJobs(status: .copied).map(\.sourcePath), ["/src/a.jpg"])
    }

    func testRawQueueAndCacheRowsRoundTripWithoutParsingIdentity() throws {
        let database = try OrganizerDatabase(url: temporaryDirectoryURL.appendingPathComponent(".organize_cache.db"))
        defer { database.close() }

        try database.saveRawCacheRecords(
            [
                RawFileCacheRecord(
                    namespace: .destination,
                    path: "/dest/copied.jpg",
                    hash: "raw-hash",
                    size: 11,
                    modificationTime: 1_700_000_010
                ),
            ]
        )
        try database.enqueueQueuedJobs(
            [
                QueuedCopyJob(
                    sourcePath: "/src/raw-a.jpg",
                    destinationPath: "/dst/raw-a.jpg",
                    hash: "raw-job-a",
                    status: .pending
                ),
                QueuedCopyJob(
                    sourcePath: "/src/raw-b.jpg",
                    destinationPath: "/dst/raw-b.jpg",
                    hash: "raw-job-b",
                    status: .copied
                ),
            ]
        )

        XCTAssertEqual(try database.loadRawCacheRecords(namespace: .destination).map(\.hash), ["raw-hash"])
        XCTAssertEqual(try database.loadQueuedJobs().map(\.hash), ["raw-job-a", "raw-job-b"])
    }

    func testLoadQueuedJobsCanPreserveInsertionOrderForResume() throws {
        let database = try OrganizerDatabase(url: temporaryDirectoryURL.appendingPathComponent(".organize_cache.db"))
        defer { database.close() }

        try database.enqueueQueuedJobs(
            [
                QueuedCopyJob(sourcePath: "/src/c.jpg", destinationPath: "/dst/c.jpg", hash: "h3", status: .pending),
                QueuedCopyJob(sourcePath: "/src/a.jpg", destinationPath: "/dst/a.jpg", hash: "h1", status: .pending),
                QueuedCopyJob(sourcePath: "/src/b.jpg", destinationPath: "/dst/b.jpg", hash: "h2", status: .pending),
            ]
        )

        XCTAssertEqual(
            try database.loadQueuedJobs(status: .pending, orderByInsertion: true).map(\.sourcePath),
            ["/src/c.jpg", "/src/a.jpg", "/src/b.jpg"]
        )
        XCTAssertEqual(
            try database.loadQueuedJobs(status: .pending, orderByInsertion: false).map(\.sourcePath),
            ["/src/a.jpg", "/src/b.jpg", "/src/c.jpg"]
        )
    }

    func testEnumerateRawCacheRecordBatchesPreservesPathOrdering() throws {
        let database = try OrganizerDatabase(url: temporaryDirectoryURL.appendingPathComponent(".organize_cache.db"))
        defer { database.close() }

        try database.saveRawCacheRecords(
            [
                RawFileCacheRecord(namespace: .destination, path: "/dest/c.jpg", hash: "c", size: 3, modificationTime: 3),
                RawFileCacheRecord(namespace: .destination, path: "/dest/a.jpg", hash: "a", size: 1, modificationTime: 1),
                RawFileCacheRecord(namespace: .destination, path: "/dest/b.jpg", hash: "b", size: 2, modificationTime: 2),
            ]
        )

        var streamedPaths: [String] = []
        try database.enumerateRawCacheRecordBatches(namespace: .destination, batchSize: 2) { batch in
            streamedPaths.append(contentsOf: batch.map(\.path))
        }

        XCTAssertEqual(streamedPaths, ["/dest/a.jpg", "/dest/b.jpg", "/dest/c.jpg"])
    }

    func testEnumerateQueuedJobBatchesCanPreserveInsertionOrder() throws {
        let database = try OrganizerDatabase(url: temporaryDirectoryURL.appendingPathComponent(".organize_cache.db"))
        defer { database.close() }

        try database.enqueueQueuedJobs(
            [
                QueuedCopyJob(sourcePath: "/src/3.jpg", destinationPath: "/dst/3.jpg", hash: "h3", status: .pending),
                QueuedCopyJob(sourcePath: "/src/1.jpg", destinationPath: "/dst/1.jpg", hash: "h1", status: .pending),
                QueuedCopyJob(sourcePath: "/src/2.jpg", destinationPath: "/dst/2.jpg", hash: "h2", status: .pending),
            ]
        )

        var streamedPaths: [String] = []
        try database.enumerateQueuedJobBatches(status: .pending, orderByInsertion: true, batchSize: 2) { batch in
            streamedPaths.append(contentsOf: batch.map(\.sourcePath))
        }

        XCTAssertEqual(streamedPaths, ["/src/3.jpg", "/src/1.jpg", "/src/2.jpg"])
        XCTAssertEqual(try database.queuedJobCount(status: .pending), 3)
    }

    func testDestinationIndexSnapshotMatchesFastDestSemantics() throws {
        let database = try OrganizerDatabase(url: temporaryDirectoryURL.appendingPathComponent(".organize_cache.db"))
        defer { database.close() }

        try database.saveCacheRecords(
            [
                FileCacheRecord(
                    namespace: .destination,
                    path: "/dest/2024/02/14/2024-02-14_002.jpg",
                    identity: FileIdentity(size: 7, digest: "main"),
                    size: 7,
                    modificationTime: 1_700_000_000
                ),
                FileCacheRecord(
                    namespace: .destination,
                    path: "/dest/Unknown_Date/Unknown_004.mov",
                    identity: FileIdentity(size: 8, digest: "unknown"),
                    size: 8,
                    modificationTime: 1_700_000_001
                ),
                FileCacheRecord(
                    namespace: .destination,
                    path: "/dest/Duplicate/2024/02/14/2024-02-14_005.jpg",
                    identity: FileIdentity(size: 9, digest: "dup"),
                    size: 9,
                    modificationTime: 1_700_000_002
                ),
            ]
        )

        let snapshot = try database.destinationIndexSnapshot()

        XCTAssertEqual(snapshot.pathsByIdentity[FileIdentity(size: 7, digest: "main")], "/dest/2024/02/14/2024-02-14_002.jpg")
        XCTAssertEqual(snapshot.sequenceState.primaryByDate["2024-02-14"], 2)
        XCTAssertEqual(snapshot.sequenceState.primaryByDate["Unknown_Date"], 4)
        XCTAssertEqual(snapshot.sequenceState.duplicatesByDate["2024-02-14"], 5)
    }

    private func schemaColumns(
        table: String,
        database: OpaquePointer?
    ) throws -> [SchemaColumn] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK else {
            XCTFail("Could not prepare schema query")
            return []
        }
        defer { sqlite3_finalize(statement) }

        var columns: [SchemaColumn] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(statement, 1))
            let type = String(cString: sqlite3_column_text(statement, 2))
            let primaryKeyPosition = sqlite3_column_int(statement, 5)
            columns.append(
                SchemaColumn(
                    name: name,
                    type: type,
                    primaryKeyPosition: primaryKeyPosition
                )
            )
        }
        return columns
    }
}

import Foundation
import SQLite3

public enum OrganizerDatabaseError: LocalizedError, Sendable {
    case openFailed(String)
    case executionFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case invalidIdentity(String)
    case databaseClosed

    public var errorDescription: String? {
        switch self {
        case let .openFailed(message):
            return "Chronoframe could not open the organizer database: \(message)"
        case let .executionFailed(message):
            return "Chronoframe could not execute a database statement: \(message)"
        case let .prepareFailed(message):
            return "Chronoframe could not prepare a database statement: \(message)"
        case let .stepFailed(message):
            return "Chronoframe could not read organizer database rows: \(message)"
        case let .invalidIdentity(value):
            return "Chronoframe encountered an invalid file identity string: \(value)"
        case .databaseClosed:
            return "Chronoframe tried to use a closed organizer database."
        }
    }
}

public struct DestinationIndexSnapshot: Equatable, Sendable {
    public var pathsByIdentity: [FileIdentity: String]
    public var sequenceState: SequenceCounterState

    public init(
        pathsByIdentity: [FileIdentity: String] = [:],
        sequenceState: SequenceCounterState = SequenceCounterState()
    ) {
        self.pathsByIdentity = pathsByIdentity
        self.sequenceState = sequenceState
    }

    public static func fromCacheRecords(
        _ records: [FileCacheRecord],
        namingRules: PlannerNamingRules = .pythonReference
    ) -> DestinationIndexSnapshot {
        fromRawCacheRecords(records.map(RawFileCacheRecord.init(cacheRecord:)), namingRules: namingRules)
    }

    public static func fromRawCacheRecords(
        _ records: [RawFileCacheRecord],
        namingRules: PlannerNamingRules = .pythonReference
    ) -> DestinationIndexSnapshot {
        fromIndexedPaths(
            records
                .filter { $0.namespace == .destination }
                .map { (path: $0.path, identity: $0.parsedIdentity) },
            namingRules: namingRules
        )
    }

    static func fromIndexedPaths(
        _ records: [(path: String, identity: FileIdentity?)],
        namingRules: PlannerNamingRules = .pythonReference
    ) -> DestinationIndexSnapshot {
        let filenamePattern = try? NSRegularExpression(pattern: #"^(\d{4}-\d{2}-\d{2}|Unknown)_(\d+)"#)

        var pathsByIdentity: [FileIdentity: String] = [:]
        var primaryByDate: [String: Int] = [:]
        var duplicatesByDate: [String: Int] = [:]

        for record in records {
            if let identity = record.identity {
                pathsByIdentity[identity] = record.path
            }

            guard let filenamePattern else { continue }
            let filename = URL(fileURLWithPath: record.path).lastPathComponent
            let searchRange = NSRange(filename.startIndex..<filename.endIndex, in: filename)
            guard let match = filenamePattern.firstMatch(in: filename, range: searchRange) else { continue }

            guard
                let prefixRange = Range(match.range(at: 1), in: filename),
                let sequenceRange = Range(match.range(at: 2), in: filename),
                let sequence = Int(filename[sequenceRange])
            else {
                continue
            }

            let dateBucket = String(filename[prefixRange]) == "Unknown"
                ? namingRules.unknownDateDirectoryName
                : String(filename[prefixRange])
            let isDuplicate = URL(fileURLWithPath: record.path).pathComponents.contains(namingRules.duplicateDirectoryName)

            if isDuplicate {
                duplicatesByDate[dateBucket] = max(duplicatesByDate[dateBucket] ?? 0, sequence)
            } else {
                primaryByDate[dateBucket] = max(primaryByDate[dateBucket] ?? 0, sequence)
            }
        }

        return DestinationIndexSnapshot(
            pathsByIdentity: pathsByIdentity,
            sequenceState: SequenceCounterState(
                primaryByDate: primaryByDate,
                duplicatesByDate: duplicatesByDate
            )
        )
    }
}

public final class OrganizerDatabase {
    private let url: URL
    private var database: OpaquePointer?

    public init(url: URL, readOnly: Bool = false) throws {
        self.url = url

        if !readOnly {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        let flags = readOnly
            ? SQLITE_OPEN_READONLY
            : SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX

        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = Self.errorMessage(from: handle)
            sqlite3_close(handle)
            throw OrganizerDatabaseError.openFailed(message)
        }

        database = handle

        if !readOnly {
            // Wait up to 30 s before returning SQLITE_BUSY, instead of failing
            // immediately when another connection holds a write lock.
            try execute("PRAGMA busy_timeout=30000;")
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA synchronous=NORMAL;")
            try initializeSchema()
        }
    }

    deinit {
        close()
    }

    public func close() {
        if let database {
            sqlite3_close(database)
            self.database = nil
        }
    }

    public func initializeSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS FileCache (
                id INTEGER,
                path TEXT,
                hash TEXT,
                size INTEGER,
                mtime REAL,
                PRIMARY KEY (id, path)
            );
            """
        )

        try execute(
            """
            CREATE TABLE IF NOT EXISTS CopyJobs (
                src_path TEXT PRIMARY KEY,
                dst_path TEXT,
                hash TEXT,
                status TEXT
            );
            """
        )
    }

    public func journalMode() throws -> String {
        try scalarString(statement: "PRAGMA journal_mode;")
    }

    public func synchronousMode() throws -> Int32 {
        try scalarInt(statement: "PRAGMA synchronous;")
    }

    public func loadRawCacheRecords(namespace: CacheNamespace) throws -> [RawFileCacheRecord] {
        var rows: [RawFileCacheRecord] = []
        try enumerateRawCacheRecordBatches(namespace: namespace) { batch in
            rows.append(contentsOf: batch)
        }
        return rows
    }

    public func enumerateRawCacheRecordBatches(
        namespace: CacheNamespace,
        batchSize: Int = 512,
        _ body: ([RawFileCacheRecord]) throws -> Void
    ) throws {
        let statement = try prepare("SELECT id, path, hash, size, mtime FROM FileCache WHERE id = ? ORDER BY path")
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(namespace.rawValue))

        var batch: [RawFileCacheRecord] = []
        batch.reserveCapacity(max(1, batchSize))

        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE {
                break
            }
            guard stepResult == SQLITE_ROW else {
                throw OrganizerDatabaseError.stepFailed(lastErrorMessage())
            }

            guard
                let namespaceValue = CacheNamespace(rawValue: Int(sqlite3_column_int(statement, 0))),
                let path = Self.sqliteString(statement, column: 1),
                let hash = Self.sqliteString(statement, column: 2)
            else {
                throw OrganizerDatabaseError.invalidIdentity(Self.sqliteString(statement, column: 2) ?? "")
            }

            batch.append(
                RawFileCacheRecord(
                    namespace: namespaceValue,
                    path: path,
                    hash: hash,
                    size: sqlite3_column_int64(statement, 3),
                    modificationTime: sqlite3_column_double(statement, 4)
                )
            )

            if batch.count >= max(1, batchSize) {
                try body(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }

        if !batch.isEmpty {
            try body(batch)
        }
    }

    public func loadCacheRecords(namespace: CacheNamespace) throws -> [FileCacheRecord] {
        try loadRawCacheRecords(namespace: namespace).map { row in
            guard let typedRecord = row.typedRecord else {
                throw OrganizerDatabaseError.invalidIdentity(row.hash)
            }
            return typedRecord
        }
    }

    public func saveRawCacheRecords(_ records: [RawFileCacheRecord]) throws {
        try saveRawCacheRecords(records[...])
    }

    public func saveRawCacheRecords<S: Sequence>(_ records: S) throws where S.Element == RawFileCacheRecord {
        let statement = try prepare(
            "REPLACE INTO FileCache (id, path, hash, size, mtime) VALUES (?, ?, ?, ?, ?)"
        )
        defer { sqlite3_finalize(statement) }

        var wroteAnyRecords = false

        do {
            for record in records {
                if !wroteAnyRecords {
                    try execute("BEGIN IMMEDIATE TRANSACTION;")
                    wroteAnyRecords = true
                }

                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_int(statement, 1, Int32(record.namespace.rawValue))
                sqlite3_bind_text(statement, 2, record.path, -1, Self.sqliteTransient)
                sqlite3_bind_text(statement, 3, record.hash, -1, Self.sqliteTransient)
                sqlite3_bind_int64(statement, 4, record.size)
                sqlite3_bind_double(statement, 5, record.modificationTime)

                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw OrganizerDatabaseError.stepFailed(lastErrorMessage())
                }
            }

            if wroteAnyRecords {
                try execute("COMMIT;")
            }
        } catch {
            if wroteAnyRecords {
                try? execute("ROLLBACK;")
            }
            throw error
        }
    }

    public func saveCacheRecords(_ records: [FileCacheRecord]) throws {
        try saveRawCacheRecords(records.map(RawFileCacheRecord.init(cacheRecord:)))
    }

    public func enqueueQueuedJobs(_ jobs: [QueuedCopyJob]) throws {
        try enqueueQueuedJobs(jobs[...])
    }

    public func enqueueQueuedJobs<S: Sequence>(_ jobs: S) throws where S.Element == QueuedCopyJob {
        let statement = try prepare(
            "INSERT OR IGNORE INTO CopyJobs (src_path, dst_path, hash, status) VALUES (?, ?, ?, ?)"
        )
        defer { sqlite3_finalize(statement) }

        var wroteAnyJobs = false

        do {
            for job in jobs {
                if !wroteAnyJobs {
                    try execute("BEGIN IMMEDIATE TRANSACTION;")
                    wroteAnyJobs = true
                }

                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_text(statement, 1, job.sourcePath, -1, Self.sqliteTransient)
                sqlite3_bind_text(statement, 2, job.destinationPath, -1, Self.sqliteTransient)
                sqlite3_bind_text(statement, 3, job.hash, -1, Self.sqliteTransient)
                sqlite3_bind_text(statement, 4, job.status.rawValue, -1, Self.sqliteTransient)

                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw OrganizerDatabaseError.stepFailed(lastErrorMessage())
                }
            }

            if wroteAnyJobs {
                try execute("COMMIT;")
            }
        } catch {
            if wroteAnyJobs {
                try? execute("ROLLBACK;")
            }
            throw error
        }
    }

    public func enqueuePlannedTransfers<S: Sequence>(_ transfers: S) throws where S.Element == PlannedTransfer {
        try enqueueQueuedJobs(
            transfers.lazy.map { transfer in
                QueuedCopyJob(
                    sourcePath: transfer.sourcePath,
                    destinationPath: transfer.destinationPath,
                    hash: transfer.identity.rawValue,
                    status: .pending
                )
            }
        )
    }

    public func enqueueJobs(_ jobs: [CopyJobRecord]) throws {
        try enqueueQueuedJobs(jobs.map(QueuedCopyJob.init(copyJob:)))
    }

    public func loadQueuedJobs(
        status: CopyJobStatus? = nil,
        orderByInsertion: Bool = false
    ) throws -> [QueuedCopyJob] {
        var rows: [QueuedCopyJob] = []
        try enumerateQueuedJobBatches(status: status, orderByInsertion: orderByInsertion) { batch in
            rows.append(contentsOf: batch)
        }
        return rows
    }

    public func enumerateQueuedJobBatches(
        status: CopyJobStatus? = nil,
        orderByInsertion: Bool = false,
        batchSize: Int = 512,
        _ body: ([QueuedCopyJob]) throws -> Void
    ) throws {
        let sql: String
        let orderClause = orderByInsertion ? " ORDER BY rowid" : " ORDER BY src_path"
        if status != nil {
            sql = "SELECT src_path, dst_path, hash, status FROM CopyJobs WHERE status = ?\(orderClause)"
        } else {
            sql = "SELECT src_path, dst_path, hash, status FROM CopyJobs\(orderClause)"
        }

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        if let status {
            sqlite3_bind_text(statement, 1, status.rawValue, -1, Self.sqliteTransient)
        }

        var batch: [QueuedCopyJob] = []
        batch.reserveCapacity(max(1, batchSize))

        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE {
                break
            }
            guard stepResult == SQLITE_ROW else {
                throw OrganizerDatabaseError.stepFailed(lastErrorMessage())
            }

            guard
                let sourcePath = Self.sqliteString(statement, column: 0),
                let destinationPath = Self.sqliteString(statement, column: 1),
                let hash = Self.sqliteString(statement, column: 2),
                let statusString = Self.sqliteString(statement, column: 3),
                let jobStatus = CopyJobStatus(rawValue: statusString)
            else {
                throw OrganizerDatabaseError.invalidIdentity(Self.sqliteString(statement, column: 2) ?? "")
            }

            batch.append(
                QueuedCopyJob(
                    sourcePath: sourcePath,
                    destinationPath: destinationPath,
                    hash: hash,
                    status: jobStatus
                )
            )

            if batch.count >= max(1, batchSize) {
                try body(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }

        if !batch.isEmpty {
            try body(batch)
        }
    }

    public func loadCopyJobs(status: CopyJobStatus? = nil) throws -> [CopyJobRecord] {
        try loadQueuedJobs(status: status).map { row in
            guard let typedRecord = row.typedRecord else {
                throw OrganizerDatabaseError.invalidIdentity(row.hash)
            }
            return typedRecord
        }
    }

    public func queuedJobCount(status: CopyJobStatus? = nil) throws -> Int {
        if let status {
            let statement = try prepare("SELECT COUNT(*) FROM CopyJobs WHERE status = ?")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, status.rawValue, -1, Self.sqliteTransient)

            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw OrganizerDatabaseError.stepFailed(lastErrorMessage())
            }

            return Int(sqlite3_column_int(statement, 0))
        }

        return Int(try scalarInt(statement: "SELECT COUNT(*) FROM CopyJobs"))
    }

    public func pendingJobCount() throws -> Int {
        try queuedJobCount(status: .pending)
    }

    /// Deletes all rows from `CopyJobs` whose status is `.pending`.
    public func clearPendingJobs() throws {
        try execute("DELETE FROM CopyJobs WHERE status = 'pending'")
    }

    /// Truncates the entire `CopyJobs` table.
    /// Call this before a "Start Fresh" transfer so that stale records left by
    /// a previous run (including foreign entries from the Python backend) do not
    /// block `enqueuePlannedTransfers`'s `INSERT OR IGNORE` logic.
    public func clearAllJobs() throws {
        try execute("DELETE FROM CopyJobs")
    }

    public func updateJobStatus(sourcePath: String, status: CopyJobStatus) throws {
        let statement = try prepare("UPDATE CopyJobs SET status = ? WHERE src_path = ?")
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, status.rawValue, -1, Self.sqliteTransient)
        sqlite3_bind_text(statement, 2, sourcePath, -1, Self.sqliteTransient)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw OrganizerDatabaseError.stepFailed(lastErrorMessage())
        }
    }

    public func destinationIndexSnapshot(
        namingRules: PlannerNamingRules = .pythonReference
    ) throws -> DestinationIndexSnapshot {
        DestinationIndexSnapshot.fromRawCacheRecords(
            try loadRawCacheRecords(namespace: .destination),
            namingRules: namingRules
        )
    }

    private func scalarString(statement sql: String) throws -> String {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw OrganizerDatabaseError.stepFailed(lastErrorMessage())
        }

        return Self.sqliteString(statement, column: 0) ?? ""
    }

    private func scalarInt(statement sql: String) throws -> Int32 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw OrganizerDatabaseError.stepFailed(lastErrorMessage())
        }

        return sqlite3_column_int(statement, 0)
    }

    private func execute(_ sql: String) throws {
        guard let database else {
            throw OrganizerDatabaseError.databaseClosed
        }

        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw OrganizerDatabaseError.executionFailed(lastErrorMessage())
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        guard let database else {
            throw OrganizerDatabaseError.databaseClosed
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw OrganizerDatabaseError.prepareFailed(lastErrorMessage())
        }
        return statement
    }

    private func lastErrorMessage() -> String {
        Self.errorMessage(from: database)
    }

    private static func errorMessage(from database: OpaquePointer?) -> String {
        if let database, let message = sqlite3_errmsg(database) {
            return String(cString: message)
        }
        return "Unknown SQLite error"
    }

    private static func sqliteString(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: pointer)
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

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
        let filenamePattern = try? NSRegularExpression(pattern: #"^(\d{4}-\d{2}-\d{2}|Unknown)_(\d+)"#)

        var pathsByIdentity: [FileIdentity: String] = [:]
        var primaryByDate: [String: Int] = [:]
        var duplicatesByDate: [String: Int] = [:]

        for record in records where record.namespace == .destination {
            pathsByIdentity[record.identity] = record.path

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

    public func loadCacheRecords(namespace: CacheNamespace) throws -> [FileCacheRecord] {
        let statement = try prepare("SELECT id, path, hash, size, mtime FROM FileCache WHERE id = ? ORDER BY path")
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(namespace.rawValue))

        var rows: [FileCacheRecord] = []
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
                let identityString = Self.sqliteString(statement, column: 2),
                let identity = FileIdentity(rawValue: identityString)
            else {
                throw OrganizerDatabaseError.invalidIdentity(Self.sqliteString(statement, column: 2) ?? "")
            }

            rows.append(
                FileCacheRecord(
                    namespace: namespaceValue,
                    path: path,
                    identity: identity,
                    size: sqlite3_column_int64(statement, 3),
                    modificationTime: sqlite3_column_double(statement, 4)
                )
            )
        }

        return rows
    }

    public func saveCacheRecords(_ records: [FileCacheRecord]) throws {
        guard !records.isEmpty else { return }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let statement = try prepare(
                "REPLACE INTO FileCache (id, path, hash, size, mtime) VALUES (?, ?, ?, ?, ?)"
            )
            defer { sqlite3_finalize(statement) }

            for record in records {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_int(statement, 1, Int32(record.namespace.rawValue))
                sqlite3_bind_text(statement, 2, record.path, -1, Self.sqliteTransient)
                sqlite3_bind_text(statement, 3, record.identity.rawValue, -1, Self.sqliteTransient)
                sqlite3_bind_int64(statement, 4, record.size)
                sqlite3_bind_double(statement, 5, record.modificationTime)

                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw OrganizerDatabaseError.stepFailed(lastErrorMessage())
                }
            }

            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func enqueueJobs(_ jobs: [CopyJobRecord]) throws {
        guard !jobs.isEmpty else { return }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let statement = try prepare(
                "INSERT OR IGNORE INTO CopyJobs (src_path, dst_path, hash, status) VALUES (?, ?, ?, ?)"
            )
            defer { sqlite3_finalize(statement) }

            for job in jobs {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_text(statement, 1, job.sourcePath, -1, Self.sqliteTransient)
                sqlite3_bind_text(statement, 2, job.destinationPath, -1, Self.sqliteTransient)
                sqlite3_bind_text(statement, 3, job.identity.rawValue, -1, Self.sqliteTransient)
                sqlite3_bind_text(statement, 4, job.status.rawValue, -1, Self.sqliteTransient)

                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw OrganizerDatabaseError.stepFailed(lastErrorMessage())
                }
            }

            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func loadCopyJobs(status: CopyJobStatus? = nil) throws -> [CopyJobRecord] {
        let sql: String
        if status != nil {
            sql = "SELECT src_path, dst_path, hash, status FROM CopyJobs WHERE status = ? ORDER BY src_path"
        } else {
            sql = "SELECT src_path, dst_path, hash, status FROM CopyJobs ORDER BY src_path"
        }

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        if let status {
            sqlite3_bind_text(statement, 1, status.rawValue, -1, Self.sqliteTransient)
        }

        var rows: [CopyJobRecord] = []
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
                let identityString = Self.sqliteString(statement, column: 2),
                let identity = FileIdentity(rawValue: identityString),
                let statusString = Self.sqliteString(statement, column: 3),
                let jobStatus = CopyJobStatus(rawValue: statusString)
            else {
                throw OrganizerDatabaseError.invalidIdentity(Self.sqliteString(statement, column: 2) ?? "")
            }

            rows.append(
                CopyJobRecord(
                    sourcePath: sourcePath,
                    destinationPath: destinationPath,
                    identity: identity,
                    status: jobStatus
                )
            )
        }

        return rows
    }

    public func pendingJobCount() throws -> Int {
        try Int(scalarInt(statement: "SELECT COUNT(*) FROM CopyJobs WHERE status = 'PENDING'"))
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
        DestinationIndexSnapshot.fromCacheRecords(
            try loadCacheRecords(namespace: .destination),
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

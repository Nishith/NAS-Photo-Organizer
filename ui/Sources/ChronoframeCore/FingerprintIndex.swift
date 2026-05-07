import Foundation
import SQLite3

/// Persistent lookup table mapping file identity (BLAKE2b digest + size) to
/// paths and folder roots. Used by import prevention (Feature 4),
/// cross-folder dedup (Feature 5), and background scanning (Feature 10).
extension OrganizerDatabase {
    public func ensureFingerprintIndexSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS FingerprintIndex (
                digest TEXT NOT NULL,
                size INTEGER NOT NULL,
                path TEXT NOT NULL,
                folder_root TEXT NOT NULL,
                mtime REAL NOT NULL,
                PRIMARY KEY (path)
            );
            """
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS idx_fingerprint_digest ON FingerprintIndex(digest, size);"
        )
    }

    // MARK: - Lookup

    /// Returns all paths that share the given identity (digest + size).
    public func fingerprintLookup(digest: String, size: Int64) throws -> [FingerprintIndexRecord] {
        let statement = try prepare(
            "SELECT path, folder_root, mtime FROM FingerprintIndex WHERE digest = ? AND size = ?"
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, digest, -1, OrganizerDatabase.sqliteTransient)
        sqlite3_bind_int64(statement, 2, size)

        var results: [FingerprintIndexRecord] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw OrganizerDatabaseError.stepFailed(lastErrorMessage())
            }
            guard let path = OrganizerDatabase.sqliteString(statement, column: 0) else { continue }
            let folderRoot = OrganizerDatabase.sqliteString(statement, column: 1) ?? ""
            let mtime = sqlite3_column_double(statement, 2)
            results.append(FingerprintIndexRecord(
                digest: digest,
                size: size,
                path: path,
                folderRoot: folderRoot,
                modificationTime: mtime
            ))
        }
        return results
    }

    // MARK: - Insert / upsert

    public func saveFingerprintIndexRecords<S: Sequence>(_ records: S) throws
        where S.Element == FingerprintIndexRecord
    {
        let statement = try prepare(
            """
            REPLACE INTO FingerprintIndex (digest, size, path, folder_root, mtime)
            VALUES (?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }

        var wroteAny = false
        do {
            for record in records {
                if !wroteAny {
                    try execute("BEGIN IMMEDIATE TRANSACTION;")
                    wroteAny = true
                }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_text(statement, 1, record.digest, -1, OrganizerDatabase.sqliteTransient)
                sqlite3_bind_int64(statement, 2, record.size)
                sqlite3_bind_text(statement, 3, record.path, -1, OrganizerDatabase.sqliteTransient)
                sqlite3_bind_text(statement, 4, record.folderRoot, -1, OrganizerDatabase.sqliteTransient)
                sqlite3_bind_double(statement, 5, record.modificationTime)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw OrganizerDatabaseError.stepFailed(lastErrorMessage())
                }
            }
            if wroteAny {
                try execute("COMMIT;")
            }
        } catch {
            if wroteAny {
                try? execute("ROLLBACK;")
            }
            throw error
        }
    }

    // MARK: - Removal

    public func removeFingerprintIndexRecords(forFolder root: String) throws {
        let statement = try prepare("DELETE FROM FingerprintIndex WHERE folder_root = ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, root, -1, OrganizerDatabase.sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw OrganizerDatabaseError.stepFailed(lastErrorMessage())
        }
    }

    // MARK: - Bulk query

    public func allFingerprintDigests(forFolder root: String) throws -> Set<String> {
        let statement = try prepare(
            "SELECT DISTINCT digest FROM FingerprintIndex WHERE folder_root = ?"
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, root, -1, OrganizerDatabase.sqliteTransient)

        var digests: Set<String> = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw OrganizerDatabaseError.stepFailed(lastErrorMessage())
            }
            if let digest = OrganizerDatabase.sqliteString(statement, column: 0) {
                digests.insert(digest)
            }
        }
        return digests
    }
}

// MARK: - Record type

public struct FingerprintIndexRecord: Sendable, Equatable {
    public var digest: String
    public var size: Int64
    public var path: String
    public var folderRoot: String
    public var modificationTime: TimeInterval

    public init(
        digest: String,
        size: Int64,
        path: String,
        folderRoot: String,
        modificationTime: TimeInterval
    ) {
        self.digest = digest
        self.size = size
        self.path = path
        self.folderRoot = folderRoot
        self.modificationTime = modificationTime
    }
}

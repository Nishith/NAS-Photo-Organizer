import Foundation
import SQLite3

/// Per-file cache entry for the Deduplicate scanner. Keyed on `path` and
/// invalidated when `(size, mtime)` no longer match the file on disk. Stored
/// in the same `.organize_cache.db` SQLite database as the file-identity
/// cache so a single open connection serves both pipelines.
public struct DedupeFeatureRecord: Equatable, Sendable {
    public var path: String
    public var size: Int64
    public var modificationTime: TimeInterval
    public var dhash: UInt64?
    public var featurePrintData: Data?
    public var sharpness: Double
    public var faceScore: Double?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var captureDate: Date?
    public var pairedPath: String?

    public init(
        path: String,
        size: Int64,
        modificationTime: TimeInterval,
        dhash: UInt64? = nil,
        featurePrintData: Data? = nil,
        sharpness: Double = 0,
        faceScore: Double? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        captureDate: Date? = nil,
        pairedPath: String? = nil
    ) {
        self.path = path
        self.size = size
        self.modificationTime = modificationTime
        self.dhash = dhash
        self.featurePrintData = featurePrintData
        self.sharpness = sharpness
        self.faceScore = faceScore
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.captureDate = captureDate
        self.pairedPath = pairedPath
    }
}

extension OrganizerDatabase {
    /// Idempotent — call once per scan. Adds the `DedupeFeatures` table if
    /// it doesn't already exist. Existing organize-cache schemas are
    /// untouched.
    public func ensureDedupeFeaturesSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS DedupeFeatures (
                path TEXT PRIMARY KEY,
                size INTEGER NOT NULL,
                mtime REAL NOT NULL,
                dhash INTEGER,
                feature_print BLOB,
                sharpness REAL NOT NULL DEFAULT 0,
                face_score REAL,
                pixel_width INTEGER,
                pixel_height INTEGER,
                capture_date REAL,
                paired_path TEXT
            );
            """
        )
    }

    public func loadDedupeFeatureRecords() throws -> [String: DedupeFeatureRecord] {
        var rows: [String: DedupeFeatureRecord] = [:]
        let statement = try prepare(
            "SELECT path, size, mtime, dhash, feature_print, sharpness, face_score, pixel_width, pixel_height, capture_date, paired_path FROM DedupeFeatures"
        )
        defer { sqlite3_finalize(statement) }

        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw OrganizerDatabaseError.stepFailed(lastErrorMessage())
            }

            guard let path = OrganizerDatabase.sqliteString(statement, column: 0) else { continue }
            let size = sqlite3_column_int64(statement, 1)
            let mtime = sqlite3_column_double(statement, 2)

            var dhash: UInt64?
            if sqlite3_column_type(statement, 3) != SQLITE_NULL {
                dhash = UInt64(bitPattern: sqlite3_column_int64(statement, 3))
            }

            var featurePrintData: Data?
            if sqlite3_column_type(statement, 4) == SQLITE_BLOB,
               let bytes = sqlite3_column_blob(statement, 4) {
                let length = Int(sqlite3_column_bytes(statement, 4))
                featurePrintData = Data(bytes: bytes, count: length)
            }

            let sharpness = sqlite3_column_double(statement, 5)
            let faceScore: Double? = sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 6)
            let pixelWidth: Int? = sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 7))
            let pixelHeight: Int? = sqlite3_column_type(statement, 8) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 8))
            let captureDate: Date? = sqlite3_column_type(statement, 9) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 9))
            let pairedPath: String? = OrganizerDatabase.sqliteString(statement, column: 10)

            rows[path] = DedupeFeatureRecord(
                path: path,
                size: size,
                modificationTime: mtime,
                dhash: dhash,
                featurePrintData: featurePrintData,
                sharpness: sharpness,
                faceScore: faceScore,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                captureDate: captureDate,
                pairedPath: pairedPath
            )
        }
        return rows
    }

    /// Load all cached dedupe metadata except the heavyweight Vision feature
    /// print blob. The scanner uses this as its warm-cache fast path, then
    /// fetches feature blobs lazily only for pairs that survive cheap filters.
    public func loadDedupeFeatureMetadataRecords() throws -> [String: DedupeFeatureRecord] {
        var rows: [String: DedupeFeatureRecord] = [:]
        let statement = try prepare(
            "SELECT path, size, mtime, dhash, sharpness, face_score, pixel_width, pixel_height, capture_date, paired_path FROM DedupeFeatures"
        )
        defer { sqlite3_finalize(statement) }

        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw OrganizerDatabaseError.stepFailed(lastErrorMessage())
            }

            guard let path = OrganizerDatabase.sqliteString(statement, column: 0) else { continue }
            let size = sqlite3_column_int64(statement, 1)
            let mtime = sqlite3_column_double(statement, 2)

            var dhash: UInt64?
            if sqlite3_column_type(statement, 3) != SQLITE_NULL {
                dhash = UInt64(bitPattern: sqlite3_column_int64(statement, 3))
            }

            let sharpness = sqlite3_column_double(statement, 4)
            let faceScore: Double? = sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 5)
            let pixelWidth: Int? = sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 6))
            let pixelHeight: Int? = sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 7))
            let captureDate: Date? = sqlite3_column_type(statement, 8) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
            let pairedPath: String? = OrganizerDatabase.sqliteString(statement, column: 9)

            rows[path] = DedupeFeatureRecord(
                path: path,
                size: size,
                modificationTime: mtime,
                dhash: dhash,
                featurePrintData: nil,
                sharpness: sharpness,
                faceScore: faceScore,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                captureDate: captureDate,
                pairedPath: pairedPath
            )
        }
        return rows
    }

    public func loadDedupeFeaturePrintData(for paths: [String]) throws -> [String: Data] {
        guard !paths.isEmpty else { return [:] }

        let statement = try prepare("SELECT feature_print FROM DedupeFeatures WHERE path = ?")
        defer { sqlite3_finalize(statement) }

        var rows: [String: Data] = [:]
        rows.reserveCapacity(paths.count)

        for path in paths {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, path, -1, OrganizerDatabase.sqliteTransient)

            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE {
                continue
            }
            guard stepResult == SQLITE_ROW else {
                throw OrganizerDatabaseError.stepFailed(lastErrorMessage())
            }
            guard
                sqlite3_column_type(statement, 0) == SQLITE_BLOB,
                let bytes = sqlite3_column_blob(statement, 0)
            else {
                continue
            }
            let length = Int(sqlite3_column_bytes(statement, 0))
            rows[path] = Data(bytes: bytes, count: length)
        }

        return rows
    }

    public func saveDedupeFeatureRecords<S: Sequence>(_ records: S) throws where S.Element == DedupeFeatureRecord {
        let statement = try prepare(
            """
            REPLACE INTO DedupeFeatures
            (path, size, mtime, dhash, feature_print, sharpness, face_score, pixel_width, pixel_height, capture_date, paired_path)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                sqlite3_bind_text(statement, 1, record.path, -1, OrganizerDatabase.sqliteTransient)
                sqlite3_bind_int64(statement, 2, record.size)
                sqlite3_bind_double(statement, 3, record.modificationTime)
                if let dhash = record.dhash {
                    sqlite3_bind_int64(statement, 4, Int64(bitPattern: dhash))
                } else {
                    sqlite3_bind_null(statement, 4)
                }
                if let blob = record.featurePrintData {
                    _ = blob.withUnsafeBytes { rawBuffer in
                        sqlite3_bind_blob(statement, 5, rawBuffer.baseAddress, Int32(blob.count), OrganizerDatabase.sqliteTransient)
                    }
                } else {
                    sqlite3_bind_null(statement, 5)
                }
                sqlite3_bind_double(statement, 6, record.sharpness)
                if let faceScore = record.faceScore {
                    sqlite3_bind_double(statement, 7, faceScore)
                } else {
                    sqlite3_bind_null(statement, 7)
                }
                if let pixelWidth = record.pixelWidth {
                    sqlite3_bind_int64(statement, 8, Int64(pixelWidth))
                } else {
                    sqlite3_bind_null(statement, 8)
                }
                if let pixelHeight = record.pixelHeight {
                    sqlite3_bind_int64(statement, 9, Int64(pixelHeight))
                } else {
                    sqlite3_bind_null(statement, 9)
                }
                if let captureDate = record.captureDate {
                    sqlite3_bind_double(statement, 10, captureDate.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(statement, 10)
                }
                if let pairedPath = record.pairedPath {
                    sqlite3_bind_text(statement, 11, pairedPath, -1, OrganizerDatabase.sqliteTransient)
                } else {
                    sqlite3_bind_null(statement, 11)
                }
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

    /// Delete cache rows for any path that no longer exists in `currentPaths`.
    public func pruneDedupeFeatureRecords(notIn currentPaths: Set<String>) throws {
        let statement = try prepare("SELECT path FROM DedupeFeatures")
        defer { sqlite3_finalize(statement) }

        var stale: [String] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw OrganizerDatabaseError.stepFailed(lastErrorMessage())
            }
            guard let path = OrganizerDatabase.sqliteString(statement, column: 0) else { continue }
            if !currentPaths.contains(path) {
                stale.append(path)
            }
        }
        guard !stale.isEmpty else { return }

        let deleteStatement = try prepare("DELETE FROM DedupeFeatures WHERE path = ?")
        defer { sqlite3_finalize(deleteStatement) }

        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            for path in stale {
                sqlite3_reset(deleteStatement)
                sqlite3_clear_bindings(deleteStatement)
                sqlite3_bind_text(deleteStatement, 1, path, -1, OrganizerDatabase.sqliteTransient)
                guard sqlite3_step(deleteStatement) == SQLITE_DONE else {
                    throw OrganizerDatabaseError.stepFailed(lastErrorMessage())
                }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }
}

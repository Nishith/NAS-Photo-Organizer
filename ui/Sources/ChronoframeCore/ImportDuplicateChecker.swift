import Foundation

/// Pre-import check that compares incoming photos against an existing
/// `FingerprintIndex`. Streams progress and returns which files are
/// duplicates vs. unique.
public enum ImportDuplicateChecker {
    public struct CheckResult: Sendable, Equatable {
        public var totalFiles: Int
        public var duplicates: [DuplicateEntry]
        public var uniqueFiles: [String]
        public var duplicateBytes: Int64

        public init(
            totalFiles: Int = 0,
            duplicates: [DuplicateEntry] = [],
            uniqueFiles: [String] = [],
            duplicateBytes: Int64 = 0
        ) {
            self.totalFiles = totalFiles
            self.duplicates = duplicates
            self.uniqueFiles = uniqueFiles
            self.duplicateBytes = duplicateBytes
        }
    }

    public struct DuplicateEntry: Sendable, Equatable {
        public var sourcePath: String
        public var existingPath: String
        public var sizeBytes: Int64

        public init(sourcePath: String, existingPath: String, sizeBytes: Int64) {
            self.sourcePath = sourcePath
            self.existingPath = existingPath
            self.sizeBytes = sizeBytes
        }
    }

    /// Check source files against the fingerprint index for duplicates.
    public static func check(
        sourcePaths: [String],
        database: OrganizerDatabase,
        hasher: FileIdentityHasher,
        workerCount: Int = 4
    ) -> AsyncThrowingStream<ImportCheckEvent, Error> {
        let databaseReference = SendableDatabaseReference(database)
        return AsyncThrowingStream { continuation in
            Task.detached {
                let database = databaseReference.database
                let total = sourcePaths.count
                var duplicates: [DuplicateEntry] = []
                var uniqueFiles: [String] = []
                var duplicateBytes: Int64 = 0

                for (index, path) in sourcePaths.enumerated() {
                    if index > 0, index.isMultiple(of: 25) {
                        continuation.yield(.progress(checked: index, total: total))
                    }

                    let url = URL(fileURLWithPath: path)
                    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                          let size = Self.fileSize(from: attrs) else {
                        uniqueFiles.append(path)
                        continue
                    }

                    guard let identity = try? hasher.hashIdentity(at: url, knownSize: size) else {
                        uniqueFiles.append(path)
                        continue
                    }

                    do {
                        let matches = try database.fingerprintLookup(
                            digest: identity.digest, size: identity.size
                        )
                        if let existing = matches.first {
                            duplicates.append(DuplicateEntry(
                                sourcePath: path,
                                existingPath: existing.path,
                                sizeBytes: size
                            ))
                            duplicateBytes += size
                        } else {
                            uniqueFiles.append(path)
                        }
                    } catch {
                        uniqueFiles.append(path)
                    }
                }

                continuation.yield(.progress(checked: total, total: total))
                continuation.yield(.complete(CheckResult(
                    totalFiles: total,
                    duplicates: duplicates,
                    uniqueFiles: uniqueFiles,
                    duplicateBytes: duplicateBytes
                )))
                continuation.finish()
            }
        }
    }

    private static func fileSize(from attributes: [FileAttributeKey: Any]) -> Int64? {
        if let size = attributes[.size] as? NSNumber {
            return size.int64Value
        }
        return attributes[.size] as? Int64
    }

    private struct SendableDatabaseReference: @unchecked Sendable {
        let database: OrganizerDatabase

        init(_ database: OrganizerDatabase) {
            self.database = database
        }
    }
}

public enum ImportCheckEvent: Sendable {
    case progress(checked: Int, total: Int)
    case complete(ImportDuplicateChecker.CheckResult)
}

/// User's choice when duplicates are found during import.
public enum ImportDuplicateAction: String, Sendable, Codable, CaseIterable {
    case ask
    case alwaysSkip
    case alwaysImport
}

#if canImport(ChronoframeCore)
import ChronoframeCore
#endif
import Foundation

/// A single record describing a source path that has had at least one
/// successful transfer into a given destination.
public struct TransferredSourceRecord: Identifiable, Codable, Equatable, Sendable {
    public var sourcePath: String
    public var firstTransferredAt: Date
    public var lastTransferredAt: Date
    public var runCount: Int
    public var lastCopiedCount: Int
    public var totalCopiedCount: Int

    public var id: String { sourcePath }

    public init(
        sourcePath: String,
        firstTransferredAt: Date,
        lastTransferredAt: Date,
        runCount: Int,
        lastCopiedCount: Int,
        totalCopiedCount: Int
    ) {
        self.sourcePath = sourcePath
        self.firstTransferredAt = firstTransferredAt
        self.lastTransferredAt = lastTransferredAt
        self.runCount = runCount
        self.lastCopiedCount = lastCopiedCount
        self.totalCopiedCount = totalCopiedCount
    }
}

/// Reads and writes `.organize_transferred_sources.json` at a destination
/// root. The file records every source path a user has successfully
/// transferred into this destination so it can be displayed in the UI.
public struct TransferredSourcesLog {
    public static let fileName = ".organize_transferred_sources.json"

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func fileURL(forDestinationRoot destinationRoot: String) -> URL? {
        let trimmed = destinationRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
            .appendingPathComponent(Self.fileName)
    }

    public func load(destinationRoot: String) -> [TransferredSourceRecord] {
        guard let url = fileURL(forDestinationRoot: destinationRoot) else { return [] }
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let records = try decoder.decode([TransferredSourceRecord].self, from: data)
            return records.sorted { $0.lastTransferredAt > $1.lastTransferredAt }
        } catch {
            return []
        }
    }

    /// Records a successful transfer. Merges with any existing record for
    /// the same source path (updating counts and timestamps). Returns the
    /// full sorted list after the update.
    @discardableResult
    public func recordTransfer(
        sourcePath: String,
        destinationRoot: String,
        copiedCount: Int,
        at date: Date = Date()
    ) -> [TransferredSourceRecord] {
        let trimmedSource = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty, let url = fileURL(forDestinationRoot: destinationRoot) else {
            return load(destinationRoot: destinationRoot)
        }

        var records = load(destinationRoot: destinationRoot)
        if let index = records.firstIndex(where: { $0.sourcePath == trimmedSource }) {
            var existing = records[index]
            existing.lastTransferredAt = date
            existing.runCount += 1
            existing.lastCopiedCount = copiedCount
            existing.totalCopiedCount += copiedCount
            records[index] = existing
        } else {
            records.append(
                TransferredSourceRecord(
                    sourcePath: trimmedSource,
                    firstTransferredAt: date,
                    lastTransferredAt: date,
                    runCount: 1,
                    lastCopiedCount: copiedCount,
                    totalCopiedCount: copiedCount
                )
            )
        }

        records.sort { $0.lastTransferredAt > $1.lastTransferredAt }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(records)
            try data.write(to: url, options: .atomic)
        } catch {
            // Non-fatal: the transfer itself already succeeded.
        }

        return records
    }

    /// Removes a record for the given source path. Used by the UI's
    /// "Forget this source" action.
    @discardableResult
    public func removeRecord(sourcePath: String, destinationRoot: String) -> [TransferredSourceRecord] {
        guard let url = fileURL(forDestinationRoot: destinationRoot) else {
            return load(destinationRoot: destinationRoot)
        }
        var records = load(destinationRoot: destinationRoot)
        records.removeAll { $0.sourcePath == sourcePath }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(records)
            try data.write(to: url, options: .atomic)
        } catch {
            // Non-fatal.
        }
        return records
    }
}

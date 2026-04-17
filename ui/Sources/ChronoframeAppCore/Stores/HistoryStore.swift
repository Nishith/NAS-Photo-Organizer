#if canImport(ChronoframeCore)
import ChronoframeCore
#endif
import Foundation
import Combine

public final class HistoryStore: ObservableObject {
    @Published public private(set) var entries: [RunHistoryEntry]
    @Published public private(set) var transferredSources: [TransferredSourceRecord]
    @Published public private(set) var destinationRoot: String
    @Published public private(set) var lastRefreshError: String?
    private let indexer: any RunHistoryIndexing
    private let transferredSourcesLog: TransferredSourcesLog

    public init(
        entries: [RunHistoryEntry] = [],
        transferredSources: [TransferredSourceRecord] = [],
        destinationRoot: String = "",
        indexer: any RunHistoryIndexing = RunHistoryIndexer(),
        transferredSourcesLog: TransferredSourcesLog = TransferredSourcesLog()
    ) {
        self.entries = entries
        self.transferredSources = transferredSources
        self.destinationRoot = destinationRoot
        self.lastRefreshError = nil
        self.indexer = indexer
        self.transferredSourcesLog = transferredSourcesLog
    }

    public func refresh(destinationRoot: String) {
        self.destinationRoot = destinationRoot
        self.entries = []
        self.transferredSources = []
        self.lastRefreshError = nil

        let trimmed = destinationRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            entries = try indexer.index(destinationRoot: trimmed)
        } catch {
            lastRefreshError = error.localizedDescription
        }

        transferredSources = transferredSourcesLog.load(destinationRoot: trimmed)
    }

    /// Records a successful transfer in the per-destination JSON log and
    /// refreshes the in-memory `transferredSources` list.
    public func recordSuccessfulTransfer(sourcePath: String, destinationRoot: String, copiedCount: Int) {
        let trimmedSource = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDest = destinationRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty, !trimmedDest.isEmpty else { return }

        transferredSources = transferredSourcesLog.recordTransfer(
            sourcePath: trimmedSource,
            destinationRoot: trimmedDest,
            copiedCount: copiedCount
        )
    }

    /// Removes a source-path record from the per-destination log and updates the list.
    public func removeTransferredSource(_ record: TransferredSourceRecord) {
        let trimmedDest = destinationRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDest.isEmpty else { return }
        transferredSources = transferredSourcesLog.removeRecord(
            sourcePath: record.sourcePath,
            destinationRoot: trimmedDest
        )
    }

    /// Moves the artifact file for `entry` to the Trash and removes it from the in-memory list.
    /// Silently ignores entries whose file no longer exists on disk.
    public func remove(entry: RunHistoryEntry) {
        let url = URL(fileURLWithPath: entry.path)
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        entries.removeAll { $0.id == entry.id }
    }

    /// Moves all artifact files to the Trash and clears the in-memory list.
    public func removeAll() {
        for entry in entries {
            let url = URL(fileURLWithPath: entry.path)
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        entries.removeAll()
    }
}

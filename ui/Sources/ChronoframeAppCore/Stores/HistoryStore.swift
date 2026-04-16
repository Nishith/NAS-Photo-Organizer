#if canImport(ChronoframeCore)
import ChronoframeCore
#endif
import Foundation
import Combine

public final class HistoryStore: ObservableObject {
    @Published public private(set) var entries: [RunHistoryEntry]
    @Published public private(set) var destinationRoot: String
    @Published public private(set) var lastRefreshError: String?
    private let indexer: any RunHistoryIndexing

    public init(
        entries: [RunHistoryEntry] = [],
        destinationRoot: String = "",
        indexer: any RunHistoryIndexing = RunHistoryIndexer()
    ) {
        self.entries = entries
        self.destinationRoot = destinationRoot
        self.lastRefreshError = nil
        self.indexer = indexer
    }

    public func refresh(destinationRoot: String) {
        self.destinationRoot = destinationRoot
        self.entries = []
        self.lastRefreshError = nil

        let trimmed = destinationRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            entries = try indexer.index(destinationRoot: trimmed)
        } catch {
            lastRefreshError = error.localizedDescription
        }
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

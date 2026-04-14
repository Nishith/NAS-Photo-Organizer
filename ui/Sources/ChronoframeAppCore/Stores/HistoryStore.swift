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
}

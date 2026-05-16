import Foundation
#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif

@MainActor
final class HistoryCoordinator {
    private let preferencesStore: PreferencesStore
    private let setupStore: SetupStore
    private let historyStore: HistoryStore
    private let runSessionStore: RunSessionStore
    private let deduplicateSessionStore: DeduplicateSessionStore
    private let finderService: any FinderServicing
    private let navigate: @MainActor (AppRoute) -> Void
    private let makeSecurityScopeForDestination: @MainActor (String) -> SecurityScopedFolderAccess?

    init(
        preferencesStore: PreferencesStore,
        setupStore: SetupStore,
        historyStore: HistoryStore,
        runSessionStore: RunSessionStore,
        deduplicateSessionStore: DeduplicateSessionStore,
        finderService: any FinderServicing,
        navigate: @escaping @MainActor (AppRoute) -> Void,
        makeSecurityScopeForDestination: @escaping @MainActor (String) -> SecurityScopedFolderAccess? = { _ in nil }
    ) {
        self.preferencesStore = preferencesStore
        self.setupStore = setupStore
        self.historyStore = historyStore
        self.runSessionStore = runSessionStore
        self.deduplicateSessionStore = deduplicateSessionStore
        self.finderService = finderService
        self.navigate = navigate
        self.makeSecurityScopeForDestination = makeSecurityScopeForDestination
    }

    /// Triggers a revert of the receipt. Audit receipts go through the
    /// organize Run workspace so progress/summary show up there; dedupe
    /// receipts go through the Deduplicate workspace which already owns
    /// its own commit-progress surface.
    func revertHistoryEntry(_ entry: RunHistoryEntry) {
        switch entry.kind {
        case .auditReceipt:
            let destinationRoot = receiptDestinationRoot(for: entry)
            navigate(.organize(.run))
            runSessionStore.requestRevert(
                receiptURL: URL(fileURLWithPath: entry.path),
                destinationRoot: destinationRoot,
                securityScope: makeSecurityScopeForDestination(destinationRoot)
            )
        case .dedupeAuditReceipt:
            let destinationRoot = receiptDestinationRoot(for: entry)
            navigate(.deduplicate)
            deduplicateSessionStore.revert(
                receiptURL: URL(fileURLWithPath: entry.path),
                destinationRoot: destinationRoot,
                securityScope: makeSecurityScopeForDestination(destinationRoot)
            )
        case .reorganizeAuditReceipt:
            let destinationRoot = receiptDestinationRoot(for: entry)
            navigate(.organize(.run))
            runSessionStore.requestReorganizeRevert(
                receiptURL: URL(fileURLWithPath: entry.path),
                destinationRoot: destinationRoot,
                securityScope: makeSecurityScopeForDestination(destinationRoot)
            )
        default:
            return
        }
    }

    private func receiptDestinationRoot(for entry: RunHistoryEntry) -> String {
        let receiptURL = URL(fileURLWithPath: entry.path)
        let logDirectory = receiptURL.deletingLastPathComponent()
        if logDirectory.lastPathComponent == ".organize_logs" {
            return logDirectory.deletingLastPathComponent().path
        }
        return historyStore.destinationRoot
    }

    func revealHistoryEntry(_ entry: RunHistoryEntry) {
        finderService.revealInFinder(entry.path)
    }

    func openHistoryEntry(_ entry: RunHistoryEntry) {
        finderService.openPath(entry.path)
    }

    func useHistoricalSource(_ record: TransferredSourceRecord) {
        if setupStore.usingProfile {
            setupStore.clearProfileSelection()
            preferencesStore.lastSelectedProfileName = ""
        }

        setupStore.sourcePath = record.sourcePath
        preferencesStore.lastManualSourcePath = record.sourcePath
        navigate(.organize(.setup))
    }

    func revealTransferredSource(_ record: TransferredSourceRecord) {
        finderService.revealInFinder(record.sourcePath)
    }

    func forgetTransferredSource(_ record: TransferredSourceRecord) {
        historyStore.removeTransferredSource(record)
    }
}

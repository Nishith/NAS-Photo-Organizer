#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import Foundation
import XCTest
@testable import ChronoframeApp

final class HistoryCoordinatorTests: XCTestCase {
    @MainActor
    func testHistoryActionsOpenRevealReuseAndForgetRecords() {
        let harness = AppStateHarness()
        var route: AppRoute?
        let coordinator = HistoryCoordinator(
            preferencesStore: harness.preferencesStore,
            setupStore: harness.setupStore,
            historyStore: harness.historyStore,
            runSessionStore: harness.runSessionStore,
            deduplicateSessionStore: harness.deduplicateSessionStore,
            finderService: harness.finderService,
            navigate: { route = $0 }
        )

        let entry = RunHistoryEntry(
            kind: .runLog,
            title: "Run Log",
            path: "/tmp/destination/.organize_log.txt",
            createdAt: Date()
        )
        let record = TransferredSourceRecord(
            sourcePath: "/Volumes/Card",
            firstTransferredAt: Date(),
            lastTransferredAt: Date(),
            runCount: 1,
            lastCopiedCount: 10,
            totalCopiedCount: 10
        )

        coordinator.openHistoryEntry(entry)
        coordinator.revealHistoryEntry(entry)
        coordinator.useHistoricalSource(record)
        coordinator.revealTransferredSource(record)
        coordinator.forgetTransferredSource(record)

        XCTAssertEqual(harness.finderService.openedPaths, ["/tmp/destination/.organize_log.txt"])
        XCTAssertEqual(harness.finderService.revealedPaths, [
            "/tmp/destination/.organize_log.txt",
            "/Volumes/Card",
        ])
        XCTAssertEqual(route, .organize(.setup))
        XCTAssertEqual(harness.setupStore.sourcePath, "/Volumes/Card")
    }
}

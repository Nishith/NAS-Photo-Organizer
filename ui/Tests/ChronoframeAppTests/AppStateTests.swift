#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import Foundation
import XCTest
@testable import ChronoframeApp

final class AppStateTests: XCTestCase {
    @MainActor
    func testUITestScenarioParsesEnvironmentAndMarksSettingsLaunches() {
        XCTAssertEqual(
            UITestScenario.current(environment: ["CHRONOFRAME_UI_TEST_SCENARIO": "historyPopulated"]),
            .historyPopulated
        )
        XCTAssertNil(UITestScenario.current(environment: [:]))
        XCTAssertNil(UITestScenario.current(environment: ["CHRONOFRAME_UI_TEST_SCENARIO": "unknown"]))
        XCTAssertTrue(UITestScenario.settingsSections.opensSettingsOnLaunch)
        XCTAssertFalse(UITestScenario.setupReady.opensSettingsOnLaunch)
    }

    @MainActor
    func testUITestAppStateFactorySeedsHistoryAndProfilesScenarios() {
        let historyState = UITestAppStateFactory.make(scenario: .historyPopulated)

        XCTAssertEqual(historyState.selection, .history)
        XCTAssertEqual(historyState.historyStore.destinationRoot, "/Volumes/Archive/Chronoframe Library")
        XCTAssertEqual(historyState.historyStore.entries.map(\.title), ["Dry Run Report", "Transfer Receipt", "Run Log"])
        XCTAssertEqual(historyState.historyStore.transferredSources.count, 1)
        XCTAssertEqual(historyState.historyStore.transferredSources.first?.sourcePath, "/Volumes/Card/April Session")

        let profilesState = UITestAppStateFactory.make(scenario: .profilesPopulated)

        XCTAssertEqual(profilesState.selection, .profiles)
        XCTAssertTrue(profilesState.setupStore.usingProfile)
        XCTAssertEqual(profilesState.setupStore.selectedProfileName, "Meridian Travel")
        XCTAssertEqual(profilesState.setupStore.newProfileName, "Weekend Archive")
        XCTAssertEqual(profilesState.setupStore.profiles.map(\.name), ["Meridian Travel", "Studio Imports"])
    }

    @MainActor
    func testUITestAppStateFactoryStartsPreviewForRunScenario() async {
        let appState = UITestAppStateFactory.make(scenario: .runPreviewReview)

        let finished = await waitForCondition(timeoutNanoseconds: 2_000_000_000) {
            appState.runSessionStore.summary?.status == .dryRunFinished
        }

        XCTAssertTrue(finished)
        XCTAssertEqual(appState.selection, .run)
        XCTAssertEqual(appState.runSessionStore.summary?.metrics.plannedCount, 42)
        XCTAssertEqual(
            appState.runSessionStore.summary?.artifacts.reportPath,
            "/Volumes/Archive/Chronoframe Library/.organize_logs/dry_run_report.csv"
        )
    }

    @MainActor
    func testBootstrapRestoresManualBookmarksAndRefreshesHistory() {
        let harness = AppStateHarness()
        harness.preferencesStore.storeBookmark(
            FolderBookmark(key: "manual.source", path: "/Volumes/OldCard", data: Data([0x01]))
        )
        harness.preferencesStore.storeBookmark(
            FolderBookmark(key: "manual.destination", path: "/Volumes/OldArchive", data: Data([0x02]))
        )
        harness.folderAccessService.resolvedBookmarks["manual.source"] = ResolvedFolderBookmark(
            url: URL(fileURLWithPath: "/Volumes/NewCard"),
            refreshedBookmark: FolderBookmark(key: "manual.source", path: "/Volumes/NewCard", data: Data([0x11]))
        )
        harness.folderAccessService.resolvedBookmarks["manual.destination"] = ResolvedFolderBookmark(
            url: URL(fileURLWithPath: "/Volumes/NewArchive"),
            refreshedBookmark: FolderBookmark(key: "manual.destination", path: "/Volumes/NewArchive", data: Data([0x22]))
        )

        let appState = harness.makeAppState()

        XCTAssertEqual(appState.setupStore.sourcePath, "/Volumes/NewCard")
        XCTAssertEqual(appState.setupStore.destinationPath, "/Volumes/NewArchive")
        XCTAssertEqual(appState.preferencesStore.lastManualSourcePath, "/Volumes/NewCard")
        XCTAssertEqual(appState.preferencesStore.lastManualDestinationPath, "/Volumes/NewArchive")
        XCTAssertEqual(appState.preferencesStore.bookmark(for: "manual.source")?.path, "/Volumes/NewCard")
        XCTAssertEqual(appState.preferencesStore.bookmark(for: "manual.destination")?.path, "/Volumes/NewArchive")
        XCTAssertEqual(appState.historyStore.destinationRoot, "/Volumes/NewArchive")
    }

    @MainActor
    func testFacadeForwardsPreviewAndTransferFlows() async {
        let harness = AppStateHarness()
        harness.setupStore.sourcePath = "/tmp/source"
        harness.setupStore.destinationPath = "/tmp/destination"
        harness.engine.startMode = .events([
            .complete(
                RunSummary(
                    status: .dryRunFinished,
                    title: "Preview complete",
                    metrics: RunMetrics(plannedCount: 1),
                    artifacts: RunArtifactPaths(
                        destinationRoot: "/tmp/destination",
                        reportPath: "/tmp/destination/.organize_logs/dry_run_report.csv",
                        logFilePath: "/tmp/destination/.organize_log.txt",
                        logsDirectoryPath: "/tmp/destination/.organize_logs"
                    )
                )
            )
        ])
        let appState = harness.makeAppState()
        appState.setupStore.sourcePath = "/tmp/source"
        appState.setupStore.destinationPath = "/tmp/destination"

        await appState.startPreview()
        let finished = await waitForCondition { appState.runSessionStore.summary != nil }

        XCTAssertTrue(finished)
        XCTAssertEqual(appState.selection, .run)
        XCTAssertEqual(harness.engine.startConfigurations.count, 1)
        harness.engine.preflightResult = .success(
            RunPreflight(
                configuration: RunConfiguration(mode: .transfer, sourcePath: "/tmp/source", destinationPath: "/tmp/destination"),
                resolvedSourcePath: "/tmp/source",
                resolvedDestinationPath: "/tmp/destination",
                pendingJobCount: 2
            )
        )
        harness.engine.resumeMode = .events([
            .complete(
                RunSummary(
                    status: .finished,
                    title: "Transfer complete",
                    metrics: RunMetrics(copiedCount: 3),
                    artifacts: RunArtifactPaths(destinationRoot: "/tmp/destination")
                )
            )
        ])

        await appState.startTransfer()

        XCTAssertEqual(appState.selection, .run)
        XCTAssertEqual(appState.runSessionStore.prompt?.kind, .resumePendingJobs)

        appState.confirmRunPrompt()
        let transferFinished = await waitForCondition { appState.runSessionStore.summary?.status == .finished }

        XCTAssertTrue(transferFinished)
        XCTAssertEqual(harness.engine.resumeConfigurations.count, 1)
    }

    @MainActor
    func testFacadeRoutesProfileAndHistoryActionsAcrossCollaborators() async {
        let harness = AppStateHarness()
        harness.repository.profiles = [
            Profile(name: "travel", sourcePath: "/Volumes/Card", destinationPath: "/Volumes/Trips")
        ]
        harness.preferencesStore.storeBookmark(FolderBookmark(key: "manual.source", path: "/Volumes/Card", data: Data([0x01])))
        harness.preferencesStore.storeBookmark(FolderBookmark(key: "manual.destination", path: "/Volumes/Trips", data: Data([0x02])))
        let appState = harness.makeAppState()

        appState.refreshProfiles()
        appState.useProfile(named: "travel")
        appState.setupStore.newProfileName = "archive"
        appState.saveCurrentPathsAsProfile()

        let record = TransferredSourceRecord(
            sourcePath: "/Volumes/Card",
            firstTransferredAt: Date(),
            lastTransferredAt: Date(),
            runCount: 1,
            lastCopiedCount: 10,
            totalCopiedCount: 10
        )
        appState.useHistoricalSource(record)

        XCTAssertEqual(appState.selection, .setup)
        XCTAssertEqual(appState.setupStore.selectedProfileName, "")
        XCTAssertEqual(appState.setupStore.sourcePath, "/Volumes/Card")
        XCTAssertEqual(harness.repository.savedProfiles.last?.name, "archive")
    }
}

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

        XCTAssertEqual(historyState.selection, .organize)
        XCTAssertEqual(historyState.organizeSubSelection, .history)
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
        XCTAssertEqual(appState.selection, .organize)
        XCTAssertEqual(appState.organizeSubSelection, .run)
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
    func testBootstrapRestoresDeduplicateFolderBookmark() {
        let harness = AppStateHarness()
        harness.preferencesStore.storeBookmark(
            FolderBookmark(key: "deduplicate.destination", path: "/Volumes/OldDedupe", data: Data([0x03]))
        )
        harness.folderAccessService.resolvedBookmarks["deduplicate.destination"] = ResolvedFolderBookmark(
            url: URL(fileURLWithPath: "/Volumes/NewDedupe"),
            refreshedBookmark: FolderBookmark(key: "deduplicate.destination", path: "/Volumes/NewDedupe", data: Data([0x33]))
        )

        let appState = harness.makeAppState()

        XCTAssertEqual(appState.deduplicateDestinationPath, "/Volumes/NewDedupe")
        XCTAssertEqual(harness.preferencesStore.lastDeduplicateDestinationPath, "/Volumes/NewDedupe")
        XCTAssertEqual(harness.preferencesStore.bookmark(for: "deduplicate.destination")?.path, "/Volumes/NewDedupe")
    }

    @MainActor
    func testDeduplicateFolderPickerStoresIndependentPathAndBookmark() async {
        let harness = AppStateHarness()
        harness.setupStore.destinationPath = "/Volumes/Organize"
        harness.folderAccessService.nextChosenFolder = URL(fileURLWithPath: "/Volumes/Dedupe")
        let appState = harness.makeAppState(performInitialBootstrap: false)

        await appState.chooseDeduplicateDestinationFolder()

        XCTAssertEqual(harness.setupStore.destinationPath, "/Volumes/Organize")
        XCTAssertEqual(harness.preferencesStore.lastDeduplicateDestinationPath, "/Volumes/Dedupe")
        XCTAssertEqual(appState.deduplicateDestinationPath, "/Volumes/Dedupe")
        XCTAssertEqual(harness.folderAccessService.chooseFolderCalls.count, 1, "Picker must not double-prompt")
        XCTAssertEqual(harness.folderAccessService.chooseFolderCalls.last?.startingAt, "/Volumes/Organize")
        XCTAssertEqual(harness.folderAccessService.chooseFolderCalls.last?.prompt, "Choose Deduplicate Folder")
        XCTAssertEqual(harness.folderAccessService.bookmarkURLs, [URL(fileURLWithPath: "/Volumes/Dedupe")])
        XCTAssertEqual(harness.preferencesStore.bookmark(for: "deduplicate.destination")?.path, "/Volumes/Dedupe")
    }

    /// Regression for review rec #2: bookmark-creation failure used to be
    /// swallowed via `try?`, leaving the path persisted with no bookmark.
    /// The picker must now leave the path unchanged and surface a
    /// transient error so the user knows the folder didn't take.
    @MainActor
    func testChooseDeduplicateDestinationSurfacesBookmarkCreationFailure() async {
        let harness = AppStateHarness()
        harness.preferencesStore.lastDeduplicateDestinationPath = "/Volumes/Existing"
        harness.folderAccessService.nextChosenFolder = URL(fileURLWithPath: "/Volumes/NewFolder")
        harness.folderAccessService.bookmarkCreationFailures["deduplicate.destination"] = AppTestFailure.expectedFailure("disk full")
        let appState = harness.makeAppState(performInitialBootstrap: false)

        await appState.chooseDeduplicateDestinationFolder()

        XCTAssertNotNil(appState.transientErrorMessage, "Bookmark failure must surface a transient error")
        XCTAssertEqual(
            harness.preferencesStore.lastDeduplicateDestinationPath,
            "/Volumes/Existing",
            "Path must remain unchanged when the bookmark could not be created"
        )
        XCTAssertNil(harness.preferencesStore.bookmark(for: "deduplicate.destination"))
    }

    /// Regression for review rec #1: when the stored bookmark no longer
    /// resolves (folder deleted, volume unmounted), bootstrap must drop
    /// both the bookmark and the path so future scans fall back to the
    /// Organize destination instead of silently scanning a dead path.
    @MainActor
    func testBootstrapClearsDeduplicateDestinationWhenBookmarkResolutionFails() {
        let harness = AppStateHarness()
        harness.preferencesStore.lastDeduplicateDestinationPath = "/Volumes/Gone"
        harness.preferencesStore.storeBookmark(
            FolderBookmark(key: "deduplicate.destination", path: "/Volumes/Gone", data: Data([0x09]))
        )
        harness.folderAccessService.bookmarkResolutionFailures.insert("deduplicate.destination")

        let appState = harness.makeAppState()

        XCTAssertEqual(harness.preferencesStore.lastDeduplicateDestinationPath, "")
        XCTAssertNil(harness.preferencesStore.bookmark(for: "deduplicate.destination"))
        XCTAssertFalse(appState.hasDedicatedDeduplicateDestinationPath)
    }

    /// Review rec #4: explicit "Use Organize Destination" affordance
    /// drops the dedicated dedupe folder and reverts to the fallback.
    @MainActor
    func testClearDeduplicateDestinationFolderRevertsToOrganizeFallback() {
        let harness = AppStateHarness()
        harness.setupStore.destinationPath = "/Volumes/Organize"
        harness.preferencesStore.lastDeduplicateDestinationPath = "/Volumes/Dedupe"
        harness.preferencesStore.storeBookmark(
            FolderBookmark(key: "deduplicate.destination", path: "/Volumes/Dedupe", data: Data([0x10]))
        )
        let appState = harness.makeAppState(performInitialBootstrap: false)

        XCTAssertTrue(appState.hasDedicatedDeduplicateDestinationPath)

        appState.clearDeduplicateDestinationFolder()

        XCTAssertFalse(appState.hasDedicatedDeduplicateDestinationPath)
        XCTAssertEqual(appState.deduplicateDestinationPath, "/Volumes/Organize")
        XCTAssertNil(harness.preferencesStore.bookmark(for: "deduplicate.destination"))
    }

    /// Review rec #14: Reveal in Finder for the dedupe folder.
    @MainActor
    func testRevealDeduplicateDestinationCallsFinderService() {
        let harness = AppStateHarness()
        harness.preferencesStore.lastDeduplicateDestinationPath = "/Volumes/Dedupe"
        let appState = harness.makeAppState(performInitialBootstrap: false)

        appState.revealDeduplicateDestinationInFinder()

        XCTAssertEqual(harness.finderService.revealedPaths, ["/Volumes/Dedupe"])
    }

    @MainActor
    func testDeduplicateScanUsesDedicatedFolderWhenSetAndFallsBackOtherwise() {
        let harness = AppStateHarness()
        harness.setupStore.destinationPath = "/Volumes/Organize"
        let appState = harness.makeAppState(performInitialBootstrap: false)

        appState.startDeduplicateScan()
        XCTAssertEqual(harness.deduplicateEngine.lastScanConfiguration?.destinationPath, "/Volumes/Organize")

        harness.preferencesStore.lastDeduplicateDestinationPath = "/Volumes/Dedupe"
        appState.startDeduplicateScan()

        XCTAssertEqual(harness.deduplicateEngine.lastScanConfiguration?.destinationPath, "/Volumes/Dedupe")
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
        XCTAssertEqual(appState.selection, .organize)
        XCTAssertEqual(appState.organizeSubSelection, .run)
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

        XCTAssertEqual(appState.selection, .organize)
        XCTAssertEqual(appState.organizeSubSelection, .run)
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

        XCTAssertEqual(appState.selection, .organize)
        XCTAssertEqual(appState.organizeSubSelection, .setup)
        XCTAssertEqual(appState.setupStore.selectedProfileName, "")
        XCTAssertEqual(appState.setupStore.sourcePath, "/Volumes/Card")
        XCTAssertEqual(harness.repository.savedProfiles.last?.name, "archive")
    }
}

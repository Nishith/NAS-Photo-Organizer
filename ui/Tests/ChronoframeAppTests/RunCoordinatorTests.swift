#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import Foundation
import XCTest
@testable import ChronoframeApp

final class RunCoordinatorTests: XCTestCase {
    @MainActor
    func testStartPreviewSelectsRunAndFinderActionsUseArtifacts() async {
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
        var route: AppRoute?
        let coordinator = RunCoordinator(
            preferencesStore: harness.preferencesStore,
            setupStore: harness.setupStore,
            historyStore: harness.historyStore,
            runSessionStore: harness.runSessionStore,
            finderService: harness.finderService,
            showSettingsWindowAction: {},
            navigate: { route = $0 },
            canStartRun: { true }
        )

        await coordinator.startPreview()
        let finished = await waitForCondition { harness.runSessionStore.summary != nil }

        XCTAssertTrue(finished)
        XCTAssertEqual(route, .organize(.run))
        XCTAssertEqual(harness.engine.startConfigurations.count, 1)

        coordinator.openDestination()
        coordinator.openReport()
        coordinator.openLogsDirectory()

        XCTAssertEqual(harness.finderService.openedPaths, [
            "/tmp/destination",
            "/tmp/destination/.organize_logs/dry_run_report.csv",
            "/tmp/destination/.organize_logs",
        ])
    }

    @MainActor
    func testStartTransferPromptRoutingDismissalAndSettingsStayWired() async {
        let harness = AppStateHarness()
        harness.setupStore.sourcePath = "/tmp/source"
        harness.setupStore.destinationPath = "/tmp/destination"
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
        var route: AppRoute?
        var settingsOpened = 0
        let coordinator = RunCoordinator(
            preferencesStore: harness.preferencesStore,
            setupStore: harness.setupStore,
            historyStore: harness.historyStore,
            runSessionStore: harness.runSessionStore,
            finderService: harness.finderService,
            showSettingsWindowAction: { settingsOpened += 1 },
            navigate: { route = $0 },
            canStartRun: { true }
        )

        await coordinator.startTransfer()
        XCTAssertEqual(route, .organize(.run))
        XCTAssertEqual(harness.runSessionStore.prompt?.kind, .resumePendingJobs)

        coordinator.confirmRunPrompt()
        let finished = await waitForCondition { harness.runSessionStore.summary?.status == .finished }
        XCTAssertTrue(finished)
        XCTAssertEqual(harness.engine.resumeConfigurations.count, 1)

        coordinator.openSettingsWindow()
        XCTAssertEqual(settingsOpened, 1)

        harness.engine.preflightResult = .success(
            RunPreflight(
                configuration: RunConfiguration(mode: .transfer, sourcePath: "/tmp/source", destinationPath: "/tmp/destination"),
                resolvedSourcePath: "/tmp/source",
                resolvedDestinationPath: "/tmp/destination"
            )
        )

        await coordinator.startTransfer()
        XCTAssertEqual(harness.runSessionStore.prompt?.kind, .confirmTransfer)
        coordinator.dismissRunPrompt()
        XCTAssertNil(harness.runSessionStore.prompt)
        XCTAssertEqual(harness.runSessionStore.status, .idle)
    }
}

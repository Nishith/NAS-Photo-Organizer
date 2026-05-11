#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import XCTest
@testable import ChronoframeApp

final class RunWorkspaceModelTests: XCTestCase {
    func testPreviewReviewStateComputesTransferReadinessAndIssueSummary() {
        let model = RunWorkspaceModel(
            context: RunWorkspaceContext(
                status: .dryRunFinished,
                currentMode: .preview,
                currentTaskTitle: "Preview complete",
                currentPhase: .classification,
                progress: 1,
                metrics: RunMetrics(
                    discoveredCount: 84,
                    plannedCount: 42,
                    alreadyInDestinationCount: 29,
                    duplicateCount: 7,
                    hashErrorCount: 1,
                    copiedCount: 0,
                    failedCount: 0,
                    errorCount: 1
                ),
                summary: RunSummary(
                    status: .dryRunFinished,
                    title: "Preview complete",
                    metrics: RunMetrics(plannedCount: 42),
                    artifacts: RunArtifactPaths(destinationRoot: "/Volumes/Archive")
                ),
                lastErrorMessage: nil,
                warningCount: 1,
                errorCount: 1,
                issueCount: 1,
                logEntries: [
                    RunWorkspaceLogLine(id: 1, text: "WARNING: review metadata"),
                    RunWorkspaceLogLine(id: 2, text: "ERROR: hashing failed"),
                ],
                historyDestinationRoot: "/Volumes/Archive",
                currentSourceRoot: "/Volumes/Ingest",
                canStartRun: true
            )
        )

        XCTAssertEqual(model.heroState.badgeTitle, "Preview Complete")
        XCTAssertTrue(model.showsPreviewReview)
        XCTAssertTrue(model.canStartTransferFromPreview)
        XCTAssertEqual(model.issueSummaryValue, "1 warning, 1 error")
        XCTAssertEqual(model.tabTitle(.issues), "Issues (2)")
        XCTAssertEqual(model.sourceSummaryValue, "/Volumes/Ingest")
    }

    func testFailedStateRoutesToIssuesAndFormatsArtifactsFallback() {
        let model = RunWorkspaceModel(
            context: RunWorkspaceContext(
                status: .failed,
                currentMode: .transfer,
                currentTaskTitle: "Failed",
                currentPhase: .copy,
                progress: 0.5,
                metrics: RunMetrics(failedCount: 3, errorCount: 2),
                summary: nil,
                lastErrorMessage: "Disk became unavailable",
                warningCount: 0,
                errorCount: 2,
                issueCount: 3,
                logEntries: [
                    RunWorkspaceLogLine(id: 1, text: "ERROR: disk unavailable"),
                ],
                historyDestinationRoot: "/Volumes/Fallback",
                currentSourceRoot: "",
                canStartRun: true
            )
        )

        XCTAssertEqual(model.heroState.primaryAction, .showIssues)
        XCTAssertEqual(model.heroState.message, "Disk became unavailable")
        XCTAssertEqual(model.destinationSummaryValue, "/Volumes/Fallback")
        XCTAssertEqual(model.sourceSummaryValue, "Source will appear here once a run is configured")
        XCTAssertEqual(model.issueEntries.count, 1)
        XCTAssertEqual(model.issueTone, .danger)
    }

    func testRunningTransferFormatsVisibleProgressDetails() {
        let model = RunWorkspaceModel(
            context: RunWorkspaceContext(
                status: .running,
                currentMode: .transfer,
                currentTaskTitle: "Copying files...",
                currentPhase: .copy,
                progress: 0.85,
                metrics: RunMetrics(
                    plannedCount: 8_271,
                    copiedCount: 7_064,
                    bytesCopied: 1_500_000,
                    bytesTotal: 3_000_000,
                    speedMBps: 12.3,
                    etaSeconds: 95
                ),
                summary: nil,
                lastErrorMessage: nil,
                warningCount: 0,
                errorCount: 0,
                issueCount: 0,
                logEntries: [],
                historyDestinationRoot: "/Volumes/Archive",
                currentSourceRoot: "/Volumes/Ingest",
                canStartRun: true
            )
        )

        XCTAssertTrue(model.showsCopyProgressDetails)
        XCTAssertEqual(model.fileProgressSummaryValue, "7,064 of 8,271 files · 85%")
        XCTAssertEqual(model.throughputSummaryValue, "12.3 MB/s · 1m 35s")
        XCTAssertNotEqual(model.byteProgressSummaryValue, "Measuring")
    }

    func testStalePreviewReviewDisablesTransfer() {
        let model = RunWorkspaceModel(
            context: RunWorkspaceContext(
                status: .dryRunFinished,
                currentMode: .preview,
                currentTaskTitle: "Preview complete",
                currentPhase: .classification,
                progress: 1,
                metrics: RunMetrics(plannedCount: 3),
                summary: nil,
                lastErrorMessage: nil,
                warningCount: 0,
                errorCount: 0,
                issueCount: 0,
                logEntries: [],
                historyDestinationRoot: "/Volumes/Archive",
                currentSourceRoot: "/Volumes/Ingest",
                canStartRun: true,
                previewReviewIsStale: true,
                previewReviewSummary: PreviewReviewSummary(totalCount: 3, readyCount: 3),
                previewReviewPath: "/Volumes/Archive/.organize_logs/preview_review.jsonl"
            )
        )

        XCTAssertFalse(model.canStartTransferFromPreview)
        XCTAssertTrue(model.previewReviewMessage.contains("Rebuild the preview"))
        XCTAssertEqual(model.tabTitle(.review), "Review")
    }

    // MARK: - isBlankIdle (design-critique fix #7)

    func testIsBlankIdleRequiresBothIdleStatusAndZeroDiscoveredFiles() {
        // Idle with nothing discovered → blank idle (show onboarding card, not empty sections)
        XCTAssertTrue(makeModel(status: .idle, discoveredCount: 0).isBlankIdle)

        // Idle but files were already discovered in this session → not blank
        XCTAssertFalse(makeModel(status: .idle, discoveredCount: 1).isBlankIdle)
        XCTAssertFalse(makeModel(status: .idle, discoveredCount: 200).isBlankIdle)

        // Active/terminal states are never blank idle regardless of count
        XCTAssertFalse(makeModel(status: .running, discoveredCount: 0).isBlankIdle)
        XCTAssertFalse(makeModel(status: .preflighting, discoveredCount: 0).isBlankIdle)
        XCTAssertFalse(makeModel(status: .finished, discoveredCount: 0).isBlankIdle)
        XCTAssertFalse(makeModel(status: .dryRunFinished, discoveredCount: 0).isBlankIdle)
        XCTAssertFalse(makeModel(status: .failed, discoveredCount: 0).isBlankIdle)
    }

    // MARK: - Helpers

    private func makeModel(status: RunStatus, discoveredCount: Int = 0) -> RunWorkspaceModel {
        RunWorkspaceModel(
            context: RunWorkspaceContext(
                status: status,
                currentMode: nil,
                currentTaskTitle: "",
                currentPhase: nil,
                progress: 0,
                metrics: RunMetrics(discoveredCount: discoveredCount),
                summary: nil,
                lastErrorMessage: nil,
                warningCount: 0,
                errorCount: 0,
                issueCount: 0,
                logEntries: [],
                historyDestinationRoot: "",
                currentSourceRoot: "",
                canStartRun: false
            )
        )
    }
}

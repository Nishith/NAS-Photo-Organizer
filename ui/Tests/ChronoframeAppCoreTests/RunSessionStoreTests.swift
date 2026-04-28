import Foundation
import XCTest
@testable import ChronoframeAppCore

final class RunSessionStoreTests: XCTestCase {
    private var historyStore: HistoryStore!
    private var logStore: RunLogStore!
    private var tempDestinationURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        historyStore = HistoryStore()
        logStore = RunLogStore(capacity: 500)
        tempDestinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunSessionStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDestinationURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDestinationURL {
            try? FileManager.default.removeItem(at: tempDestinationURL)
        }
        tempDestinationURL = nil
        historyStore = nil
        logStore = nil
        try super.tearDownWithError()
    }

    @MainActor
    func testPreviewRunCompletesAndUpdatesSessionState() async throws {
        let configuration = RunConfiguration(mode: .preview, sourcePath: "/tmp/source", destinationPath: tempDestinationURL.path)
        let preflight = RunPreflight(
            configuration: configuration,
            resolvedSourcePath: configuration.sourcePath,
            resolvedDestinationPath: configuration.destinationPath
        )
        let summary = RunSummary(
            status: .dryRunFinished,
            title: "Preview complete",
            metrics: RunMetrics(discoveredCount: 3, plannedCount: 2, errorCount: 1),
            artifacts: RunArtifactPaths(
                destinationRoot: tempDestinationURL.path,
                reportPath: tempDestinationURL.appendingPathComponent(".organize_logs/report.csv").path,
                logFilePath: tempDestinationURL.appendingPathComponent(".organize_log.txt").path,
                logsDirectoryPath: tempDestinationURL.appendingPathComponent(".organize_logs", isDirectory: true).path
            )
        )
        let histogram = [DateHistogramBucket(key: "2026-04", plannedCount: 2)]
        let engine = MockOrganizerEngine(
            preflightResult: .success(preflight),
            startMode: .events([
                .startup,
                .phaseStarted(phase: .discovery, total: 3),
                .phaseCompleted(phase: .discovery, result: RunPhaseResult(found: 3)),
                .copyPlanReady(count: 2),
                .dateHistogram(buckets: histogram),
                .issue(RunIssue(severity: .error, message: "Checksum mismatch")),
                .complete(summary),
            ])
        )
        let store = RunSessionStore(engine: engine, logStore: logStore, historyStore: historyStore)

        await store.requestRun(mode: .preview, configuration: configuration)
        let finished = await waitForCondition { store.summary != nil }
        XCTAssertTrue(finished)

        XCTAssertEqual(store.status, .dryRunFinished)
        XCTAssertEqual(store.currentMode, .preview)
        XCTAssertEqual(store.metrics.discoveredCount, 3)
        XCTAssertEqual(store.metrics.plannedCount, 2)
        XCTAssertEqual(store.metrics.errorCount, 1)
        XCTAssertEqual(store.metrics.dateHistogram, histogram)
        XCTAssertEqual(store.summary?.title, "Preview complete")
        XCTAssertEqual(store.summary?.metrics.dateHistogram, histogram)
        XCTAssertEqual(engine.startConfigurations.count, 1)
        XCTAssertTrue(store.logLines.contains("Engine started."))
        XCTAssertTrue(store.logLines.contains("Plan ready: 2 files queued for copy."))
        XCTAssertTrue(store.logLines.contains("ERROR: Checksum mismatch"))
        XCTAssertTrue(store.logLines.contains("Finished: Preview complete"))
    }

    @MainActor
    func testTransferRunShowsResumePromptAndConfirmUsesResumeStream() async throws {
        let configuration = RunConfiguration(mode: .transfer, sourcePath: "/tmp/source", destinationPath: tempDestinationURL.path)
        let preflight = RunPreflight(
            configuration: configuration,
            resolvedSourcePath: configuration.sourcePath,
            resolvedDestinationPath: configuration.destinationPath,
            pendingJobCount: 4
        )
        let engine = MockOrganizerEngine(
            preflightResult: .success(preflight),
            resumeMode: .events([
                .complete(
                    RunSummary(
                        status: .finished,
                        title: "Done",
                        metrics: RunMetrics(copiedCount: 4),
                        artifacts: RunArtifactPaths(destinationRoot: tempDestinationURL.path)
                    )
                )
            ])
        )
        let store = RunSessionStore(engine: engine, logStore: logStore, historyStore: historyStore)

        await store.requestRun(mode: .transfer, configuration: configuration)

        XCTAssertEqual(store.prompt?.kind, .resumePendingJobs)
        XCTAssertEqual(store.prompt?.title, "Resume Pending Transfer")
        XCTAssertEqual(engine.resumeConfigurations.count, 0)

        store.confirmPrompt()
        let resumed = await waitForCondition { store.summary?.status == .finished }
        XCTAssertTrue(resumed)

        XCTAssertEqual(engine.resumeConfigurations.count, 1)
        XCTAssertEqual(store.status, .finished)
        XCTAssertNil(store.prompt)
    }

    @MainActor
    func testMissingDependenciesCreatesBlockingPrompt() async {
        let configuration = RunConfiguration(mode: .preview, sourcePath: "/tmp/source", destinationPath: tempDestinationURL.path)
        let preflight = RunPreflight(
            configuration: configuration,
            resolvedSourcePath: configuration.sourcePath,
            resolvedDestinationPath: configuration.destinationPath,
            missingDependencies: ["rich", "pyyaml"]
        )
        let engine = MockOrganizerEngine(preflightResult: .success(preflight))
        let store = RunSessionStore(engine: engine, logStore: logStore, historyStore: historyStore)

        await store.requestRun(mode: .preview, configuration: configuration)

        XCTAssertEqual(store.status, .preflighting)
        XCTAssertEqual(store.prompt?.kind, .blockingError)
        XCTAssertTrue(store.prompt?.message.contains("rich, pyyaml") ?? false)

        store.dismissPrompt()
        XCTAssertEqual(store.status, .idle)
        XCTAssertEqual(store.currentTaskTitle, "Idle")
    }

    @MainActor
    func testCancelCurrentRunMarksCancelled() async {
        let configuration = RunConfiguration(mode: .preview, sourcePath: "/tmp/source", destinationPath: tempDestinationURL.path)
        let preflight = RunPreflight(
            configuration: configuration,
            resolvedSourcePath: configuration.sourcePath,
            resolvedDestinationPath: configuration.destinationPath
        )
        let engine = MockOrganizerEngine(preflightResult: .success(preflight), startMode: .pending)
        let store = RunSessionStore(engine: engine, logStore: logStore, historyStore: historyStore)

        await store.requestRun(mode: .preview, configuration: configuration)
        let running = await waitForCondition { store.isRunning }
        XCTAssertTrue(running)

        store.cancelCurrentRun()
        let cancelled = await waitForCondition { store.status == .cancelled }
        XCTAssertTrue(cancelled)

        XCTAssertEqual(engine.cancelCallCount, 1)
        XCTAssertEqual(store.summary?.status, .cancelled)
        XCTAssertEqual(store.currentTaskTitle, "Cancelled")
    }

    @MainActor
    func testStartFailureMarksSessionFailed() async {
        let configuration = RunConfiguration(mode: .preview, sourcePath: "/tmp/source", destinationPath: tempDestinationURL.path)
        let preflight = RunPreflight(
            configuration: configuration,
            resolvedSourcePath: configuration.sourcePath,
            resolvedDestinationPath: configuration.destinationPath
        )
        let engine = MockOrganizerEngine(
            preflightResult: .success(preflight),
            startMode: .fails(TestFailure.expectedFailure("backend launch failed"))
        )
        let store = RunSessionStore(engine: engine, logStore: logStore, historyStore: historyStore)

        await store.requestRun(mode: .preview, configuration: configuration)
        let failed = await waitForCondition { store.status == .failed }
        XCTAssertTrue(failed)

        XCTAssertEqual(
            store.lastErrorMessage,
            "Chronoframe could not finish this run. Your source files were left untouched. Check that both folders are available, then try again. Details: backend launch failed"
        )
        XCTAssertEqual(store.summary?.status, .failed)
        XCTAssertTrue(
            store.logLines.contains(
                "ERROR: Chronoframe could not finish this run. Your source files were left untouched. Check that both folders are available, then try again. Details: backend launch failed"
            )
        )
    }

    // MARK: - Cancellation timing variants

    @MainActor
    func testCancelDuringDiscoveryPhaseRecordsPhaseBeforeCancellation() async throws {
        let configuration = RunConfiguration(mode: .preview, sourcePath: "/tmp/source", destinationPath: tempDestinationURL.path)
        let preflight = RunPreflight(
            configuration: configuration,
            resolvedSourcePath: configuration.sourcePath,
            resolvedDestinationPath: configuration.destinationPath
        )
        // Stream yields a discovery-started event and then hangs, simulating a long scan.
        let engine = MockOrganizerEngine(preflightResult: .success(preflight), startMode: .pending)
        let store = RunSessionStore(engine: engine, logStore: logStore, historyStore: historyStore)

        await store.requestRun(mode: .preview, configuration: configuration)
        let running = await waitForCondition { store.isRunning }
        XCTAssertTrue(running)

        // Wait until the stream task has actually called engine.start() and the
        // continuation is live. status == .running only means beginStream() has
        // set the flag synchronously; the Task body (which calls engine.start())
        // is scheduled separately and may not have run yet.
        let continuationReady = await waitForCondition { engine.pendingContinuation != nil }
        XCTAssertTrue(continuationReady, "Engine continuation should be available before yielding events")

        // Inject a discovery phase event via the pending continuation before cancelling.
        engine.pendingContinuation?.yield(.phaseStarted(phase: .discovery, total: 50))
        let phaseSet = await waitForCondition { store.currentPhase == .discovery }
        XCTAssertTrue(phaseSet, "Phase should be set before cancellation")

        store.cancelCurrentRun()
        let cancelled = await waitForCondition { store.status == .cancelled }
        XCTAssertTrue(cancelled)
        XCTAssertEqual(store.summary?.status, .cancelled)
    }

    @MainActor
    func testCancelDuringCopyPhaseProducesCancelledSummary() async throws {
        let configuration = RunConfiguration(mode: .transfer, sourcePath: "/tmp/source", destinationPath: tempDestinationURL.path)
        let preflight = RunPreflight(
            configuration: configuration,
            resolvedSourcePath: configuration.sourcePath,
            resolvedDestinationPath: configuration.destinationPath,
            pendingJobCount: 0
        )
        let engine = MockOrganizerEngine(preflightResult: .success(preflight), startMode: .pending)
        let store = RunSessionStore(engine: engine, logStore: logStore, historyStore: historyStore)

        await store.requestRun(mode: .transfer, configuration: configuration)
        // Confirm the transfer prompt.
        store.confirmPrompt()
        let running = await waitForCondition { store.isRunning }
        XCTAssertTrue(running)

        // Wait until the stream task has actually called engine.start().
        let continuationReady = await waitForCondition { engine.pendingContinuation != nil }
        XCTAssertTrue(continuationReady, "Engine continuation should be available before yielding events")

        // Simulate copy phase in progress before cancellation.
        engine.pendingContinuation?.yield(.phaseStarted(phase: .copy, total: 100))
        engine.pendingContinuation?.yield(.phaseProgress(phase: .copy, completed: 30, total: 100, bytesCopied: 30_000, bytesTotal: 100_000))
        let progressSet = await waitForCondition { store.progress > 0 }
        XCTAssertTrue(progressSet)
        XCTAssertEqual(store.currentTaskTitle, "Copying files... 30 of 100 files…")
        XCTAssertEqual(store.metrics.plannedCount, 100)
        XCTAssertEqual(store.metrics.copiedCount, 30)
        XCTAssertEqual(store.metrics.bytesCopied, 30_000)
        XCTAssertEqual(store.metrics.bytesTotal, 100_000)

        store.cancelCurrentRun()
        let cancelled = await waitForCondition { store.status == .cancelled }
        XCTAssertTrue(cancelled)
        XCTAssertEqual(store.summary?.status, .cancelled)
        // Speed metrics should be cleared on cancellation.
        XCTAssertEqual(store.metrics.speedMBps, 0)
        XCTAssertNil(store.metrics.etaSeconds)
    }

    // MARK: - Status propagation from complete event

    @MainActor
    func testNothingToCopyStatusPropagatesFromCompleteEvent() async throws {
        let configuration = RunConfiguration(mode: .preview, sourcePath: "/tmp/source", destinationPath: tempDestinationURL.path)
        let preflight = RunPreflight(
            configuration: configuration,
            resolvedSourcePath: configuration.sourcePath,
            resolvedDestinationPath: configuration.destinationPath
        )
        let summary = RunSummary(
            status: .nothingToCopy,
            title: "Nothing to copy",
            metrics: RunMetrics(discoveredCount: 5, plannedCount: 0),
            artifacts: RunArtifactPaths(destinationRoot: tempDestinationURL.path)
        )
        let engine = MockOrganizerEngine(
            preflightResult: .success(preflight),
            startMode: .events([.complete(summary)])
        )
        let store = RunSessionStore(engine: engine, logStore: logStore, historyStore: historyStore)

        await store.requestRun(mode: .preview, configuration: configuration)
        let done = await waitForCondition { store.status == .nothingToCopy }
        XCTAssertTrue(done)
        XCTAssertEqual(store.summary?.title, "Nothing to copy")
        XCTAssertEqual(store.metrics.plannedCount, 0)
    }

    // MARK: - Accumulated issue/error counting

    @MainActor
    func testMultipleErrorIssuesAccumulateErrorCount() async throws {
        let configuration = RunConfiguration(mode: .preview, sourcePath: "/tmp/source", destinationPath: tempDestinationURL.path)
        let preflight = RunPreflight(
            configuration: configuration,
            resolvedSourcePath: configuration.sourcePath,
            resolvedDestinationPath: configuration.destinationPath
        )
        let summary = RunSummary(
            status: .dryRunFinished,
            title: "Preview complete",
            metrics: RunMetrics(errorCount: 3),
            artifacts: RunArtifactPaths(destinationRoot: tempDestinationURL.path)
        )
        let engine = MockOrganizerEngine(
            preflightResult: .success(preflight),
            startMode: .events([
                .issue(RunIssue(severity: .error, message: "Error 1")),
                .issue(RunIssue(severity: .warning, message: "Warning")),
                .issue(RunIssue(severity: .error, message: "Error 2")),
                .issue(RunIssue(severity: .error, message: "Error 3")),
                .complete(summary),
            ])
        )
        let store = RunSessionStore(engine: engine, logStore: logStore, historyStore: historyStore)

        await store.requestRun(mode: .preview, configuration: configuration)
        let done = await waitForCondition { store.summary != nil }
        XCTAssertTrue(done)

        // Final metrics come from the complete event (engine's authoritative count).
        XCTAssertEqual(store.metrics.errorCount, 3)
        // Log lines should contain all issues. Warnings use "⚠ " prefix per RunIssue.renderedLine.
        XCTAssertTrue(store.logLines.contains("ERROR: Error 1"))
        XCTAssertTrue(store.logLines.contains("⚠ Warning"))
        XCTAssertTrue(store.logLines.contains("ERROR: Error 2"))
    }

    // MARK: - Confirm-transfer prompt path

    @MainActor
    func testConfirmTransferPromptStartsFreshTransferStream() async throws {
        let configuration = RunConfiguration(mode: .transfer, sourcePath: "/tmp/source", destinationPath: tempDestinationURL.path)
        let preflight = RunPreflight(
            configuration: configuration,
            resolvedSourcePath: configuration.sourcePath,
            resolvedDestinationPath: configuration.destinationPath,
            pendingJobCount: 0  // fresh transfer (not resume)
        )
        let summary = RunSummary(
            status: .finished,
            title: "Done",
            metrics: RunMetrics(copiedCount: 2),
            artifacts: RunArtifactPaths(destinationRoot: tempDestinationURL.path)
        )
        let engine = MockOrganizerEngine(
            preflightResult: .success(preflight),
            startMode: .events([.complete(summary)])
        )
        let store = RunSessionStore(engine: engine, logStore: logStore, historyStore: historyStore)

        await store.requestRun(mode: .transfer, configuration: configuration)
        XCTAssertEqual(store.prompt?.kind, .confirmTransfer)
        XCTAssertEqual(engine.startConfigurations.count, 0, "Stream should not start until confirmed")

        store.confirmPrompt()
        let finished = await waitForCondition { store.status == .finished }
        XCTAssertTrue(finished)
        XCTAssertEqual(engine.startConfigurations.count, 1)
        XCTAssertEqual(engine.resumeConfigurations.count, 0, "Fresh transfer should use start, not resume")
    }

    @MainActor
    func testBackendPromptEventSurfacesBlockingPrompt() async {
        let configuration = RunConfiguration(mode: .preview, sourcePath: "/tmp/source", destinationPath: tempDestinationURL.path)
        let preflight = RunPreflight(
            configuration: configuration,
            resolvedSourcePath: configuration.sourcePath,
            resolvedDestinationPath: configuration.destinationPath
        )
        let engine = MockOrganizerEngine(
            preflightResult: .success(preflight),
            startMode: .events([.prompt(message: "Need confirmation")])
        )
        let store = RunSessionStore(engine: engine, logStore: logStore, historyStore: historyStore)

        await store.requestRun(mode: .preview, configuration: configuration)
        let prompted = await waitForCondition { store.prompt != nil }
        XCTAssertTrue(prompted)

        XCTAssertEqual(store.prompt?.kind, .blockingError)
        XCTAssertEqual(store.prompt?.title, "Organizer Needs Attention")
        XCTAssertEqual(
            store.prompt?.message,
            "Chronoframe needs attention before it can continue. Review the message below, then try again. Details: Need confirmation"
        )
    }
}

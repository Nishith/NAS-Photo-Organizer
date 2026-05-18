import Foundation
import XCTest
@testable import ChronoframeAppCore

final class RunSessionStoreTests: XCTestCase {
    // `nonisolated(unsafe)` lets the test's storage be observed from
    // both nonisolated setUp/tearDown and the @MainActor test bodies.
    // XCTest invokes these methods serially on the main thread, so
    // there's no concurrent access in practice.
    private nonisolated(unsafe) var historyStore: HistoryStore!
    private nonisolated(unsafe) var logStore: RunLogStore!
    private nonisolated(unsafe) var tempDestinationURL: URL!

    // Use the async `setUp()` / `tearDown()` overrides rather than
    // `setUpWithError() throws` so the body has an async context that
    // can call the @MainActor-isolated initializers.
    override func setUp() async throws {
        try await super.setUp()
        historyStore = await HistoryStore()
        logStore = await RunLogStore(capacity: 500)
        tempDestinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunSessionStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDestinationURL, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDestinationURL {
            try? FileManager.default.removeItem(at: tempDestinationURL)
        }
        tempDestinationURL = nil
        historyStore = nil
        logStore = nil
        try await super.tearDown()
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
    func testSecurityScopeClosesAfterRunCompletionAndPromptDismissal() async throws {
        let configuration = RunConfiguration(mode: .preview, sourcePath: "/tmp/source", destinationPath: tempDestinationURL.path)
        let preflight = RunPreflight(
            configuration: configuration,
            resolvedSourcePath: configuration.sourcePath,
            resolvedDestinationPath: configuration.destinationPath
        )
        let summary = RunSummary(
            status: .dryRunFinished,
            title: "Preview complete",
            metrics: RunMetrics(),
            artifacts: RunArtifactPaths(destinationRoot: tempDestinationURL.path)
        )
        let completionTracker = SecurityScopeCloseTracker()
        let completingStore = RunSessionStore(
            engine: MockOrganizerEngine(
                preflightResult: .success(preflight),
                startMode: .events([.complete(summary)])
            ),
            logStore: logStore,
            historyStore: historyStore
        )

        await completingStore.requestRun(
            mode: .preview,
            configuration: configuration,
            securityScope: completionTracker.makeScope()
        )
        let completed = await waitForCondition { completingStore.summary != nil }
        XCTAssertTrue(completed)
        XCTAssertEqual(completionTracker.closeCount, 1)
        completingStore.cancelCurrentRun()
        XCTAssertEqual(completionTracker.closeCount, 1, "Closing the session again must not double-close the security scope")

        let promptTracker = SecurityScopeCloseTracker()
        let promptStore = RunSessionStore(
            engine: MockOrganizerEngine(
                preflightResult: .success(RunPreflight(
                    configuration: configuration,
                    resolvedSourcePath: configuration.sourcePath,
                    resolvedDestinationPath: configuration.destinationPath,
                    pendingJobCount: 1
                ))
            ),
            logStore: RunLogStore(capacity: 10),
            historyStore: HistoryStore()
        )

        await promptStore.requestRun(
            mode: .transfer,
            configuration: configuration,
            securityScope: promptTracker.makeScope()
        )
        XCTAssertEqual(promptStore.status, .preflighting)
        XCTAssertEqual(promptTracker.closeCount, 0)
        promptStore.dismissPrompt()
        XCTAssertEqual(promptTracker.closeCount, 1)
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
    func testLateEventsFromCancelledStreamAreDroppedSilently() async {
        let configuration = RunConfiguration(mode: .preview, sourcePath: "/tmp/source", destinationPath: tempDestinationURL.path)
        let preflight = RunPreflight(
            configuration: configuration,
            resolvedSourcePath: configuration.sourcePath,
            resolvedDestinationPath: configuration.destinationPath
        )
        let engine = MockOrganizerEngine(preflightResult: .success(preflight), startMode: .pending)
        let store = RunSessionStore(engine: engine, logStore: logStore, historyStore: historyStore)

        await store.requestRun(mode: .preview, configuration: configuration)
        _ = await waitForCondition { engine.pendingContinuation != nil }
        XCTAssertTrue(store.isRunning)
        XCTAssertEqual(store.metrics.discoveredCount, 0)

        // Capture the continuation BEFORE cancelling so the cancel path doesn't
        // null it out before we can simulate the late yield.
        let continuation = engine.pendingContinuation
        store.cancelCurrentRun()
        _ = await waitForCondition { store.status == .cancelled }

        // Simulate an in-flight event that the engine yields after cancel but
        // before its stream loop reaches the next checkpoint. Without the
        // runEpoch gate this would still race in via `consume` and update the
        // metrics on a cancelled session.
        continuation?.yield(.phaseCompleted(phase: .discovery, result: RunPhaseResult(found: 999)))
        continuation?.finish()

        // Give MainActor a chance to process the late event.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.metrics.discoveredCount, 0, "Late events from a cancelled stream must not mutate the new session state")
        XCTAssertEqual(store.status, .cancelled)
    }

    @MainActor
    func testStartingSecondRunCancelsExistingEngineTask() async {
        let configuration = RunConfiguration(mode: .preview, sourcePath: "/tmp/source", destinationPath: tempDestinationURL.path)
        let preflight = RunPreflight(
            configuration: configuration,
            resolvedSourcePath: configuration.sourcePath,
            resolvedDestinationPath: configuration.destinationPath
        )
        let engine = MockOrganizerEngine(preflightResult: .success(preflight), startMode: .pending)
        let store = RunSessionStore(engine: engine, logStore: logStore, historyStore: historyStore)

        await store.requestRun(mode: .preview, configuration: configuration)
        let firstRunStarted = await waitForCondition { engine.pendingContinuation != nil }
        XCTAssertTrue(firstRunStarted)

        await store.requestRun(mode: .preview, configuration: configuration)
        let secondRunStarted = await waitForCondition { engine.startConfigurations.count == 2 }
        XCTAssertTrue(secondRunStarted)

        XCTAssertEqual(engine.cancelCallCount, 1)
        XCTAssertEqual(store.status, .running)
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

    @MainActor
    func testRevertStreamUpdatesMetricsArtifactsAndCompletionCopy() async throws {
        let receiptURL = tempDestinationURL
            .appendingPathComponent(".organize_logs", isDirectory: true)
            .appendingPathComponent("audit_receipt.json")
        let summary = RunSummary(
            status: .reverted,
            title: "Revert complete",
            metrics: RunMetrics(revertedCount: 2, skippedCount: 1, missingCount: 3),
            artifacts: RunArtifactPaths(destinationRoot: tempDestinationURL.path, reportPath: receiptURL.path)
        )
        let engine = MockOrganizerEngine(
            preflightResult: .success(
                RunPreflight(
                    configuration: RunConfiguration(mode: .preview, sourcePath: "", destinationPath: tempDestinationURL.path),
                    resolvedSourcePath: "",
                    resolvedDestinationPath: tempDestinationURL.path
                )
            ),
            revertMode: .events([
                .phaseStarted(phase: .revert, total: 6),
                .phaseCompleted(
                    phase: .revert,
                    result: RunPhaseResult(revertedCount: 2, skippedCount: 1, missingCount: 3)
                ),
                .complete(summary),
            ])
        )
        let store = RunSessionStore(engine: engine, logStore: logStore, historyStore: historyStore)

        store.requestRevert(receiptURL: receiptURL, destinationRoot: tempDestinationURL.path)
        let finished = await waitForCondition { store.status == .reverted }
        XCTAssertTrue(finished)

        XCTAssertEqual(engine.revertRequests.count, 1)
        XCTAssertEqual(engine.revertRequests.first?.receiptURL, receiptURL)
        XCTAssertEqual(store.currentMode, .revert)
        XCTAssertEqual(store.metrics.revertedCount, 2)
        XCTAssertEqual(store.metrics.skippedCount, 1)
        XCTAssertEqual(store.metrics.missingCount, 3)
        XCTAssertEqual(store.artifacts.reportPath, receiptURL.path)
        XCTAssertTrue(store.logLines.contains("Revert complete: 2 reverted, 1 preserved, 3 already missing."))
        XCTAssertTrue(store.logLines.contains("Finished: Revert complete"))
    }

    @MainActor
    func testReorganizeStreamUpdatesMetricsAndCompletionCopy() async throws {
        let summary = RunSummary(
            status: .reorganized,
            title: "Reorganize complete",
            metrics: RunMetrics(failedCount: 1, skippedCount: 2, movedCount: 4),
            artifacts: RunArtifactPaths(destinationRoot: tempDestinationURL.path)
        )
        let engine = MockOrganizerEngine(
            preflightResult: .success(
                RunPreflight(
                    configuration: RunConfiguration(mode: .preview, sourcePath: "", destinationPath: tempDestinationURL.path),
                    resolvedSourcePath: "",
                    resolvedDestinationPath: tempDestinationURL.path
                )
            ),
            reorganizeMode: .events([
                .phaseStarted(phase: .reorganize, total: 7),
                .phaseCompleted(
                    phase: .reorganize,
                    result: RunPhaseResult(failedCount: 1, skippedCount: 2, movedCount: 4)
                ),
                .complete(summary),
            ])
        )
        let store = RunSessionStore(engine: engine, logStore: logStore, historyStore: historyStore)

        store.requestReorganize(destinationRoot: tempDestinationURL.path, targetStructure: .yyyyMM)
        let finished = await waitForCondition { store.status == .reorganized }
        XCTAssertTrue(finished)

        XCTAssertEqual(engine.reorganizeRequests.count, 1)
        XCTAssertEqual(engine.reorganizeRequests.first?.destinationRoot, tempDestinationURL.path)
        XCTAssertEqual(engine.reorganizeRequests.first?.targetStructure, .yyyyMM)
        XCTAssertEqual(store.currentMode, .reorganize)
        XCTAssertEqual(store.metrics.movedCount, 4)
        XCTAssertEqual(store.metrics.skippedCount, 2)
        XCTAssertEqual(store.metrics.failedCount, 1)
        XCTAssertTrue(store.logLines.contains("Reorganize complete: 4 moved, 2 skipped, 1 failed."))
    }

    @MainActor
    func testConfirmPromptStartFreshClearsStaleQueueBeforeTransfer() async throws {
        let dbURL = tempDestinationURL.appendingPathComponent(".organize_cache.db")
        let database = try OrganizerDatabase(url: dbURL)
        try database.enqueueJobs([
            CopyJobRecord(
                sourcePath: "/src/stale-a.jpg",
                destinationPath: "/dst/stale-a.jpg",
                identity: FileIdentity(size: 1, digest: "a"),
                status: .pending
            ),
            CopyJobRecord(
                sourcePath: "/src/stale-b.jpg",
                destinationPath: "/dst/stale-b.jpg",
                identity: FileIdentity(size: 2, digest: "b"),
                status: .copied
            ),
        ])
        database.close()

        let configuration = RunConfiguration(mode: .transfer, sourcePath: "/tmp/source", destinationPath: tempDestinationURL.path)
        let preflight = RunPreflight(
            configuration: configuration,
            resolvedSourcePath: configuration.sourcePath,
            resolvedDestinationPath: configuration.destinationPath,
            pendingJobCount: 1
        )
        let engine = MockOrganizerEngine(
            preflightResult: .success(preflight),
            startMode: .events([
                .complete(
                    RunSummary(
                        status: .finished,
                        title: "Done",
                        metrics: RunMetrics(copiedCount: 0),
                        artifacts: RunArtifactPaths(destinationRoot: tempDestinationURL.path)
                    )
                ),
            ])
        )
        let store = RunSessionStore(engine: engine, logStore: logStore, historyStore: historyStore)

        await store.requestRun(mode: .transfer, configuration: configuration)
        XCTAssertEqual(store.prompt?.kind, .resumePendingJobs)

        store.confirmPromptStartFresh()
        let finished = await waitForCondition { store.status == .finished }
        XCTAssertTrue(finished)
        XCTAssertEqual(engine.startConfigurations.count, 1)
        XCTAssertEqual(engine.resumeConfigurations.count, 0)

        let reopened = try OrganizerDatabase(url: dbURL)
        defer { reopened.close() }
        XCTAssertEqual(try reopened.queuedJobCount(), 0)
    }

    @MainActor
    func testHashingProgressShowsTotalAndEstimatedRemainingTime() async throws {
        let configuration = RunConfiguration(mode: .preview, sourcePath: "/tmp/source", destinationPath: tempDestinationURL.path)
        let preflight = RunPreflight(
            configuration: configuration,
            resolvedSourcePath: configuration.sourcePath,
            resolvedDestinationPath: configuration.destinationPath
        )
        let engine = MockOrganizerEngine(preflightResult: .success(preflight), startMode: .pending)
        let store = RunSessionStore(engine: engine, logStore: logStore, historyStore: historyStore)

        await store.requestRun(mode: .preview, configuration: configuration)
        let continuationReady = await waitForCondition { engine.pendingContinuation != nil }
        XCTAssertTrue(continuationReady)
        engine.pendingContinuation?.yield(.phaseStarted(phase: .sourceHashing, total: 100))
        engine.pendingContinuation?.yield(.phaseProgress(phase: .sourceHashing, completed: 42, total: 100, bytesCopied: nil, bytesTotal: nil))
        let updated = await waitForCondition { store.currentTaskTitle.contains("42 of 100 files") }
        XCTAssertTrue(updated)

        XCTAssertEqual(store.progress, 0.42, accuracy: 0.000_1)
        XCTAssertTrue(store.currentTaskTitle.hasPrefix("Hashing source... 42 of 100 files"))
        XCTAssertTrue(store.currentTaskTitle.contains("remaining"))
        XCTAssertNotNil(store.metrics.etaSeconds)
    }

    @MainActor
    func testIndeterminateProgressStillShowsCompletedFileCountWithoutJumpingProgress() async throws {
        let configuration = RunConfiguration(mode: .preview, sourcePath: "/tmp/source", destinationPath: tempDestinationURL.path)
        let preflight = RunPreflight(
            configuration: configuration,
            resolvedSourcePath: configuration.sourcePath,
            resolvedDestinationPath: configuration.destinationPath
        )
        let engine = MockOrganizerEngine(preflightResult: .success(preflight), startMode: .pending)
        let store = RunSessionStore(engine: engine, logStore: logStore, historyStore: historyStore)

        await store.requestRun(mode: .preview, configuration: configuration)
        let continuationReady = await waitForCondition { engine.pendingContinuation != nil }
        XCTAssertTrue(continuationReady)
        engine.pendingContinuation?.yield(.phaseStarted(phase: .sourceHashing, total: nil))
        engine.pendingContinuation?.yield(.phaseProgress(phase: .sourceHashing, completed: 42, total: 0, bytesCopied: nil, bytesTotal: nil))
        let updated = await waitForCondition { store.currentTaskTitle.contains("42 files") }
        XCTAssertTrue(updated)

        XCTAssertEqual(store.progress, 0)
        XCTAssertEqual(store.currentTaskTitle, "Hashing source... 42 files…")
        XCTAssertNil(store.metrics.etaSeconds)
    }
}

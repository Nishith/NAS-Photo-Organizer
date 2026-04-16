import Foundation
import XCTest
@testable import ChronoframeAppCore

final class HybridOrganizerEngineTests: XCTestCase {
    @MainActor
    func testPreviewRequestsUsePreviewEngine() async throws {
        let configuration = RunConfiguration(mode: .preview, sourcePath: "/tmp/source", destinationPath: "/tmp/dest")
        let previewPreflight = RunPreflight(
            configuration: configuration,
            resolvedSourcePath: configuration.sourcePath,
            resolvedDestinationPath: configuration.destinationPath
        )
        let previewEngine = MockOrganizerEngine(
            preflightResult: .success(previewPreflight),
            startMode: .events([
                .complete(
                    RunSummary(
                        status: .dryRunFinished,
                        title: "Preview complete",
                        metrics: RunMetrics(plannedCount: 2),
                        artifacts: RunArtifactPaths(destinationRoot: configuration.destinationPath)
                    )
                )
            ])
        )
        let transferEngine = MockOrganizerEngine(
            preflightResult: .failure(TestFailure.expectedFailure("transfer should not be used"))
        )
        let engine = HybridOrganizerEngine(previewEngine: previewEngine, transferEngine: transferEngine)

        let preflight = try await engine.preflight(configuration)
        XCTAssertEqual(preflight, previewPreflight)

        let events = try await Self.collect(try engine.start(configuration))
        XCTAssertEqual(previewEngine.startConfigurations, [configuration])
        XCTAssertTrue(transferEngine.startConfigurations.isEmpty)

        guard case let .complete(summary)? = events.last else {
            return XCTFail("Expected preview completion event")
        }
        XCTAssertEqual(summary.status, RunStatus.dryRunFinished)
    }

    @MainActor
    func testTransferRequestsUseTransferEngineForPreflightStartAndResume() async throws {
        let configuration = RunConfiguration(mode: .transfer, sourcePath: "/tmp/source", destinationPath: "/tmp/dest")
        let transferPreflight = RunPreflight(
            configuration: configuration,
            resolvedSourcePath: configuration.sourcePath,
            resolvedDestinationPath: configuration.destinationPath,
            pendingJobCount: 3
        )
        let previewEngine = MockOrganizerEngine(
            preflightResult: .failure(TestFailure.expectedFailure("preview should not be used"))
        )
        let transferEngine = MockOrganizerEngine(
            preflightResult: .success(transferPreflight),
            startMode: .events([
                .complete(
                    RunSummary(
                        status: .finished,
                        title: "Transfer done",
                        metrics: RunMetrics(copiedCount: 1),
                        artifacts: RunArtifactPaths(destinationRoot: configuration.destinationPath)
                    )
                )
            ]),
            resumeMode: .events([
                .complete(
                    RunSummary(
                        status: .finished,
                        title: "Resume done",
                        metrics: RunMetrics(copiedCount: 3),
                        artifacts: RunArtifactPaths(destinationRoot: configuration.destinationPath)
                    )
                )
            ])
        )
        let engine = HybridOrganizerEngine(previewEngine: previewEngine, transferEngine: transferEngine)

        let preflight = try await engine.preflight(configuration)
        XCTAssertEqual(preflight, transferPreflight)

        _ = try await Self.collect(try engine.start(configuration))
        _ = try await Self.collect(try engine.resume(configuration))

        XCTAssertEqual(transferEngine.startConfigurations, [configuration])
        XCTAssertEqual(transferEngine.resumeConfigurations, [configuration])
        XCTAssertTrue(previewEngine.startConfigurations.isEmpty)
        XCTAssertTrue(previewEngine.resumeConfigurations.isEmpty)
    }

    @MainActor
    func testCancelForwardsToBothUnderlyingEngines() {
        let previewEngine = MockOrganizerEngine(preflightResult: .failure(TestFailure.expectedFailure("unused")))
        let transferEngine = MockOrganizerEngine(preflightResult: .failure(TestFailure.expectedFailure("unused")))
        let engine = HybridOrganizerEngine(previewEngine: previewEngine, transferEngine: transferEngine)

        engine.cancelCurrentRun()

        XCTAssertEqual(previewEngine.cancelCallCount, 1)
        XCTAssertEqual(transferEngine.cancelCallCount, 1)
    }

    private static func collect(_ stream: AsyncThrowingStream<RunEvent, Error>) async throws -> [RunEvent] {
        var events: [RunEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }
}

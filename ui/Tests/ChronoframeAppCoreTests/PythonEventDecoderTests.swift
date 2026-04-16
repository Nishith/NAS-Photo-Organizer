import XCTest
@testable import ChronoframeAppCore

final class PythonEventDecoderTests: XCTestCase {
    func testDecodesCopyPlanReadyEvent() {
        let decoder = PythonEventDecoder()
        let event = decoder.decode(
            line: #"{"type":"copy_plan_ready","count":12}"#,
            currentMetrics: RunMetrics(),
            currentArtifacts: RunArtifactPaths(destinationRoot: "/tmp/chronoframe-dst")
        )

        guard case let .copyPlanReady(count)? = event else {
            return XCTFail("Expected a copy-plan event")
        }

        XCTAssertEqual(count, 12)
    }

    func testDecodesCompletionIntoTypedArtifacts() {
        let decoder = PythonEventDecoder()
        let event = decoder.decode(
            line: #"{"type":"complete","status":"dry_run_finished","dest":"/tmp/chronoframe-dst","report":"/tmp/chronoframe-dst/.organize_logs/dry_run_report_20260413.csv"}"#,
            currentMetrics: RunMetrics(plannedCount: 4, duplicateCount: 1),
            currentArtifacts: RunArtifactPaths(destinationRoot: "/tmp/previous")
        )

        guard case let .complete(summary)? = event else {
            return XCTFail("Expected a completion event")
        }

        XCTAssertEqual(summary.status, .dryRunFinished)
        XCTAssertEqual(summary.title, "Preview complete")
        XCTAssertEqual(summary.metrics.plannedCount, 4)
        XCTAssertEqual(summary.metrics.duplicateCount, 1)
        XCTAssertEqual(summary.artifacts.destinationRoot, "/tmp/chronoframe-dst")
        XCTAssertEqual(summary.artifacts.reportPath, "/tmp/chronoframe-dst/.organize_logs/dry_run_report_20260413.csv")
        XCTAssertEqual(summary.artifacts.logFilePath, "/tmp/chronoframe-dst/.organize_log.txt")
        XCTAssertEqual(summary.artifacts.logsDirectoryPath, "/tmp/chronoframe-dst/.organize_logs")
    }

    func testFallsBackToIssueForPlaintextWarnings() {
        let decoder = PythonEventDecoder()
        let event = decoder.decode(
            line: "WARNING: Verification retry budget nearly exhausted",
            currentMetrics: RunMetrics(),
            currentArtifacts: RunArtifactPaths()
        )

        guard case let .issue(issue)? = event else {
            return XCTFail("Expected a warning issue")
        }

        XCTAssertEqual(issue.severity, .warning)
        XCTAssertEqual(issue.message, "Verification retry budget nearly exhausted")
    }
}

import ChronoframeCLIKit
import ChronoframeCore
import XCTest

final class EventEmitterTests: XCTestCase {
    func testJSONEmitterUsesCompatibilityProgressKeys() throws {
        let line = try JSONLineEmitter.line(
            for: .phaseProgress(
                phase: .copy,
                completed: 2,
                total: 5,
                bytesCopied: 128,
                bytesTotal: 512,
                currentFilePath: nil
            )
        )

        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["type"] as? String, "task_progress")
        XCTAssertEqual(payload["task"] as? String, "copy")
        XCTAssertEqual(payload["completed"] as? Int, 2)
        XCTAssertEqual(payload["total"] as? Int, 5)
        XCTAssertEqual(payload["bytes_copied"] as? Int, 128)
        XCTAssertEqual(payload["bytes_total"] as? Int, 512)
    }

    func testJSONEmitterStampsEventVersionOnEveryEvent() throws {
        // event_version is the wire-format contract for downstream
        // consumers (CI scripts, log shippers). Every emitted line carries
        // it so a consumer can branch on the schema. The version must
        // match `JSONLineEmitter.eventVersion`.
        let events: [RunEvent] = [
            .startup,
            .phaseStarted(phase: .discovery, total: 10),
            .phaseProgress(phase: .copy, completed: 1, total: 1, bytesCopied: 0, bytesTotal: 0, currentFilePath: nil),
            .copyPlanReady(count: 5),
            .issue(RunIssue(severity: .warning, message: "test")),
        ]
        for event in events {
            let line = try JSONLineEmitter.line(for: event)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            )
            XCTAssertEqual(
                payload["event_version"] as? Int,
                JSONLineEmitter.eventVersion,
                "Event \(event) missing event_version"
            )
        }
    }

    func testJSONEmitterUsesBackendStatusNames() throws {
        let line = try JSONLineEmitter.line(
            for: .complete(
                RunSummary(
                    status: .dryRunFinished,
                    title: "Preview complete",
                    metrics: RunMetrics(plannedCount: 3),
                    artifacts: RunArtifactPaths(destinationRoot: "/out", reportPath: "/out/report.csv")
                )
            )
        )

        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["type"] as? String, "complete")
        XCTAssertEqual(payload["status"] as? String, "dry_run_finished")
        let artifacts = try XCTUnwrap(payload["artifacts"] as? [String: Any])
        XCTAssertEqual(artifacts["destination"] as? String, "/out")
        XCTAssertEqual(artifacts["report"] as? String, "/out/report.csv")
    }

    func testHumanEmitterSuppressesHistogramNoise() {
        XCTAssertNil(HumanLineEmitter.line(for: .dateHistogram(buckets: [])))
    }
}

import XCTest
@testable import ChronoframeCore

final class ChronoframeCoreModelTests: XCTestCase {
    func testRunStatusMappingAndIssueRenderingRemainStable() {
        XCTAssertEqual(RunStatus(backendStatus: "dry_run_finished"), .dryRunFinished)
        XCTAssertEqual(RunStatus(backendStatus: "finished"), .finished)
        XCTAssertEqual(RunStatus(backendStatus: "nothing_to_copy"), .nothingToCopy)
        XCTAssertEqual(RunStatus(backendStatus: "cancelled"), .cancelled)
        XCTAssertEqual(RunStatus(backendStatus: "idle"), .idle)
        XCTAssertEqual(RunStatus(backendStatus: "mystery"), .failed)

        XCTAssertEqual(RunIssue(severity: .info, message: "Started").renderedLine, "ℹ Started")
        XCTAssertEqual(RunIssue(severity: .warning, message: "Slow disk").renderedLine, "⚠ Slow disk")
        XCTAssertEqual(RunIssue(severity: .error, message: "Copy failed").renderedLine, "ERROR: Copy failed")
    }

    func testSidebarAndHistoryMetadataRemainStable() {
        XCTAssertEqual(Profile(name: "travel", sourcePath: "/src", destinationPath: "/dst").id, "travel")

        for phase in RunPhase.allCases {
            XCTAssertFalse(phase.title.isEmpty)
            XCTAssertFalse(phase.runningTitle.isEmpty)
        }

        for destination in SidebarDestination.allCases {
            XCTAssertFalse(destination.title.isEmpty)
            XCTAssertFalse(destination.subtitle.isEmpty)
            XCTAssertFalse(destination.systemImage.isEmpty)
        }

        for kind in RunHistoryEntryKind.allCases {
            XCTAssertFalse(kind.title.isEmpty)
            XCTAssertFalse(kind.systemImage.isEmpty)
        }
    }
}

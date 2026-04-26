import XCTest
@testable import ChronoframeAppCore

final class RunLogStoreTests: XCTestCase {
    func testRingBufferDropsOldestLines() {
        let store = RunLogStore(capacity: PreferencesStore.minimumLogCapacity)

        for index in 0...PreferencesStore.minimumLogCapacity {
            store.append("line \(index)")
        }

        XCTAssertEqual(store.lines.count, PreferencesStore.minimumLogCapacity)
        XCTAssertEqual(store.lines.first, "line 1")
        XCTAssertEqual(store.lines.last, "line \(PreferencesStore.minimumLogCapacity)")
    }

    func testSeverityCountersTrackRenderedLines() {
        let store = RunLogStore(capacity: PreferencesStore.minimumLogCapacity)

        store.append(issue: RunIssue(severity: .info, message: "Discovery started"))
        store.append(issue: RunIssue(severity: .warning, message: "Slow destination scan"))
        store.append(issue: RunIssue(severity: .error, message: "Verification failed"))

        XCTAssertEqual(store.infoCount, 1)
        XCTAssertEqual(store.warningCount, 1)
        XCTAssertEqual(store.errorCount, 1)
    }

    func testIssueMessagesAreRenderedWithUserFacingGuidance() {
        let store = RunLogStore(capacity: PreferencesStore.minimumLogCapacity)

        store.append(
            issue: RunIssue(
                severity: .error,
                message: "Copy failed: /Volumes/Card/IMG_0001.JPG -> /Volumes/Archive/IMG_0001.JPG: Permission denied"
            )
        )

        XCTAssertEqual(store.errorCount, 1)
        XCTAssertEqual(store.warningCount, 0)
        XCTAssertEqual(store.infoCount, 0)
        XCTAssertEqual(store.lines.count, 1)
        XCTAssertTrue(store.lines[0].hasPrefix("ERROR: Chronoframe could not copy this file"), store.lines[0])
        XCTAssertTrue(store.lines[0].contains("source was left untouched"), store.lines[0])
        XCTAssertTrue(store.lines[0].contains("Permission denied"), store.lines[0])
    }

    func testSeverityCountersStayAccurateAfterOldLinesTrim() {
        let store = RunLogStore(capacity: PreferencesStore.minimumLogCapacity)

        for index in 0..<PreferencesStore.minimumLogCapacity {
            store.append(issue: RunIssue(severity: .warning, message: "warning \(index)"))
        }
        for index in 0..<PreferencesStore.minimumLogCapacity {
            store.append(issue: RunIssue(severity: .error, message: "error \(index)"))
        }

        XCTAssertEqual(store.lines.count, PreferencesStore.minimumLogCapacity)
        XCTAssertEqual(store.warningCount, 0)
        XCTAssertEqual(store.errorCount, PreferencesStore.minimumLogCapacity)
        XCTAssertEqual(store.infoCount, 0)
    }

    func testByteBudgetAlsoTrimsOversizedBuffers() {
        let store = RunLogStore(capacity: 1_000)
        let payload = String(repeating: "x", count: 1_024)

        for index in 0..<600 {
            store.append("line \(index) \(payload)")
        }

        XCTAssertLessThan(store.lines.count, 600)
        XCTAssertEqual(store.lines.last?.hasPrefix("line 599 "), true)
    }
}

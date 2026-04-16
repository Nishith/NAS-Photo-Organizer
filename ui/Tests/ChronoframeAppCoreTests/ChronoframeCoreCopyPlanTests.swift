import Foundation
import XCTest
@testable import ChronoframeCore

final class ChronoframeCoreCopyPlanTests: XCTestCase {
    func testBuildMatchesSequenceReuseAndDuplicateRouting() {
        let destinationSnapshot = DestinationIndexSnapshot(
            pathsByIdentity: [:],
            sequenceState: SequenceCounterState(
                primaryByDate: ["2024-02-14": 2],
                duplicatesByDate: ["2024-02-14": 3]
            )
        )

        let result = CopyPlanBuilder.build(
            sourceFiles: [
                candidate("/source/batch/IMG_20240214_080000.jpg", identity: "7_hash_a", date: "2024-02-14"),
                candidate("/source/batch/IMG_20240214_080100.jpg", identity: "7_hash_b", date: "2024-02-14"),
                candidate("/source/batch/VID_20240214_080200.mov", identity: "7_hash_a", date: "2024-02-14"),
            ],
            destinationSnapshot: destinationSnapshot,
            destinationRoot: "/dest"
        )

        XCTAssertEqual(
            result.copyJobs.map(\.destinationPath),
            [
                "/dest/2024/02/14/2024-02-14_003.jpg",
                "/dest/2024/02/14/2024-02-14_004.jpg",
                "/dest/Duplicate/2024/02/14/2024-02-14_004.mov",
            ]
        )
        XCTAssertEqual(result.counts.newCount, 2)
        XCTAssertEqual(result.counts.duplicateCount, 1)
        XCTAssertEqual(result.warningMessages, [])
        XCTAssertEqual(result.sequenceState.primaryByDate["2024-02-14"], 4)
        XCTAssertEqual(result.sequenceState.duplicatesByDate["2024-02-14"], 4)
    }

    func testBuildSkipsExistingDestinationAndRoutesUnknownDateDuplicates() {
        let existingIdentity = FileIdentity(rawValue: "5_hash_existing")!
        let destinationSnapshot = DestinationIndexSnapshot(
            pathsByIdentity: [existingIdentity: "/dest/2024/01/03/2024-01-03_001.jpg"],
            sequenceState: SequenceCounterState(
                primaryByDate: ["Unknown_Date": 0],
                duplicatesByDate: [:]
            )
        )

        let result = CopyPlanBuilder.build(
            sourceFiles: [
                candidate("/source/camera/IMG_20240103_010101.jpg", identity: "5_hash_existing", date: "2024-01-03"),
                candidate("/source/camera/IMG_20240102_101010.jpg", identity: "5_hash_alpha", date: "2024-01-02"),
                candidate("/source/misc/orphan.mov", identity: "13_hash_unknown", date: nil),
                candidate("/source/camera/VID_20240102_121212.mov", identity: "5_hash_alpha", date: "2024-01-02"),
            ],
            destinationSnapshot: destinationSnapshot,
            destinationRoot: "/dest"
        )

        XCTAssertEqual(result.counts.alreadyInDestinationCount, 1)
        XCTAssertEqual(result.counts.newCount, 2)
        XCTAssertEqual(result.counts.duplicateCount, 1)
        XCTAssertEqual(result.copyJobs.map(\.destinationPath), [
            "/dest/2024/01/02/2024-01-02_001.jpg",
            "/dest/Unknown_Date/Unknown_001.mov",
            "/dest/Duplicate/2024/01/02/2024-01-02_001.mov",
        ])
    }

    func testBuildEmitsOverflowWarningAndWidensSequence() {
        let destinationSnapshot = DestinationIndexSnapshot(
            pathsByIdentity: [:],
            sequenceState: SequenceCounterState(primaryByDate: ["2024-02-14": 999], duplicatesByDate: [:])
        )

        let result = CopyPlanBuilder.build(
            sourceFiles: [
                candidate("/source/batch/IMG_20240214_230000.jpg", identity: "12_hash_overflow", date: "2024-02-14"),
            ],
            destinationSnapshot: destinationSnapshot,
            destinationRoot: "/dest"
        )

        XCTAssertEqual(result.copyJobs.map(\.destinationPath), ["/dest/2024/02/14/2024-02-14_1000.jpg"])
        XCTAssertEqual(
            result.warningMessages,
            ["Sequence overflow on dates (>999 files/day): 2024-02-14"]
        )
    }

    func testBuildCountsHashErrorsWithoutPlanningThem() {
        let result = CopyPlanBuilder.build(
            sourceFiles: [
                PlanningFileCandidate(sourcePath: "/source/missing.jpg", identity: nil, capturedAt: nil),
                candidate("/source/good.jpg", identity: "4_hash_ok", date: "2024-03-01"),
            ],
            destinationSnapshot: DestinationIndexSnapshot(),
            destinationRoot: "/dest"
        )

        XCTAssertEqual(result.counts.hashErrorCount, 1)
        XCTAssertEqual(result.copyJobs.count, 1)
        XCTAssertEqual(result.copyJobs.first?.destinationPath, "/dest/2024/03/01/2024-03-01_001.jpg")
    }

    private func candidate(_ path: String, identity: String, date: String?) -> PlanningFileCandidate {
        PlanningFileCandidate(
            sourcePath: path,
            identity: FileIdentity(rawValue: identity),
            capturedAt: date.flatMap(Self.dayFormatter.date(from:))
        )
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

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
        XCTAssertEqual(result.infoMessages, [])
        XCTAssertEqual(
            result.warningMessages,
            ["Sequence overflow on dates (>999 files/day): 2024-02-14"]
        )
    }

    func testBuildUsesWideSequenceForGreenfieldCrowdedDayWithInfo() {
        let result = CopyPlanBuilder.build(
            sourceFiles: (1...1_001).map { index in
                candidate(
                    String(format: "/source/batch/IMG_20260419_%06d.jpg", index),
                    identity: "\(index)_hash_\(index)",
                    date: "2026-04-19"
                )
            },
            destinationSnapshot: DestinationIndexSnapshot(),
            destinationRoot: "/dest"
        )

        let destinations = result.copyJobs.map(\.destinationPath)
        XCTAssertEqual(destinations.first, "/dest/2026/04/19/2026-04-19_0001.jpg")
        XCTAssertEqual(destinations[998], "/dest/2026/04/19/2026-04-19_0999.jpg")
        XCTAssertEqual(destinations[999], "/dest/2026/04/19/2026-04-19_1000.jpg")
        XCTAssertEqual(destinations.last, "/dest/2026/04/19/2026-04-19_1001.jpg")
        XCTAssertEqual(result.warningMessages, [])
        XCTAssertEqual(
            result.infoMessages,
            ["Day 2026-04-19: 1,001 files — using 4-digit sequence numbers."]
        )
        XCTAssertEqual(result.dateHistogram, [DateHistogramBucket(key: "2026-04", plannedCount: 1_001)])
    }

    func testBuildDoesNotWarnWhenExistingDateAlreadyUsesWideSequence() {
        let destinationSnapshot = DestinationIndexSnapshot(
            pathsByIdentity: [:],
            sequenceState: SequenceCounterState(primaryByDate: ["2024-02-14": 1_000], duplicatesByDate: [:])
        )

        let result = CopyPlanBuilder.build(
            sourceFiles: [
                candidate("/source/batch/IMG_20240214_230000.jpg", identity: "12_hash_next", date: "2024-02-14"),
            ],
            destinationSnapshot: destinationSnapshot,
            destinationRoot: "/dest"
        )

        XCTAssertEqual(result.copyJobs.map(\.destinationPath), ["/dest/2024/02/14/2024-02-14_1001.jpg"])
        XCTAssertEqual(result.warningMessages, [])
        XCTAssertEqual(result.infoMessages, [])
    }

    func testBuildUsesWideSequenceForCrowdedDuplicateBucket() {
        let result = CopyPlanBuilder.build(
            sourceFiles: (0...1_000).map { index in
                candidate(
                    String(format: "/source/dup/IMG_20260419_%06d.jpg", index),
                    identity: "5_same_hash",
                    date: "2026-04-19"
                )
            },
            destinationSnapshot: DestinationIndexSnapshot(),
            destinationRoot: "/dest"
        )

        let duplicateDestinations = result.transfers
            .filter(\.isDuplicate)
            .map(\.destinationPath)
        XCTAssertEqual(result.counts.newCount, 1)
        XCTAssertEqual(result.counts.duplicateCount, 1_000)
        XCTAssertEqual(duplicateDestinations.first, "/dest/Duplicate/2026/04/19/2026-04-19_0001.jpg")
        XCTAssertEqual(duplicateDestinations[998], "/dest/Duplicate/2026/04/19/2026-04-19_0999.jpg")
        XCTAssertEqual(duplicateDestinations[999], "/dest/Duplicate/2026/04/19/2026-04-19_1000.jpg")
        XCTAssertEqual(result.warningMessages, [])
        XCTAssertEqual(result.dateHistogram, [DateHistogramBucket(key: "2026-04", plannedCount: 1_001)])
    }

    func testBuildDateHistogramIncludesTransfersAndSortsUnknownLast() {
        let result = CopyPlanBuilder.build(
            sourceFiles: [
                candidate("/source/feb/IMG_20260201_010101.jpg", identity: "1_hash_feb", date: "2026-02-01"),
                candidate("/source/unknown/orphan.jpg", identity: "1_hash_unknown", date: nil),
                candidate("/source/jan/IMG_20260131_010101.jpg", identity: "1_hash_jan", date: "2026-01-31"),
            ],
            destinationSnapshot: DestinationIndexSnapshot(),
            destinationRoot: "/dest"
        )

        XCTAssertEqual(
            result.dateHistogram,
            [
                DateHistogramBucket(key: "2026-01", plannedCount: 1),
                DateHistogramBucket(key: "2026-02", plannedCount: 1),
                DateHistogramBucket(key: "Unknown", plannedCount: 1),
            ]
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

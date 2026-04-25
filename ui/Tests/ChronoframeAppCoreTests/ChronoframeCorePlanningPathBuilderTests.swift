import Foundation
import XCTest
@testable import ChronoframeCore

/// Unit coverage for `PlanningPathBuilder` — the lowest-level path-construction
/// helper used by the planner. Phase 1 of the Python migration extends this
/// builder with new folder layouts; locking down today's behavior here makes
/// regressions visible the moment they happen.
final class ChronoframeCorePlanningPathBuilderTests: XCTestCase {
    private let rules = PlannerNamingRules.pythonReference

    // MARK: - formatSequence

    func testFormatSequencePadsToMinimumWidth() {
        XCTAssertEqual(PlanningPathBuilder.formatSequence(1, minimumWidth: 3), "001")
        XCTAssertEqual(PlanningPathBuilder.formatSequence(42, minimumWidth: 3), "042")
        XCTAssertEqual(PlanningPathBuilder.formatSequence(999, minimumWidth: 3), "999")
    }

    func testFormatSequenceWidensBeyondMinimumWhenSequenceOverflows() {
        XCTAssertEqual(PlanningPathBuilder.formatSequence(1000, minimumWidth: 3), "1000")
        XCTAssertEqual(PlanningPathBuilder.formatSequence(12345, minimumWidth: 3), "12345")
    }

    func testFormatSequenceHandlesZero() {
        XCTAssertEqual(PlanningPathBuilder.formatSequence(0, minimumWidth: 3), "000")
    }

    // MARK: - maxSequence

    func testMaxSequenceMatchesWidthBoundary() {
        XCTAssertEqual(PlanningPathBuilder.maxSequence(for: 3), 999)
        XCTAssertEqual(PlanningPathBuilder.maxSequence(for: 4), 9_999)
        XCTAssertEqual(PlanningPathBuilder.maxSequence(for: 1), 9)
    }

    // MARK: - buildDestinationPath (current YYYY/MM/DD layout)

    func testBuildDestinationPathProducesPythonReferenceLayoutForKnownDate() {
        let path = PlanningPathBuilder.buildDestinationPath(
            for: "/source/IMG_20240214_080000.jpg",
            destinationRoot: "/dest",
            dateBucket: "2024-02-14",
            sequence: 7,
            duplicateDirectoryName: nil,
            namingRules: rules
        )
        XCTAssertEqual(path, "/dest/2024/02/14/2024-02-14_007.jpg")
    }

    func testBuildDestinationPathNestsDuplicatesUnderDuplicateDirectory() {
        let path = PlanningPathBuilder.buildDestinationPath(
            for: "/source/clip.mov",
            destinationRoot: "/dest",
            dateBucket: "2024-02-14",
            sequence: 12,
            duplicateDirectoryName: rules.duplicateDirectoryName,
            namingRules: rules
        )
        XCTAssertEqual(path, "/dest/Duplicate/2024/02/14/2024-02-14_012.mov")
    }

    func testBuildDestinationPathRoutesUnknownDateBucketToUnknownDateDirectory() {
        let path = PlanningPathBuilder.buildDestinationPath(
            for: "/source/orphan.heic",
            destinationRoot: "/dest",
            dateBucket: rules.unknownDateDirectoryName,
            sequence: 4,
            duplicateDirectoryName: nil,
            namingRules: rules
        )
        XCTAssertEqual(path, "/dest/Unknown_Date/Unknown_004.heic")
    }

    func testBuildDestinationPathPreservesOriginalExtensionCase() {
        let path = PlanningPathBuilder.buildDestinationPath(
            for: "/source/IMG_20240214_080000.JPG",
            destinationRoot: "/dest",
            dateBucket: "2024-02-14",
            sequence: 1,
            duplicateDirectoryName: nil,
            namingRules: rules
        )
        XCTAssertTrue(path.hasSuffix(".JPG"), "extension casing must be preserved; got \(path)")
    }

    // MARK: - buildDestinationPath (alternate folder layouts)

    func testBuildDestinationPathYYYYMMLayoutDropsDayDirectory() {
        let path = PlanningPathBuilder.buildDestinationPath(
            for: "/source/clip.mov",
            destinationRoot: "/dest",
            dateBucket: "2024-02-14",
            sequence: 5,
            duplicateDirectoryName: nil,
            namingRules: rules,
            folderStructure: .yyyyMM
        )
        XCTAssertEqual(path, "/dest/2024/02/2024-02-14_005.mov")
    }

    func testBuildDestinationPathYYYYLayoutKeepsOnlyYearDirectory() {
        let path = PlanningPathBuilder.buildDestinationPath(
            for: "/source/clip.mov",
            destinationRoot: "/dest",
            dateBucket: "2024-02-14",
            sequence: 5,
            duplicateDirectoryName: nil,
            namingRules: rules,
            folderStructure: .yyyy
        )
        XCTAssertEqual(path, "/dest/2024/2024-02-14_005.mov")
    }

    func testBuildDestinationPathFlatLayoutPlacesFileAtRoot() {
        let path = PlanningPathBuilder.buildDestinationPath(
            for: "/source/clip.mov",
            destinationRoot: "/dest",
            dateBucket: "2024-02-14",
            sequence: 5,
            duplicateDirectoryName: nil,
            namingRules: rules,
            folderStructure: .flat
        )
        XCTAssertEqual(path, "/dest/2024-02-14_005.mov")
    }

    func testBuildDestinationPathYYYYMonEventUsesAbbreviatedMonth() {
        let path = PlanningPathBuilder.buildDestinationPath(
            for: "/source/IMG.jpg",
            destinationRoot: "/dest",
            dateBucket: "2024-02-14",
            sequence: 3,
            duplicateDirectoryName: nil,
            namingRules: rules,
            folderStructure: .yyyyMonEvent,
            sourceRoot: "/source"
        )
        XCTAssertEqual(path, "/dest/2024/Feb/2024-02-14_003.jpg")
    }

    func testBuildDestinationPathYYYYMonEventInsertsEventFolder() {
        let path = PlanningPathBuilder.buildDestinationPath(
            for: "/source/Birthday/IMG.jpg",
            destinationRoot: "/dest",
            dateBucket: "2024-02-14",
            sequence: 3,
            duplicateDirectoryName: nil,
            namingRules: rules,
            folderStructure: .yyyyMonEvent,
            sourceRoot: "/source"
        )
        XCTAssertEqual(path, "/dest/2024/Feb/Birthday/2024-02-14_003.jpg")
    }

    func testBuildDestinationPathYYYYMonEventUsesImmediateParentForNestedSource() {
        let path = PlanningPathBuilder.buildDestinationPath(
            for: "/source/2024/Birthday/IMG.jpg",
            destinationRoot: "/dest",
            dateBucket: "2024-02-14",
            sequence: 3,
            duplicateDirectoryName: nil,
            namingRules: rules,
            folderStructure: .yyyyMonEvent,
            sourceRoot: "/source"
        )
        XCTAssertEqual(path, "/dest/2024/Feb/Birthday/2024-02-14_003.jpg")
    }

    func testBuildDestinationPathYYYYMonEventUnknownDateRoutesUnderUnknownDirectory() {
        let path = PlanningPathBuilder.buildDestinationPath(
            for: "/source/Birthday/orphan.heic",
            destinationRoot: "/dest",
            dateBucket: rules.unknownDateDirectoryName,
            sequence: 4,
            duplicateDirectoryName: nil,
            namingRules: rules,
            folderStructure: .yyyyMonEvent,
            sourceRoot: "/source"
        )
        XCTAssertEqual(path, "/dest/Unknown_Date/Birthday/Unknown_004.heic")
    }

    func testBuildDestinationPathYYYYMMNestsDuplicatesUnderDuplicateDirectory() {
        let path = PlanningPathBuilder.buildDestinationPath(
            for: "/source/clip.mov",
            destinationRoot: "/dest",
            dateBucket: "2024-02-14",
            sequence: 12,
            duplicateDirectoryName: rules.duplicateDirectoryName,
            namingRules: rules,
            folderStructure: .yyyyMM
        )
        XCTAssertEqual(path, "/dest/Duplicate/2024/02/2024-02-14_012.mov")
    }

    func testBuildDestinationPathFlatLayoutRoutesUnknownDateToUnknownDirectory() {
        let path = PlanningPathBuilder.buildDestinationPath(
            for: "/source/orphan.heic",
            destinationRoot: "/dest",
            dateBucket: rules.unknownDateDirectoryName,
            sequence: 4,
            duplicateDirectoryName: nil,
            namingRules: rules,
            folderStructure: .flat
        )
        XCTAssertEqual(path, "/dest/Unknown_Date/Unknown_004.heic")
    }

    // MARK: - eventSubpath

    func testEventSubpathReturnsEmptyWhenFileSitsAtSourceRoot() {
        XCTAssertEqual(PlanningPathBuilder.eventSubpath(sourcePath: "/source/IMG.jpg", sourceRoot: "/source"), "")
    }

    func testEventSubpathReturnsImmediateParentFolderName() {
        XCTAssertEqual(
            PlanningPathBuilder.eventSubpath(sourcePath: "/source/Birthday/IMG.jpg", sourceRoot: "/source"),
            "Birthday"
        )
    }

    func testEventSubpathReturnsBasenameOfDeepestParentForNestedFiles() {
        XCTAssertEqual(
            PlanningPathBuilder.eventSubpath(sourcePath: "/source/2024/Birthday/IMG.jpg", sourceRoot: "/source"),
            "Birthday"
        )
    }

    func testEventSubpathTreatsTrailingSlashOnSourceRootAsEquivalent() {
        XCTAssertEqual(
            PlanningPathBuilder.eventSubpath(sourcePath: "/source/IMG.jpg", sourceRoot: "/source/"),
            ""
        )
    }
}

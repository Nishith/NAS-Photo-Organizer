import Foundation
import XCTest
@testable import ChronoframeCore

final class ChronoframeCoreReorganizeExecutorTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChronoframeCoreReorganizeExecutorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        try super.tearDownWithError()
    }

    // MARK: - Plan: error paths

    func testPlanThrowsForMissingDestination() {
        let missing = temporaryDirectoryURL.appendingPathComponent("does-not-exist")
        XCTAssertThrowsError(
            try ReorganizeExecutor().plan(destinationRoot: missing, targetStructure: .yyyyMMDD)
        ) { error in
            guard case ReorganizeExecutorError.destinationNotFound = error else {
                return XCTFail("Expected destinationNotFound, got \(error)")
            }
        }
    }

    func testPlanThrowsWhenDestinationIsAFile() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("not-a-dir.txt")
        try Data("x".utf8).write(to: fileURL)
        XCTAssertThrowsError(
            try ReorganizeExecutor().plan(destinationRoot: fileURL, targetStructure: .yyyyMMDD)
        ) { error in
            guard case ReorganizeExecutorError.destinationNotADirectory = error else {
                return XCTFail("Expected destinationNotADirectory, got \(error)")
            }
        }
    }

    // MARK: - Plan: layout transitions

    func testPlanFlatToYYYYMMDDProducesCorrectMoves() throws {
        try writeFile(at: ["2024-04-08_001.HEIC"])
        try writeFile(at: ["2024-04-08_002.HEIC"])
        try writeFile(at: ["2024-04-10_001.png"])

        let plan = try ReorganizeExecutor().plan(
            destinationRoot: temporaryDirectoryURL,
            targetStructure: .yyyyMMDD
        )

        XCTAssertEqual(plan.moves.count, 3)
        XCTAssertEqual(plan.unchangedCount, 0)
        XCTAssertEqual(plan.unrecognizedCount, 0)
        XCTAssertEqual(
            plan.moves[0].destinationPath,
            temporaryDirectoryURL.appendingPathComponent("2024/04/08/2024-04-08_001.HEIC").standardizedFileURL.path
        )
        XCTAssertEqual(
            plan.moves[2].destinationPath,
            temporaryDirectoryURL.appendingPathComponent("2024/04/10/2024-04-10_001.png").standardizedFileURL.path
        )
    }

    func testPlanYYYYMMDDToFlatCollapsesNesting() throws {
        try writeFile(at: ["2024", "05", "15", "2024-05-15_001.jpg"])
        try writeFile(at: ["2024", "05", "16", "2024-05-16_001.jpg"])

        let plan = try ReorganizeExecutor().plan(
            destinationRoot: temporaryDirectoryURL,
            targetStructure: .flat
        )

        XCTAssertEqual(plan.moves.count, 2)
        let destinationPaths = Set(plan.moves.map(\.destinationPath))
        XCTAssertEqual(
            destinationPaths,
            Set([
                temporaryDirectoryURL.appendingPathComponent("2024-05-15_001.jpg").standardizedFileURL.path,
                temporaryDirectoryURL.appendingPathComponent("2024-05-16_001.jpg").standardizedFileURL.path,
            ])
        )
    }

    func testPlanYYYYMMDDToYYYYCollapsesToYearOnly() throws {
        try writeFile(at: ["2023", "12", "31", "2023-12-31_001.jpg"])
        try writeFile(at: ["2024", "01", "01", "2024-01-01_001.jpg"])

        let plan = try ReorganizeExecutor().plan(
            destinationRoot: temporaryDirectoryURL,
            targetStructure: .yyyy
        )

        XCTAssertEqual(plan.moves.count, 2)
        let destinationPaths = Set(plan.moves.map(\.destinationPath))
        XCTAssertEqual(
            destinationPaths,
            Set([
                temporaryDirectoryURL.appendingPathComponent("2023/2023-12-31_001.jpg").standardizedFileURL.path,
                temporaryDirectoryURL.appendingPathComponent("2024/2024-01-01_001.jpg").standardizedFileURL.path,
            ])
        )
    }

    func testPlanYYYYMMToYYYYMMDD() throws {
        try writeFile(at: ["2024", "03", "2024-03-15_001.jpg"])

        let plan = try ReorganizeExecutor().plan(
            destinationRoot: temporaryDirectoryURL,
            targetStructure: .yyyyMMDD
        )

        XCTAssertEqual(plan.moves.count, 1)
        XCTAssertEqual(
            plan.moves[0].destinationPath,
            temporaryDirectoryURL.appendingPathComponent("2024/03/15/2024-03-15_001.jpg").standardizedFileURL.path
        )
    }

    func testPlanPreservesDuplicateSubfolder() throws {
        try writeFile(at: ["Duplicate", "2024-04-10_001.png"])

        let plan = try ReorganizeExecutor().plan(
            destinationRoot: temporaryDirectoryURL,
            targetStructure: .yyyyMMDD
        )

        XCTAssertEqual(plan.moves.count, 1)
        XCTAssertEqual(
            plan.moves[0].destinationPath,
            temporaryDirectoryURL.appendingPathComponent("Duplicate/2024/04/10/2024-04-10_001.png").standardizedFileURL.path
        )
    }

    func testPlanDetectsFilesAlreadyInTargetLayoutAsUnchanged() throws {
        try writeFile(at: ["2024", "05", "01", "2024-05-01_001.jpg"])
        try writeFile(at: ["2024", "05", "01", "2024-05-01_002.jpg"])

        let plan = try ReorganizeExecutor().plan(
            destinationRoot: temporaryDirectoryURL,
            targetStructure: .yyyyMMDD
        )

        XCTAssertEqual(plan.moves.count, 0)
        XCTAssertEqual(plan.unchangedCount, 2)
    }

    func testPlanIgnoresArtifactDirectoriesAndFiles() throws {
        try writeFile(at: [".organize_logs", "audit_receipt_2024.json"])
        try writeFile(at: [".organize_cache.db"])
        try writeFile(at: [".organize_log.txt"])
        try writeFile(at: ["dry_run_report_2024_05.csv"])
        try writeFile(at: ["audit_receipt_2024_05.json"])
        try writeFile(at: ["2024-04-08_001.jpg"])

        let plan = try ReorganizeExecutor().plan(
            destinationRoot: temporaryDirectoryURL,
            targetStructure: .yyyyMMDD
        )

        // Only the real photo gets a move.
        XCTAssertEqual(plan.moves.count, 1)
        XCTAssertEqual(plan.moves[0].sourcePath, temporaryDirectoryURL.appendingPathComponent("2024-04-08_001.jpg").standardizedFileURL.path)
        XCTAssertEqual(plan.unrecognizedCount, 0)
    }

    func testPlanCountsUnrecognizedFilesSeparately() throws {
        try writeFile(at: ["random_photo.jpg"])
        try writeFile(at: ["IMG_1234.HEIC"])
        try writeFile(at: ["2024-04-08_001.jpg"])

        let plan = try ReorganizeExecutor().plan(
            destinationRoot: temporaryDirectoryURL,
            targetStructure: .flat
        )

        // 1 already-flat dated file (unchanged) + 2 unrecognized.
        XCTAssertEqual(plan.moves.count, 0)
        XCTAssertEqual(plan.unchangedCount, 1)
        XCTAssertEqual(plan.unrecognizedCount, 2)
    }

    func testPlanRoutesUnknownDateFilesUnderUnknownDateBucket() throws {
        try writeFile(at: ["Unknown_Date", "Unknown_001.jpg"])

        let plan = try ReorganizeExecutor().plan(
            destinationRoot: temporaryDirectoryURL,
            targetStructure: .yyyyMMDD
        )

        // Already in Unknown_Date — same target since no date components are required.
        XCTAssertEqual(plan.moves.count, 0)
        XCTAssertEqual(plan.unchangedCount, 1)
    }

    func testPlanYYYYMonEventDetectsAndPreservesEventFolder() throws {
        // Source layout: 2024/Apr/Birthday/2024-04-08_001.jpg
        try writeFile(at: ["2024", "Apr", "Birthday", "2024-04-08_001.jpg"])

        // Reorg INTO yyyyMonEvent → unchanged.
        let plan = try ReorganizeExecutor().plan(
            destinationRoot: temporaryDirectoryURL,
            targetStructure: .yyyyMonEvent
        )
        XCTAssertEqual(plan.moves.count, 0)
        XCTAssertEqual(plan.unchangedCount, 1)
    }

    func testPlanMigratesYYYYMMDDIntoYYYYMonEventWithoutEvent() throws {
        try writeFile(at: ["2024", "04", "08", "2024-04-08_001.jpg"])

        let plan = try ReorganizeExecutor().plan(
            destinationRoot: temporaryDirectoryURL,
            targetStructure: .yyyyMonEvent
        )

        // No event known → file lands directly under YYYY/Mon/.
        XCTAssertEqual(plan.moves.count, 1)
        XCTAssertEqual(
            plan.moves[0].destinationPath,
            temporaryDirectoryURL.appendingPathComponent("2024/Apr/2024-04-08_001.jpg").standardizedFileURL.path
        )
    }

    // MARK: - Execute

    func testExecuteMovesFilesAndCleansEmptyParents() throws {
        let fileURL = try writeFile(at: ["2024-04-08_001.HEIC"])

        let plan = try ReorganizeExecutor().plan(
            destinationRoot: temporaryDirectoryURL,
            targetStructure: .yyyyMMDD
        )

        let result = ReorganizeExecutor().execute(plan: plan)

        XCTAssertEqual(result.movedCount, 1)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: temporaryDirectoryURL.appendingPathComponent("2024/04/08/2024-04-08_001.HEIC").path
        ))
    }

    func testExecuteRemovesEmptyParentDirectory() throws {
        let fileURL = try writeFile(at: ["2024", "04", "08", "2024-04-08_001.HEIC"])
        let plan = try ReorganizeExecutor().plan(
            destinationRoot: temporaryDirectoryURL,
            targetStructure: .flat
        )
        XCTAssertEqual(plan.moves.count, 1)

        _ = ReorganizeExecutor().execute(plan: plan)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: temporaryDirectoryURL.appendingPathComponent("2024/04/08").path
            ),
            "Empty leaf directory should be cleaned up"
        )
    }

    func testExecuteSkipsWhenDestinationAlreadyExists() throws {
        // Pretend we got into a state where both old and new locations exist.
        let oldURL = try writeFile(at: ["2024-04-08_001.HEIC"])
        try writeFile(at: ["2024", "04", "08", "2024-04-08_001.HEIC"])

        let plan = try ReorganizeExecutor().plan(
            destinationRoot: temporaryDirectoryURL,
            targetStructure: .yyyyMMDD
        )

        let issues = Recorder<RunIssue>()
        let observer = ReorganizeExecutionObserver(onIssue: { issues.append($0) })
        let result = ReorganizeExecutor().execute(plan: plan, observer: observer)

        XCTAssertEqual(result.movedCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldURL.path), "Source must be preserved on collision")
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues.values[0].message.contains("Destination exists"))
    }

    func testExecuteHonorsCancellation() throws {
        try writeFile(at: ["2024-04-08_001.HEIC"])
        try writeFile(at: ["2024-04-09_001.HEIC"])
        let plan = try ReorganizeExecutor().plan(
            destinationRoot: temporaryDirectoryURL,
            targetStructure: .yyyyMMDD
        )
        XCTAssertEqual(plan.moves.count, 2)

        let flag = AtomicFlag()
        let observer = ReorganizeExecutionObserver(onTaskProgress: { _, _ in flag.set(true) })

        let result = ReorganizeExecutor().execute(
            plan: plan,
            observer: observer,
            isCancelled: { flag.value }
        )

        XCTAssertEqual(result.movedCount, 1, "Cancellation should stop the loop after one move")
    }

    func testExecuteReportsProgressEachStep() throws {
        try writeFile(at: ["2024-04-08_001.HEIC"])
        try writeFile(at: ["2024-04-08_002.HEIC"])
        try writeFile(at: ["2024-04-09_001.HEIC"])
        let plan = try ReorganizeExecutor().plan(
            destinationRoot: temporaryDirectoryURL,
            targetStructure: .yyyyMMDD
        )

        let startTotal = Box<Int>(-1)
        let progressEvents = Recorder<(Int, Int)>()
        let observer = ReorganizeExecutionObserver(
            onTaskStart: { total in startTotal.set(total) },
            onTaskProgress: { completed, total in progressEvents.append((completed, total)) }
        )

        _ = ReorganizeExecutor().execute(plan: plan, observer: observer)

        XCTAssertEqual(startTotal.value, 3)
        XCTAssertEqual(progressEvents.count, 3)
        XCTAssertEqual(progressEvents.values.last?.0, 3)
        XCTAssertEqual(progressEvents.values.last?.1, 3)
    }

    func testExecuteEmptyPlanIsNoOp() {
        let plan = ReorganizePlan(
            destinationRoot: temporaryDirectoryURL.path,
            targetStructure: .yyyyMMDD,
            moves: [],
            unchangedCount: 0,
            unrecognizedCount: 0
        )
        let result = ReorganizeExecutor().execute(plan: plan)
        XCTAssertEqual(result.movedCount, 0)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.totalMoves, 0)
    }

    // MARK: - Helpers

    @discardableResult
    private func writeFile(at relativeComponents: [String]) throws -> URL {
        var url = temporaryDirectoryURL!
        for (index, component) in relativeComponents.enumerated() {
            if index < relativeComponents.count - 1 {
                url.appendPathComponent(component, isDirectory: true)
            } else {
                url.appendPathComponent(component)
            }
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("test".utf8).write(to: url)
        return url
    }

    private final class AtomicFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        var value: Bool {
            lock.lock(); defer { lock.unlock() }
            return _value
        }
        func set(_ newValue: Bool) {
            lock.lock(); defer { lock.unlock() }
            _value = newValue
        }
    }

    private final class Recorder<Element>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Element] = []
        func append(_ value: Element) {
            lock.lock(); defer { lock.unlock() }
            items.append(value)
        }
        var values: [Element] {
            lock.lock(); defer { lock.unlock() }
            return items
        }
        var count: Int { values.count }
    }

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T
        init(_ value: T) { self._value = value }
        var value: T {
            lock.lock(); defer { lock.unlock() }
            return _value
        }
        func set(_ newValue: T) {
            lock.lock(); defer { lock.unlock() }
            _value = newValue
        }
    }
}

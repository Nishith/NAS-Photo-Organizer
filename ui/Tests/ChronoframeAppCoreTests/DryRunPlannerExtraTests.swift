import XCTest
@testable import ChronoframeCore

final class DryRunPlannerExtraTests: XCTestCase {
    func testDryRunPlanningResultProperties() {
        let result = DryRunPlanningResult(
            discoveredSourceCount: 1,
            destinationIndexedCount: 1,
            sourceHashedCount: 1,
            copyPlan: CopyPlanResult(
                transfers: [],
                counts: CopyPlanCounts(),
                warningMessages: ["warn"],
                sequenceState: SequenceCounterState(),
                infoMessages: ["info"],
                dateHistogram: []
            )
        )
        
        XCTAssertEqual(result.copyJobs.count, 0)
        XCTAssertEqual(result.transfers.count, 0)
        XCTAssertEqual(result.transferCount, 0)
        XCTAssertEqual(result.counts.newCount, 0)
        XCTAssertEqual(result.warningMessages, ["warn"])
        XCTAssertEqual(result.infoMessages, ["info"])
        XCTAssertEqual(result.dateHistogram.count, 0)
    }
    
    func testDryRunPlannerHashErrorPath() async throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DryRunPlannerHashErrorTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        
        let sourceDir = temporaryDirectory.appendingPathComponent("source")
        let destDir = temporaryDirectory.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        
        let fileURL = sourceDir.appendingPathComponent("error.jpg")
        try Data("unreadable".utf8).write(to: fileURL)
        
        // Make the file unreadable to trigger a hash error
        let path = fileURL.path
        _ = path.withCString { Darwin.chmod($0, 0) }
        defer { _ = path.withCString { Darwin.chmod($0, 0o644) } }
        
        let planner = DryRunPlanner()
        let result = try planner.plan(sourceRoot: sourceDir, destinationRoot: destDir)
        
        XCTAssertEqual(result.counts.hashErrorCount, 1)
        XCTAssertEqual(result.previewReviewItems.first?.status, .hashError)
    }
    
    func testDryRunPlannerFolderStructures() async throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DryRunPlannerFolderTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        
        let sourceDir = temporaryDirectory.appendingPathComponent("source")
        let destDir = temporaryDirectory.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        
        let fileURL = sourceDir.appendingPathComponent("2023-01-01_file.jpg")
        try Data("image".utf8).write(to: fileURL)
        
        let planner = DryRunPlanner()
        
        // Test YYYY
        let resultYYYY = try planner.plan(sourceRoot: sourceDir, destinationRoot: destDir, folderStructure: .yyyy)
        XCTAssertTrue(resultYYYY.transfers.first?.destinationPath.contains("/2023/") ?? false)
        
        // Test YYYY/MM
        let resultMM = try planner.plan(sourceRoot: sourceDir, destinationRoot: destDir, folderStructure: .yyyyMM)
        XCTAssertTrue(resultMM.transfers.first?.destinationPath.contains("/2023/01/") ?? false)
        
        // Test Flat
        let resultFlat = try planner.plan(sourceRoot: sourceDir, destinationRoot: destDir, folderStructure: .flat)
        XCTAssertFalse(resultFlat.transfers.first?.destinationPath.contains("/2023/") ?? true)
    }
    
    func testDryRunPlannerEventSuggestions() async throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DryRunPlannerEventTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        
        let sourceDir = temporaryDirectory.appendingPathComponent("source/Event Name")
        let destDir = temporaryDirectory.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        
        let fileURL = sourceDir.appendingPathComponent("2023-01-01_file.jpg")
        try Data("image".utf8).write(to: fileURL)
        
        let planner = DryRunPlanner()
        let result = try planner.plan(sourceRoot: sourceDir.deletingLastPathComponent(), 
                                      destinationRoot: destDir, 
                                      eventSuggestionMode: .suggest)
        
        XCTAssertNotNil(result.previewReviewItems.first?.eventSuggestion)
    }
    
    func testDryRunPlannerIgnoresStaleDestinationRecord() async throws {
        // A stale database record for a file that no longer exists on disk
        // must not cause the planner to treat a new source file as already
        // in destination. The full-scan path discovers only files present on
        // disk, so the stale record is effectively invisible to the snapshot.
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DryRunPlannerIgnoreStale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceDir = temporaryDirectory.appendingPathComponent("source")
        let destDir = temporaryDirectory.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Seed a source file whose hash will match the stale destination record.
        let sourceFile = sourceDir.appendingPathComponent("sub/IMG_20260101_120000.jpg")
        try FileManager.default.createDirectory(at: sourceFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("stale-test".utf8).write(to: sourceFile)

        let dbURL = destDir.appendingPathComponent(".organize_cache.db")
        let database = try OrganizerDatabase(url: dbURL)

        // Stale record: path doesn't exist on disk, hash matches source file hash.
        let fakePath = destDir.appendingPathComponent("missing.jpg").path
        let fakeRecord = RawFileCacheRecord(
            namespace: .destination,
            path: fakePath,
            hash: "fakehash",
            size: 100,
            modificationTime: 12345.0
        )
        try database.saveRawCacheRecords([fakeRecord])
        database.close()

        let planner = DryRunPlanner()
        let result = try planner.plan(sourceRoot: sourceDir, destinationRoot: destDir)

        // The source file must appear in the copy plan — the stale record
        // must not suppress it as already-in-destination.
        XCTAssertEqual(result.counts.newCount, 1, "Source file must be planned for copy despite stale dest record")
        XCTAssertEqual(result.counts.alreadyInDestinationCount, 0)
    }
    
    func testDryRunPlannerEmptySourceThrows() async throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DryRunPlannerEmpty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        
        let planner = DryRunPlanner()
        let result = try planner.plan(sourceRoot: temporaryDirectory, destinationRoot: temporaryDirectory)
        XCTAssertEqual(result.transfers.count, 0)
    }
}

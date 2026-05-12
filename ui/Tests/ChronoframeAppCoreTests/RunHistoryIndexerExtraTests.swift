import XCTest
@testable import ChronoframeAppCore

final class RunHistoryIndexerExtraTests: XCTestCase {
    func testRunHistoryIndexerEdgeCases() throws {
        let indexer = RunHistoryIndexer()
        
        // Empty destination
        XCTAssertEqual(try indexer.index(destinationRoot: "").count, 0)
        XCTAssertEqual(try indexer.index(destinationRoot: "   ").count, 0)
        
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RunHistoryIndexerExtra-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        
        // Test relativePath with path NOT under root (using a trick or direct call if possible)
        // Since it's private, we can't call it directly. 
        // But we can trigger it via index if we pass a weird path.
        // Actually, let's just cover the public surface more.
        
        let logsDir = temporaryDirectory.appendingPathComponent(".organize_logs")
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        
        // Create root-level artifacts
        let logFile = temporaryDirectory.appendingPathComponent(".organize_log.txt")
        try Data("log content".utf8).write(to: logFile)
        
        let dbFile = temporaryDirectory.appendingPathComponent(".organize_cache.db")
        try Data("db content".utf8).write(to: dbFile)
        
        let jsonFile = logsDir.appendingPathComponent("extra.json")
        try Data("{}".utf8).write(to: jsonFile)
        
        let csvFile = logsDir.appendingPathComponent("extra.csv")
        try Data("a,b,c".utf8).write(to: csvFile)
        
        let complexJson = logsDir.appendingPathComponent("complex_name-test.json")
        try Data("{}".utf8).write(to: complexJson)
        
        let results = try indexer.index(destinationRoot: temporaryDirectory.path)
        XCTAssertEqual(results.count, 5) // log, db, jsonFile, csvFile, complexJson
        
        // Test with a path that is a file (should handle gracefully via resourceValues)
        _ = try indexer.index(destinationRoot: logFile.path)
    }
}

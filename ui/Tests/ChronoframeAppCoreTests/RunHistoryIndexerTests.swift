import Foundation
import XCTest
@testable import ChronoframeAppCore

final class RunHistoryIndexerTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChronoframeRunHistoryIndexerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        try super.tearDownWithError()
    }

    func testIndexDiscoversQueueDatabaseAndStructuredArtifacts() throws {
        let logFile = temporaryDirectoryURL.appendingPathComponent(".organize_log.txt")
        let queueDatabase = temporaryDirectoryURL.appendingPathComponent(".organize_cache.db")
        let logsDirectory = temporaryDirectoryURL.appendingPathComponent(".organize_logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

        let report = logsDirectory.appendingPathComponent("dry_run_report_20260413_120000.csv")
        let receipt = logsDirectory.appendingPathComponent("audit_receipt_20260413_121500.json")
        let stats = logsDirectory.appendingPathComponent("hash_stats.csv")
        let summary = logsDirectory.appendingPathComponent("queue_summary.json")
        let ignored = logsDirectory.appendingPathComponent("preview.txt")

        try "run log".write(to: logFile, atomically: true, encoding: .utf8)
        try "sqlite".write(to: queueDatabase, atomically: true, encoding: .utf8)
        try "report".write(to: report, atomically: true, encoding: .utf8)
        try "{}".write(to: receipt, atomically: true, encoding: .utf8)
        try "bytes".write(to: stats, atomically: true, encoding: .utf8)
        try "{\"status\": \"ok\"}".write(to: summary, atomically: true, encoding: .utf8)
        try "skip".write(to: ignored, atomically: true, encoding: .utf8)

        try setModificationDate(Date(timeIntervalSince1970: 10), for: logFile)
        try setModificationDate(Date(timeIntervalSince1970: 20), for: queueDatabase)
        try setModificationDate(Date(timeIntervalSince1970: 30), for: report)
        try setModificationDate(Date(timeIntervalSince1970: 40), for: receipt)
        try setModificationDate(Date(timeIntervalSince1970: 50), for: stats)
        try setModificationDate(Date(timeIntervalSince1970: 60), for: summary)

        let indexer = RunHistoryIndexer()
        let entries = try indexer.index(destinationRoot: temporaryDirectoryURL.path)

        XCTAssertEqual(entries.map(\.kind), [
            .jsonArtifact,
            .csvArtifact,
            .auditReceipt,
            .dryRunReport,
            .queueDatabase,
            .runLog,
        ])

        XCTAssertEqual(entries.map(\.relativePath), [
            ".organize_logs/queue_summary.json",
            ".organize_logs/hash_stats.csv",
            ".organize_logs/audit_receipt_20260413_121500.json",
            ".organize_logs/dry_run_report_20260413_120000.csv",
            ".organize_cache.db",
            ".organize_log.txt",
        ])

        XCTAssertEqual(entries.first?.title, "Queue Summary")
        XCTAssertEqual(entries[1].title, "Hash Stats")
        XCTAssertEqual(entries[4].title, "Queue Database")
        XCTAssertEqual(entries.first?.fileSizeBytes, 16)
        XCTAssertEqual(entries.last?.fileSizeBytes, 7)
    }

    func testIndexReturnsEmptyEntriesForBlankDestination() throws {
        let indexer = RunHistoryIndexer()

        XCTAssertEqual(try indexer.index(destinationRoot: ""), [])
        XCTAssertEqual(try indexer.index(destinationRoot: "   "), [])
    }

    private func setModificationDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}

import Foundation
import XCTest
@testable import ChronoframeAppCore

final class HistoryStoreTests: XCTestCase {
    func testRefreshUsesIndexerResults() {
        let entries = [
            RunHistoryEntry(
                kind: .queueDatabase,
                title: "Queue Database",
                path: "/tmp/run/.organize_cache.db",
                relativePath: ".organize_cache.db",
                fileSizeBytes: 4_096,
                createdAt: Date(timeIntervalSince1970: 30)
            ),
            RunHistoryEntry(
                kind: .auditReceipt,
                title: "Audit Receipt",
                path: "/tmp/run/.organize_logs/audit_receipt.json",
                relativePath: ".organize_logs/audit_receipt.json",
                fileSizeBytes: 512,
                createdAt: Date(timeIntervalSince1970: 20)
            ),
        ]
        let indexer = MockRunHistoryIndexer(result: .success(entries))

        let store = HistoryStore(indexer: indexer)
        store.refresh(destinationRoot: "/tmp/run")

        XCTAssertEqual(store.entries, entries)
        XCTAssertEqual(store.destinationRoot, "/tmp/run")
        XCTAssertNil(store.lastRefreshError)
    }

    func testRemoveEntryTrashesFileAndRemovesFromList() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("audit_receipt.json")
        try Data("{}".utf8).write(to: fileURL)

        let entry = RunHistoryEntry(
            kind: .auditReceipt,
            title: "Audit Receipt",
            path: fileURL.path,
            relativePath: "audit_receipt.json",
            fileSizeBytes: 2,
            createdAt: .now
        )
        let store = HistoryStore(entries: [entry])
        store.remove(entry: entry)

        XCTAssertTrue(store.entries.isEmpty, "Entry should be removed from the in-memory list")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "File should no longer exist at its original path after trashing")
    }

    func testRemoveNonexistentEntryIsIdempotent() {
        let entry = RunHistoryEntry(
            kind: .runLog, title: "Gone", path: "/nonexistent/file.log", createdAt: .now
        )
        let store = HistoryStore(entries: [entry])
        // Should not throw even if file doesn't exist.
        store.remove(entry: entry)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testRemoveAllTrashesAllFilesAndClearsList() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var entries: [RunHistoryEntry] = []
        for i in 1...3 {
            let url = tempDir.appendingPathComponent("file_\(i).json")
            try Data("{}".utf8).write(to: url)
            entries.append(RunHistoryEntry(kind: .auditReceipt, title: "Entry \(i)", path: url.path, createdAt: .now))
        }
        let store = HistoryStore(entries: entries)
        store.removeAll()

        XCTAssertTrue(store.entries.isEmpty, "All entries should be removed")
        for entry in entries {
            XCTAssertFalse(FileManager.default.fileExists(atPath: entry.path),
                           "File should no longer exist: \(entry.path)")
        }
    }

    func testRefreshRecordsIndexerFailures() {
        let indexer = MockRunHistoryIndexer(result: .failure(MockRunHistoryIndexer.Error.sample))
        let store = HistoryStore(
            entries: [
                RunHistoryEntry(kind: .runLog, title: "Run Log", path: "/tmp/old.log", createdAt: .distantPast)
            ],
            indexer: indexer
        )

        store.refresh(destinationRoot: "/tmp/run")

        XCTAssertEqual(store.entries, [])
        XCTAssertEqual(store.destinationRoot, "/tmp/run")
        XCTAssertEqual(
            store.lastRefreshError,
            "Chronoframe could not refresh Run History. Check that the destination drive is connected, then try again. Details: History index failed"
        )
    }
}

private struct MockRunHistoryIndexer: RunHistoryIndexing {
    enum Error: LocalizedError {
        case sample

        var errorDescription: String? {
            "History index failed"
        }
    }

    let result: Result<[RunHistoryEntry], Swift.Error>

    func index(destinationRoot: String) throws -> [RunHistoryEntry] {
        try result.get()
    }
}

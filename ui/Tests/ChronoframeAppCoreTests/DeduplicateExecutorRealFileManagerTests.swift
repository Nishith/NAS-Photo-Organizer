import Foundation
import XCTest
@testable import ChronoframeCore

/// Exercises `DeduplicateExecutor` with the **production** FileManager-backed
/// `DeduplicateFileOperations` adapter (the default initializer) against real
/// files in a per-test temporary directory.
///
/// Existing dedupe tests use a `MockDeduplicateFileOperations` whose
/// `trashItem` is `moveItem`. That mock proves the planner→executor→receipt
/// loop but **does not** prove the bytes actually reach `FileManager.trashItem`,
/// nor that real macOS Trash semantics (cross-volume behavior, `.Trashes/<uid>`
/// directories, name collisions) are handled correctly. These tests run only
/// in the local-dev (un-sandboxed) lane; sandboxed CI may still skip
/// `FileManager.trashItem` if entitlements are missing — surfaced as XCTSkip.
final class DeduplicateExecutorRealFileManagerTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DedupeRealFM-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        try super.tearDownWithError()
    }

    // AGENTS-INVARIANT: 12
    func testRealTrashAdapterMovesFileToMacOSTrashAndWritesReceipt() async throws {
        // Probe FileManager.trashItem capability; sandboxed CI without
        // file-system entitlements rejects it.
        let probe = temporaryDirectoryURL.appendingPathComponent("probe.tmp")
        try Data("probe".utf8).write(to: probe)
        do {
            var trashed: NSURL?
            try FileManager.default.trashItem(at: probe, resultingItemURL: &trashed)
            if let trashed = trashed as URL? {
                try? FileManager.default.removeItem(at: trashed)
            }
        } catch {
            throw XCTSkip("FileManager.trashItem unavailable in this environment: \(error.localizedDescription)")
        }

        let dst = temporaryDirectoryURL.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)

        let targetA = dst.appendingPathComponent("dup-a.jpg")
        let targetB = dst.appendingPathComponent("dup-b.jpg")
        try Data(repeating: 0x42, count: 1024).write(to: targetA)
        try Data(repeating: 0x42, count: 1024).write(to: targetB)

        let executor = DeduplicateExecutor() // production adapter
        let plan = DeduplicationPlan(items: [
            DeduplicationPlan.Item(
                path: targetB.path,
                sizeBytes: 1024,
                owningClusterID: UUID(),
                owningClusterKind: .exactDuplicate,
                pairOrigin: nil
            )
        ])
        let stream = executor.commit(plan: plan, destinationRoot: dst.path, hardDelete: false)

        var trashedEvents: [(originalPath: String, trashURL: URL?)] = []
        var completed: DeduplicateCommitSummary?
        for try await event in stream {
            switch event {
            case let .itemTrashed(originalPath, trashURL, _):
                trashedEvents.append((originalPath, trashURL))
            case let .complete(summary):
                completed = summary
            default:
                break
            }
        }

        XCTAssertEqual(trashedEvents.count, 1)
        let trashedURL = try XCTUnwrap(trashedEvents.first?.trashURL,
            "Real FileManager.trashItem must populate resultingItemURL")
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetB.path),
            "Trashed file must no longer exist at the original path")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashedURL.path),
            "Trashed file must exist at the returned trash URL: \(trashedURL.path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetA.path),
            "Untouched cluster mate must remain on disk")

        let summary = try XCTUnwrap(completed)
        XCTAssertEqual(summary.deletedCount, 1)
        XCTAssertEqual(summary.failedCount, 0)

        // Receipt must record the trashURL so revert can restore.
        let logsDir = dst.appendingPathComponent(".organize_logs", isDirectory: true)
        let receipts = (try FileManager.default.contentsOfDirectory(atPath: logsDir.path))
            .filter { $0.hasPrefix("dedupe_audit_receipt_") && $0.hasSuffix(".json") }
        XCTAssertEqual(receipts.count, 1, "Exactly one COMPLETED receipt")
        let receiptData = try Data(contentsOf: logsDir.appendingPathComponent(receipts[0]))
        let receiptJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: receiptData) as? [String: Any]
        )
        XCTAssertEqual(receiptJSON["status"] as? String, "COMPLETED")
        let items = try XCTUnwrap(receiptJSON["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertNotNil(items[0]["trashURL"] as? String,
            "Receipt entry must record the on-disk trashURL for revert to work")

        // Clean up the file we trashed so it doesn't pollute the user's Trash.
        try? FileManager.default.removeItem(at: trashedURL)
    }
}

import Foundation
import XCTest
@testable import ChronoframeCore

/// Phase 1 finding #3 regression: a crashed organize run used to
/// leave the destination with copied files but no recoverable audit
/// receipt — the `StreamingAuditReceiptWriter` only wrote the JSON
/// receipt at `finish()`, so SIGKILL/power-loss between transfers
/// produced no Run History entry. The fix writes a PENDING receipt
/// at init time and adds `TransferExecutor.recoverInterruptedRuns(at:)`
/// that consolidates PENDING receipts + their `.transfers.tmp` spools
/// into ABORTED receipts the user can revert.
final class TransferExecutorCrashRecoveryTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferExecutorCrashRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        try super.tearDownWithError()
    }

    func testRecoveryConsolidatesPendingReceiptAndSpoolIntoAbortedReceipt() throws {
        let logsDirectory = temporaryDirectoryURL.appendingPathComponent(".organize_logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

        // Simulate a crashed run: a PENDING receipt header plus a
        // spool containing two completed transfers. The shape mirrors
        // exactly what `StreamingAuditReceiptWriter` writes during a
        // normal run before `finish()` rewrites the receipt.
        let runID = UUID().uuidString
        let stem = "audit_receipt_20260518_120000_\(runID)"
        let receiptURL = logsDirectory.appendingPathComponent("\(stem).json")
        let spoolURL = logsDirectory.appendingPathComponent("\(stem).transfers.tmp")

        let pendingHeader: [String: Any] = [
            "schemaVersion": 2,
            "runID": runID,
            "operation": "organize",
            "status": "PENDING",
            "timestamp": "2026-05-18T12:00:00Z",
            "startedAt": "2026-05-18T12:00:00Z",
            "transferSpool": spoolURL.lastPathComponent,
            "transfers": [],
        ]
        let pendingData = try JSONSerialization.data(withJSONObject: pendingHeader, options: [.prettyPrinted])
        try pendingData.write(to: receiptURL, options: [.atomic])

        let spoolBody = """
            {"dest":"/dst/2024/01/01/IMG_01.jpg","hash":"100_aaa","source":"/src/IMG_01.jpg"},
            {"dest":"/dst/2024/01/02/IMG_02.jpg","hash":"200_bbb","source":"/src/IMG_02.jpg"}
        """
        try spoolBody.data(using: .utf8)!.write(to: spoolURL, options: [.atomic])

        // Now run the recovery sweep.
        let executor = makeExecutor()
        let recovered = executor.recoverInterruptedRuns(at: temporaryDirectoryURL)
        XCTAssertEqual(recovered, 1, "Exactly one PENDING receipt should be consolidated")

        // Spool is removed.
        XCTAssertFalse(FileManager.default.fileExists(atPath: spoolURL.path))

        // Receipt was rewritten as ABORTED with the spool's transfers
        // inlined.
        let consolidatedData = try Data(contentsOf: receiptURL)
        let consolidated = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: consolidatedData) as? [String: Any]
        )
        XCTAssertEqual(consolidated["status"] as? String, "ABORTED")
        XCTAssertEqual(consolidated["runID"] as? String, runID)
        XCTAssertNotNil(consolidated["recoveredAt"])
        let transfers = try XCTUnwrap(consolidated["transfers"] as? [[String: Any]])
        XCTAssertEqual(transfers.count, 2)
        XCTAssertEqual(transfers[0]["source"] as? String, "/src/IMG_01.jpg")
        XCTAssertEqual(transfers[1]["dest"] as? String, "/dst/2024/01/02/IMG_02.jpg")
    }

    func testRecoveryLeavesCompletedReceiptsAlone() throws {
        let logsDirectory = temporaryDirectoryURL.appendingPathComponent(".organize_logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

        let receiptURL = logsDirectory.appendingPathComponent("audit_receipt_20260518_120000_completed.json")
        let completed: [String: Any] = [
            "schemaVersion": 2,
            "status": "COMPLETED",
            "transfers": [
                ["source": "/s", "dest": "/d", "hash": "1_x"] as [String: Any],
            ] as [Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: completed, options: [.prettyPrinted])
        try data.write(to: receiptURL)
        let originalSize = (try FileManager.default.attributesOfItem(atPath: receiptURL.path)[.size] as? NSNumber)?.intValue

        let executor = makeExecutor()
        let recovered = executor.recoverInterruptedRuns(at: temporaryDirectoryURL)
        XCTAssertEqual(recovered, 0, "COMPLETED receipts must not be rewritten by the recovery sweep")

        let postSize = (try FileManager.default.attributesOfItem(atPath: receiptURL.path)[.size] as? NSNumber)?.intValue
        XCTAssertEqual(originalSize, postSize, "Receipt file should not have been touched")
    }

    private func makeExecutor() -> TransferExecutor {
        TransferExecutor()
    }
}

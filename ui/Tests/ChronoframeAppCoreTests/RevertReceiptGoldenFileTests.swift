import Foundation
import XCTest
@testable import ChronoframeCore

/// Golden-file tests that pin the on-disk shape of `audit_receipt_*.json` and
/// the behavior of `RevertReceipt`'s decoder for each schemaVersion the writer
/// has emitted (or could plausibly emit).
///
/// Existing roundtrip tests encode-then-decode through a single shape; they
/// cannot surface the gap where a future writer emits `schemaVersion: 3` and
/// the v2 reader silently treats it as a v2 receipt. These tests load
/// hand-crafted JSON fixtures so each schema variant is exercised explicitly.
///
/// **These tests document, not enforce, the current schemaVersion gap**: a
/// v99 receipt is decoded as a v2 receipt today (Finding #6 in
/// prodsec/Chronoframe/TOP_IMPROVEMENTS.md). When the reader is upgraded to
/// reject unknown forward versions, the `testCurrentDecoderSilentlyAccepts*`
/// case will need to flip to assert the expected `unsupportedSchema` error.
final class RevertReceiptGoldenFileTests: XCTestCase {

    // MARK: V2 — current writer shape

    private static let v2Receipt = #"""
    {
      "schemaVersion": 2,
      "timestamp": "2026-04-15T12:00:00Z",
      "status": "COMPLETED",
      "total_jobs": 2,
      "transfers": [
        {
          "source": "/Volumes/Source/IMG_0001.jpg",
          "dest": "/Volumes/Destination/2024/06/15/2024-06-15_001.jpg",
          "hash": "1024_aabbccdd"
        },
        {
          "source": "/Volumes/Source/IMG_0002.heic",
          "dest": "/Volumes/Destination/2024/06/15/2024-06-15_002.heic",
          "hash": "2048_eeff0011"
        }
      ]
    }
    """#

    func testCurrentDecoderParsesV2ReceiptIntoTransferList() throws {
        let data = Self.v2Receipt.data(using: .utf8)!
        let receipt = try JSONDecoder().decode(RevertReceipt.self, from: data)
        XCTAssertEqual(receipt.status, "COMPLETED")
        XCTAssertEqual(receipt.timestamp, "2026-04-15T12:00:00Z")
        XCTAssertEqual(receipt.totalJobs, 2)
        XCTAssertEqual(receipt.transfers.count, 2)
        XCTAssertEqual(receipt.transfers[0].source, "/Volumes/Source/IMG_0001.jpg")
        XCTAssertEqual(receipt.transfers[0].dest, "/Volumes/Destination/2024/06/15/2024-06-15_001.jpg")
        XCTAssertEqual(receipt.transfers[0].hash, "1024_aabbccdd")
    }

    // MARK: V1 — early writer shape (no status, no schemaVersion)

    private static let v1Receipt = #"""
    {
      "timestamp": "2024-01-15T10:00:00Z",
      "total_jobs": 1,
      "transfers": [
        {
          "source": "/old/IMG_0001.jpg",
          "dest": "/dest/2024/01/15/2024-01-15_001.jpg",
          "hash": "512_legacyhash"
        }
      ]
    }
    """#

    func testCurrentDecoderAcceptsLegacyV1ReceiptWithoutStatusField() throws {
        let data = Self.v1Receipt.data(using: .utf8)!
        let receipt = try JSONDecoder().decode(RevertReceipt.self, from: data)
        XCTAssertNil(receipt.status, "Legacy receipts without status should decode with status == nil")
        XCTAssertEqual(receipt.totalJobs, 1)
        XCTAssertEqual(receipt.transfers.count, 1)
    }

    // MARK: Status variants the writer can produce

    private static func receiptJSON(withStatus status: String, transferCount: Int = 1) -> String {
        let transfers = (0..<transferCount).map { i in
            #"""
            {"source": "/s/\#(i)", "dest": "/d/\#(i)", "hash": "\#(i)_h\#(i)"}
            """#
        }.joined(separator: ",\n          ")
        return #"""
        {
          "schemaVersion": 2,
          "timestamp": "2026-04-15T12:00:00Z",
          "status": "\#(status)",
          "total_jobs": \#(transferCount),
          "transfers": [
            \#(transfers)
          ]
        }
        """#
    }

    // AGENTS-INVARIANT: 9
    func testCurrentDecoderAcceptsAllStatusValuesTheWriterEmits() throws {
        for status in ["PENDING", "COMPLETED", "ABORTED", "FAILED"] {
            let data = Self.receiptJSON(withStatus: status).data(using: .utf8)!
            let receipt = try JSONDecoder().decode(RevertReceipt.self, from: data)
            XCTAssertEqual(receipt.status, status)
            XCTAssertEqual(receipt.transfers.count, 1)
        }
    }

    // MARK: Forward-compat gap — Finding #6

    private static let v99Receipt = #"""
    {
      "schemaVersion": 99,
      "timestamp": "2030-01-01T00:00:00Z",
      "status": "COMPLETED",
      "total_jobs": 1,
      "identityScheme": "blake3-v1",
      "boundary": "/Volumes/Future",
      "transfers": [
        {
          "source": "/s/a.jpg",
          "dest": "/d/a.jpg",
          "hash": "1024_future_hash_with_different_algorithm"
        }
      ]
    }
    """#

    /// Documents Finding #6: a future writer (schemaVersion 99) emits unknown
    /// fields. The current reader silently drops them and decodes the receipt
    /// as if it were v2. If `identityScheme` semantics change so that "hash"
    /// is no longer BLAKE2b, an in-the-wild v2 reader will mis-revert (hashes
    /// will never match, every transfer becomes "preserved").
    ///
    /// When the schemaVersion gate lands, change this test to assert a typed
    /// `unsupportedSchema(version: 99)` error and remove the documentation.
    func testCurrentDecoderSilentlyAcceptsUnknownFutureSchemaVersion() throws {
        let data = Self.v99Receipt.data(using: .utf8)!
        let receipt = try JSONDecoder().decode(RevertReceipt.self, from: data)
        XCTAssertEqual(
            receipt.status, "COMPLETED",
            "Today's decoder silently treats v99 as decodable. Finding #6: this is the bug."
        )
        XCTAssertEqual(receipt.transfers.count, 1)
        XCTAssertEqual(receipt.transfers[0].hash, "1024_future_hash_with_different_algorithm")
    }

    // MARK: Malformed shapes the decoder must reject

    private static let receiptMissingHash = #"""
    {
      "status": "COMPLETED",
      "transfers": [
        { "source": "/s", "dest": "/d" }
      ]
    }
    """#

    func testDecoderRejectsTransferMissingRequiredFields() {
        let data = Self.receiptMissingHash.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(RevertReceipt.self, from: data))
    }

    private static let receiptEmptyTransfers = #"""
    { "status": "COMPLETED", "transfers": [] }
    """#

    func testDecoderAcceptsEmptyTransferList() throws {
        let data = Self.receiptEmptyTransfers.data(using: .utf8)!
        let receipt = try JSONDecoder().decode(RevertReceipt.self, from: data)
        XCTAssertTrue(receipt.transfers.isEmpty)
    }
}

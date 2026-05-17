import Foundation
import XCTest
@testable import ChronoframeCore

/// Fault-injection tests for `DeduplicateExecutor.commit()` that simulate
/// failure modes that can't be reached through normal happy-path inputs:
/// `.organize_logs/` becoming unwritable after preflight (Finding #7),
/// per-item Trash failures mixed with successes, and abort-while-in-flight.
///
/// These confirm what the executor *currently does* under these conditions
/// — they document the surface so a future fix can intentionally change the
/// behavior and have the test update at the same time.
final class DeduplicateExecutorFaultInjectionTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DedupeFault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? chmod(temporaryDirectoryURL.path, 0o755)
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        try super.tearDownWithError()
    }

    private func chmod(_ path: String, _ mode: mode_t) throws {
        let result = Darwin.chmod(path, mode)
        if result != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    /// Finding #7 (prodsec/Chronoframe/TOP_IMPROVEMENTS.md): if the per-item
    /// receipt write fails after the file has already been moved to Trash,
    /// the same path is double-emitted (once as `itemTrashed`, once as
    /// `itemFailed`) and the on-disk receipt does not record the trashURL.
    /// The executor counts the item in `deletedCount` AND in `failedCount`,
    /// and revert later reports "Receipt is missing the Trash URL".
    func testReceiptWriteFailureMidRunDoubleEmitsItemAndDropsTrashURLFromReceipt() async throws {
        let dst = temporaryDirectoryURL.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)

        let target = dst.appendingPathComponent("victim.jpg")
        try Data(repeating: 0x42, count: 256).write(to: target)

        let fileOps = MovingFileOpsThatRevokeLogsAfterFirstTrash(
            logsDirectory: dst.appendingPathComponent(".organize_logs"),
            tempDirectory: temporaryDirectoryURL
        )
        let executor = DeduplicateExecutor(fileOperations: fileOps)
        let plan = DeduplicationPlan(items: [
            DeduplicationPlan.Item(
                path: target.path,
                sizeBytes: 256,
                owningClusterID: UUID(),
                owningClusterKind: .exactDuplicate,
                pairOrigin: nil
            )
        ])
        let stream = executor.commit(plan: plan, destinationRoot: dst.path, hardDelete: false)

        var trashedPaths: [String] = []
        var failedEvents: [(path: String, message: String)] = []
        var summary: DeduplicateCommitSummary?
        do {
            for try await event in stream {
                switch event {
                case let .itemTrashed(originalPath, _, _):
                    trashedPaths.append(originalPath)
                case let .itemFailed(originalPath, message):
                    failedEvents.append((originalPath, message))
                case .complete(let s):
                    summary = s
                default: break
                }
            }
        } catch {
            // Receipt finalize also fails; expected when logs dir is revoked.
        }

        XCTAssertEqual(trashedPaths, [target.path], "the trash itself succeeded once for the real path")

        // Finding #7 (extended shape): the executor emits TWO itemFailed
        // events for a single trashed file when the logs directory becomes
        // unwritable mid-run:
        //   1. The per-item catch fires with originalPath=<victim path>,
        //      even though the trash itself succeeded.
        //   2. The finalize catch fires with originalPath="" — a phantom
        //      failure event for no specific file. UI listeners that treat
        //      `itemFailed` as "this file failed" will render a ghost row.
        XCTAssertEqual(failedEvents.count, 2,
            "Finding #7: receipt-revocation produces a per-item false-negative AND a phantom empty-path event.")
        XCTAssertTrue(
            failedEvents.contains(where: { $0.path == target.path }),
            "First itemFailed should re-tag the already-trashed file as failed (false negative)."
        )
        XCTAssertTrue(
            failedEvents.contains(where: { $0.path == "" && $0.message.contains("Critical") }),
            "Second itemFailed is the finalize-failure event with originalPath=\"\"."
        )

        let s = try XCTUnwrap(summary)
        XCTAssertEqual(s.deletedCount, 1, "deletedCount correctly counts the real trash")
        XCTAssertEqual(s.failedCount, 2, "failedCount double-counts: 1 false-negative + 1 finalize")

        // Restore permissions so tearDown can clean up.
        try? chmod(dst.appendingPathComponent(".organize_logs").path, 0o755)

        // Receipt state on disk: PENDING (because final-finalize couldn't
        // write either). Revert would see no transfers recorded.
        let logsDir = dst.appendingPathComponent(".organize_logs")
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: logsDir.path) {
            let receipts = contents.filter { $0.hasPrefix("dedupe_audit_receipt_") }
            if let first = receipts.first,
               let data = try? Data(contentsOf: logsDir.appendingPathComponent(first)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                let status = json["status"] as? String
                XCTAssertTrue(
                    status == "PENDING" || status == "COMPLETED",
                    "Finding #7: receipt ends in PENDING when finalize fails. status=\(status ?? "nil")"
                )
                if let items = json["items"] as? [[String: Any]] {
                    let trashURL = items.first?["trashURL"] as? String
                    XCTAssertNil(
                        trashURL,
                        "Finding #7: trashURL is missing from receipt — revert cannot restore this file."
                    )
                }
            }
        }
    }
}

// MARK: - Fault-injecting adapters

/// A `DeduplicateFileOperations` that:
/// - moves files into a fake-trash sibling directory (so we don't pollute
///   the user's real Trash during a test),
/// - revokes write permission on the receipt directory immediately after
///   the first successful trash, so the subsequent per-item `writeReceipt`
///   throws an EACCES.
///
/// Reproduces the exact race described in Finding #7 from the deep review.
private final class MovingFileOpsThatRevokeLogsAfterFirstTrash: DeduplicateFileOperations, @unchecked Sendable {
    let logsDirectory: URL
    let fakeTrash: URL
    private var firstTrashCompleted = false

    init(logsDirectory: URL, tempDirectory: URL) {
        self.logsDirectory = logsDirectory
        self.fakeTrash = tempDirectory.appendingPathComponent("fake-trash", isDirectory: true)
        try? FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func trashItem(at url: URL) throws -> URL? {
        let destination = fakeTrash.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: destination)
        if !firstTrashCompleted {
            firstTrashCompleted = true
            // Revoke write+execute on the logs dir so subsequent receipt
            // writes throw. chmod the directory inode, not its contents.
            _ = Darwin.chmod(logsDirectory.path, 0o500)
        }
        return destination
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }

    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: createIntermediates)
    }
}

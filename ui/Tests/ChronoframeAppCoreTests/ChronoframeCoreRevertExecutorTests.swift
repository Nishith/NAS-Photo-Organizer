import Foundation
import XCTest
@testable import ChronoframeCore

final class ChronoframeCoreRevertExecutorTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChronoframeCoreRevertExecutorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        try super.tearDownWithError()
    }

    // MARK: - Receipt decoding

    func testLoadReceiptDecodesPythonAuditReceiptFormat() throws {
        let receiptURL = temporaryDirectoryURL.appendingPathComponent("audit_receipt_test.json")
        let json = """
        {
            "timestamp": "2026-04-24T10:00:00.000000",
            "total_jobs": 2,
            "status": "COMPLETED",
            "transfers": [
                { "source": "/src/a.jpg", "dest": "/dst/2024/05/a.jpg", "hash": "5_abc123" },
                { "source": "/src/b.mov", "dest": "/dst/2024/05/b.mov", "hash": "10_def456" }
            ]
        }
        """
        try Data(json.utf8).write(to: receiptURL)

        let receipt = try RevertExecutor().loadReceipt(at: receiptURL)

        XCTAssertEqual(receipt.timestamp, "2026-04-24T10:00:00.000000")
        XCTAssertEqual(receipt.totalJobs, 2)
        XCTAssertEqual(receipt.status, "COMPLETED")
        XCTAssertEqual(receipt.transfers.count, 2)
        XCTAssertEqual(receipt.transfers[0].source, "/src/a.jpg")
        XCTAssertEqual(receipt.transfers[0].dest, "/dst/2024/05/a.jpg")
        XCTAssertEqual(receipt.transfers[0].hash, "5_abc123")
        XCTAssertEqual(receipt.transfers[1].hash, "10_def456")
    }

    func testLoadReceiptToleratesMissingOptionalFields() throws {
        let receiptURL = temporaryDirectoryURL.appendingPathComponent("audit_receipt_minimal.json")
        try Data(#"{"transfers":[]}"#.utf8).write(to: receiptURL)

        let receipt = try RevertExecutor().loadReceipt(at: receiptURL)

        XCTAssertNil(receipt.timestamp)
        XCTAssertNil(receipt.totalJobs)
        XCTAssertNil(receipt.status)
        XCTAssertEqual(receipt.transfers.count, 0)
    }

    func testLoadReceiptThrowsForMissingFile() {
        let missingURL = temporaryDirectoryURL.appendingPathComponent("does_not_exist.json")

        XCTAssertThrowsError(try RevertExecutor().loadReceipt(at: missingURL)) { error in
            guard case let RevertExecutorError.receiptNotFound(path) = error else {
                XCTFail("Expected receiptNotFound, got \(error)")
                return
            }
            XCTAssertEqual(path, missingURL.path)
        }
    }

    func testLoadReceiptThrowsForMalformedJSON() throws {
        let receiptURL = temporaryDirectoryURL.appendingPathComponent("bad.json")
        try Data("{not valid json".utf8).write(to: receiptURL)

        XCTAssertThrowsError(try RevertExecutor().loadReceipt(at: receiptURL)) { error in
            guard case RevertExecutorError.invalidReceipt = error else {
                XCTFail("Expected invalidReceipt, got \(error)")
                return
            }
        }
    }

    // MARK: - Revert behavior

    func testRevertDeletesFilesWhoseHashStillMatches() throws {
        let dstURL = temporaryDirectoryURL.appendingPathComponent("photo.jpg")
        try Data("alpha".utf8).write(to: dstURL)
        let identity = try FileIdentityHasher().hashIdentity(at: dstURL)

        let receipt = RevertReceipt(
            transfers: [
                RevertReceiptTransfer(source: "/src/photo.jpg", dest: dstURL.path, hash: identity.rawValue)
            ]
        )

        let result = RevertExecutor().revert(receipt: receipt)

        XCTAssertEqual(result.revertedCount, 1)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.missingCount, 0)
        XCTAssertEqual(result.totalTransfers, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dstURL.path))
    }

    func testRevertPreservesFilesWithMismatchedHash() throws {
        let dstURL = temporaryDirectoryURL.appendingPathComponent("modified.jpg")
        try Data("modified content".utf8).write(to: dstURL)

        let receipt = RevertReceipt(
            transfers: [
                RevertReceiptTransfer(
                    source: "/src/modified.jpg",
                    dest: dstURL.path,
                    hash: "5_originalhash" // Will not match current file
                )
            ]
        )

        let issues = Recorder<RunIssue>()
        let observer = RevertExecutionObserver(onIssue: { issues.append($0) })
        let result = RevertExecutor().revert(receipt: receipt, observer: observer)

        XCTAssertEqual(result.revertedCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.missingCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dstURL.path), "Modified file must be preserved")
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues.values[0].message.contains("Preserved"))
    }

    func testRevertCountsMissingFilesSeparatelyButDoesNotFail() throws {
        let receipt = RevertReceipt(
            transfers: [
                RevertReceiptTransfer(
                    source: "/src/gone.jpg",
                    dest: temporaryDirectoryURL.appendingPathComponent("never_existed.jpg").path,
                    hash: "5_anyhash"
                )
            ]
        )

        let result = RevertExecutor().revert(receipt: receipt)

        XCTAssertEqual(result.revertedCount, 0)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.missingCount, 1)
        XCTAssertEqual(result.totalTransfers, 1)
    }

    func testRevertCleansUpEmptyParentDirectory() throws {
        let nestedDir = temporaryDirectoryURL.appendingPathComponent("2024/05/01", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        let dstURL = nestedDir.appendingPathComponent("only.jpg")
        try Data("only".utf8).write(to: dstURL)
        let identity = try FileIdentityHasher().hashIdentity(at: dstURL)

        let receipt = RevertReceipt(
            transfers: [
                RevertReceiptTransfer(source: "/src/only.jpg", dest: dstURL.path, hash: identity.rawValue)
            ]
        )

        _ = RevertExecutor().revert(receipt: receipt)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dstURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: nestedDir.path), "Empty parent directory should be removed")
    }

    func testRevertLeavesNonEmptyParentDirectoryAlone() throws {
        let dir = temporaryDirectoryURL.appendingPathComponent("multi", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dstA = dir.appendingPathComponent("a.jpg")
        let dstB = dir.appendingPathComponent("b.jpg")
        try Data("a".utf8).write(to: dstA)
        try Data("b".utf8).write(to: dstB)
        let identityA = try FileIdentityHasher().hashIdentity(at: dstA)

        let receipt = RevertReceipt(
            transfers: [
                RevertReceiptTransfer(source: "/src/a.jpg", dest: dstA.path, hash: identityA.rawValue)
            ]
        )

        _ = RevertExecutor().revert(receipt: receipt)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dstA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dstB.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    func testRevertEmitsProgressForRevertedAndSkippedButNotMissing() throws {
        // 1 reverted, 1 skipped, 1 missing. Python parity: progress only counts reverted+skipped.
        let revertableURL = temporaryDirectoryURL.appendingPathComponent("ok.jpg")
        try Data("ok".utf8).write(to: revertableURL)
        let okIdentity = try FileIdentityHasher().hashIdentity(at: revertableURL)

        let mismatchURL = temporaryDirectoryURL.appendingPathComponent("mismatch.jpg")
        try Data("xx".utf8).write(to: mismatchURL)

        let receipt = RevertReceipt(
            transfers: [
                RevertReceiptTransfer(source: "/src/ok.jpg", dest: revertableURL.path, hash: okIdentity.rawValue),
                RevertReceiptTransfer(source: "/src/mismatch.jpg", dest: mismatchURL.path, hash: "9_wrong"),
                RevertReceiptTransfer(
                    source: "/src/missing.jpg",
                    dest: temporaryDirectoryURL.appendingPathComponent("absent.jpg").path,
                    hash: "5_irrelevant"
                ),
            ]
        )

        let startTotal = Box<Int>(-1)
        let progressEvents = Recorder<(Int, Int)>()
        let observer = RevertExecutionObserver(
            onTaskStart: { total in startTotal.set(total) },
            onTaskProgress: { completed, total in progressEvents.append((completed, total)) }
        )

        let result = RevertExecutor().revert(receipt: receipt, observer: observer)

        XCTAssertEqual(startTotal.value, 3)
        XCTAssertEqual(result.revertedCount, 1)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.missingCount, 1)
        // Progress fires twice (reverted + skipped); the missing entry does NOT advance the bar.
        XCTAssertEqual(progressEvents.count, 2)
        XCTAssertEqual(progressEvents.values.last?.0, 2)
        XCTAssertEqual(progressEvents.values.last?.1, 3)
    }

    func testRevertHonorsCancellation() throws {
        let urlA = temporaryDirectoryURL.appendingPathComponent("a.jpg")
        let urlB = temporaryDirectoryURL.appendingPathComponent("b.jpg")
        try Data("a".utf8).write(to: urlA)
        try Data("b".utf8).write(to: urlB)
        let identityA = try FileIdentityHasher().hashIdentity(at: urlA)
        let identityB = try FileIdentityHasher().hashIdentity(at: urlB)

        let receipt = RevertReceipt(
            transfers: [
                RevertReceiptTransfer(source: "/src/a.jpg", dest: urlA.path, hash: identityA.rawValue),
                RevertReceiptTransfer(source: "/src/b.jpg", dest: urlB.path, hash: identityB.rawValue),
            ]
        )

        let flag = AtomicFlag()
        let observer = RevertExecutionObserver(onTaskProgress: { _, _ in flag.set(true) })

        let result = RevertExecutor().revert(
            receipt: receipt,
            observer: observer,
            isCancelled: { flag.value }
        )

        XCTAssertEqual(result.revertedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: urlA.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: urlB.path),
            "Cancellation must stop the loop before the second transfer"
        )
    }

    /// Sendable wrapper so the @Sendable closures in observer + isCancelled
    /// can safely share state without triggering capture-mutation diagnostics.
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

    /// Sendable thread-safe append-only collector for observer callbacks.
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

    func testRevertHandlesEmptyTransfersList() {
        let result = RevertExecutor().revert(receipt: RevertReceipt(transfers: []))

        XCTAssertEqual(result.revertedCount, 0)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.missingCount, 0)
        XCTAssertEqual(result.totalTransfers, 0)
    }
}

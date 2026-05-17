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

    func testLoadReceiptDecodesChronoframeAuditReceiptFormat() throws {
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

    func testLoadReceiptThrowsUnreadableReceiptWhenPathIsDirectory() throws {
        let directoryURL = temporaryDirectoryURL.appendingPathComponent("receipt-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(try RevertExecutor().loadReceipt(at: directoryURL)) { error in
            guard case let RevertExecutorError.receiptUnreadable(path, reason) = error else {
                XCTFail("Expected receiptUnreadable, got \(error)")
                return
            }
            XCTAssertEqual(path, directoryURL.path)
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func testErrorDescriptionsAreUserFacing() {
        XCTAssertTrue(
            RevertExecutorError.receiptNotFound(path: "/missing").errorDescription?
                .contains("could not be found") == true
        )
        XCTAssertTrue(
            RevertExecutorError.invalidReceipt(reason: "bad json").errorDescription?
                .contains("could not read this revert receipt") == true
        )
        XCTAssertTrue(
            RevertExecutorError.receiptUnreadable(path: "/receipt.json", reason: "permission denied").errorDescription?
                .contains("could not open this revert receipt") == true
        )
    }

    // MARK: - Corrupt-receipt quarantine

    func testQuarantineRenamesCorruptReceiptStrippingJSONExtension() throws {
        let receiptURL = temporaryDirectoryURL.appendingPathComponent("audit_receipt_20260413.json")
        try Data("{not valid json".utf8).write(to: receiptURL)

        let quarantined = RevertExecutor().quarantineCorruptReceipt(at: receiptURL)

        XCTAssertNotNil(quarantined)
        XCTAssertEqual(quarantined?.lastPathComponent, "audit_receipt_20260413.corrupt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantined!.path))
        XCTAssertEqual(quarantined?.pathExtension, "corrupt")
    }

    func testQuarantinePreservesOriginalContentForDiagnostics() throws {
        let receiptURL = temporaryDirectoryURL.appendingPathComponent("audit_receipt_diag.json")
        let originalBytes = Data("{truncated...".utf8)
        try originalBytes.write(to: receiptURL)

        let quarantined = try XCTUnwrap(RevertExecutor().quarantineCorruptReceipt(at: receiptURL))

        XCTAssertEqual(try Data(contentsOf: quarantined), originalBytes)
    }

    func testQuarantineReturnsNilWhenSourceMissing() {
        let missingURL = temporaryDirectoryURL.appendingPathComponent("does_not_exist.json")
        XCTAssertNil(RevertExecutor().quarantineCorruptReceipt(at: missingURL))
    }

    // MARK: - TOCTOU: inode-mismatch safety net

    func testSafeRevertRefusesWhenDirectoryEntryIsSwappedAfterHash() throws {
        // Realistic crafted scenario: the destination file is hashed via its
        // open fd, then before unlinkat fires, an attacker (simulated by the
        // post-open race hook) replaces the directory entry by removing the
        // original and creating a new file with the same name but different
        // inode. The fd-held hash still matches the receipt, but the
        // directory entry's inode no longer matches the fd. The unlink must
        // be refused.
        let sourcePath = "/src/photo.jpg"
        let destURL = temporaryDirectoryURL.appendingPathComponent("victim.jpg")
        let originalContent = Data("original bytes that hash to a known value".utf8)
        try originalContent.write(to: destURL)

        // Compute the legitimate hash so the receipt matches the open fd.
        let receiptHash = try FileIdentityHasher().hashIdentity(at: destURL).rawValue

        var executor = RevertExecutor()
        executor._postOpenRaceHook = { _, _ in
            // Simulate a swap: delete the entry and recreate it with new
            // content (and therefore a different inode) — but the executor
            // is still holding the original fd via O_NOFOLLOW open.
            try? FileManager.default.removeItem(at: destURL)
            try? Data("imposter content".utf8).write(to: destURL)
        }

        let receipt = RevertReceipt(transfers: [
            RevertReceiptTransfer(source: sourcePath, dest: destURL.path, hash: receiptHash)
        ])
        let issues = Recorder<RunIssue>()

        let result = executor.revert(
            receipt: receipt,
            observer: RevertExecutionObserver(onIssue: { issues.append($0) })
        )

        XCTAssertEqual(result.revertedCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertTrue(
            issues.values.first?.message.contains("destination entry changed") == true,
            "Expected inode-swap refusal, got: \(issues.values.first?.message ?? "<no issue>")"
        )
        // The (swapped-in) imposter file must remain — we refused to touch it.
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))
    }

    func testSafeRevertSurfacesPosixErrorWhenEntryDisappearsBetweenHashAndUnlink() throws {
        // Hook removes the directory entry after the fd is open. The fd we
        // hashed remains valid (open(2) holds an inode reference), but the
        // subsequent `fstatat` on the basename fails with ENOENT and we
        // surface a clear warning rather than blindly issuing unlinkat.
        let destURL = temporaryDirectoryURL.appendingPathComponent("vanishing.jpg")
        let content = Data("transient content".utf8)
        try content.write(to: destURL)
        let receiptHash = try FileIdentityHasher().hashIdentity(at: destURL).rawValue

        var executor = RevertExecutor()
        executor._postOpenRaceHook = { _, _ in
            try? FileManager.default.removeItem(at: destURL)
        }

        let receipt = RevertReceipt(transfers: [
            RevertReceiptTransfer(source: "/src/v.jpg", dest: destURL.path, hash: receiptHash)
        ])
        let issues = Recorder<RunIssue>()

        let result = executor.revert(
            receipt: receipt,
            observer: RevertExecutionObserver(onIssue: { issues.append($0) })
        )

        XCTAssertEqual(result.revertedCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
        // Either the fstatat re-stat fails (ENOENT) or the inode mismatch
        // path triggers — both are correct behaviours. Assert we did NOT
        // accidentally unlink anything.
        XCTAssertFalse(FileManager.default.fileExists(atPath: destURL.path))
        XCTAssertTrue(
            (issues.values.first?.message.contains("Could not re-stat") == true) ||
            (issues.values.first?.message.contains("destination entry changed") == true),
            "Got: \(issues.values.first?.message ?? "<no issue>")"
        )
    }

    func testSafeRevertSurfacesUserFacingMessageForUnreadableDestination() throws {
        // A path that exists (passes the pre-check) but cannot be opened by
        // the current process: simulate by chmod 000. Opens with O_NOFOLLOW
        // and gets EACCES, which our safeRevert surfaces with the POSIX
        // strerror text rather than the legacy ELOOP-specific message.
        let destURL = temporaryDirectoryURL.appendingPathComponent("locked.jpg")
        try Data("locked content".utf8).write(to: destURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: destURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destURL.path)
        }

        let receipt = RevertReceipt(transfers: [
            RevertReceiptTransfer(source: "/src/locked.jpg", dest: destURL.path, hash: "anything")
        ])
        let issues = Recorder<RunIssue>()

        let result = RevertExecutor().revert(
            receipt: receipt,
            observer: RevertExecutionObserver(onIssue: { issues.append($0) })
        )

        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertTrue(
            issues.values.first?.message.contains("Could not open") == true,
            "Got: \(issues.values.first?.message ?? "<no issue>")"
        )
    }

    // AGENTS-INVARIANT: 15
    func testSafeRevertRefusesSymlinkAtDestination() throws {
        // A symlink at the destination path (rather than the regular file
        // recorded by the receipt) must be refused outright. Opening with
        // O_NOFOLLOW returns ELOOP and we surface a clear warning.
        let targetURL = temporaryDirectoryURL.appendingPathComponent("outside.jpg")
        try Data("victim outside dest".utf8).write(to: targetURL)
        let linkURL = temporaryDirectoryURL.appendingPathComponent("symlink.jpg")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        let receipt = RevertReceipt(transfers: [
            RevertReceiptTransfer(source: "/src/symlink.jpg", dest: linkURL.path, hash: "ignored")
        ])
        let issues = Recorder<RunIssue>()

        let result = RevertExecutor().revert(
            receipt: receipt,
            observer: RevertExecutionObserver(onIssue: { issues.append($0) })
        )

        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.revertedCount, 0)
        XCTAssertTrue(
            issues.values.first?.message.contains("symlink") == true,
            "Got: \(issues.values.first?.message ?? "<no issue>")"
        )
        // The symlink and its target must both be untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: linkURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetURL.path))
    }

    // MARK: - Quarantine (continued)

    func testQuarantineDisambiguatesWhenDestinationExists() throws {
        let receiptURL = temporaryDirectoryURL.appendingPathComponent("audit_receipt_dup.json")
        let collisionURL = temporaryDirectoryURL.appendingPathComponent("audit_receipt_dup.corrupt")
        try Data("{bad".utf8).write(to: receiptURL)
        try Data("previously quarantined".utf8).write(to: collisionURL)

        let quarantined = try XCTUnwrap(RevertExecutor().quarantineCorruptReceipt(at: receiptURL))

        // Existing collision is preserved, new file gets a timestamp suffix.
        XCTAssertTrue(FileManager.default.fileExists(atPath: collisionURL.path))
        XCTAssertNotEqual(quarantined.path, collisionURL.path)
        XCTAssertTrue(quarantined.lastPathComponent.hasPrefix("audit_receipt_dup.corrupt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))
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

    func testRevertSkipsWhenDestinationCannotBeHashed() throws {
        let directoryURL = temporaryDirectoryURL.appendingPathComponent("directory.jpg", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let receipt = RevertReceipt(
            transfers: [
                RevertReceiptTransfer(
                    source: "/src/directory.jpg",
                    dest: directoryURL.path,
                    hash: "10_anyhash"
                ),
            ]
        )
        let issues = Recorder<RunIssue>()

        let result = RevertExecutor().revert(
            receipt: receipt,
            observer: RevertExecutionObserver(onIssue: { issues.append($0) })
        )

        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directoryURL.path))
        // The fd-based safe revert path catches non-regular destinations
        // (directories, FIFOs, sockets) via `fstat` before attempting to hash,
        // producing a clearer message than the legacy path.
        XCTAssertTrue(
            issues.values.first?.message.contains("non-regular file") == true,
            "Got: \(issues.values.first?.message ?? "<no issue>")"
        )
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
        // 1 reverted, 1 skipped, 1 missing. Progress counts only reverted+skipped.
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

    // MARK: - Destination boundary guard

    /// Structural guard for the receipt path-traversal fix: when a
    /// destinationBoundary is supplied, paths outside it must be refused even
    /// when the hash matches.
    func testRevertRefusesPathsOutsideDestinationBoundary() throws {
        let destinationRoot = temporaryDirectoryURL.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        // File that exists outside the destination boundary.
        let outsideURL = temporaryDirectoryURL.appendingPathComponent("outside_tax_return.pdf")
        try Data("important".utf8).write(to: outsideURL)
        let outsideIdentity = try FileIdentityHasher().hashIdentity(at: outsideURL)

        let receipt = RevertReceipt(
            transfers: [
                RevertReceiptTransfer(
                    source: "/dev/null",
                    dest: outsideURL.path,
                    hash: outsideIdentity.rawValue
                )
            ]
        )

        let issues = Recorder<RunIssue>()
        let result = RevertExecutor().revert(
            receipt: receipt,
            observer: RevertExecutionObserver(onIssue: { issues.append($0) }),
            destinationBoundary: destinationRoot
        )

        XCTAssertEqual(result.revertedCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outsideURL.path),
            "File outside the destination boundary must not be deleted, even on hash match"
        )
        XCTAssertTrue(issues.values.first?.message.contains("Refusing to revert path outside destination") == true)
    }

    func testRevertWithBoundaryStillRemovesFilesInsideTheBoundary() throws {
        let destinationRoot = temporaryDirectoryURL.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationRoot.appendingPathComponent("2024/05"),
            withIntermediateDirectories: true
        )
        let insideURL = destinationRoot.appendingPathComponent("2024/05/photo.jpg")
        try Data("inside".utf8).write(to: insideURL)
        let identity = try FileIdentityHasher().hashIdentity(at: insideURL)

        let receipt = RevertReceipt(
            transfers: [
                RevertReceiptTransfer(source: "/src/photo.jpg", dest: insideURL.path, hash: identity.rawValue)
            ]
        )

        let result = RevertExecutor().revert(receipt: receipt, destinationBoundary: destinationRoot)

        XCTAssertEqual(result.revertedCount, 1)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: insideURL.path))
    }

    func testRevertRefusesSymlinkEscapedPathInsideDestinationBoundary() throws {
        let destinationRoot = temporaryDirectoryURL.appendingPathComponent("dest", isDirectory: true)
        let outsideRoot = temporaryDirectoryURL.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)

        let outsideURL = outsideRoot.appendingPathComponent("photo.jpg")
        try Data("outside".utf8).write(to: outsideURL)
        let linkURL = destinationRoot.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outsideRoot)
        let escapedReceiptPath = linkURL.appendingPathComponent("photo.jpg")
        let identity = try FileIdentityHasher().hashIdentity(at: escapedReceiptPath)

        let receipt = RevertReceipt(
            transfers: [
                RevertReceiptTransfer(source: "/src/photo.jpg", dest: escapedReceiptPath.path, hash: identity.rawValue),
            ]
        )
        let issues = Recorder<RunIssue>()

        let result = RevertExecutor().revert(
            receipt: receipt,
            observer: RevertExecutionObserver(onIssue: { issues.append($0) }),
            destinationBoundary: destinationRoot
        )

        XCTAssertEqual(result.revertedCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideURL.path))
        XCTAssertTrue(issues.values.first?.message.contains("outside destination") == true)
    }

    func testRevertWithoutBoundaryPreservesLegacyBehavior() throws {
        // When the boundary is nil (legacy/test callers), behavior is unchanged
        // — the hash check is the only guard.
        let dstURL = temporaryDirectoryURL.appendingPathComponent("legacy.jpg")
        try Data("legacy".utf8).write(to: dstURL)
        let identity = try FileIdentityHasher().hashIdentity(at: dstURL)

        let receipt = RevertReceipt(
            transfers: [
                RevertReceiptTransfer(source: "/src/legacy.jpg", dest: dstURL.path, hash: identity.rawValue)
            ]
        )

        let result = RevertExecutor().revert(receipt: receipt)

        XCTAssertEqual(result.revertedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dstURL.path))
    }

    /// Tests the TOCTOU second boundary check path.
    ///
    /// The real attack vector requires a symlink to be swapped between the first
    /// boundary check and `fileManager.removeItem` — a race that's impossible to
    /// provoke reliably in a unit test.  The `_boundaryPathResolver` seam lets us
    /// inject a resolver that returns different values on successive calls, simulating
    /// the race deterministically:
    ///   • Call 1 (pre-hash boundary check) → path appears inside boundary → proceeds
    ///   • Call 2 (post-hash TOCTOU re-check) → path appears outside boundary → skipped
    // AGENTS-INVARIANT: 8
    func testRevertPostHashBoundaryRecheckRefusesSymlinkSwappedPath() throws {
        let destinationRoot = temporaryDirectoryURL.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let insideURL = destinationRoot.appendingPathComponent("photo.jpg")
        try Data("inside".utf8).write(to: insideURL)
        let identity = try FileIdentityHasher().hashIdentity(at: insideURL)

        let receipt = RevertReceipt(
            transfers: [
                RevertReceiptTransfer(
                    source: "/src/photo.jpg",
                    dest: insideURL.path,
                    hash: identity.rawValue
                )
            ]
        )

        let boundaryPath = SafePathContainment.resolvedPath(for: destinationRoot, treatAsDirectory: true)
        let outsidePath = temporaryDirectoryURL.appendingPathComponent("outside/photo.jpg").path
        let callCount = AtomicCounter()

        var executor = RevertExecutor()
        executor._boundaryPathResolver = { _ in
            let n = callCount.increment()
            // First call: pre-hash check — return a path inside the boundary so we proceed.
            // Second call: post-hash re-check — return outside to trigger the TOCTOU guard.
            return n == 1 ? (boundaryPath + "/photo.jpg") : outsidePath
        }

        let issues = Recorder<RunIssue>()
        let result = executor.revert(
            receipt: receipt,
            observer: RevertExecutionObserver(onIssue: { issues.append($0) }),
            destinationBoundary: destinationRoot
        )

        XCTAssertEqual(result.revertedCount, 0, "File must NOT be deleted when post-hash re-check fails")
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: insideURL.path),
            "File must be preserved when the TOCTOU re-check detects boundary escape"
        )
        XCTAssertTrue(
            issues.values.first?.message.contains("post-hash re-check") == true,
            "Observer must receive the TOCTOU-specific warning message"
        )
    }

    /// Thread-safe integer counter for tracking injection call sequences in tests.
    private final class AtomicCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        /// Atomically increment and return the new value.
        func increment() -> Int {
            lock.lock(); defer { lock.unlock() }
            _count += 1
            return _count
        }
    }
}

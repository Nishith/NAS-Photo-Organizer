import Foundation

/// Applies a `DeduplicationPlan` to disk: each item is moved to Trash, while
/// a `dedupe_audit_receipt_<timestamp>_<runID>.json` is kept durable
/// next to the existing organize artifacts so the receipt surfaces in the
/// Run History tab and can be reverted.
///
/// The receipt directory is **preflighted** before any mutation. If the
/// log directory cannot be created or written to (read-only volume,
/// permission denied), the commit fails with no files touched. This
/// guarantees that every successful deletion is recorded.
public final class DeduplicateExecutor: @unchecked Sendable {
    private var cancelFlag = ManagedAtomicBool()
    private let fileOperations: DeduplicateFileOperations

    public init() {
        self.fileOperations = FileManagerDeduplicateFileOperations()
    }

    init(fileOperations: DeduplicateFileOperations) {
        self.fileOperations = fileOperations
    }

    public func cancel() {
        cancelFlag.set(true)
    }

    /// Convenience overload that builds the deletion plan from raw user
    /// decisions. Existing callers continue to use this; the UI footer
    /// uses `DeduplicationPlanner.plan` directly so its preview matches
    /// the executor exactly.
    public func commit(
        decisions: DedupeDecisions,
        clusters: [DuplicateCluster],
        configuration: DeduplicateConfiguration
    ) -> AsyncThrowingStream<DeduplicateCommitEvent, Error> {
        let plan = DeduplicationPlanner.plan(
            decisions: decisions,
            clusters: clusters,
            configuration: configuration
        )
        return commit(
            plan: plan,
            destinationRoot: configuration.destinationPath,
            hardDelete: false
        )
    }

    /// Stream the commit. Preflights the receipt directory first; aborts
    /// the entire commit if it isn't writable. Once mutation begins,
    /// every plan item produces either an `itemTrashed` or `itemFailed`
    /// event, and every successful mutation contributes a receipt entry
    /// (using its plan-attached cluster ownership — Live Photo MOV halves
    /// and other paired partners are no longer dropped).
    public func commit(
        plan: DeduplicationPlan,
        destinationRoot: String,
        hardDelete: Bool
    ) -> AsyncThrowingStream<DeduplicateCommitEvent, Error> {
        cancelFlag.set(false)
        let cancelFlag = self.cancelFlag
        let fileOperations = self.fileOperations

        return AsyncThrowingStream<DeduplicateCommitEvent, Error> { continuation in
            Task.detached {
                let logsDirectory: URL
                do {
                    logsDirectory = try Self.preflightReceiptDirectory(destinationRoot: destinationRoot)
                } catch {
                    continuation.finish(throwing: ReceiptPreflightError(underlying: error))
                    return
                }

                continuation.yield(.started(totalToDelete: plan.items.count))

                let runID = UUID()
                let startedAt = Date()
                let receiptURL: URL
                var receiptItems = plan.items.map { planItem in
                    DeduplicateAuditReceipt.Item(
                        originalPath: planItem.path,
                        sizeBytes: planItem.sizeBytes,
                        trashURL: nil,
                        method: .trash,
                        clusterID: planItem.owningClusterID,
                        clusterKind: planItem.owningClusterKind
                    )
                }
                do {
                    receiptURL = try Self.makeReceiptURL(logsDirectory: logsDirectory, runID: runID, createdAt: startedAt)
                    try Self.writeReceipt(
                        receiptURL: receiptURL,
                        runID: runID,
                        status: "PENDING",
                        createdAt: startedAt,
                        finishedAt: nil,
                        destinationRoot: destinationRoot,
                        items: receiptItems,
                        bytesReclaimed: 0,
                        abortReason: nil
                    )
                } catch {
                    continuation.finish(throwing: ReceiptPreflightError(underlying: error))
                    return
                }

                var deletedCount = 0
                var failedCount = 0
                var bytesReclaimed: Int64 = 0
                var abortReason: String?

                for (index, planItem) in plan.items.enumerated() {
                    if cancelFlag.get() {
                        abortReason = "Deduplicate was cancelled before all selected files moved to Trash."
                        break
                    }
                    let url = URL(fileURLWithPath: planItem.path)

                    do {
                        let trashURL = try fileOperations.trashItem(at: url)
                        deletedCount += 1
                        bytesReclaimed += planItem.sizeBytes
                        continuation.yield(.itemTrashed(originalPath: planItem.path, trashURL: trashURL, sizeBytes: planItem.sizeBytes))
                        receiptItems[index].trashURL = trashURL?.absoluteString
                        try Self.writeReceipt(
                            receiptURL: receiptURL,
                            runID: runID,
                            status: "PENDING",
                            createdAt: startedAt,
                            finishedAt: nil,
                            destinationRoot: destinationRoot,
                            items: receiptItems,
                            bytesReclaimed: bytesReclaimed,
                            abortReason: nil
                        )
                    } catch {
                        failedCount += 1
                        continuation.yield(.itemFailed(originalPath: planItem.path, errorMessage: error.localizedDescription))
                    }
                }

                var receiptError: Error?
                let finalStatus = abortReason == nil ? "COMPLETED" : "ABORTED"
                do {
                    try Self.writeReceipt(
                        receiptURL: receiptURL,
                        runID: runID,
                        status: finalStatus,
                        createdAt: startedAt,
                        finishedAt: Date(),
                        destinationRoot: destinationRoot,
                        items: receiptItems,
                        bytesReclaimed: bytesReclaimed,
                        abortReason: abortReason
                    )
                } catch {
                    receiptError = error
                    continuation.yield(.itemFailed(
                        originalPath: "",
                        errorMessage: "Critical: dedupe audit receipt could not be finalized. The last pending receipt remains in Run History. Details: \(error.localizedDescription)"
                    ))
                }

                continuation.yield(.complete(
                    DeduplicateCommitSummary(
                        deletedCount: deletedCount,
                        failedCount: failedCount + (receiptError == nil ? 0 : 1),
                        bytesReclaimed: bytesReclaimed,
                        receiptPath: receiptURL.path,
                        hardDelete: false
                    )
                ))
                continuation.finish()
            }
        }
    }

    /// Restore items listed in `receiptURL` from Trash back to their original
    /// paths. Items that were hard-deleted (or evicted from Trash) are
    /// reported as failures. Returns a stream of the same commit events the
    /// forward path uses, so the UI can reuse its progress surface.
    public func revert(
        receiptURL: URL,
        destinationBoundary: URL? = nil
    ) -> AsyncThrowingStream<DeduplicateCommitEvent, Error> {
        let fileOperations = self.fileOperations
        return AsyncThrowingStream<DeduplicateCommitEvent, Error> { continuation in
            Task.detached {
                do {
                    let data = try Data(contentsOf: receiptURL)
                    let receipt = try JSONDecoder.dedupe.decode(DeduplicateAuditReceipt.self, from: data)
                    guard receipt.kind == "dedupe" || receipt.operation == "deduplicate" else {
                        throw DeduplicateReceiptValidationError.invalidKind
                    }
                    guard ["PENDING", "COMPLETED", "ABORTED", "FAILED"].contains(receipt.status) else {
                        throw DeduplicateReceiptValidationError.invalidStatus(receipt.status)
                    }
                    continuation.yield(.started(totalToDelete: receipt.items.count))

                    let boundaryURL = destinationBoundary
                        ?? Self.inferredDestinationBoundary(for: receiptURL)
                        ?? URL(fileURLWithPath: receipt.destinationRoot, isDirectory: true)
                    var deletedCount = 0
                    var failedCount = 0
                    var bytesReclaimed: Int64 = 0

                    for item in receipt.items {
                        if item.method == .hardDelete {
                            failedCount += 1
                            continuation.yield(.itemFailed(originalPath: item.originalPath, errorMessage: "Hard-deleted items cannot be restored."))
                            continue
                        }
                        guard let trashURLString = item.trashURL, let trashURL = URL(string: trashURLString) else {
                            failedCount += 1
                            continuation.yield(.itemFailed(originalPath: item.originalPath, errorMessage: "Receipt is missing the Trash URL for this item."))
                            continue
                        }
                        let originalURL = URL(fileURLWithPath: item.originalPath)
                        guard SafePathContainment.isContained(
                            originalURL,
                            in: boundaryURL
                        ) else {
                            failedCount += 1
                            continuation.yield(.itemFailed(originalPath: item.originalPath, errorMessage: "Receipt path is outside the dedupe destination."))
                            continue
                        }
                        if FileManager.default.fileExists(atPath: originalURL.path) {
                            failedCount += 1
                            continuation.yield(.itemFailed(originalPath: item.originalPath, errorMessage: "Original path already exists. Chronoframe left it untouched."))
                            continue
                        }
                        do {
                            try fileOperations.createDirectory(
                                at: originalURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true
                            )
                            try fileOperations.moveItem(at: trashURL, to: originalURL)
                            deletedCount += 1
                            bytesReclaimed += item.sizeBytes
                            continuation.yield(.itemTrashed(originalPath: item.originalPath, trashURL: trashURL, sizeBytes: item.sizeBytes))
                        } catch {
                            failedCount += 1
                            continuation.yield(.itemFailed(originalPath: item.originalPath, errorMessage: error.localizedDescription))
                        }
                    }

                    continuation.yield(.complete(
                        DeduplicateCommitSummary(
                            deletedCount: deletedCount,
                            failedCount: failedCount,
                            bytesReclaimed: bytesReclaimed,
                            receiptPath: receiptURL.path,
                            hardDelete: false
                        )
                    ))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Helpers

    /// Verify the receipt directory exists and is writable BEFORE we
    /// touch any user file. Probes by writing + removing a tiny file.
    static func preflightReceiptDirectory(destinationRoot: String) throws -> URL {
        let logsDirectory = URL(fileURLWithPath: destinationRoot).appendingPathComponent(".organize_logs")
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let probe = logsDirectory.appendingPathComponent(".dedupe_preflight_\(UUID().uuidString)")
        try Data().write(to: probe)
        try FileManager.default.removeItem(at: probe)
        return logsDirectory
    }

    static func inferredDestinationBoundary(for receiptURL: URL) -> URL? {
        let logsDirectory = receiptURL.deletingLastPathComponent()
        guard logsDirectory.lastPathComponent == ".organize_logs" else { return nil }
        return logsDirectory.deletingLastPathComponent()
    }

    static func makeReceiptURL(
        logsDirectory: URL,
        runID: UUID,
        createdAt: Date
    ) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: createdAt)
        return logsDirectory.appendingPathComponent("dedupe_audit_receipt_\(timestamp)_\(runID.uuidString).json")
    }

    static func writeReceipt(
        receiptURL: URL,
        runID: UUID,
        status: String,
        createdAt: Date,
        finishedAt: Date?,
        destinationRoot: String,
        items: [DeduplicateAuditReceipt.Item],
        bytesReclaimed: Int64,
        abortReason: String?
    ) throws {
        let receipt = DeduplicateAuditReceipt(
            runID: runID,
            status: status,
            createdAt: createdAt,
            finishedAt: finishedAt,
            destinationRoot: destinationRoot,
            items: items,
            bytesReclaimed: bytesReclaimed,
            abortReason: abortReason
        )
        let data = try JSONEncoder.dedupe.encode(receipt)
        try data.write(to: receiptURL, options: .atomic)
    }
}

public enum DeduplicateReceiptValidationError: LocalizedError, Equatable {
    case invalidKind
    case invalidStatus(String)

    public var errorDescription: String? {
        switch self {
        case .invalidKind:
            return "This receipt is not a deduplicate receipt."
        case let .invalidStatus(status):
            return "This deduplicate receipt has an unknown status: \(status)."
        }
    }
}

protocol DeduplicateFileOperations: Sendable {
    func removeItem(at url: URL) throws
    func trashItem(at url: URL) throws -> URL?
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool) throws
}

private struct FileManagerDeduplicateFileOperations: DeduplicateFileOperations {
    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func trashItem(at url: URL) throws -> URL? {
        var trashURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashURL)
        return trashURL as URL?
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }

    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: createIntermediates)
    }
}

/// Thrown from `commit` when the receipt directory is not usable. The
/// commit stream finishes with this error before any file is mutated, so
/// the caller can surface it as "deduplicate could not start" rather than
/// "some files were deleted but the audit failed".
public struct ReceiptPreflightError: LocalizedError {
    public let underlying: Error

    public var errorDescription: String? {
        "Chronoframe cannot write the dedupe audit receipt to this destination, so the deduplicate run was aborted before any files changed. Ensure the destination volume is writable and try again. Details: \(underlying.localizedDescription)"
    }
}

extension JSONEncoder {
    static let dedupe: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let dedupe: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

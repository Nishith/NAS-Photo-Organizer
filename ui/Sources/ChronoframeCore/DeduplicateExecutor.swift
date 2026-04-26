import Foundation

/// Applies a `DeduplicationPlan` to disk: each item is moved to Trash or
/// hard-deleted, then a `dedupe_audit_receipt_<timestamp>.json` is written
/// next to the existing organize artifacts so the receipt surfaces in the
/// Run History tab and can be reverted.
///
/// The receipt directory is **preflighted** before any mutation. If the
/// log directory cannot be created or written to (read-only volume,
/// permission denied), the commit fails with no files touched. This
/// guarantees that every successful deletion is recorded.
public final class DeduplicateExecutor: @unchecked Sendable {
    private var cancelFlag = ManagedAtomicBool()

    public init() {}

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
            hardDelete: decisions.hardDelete
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

        return AsyncThrowingStream { continuation in
            Task.detached {
                let logsDirectory: URL
                do {
                    logsDirectory = try Self.preflightReceiptDirectory(destinationRoot: destinationRoot)
                } catch {
                    continuation.finish(throwing: ReceiptPreflightError(underlying: error))
                    return
                }

                continuation.yield(.started(totalToDelete: plan.items.count))

                var receiptItems: [DeduplicateAuditReceipt.Item] = []
                var deletedCount = 0
                var failedCount = 0
                var bytesReclaimed: Int64 = 0

                for planItem in plan.items {
                    if cancelFlag.get() { break }
                    let url = URL(fileURLWithPath: planItem.path)

                    if hardDelete {
                        do {
                            try FileManager.default.removeItem(at: url)
                            deletedCount += 1
                            bytesReclaimed += planItem.sizeBytes
                            continuation.yield(.itemTrashed(originalPath: planItem.path, trashURL: nil, sizeBytes: planItem.sizeBytes))
                            receiptItems.append(
                                DeduplicateAuditReceipt.Item(
                                    originalPath: planItem.path,
                                    sizeBytes: planItem.sizeBytes,
                                    trashURL: nil,
                                    method: .hardDelete,
                                    clusterID: planItem.owningClusterID,
                                    clusterKind: planItem.owningClusterKind
                                )
                            )
                        } catch {
                            failedCount += 1
                            continuation.yield(.itemFailed(originalPath: planItem.path, errorMessage: error.localizedDescription))
                        }
                    } else {
                        var trashURL: NSURL?
                        do {
                            try FileManager.default.trashItem(at: url, resultingItemURL: &trashURL)
                            deletedCount += 1
                            bytesReclaimed += planItem.sizeBytes
                            continuation.yield(.itemTrashed(originalPath: planItem.path, trashURL: trashURL as URL?, sizeBytes: planItem.sizeBytes))
                            receiptItems.append(
                                DeduplicateAuditReceipt.Item(
                                    originalPath: planItem.path,
                                    sizeBytes: planItem.sizeBytes,
                                    trashURL: (trashURL as URL?)?.absoluteString,
                                    method: .trash,
                                    clusterID: planItem.owningClusterID,
                                    clusterKind: planItem.owningClusterKind
                                )
                            )
                        } catch {
                            failedCount += 1
                            continuation.yield(.itemFailed(originalPath: planItem.path, errorMessage: error.localizedDescription))
                        }
                    }
                }

                // Write the receipt. Files are already mutated by this
                // point, so a failure here is a critical issue: we lose
                // the app-level revert trail (and, for hard-delete, the
                // audit record itself). Surface it loudly and tag the
                // summary so the UI can warn the user.
                var receiptPath: String?
                var receiptError: Error?
                if !receiptItems.isEmpty {
                    do {
                        receiptPath = try Self.writeReceipt(
                            logsDirectory: logsDirectory,
                            destinationRoot: destinationRoot,
                            items: receiptItems,
                            bytesReclaimed: bytesReclaimed
                        )
                    } catch {
                        receiptError = error
                        let prefix = hardDelete
                            ? "Critical: dedupe audit receipt could not be written. Files were already deleted and cannot be revert-restored."
                            : "Critical: dedupe audit receipt could not be written. Files are in the Trash but Run History will not show this run for revert."
                        continuation.yield(.itemFailed(
                            originalPath: "",
                            errorMessage: "\(prefix) Details: \(error.localizedDescription)"
                        ))
                    }
                }

                continuation.yield(.complete(
                    DeduplicateCommitSummary(
                        deletedCount: deletedCount,
                        failedCount: failedCount + (receiptError == nil ? 0 : 1),
                        bytesReclaimed: bytesReclaimed,
                        receiptPath: receiptPath,
                        hardDelete: hardDelete
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
    public func revert(receiptURL: URL) -> AsyncThrowingStream<DeduplicateCommitEvent, Error> {
        AsyncThrowingStream { continuation in
            Task.detached {
                do {
                    let data = try Data(contentsOf: receiptURL)
                    let receipt = try JSONDecoder.dedupe.decode(DeduplicateAuditReceipt.self, from: data)
                    continuation.yield(.started(totalToDelete: receipt.items.count))

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
                        do {
                            try FileManager.default.createDirectory(
                                at: originalURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true
                            )
                            try FileManager.default.moveItem(at: trashURL, to: originalURL)
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

    static func writeReceipt(
        logsDirectory: URL,
        destinationRoot: String,
        items: [DeduplicateAuditReceipt.Item],
        bytesReclaimed: Int64
    ) throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())

        let receiptURL = logsDirectory.appendingPathComponent("dedupe_audit_receipt_\(timestamp).json")
        let receipt = DeduplicateAuditReceipt(
            createdAt: Date(),
            destinationRoot: destinationRoot,
            items: items,
            bytesReclaimed: bytesReclaimed
        )
        let data = try JSONEncoder.dedupe.encode(receipt)
        try data.write(to: receiptURL, options: .atomic)
        return receiptURL.path
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

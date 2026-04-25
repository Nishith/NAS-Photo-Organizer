import Foundation

/// Applies a `DedupeDecisions` map to disk: each path marked `.delete` is
/// either moved to Trash or hard-deleted, depending on the decisions flag.
/// Writes a `dedupe_audit_receipt_<timestamp>.json` next to the existing
/// organize artifacts so the receipt surfaces in the Run History tab and
/// can be reverted (Trash items only).
public final class DeduplicateExecutor: @unchecked Sendable {
    private var cancelFlag = ManagedAtomicBool()

    public init() {}

    public func cancel() {
        cancelFlag.set(true)
    }

    /// Stream the commit. The caller funnels events into the UI's progress
    /// surface and writes the audit receipt once `complete` arrives.
    public func commit(
        decisions: DedupeDecisions,
        clusters: [DuplicateCluster],
        configuration: DeduplicateConfiguration
    ) -> AsyncThrowingStream<DeduplicateCommitEvent, Error> {
        cancelFlag.set(false)
        let cancelFlag = self.cancelFlag

        return AsyncThrowingStream { continuation in
            Task.detached {
                let toDelete = Self.expandedDeletePaths(decisions: decisions, clusters: clusters, configuration: configuration)
                continuation.yield(.started(totalToDelete: toDelete.count))

                let clusterByPath = Self.clusterIndex(clusters)
                var receiptItems: [DeduplicateAuditReceipt.Item] = []
                var deletedCount = 0
                var failedCount = 0
                var bytesReclaimed: Int64 = 0

                for path in toDelete {
                    if cancelFlag.get() { break }
                    let url = URL(fileURLWithPath: path)
                    let attributes = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
                    let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0

                    if decisions.hardDelete {
                        do {
                            try FileManager.default.removeItem(at: url)
                            deletedCount += 1
                            bytesReclaimed += size
                            continuation.yield(.itemTrashed(originalPath: path, trashURL: nil, sizeBytes: size))
                            if let cluster = clusterByPath[path] {
                                receiptItems.append(
                                    DeduplicateAuditReceipt.Item(
                                        originalPath: path,
                                        sizeBytes: size,
                                        trashURL: nil,
                                        method: .hardDelete,
                                        clusterID: cluster.id,
                                        clusterKind: cluster.kind
                                    )
                                )
                            }
                        } catch {
                            failedCount += 1
                            continuation.yield(.itemFailed(originalPath: path, errorMessage: error.localizedDescription))
                        }
                    } else {
                        var trashURL: NSURL?
                        do {
                            try FileManager.default.trashItem(at: url, resultingItemURL: &trashURL)
                            deletedCount += 1
                            bytesReclaimed += size
                            continuation.yield(.itemTrashed(originalPath: path, trashURL: trashURL as URL?, sizeBytes: size))
                            if let cluster = clusterByPath[path] {
                                receiptItems.append(
                                    DeduplicateAuditReceipt.Item(
                                        originalPath: path,
                                        sizeBytes: size,
                                        trashURL: (trashURL as URL?)?.absoluteString,
                                        method: .trash,
                                        clusterID: cluster.id,
                                        clusterKind: cluster.kind
                                    )
                                )
                            }
                        } catch {
                            failedCount += 1
                            continuation.yield(.itemFailed(originalPath: path, errorMessage: error.localizedDescription))
                        }
                    }
                }

                var receiptPath: String?
                if !receiptItems.isEmpty {
                    do {
                        receiptPath = try Self.writeReceipt(
                            destinationRoot: configuration.destinationPath,
                            items: receiptItems,
                            bytesReclaimed: bytesReclaimed
                        )
                    } catch {
                        // Receipt write failure shouldn't fail the commit;
                        // the user just won't see this run in History.
                        continuation.yield(.itemFailed(originalPath: "", errorMessage: "Could not write dedupe audit receipt: \(error.localizedDescription)"))
                    }
                }

                continuation.yield(.complete(
                    DeduplicateCommitSummary(
                        deletedCount: deletedCount,
                        failedCount: failedCount,
                        bytesReclaimed: bytesReclaimed,
                        receiptPath: receiptPath,
                        hardDelete: decisions.hardDelete
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

    /// Expand the user's keep/delete map into the actual list of paths to
    /// delete, honoring pair locks: if a JPEG is marked Delete and its
    /// RAW partner exists in the cluster, the partner is implicitly
    /// deleted too (and vice versa) when the configuration says pairs
    /// move as a unit. Order is path-sorted for deterministic test output.
    static func expandedDeletePaths(
        decisions: DedupeDecisions,
        clusters: [DuplicateCluster],
        configuration: DeduplicateConfiguration
    ) -> [String] {
        var toDelete: Set<String> = []

        let pairs = configuration.treatRawJpegPairsAsUnit || configuration.treatLivePhotoPairsAsUnit
        let allMembers = clusters.flatMap { $0.members }
        let memberByPath = Dictionary(uniqueKeysWithValues: allMembers.map { ($0.path, $0) })

        for cluster in clusters {
            // Safety rail: never delete every member of a cluster.
            let perMember: [(path: String, decision: DedupeDecision)] = cluster.members.map { member in
                let decision = decisions.decision(for: member.path) ?? (cluster.suggestedKeeperIDs.contains(member.id) ? .keep : .delete)
                return (member.path, decision)
            }
            let allDelete = perMember.allSatisfy { $0.decision == .delete }
            if allDelete { continue }

            for (path, decision) in perMember where decision == .delete {
                toDelete.insert(path)
                if pairs, let partner = memberByPath[path]?.pairedPath {
                    toDelete.insert(partner)
                }
            }
        }
        return toDelete.sorted()
    }

    static func clusterIndex(_ clusters: [DuplicateCluster]) -> [String: DuplicateCluster] {
        var index: [String: DuplicateCluster] = [:]
        for cluster in clusters {
            for member in cluster.members {
                index[member.path] = cluster
            }
        }
        return index
    }

    static func writeReceipt(
        destinationRoot: String,
        items: [DeduplicateAuditReceipt.Item],
        bytesReclaimed: Int64
    ) throws -> String {
        let logsDirectory = URL(fileURLWithPath: destinationRoot).appendingPathComponent(".organize_logs")
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

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

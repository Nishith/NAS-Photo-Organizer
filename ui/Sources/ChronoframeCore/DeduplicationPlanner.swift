import Foundation

/// Single source of truth for "what files will the executor mutate, given
/// these decisions and clusters?". Used by both the commit footer (preview
/// counts) and the executor (so the audit receipt is exhaustive).
///
/// Resolution order:
///
/// 1. Compute each cluster member's effective decision (explicit user
///    decision, or fall back to the cluster's suggested keepers).
/// 2. Pair-as-unit conflict resolution (Keep wins). For each paired pair
///    whose `kind` toggle is enabled, if either side has effective Keep
///    the other side is forced to Keep too. This stops the previous bug
///    where an explicit Keep on one half got silently overridden by a
///    Delete on the other half.
/// 3. Per-cluster safety rail: skip any cluster whose effective decisions
///    are all Delete after step 2 (never empty a cluster).
/// 4. Emit Items for direct cluster-member Deletes, with cluster ownership.
/// 5. Pair expansion for partners outside any cluster (Live Photo MOV
///    halves, mainly). Each toggle is honored independently — disabling
///    RAW pairing no longer accidentally leaves Live Photo pairing's
///    expansion untouched, and vice versa. Partner inherits its
///    triggering member's cluster ownership so the receipt is complete.
public enum DeduplicationPlanner {
    public static func plan(
        decisions: DedupeDecisions,
        clusters: [DuplicateCluster],
        configuration: DeduplicateConfiguration
    ) -> DeduplicationPlan {
        // 1. Effective decision per cluster member.
        struct Effective {
            var decision: DedupeDecision
            var source: DecisionSource
            let cluster: DuplicateCluster
            let member: PhotoCandidate
        }
        enum DecisionSource {
            case explicit
            case automatic
            case defaultKeep
        }
        var effective: [String: Effective] = [:]
        for cluster in clusters {
            let suggestedKeepers = Set(cluster.suggestedKeeperIDs.prefix(1))
            let canAutoSelectDeletes = isAutomaticCommitEligible(cluster)
            for member in cluster.members {
                let explicitDecision = decisions.decision(for: member.path)
                let decision = explicitDecision
                    ?? (canAutoSelectDeletes
                        ? (suggestedKeepers.contains(member.id) ? .keep : .delete)
                        : .keep)
                let source: DecisionSource = if explicitDecision != nil {
                    .explicit
                } else if canAutoSelectDeletes {
                    .automatic
                } else {
                    .defaultKeep
                }
                effective[member.path] = Effective(
                    decision: decision,
                    source: source,
                    cluster: cluster,
                    member: member
                )
            }
        }

        // 2. Pair-as-unit conflict resolution: Keep wins regardless of
        // *why* a member ended up Keep. Whether the Keep is explicit,
        // automatic (high-confidence keeper), or implicit (low/medium-
        // confidence cluster with no auto-deletes), pairing it with a
        // Delete partner flips the Delete back to Keep. This restores
        // the AGENTS.md safety invariant in the case where a user marks
        // one half of a pair Delete and the other half is sitting at
        // default-Keep — the UI shows both as Keep, the user expects
        // both to survive, and pair-fanout would otherwise silently
        // delete the unmarked partner. Iterate over a snapshot of the
        // keys because we mutate the map.
        for path in Array(effective.keys) {
            guard let info = effective[path], let partner = info.member.pairedPath else { continue }
            let kind = pairKind(for: info.member)
            if !pairKindEnabled(kind, in: configuration) { continue }
            guard let partnerInfo = effective[partner] else { continue }
            switch (info.decision, partnerInfo.decision) {
            case (.keep, .delete):
                effective[partner]?.decision = .keep
            case (.delete, .keep):
                effective[path]?.decision = .keep
            default:
                break
            }
        }

        // 3. Per-cluster safety rail.
        var skipped: Set<UUID> = []
        for cluster in clusters {
            let allDelete = cluster.members.allSatisfy {
                effective[$0.path]?.decision == .delete
            }
            if allDelete { skipped.insert(cluster.id) }
        }

        // 4. Direct deletes (cluster members marked Delete).
        var planItems: [String: DeduplicationPlan.Item] = [:]
        for cluster in clusters where !skipped.contains(cluster.id) {
            for member in cluster.members {
                guard effective[member.path]?.decision == .delete else { continue }
                planItems[member.path] = DeduplicationPlan.Item(
                    path: member.path,
                    sizeBytes: member.size,
                    owningClusterID: cluster.id,
                    owningClusterKind: cluster.kind,
                    pairOrigin: nil
                )
            }
        }

        // 5. Pair expansion for partners that may not be cluster members.
        for cluster in clusters where !skipped.contains(cluster.id) {
            for member in cluster.members {
                guard let owningItem = planItems[member.path], owningItem.pairOrigin == nil else { continue }
                guard let partner = member.pairedPath else { continue }
                let kind = pairKind(for: member)
                if !pairKindEnabled(kind, in: configuration) { continue }
                // If the partner is a cluster member with effective Keep,
                // step 2 already neutralised this conflict. Defensive
                // belt-and-braces check that also closes the order-of-
                // operations gap where step 3's safety rail ran before
                // step 5's pair fanout and so couldn't catch the
                // cluster-empty case.
                if effective[partner]?.decision == .keep {
                    continue
                }
                // Explicit per-pair Keep override. Lets the user preserve a
                // singleton partner (typically the Live Photo MOV half) that
                // isn't a cluster member and therefore has no slot in the
                // `effective` decision map for step 2 to act on.
                if decisions.pairKeepOverrides.contains(partner) {
                    continue
                }
                if planItems[partner] != nil { continue }
                let partnerSize = effective[partner]?.member.size ?? fileSize(at: partner)
                planItems[partner] = DeduplicationPlan.Item(
                    path: partner,
                    sizeBytes: partnerSize,
                    owningClusterID: owningItem.owningClusterID,
                    owningClusterKind: owningItem.owningClusterKind,
                    pairOrigin: kind == .livePhoto ? .livePhoto : .rawJpeg
                )
            }
        }

        return DeduplicationPlan(items: planItems.values.sorted { $0.path < $1.path })
    }

    public static func suggestedDecisions(
        for clusters: [DuplicateCluster],
        configuration: DeduplicateConfiguration,
        hardDelete: Bool = false
    ) -> DedupeDecisions {
        var byPath: [String: DedupeDecision] = [:]
        for cluster in clusters {
            let keepers = Set(cluster.suggestedKeeperIDs.prefix(1))
            for member in cluster.members {
                byPath[member.path] = keepers.contains(member.id) ? .keep : .delete
            }
        }
        applyPairKeepWins(to: &byPath, clusters: clusters, configuration: configuration)
        return DedupeDecisions(byPath: byPath, hardDelete: false)
    }

    public static func automaticDecisions(
        for clusters: [DuplicateCluster],
        configuration: DeduplicateConfiguration
    ) -> DedupeDecisions {
        suggestedDecisions(
            for: clusters.filter(isAutomaticCommitEligible),
            configuration: configuration,
            hardDelete: false
        )
    }

    // MARK: - Helpers

    public static func isAutomaticCommitEligible(_ cluster: DuplicateCluster) -> Bool {
        let confidence = cluster.annotation?.confidence ?? .medium
        return confidence == .high
    }

    static func applyPairKeepWins(
        to decisions: inout [String: DedupeDecision],
        clusters: [DuplicateCluster],
        configuration: DeduplicateConfiguration
    ) {
        for cluster in clusters {
            for member in cluster.members {
                guard let partner = member.pairedPath else { continue }
                guard decisions[member.path] != nil, decisions[partner] != nil else { continue }
                let kind = pairKind(for: member)
                if !pairKindEnabled(kind, in: configuration) { continue }
                if decisions[member.path] == .keep || decisions[partner] == .keep {
                    decisions[member.path] = .keep
                    decisions[partner] = .keep
                }
            }
        }
    }

    static func pairKind(for member: PhotoCandidate) -> DeduplicatePairDetector.Pair.Kind {
        if member.isLivePhotoStill { return .livePhoto }
        if let partner = member.pairedPath {
            let ext = MediaLibraryRules.normalizedExtension(for: partner)
            if ext == ".mov" || ext == ".m4v" { return .livePhoto }
        }
        return .rawJpeg
    }

    static func pairKindEnabled(
        _ kind: DeduplicatePairDetector.Pair.Kind,
        in configuration: DeduplicateConfiguration
    ) -> Bool {
        switch kind {
        case .rawJpeg: return configuration.treatRawJpegPairsAsUnit
        case .livePhoto: return configuration.treatLivePhotoPairsAsUnit
        }
    }

    static func fileSize(at path: String) -> Int64 {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }
}

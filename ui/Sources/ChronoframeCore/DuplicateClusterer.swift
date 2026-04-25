import Foundation

/// Time-windowed similarity clusterer. Sorts candidates by capture date and
/// considers each pair within `±timeWindowSeconds`. A pair is "similar" if
/// the dHash Hamming distance is within the threshold AND the Vision
/// feature-print distance is within the threshold. Connected components
/// (union-find) become clusters. Singletons are dropped.
public enum DuplicateClusterer {
    /// Pluggable distance comparator so tests can supply a deterministic
    /// stand-in for Vision (which would otherwise need real image data).
    public typealias FeaturePrintDistance = @Sendable (Data, Data) -> Double?

    public static func cluster(
        candidates: [PhotoCandidate],
        configuration: DeduplicateConfiguration,
        burstWindowSeconds: Int = 10,
        featurePrintDistance: FeaturePrintDistance = defaultFeaturePrintDistance
    ) -> [DuplicateCluster] {
        // Pair members are committed alongside their primary, so we cluster
        // only on primaries (those with no partner OR who are listed first
        // in their pair). We attach the secondary back when emitting.
        let primaries = candidates.filter { candidate in
            guard let partner = candidate.pairedPath else { return true }
            return candidate.path < partner
        }
        let candidatesByPath = Dictionary(uniqueKeysWithValues: candidates.map { ($0.path, $0) })

        let sorted = primaries.sorted { lhs, rhs in
            (lhs.captureDate ?? .distantPast) < (rhs.captureDate ?? .distantPast)
        }
        guard sorted.count > 1 else { return [] }

        var unionFind = UnionFind(count: sorted.count)
        let timeWindow = TimeInterval(configuration.timeWindowSeconds)

        for i in 0..<sorted.count {
            let lhs = sorted[i]
            guard let lhsDate = lhs.captureDate, let lhsHash = lhs.dhash else { continue }
            for j in (i + 1)..<sorted.count {
                let rhs = sorted[j]
                guard let rhsDate = rhs.captureDate else { break }
                if rhsDate.timeIntervalSince(lhsDate) > timeWindow { break }
                guard let rhsHash = rhs.dhash else { continue }

                if PerceptualHash.hammingDistance(lhsHash, rhsHash) > configuration.dhashHammingThreshold {
                    continue
                }

                guard let lhsPrint = lhs.featurePrintData, let rhsPrint = rhs.featurePrintData else {
                    // Without Vision data we keep the dHash match; this lets
                    // tests run without exercising Vision and gives a sane
                    // fallback if a feature print failed to compute.
                    unionFind.union(i, j)
                    continue
                }
                guard let distance = featurePrintDistance(lhsPrint, rhsPrint) else { continue }
                if distance <= configuration.similarityThreshold {
                    unionFind.union(i, j)
                }
            }
        }

        // Group by component root.
        var componentMembers: [Int: [Int]] = [:]
        for index in 0..<sorted.count {
            let root = unionFind.find(index)
            componentMembers[root, default: []].append(index)
        }

        var clusters: [DuplicateCluster] = []
        for (_, indices) in componentMembers where indices.count > 1 {
            var members: [PhotoCandidate] = []
            for index in indices {
                let primary = sorted[index]
                members.append(primary)
                if let partnerPath = primary.pairedPath, let partner = candidatesByPath[partnerPath] {
                    members.append(partner)
                }
            }
            let kind = clusterKind(for: members, burstWindowSeconds: burstWindowSeconds)
            let suggested = suggestKeeperIDs(for: members)
            let bytes = bytesIfPruned(members: members, keeperIDs: Set(suggested))
            clusters.append(
                DuplicateCluster(
                    kind: kind,
                    members: members.sorted { ($0.captureDate ?? .distantPast) < ($1.captureDate ?? .distantPast) },
                    suggestedKeeperIDs: suggested,
                    bytesIfPruned: bytes
                )
            )
        }

        return clusters.sorted { ($0.members.first?.captureDate ?? .distantPast) < ($1.members.first?.captureDate ?? .distantPast) }
    }

    /// Build clusters for byte-identical files using the existing file
    /// identity (size + BLAKE2b digest). Each group of more than one path
    /// that shares a `FileIdentity` becomes one `exactDuplicate` cluster.
    public static func exactDuplicateClusters(
        candidatesByIdentity: [FileIdentity: [PhotoCandidate]]
    ) -> [DuplicateCluster] {
        candidatesByIdentity.values.compactMap { members -> DuplicateCluster? in
            guard members.count > 1 else { return nil }
            let suggested = suggestKeeperIDs(for: members)
            return DuplicateCluster(
                kind: .exactDuplicate,
                members: members.sorted { $0.path < $1.path },
                suggestedKeeperIDs: suggested,
                bytesIfPruned: bytesIfPruned(members: members, keeperIDs: Set(suggested))
            )
        }
    }

    static func clusterKind(for members: [PhotoCandidate], burstWindowSeconds: Int) -> ClusterKind {
        let dates = members.compactMap { $0.captureDate }
        guard let first = dates.min(), let last = dates.max() else { return .nearDuplicate }
        return last.timeIntervalSince(first) <= TimeInterval(burstWindowSeconds) ? .burst : .nearDuplicate
    }

    static func suggestKeeperIDs(for members: [PhotoCandidate]) -> [String] {
        guard let best = members.max(by: { $0.qualityScore < $1.qualityScore }) else { return [] }
        let epsilon = 0.02
        return members
            .filter { abs($0.qualityScore - best.qualityScore) <= epsilon }
            .map(\.id)
    }

    static func bytesIfPruned(members: [PhotoCandidate], keeperIDs: Set<String>) -> Int64 {
        members.filter { !keeperIDs.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    public static let defaultFeaturePrintDistance: FeaturePrintDistance = { @Sendable lhs, rhs in
        try? VisionFeaturePrinter.distance(lhs, rhs)
    }
}

/// Compact union-find with path compression + union-by-rank.
private struct UnionFind {
    private var parent: [Int]
    private var rank: [Int]

    init(count: Int) {
        parent = Array(0..<count)
        rank = Array(repeating: 0, count: count)
    }

    mutating func find(_ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        var current = x
        while parent[current] != root {
            let next = parent[current]
            parent[current] = root
            current = next
        }
        return root
    }

    mutating func union(_ a: Int, _ b: Int) {
        let rootA = find(a)
        let rootB = find(b)
        guard rootA != rootB else { return }
        if rank[rootA] < rank[rootB] {
            parent[rootA] = rootB
        } else if rank[rootA] > rank[rootB] {
            parent[rootB] = rootA
        } else {
            parent[rootB] = rootA
            rank[rootA] += 1
        }
    }
}

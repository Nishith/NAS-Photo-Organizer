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
    public typealias FeaturePrintDataProvider = @Sendable (String) -> Data?

    public static func cluster(
        candidates: [PhotoCandidate],
        configuration: DeduplicateConfiguration,
        burstWindowSeconds: Int = 10,
        featurePrintDistance: FeaturePrintDistance? = nil,
        featurePrintDataProvider: FeaturePrintDataProvider? = nil
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
        let burstMode = configuration.burstModeEnabled
        let timeWindow = TimeInterval(configuration.timeWindowSeconds)
        let defaultDistanceCache = VisionFeaturePrintDistanceCache()
        let featurePrintCache = FeaturePrintDataCache(provider: featurePrintDataProvider)

        // Capture pairwise distances for annotation (Feature 7).
        var pairwiseMatches: [PairwiseMatch] = []

        for i in 0..<sorted.count {
            let lhs = sorted[i]
            guard let lhsHash = lhs.dhash else { continue }
            if burstMode, lhs.captureDate == nil { continue }
            for j in (i + 1)..<sorted.count {
                let rhs = sorted[j]

                var timeDelta: TimeInterval?
                if let lhsDate = lhs.captureDate, let rhsDate = rhs.captureDate {
                    timeDelta = rhsDate.timeIntervalSince(lhsDate)
                }

                if burstMode, let td = timeDelta, td > timeWindow {
                    break
                }
                guard let rhsHash = rhs.dhash else { continue }

                let hammingDist = PerceptualHash.hammingDistance(lhsHash, rhsHash)
                if hammingDist > configuration.dhashHammingThreshold {
                    continue
                }

                guard
                    let lhsPrint = featurePrintData(for: lhs, cache: featurePrintCache),
                    let rhsPrint = featurePrintData(for: rhs, cache: featurePrintCache)
                else {
                    // dHash is only a cheap candidate filter. If Vision data
                    // is unavailable, do not create a mutable duplicate
                    // cluster from dHash alone.
                    continue
                }
                let distance = featurePrintDistance?(lhsPrint, rhsPrint)
                    ?? defaultDistanceCache.distance(
                        lhsPath: lhs.path,
                        lhsData: lhsPrint,
                        rhsPath: rhs.path,
                        rhsData: rhsPrint
                    )
                guard let distance else { continue }
                if distance <= configuration.similarityThreshold {
                    unionFind.union(i, j)
                    pairwiseMatches.append(PairwiseMatch(
                        lhsPath: lhs.path, rhsPath: rhs.path,
                        visionDistance: distance, dhashDistance: hammingDist,
                        timeDeltaSeconds: timeDelta
                    ))
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
            var cluster = DuplicateCluster(
                kind: kind,
                members: members.sorted { ($0.captureDate ?? .distantPast) < ($1.captureDate ?? .distantPast) },
                suggestedKeeperIDs: suggested,
                bytesIfPruned: bytes
            )
            cluster.annotation = ClusterAnnotator.annotate(
                cluster: cluster,
                pairwiseMatches: pairwiseMatches,
                configuration: configuration
            )
            clusters.append(cluster)
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
            var cluster = DuplicateCluster(
                kind: .exactDuplicate,
                members: members.sorted { $0.path < $1.path },
                suggestedKeeperIDs: suggested,
                bytesIfPruned: bytesIfPruned(members: members, keeperIDs: Set(suggested))
            )
            cluster.annotation = ClusterAnnotation(
                confidence: .high,
                matchReason: MatchReason(kind: .exactDuplicate),
                keeperReason: ClusterAnnotator.buildKeeperReason(cluster: cluster)
            )
            return cluster
        }
    }

    static func clusterKind(for members: [PhotoCandidate], burstWindowSeconds: Int) -> ClusterKind {
        let dates = members.compactMap { $0.captureDate }
        guard let first = dates.min(), let last = dates.max() else { return .nearDuplicate }
        return last.timeIntervalSince(first) <= TimeInterval(burstWindowSeconds) ? .burst : .nearDuplicate
    }

    static func suggestKeeperIDs(for members: [PhotoCandidate]) -> [String] {
        guard let best = members.sorted(by: isPreferredKeeper).first else { return [] }
        return [best.id]
    }

    static func isPreferredKeeper(_ lhs: PhotoCandidate, _ rhs: PhotoCandidate) -> Bool {
        let lhsArea = pixelArea(for: lhs)
        let rhsArea = pixelArea(for: rhs)
        let lhsFace = lhs.faceScore ?? 0
        let rhsFace = rhs.faceScore ?? 0

        if lhs.qualityScore != rhs.qualityScore { return lhs.qualityScore > rhs.qualityScore }
        if lhs.sharpness != rhs.sharpness { return lhs.sharpness > rhs.sharpness }
        if lhs.size != rhs.size { return lhs.size > rhs.size }
        if lhsArea != rhsArea { return lhsArea > rhsArea }
        if lhsFace != rhsFace { return lhsFace > rhsFace }
        // Expression tiebreakers (Feature 2)
        let lhsEyes = lhs.eyesOpenScore ?? 0
        let rhsEyes = rhs.eyesOpenScore ?? 0
        if lhsEyes != rhsEyes { return lhsEyes > rhsEyes }
        let lhsSmile = lhs.smileScore ?? 0
        let rhsSmile = rhs.smileScore ?? 0
        if lhsSmile != rhsSmile { return lhsSmile > rhsSmile }
        if lhs.isRaw != rhs.isRaw { return lhs.isRaw }
        return lhs.path < rhs.path
    }

    static func bytesIfPruned(members: [PhotoCandidate], keeperIDs: Set<String>) -> Int64 {
        members.filter { !keeperIDs.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    private static func pixelArea(for candidate: PhotoCandidate) -> Int64 {
        Int64(max(0, candidate.pixelWidth ?? 0)) * Int64(max(0, candidate.pixelHeight ?? 0))
    }

    public static let defaultFeaturePrintDistance: FeaturePrintDistance = { @Sendable lhs, rhs in
        try? VisionFeaturePrinter.distance(lhs, rhs)
    }

    private static func featurePrintData(
        for candidate: PhotoCandidate,
        cache: FeaturePrintDataCache
    ) -> Data? {
        candidate.featurePrintData ?? cache.data(for: candidate.path)
    }
}

private final class FeaturePrintDataCache: @unchecked Sendable {
    private let provider: DuplicateClusterer.FeaturePrintDataProvider?
    private var cache: [String: Data] = [:]
    private var missing: Set<String> = []

    init(provider: DuplicateClusterer.FeaturePrintDataProvider?) {
        self.provider = provider
    }

    func data(for path: String) -> Data? {
        if let cached = cache[path] {
            return cached
        }
        if missing.contains(path) {
            return nil
        }
        guard let data = provider?(path) else {
            missing.insert(path)
            return nil
        }
        cache[path] = data
        return data
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

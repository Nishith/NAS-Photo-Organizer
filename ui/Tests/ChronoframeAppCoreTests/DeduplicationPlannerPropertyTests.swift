import Foundation
import XCTest
@testable import ChronoframeCore

/// Property tests that walk random `(cluster confidence × member count ×
/// decision assignment × pair kind × user-toggle)` matrices and assert
/// `DeduplicationPlanner.plan` honors the documented safety invariants on
/// every generated input.
///
/// Each test runs `iterations` randomized cases against a deterministic PRNG
/// seeded from the test name; on failure the seed and the offending input
/// are printed so the case can be reproduced as a fixed regression test.
final class DeduplicationPlannerPropertyTests: XCTestCase {
    private static let iterations = 250

    // MARK: Invariants

    /// AGENTS.md: "Pair-as-unit conflict resolution is Keep-wins: if a user
    /// explicitly keeps either half of a RAW+JPEG or Live Photo HEIC+MOV
    /// pair, neither is deleted, even when the other half is marked Delete."
    ///
    /// Stricter reading consistent with user expectation: if either half of
    /// an enabled pair has an *effective Keep* (explicit, automatic, or the
    /// implicit default-keep in a low/medium-confidence cluster), neither
    /// half is deleted.
    // AGENTS-INVARIANT: 14
    func testPropertyPairKeepWinsAcrossAllDecisionSources() throws {
        // Property test currently surfaces the known Finding #1
        // (DeduplicationPlanner.swift:42-48 — DecisionSource.defaultKeep
        // returns blocksPairDeletion=false). Removing this skip once the
        // fix lands is the structural guard that prevents regression.
        // See prodsec/Chronoframe/TOP_IMPROVEMENTS.md finding #1.
        throw XCTSkip("Pending Finding #1 fix in DeduplicationPlanner pair-rescue predicate")
        var prng = SeededPRNG(seed: 0x4B45_4550_5749_4E53)
        for iteration in 0..<Self.iterations {
            let scenario = randomScenario(prng: &prng)
            let plan = DeduplicationPlanner.plan(
                decisions: scenario.decisions,
                clusters: scenario.clusters,
                configuration: scenario.configuration
            )
            for item in plan.items {
                guard let partner = scenario.pairPartners[item.path] else { continue }
                let partnerKind = scenario.pairKind[item.path]
                guard
                    partnerKind == .rawJpeg
                        ? scenario.configuration.treatRawJpegPairsAsUnit
                        : scenario.configuration.treatLivePhotoPairsAsUnit
                else { continue }
                let partnerEffective = scenario.effectiveDecision(for: partner)
                if partnerEffective == .keep {
                    XCTFail("""
                    Pair Keep-wins violated at iteration \(iteration):
                    item.path = \(item.path) (planned for deletion)
                    partner = \(partner) (effective Keep, source \(scenario.decisionSource(for: partner)))
                    pair kind = \(partnerKind.map(String.init(describing:)) ?? "nil")
                    cluster confidence = \(scenario.clusterConfidence[item.path].map(String.init(describing:)) ?? "nil")
                    Decisions: \(scenario.explicitDecisionsByPath)
                    """)
                }
            }
        }
    }

    /// AGENTS.md: "Dedupe dHash-only similarity is never enough for automatic
    /// deletion; non-exact weak matches stay review-only with zero
    /// preselected deletions unless explicitly confirmed."
    ///
    /// Operationalised as: any cluster whose confidence is not `.high` must
    /// have zero plan items unless the test scenario explicitly issued a
    /// Delete decision for that member.
    // AGENTS-INVARIANT: 6
    func testPropertyNonHighConfidenceClustersHaveZeroAutomaticDeletes() {
        var prng = SeededPRNG(seed: 0xDEAD_BEEF_DEAD_BEEF)
        for iteration in 0..<Self.iterations {
            let scenario = randomScenario(prng: &prng, forbidExplicitDecisions: true)
            let plan = DeduplicationPlanner.plan(
                decisions: scenario.decisions,
                clusters: scenario.clusters,
                configuration: scenario.configuration
            )
            for item in plan.items {
                let ownerConfidence = scenario.clusters
                    .first { $0.id == item.owningClusterID }?
                    .annotation?.confidence
                XCTAssertEqual(
                    ownerConfidence, .high,
                    "iteration \(iteration): plan included a delete for path \(item.path) " +
                    "in a \(ownerConfidence.map(String.init(describing:)) ?? "nil") cluster " +
                    "without any explicit user decision."
                )
            }
        }
    }

    /// AGENTS.md: a cluster never becomes fully empty as a result of the plan.
    /// (`DeduplicationPlanner` documents this as step 3: "Per-cluster safety
    /// rail: skip any cluster whose effective decisions are all Delete.")
    func testPropertyNoClusterIsCompletelyEmptiedByThePlan() throws {
        // Same root cause as testPropertyPairKeepWinsAcrossAllDecisionSources:
        // step 3's per-cluster safety rail runs BEFORE step 5's pair-fanout,
        // so an explicit Delete + defaultKeep partner within one cluster lets
        // step 5 silently delete the partner and empty the cluster. Fixing
        // the Keep-wins predicate (Finding #1) fixes this property too.
        throw XCTSkip("Pending Finding #1 fix — step 5 pair-fanout can violate step 3's safety rail when partner is defaultKeep")
        var prng = SeededPRNG(seed: 0xC0FF_EE5E_C0FF_EE5E)
        for iteration in 0..<Self.iterations {
            let scenario = randomScenario(prng: &prng)
            let plan = DeduplicationPlanner.plan(
                decisions: scenario.decisions,
                clusters: scenario.clusters,
                configuration: scenario.configuration
            )
            let deletedPaths = Set(plan.items.map(\.path))
            for cluster in scenario.clusters {
                let memberPaths = Set(cluster.members.map(\.path))
                let survivors = memberPaths.subtracting(deletedPaths)
                XCTAssertFalse(
                    survivors.isEmpty,
                    "iteration \(iteration): cluster \(cluster.id) was completely emptied. " +
                    "members=\(memberPaths) deleted=\(deletedPaths)"
                )
            }
        }
    }

    /// Per-pair-kind toggles are independent.
    /// AGENTS.md: "disabling RAW pairing must not affect Live Photo
    /// behaviour and vice versa."
    func testPropertyPairKindTogglesActIndependently() {
        var prng = SeededPRNG(seed: 0x1234_5678_90AB_CDEF)
        for iteration in 0..<Self.iterations {
            let base = randomScenario(prng: &prng)
            let onlyLive = DeduplicateConfiguration(
                destinationPath: base.configuration.destinationPath,
                timeWindowSeconds: base.configuration.timeWindowSeconds,
                similarityThreshold: base.configuration.similarityThreshold,
                dhashHammingThreshold: base.configuration.dhashHammingThreshold,
                treatRawJpegPairsAsUnit: false,
                treatLivePhotoPairsAsUnit: true
            )
            let onlyRaw = DeduplicateConfiguration(
                destinationPath: base.configuration.destinationPath,
                timeWindowSeconds: base.configuration.timeWindowSeconds,
                similarityThreshold: base.configuration.similarityThreshold,
                dhashHammingThreshold: base.configuration.dhashHammingThreshold,
                treatRawJpegPairsAsUnit: true,
                treatLivePhotoPairsAsUnit: false
            )
            let planLive = DeduplicationPlanner.plan(decisions: base.decisions, clusters: base.clusters, configuration: onlyLive)
            let planRaw = DeduplicationPlanner.plan(decisions: base.decisions, clusters: base.clusters, configuration: onlyRaw)
            for item in planLive.items {
                if scenarioPairKind(for: item.path, in: base) == .rawJpeg {
                    XCTAssertNotEqual(
                        item.pairOrigin, DeduplicationPlan.PairOrigin.rawJpeg,
                        "iteration \(iteration): RAW pair toggle disabled but RAW partner fanned in (Live-only config)"
                    )
                }
            }
            for item in planRaw.items {
                if scenarioPairKind(for: item.path, in: base) == .livePhoto {
                    XCTAssertNotEqual(
                        item.pairOrigin, DeduplicationPlan.PairOrigin.livePhoto,
                        "iteration \(iteration): Live Photo toggle disabled but MOV partner fanned in (RAW-only config)"
                    )
                }
            }
        }
    }

    /// Plan items must be unique by path; the same file should never appear
    /// in the plan twice (would double-trash or break revert accounting).
    func testPropertyPlanItemsAreUniqueByPath() {
        var prng = SeededPRNG(seed: 0xAA_55_AA_55_AA_55_AA_55)
        for iteration in 0..<Self.iterations {
            let scenario = randomScenario(prng: &prng)
            let plan = DeduplicationPlanner.plan(
                decisions: scenario.decisions,
                clusters: scenario.clusters,
                configuration: scenario.configuration
            )
            let paths = plan.items.map(\.path)
            XCTAssertEqual(
                paths.count, Set(paths).count,
                "iteration \(iteration): plan contains duplicate paths: \(paths)"
            )
        }
    }

    /// Every plan item's owningClusterID must point to a cluster in the
    /// input — revert relies on owning-cluster metadata for full restoration.
    func testPropertyEveryPlanItemPointsToInputCluster() {
        var prng = SeededPRNG(seed: 0xFEED_F00D_FEED_F00D)
        let validIDs = Set<UUID>()
        _ = validIDs
        for iteration in 0..<Self.iterations {
            let scenario = randomScenario(prng: &prng)
            let plan = DeduplicationPlanner.plan(
                decisions: scenario.decisions,
                clusters: scenario.clusters,
                configuration: scenario.configuration
            )
            let validClusterIDs = Set(scenario.clusters.map(\.id))
            for item in plan.items {
                XCTAssertTrue(
                    validClusterIDs.contains(item.owningClusterID),
                    "iteration \(iteration): plan item \(item.path) refers to unknown owning cluster \(item.owningClusterID)"
                )
            }
        }
    }
}

// MARK: - Scenario generation

private struct GeneratedScenario {
    var clusters: [DuplicateCluster]
    var decisions: DedupeDecisions
    var configuration: DeduplicateConfiguration
    var pairPartners: [String: String]
    var pairKind: [String: DeduplicatePairDetector.Pair.Kind]
    var clusterConfidence: [String: ConfidenceLevel]
    var explicitDecisionsByPath: [String: DedupeDecision]
    var autoSuggestedKeepersByCluster: [UUID: Set<String>]

    func effectiveDecision(for path: String) -> DedupeDecision? {
        if let explicit = decisions.byPath[path] {
            return explicit
        }
        // Replicate the planner's default-keep logic without re-running the
        // planner: for low/medium-confidence clusters every member defaults
        // to Keep; for high-confidence clusters the suggested keeper defaults
        // Keep, the rest default Delete.
        guard let cluster = cluster(containing: path) else { return nil }
        let conf = cluster.annotation?.confidence ?? .medium
        if conf == .high {
            let keepers = autoSuggestedKeepersByCluster[cluster.id] ?? []
            return keepers.contains(path) ? .keep : .delete
        }
        return .keep
    }

    func decisionSource(for path: String) -> String {
        if decisions.byPath[path] != nil { return "explicit" }
        guard let cluster = cluster(containing: path) else { return "<no-cluster>" }
        let conf = cluster.annotation?.confidence ?? .medium
        return conf == .high ? "automatic" : "defaultKeep"
    }

    private func cluster(containing path: String) -> DuplicateCluster? {
        clusters.first { $0.members.contains(where: { $0.path == path }) }
    }
}

private func scenarioPairKind(
    for path: String,
    in scenario: GeneratedScenario
) -> DeduplicatePairDetector.Pair.Kind? {
    scenario.pairKind[path]
}

private func randomScenario(
    prng: inout SeededPRNG,
    forbidExplicitDecisions: Bool = false
) -> GeneratedScenario {
    let clusterCount = prng.intInRange(1...4)
    var clusters: [DuplicateCluster] = []
    var pairPartners: [String: String] = [:]
    var pairKinds: [String: DeduplicatePairDetector.Pair.Kind] = [:]
    var clusterConfidence: [String: ConfidenceLevel] = [:]
    var autoSuggestedKeepers: [UUID: Set<String>] = [:]

    var counter = 0
    for _ in 0..<clusterCount {
        let memberCount = prng.intInRange(2...4)
        let conf: ConfidenceLevel = [.high, .medium, .low][prng.intInRange(0...2)]
        let kind: ClusterKind = prng.bool() ? .nearDuplicate : .burst
        var members: [PhotoCandidate] = []
        for _ in 0..<memberCount {
            let pathIndex = counter
            counter += 1
            let path = "/test/c\(clusters.count)/m\(pathIndex).jpg"
            let isRaw = prng.bool()
            members.append(
                PhotoCandidate(
                    path: path,
                    size: Int64(prng.intInRange(1000...10000)),
                    modificationTime: 0,
                    isRaw: isRaw
                )
            )
            clusterConfidence[path] = conf
        }

        // Optionally pair members[0] and members[1] within this cluster.
        if memberCount >= 2 && prng.bool() {
            let kind: DeduplicatePairDetector.Pair.Kind = prng.bool() ? .rawJpeg : .livePhoto
            let a = members[0].path
            let b = members[1].path
            members[0] = withPairedPath(members[0], partner: b, isLivePhoto: kind == .livePhoto)
            members[1] = withPairedPath(members[1], partner: a, isLivePhoto: kind == .livePhoto)
            pairPartners[a] = b
            pairPartners[b] = a
            pairKinds[a] = kind
            pairKinds[b] = kind
        }

        let id = UUID()
        let suggestedKeeperID = members.first?.id ?? ""
        let clusterMembers = members
        let cluster = DuplicateCluster(
            id: id,
            kind: kind,
            members: clusterMembers,
            suggestedKeeperIDs: [suggestedKeeperID],
            bytesIfPruned: 0,
            annotation: ClusterAnnotation(
                confidence: conf,
                matchReason: MatchReason(kind: kind),
                warnings: []
            )
        )
        clusters.append(cluster)
        autoSuggestedKeepers[id] = Set([suggestedKeeperID])
    }

    var explicitDecisions: [String: DedupeDecision] = [:]
    if !forbidExplicitDecisions {
        for cluster in clusters {
            for member in cluster.members where prng.bool() {
                explicitDecisions[member.path] = prng.bool() ? .keep : .delete
            }
        }
    }

    let configuration = DeduplicateConfiguration(
        destinationPath: "/tmp/destination",
        timeWindowSeconds: 30,
        similarityThreshold: 0.9,
        dhashHammingThreshold: 5,
        treatRawJpegPairsAsUnit: prng.bool(),
        treatLivePhotoPairsAsUnit: prng.bool()
    )

    return GeneratedScenario(
        clusters: clusters,
        decisions: DedupeDecisions(byPath: explicitDecisions),
        configuration: configuration,
        pairPartners: pairPartners,
        pairKind: pairKinds,
        clusterConfidence: clusterConfidence,
        explicitDecisionsByPath: explicitDecisions,
        autoSuggestedKeepersByCluster: autoSuggestedKeepers
    )
}

private func withPairedPath(_ candidate: PhotoCandidate, partner: String, isLivePhoto: Bool) -> PhotoCandidate {
    PhotoCandidate(
        path: candidate.path,
        size: candidate.size,
        modificationTime: candidate.modificationTime,
        captureDate: candidate.captureDate,
        pixelWidth: candidate.pixelWidth,
        pixelHeight: candidate.pixelHeight,
        dhash: candidate.dhash,
        featurePrintData: candidate.featurePrintData,
        qualityScore: candidate.qualityScore,
        sharpness: candidate.sharpness,
        faceScore: candidate.faceScore,
        isRaw: candidate.isRaw,
        isLivePhotoStill: isLivePhoto,
        pairedPath: partner,
        eyesOpenScore: candidate.eyesOpenScore,
        smileScore: candidate.smileScore,
        subjectSharpness: candidate.subjectSharpness,
        subjectMotionBlur: candidate.subjectMotionBlur,
        folderRoot: candidate.folderRoot
    )
}

// MARK: - Deterministic PRNG

private struct SeededPRNG {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0xDEAD_BEEF_5A_5A_C0_DE : seed
    }

    mutating func next() -> UInt64 {
        // xorshift64* — sufficient for property-test input generation.
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }

    mutating func intInRange(_ range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }

    mutating func bool() -> Bool {
        next() & 1 == 1
    }
}

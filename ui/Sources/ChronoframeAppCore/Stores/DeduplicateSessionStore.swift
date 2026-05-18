#if canImport(ChronoframeCore)
import ChronoframeCore
#endif
import Combine
import Foundation

@MainActor
public final class DeduplicateSessionStore: ObservableObject {
    public enum Status: Sendable, Equatable {
        case idle
        case scanning
        case readyToReview
        case committing
        case completed
        /// In-flight restore of a previous dedupe receipt. Distinct from
        /// `.committing` so the UI can show "Restoring N files from
        /// Trash…" instead of mistaking an empty cluster list for an
        /// empty scan.
        case reverting
        /// Restore finished. Distinct from `.completed` so the UI can
        /// say "Restored N files" instead of "Removed N photos".
        case reverted
        case failed(String)
    }

    @Published public private(set) var status: Status = .idle
    @Published public private(set) var currentPhase: DeduplicatePhase?
    @Published public private(set) var phaseCompleted: Int = 0
    @Published public private(set) var phaseTotal: Int = 0
    @Published public private(set) var clusters: [DuplicateCluster] = []
    @Published public private(set) var summary: DeduplicateSummary?
    @Published public private(set) var commitSummary: DeduplicateCommitSummary?
    @Published public private(set) var lastErrorMessage: String?
    @Published public private(set) var issues: [DeduplicateIssue] = []
    @Published public private(set) var runHistory: [DeduplicateFolderHistoryRecord]
    @Published public var decisions: DedupeDecisions = DedupeDecisions()
    @Published public var approvedClusterIDs: Set<DuplicateCluster.ID> = []

    private let engine: any DeduplicateEngine
    private let runHistoryStore: any DeduplicateRunHistoryStoring
    private var streamTask: Task<Void, Never>?
    private var securityScope: SecurityScopedFolderAccess?
    /// Monotonic token: each new stream task captures the current epoch.
    /// `cancelStream` bumps it, so any event hopping back onto MainActor
    /// from a cancelled or replaced task is dropped silently.
    private var currentRunEpoch: UInt64 = 0
    /// Configuration of the most recent scan. Captured so plan previews
    /// (footer counts, recoverable bytes) and the actual commit always
    /// agree on which pair-as-unit toggles + similarity thresholds were
    /// in effect when the clusters were produced.
    private var lastScanConfiguration: DeduplicateConfiguration?
    /// True while an `engine.revert(...)` stream is being consumed.
    /// `consumeCommit`'s `.complete` arm uses this to land in
    /// `.reverted` instead of `.completed`.
    private var isHandlingRevert = false
    /// Configuration used by the current forward commit. Captured so the
    /// persisted folder-history entry records the folder the user actually
    /// deduplicated, even if preferences change while commit is in-flight.
    private var activeCommitConfiguration: DeduplicateConfiguration?

    public init(
        engine: any DeduplicateEngine,
        runHistoryStore: any DeduplicateRunHistoryStoring = UserDefaultsDeduplicateRunHistoryStore()
    ) {
        self.engine = engine
        self.runHistoryStore = runHistoryStore
        self.runHistory = runHistoryStore.load()
    }

    public var isWorking: Bool {
        switch status {
        case .scanning, .committing, .reverting: return true
        default: return false
        }
    }

    /// The deletion plan the executor would build for the current
    /// decisions + clusters + active scan configuration. Drives the
    /// commit footer's pending-count + recoverable-bytes display, so the
    /// preview matches what actually happens (including pair-expanded
    /// partners that aren't cluster members).
    public func currentDeletionPlan() -> DeduplicationPlan {
        guard let configuration = lastScanConfiguration else {
            return DeduplicationPlan(items: [])
        }
        let withSuggestions = applySuggestionsToDecisions()
        return DeduplicationPlanner.plan(
            decisions: withSuggestions,
            clusters: clusters,
            configuration: configuration
        )
    }

    public var totalRecoverableBytes: Int64 {
        currentDeletionPlan().totalBytes
    }

    public var pendingDeleteCount: Int {
        currentDeletionPlan().count
    }

    /// Clusters the user explicitly approved or changed. Scan completion
    /// pre-populates suggested decisions for preview/commit math, but those
    /// suggestions are not the same as a human-reviewed group.
    public var reviewedClusters: [DuplicateCluster] {
        clusters.filter { approvedClusterIDs.contains($0.id) }
    }

    /// Deletion plan scoped to reviewed clusters only.
    public func reviewedDeletionPlan() -> DeduplicationPlan {
        guard let configuration = lastScanConfiguration else {
            return DeduplicationPlan(items: [])
        }
        return DeduplicationPlanner.plan(
            decisions: decisions,
            clusters: reviewedClusters,
            configuration: configuration
        )
    }

    /// Commits delete decisions for reviewed clusters only; unreviewed clusters
    /// remain in the session untouched.
    public func commitReviewed(
        configuration: DeduplicateConfiguration,
        securityScope: SecurityScopedFolderAccess? = nil
    ) {
        cancelStream()
        self.securityScope = securityScope
        commitSummary = nil
        isHandlingRevert = false
        status = .committing
        let commitConfiguration = lastScanConfiguration ?? configuration
        activeCommitConfiguration = commitConfiguration
        do {
            let stream = try engine.commit(
                decisions: decisions,
                clusters: reviewedClusters,
                configuration: commitConfiguration
            )
            let epoch = currentRunEpoch
            streamTask = Task { [weak self] in
                do {
                    for try await event in stream {
                        await MainActor.run { [weak self] in
                            guard let self, self.currentRunEpoch == epoch else { return }
                            self.consumeCommit(event)
                        }
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self, self.currentRunEpoch == epoch else { return }
                        self.applyStreamError(error)
                    }
                }
            }
        } catch {
            applyStreamError(error)
        }
    }

    /// Phase 1 finding: `.failed` was assigned for ANY thrown error,
    /// including `CancellationError`. The latter has a useless
    /// `localizedDescription` ("The operation couldn't be completed.
    /// (Swift.CancellationError error 1.)") that consumers were
    /// rendering as a user-visible failure. Treat cancellation as a
    /// clean state transition instead.
    private func applyStreamError(_ error: Error) {
        if error is CancellationError || Task.isCancelled {
            status = .idle
            lastErrorMessage = nil
            closeSecurityScope()
            return
        }
        status = .failed(error.localizedDescription)
        lastErrorMessage = error.localizedDescription
        closeSecurityScope()
    }

    public var hasPausedReview: Bool {
        status == .idle && !clusters.isEmpty && lastScanConfiguration != nil
    }

    public var pausedReviewConfiguration: DeduplicateConfiguration? {
        hasPausedReview ? lastScanConfiguration : nil
    }

    public func pausedReviewMatches(configuration: DeduplicateConfiguration) -> Bool {
        pausedReviewConfiguration == configuration
    }

    public func startScan(
        configuration: DeduplicateConfiguration,
        securityScope: SecurityScopedFolderAccess? = nil
    ) {
        cancelStream()
        self.securityScope = securityScope
        clusters = []
        summary = nil
        commitSummary = nil
        issues = []
        lastErrorMessage = nil
        status = .scanning
        currentPhase = nil
        phaseCompleted = 0
        phaseTotal = 0
        lastScanConfiguration = configuration
        decisions = DedupeDecisions(byPath: [:])
        approvedClusterIDs = []

        do {
            let stream = try engine.scan(configuration)
            let epoch = currentRunEpoch
            streamTask = Task { [weak self] in
                do {
                    for try await event in stream {
                        await MainActor.run { [weak self] in
                            guard let self, self.currentRunEpoch == epoch else { return }
                            self.consume(event)
                        }
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self, self.currentRunEpoch == epoch else { return }
                        self.status = .failed(error.localizedDescription)
                        self.lastErrorMessage = error.localizedDescription
                        self.activeCommitConfiguration = nil
                        self.closeSecurityScope()
                    }
                }
            }
        } catch {
            status = .failed(error.localizedDescription)
            lastErrorMessage = error.localizedDescription
            activeCommitConfiguration = nil
            closeSecurityScope()
        }
    }

    public func cancel() {
        engine.cancelCurrentScan()
        cancelStream()
        if isWorking {
            status = .idle
        }
        activeCommitConfiguration = nil
        closeSecurityScope()
    }

    /// Restore items listed in a previous dedupe audit receipt from Trash
    /// back to their original paths. Streams progress through the same
    /// commit-event channel as the forward path so the UI surface is shared.
    public func revert(
        receiptURL: URL,
        destinationRoot: String,
        securityScope: SecurityScopedFolderAccess? = nil
    ) {
        cancelStream()
        self.securityScope = securityScope
        commitSummary = nil
        isHandlingRevert = true
        status = .reverting
        do {
            let stream = try engine.revert(receiptURL: receiptURL, destinationRoot: destinationRoot)
            let epoch = currentRunEpoch
            streamTask = Task { [weak self] in
                do {
                    for try await event in stream {
                        await MainActor.run { [weak self] in
                            guard let self, self.currentRunEpoch == epoch else { return }
                            self.consumeCommit(event)
                        }
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self, self.currentRunEpoch == epoch else { return }
                        self.applyStreamError(error)
                    }
                }
            }
        } catch {
            applyStreamError(error)
        }
    }

    public func commit(
        configuration: DeduplicateConfiguration,
        securityScope: SecurityScopedFolderAccess? = nil
    ) {
        cancelStream()
        self.securityScope = securityScope
        commitSummary = nil
        isHandlingRevert = false
        status = .committing
        let commitConfiguration = lastScanConfiguration ?? configuration
        activeCommitConfiguration = commitConfiguration
        do {
            let stream = try engine.commit(
                decisions: applySuggestionsToDecisions(),
                clusters: clusters,
                configuration: commitConfiguration
            )
            let epoch = currentRunEpoch
            streamTask = Task { [weak self] in
                do {
                    for try await event in stream {
                        await MainActor.run { [weak self] in
                            guard let self, self.currentRunEpoch == epoch else { return }
                            self.consumeCommit(event)
                        }
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self, self.currentRunEpoch == epoch else { return }
                        self.applyStreamError(error)
                    }
                }
            }
        } catch {
            applyStreamError(error)
        }
    }

    public func setDecision(_ decision: DedupeDecision, forPath path: String) {
        var byPath = decisions.byPath
        byPath[path] = decision
        decisions = DedupeDecisions(byPath: byPath)
        if let cluster = clusters.first(where: { cluster in
            cluster.members.contains { $0.path == path }
        }) {
            approvedClusterIDs.insert(cluster.id)
        }
    }

    public func approveCluster(_ clusterID: DuplicateCluster.ID) {
        approvedClusterIDs.insert(clusterID)
    }

    public func acceptSuggestionsForCluster(_ cluster: DuplicateCluster) {
        var byPath = decisions.byPath
        for (path, decision) in suggestedDecisions(for: [cluster]).byPath {
            byPath[path] = decision
        }
        decisions = DedupeDecisions(byPath: byPath)
        approvedClusterIDs.insert(cluster.id)
    }

    public func keepAllInCluster(_ cluster: DuplicateCluster) {
        var byPath = decisions.byPath
        for member in cluster.members {
            byPath[member.path] = .keep
        }
        decisions = DedupeDecisions(byPath: byPath)
        approvedClusterIDs.insert(cluster.id)
    }

    public func deleteAllInCluster(_ cluster: DuplicateCluster) {
        var byPath = decisions.byPath
        for member in cluster.members {
            byPath[member.path] = .delete
        }
        decisions = DedupeDecisions(byPath: byPath)
        approvedClusterIDs.insert(cluster.id)
    }

    public func acceptAllSuggestions() {
        // Phase 1 finding #10: scope this to *automatically eligible*
        // clusters (high-confidence) only, matching the AGENTS.md
        // invariant that non-exact / weak matches stay review-only
        // until the user explicitly approves them. The previous
        // implementation approved every cluster regardless of
        // confidence, so a user clicking "Accept all suggestions"
        // would silently commit low/medium-confidence preselects on
        // commit.
        let eligibleClusters = clusters.filter(DeduplicationPlanner.isAutomaticCommitEligible)
        guard !eligibleClusters.isEmpty else { return }
        var byPath = decisions.byPath
        for (path, decision) in suggestedDecisions(for: eligibleClusters).byPath {
            byPath[path] = decision
        }
        decisions = DedupeDecisions(byPath: byPath)
        approvedClusterIDs.formUnion(eligibleClusters.map(\.id))
    }

    // MARK: - Confidence Triage

    public var triageBuckets: [ConfidenceLevel: [DuplicateCluster]] {
        var buckets: [ConfidenceLevel: [DuplicateCluster]] = [
            .high: [], .medium: [], .low: [],
        ]
        for cluster in clusters {
            let level = cluster.annotation?.confidence ?? .medium
            buckets[level, default: []].append(cluster)
        }
        return buckets
    }

    public func acceptAllHighConfidence() {
        let highClusters = triageBuckets[.high] ?? []
        guard !highClusters.isEmpty else { return }
        var byPath = decisions.byPath
        for (path, decision) in suggestedDecisions(for: highClusters).byPath {
            byPath[path] = decision
        }
        decisions = DedupeDecisions(byPath: byPath)
        approvedClusterIDs.formUnion(highClusters.map(\.id))
    }

    public func pauseReview() {
        guard status == .readyToReview, !clusters.isEmpty else { return }
        cancelStream()
        status = .idle
        currentPhase = nil
        phaseCompleted = 0
        phaseTotal = 0
        activeCommitConfiguration = nil
    }

    public func resumePausedReview() {
        guard hasPausedReview else { return }
        status = .readyToReview
        currentPhase = nil
        phaseCompleted = 0
        phaseTotal = 0
        commitSummary = nil
        lastErrorMessage = nil
    }

    public func reset() {
        cancelStream()
        clusters = []
        summary = nil
        commitSummary = nil
        issues = []
        lastErrorMessage = nil
        status = .idle
        currentPhase = nil
        phaseCompleted = 0
        phaseTotal = 0
        lastScanConfiguration = nil
        isHandlingRevert = false
        activeCommitConfiguration = nil
        decisions = DedupeDecisions(byPath: [:])
        approvedClusterIDs = []
        closeSecurityScope()
    }

    // MARK: - Private

    private func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
        currentRunEpoch &+= 1
        closeSecurityScope()
    }

    private func closeSecurityScope() {
        securityScope?.close()
        securityScope = nil
    }

    private func consume(_ event: DeduplicateEvent) {
        switch event {
        case .startup:
            break
        case let .phaseStarted(phase, total):
            currentPhase = phase
            phaseCompleted = 0
            phaseTotal = total ?? 0
        case let .phaseProgress(phase, completed, total):
            currentPhase = phase
            phaseCompleted = completed
            phaseTotal = total
        case .phaseCompleted:
            break
        case let .clusterDiscovered(cluster):
            clusters.append(cluster)
        case let .issue(issue):
            issues.append(issue)
        case let .complete(summary):
            self.summary = summary
            status = .readyToReview
            currentPhase = nil
            closeSecurityScope()
            // Pre-populate decisions with suggestions so the UI starts in
            // a plan-preview state. The user still needs to approve a group
            // before it counts as reviewed.
            let suggested = suggestedDecisions(for: clusters)
            decisions = DedupeDecisions(byPath: suggested.byPath)
            approvedClusterIDs = []
        }
    }

    private func consumeCommit(_ event: DeduplicateCommitEvent) {
        switch event {
        case let .started(total):
            phaseCompleted = 0
            phaseTotal = total
        case .itemTrashed:
            phaseCompleted += 1
        case let .itemTrashedReceiptStale(_, _, _, message):
            // Phase 1 finding #7: the file IS in Trash but the
            // per-item receipt write failed. Surface a warning rather
            // than an error — the user's intent succeeded; only the
            // audit trail is stale. Still advances the progress counter
            // so the UI doesn't appear stuck.
            issues.append(DeduplicateIssue(
                severity: .warning,
                message: "File was moved to Trash, but the audit receipt could not be updated: \(message)"
            ))
            phaseCompleted += 1
        case let .itemFailed(_, message):
            issues.append(DeduplicateIssue(severity: .error, message: message))
            phaseCompleted += 1
        case let .criticalReceiptFailure(message):
            // End-of-run finalize failure. Surfaces once per run with
            // no per-item path attached.
            issues.append(DeduplicateIssue(severity: .error, message: message))
        case let .complete(summary):
            commitSummary = summary
            if !isHandlingRevert, let destinationPath = activeCommitConfiguration?.destinationPath {
                runHistory = runHistoryStore.recordRun(
                    destinationPath: destinationPath,
                    summary: summary,
                    completedAt: Date()
                )
            }
            status = isHandlingRevert ? .reverted : .completed
            isHandlingRevert = false
            activeCommitConfiguration = nil
            closeSecurityScope()
        }
    }

    private func applySuggestionsToDecisions() -> DedupeDecisions {
        var byPath = decisions.byPath
        for (path, decision) in automaticDecisions(for: clusters).byPath where byPath[path] == nil {
            byPath[path] = decision
        }
        return DedupeDecisions(byPath: byPath)
    }

    private func suggestedDecisions(for clusters: [DuplicateCluster]) -> DedupeDecisions {
        guard let configuration = lastScanConfiguration else {
            var byPath: [String: DedupeDecision] = [:]
            for cluster in clusters {
                let keepers = Set(cluster.suggestedKeeperIDs.prefix(1))
                for member in cluster.members {
                    byPath[member.path] = keepers.contains(member.id) ? .keep : .delete
                }
            }
            return DedupeDecisions(byPath: byPath)
        }
        return DeduplicationPlanner.suggestedDecisions(
            for: clusters,
            configuration: configuration
        )
    }

    private func automaticDecisions(for clusters: [DuplicateCluster]) -> DedupeDecisions {
        guard let configuration = lastScanConfiguration else {
            return DedupeDecisions(byPath: [:])
        }
        return DeduplicationPlanner.automaticDecisions(
            for: clusters,
            configuration: configuration
        )
    }
}

extension DedupeDecisions {
    /// The set of paths the user has chosen to keep within `cluster`,
    /// falling back to the cluster's suggested keepers for any member with
    /// no explicit decision.
    public func keepersForCluster(_ cluster: DuplicateCluster) -> [String] {
        let suggestedKeepers = Set(cluster.suggestedKeeperIDs.prefix(1))
        let autoSelectable = DeduplicationPlanner.isAutomaticCommitEligible(cluster)
        return cluster.members.compactMap { member in
            let decision = byPath[member.path]
                ?? (autoSelectable
                    ? (suggestedKeepers.contains(member.id) ? .keep : .delete)
                    : .keep)
            return decision == .keep ? member.path : nil
        }
    }
}

public struct DeduplicateFolderHistoryRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: String { folderPath }
    public var folderPath: String
    public var lastRunAt: Date
    public var runCount: Int
    public var lastDeletedCount: Int
    public var lastFailedCount: Int
    public var lastBytesReclaimed: Int64
    public var totalDeletedCount: Int
    public var totalFailedCount: Int
    public var totalBytesReclaimed: Int64
    public var lastReceiptPath: String?
    public var lastHardDelete: Bool

    public init(
        folderPath: String,
        lastRunAt: Date,
        runCount: Int,
        lastDeletedCount: Int,
        lastFailedCount: Int,
        lastBytesReclaimed: Int64,
        totalDeletedCount: Int,
        totalFailedCount: Int,
        totalBytesReclaimed: Int64,
        lastReceiptPath: String?,
        lastHardDelete: Bool
    ) {
        self.folderPath = folderPath
        self.lastRunAt = lastRunAt
        self.runCount = runCount
        self.lastDeletedCount = lastDeletedCount
        self.lastFailedCount = lastFailedCount
        self.lastBytesReclaimed = lastBytesReclaimed
        self.totalDeletedCount = totalDeletedCount
        self.totalFailedCount = totalFailedCount
        self.totalBytesReclaimed = totalBytesReclaimed
        self.lastReceiptPath = lastReceiptPath
        self.lastHardDelete = lastHardDelete
    }
}

public protocol DeduplicateRunHistoryStoring: AnyObject {
    func load() -> [DeduplicateFolderHistoryRecord]
    func recordRun(
        destinationPath: String,
        summary: DeduplicateCommitSummary,
        completedAt: Date
    ) -> [DeduplicateFolderHistoryRecord]
}

public final class UserDefaultsDeduplicateRunHistoryStore: DeduplicateRunHistoryStoring {
    public static let defaultLimit = 12

    private static let key = "deduplicateFolderHistory"

    private let defaults: UserDefaults
    private let limit: Int

    public init(
        defaults: UserDefaults = .standard,
        limit: Int = UserDefaultsDeduplicateRunHistoryStore.defaultLimit
    ) {
        self.defaults = defaults
        self.limit = max(1, limit)
    }

    public func load() -> [DeduplicateFolderHistoryRecord] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([DeduplicateFolderHistoryRecord].self, from: data)) ?? []
    }

    public func recordRun(
        destinationPath: String,
        summary: DeduplicateCommitSummary,
        completedAt: Date = Date()
    ) -> [DeduplicateFolderHistoryRecord] {
        let trimmed = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return load() }

        var records = load()
        let previous = records.first { $0.folderPath == trimmed }
        records.removeAll { $0.folderPath == trimmed }

        let updated = DeduplicateFolderHistoryRecord(
            folderPath: trimmed,
            lastRunAt: completedAt,
            runCount: (previous?.runCount ?? 0) + 1,
            lastDeletedCount: summary.deletedCount,
            lastFailedCount: summary.failedCount,
            lastBytesReclaimed: summary.bytesReclaimed,
            totalDeletedCount: (previous?.totalDeletedCount ?? 0) + summary.deletedCount,
            totalFailedCount: (previous?.totalFailedCount ?? 0) + summary.failedCount,
            totalBytesReclaimed: (previous?.totalBytesReclaimed ?? 0) + summary.bytesReclaimed,
            lastReceiptPath: summary.receiptPath,
            lastHardDelete: summary.hardDelete
        )
        records.insert(updated, at: 0)
        records = Array(records.prefix(limit))
        persist(records)
        return records
    }

    private func persist(_ records: [DeduplicateFolderHistoryRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

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

    private let engine: any DeduplicateEngine
    private let runHistoryStore: any DeduplicateRunHistoryStoring
    private var streamTask: Task<Void, Never>?
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

    public var hasPausedReview: Bool {
        status == .idle && !clusters.isEmpty && lastScanConfiguration != nil
    }

    public var pausedReviewConfiguration: DeduplicateConfiguration? {
        hasPausedReview ? lastScanConfiguration : nil
    }

    public func pausedReviewMatches(configuration: DeduplicateConfiguration) -> Bool {
        pausedReviewConfiguration == configuration
    }

    public func startScan(configuration: DeduplicateConfiguration) {
        cancelStream()
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
        decisions = DedupeDecisions(byPath: [:], hardDelete: decisions.hardDelete)

        do {
            let stream = try engine.scan(configuration)
            streamTask = Task { [weak self] in
                do {
                    for try await event in stream {
                        await MainActor.run { [weak self] in
                            self?.consume(event)
                        }
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.status = .failed(error.localizedDescription)
                        self?.lastErrorMessage = error.localizedDescription
                        self?.activeCommitConfiguration = nil
                    }
                }
            }
        } catch {
            status = .failed(error.localizedDescription)
            lastErrorMessage = error.localizedDescription
            activeCommitConfiguration = nil
        }
    }

    public func cancel() {
        engine.cancelCurrentScan()
        cancelStream()
        if isWorking {
            status = .idle
        }
        activeCommitConfiguration = nil
    }

    /// Restore items listed in a previous dedupe audit receipt from Trash
    /// back to their original paths. Streams progress through the same
    /// commit-event channel as the forward path so the UI surface is shared.
    public func revert(receiptURL: URL) {
        cancelStream()
        commitSummary = nil
        isHandlingRevert = true
        status = .reverting
        do {
            let stream = try engine.revert(receiptURL: receiptURL)
            streamTask = Task { [weak self] in
                do {
                    for try await event in stream {
                        await MainActor.run { [weak self] in
                            self?.consumeCommit(event)
                        }
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.status = .failed(error.localizedDescription)
                        self?.lastErrorMessage = error.localizedDescription
                    }
                }
            }
        } catch {
            status = .failed(error.localizedDescription)
            lastErrorMessage = error.localizedDescription
        }
    }

    public func commit(configuration: DeduplicateConfiguration) {
        cancelStream()
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
            streamTask = Task { [weak self] in
                do {
                    for try await event in stream {
                        await MainActor.run { [weak self] in
                            self?.consumeCommit(event)
                        }
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.status = .failed(error.localizedDescription)
                        self?.lastErrorMessage = error.localizedDescription
                    }
                }
            }
        } catch {
            status = .failed(error.localizedDescription)
            lastErrorMessage = error.localizedDescription
        }
    }

    public func setDecision(_ decision: DedupeDecision, forPath path: String) {
        var byPath = decisions.byPath
        byPath[path] = decision
        decisions = DedupeDecisions(byPath: byPath, hardDelete: decisions.hardDelete)
    }

    public func acceptSuggestionsForCluster(_ cluster: DuplicateCluster) {
        var byPath = decisions.byPath
        for (path, decision) in suggestedDecisions(for: [cluster]).byPath {
            byPath[path] = decision
        }
        decisions = DedupeDecisions(byPath: byPath, hardDelete: decisions.hardDelete)
    }

    public func acceptAllSuggestions() {
        var byPath = decisions.byPath
        for (path, decision) in suggestedDecisions(for: clusters).byPath {
            byPath[path] = decision
        }
        decisions = DedupeDecisions(byPath: byPath, hardDelete: decisions.hardDelete)
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
        decisions = DedupeDecisions(byPath: [:], hardDelete: decisions.hardDelete)
    }

    // MARK: - Private

    private func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
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
            // Pre-populate decisions with suggestions so the UI starts in
            // an "everything reviewed" state — the user only intervenes
            // for clusters they disagree with.
            acceptAllSuggestions()
        }
    }

    private func consumeCommit(_ event: DeduplicateCommitEvent) {
        switch event {
        case let .started(total):
            phaseCompleted = 0
            phaseTotal = total
        case .itemTrashed:
            phaseCompleted += 1
        case let .itemFailed(_, message):
            issues.append(DeduplicateIssue(severity: .error, message: message))
            phaseCompleted += 1
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
        }
    }

    private func applySuggestionsToDecisions() -> DedupeDecisions {
        var byPath = decisions.byPath
        for (path, decision) in suggestedDecisions(for: clusters).byPath where byPath[path] == nil {
            byPath[path] = decision
        }
        return DedupeDecisions(byPath: byPath, hardDelete: decisions.hardDelete)
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
            return DedupeDecisions(byPath: byPath, hardDelete: decisions.hardDelete)
        }
        return DeduplicationPlanner.suggestedDecisions(
            for: clusters,
            configuration: configuration,
            hardDelete: decisions.hardDelete
        )
    }
}

extension DedupeDecisions {
    /// The set of paths the user has chosen to keep within `cluster`,
    /// falling back to the cluster's suggested keepers for any member with
    /// no explicit decision.
    public func keepersForCluster(_ cluster: DuplicateCluster) -> [String] {
        let suggestedKeepers = Set(cluster.suggestedKeeperIDs.prefix(1))
        return cluster.members.compactMap { member in
            let decision = byPath[member.path] ?? (suggestedKeepers.contains(member.id) ? .keep : .delete)
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

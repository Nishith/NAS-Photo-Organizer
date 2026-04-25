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
    @Published public var decisions: DedupeDecisions = DedupeDecisions()

    private let engine: any DeduplicateEngine
    private var streamTask: Task<Void, Never>?

    public init(engine: any DeduplicateEngine) {
        self.engine = engine
    }

    public var isWorking: Bool {
        switch status {
        case .scanning, .committing: return true
        default: return false
        }
    }

    public var totalRecoverableBytes: Int64 {
        clusters.reduce(0) { partial, cluster in
            let keepers = Set(decisions.keepersForCluster(cluster))
            let pruned = cluster.members.filter { !keepers.contains($0.path) }
            return partial + pruned.reduce(0) { $0 + $1.size }
        }
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
                    }
                }
            }
        } catch {
            status = .failed(error.localizedDescription)
            lastErrorMessage = error.localizedDescription
        }
    }

    public func cancel() {
        engine.cancelCurrentScan()
        cancelStream()
        if isWorking {
            status = .idle
        }
    }

    /// Restore items listed in a previous dedupe audit receipt from Trash
    /// back to their original paths. Streams progress through the same
    /// commit-event channel as the forward path so the UI surface is shared.
    public func revert(receiptURL: URL) {
        cancelStream()
        commitSummary = nil
        status = .committing
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
        status = .committing
        do {
            let stream = try engine.commit(
                decisions: applySuggestionsToDecisions(),
                clusters: clusters,
                configuration: configuration
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
        let keepers = Set(cluster.suggestedKeeperIDs)
        for member in cluster.members {
            byPath[member.path] = keepers.contains(member.id) ? .keep : .delete
        }
        decisions = DedupeDecisions(byPath: byPath, hardDelete: decisions.hardDelete)
    }

    public func acceptAllSuggestions() {
        var byPath = decisions.byPath
        for cluster in clusters {
            let keepers = Set(cluster.suggestedKeeperIDs)
            for member in cluster.members {
                byPath[member.path] = keepers.contains(member.id) ? .keep : .delete
            }
        }
        decisions = DedupeDecisions(byPath: byPath, hardDelete: decisions.hardDelete)
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
            status = .completed
        }
    }

    private func applySuggestionsToDecisions() -> DedupeDecisions {
        var byPath = decisions.byPath
        for cluster in clusters {
            let keepers = Set(cluster.suggestedKeeperIDs)
            for member in cluster.members where byPath[member.path] == nil {
                byPath[member.path] = keepers.contains(member.id) ? .keep : .delete
            }
        }
        return DedupeDecisions(byPath: byPath, hardDelete: decisions.hardDelete)
    }
}

extension DedupeDecisions {
    /// The set of paths the user has chosen to keep within `cluster`,
    /// falling back to the cluster's suggested keepers for any member with
    /// no explicit decision.
    public func keepersForCluster(_ cluster: DuplicateCluster) -> [String] {
        cluster.members.compactMap { member in
            let decision = byPath[member.path] ?? (cluster.suggestedKeeperIDs.contains(member.id) ? .keep : .delete)
            return decision == .keep ? member.path : nil
        }
    }
}

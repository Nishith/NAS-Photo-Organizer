import Foundation
@testable import ChronoframeAppCore

enum TestFailure: Error, LocalizedError {
    case expectedFailure(String)

    var errorDescription: String? {
        switch self {
        case let .expectedFailure(message):
            return message
        }
    }
}

@MainActor
final class MockOrganizerEngine: OrganizerEngine {
    enum StreamMode {
        case events([RunEvent])
        case fails(Error)
        case pending
    }

    var preflightResult: Result<RunPreflight, Error>
    var startMode: StreamMode
    var resumeMode: StreamMode
    var revertMode: StreamMode
    var reorganizeMode: StreamMode
    var startConfigurations: [RunConfiguration] = []
    var resumeConfigurations: [RunConfiguration] = []
    var revertRequests: [(receiptURL: URL, destinationRoot: String)] = []
    var reorganizeRequests: [(destinationRoot: String, targetStructure: FolderStructure)] = []
    var cancelCallCount = 0
    var pendingContinuation: AsyncThrowingStream<RunEvent, Error>.Continuation?

    init(
        preflightResult: Result<RunPreflight, Error>,
        startMode: StreamMode = .events([]),
        resumeMode: StreamMode = .events([]),
        revertMode: StreamMode = .events([]),
        reorganizeMode: StreamMode = .events([])
    ) {
        self.preflightResult = preflightResult
        self.startMode = startMode
        self.resumeMode = resumeMode
        self.revertMode = revertMode
        self.reorganizeMode = reorganizeMode
    }

    func preflight(_ configuration: RunConfiguration) async throws -> RunPreflight {
        try preflightResult.get()
    }

    func start(_ configuration: RunConfiguration) throws -> AsyncThrowingStream<RunEvent, Error> {
        startConfigurations.append(configuration)
        return try makeStream(for: startMode)
    }

    func resume(_ configuration: RunConfiguration) throws -> AsyncThrowingStream<RunEvent, Error> {
        resumeConfigurations.append(configuration)
        return try makeStream(for: resumeMode)
    }

    func cancelCurrentRun() {
        cancelCallCount += 1
        pendingContinuation?.finish()
        pendingContinuation = nil
    }

    func revert(receiptURL: URL, destinationRoot: String) throws -> AsyncThrowingStream<RunEvent, Error> {
        revertRequests.append((receiptURL: receiptURL, destinationRoot: destinationRoot))
        return try makeStream(for: revertMode)
    }

    func reorganize(
        destinationRoot: String,
        targetStructure: FolderStructure
    ) throws -> AsyncThrowingStream<RunEvent, Error> {
        reorganizeRequests.append((destinationRoot: destinationRoot, targetStructure: targetStructure))
        return try makeStream(for: reorganizeMode)
    }

    private func makeStream(for mode: StreamMode) throws -> AsyncThrowingStream<RunEvent, Error> {
        switch mode {
        case let .events(events):
            return AsyncThrowingStream { continuation in
                Task { @MainActor in
                    for event in events {
                        continuation.yield(event)
                    }
                    continuation.finish()
                }
            }
        case let .fails(error):
            throw error
        case .pending:
            return AsyncThrowingStream { continuation in
                self.pendingContinuation = continuation
            }
        }
    }
}

@MainActor
final class MockDeduplicateEngine: DeduplicateEngine {
    var clustersToEmit: [DuplicateCluster] = []
    var summary: DeduplicateSummary = DeduplicateSummary()
    var commitEvents: [DeduplicateCommitEvent] = []
    var revertEvents: [DeduplicateCommitEvent] = []
    var scanError: Error?
    var lastScanConfiguration: DeduplicateConfiguration?
    var lastCommitDecisions: DedupeDecisions?
    var lastCommitClusters: [DuplicateCluster] = []
    var lastCommitConfiguration: DeduplicateConfiguration?

    init(
        clusters: [DuplicateCluster] = [],
        summary: DeduplicateSummary = DeduplicateSummary(),
        commitEvents: [DeduplicateCommitEvent] = [],
        revertEvents: [DeduplicateCommitEvent] = []
    ) {
        self.clustersToEmit = clusters
        self.summary = summary
        self.commitEvents = commitEvents
        self.revertEvents = revertEvents
    }

    func scan(_ configuration: DeduplicateConfiguration) throws -> AsyncThrowingStream<DeduplicateEvent, Error> {
        lastScanConfiguration = configuration
        if let scanError {
            throw scanError
        }
        let clusters = clustersToEmit
        let summary = summary
        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                continuation.yield(.startup)
                for cluster in clusters {
                    continuation.yield(.clusterDiscovered(cluster))
                }
                continuation.yield(.complete(summary))
                continuation.finish()
            }
        }
    }

    func cancelCurrentScan() {}

    func commit(
        decisions: DedupeDecisions,
        clusters: [DuplicateCluster],
        configuration: DeduplicateConfiguration
    ) throws -> AsyncThrowingStream<DeduplicateCommitEvent, Error> {
        lastCommitDecisions = decisions
        lastCommitClusters = clusters
        lastCommitConfiguration = configuration
        let events = commitEvents
        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    func revert(receiptURL: URL) throws -> AsyncThrowingStream<DeduplicateCommitEvent, Error> {
        let events = revertEvents
        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
    }
}

@MainActor
func waitForCondition(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    pollNanoseconds: UInt64 = 20_000_000,
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds

    while DispatchTime.now().uptimeNanoseconds < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: pollNanoseconds)
    }

    return condition()
}

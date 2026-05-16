#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import Dispatch
import Foundation
@testable import ChronoframeApp

enum AppTestFailure: Error, LocalizedError {
    case expectedFailure(String)

    var errorDescription: String? {
        switch self {
        case let .expectedFailure(message):
            return message
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

@MainActor
final class AppStateHarness {
    let suiteName: String
    let defaults: UserDefaults
    let preferencesStore: PreferencesStore
    let setupStore: SetupStore
    let runLogStore: RunLogStore
    let historyStore: HistoryStore
    let repository: MockProfilesRepository
    let folderAccessService: MockFolderAccessService
    let finderService: MockFinderService
    let engine: MockOrganizerEngine
    let deduplicateEngine: MockDeduplicateEngine
    let runSessionStore: RunSessionStore
    let deduplicateSessionStore: DeduplicateSessionStore

    init() {
        suiteName = "AppStateTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        preferencesStore = PreferencesStore(defaults: defaults)
        setupStore = SetupStore()
        runLogStore = RunLogStore(capacity: 300)
        historyStore = HistoryStore()
        repository = MockProfilesRepository()
        folderAccessService = MockFolderAccessService()
        finderService = MockFinderService()
        engine = MockOrganizerEngine(
            preflightResult: .success(
                RunPreflight(
                    configuration: RunConfiguration(mode: .preview, sourcePath: "/tmp/source", destinationPath: "/tmp/destination"),
                    resolvedSourcePath: "/tmp/source",
                    resolvedDestinationPath: "/tmp/destination"
                )
            ),
            startMode: .events([
                .complete(
                    RunSummary(
                        status: .dryRunFinished,
                        title: "Preview complete",
                        metrics: RunMetrics(plannedCount: 1),
                        artifacts: RunArtifactPaths(destinationRoot: "/tmp/destination")
                    )
                )
            ])
        )
        runSessionStore = RunSessionStore(engine: engine, logStore: runLogStore, historyStore: historyStore)
        deduplicateEngine = MockDeduplicateEngine()
        deduplicateSessionStore = DeduplicateSessionStore(
            engine: deduplicateEngine,
            runHistoryStore: UserDefaultsDeduplicateRunHistoryStore(defaults: defaults)
        )
    }

    func makeAppState(
        performInitialBootstrap: Bool = true,
        restoreBookmarksDuringBootstrap: Bool = true,
        showSettingsWindowAction: @escaping @MainActor () -> Void = {}
    ) -> AppState {
        AppState(
            preferencesStore: self.preferencesStore,
            setupStore: self.setupStore,
            runLogStore: self.runLogStore,
            historyStore: self.historyStore,
            runSessionStore: self.runSessionStore,
            deduplicateSessionStore: self.deduplicateSessionStore,
            folderAccessService: self.folderAccessService,
            finderService: self.finderService,
            profilesRepository: self.repository,
            performInitialBootstrap: performInitialBootstrap,
            restoreBookmarksDuringBootstrap: restoreBookmarksDuringBootstrap,
            showSettingsWindowAction: showSettingsWindowAction
        )
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
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    func revert(receiptURL: URL, destinationRoot: String) throws -> AsyncThrowingStream<DeduplicateCommitEvent, Error> {
        let events = revertEvents
        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }
}

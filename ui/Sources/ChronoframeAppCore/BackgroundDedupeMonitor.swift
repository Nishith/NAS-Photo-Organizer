import Combine
#if canImport(ChronoframeCore)
import ChronoframeCore
#endif
import Foundation

/// Watches monitored folders for new/changed media files and runs
/// incremental dedup scans in the background. Surfaces new duplicate
/// clusters via a badge count without requiring a manual scan.
@MainActor
public final class BackgroundDedupeMonitor: ObservableObject {
    @Published public var isMonitoring: Bool = false
    @Published public var pendingClusters: [DuplicateCluster] = []
    @Published public var pendingBytes: Int64 = 0

    public var badgeCount: Int { pendingClusters.count }

    private var monitor: FileSystemMonitor?
    private var monitorTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var configuration: DeduplicateConfiguration?
    private let scanner = DeduplicateScanner()

    public init() {}

    public func startMonitoring(configuration: DeduplicateConfiguration) {
        stopMonitoring()
        self.configuration = configuration

        var watchPaths = [configuration.destinationPath]
        watchPaths.append(contentsOf: configuration.additionalSources.map(\.path))

        let fsMonitor = FileSystemMonitor(paths: watchPaths, latency: 2.0)
        self.monitor = fsMonitor
        self.isMonitoring = true

        monitorTask = Task { [weak self] in
            for await events in fsMonitor.start() {
                guard let self else { return }
                let mediaEvents = events.filter { event in
                    event.isFile && (event.isCreated || event.isModified)
                        && MediaLibraryRules.isSupportedMediaFile(path: event.path)
                }
                if !mediaEvents.isEmpty {
                    self.scheduleIncrementalScan(changedPaths: mediaEvents.map(\.path))
                }
            }
        }
    }

    public func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        monitor?.stop()
        monitor = nil
        isMonitoring = false
    }

    public func clearPending() {
        pendingClusters = []
        pendingBytes = 0
    }

    // MARK: - Private

    private func scheduleIncrementalScan(changedPaths: [String]) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, let config = self.configuration else { return }

            await self.runIncrementalScan(changedPaths: changedPaths, configuration: config)
        }
    }

    private func runIncrementalScan(changedPaths: [String], configuration: DeduplicateConfiguration) async {
        let stream = scanner.scan(configuration: configuration)
        do {
            for try await event in stream {
                if case .clusterDiscovered(let cluster) = event {
                    pendingClusters.append(cluster)
                    pendingBytes += cluster.bytesIfPruned
                }
            }
        } catch {
            // Incremental scans are best-effort; log but don't surface errors.
        }
    }
}

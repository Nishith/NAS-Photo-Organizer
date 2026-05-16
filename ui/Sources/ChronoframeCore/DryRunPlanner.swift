import Foundation

public struct DryRunPlanningResult: Equatable, Sendable {
    public var discoveredSourceCount: Int
    public var destinationIndexedCount: Int
    public var sourceHashedCount: Int
    public var copyPlan: CopyPlanResult
    public var previewReviewItems: [PreviewReviewItem]
    public var previewReviewSummary: PreviewReviewSummary
    public var phaseSequence: [String]
    public var completeStatus: String

    public init(
        discoveredSourceCount: Int,
        destinationIndexedCount: Int,
        sourceHashedCount: Int,
        copyPlan: CopyPlanResult,
        previewReviewItems: [PreviewReviewItem] = [],
        phaseSequence: [String] = Self.pythonReferencePhaseSequence,
        completeStatus: String = Self.dryRunFinishedStatus
    ) {
        self.discoveredSourceCount = discoveredSourceCount
        self.destinationIndexedCount = destinationIndexedCount
        self.sourceHashedCount = sourceHashedCount
        self.copyPlan = copyPlan
        self.previewReviewItems = previewReviewItems
        self.previewReviewSummary = PreviewReviewSummary(items: previewReviewItems)
        self.phaseSequence = phaseSequence
        self.completeStatus = completeStatus
    }

    public var copyJobs: [CopyJobRecord] {
        copyPlan.copyJobs
    }

    public var transfers: [PlannedTransfer] {
        copyPlan.transfers
    }

    public var transferCount: Int {
        copyPlan.transferCount
    }

    public var counts: CopyPlanCounts {
        copyPlan.counts
    }

    public var warningMessages: [String] {
        copyPlan.warningMessages
    }

    public var infoMessages: [String] {
        copyPlan.infoMessages
    }

    public var dateHistogram: [DateHistogramBucket] {
        copyPlan.dateHistogram
    }

    public static let dryRunFinishedStatus = "dry_run_finished"

    public static let pythonReferencePhaseSequence = [
        "startup",
        "discovery:start",
        "discovery:complete",
        "dest_hash:start",
        "dest_hash:complete",
        "src_hash:start",
        "src_hash:complete",
        "classification:start",
        "classification:complete",
        "copy_plan_ready",
        "complete",
    ]
}

public struct DryRunPlanner: Sendable {
    public var fileHasher: FileIdentityHasher
    public var dateResolver: FileDateResolver

    public init(
        fileHasher: FileIdentityHasher = FileIdentityHasher(),
        dateResolver: FileDateResolver = FileDateResolver()
    ) {
        self.fileHasher = fileHasher
        self.dateResolver = dateResolver
    }

    /// Number of files processed between incremental progress events during planning.
    /// Low enough for responsive UI on slow volumes; high enough to avoid event flood.
    public static let planningProgressStride = 100

    public func plan(
        sourceRoot: URL,
        destinationRoot: URL,
        databaseURL: URL? = nil,
        workerCount: Int = 1,
        namingRules: PlannerNamingRules = .pythonReference,
        folderStructure: FolderStructure = .yyyyMMDD,
        eventSuggestionMode: EventSuggestionMode = .off,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        /// Called with incremental `RunEvent`s while the walks are in progress.
        /// Allows callers to stream progress to the UI without waiting for `plan()` to return.
        onEvent: (@Sendable (RunEvent) -> Void)? = nil
    ) throws -> DryRunPlanningResult {
        let organizerDatabaseURL = databaseURL
            ?? destinationRoot.appendingPathComponent(EngineArtifactLayout.pythonReference.queueDatabaseFilename)
        let database = try OrganizerDatabase(url: organizerDatabaseURL)
        defer { database.close() }

        try Self.throwIfCancelled(isCancelled)
        onEvent?(.phaseStarted(phase: .discovery, total: nil))
        let sourcePaths = try MediaDiscovery.discoverMediaFiles(
            at: sourceRoot,
            isCancelled: isCancelled,
            onDirectoryIssue: { issue in
                onEvent?(.issue(RunIssue(severity: .warning, message: issue.message)))
            }
        )
        let discoveredSourceCount = sourcePaths.count
        onEvent?(.phaseCompleted(phase: .discovery, result: RunPhaseResult(found: discoveredSourceCount)))
        try Self.throwIfCancelled(isCancelled)

        let destinationIndex = try buildDestinationIndex(
            destinationRoot: destinationRoot,
            database: database,
            workerCount: workerCount,
            namingRules: namingRules,
            isCancelled: isCancelled,
            onEvent: onEvent
        )

        let sourceCacheByPath = try loadTypedCacheRecordsByPath(namespace: .source, database: database)
        let reviewOverrides = try database.loadReviewOverrides()
        let reviewOverridesByKey = Dictionary(
            uniqueKeysWithValues: reviewOverrides.map { (Self.reviewOverrideKey(identity: $0.identity, sourcePath: $0.sourcePath), $0) }
        )
        let reviewOverridesByIdentity = Dictionary(grouping: reviewOverrides) { $0.identity }
        let planningSpool = try PlanningSpool()
        var counts = CopyPlanCounts()
        var sourceSeen: Set<FileIdentity> = []
        var planningErrors: [String] = []
        var reviewItemsBySourcePath: [String: PreviewReviewItem] = [:]
        var eventCandidates: [EventSuggestionCandidate] = []

        onEvent?(.phaseStarted(phase: .sourceHashing, total: sourcePaths.count))
        let sourceCheckpoint = FileCacheCheckpointWriter(namespace: .source, database: database)
        let sourceResults = try processFiles(
            sourcePaths,
            cachedRowsByPath: sourceCacheByPath,
            workerCount: workerCount,
            phase: .sourceHashing,
            total: sourcePaths.count,
            checkpoint: sourceCheckpoint,
            isCancelled: isCancelled,
            onEvent: onEvent
        )

        for (index, path) in sourcePaths.enumerated() {
            try Self.throwIfCancelled(isCancelled)
            let result = sourceResults[index]
            let resolvedWithoutOverride = dateResolver.resolveResolvedDate(for: path)

            guard let identity = result.identity else {
                counts.hashErrorCount += 1
                reviewItemsBySourcePath[path] = PreviewReviewItem(
                    sourcePath: path,
                    identityRawValue: nil,
                    resolvedDate: resolvedWithoutOverride.date,
                    dateSource: resolvedWithoutOverride.source,
                    dateConfidence: resolvedWithoutOverride.confidence,
                    plannedDestinationPath: nil,
                    status: .hashError,
                    issues: Self.reviewIssues(
                        for: resolvedWithoutOverride,
                        status: .hashError
                    )
                )
                continue
            }

            let override = reviewOverridesByKey[Self.reviewOverrideKey(identity: identity, sourcePath: path)]
                ?? Self.identityOnlyOverride(identity: identity, overridesByIdentity: reviewOverridesByIdentity)
            let resolvedDate = resolvedWithoutOverride.applying(override)
            let dateBucket = DateClassification.bucket(
                for: resolvedDate.date,
                namingRules: namingRules
            )
            let acceptedEventName = ReviewOverride.normalizedEventName(override?.eventName)

            if eventSuggestionMode == .suggest,
               let capturedAt = resolvedDate.date,
               dateBucket != namingRules.unknownDateDirectoryName,
               acceptedEventName == nil {
                eventCandidates.append(
                    EventSuggestionCandidate(
                        sourcePath: path,
                        sourceRoot: sourceRoot.path,
                        capturedAt: capturedAt,
                        dateBucket: dateBucket
                    )
                )
            }

            if let existingDestinationPath = destinationIndex.snapshot.pathsByIdentity[identity] {
                counts.alreadyInDestinationCount += 1
                reviewItemsBySourcePath[path] = PreviewReviewItem(
                    sourcePath: path,
                    identityRawValue: identity.rawValue,
                    resolvedDate: resolvedDate.date,
                    dateSource: resolvedDate.source,
                    dateConfidence: resolvedDate.confidence,
                    plannedDestinationPath: existingDestinationPath,
                    status: .alreadyInDestination,
                    issues: Self.reviewIssues(
                        for: resolvedDate,
                        status: .alreadyInDestination
                    ),
                    acceptedEventName: acceptedEventName
                )
                continue
            }

            if !sourceSeen.insert(identity).inserted {
                do {
                    try planningSpool.appendDuplicate(
                        sourcePath: path,
                        identity: identity,
                        dateBucket: dateBucket,
                        eventNameOverride: acceptedEventName
                    )
                    counts.duplicateCount += 1
                    reviewItemsBySourcePath[path] = PreviewReviewItem(
                        sourcePath: path,
                        identityRawValue: identity.rawValue,
                        resolvedDate: resolvedDate.date,
                        dateSource: resolvedDate.source,
                        dateConfidence: resolvedDate.confidence,
                        plannedDestinationPath: nil,
                        status: .duplicate,
                        issues: Self.reviewIssues(
                            for: resolvedDate,
                            status: .duplicate
                        ),
                        acceptedEventName: acceptedEventName
                    )
                } catch {
                    planningErrors.append("Failed to plan duplicate file: \(path) (\(error.localizedDescription))")
                }
                continue
            }

            do {
                try planningSpool.appendPrimary(
                    sourcePath: path,
                    identity: identity,
                    dateBucket: dateBucket,
                    eventNameOverride: acceptedEventName
                )
                counts.newCount += 1
                reviewItemsBySourcePath[path] = PreviewReviewItem(
                    sourcePath: path,
                    identityRawValue: identity.rawValue,
                    resolvedDate: resolvedDate.date,
                    dateSource: resolvedDate.source,
                    dateConfidence: resolvedDate.confidence,
                    plannedDestinationPath: nil,
                    status: .ready,
                    issues: Self.reviewIssues(
                        for: resolvedDate,
                        status: .ready
                    ),
                    acceptedEventName: acceptedEventName
                )
            } catch {
                planningErrors.append("Failed to plan file: \(path) (\(error.localizedDescription))")
            }
        }

        onEvent?(.phaseCompleted(phase: .sourceHashing, result: RunPhaseResult(found: discoveredSourceCount)))

        var primarySequences = destinationIndex.snapshot.sequenceState.primaryByDate
        var duplicateSequences = destinationIndex.snapshot.sequenceState.duplicatesByDate
        var overflowDates: Set<String> = []
        var infoMessages: [String] = []
        var transfers: [PlannedTransfer] = []

        for dateBucket in planningSpool.primaryDateBuckets.sorted() {
            try Self.throwIfCancelled(isCancelled)
            let groupedFileTotal = planningSpool.primaryCount(for: dateBucket)
            let existingMaxSequence = primarySequences[dateBucket] ?? 0
            let startSequence = existingMaxSequence + 1
            let dayWidth = CopyPlanBuilder.plannedSequenceWidth(
                existingMaxSequence: existingMaxSequence,
                newItemCount: groupedFileTotal,
                defaultWidth: namingRules.sequenceWidth
            )

            if CopyPlanBuilder.shouldWarnAboutSequenceWidth(
                existingMaxSequence: existingMaxSequence,
                plannedWidth: dayWidth,
                defaultWidth: namingRules.sequenceWidth
            ) {
                overflowDates.insert(dateBucket)
            } else if CopyPlanBuilder.shouldEmitSequenceWidthInfo(
                existingMaxSequence: existingMaxSequence,
                plannedWidth: dayWidth,
                defaultWidth: namingRules.sequenceWidth
            ) {
                infoMessages.append(
                    CopyPlanBuilder.sequenceWidthInfoMessage(
                        dateBucket: dateBucket,
                        count: groupedFileTotal,
                        width: dayWidth
                    )
                )
            }

            var groupedFileCount = 0

            try planningSpool.enumeratePrimaryRecords(for: dateBucket) { record in
                try Self.throwIfCancelled(isCancelled)
                groupedFileCount += 1
                let sequence = startSequence + groupedFileCount - 1

                transfers.append(
                    PlannedTransfer(
                        sourcePath: record.sourcePath,
                        destinationPath: PlanningPathBuilder.buildDestinationPath(
                            for: record.sourcePath,
                            destinationRoot: destinationRoot.path,
                            dateBucket: dateBucket,
                            sequence: sequence,
                            duplicateDirectoryName: nil,
                            namingRules: namingRules,
                            folderStructure: folderStructure,
                            sourceRoot: sourceRoot.path,
                            eventNameOverride: record.eventNameOverride,
                            minimumSequenceWidth: dayWidth
                        ),
                        identity: record.identity,
                        dateBucket: dateBucket,
                        isDuplicate: false
                    )
                )
            }

            if groupedFileCount > 0 {
                primarySequences[dateBucket] = startSequence + groupedFileCount - 1
            }
        }

        for dateBucket in planningSpool.duplicateDateBuckets.sorted() {
            try Self.throwIfCancelled(isCancelled)
            let groupedFileCount = planningSpool.duplicateCount(for: dateBucket)
            let existingMaxSequence = duplicateSequences[dateBucket] ?? 0
            let startSequence = existingMaxSequence + 1
            let dayWidth = CopyPlanBuilder.plannedSequenceWidth(
                existingMaxSequence: existingMaxSequence,
                newItemCount: groupedFileCount,
                defaultWidth: namingRules.sequenceWidth
            )
            var plannedCount = 0

            try planningSpool.enumerateDuplicateRecords(for: dateBucket) { duplicate in
                try Self.throwIfCancelled(isCancelled)
                plannedCount += 1
                let sequence = startSequence + plannedCount - 1

                transfers.append(
                    PlannedTransfer(
                        sourcePath: duplicate.sourcePath,
                        destinationPath: PlanningPathBuilder.buildDestinationPath(
                            for: duplicate.sourcePath,
                            destinationRoot: destinationRoot.path,
                            dateBucket: dateBucket,
                            sequence: sequence,
                            duplicateDirectoryName: namingRules.duplicateDirectoryName,
                            namingRules: namingRules,
                            folderStructure: folderStructure,
                            sourceRoot: sourceRoot.path,
                            eventNameOverride: duplicate.eventNameOverride,
                            minimumSequenceWidth: dayWidth
                        ),
                        identity: duplicate.identity,
                        dateBucket: dateBucket,
                        isDuplicate: true
                    )
                )
            }

            if plannedCount > 0 {
                duplicateSequences[dateBucket] = startSequence + plannedCount - 1
            }
        }

        let sortedOverflowDates = overflowDates.sorted()
        var warningMessages = sortedOverflowDates.isEmpty
            ? [String]()
            : [
                "Sequence overflow on dates (>\(PlanningPathBuilder.maxSequence(for: namingRules.sequenceWidth)) files/day): \(sortedOverflowDates.joined(separator: ", "))",
            ]

        if !planningErrors.isEmpty {
            warningMessages.append(contentsOf: planningErrors)
        }

        for transfer in transfers {
            guard var item = reviewItemsBySourcePath[transfer.sourcePath] else { continue }
            item.plannedDestinationPath = transfer.destinationPath
            reviewItemsBySourcePath[transfer.sourcePath] = item
        }

        if eventSuggestionMode == .suggest {
            try Self.throwIfCancelled(isCancelled)
            let suggestions = EventSuggestionEngine.suggestions(for: eventCandidates)
            for (sourcePath, suggestion) in suggestions {
                try Self.throwIfCancelled(isCancelled)
                guard var item = reviewItemsBySourcePath[sourcePath] else { continue }
                item.eventSuggestion = suggestion
                reviewItemsBySourcePath[sourcePath] = item
            }
        }

        let reviewItems = sourcePaths.compactMap { reviewItemsBySourcePath[$0] }

        return DryRunPlanningResult(
            discoveredSourceCount: discoveredSourceCount,
            destinationIndexedCount: destinationIndex.indexedFileCount,
            sourceHashedCount: discoveredSourceCount,
            copyPlan: CopyPlanResult(
                transfers: transfers,
                counts: counts,
                warningMessages: warningMessages,
                sequenceState: SequenceCounterState(
                    primaryByDate: primarySequences,
                    duplicatesByDate: duplicateSequences
                ),
                infoMessages: infoMessages,
                dateHistogram: CopyPlanBuilder.dateHistogram(from: transfers, namingRules: namingRules)
            ),
            previewReviewItems: reviewItems
        )
    }

    private static func reviewOverrideKey(identity: FileIdentity, sourcePath: String) -> String {
        "\(identity.rawValue)\u{1F}\(sourcePath)"
    }

    private static func identityOnlyOverride(
        identity: FileIdentity,
        overridesByIdentity: [FileIdentity: [ReviewOverride]]
    ) -> ReviewOverride? {
        let overrides = overridesByIdentity[identity] ?? []
        return overrides.count == 1 ? overrides[0] : nil
    }

    private static func reviewIssues(
        for resolvedDate: ResolvedMediaDate,
        status: PreviewReviewStatus
    ) -> [PreviewReviewIssueKind] {
        var issues: [PreviewReviewIssueKind] = []
        if resolvedDate.date == nil {
            issues.append(.unknownDate)
        } else if resolvedDate.confidence == .low {
            issues.append(.lowConfidenceDate)
        }

        switch status {
        case .ready:
            break
        case .alreadyInDestination:
            issues.append(.alreadyInDestination)
        case .duplicate:
            issues.append(.duplicate)
        case .hashError:
            issues.append(.hashError)
        }
        return issues
    }

    private func buildDestinationIndex(
        destinationRoot: URL,
        database: OrganizerDatabase,
        workerCount: Int,
        namingRules: PlannerNamingRules,
        isCancelled: @escaping @Sendable () -> Bool,
        onEvent: (@Sendable (RunEvent) -> Void)? = nil
    ) throws -> DestinationIndexBuildResult {
        let cachedRowsByPath = try loadTypedCacheRecordsByPath(namespace: .destination, database: database)
        var snapshotBuilder = DestinationIndexSnapshotBuilder(namingRules: namingRules)
        var indexedFileCount = 0

        let destinationPaths = try MediaDiscovery.discoverMediaFiles(
            at: destinationRoot,
            isCancelled: isCancelled,
            onDirectoryIssue: { issue in
                onEvent?(.issue(RunIssue(severity: .warning, message: issue.message)))
            }
        )
        onEvent?(.phaseStarted(phase: .destinationIndexing, total: destinationPaths.count))
        let destinationCheckpoint = FileCacheCheckpointWriter(namespace: .destination, database: database)
        let destinationResults = try processFiles(
            destinationPaths,
            cachedRowsByPath: cachedRowsByPath,
            workerCount: workerCount,
            phase: .destinationIndexing,
            total: destinationPaths.count,
            checkpoint: destinationCheckpoint,
            isCancelled: isCancelled,
            onEvent: onEvent
        )

        for (index, path) in destinationPaths.enumerated() {
            try Self.throwIfCancelled(isCancelled)
            indexedFileCount += 1
            let result = destinationResults[index]
            snapshotBuilder.consume(path: path, identity: result.identity)
        }

        onEvent?(.phaseCompleted(phase: .destinationIndexing, result: RunPhaseResult()))

        return DestinationIndexBuildResult(
            indexedFileCount: indexedFileCount,
            snapshot: snapshotBuilder.snapshot
        )
    }

    private func processFiles(
        _ paths: [String],
        cachedRowsByPath: [String: FileCacheRecord],
        workerCount: Int,
        phase: RunPhase,
        total: Int,
        checkpoint: FileCacheCheckpointWriter? = nil,
        isCancelled: @escaping @Sendable () -> Bool,
        onEvent: (@Sendable (RunEvent) -> Void)?
    ) throws -> [ProcessedFileIdentity] {
        guard !paths.isEmpty else {
            return []
        }

        let maxWorkers = max(1, workerCount)
        if maxWorkers == 1 || paths.count == 1 {
            var results: [ProcessedFileIdentity] = []
            results.reserveCapacity(paths.count)
            for (index, path) in paths.enumerated() {
                try Self.throwIfCancelled(isCancelled)
                let result = fileHasher.processFile(at: path, cachedRecord: cachedRowsByPath[path])
                checkpoint?.append(path: path, result: result)
                try checkpoint?.throwIfNeeded()
                results.append(result)
                let completed = index + 1
                if completed % Self.planningProgressStride == 0 || completed == total {
                    onEvent?(.phaseProgress(phase: phase, completed: completed,
                                            total: total, bytesCopied: nil, bytesTotal: nil))
                }
            }
            try checkpoint?.finish()
            return results
        }

        let results = OrderedFileProcessingResults(count: paths.count)
        let queue = OperationQueue()
        queue.name = "Chronoframe.DryRunPlanner.\(phase.rawValue)"
        queue.maxConcurrentOperationCount = maxWorkers

        for (index, path) in paths.enumerated() {
            let cachedRecord = cachedRowsByPath[path]
            let fileHasher = self.fileHasher
            queue.addOperation {
                guard checkpoint?.hasError != true, !isCancelled() else {
                    queue.cancelAllOperations()
                    return
                }
                let result = fileHasher.processFile(at: path, cachedRecord: cachedRecord)
                checkpoint?.append(path: path, result: result)
                if checkpoint?.hasError == true || isCancelled() {
                    queue.cancelAllOperations()
                }
                let completed = results.store(result, at: index)
                if completed % Self.planningProgressStride == 0 || completed == total {
                    onEvent?(.phaseProgress(phase: phase, completed: completed,
                                            total: total, bytesCopied: nil, bytesTotal: nil))
                }
            }
        }

        queue.waitUntilAllOperationsAreFinished()
        try Self.throwIfCancelled(isCancelled)
        try checkpoint?.finish()
        return results.values()
    }

    private func loadTypedCacheRecordsByPath(
        namespace: CacheNamespace,
        database: OrganizerDatabase
    ) throws -> [String: FileCacheRecord] {
        var recordsByPath: [String: FileCacheRecord] = [:]
        try database.enumerateRawCacheRecordBatches(namespace: namespace) { batch in
            for rawRecord in batch {
                if let typedRecord = rawRecord.typedRecord {
                    recordsByPath[rawRecord.path] = typedRecord
                }
            }
        }
        return recordsByPath
    }

    private static func throwIfCancelled(_ isCancelled: @Sendable () -> Bool) throws {
        if isCancelled() {
            throw CancellationError()
        }
    }
}

private struct DestinationIndexBuildResult {
    var indexedFileCount: Int
    var snapshot: DestinationIndexSnapshot
}

private final class FileCacheCheckpointWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let namespace: CacheNamespace
    private let database: OrganizerDatabase
    private let batchSize: Int
    private var pending: [FileCacheRecord] = []
    private var error: Error?

    init(namespace: CacheNamespace, database: OrganizerDatabase, batchSize: Int = 512) {
        self.namespace = namespace
        self.database = database
        self.batchSize = max(1, batchSize)
        pending.reserveCapacity(self.batchSize)
    }

    var hasError: Bool {
        lock.lock()
        let hasError = error != nil
        lock.unlock()
        return hasError
    }

    func append(path: String, result: ProcessedFileIdentity) {
        guard let identity = result.identity, result.wasHashed else { return }

        lock.lock()
        defer { lock.unlock() }

        guard error == nil else { return }

        pending.append(
            FileCacheRecord(
                namespace: namespace,
                path: path,
                identity: identity,
                size: result.size,
                modificationTime: result.modificationTime
            )
        )

        guard pending.count >= batchSize else { return }
        do {
            try savePendingLocked()
        } catch {
            self.error = error
        }
    }

    func throwIfNeeded() throws {
        lock.lock()
        let storedError = error
        lock.unlock()
        if let storedError {
            throw storedError
        }
    }

    func finish() throws {
        lock.lock()
        defer { lock.unlock() }

        if let error {
            throw error
        }

        do {
            try savePendingLocked()
        } catch {
            self.error = error
            throw error
        }
    }

    private func savePendingLocked() throws {
        guard !pending.isEmpty else { return }
        try database.saveCacheRecords(pending)
        pending.removeAll(keepingCapacity: true)
    }
}

private struct DestinationIndexSnapshotBuilder {
    private let namingRules: PlannerNamingRules
    // Compile-time constant pattern — try! ensures a typo crashes loudly at
    // startup rather than silently disabling sequence-number tracking.
    private let filenamePattern = try! NSRegularExpression(pattern: #"^(\d{4}-\d{2}-\d{2}|Unknown)_(\d+)"#)

    private(set) var pathsByIdentity: [FileIdentity: String] = [:]
    private(set) var primaryByDate: [String: Int] = [:]
    private(set) var duplicatesByDate: [String: Int] = [:]

    init(namingRules: PlannerNamingRules) {
        self.namingRules = namingRules
    }

    mutating func consume(path: String, identity: FileIdentity?) {
        if let identity {
            pathsByIdentity[identity] = path
        }

        let filename = URL(fileURLWithPath: path).lastPathComponent
        let searchRange = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        guard let match = filenamePattern.firstMatch(in: filename, range: searchRange) else {
            return
        }

        guard
            let prefixRange = Range(match.range(at: 1), in: filename),
            let sequenceRange = Range(match.range(at: 2), in: filename),
            let sequence = Int(filename[sequenceRange])
        else {
            return
        }

        let dateBucket = String(filename[prefixRange]) == "Unknown"
            ? namingRules.unknownDateDirectoryName
            : String(filename[prefixRange])
        let isDuplicate = URL(fileURLWithPath: path).pathComponents.contains(namingRules.duplicateDirectoryName)

        if isDuplicate {
            duplicatesByDate[dateBucket] = max(duplicatesByDate[dateBucket] ?? 0, sequence)
        } else {
            primaryByDate[dateBucket] = max(primaryByDate[dateBucket] ?? 0, sequence)
        }
    }

    var snapshot: DestinationIndexSnapshot {
        DestinationIndexSnapshot(
            pathsByIdentity: pathsByIdentity,
            sequenceState: SequenceCounterState(
                primaryByDate: primaryByDate,
                duplicatesByDate: duplicatesByDate
            )
        )
    }
}

private final class OrderedFileProcessingResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ProcessedFileIdentity?]
    private var completedCount = 0

    init(count: Int) {
        storage = Array(repeating: nil, count: count)
    }

    func store(_ result: ProcessedFileIdentity, at index: Int) -> Int {
        lock.lock()
        storage[index] = result
        completedCount += 1
        let completed = completedCount
        lock.unlock()
        return completed
    }

    func values() -> [ProcessedFileIdentity] {
        lock.lock()
        let values = storage.map {
            $0 ?? ProcessedFileIdentity(identity: nil, size: 0, modificationTime: 0, wasHashed: false)
        }
        lock.unlock()
        return values
    }
}

private enum PlanningSpoolError: Error {
    case invalidRecord(String)
}

private struct PrimaryPlanningRecord {
    var sourcePath: String
    var identity: FileIdentity
    var eventNameOverride: String?
}

private struct DuplicatePlanningRecord {
    var sourcePath: String
    var identity: FileIdentity
    var eventNameOverride: String?
}

private final class PlanningSpool {
    private let directoryURL: URL
    private let fileManager: FileManager

    private var primaryHandlesByDateBucket: [String: FileHandle] = [:]
    private var primaryURLsByDateBucket: [String: URL] = [:]
    private var primaryCountsByDateBucket: [String: Int] = [:]
    private var duplicateHandlesByDateBucket: [String: FileHandle] = [:]
    private var duplicateURLsByDateBucket: [String: URL] = [:]
    private var duplicateCountsByDateBucket: [String: Int] = [:]
    private var sealed = false

    init(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws {
        self.fileManager = fileManager
        self.directoryURL = temporaryDirectory.appendingPathComponent(
            "ChronoframePlanning-\(UUID().uuidString)",
            isDirectory: true
        )

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    deinit {
        try? closeOpenHandles()
        try? fileManager.removeItem(at: directoryURL)
    }

    var primaryDateBuckets: [String] {
        Array(primaryCountsByDateBucket.keys)
    }

    var duplicateDateBuckets: [String] {
        Array(duplicateCountsByDateBucket.keys)
    }

    func primaryCount(for dateBucket: String) -> Int {
        primaryCountsByDateBucket[dateBucket] ?? 0
    }

    func duplicateCount(for dateBucket: String) -> Int {
        duplicateCountsByDateBucket[dateBucket] ?? 0
    }

    func appendPrimary(
        sourcePath: String,
        identity: FileIdentity,
        dateBucket: String,
        eventNameOverride: String?
    ) throws {
        let handle = try primaryHandle(for: dateBucket)
        try handle.write(contentsOf: encodeLine([sourcePath, identity.rawValue, eventNameOverride ?? ""]))
        primaryCountsByDateBucket[dateBucket, default: 0] += 1
    }

    func appendDuplicate(
        sourcePath: String,
        identity: FileIdentity,
        dateBucket: String,
        eventNameOverride: String?
    ) throws {
        let handle = try duplicateHandle(for: dateBucket)
        try handle.write(contentsOf: encodeLine([sourcePath, identity.rawValue, eventNameOverride ?? ""]))
        duplicateCountsByDateBucket[dateBucket, default: 0] += 1
    }

    func enumeratePrimaryRecords(
        for dateBucket: String,
        _ body: (PrimaryPlanningRecord) throws -> Void
    ) throws {
        try sealIfNeeded()
        guard let url = primaryURLsByDateBucket[dateBucket] else {
            return
        }

        try Self.enumerateLines(at: url) { line in
            let fields = try decodeFields(from: line, expectedCount: 3)
            guard let identity = FileIdentity(rawValue: fields[1]) else {
                throw PlanningSpoolError.invalidRecord(line)
            }
            try body(
                PrimaryPlanningRecord(
                    sourcePath: fields[0],
                    identity: identity,
                    eventNameOverride: ReviewOverride.normalizedEventName(fields[2])
                )
            )
        }
    }

    func enumerateDuplicateRecords(
        for dateBucket: String,
        _ body: (DuplicatePlanningRecord) throws -> Void
    ) throws {
        try sealIfNeeded()
        guard let url = duplicateURLsByDateBucket[dateBucket] else {
            return
        }

        try Self.enumerateLines(at: url) { line in
            let fields = try decodeFields(from: line, expectedCount: 3)
            guard let identity = FileIdentity(rawValue: fields[1]) else {
                throw PlanningSpoolError.invalidRecord(line)
            }
            try body(
                DuplicatePlanningRecord(
                    sourcePath: fields[0],
                    identity: identity,
                    eventNameOverride: ReviewOverride.normalizedEventName(fields[2])
                )
            )
        }
    }

    private func evictHandlesIfNeeded() throws {
        if primaryHandlesByDateBucket.count + duplicateHandlesByDateBucket.count >= 100 {
            try closeOpenHandles()
        }
    }

    private func primaryHandle(for dateBucket: String) throws -> FileHandle {
        if let handle = primaryHandlesByDateBucket[dateBucket] {
            return handle
        }

        try evictHandlesIfNeeded()

        if let fileURL = primaryURLsByDateBucket[dateBucket] {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            primaryHandlesByDateBucket[dateBucket] = handle
            return handle
        }

        let fileURL = directoryURL.appendingPathComponent("primary_\(primaryURLsByDateBucket.count).tsv")
        fileManager.createFile(atPath: fileURL.path, contents: Data())
        let handle = try FileHandle(forWritingTo: fileURL)
        primaryHandlesByDateBucket[dateBucket] = handle
        primaryURLsByDateBucket[dateBucket] = fileURL
        return handle
    }

    private func duplicateHandle(for dateBucket: String) throws -> FileHandle {
        if let handle = duplicateHandlesByDateBucket[dateBucket] {
            return handle
        }

        try evictHandlesIfNeeded()

        if let fileURL = duplicateURLsByDateBucket[dateBucket] {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            duplicateHandlesByDateBucket[dateBucket] = handle
            return handle
        }

        let fileURL = directoryURL.appendingPathComponent("duplicate_\(duplicateURLsByDateBucket.count).tsv")
        fileManager.createFile(atPath: fileURL.path, contents: Data())
        let handle = try FileHandle(forWritingTo: fileURL)
        duplicateHandlesByDateBucket[dateBucket] = handle
        duplicateURLsByDateBucket[dateBucket] = fileURL
        return handle
    }

    private func sealIfNeeded() throws {
        guard !sealed else {
            return
        }
        try closeOpenHandles()
        sealed = true
    }

    private func closeOpenHandles() throws {
        for handle in primaryHandlesByDateBucket.values {
            try handle.close()
        }
        primaryHandlesByDateBucket.removeAll()

        for handle in duplicateHandlesByDateBucket.values {
            try handle.close()
        }
        duplicateHandlesByDateBucket.removeAll()
    }

    private func encodeLine(_ fields: [String]) -> Data {
        let encodedFields = fields.map { Data($0.utf8).base64EncodedString() }
        return Data((encodedFields.joined(separator: "\t") + "\n").utf8)
    }

    private func decodeFields(from line: String, expectedCount: Int) throws -> [String] {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count == expectedCount else {
            throw PlanningSpoolError.invalidRecord(line)
        }

        return try parts.map { part in
            guard
                let data = Data(base64Encoded: String(part)),
                let string = String(data: data, encoding: .utf8)
            else {
                throw PlanningSpoolError.invalidRecord(line)
            }
            return string
        }
    }

    private static func enumerateLines(
        at url: URL,
        _ body: (String) throws -> Void
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        var remainder = Data()

        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty {
                break
            }

            remainder.append(chunk)

            var searchRange: Range<Data.Index> = remainder.startIndex..<remainder.endIndex
            while let newlineIndex = remainder[searchRange].firstIndex(of: 0x0A) {
                let lineData = remainder[searchRange.lowerBound..<newlineIndex]
                if !lineData.isEmpty {
                    try body(String(decoding: lineData, as: UTF8.self))
                }
                searchRange = (newlineIndex + 1)..<remainder.endIndex
            }
            remainder = Data(remainder[searchRange])
        }

        if !remainder.isEmpty {
            try body(String(decoding: remainder, as: UTF8.self))
        }
    }
}

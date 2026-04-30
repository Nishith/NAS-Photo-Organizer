import Foundation

public struct DryRunPlanningResult: Equatable, Sendable {
    public var discoveredSourceCount: Int
    public var destinationIndexedCount: Int
    public var sourceHashedCount: Int
    public var copyPlan: CopyPlanResult
    public var phaseSequence: [String]
    public var completeStatus: String

    public init(
        discoveredSourceCount: Int,
        destinationIndexedCount: Int,
        sourceHashedCount: Int,
        copyPlan: CopyPlanResult,
        phaseSequence: [String] = Self.pythonReferencePhaseSequence,
        completeStatus: String = Self.dryRunFinishedStatus
    ) {
        self.discoveredSourceCount = discoveredSourceCount
        self.destinationIndexedCount = destinationIndexedCount
        self.sourceHashedCount = sourceHashedCount
        self.copyPlan = copyPlan
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
        fastDestination: Bool = false,
        workerCount: Int = 1,
        namingRules: PlannerNamingRules = .pythonReference,
        folderStructure: FolderStructure = .yyyyMMDD,
        /// Called with incremental `RunEvent`s while the walks are in progress.
        /// Allows callers to stream progress to the UI without waiting for `plan()` to return.
        onEvent: (@Sendable (RunEvent) -> Void)? = nil
    ) throws -> DryRunPlanningResult {
        let organizerDatabaseURL = databaseURL
            ?? destinationRoot.appendingPathComponent(EngineArtifactLayout.pythonReference.queueDatabaseFilename)
        let database = try OrganizerDatabase(url: organizerDatabaseURL)
        defer { database.close() }

        let destinationIndex = try buildDestinationIndex(
            destinationRoot: destinationRoot,
            database: database,
            fastDestination: fastDestination,
            workerCount: workerCount,
            namingRules: namingRules,
            onEvent: onEvent
        )

        let sourceCacheByPath = try loadTypedCacheRecordsByPath(namespace: .source, database: database)
        let planningSpool = try PlanningSpool()
        var sourceUpdates: [FileCacheRecord] = []
        var discoveredSourceCount = 0
        var counts = CopyPlanCounts()
        var sourceSeen: Set<FileIdentity> = []

        onEvent?(.phaseStarted(phase: .sourceHashing, total: nil))

        let sourcePaths = try MediaDiscovery.discoverMediaFiles(at: sourceRoot)
        discoveredSourceCount = sourcePaths.count
        let sourceResults = processFiles(
            sourcePaths,
            cachedRowsByPath: sourceCacheByPath,
            workerCount: workerCount,
            phase: .sourceHashing,
            onEvent: onEvent
        )

        for (index, path) in sourcePaths.enumerated() {
            let result = sourceResults[index]

            if let identity = result.identity, result.wasHashed {
                sourceUpdates.append(
                    FileCacheRecord(
                        namespace: .source,
                        path: path,
                        identity: identity,
                        size: result.size,
                        modificationTime: result.modificationTime
                    )
                )
                if sourceUpdates.count >= 512 {
                    try database.saveCacheRecords(sourceUpdates)
                    sourceUpdates.removeAll(keepingCapacity: true)
                }
            }

            guard let identity = result.identity else {
                counts.hashErrorCount += 1
                continue
            }

            if destinationIndex.snapshot.pathsByIdentity[identity] != nil {
                counts.alreadyInDestinationCount += 1
                continue
            }

            let dateBucket = DateClassification.bucket(
                for: dateResolver.resolveDate(for: path),
                namingRules: namingRules
            )

            if !sourceSeen.insert(identity).inserted {
                try planningSpool.appendDuplicate(
                    sourcePath: path,
                    identity: identity,
                    dateBucket: dateBucket
                )
                counts.duplicateCount += 1
                continue
            }

            try planningSpool.appendPrimary(
                sourcePath: path,
                identity: identity,
                dateBucket: dateBucket
            )
            counts.newCount += 1
        }

        try database.saveCacheRecords(sourceUpdates)

        onEvent?(.phaseCompleted(phase: .sourceHashing, result: RunPhaseResult(found: discoveredSourceCount)))

        var primarySequences = destinationIndex.snapshot.sequenceState.primaryByDate
        var duplicateSequences = destinationIndex.snapshot.sequenceState.duplicatesByDate
        var overflowDates: Set<String> = []
        var infoMessages: [String] = []
        var transfers: [PlannedTransfer] = []

        for dateBucket in planningSpool.primaryDateBuckets.sorted() {
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
        let warningMessages = sortedOverflowDates.isEmpty
            ? []
            : [
                "Sequence overflow on dates (>\(PlanningPathBuilder.maxSequence(for: namingRules.sequenceWidth)) files/day): \(sortedOverflowDates.joined(separator: ", "))",
            ]

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
            )
        )
    }

    private func buildDestinationIndex(
        destinationRoot: URL,
        database: OrganizerDatabase,
        fastDestination: Bool,
        workerCount: Int,
        namingRules: PlannerNamingRules,
        onEvent: (@Sendable (RunEvent) -> Void)? = nil
    ) throws -> DestinationIndexBuildResult {
        onEvent?(.phaseStarted(phase: .destinationIndexing, total: nil))

        if fastDestination {
            var snapshotBuilder = DestinationIndexSnapshotBuilder(namingRules: namingRules)
            var indexedCount = 0
            try database.enumerateRawCacheRecordBatches(namespace: .destination) { batch in
                indexedCount += batch.count
                for row in batch {
                    snapshotBuilder.consume(path: row.path, identity: row.parsedIdentity)
                }
                if indexedCount % Self.planningProgressStride == 0 {
                    onEvent?(.phaseProgress(phase: .destinationIndexing, completed: indexedCount,
                                            total: 0, bytesCopied: nil, bytesTotal: nil))
                }
            }
            onEvent?(.phaseCompleted(phase: .destinationIndexing, result: RunPhaseResult()))
            return DestinationIndexBuildResult(
                indexedFileCount: indexedCount,
                snapshot: snapshotBuilder.snapshot
            )
        }

        let cachedRowsByPath = try loadTypedCacheRecordsByPath(namespace: .destination, database: database)
        var snapshotBuilder = DestinationIndexSnapshotBuilder(namingRules: namingRules)
        var destinationUpdates: [FileCacheRecord] = []
        var indexedFileCount = 0

        let destinationPaths = try MediaDiscovery.discoverMediaFiles(at: destinationRoot)
        let destinationResults = processFiles(
            destinationPaths,
            cachedRowsByPath: cachedRowsByPath,
            workerCount: workerCount,
            phase: .destinationIndexing,
            onEvent: onEvent
        )

        for (index, path) in destinationPaths.enumerated() {
            indexedFileCount += 1
            let result = destinationResults[index]
            snapshotBuilder.consume(path: path, identity: result.identity)

            if let identity = result.identity, result.wasHashed {
                destinationUpdates.append(
                    FileCacheRecord(
                        namespace: .destination,
                        path: path,
                        identity: identity,
                        size: result.size,
                        modificationTime: result.modificationTime
                    )
                )
                if destinationUpdates.count >= 512 {
                    try database.saveCacheRecords(destinationUpdates)
                    destinationUpdates.removeAll(keepingCapacity: true)
                }
            }
        }

        try database.saveCacheRecords(destinationUpdates)
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
        onEvent: (@Sendable (RunEvent) -> Void)?
    ) -> [ProcessedFileIdentity] {
        guard !paths.isEmpty else {
            return []
        }

        let maxWorkers = max(1, workerCount)
        if maxWorkers == 1 || paths.count == 1 {
            var results: [ProcessedFileIdentity] = []
            results.reserveCapacity(paths.count)
            for (index, path) in paths.enumerated() {
                results.append(fileHasher.processFile(at: path, cachedRecord: cachedRowsByPath[path]))
                let completed = index + 1
                if completed % Self.planningProgressStride == 0 {
                    onEvent?(.phaseProgress(phase: phase, completed: completed,
                                            total: 0, bytesCopied: nil, bytesTotal: nil))
                }
            }
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
                let result = fileHasher.processFile(at: path, cachedRecord: cachedRecord)
                let completed = results.store(result, at: index)
                if completed % Self.planningProgressStride == 0 {
                    onEvent?(.phaseProgress(phase: phase, completed: completed,
                                            total: 0, bytesCopied: nil, bytesTotal: nil))
                }
            }
        }

        queue.waitUntilAllOperationsAreFinished()
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
}

private struct DestinationIndexBuildResult {
    var indexedFileCount: Int
    var snapshot: DestinationIndexSnapshot
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
}

private struct DuplicatePlanningRecord {
    var sourcePath: String
    var identity: FileIdentity
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

    func appendPrimary(sourcePath: String, identity: FileIdentity, dateBucket: String) throws {
        let handle = try primaryHandle(for: dateBucket)
        try handle.write(contentsOf: encodeLine([sourcePath, identity.rawValue]))
        primaryCountsByDateBucket[dateBucket, default: 0] += 1
    }

    func appendDuplicate(sourcePath: String, identity: FileIdentity, dateBucket: String) throws {
        let handle = try duplicateHandle(for: dateBucket)
        try handle.write(contentsOf: encodeLine([sourcePath, identity.rawValue]))
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
            let fields = try decodeFields(from: line, expectedCount: 2)
            guard let identity = FileIdentity(rawValue: fields[1]) else {
                throw PlanningSpoolError.invalidRecord(line)
            }
            try body(
                PrimaryPlanningRecord(
                    sourcePath: fields[0],
                    identity: identity
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
            let fields = try decodeFields(from: line, expectedCount: 2)
            guard let identity = FileIdentity(rawValue: fields[1]) else {
                throw PlanningSpoolError.invalidRecord(line)
            }
            try body(
                DuplicatePlanningRecord(
                    sourcePath: fields[0],
                    identity: identity
                )
            )
        }
    }

    private func primaryHandle(for dateBucket: String) throws -> FileHandle {
        if let handle = primaryHandlesByDateBucket[dateBucket] {
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

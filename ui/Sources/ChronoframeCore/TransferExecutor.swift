import Darwin
import Foundation
import os

public struct TransferExecutionObserver: Sendable {
    public var onPhaseStarted: @Sendable (_ total: Int, _ bytesTotal: Int64) -> Void
    public var onPhaseProgress: @Sendable (_ completed: Int, _ total: Int, _ bytesCopied: Int64, _ bytesTotal: Int64) -> Void
    public var onIssue: @Sendable (_ issue: RunIssue) -> Void

    public init(
        onPhaseStarted: @escaping @Sendable (_ total: Int, _ bytesTotal: Int64) -> Void = { _, _ in },
        onPhaseProgress: @escaping @Sendable (_ completed: Int, _ total: Int, _ bytesCopied: Int64, _ bytesTotal: Int64) -> Void = { _, _, _, _ in },
        onIssue: @escaping @Sendable (_ issue: RunIssue) -> Void = { _ in }
    ) {
        self.onPhaseStarted = onPhaseStarted
        self.onPhaseProgress = onPhaseProgress
        self.onIssue = onIssue
    }
}

public struct TransferExecutionResult: Equatable, Sendable {
    public var copiedCount: Int
    public var failedCount: Int
    public var bytesCopied: Int64
    public var bytesTotal: Int64
    public var artifacts: RunArtifactPaths

    public init(
        copiedCount: Int,
        failedCount: Int,
        bytesCopied: Int64,
        bytesTotal: Int64,
        artifacts: RunArtifactPaths
    ) {
        self.copiedCount = copiedCount
        self.failedCount = failedCount
        self.bytesCopied = bytesCopied
        self.bytesTotal = bytesTotal
        self.artifacts = artifacts
    }
}

public final class PersistentRunLogger: @unchecked Sendable {
    public let logURL: URL

    // OSAllocatedUnfairLock guards all access to `handle`, making concurrent
    // open/close/append calls safe from multiple async contexts.
    private let lock = OSAllocatedUnfairLock<FileHandle?>(initialState: nil)

    public init(logURL: URL) {
        self.logURL = logURL
    }

    deinit {
        close()
    }

    public func open() throws {
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: Data())
        }

        let newHandle = try FileHandle(forWritingTo: logURL)
        try newHandle.seekToEnd()
        lock.withLock { $0 = newHandle }
    }

    public func close() {
        lock.withLock { handle in
            try? handle?.close()
            handle = nil
        }
    }

    public func log(_ message: String) {
        append(line: message)
    }

    public func warn(_ message: String) {
        append(line: "WARNING: \(message)")
    }

    public func error(_ message: String) {
        append(line: "ERROR: \(message)")
    }

    private func append(line: String) {
        let renderedLine = "[\(Self.timestampFormatter.string(from: Date()))] \(line)\n"
        guard let data = renderedLine.data(using: .utf8) else {
            return
        }

        lock.withLock { handle in
            try? handle?.write(contentsOf: data)
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

public struct TransferExecutor: Sendable {
    public static let orphanedTemporarySuffix = ".tmp"
    public static let safetyBufferBytes: Int64 = 10 * 1024 * 1024
    public static let maxCollisionCount = 9_999
    public static let destinationCacheBatchSize = 256

    public var fileHasher: FileIdentityHasher
    public var retryPolicy: RetryPolicy
    public var failureThresholds: FailureThresholds
    public var namingRules: PlannerNamingRules

    public init(
        fileHasher: FileIdentityHasher = FileIdentityHasher(),
        retryPolicy: RetryPolicy = .pythonReference,
        failureThresholds: FailureThresholds = .pythonReference,
        namingRules: PlannerNamingRules = .pythonReference
    ) {
        self.fileHasher = fileHasher
        self.retryPolicy = retryPolicy
        self.failureThresholds = failureThresholds
        self.namingRules = namingRules
    }

    public func artifactPaths(destinationRoot: URL) -> RunArtifactPaths {
        let logsDirectoryURL = destinationRoot.appendingPathComponent(
            EngineArtifactLayout.pythonReference.logsDirectoryName,
            isDirectory: true
        )
        let logURL = destinationRoot.appendingPathComponent(EngineArtifactLayout.pythonReference.runLogFilename)

        return RunArtifactPaths(
            destinationRoot: destinationRoot.path,
            reportPath: nil,
            logFilePath: logURL.path,
            logsDirectoryPath: logsDirectoryURL.path
        )
    }

    public func cleanupTemporaryFiles(at destinationRoot: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: destinationRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var cleanedCount = 0
        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent.hasSuffix(Self.orphanedTemporarySuffix) else {
                continue
            }

            do {
                try FileManager.default.removeItem(at: fileURL)
                cleanedCount += 1
            } catch {
                continue
            }
        }

        return cleanedCount
    }

    public func execute(
        queuedJobs: [QueuedCopyJob],
        database: OrganizerDatabase,
        destinationRoot: URL,
        verifyCopies: Bool,
        runLogger: PersistentRunLogger,
        observer: TransferExecutionObserver = TransferExecutionObserver(),
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> TransferExecutionResult {
        let totalJobs = queuedJobs.count
        let bytesTotal = queuedJobs.reduce(into: Int64(0)) { partialResult, job in
            partialResult += safeFileSize(atPath: job.sourcePath) ?? 0
        }
        let context = try TransferExecutionContext(
            executor: self,
            database: database,
            destinationRoot: destinationRoot,
            verifyCopies: verifyCopies,
            runLogger: runLogger,
            observer: observer,
            isCancelled: isCancelled,
            totalJobs: totalJobs,
            bytesTotal: bytesTotal
        )
        context.start()

        var attemptedJobs = 0
        for job in queuedJobs {
            if isCancelled() {
                break
            }

            attemptedJobs += 1
            let shouldContinue = try context.process(job: job, attemptedJobs: attemptedJobs)
            if !shouldContinue {
                break
            }
        }

        return try context.finish(attemptedJobs: attemptedJobs)
    }

    public func executeQueuedJobs(
        database: OrganizerDatabase,
        destinationRoot: URL,
        verifyCopies: Bool,
        runLogger: PersistentRunLogger,
        status: CopyJobStatus = .pending,
        orderByInsertion: Bool = true,
        batchSize: Int = 512,
        observer: TransferExecutionObserver = TransferExecutionObserver(),
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> TransferExecutionResult {
        let totalJobs = try database.queuedJobCount(status: status)
        let bytesTotal = try totalBytesForQueuedJobs(
            database: database,
            status: status,
            orderByInsertion: orderByInsertion,
            batchSize: batchSize
        )
        let context = try TransferExecutionContext(
            executor: self,
            database: database,
            destinationRoot: destinationRoot,
            verifyCopies: verifyCopies,
            runLogger: runLogger,
            observer: observer,
            isCancelled: isCancelled,
            totalJobs: totalJobs,
            bytesTotal: bytesTotal
        )
        context.start()

        var attemptedJobs = 0

        do {
            try database.enumerateQueuedJobBatches(
                status: status,
                orderByInsertion: orderByInsertion,
                batchSize: batchSize
            ) { batch in
                for job in batch {
                    if isCancelled() {
                        throw TransferExecutionStopSignal.stopRequested
                    }

                    attemptedJobs += 1
                    // Drain autoreleased URL/NSString/FileManager temporaries per job;
                    // across 14k+ copies this otherwise retains until the outer call returns.
                    let shouldContinue: Bool = try autoreleasepool {
                        try context.process(job: job, attemptedJobs: attemptedJobs)
                    }
                    if !shouldContinue {
                        throw TransferExecutionStopSignal.stopRequested
                    }
                }
            }
        } catch TransferExecutionStopSignal.stopRequested {
            // Stop requested via cancellation or abort threshold.
        }

        return try context.finish(attemptedJobs: attemptedJobs)
    }

    fileprivate func shouldAbort(
        consecutiveFailures: Int,
        totalFailures: Int,
        attemptedJobs: Int,
        runLogger: PersistentRunLogger
    ) -> Bool {
        guard
            consecutiveFailures >= failureThresholds.consecutive
                || totalFailures >= failureThresholds.total
        else {
            return false
        }

        let message = "Aborting: \(consecutiveFailures) consecutive failures (\(totalFailures) total out of \(attemptedJobs) attempted)"
        runLogger.error(message)
        return true
    }

    fileprivate func removeUnverifiedCopyIfNeeded(
        atPath path: String,
        runLogger: PersistentRunLogger
    ) {
        do {
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
        } catch {
            runLogger.warn("Failed to remove unverified copy: \(path): \(error.localizedDescription)")
        }
    }

    fileprivate func flushDestinationUpdates(
        _ updates: [RawFileCacheRecord],
        database: OrganizerDatabase
    ) throws {
        guard !updates.isEmpty else {
            return
        }

        try database.saveRawCacheRecords(updates)
    }

    fileprivate func safeCopyAtomic(
        sourcePath: String,
        requestedDestinationPath: String
    ) throws -> String {
        var lastError: Error?

        for attempt in 1...max(1, retryPolicy.maxAttempts) {
            do {
                return try safeCopyAtomicOnce(
                    sourcePath: sourcePath,
                    requestedDestinationPath: requestedDestinationPath
                )
            } catch {
                lastError = error
                guard shouldRetry(after: error), attempt < retryPolicy.maxAttempts else {
                    throw error
                }

                let backoff = min(
                    retryPolicy.maximumBackoffSeconds,
                    max(
                        retryPolicy.minimumBackoffSeconds,
                        pow(2, Double(attempt - 1)) * retryPolicy.minimumBackoffSeconds
                    )
                )
                Thread.sleep(forTimeInterval: backoff)
            }
        }

        throw lastError ?? CocoaError(.fileWriteUnknown)
    }

    private func safeCopyAtomicOnce(
        sourcePath: String,
        requestedDestinationPath: String
    ) throws -> String {
        let destinationURL = URL(fileURLWithPath: requestedDestinationPath)
        let destinationDirectoryURL = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destinationDirectoryURL, withIntermediateDirectories: true)
        try checkDiskSpace(sourcePath: sourcePath, destinationDirectoryPath: destinationDirectoryURL.path)

        let finalDestinationPath = try collisionResolvedPath(for: requestedDestinationPath)
        let temporaryDestinationPath = finalDestinationPath + Self.orphanedTemporarySuffix

        if FileManager.default.fileExists(atPath: temporaryDestinationPath) {
            try? FileManager.default.removeItem(atPath: temporaryDestinationPath)
        }

        do {
            try copyFileContents(from: sourcePath, to: temporaryDestinationPath)
            try fsyncFile(atPath: temporaryDestinationPath)
            try renameFile(from: temporaryDestinationPath, to: finalDestinationPath)
            return finalDestinationPath
        } catch {
            if FileManager.default.fileExists(atPath: temporaryDestinationPath) {
                try? FileManager.default.removeItem(atPath: temporaryDestinationPath)
            }
            throw error
        }
    }

    private func collisionResolvedPath(for requestedPath: String) throws -> String {
        if !FileManager.default.fileExists(atPath: requestedPath) {
            return requestedPath
        }

        let requestedURL = URL(fileURLWithPath: requestedPath)
        let destinationDirectoryURL = requestedURL.deletingLastPathComponent()
        let extensionName = requestedURL.pathExtension
        let basename = requestedURL.deletingPathExtension().lastPathComponent

        for collisionIndex in 1...Self.maxCollisionCount {
            let filename: String
            if extensionName.isEmpty {
                filename = "\(basename)\(namingRules.collisionSuffixPrefix)\(collisionIndex)"
            } else {
                filename = "\(basename)\(namingRules.collisionSuffixPrefix)\(collisionIndex).\(extensionName)"
            }

            let candidatePath = destinationDirectoryURL.appendingPathComponent(filename).path
            if !FileManager.default.fileExists(atPath: candidatePath) {
                return candidatePath
            }
        }

        throw posixError(code: EEXIST, description: "Too many collisions for destination path: \(requestedPath)")
    }

    private func checkDiskSpace(
        sourcePath: String,
        destinationDirectoryPath: String
    ) throws {
        guard let sourceSize = safeFileSize(atPath: sourcePath) else {
            return
        }

        var fileSystemStatus = statvfs()
        let result = destinationDirectoryPath.withCString { pointer in
            statvfs(pointer, &fileSystemStatus)
        }
        guard result == 0 else {
            return
        }

        let freeBytes = Int64(fileSystemStatus.f_bavail) * Int64(fileSystemStatus.f_frsize)
        if freeBytes < sourceSize + Self.safetyBufferBytes {
            throw posixError(
                code: ENOSPC,
                description: "Insufficient disk space on destination: \(freeBytes / (1024 * 1024)) MB free, \(sourceSize / (1024 * 1024)) MB needed"
            )
        }
    }

    private func copyFileContents(from sourcePath: String, to destinationPath: String) throws {
        let result = sourcePath.withCString { sourcePointer in
            destinationPath.withCString { destinationPointer in
                copyfile(sourcePointer, destinationPointer, nil, copyfile_flags_t(COPYFILE_ALL))
            }
        }
        guard result == 0 else {
            throw currentPOSIXError()
        }
    }

    private func fsyncFile(atPath path: String) throws {
        let fileDescriptor = open(path, O_RDWR)
        guard fileDescriptor >= 0 else {
            throw currentPOSIXError()
        }
        defer {
            close(fileDescriptor)
        }

        // F_FULLFSYNC flushes all the way to the storage device on macOS,
        // unlike fsync() which only guarantees flush to the disk controller.
        guard fcntl(fileDescriptor, F_FULLFSYNC) == 0 else {
            throw currentPOSIXError()
        }
    }

    private func renameFile(from sourcePath: String, to destinationPath: String) throws {
        let result = sourcePath.withCString { sourcePointer in
            destinationPath.withCString { destinationPointer in
                rename(sourcePointer, destinationPointer)
            }
        }
        guard result == 0 else {
            throw currentPOSIXError()
        }
    }

    private func shouldRetry(after error: Error) -> Bool {
        let code = posixCode(from: error)
        guard let code else {
            return false
        }

        return !retryPolicy.nonRetryableErrnos.contains(Int32(code.rawValue))
    }

    fileprivate func safeFileSize(atPath path: String) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    private func totalBytesForQueuedJobs(
        database: OrganizerDatabase,
        status: CopyJobStatus,
        orderByInsertion: Bool,
        batchSize: Int
    ) throws -> Int64 {
        var bytesTotal: Int64 = 0
        try database.enumerateQueuedJobBatches(
            status: status,
            orderByInsertion: orderByInsertion,
            batchSize: batchSize
        ) { batch in
            for job in batch {
                bytesTotal += safeFileSize(atPath: job.sourcePath) ?? 0
            }
        }
        return bytesTotal
    }

    private func currentPOSIXError() -> NSError {
        posixError(code: errno, description: String(cString: strerror(errno)))
    }

    private func posixError(code: Int32, description: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    private func posixCode(from error: Error) -> POSIXErrorCode? {
        let nsError = error as NSError
        guard nsError.domain == NSPOSIXErrorDomain else {
            return nil
        }
        return POSIXErrorCode(rawValue: Int32(nsError.code))
    }

fileprivate static let receiptTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()
}

private enum TransferExecutionStopSignal: Error {
    case stopRequested
}

private final class StreamingAuditReceiptWriter {
    private let finalReceiptURL: URL
    private let transferSpoolURL: URL
    private let createdAt: Date
    private let timestampString: String
    private let fileManager: FileManager

    private var spoolHandle: FileHandle?
    private var transferCount = 0
    private var finished = false

    init(
        destinationRoot: URL,
        fileManager: FileManager = .default,
        createdAt: Date = Date()
    ) throws {
        self.fileManager = fileManager
        self.createdAt = createdAt
        self.timestampString = ISO8601DateFormatter().string(from: createdAt)

        let logsDirectoryURL = destinationRoot.appendingPathComponent(
            EngineArtifactLayout.pythonReference.logsDirectoryName,
            isDirectory: true
        )
        try fileManager.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)

        let stem = "\(EngineArtifactLayout.pythonReference.auditReceiptPrefix)\(TransferExecutor.receiptTimestampFormatter.string(from: createdAt))"
        self.finalReceiptURL = logsDirectoryURL.appendingPathComponent("\(stem).json")
        self.transferSpoolURL = logsDirectoryURL.appendingPathComponent("\(stem).transfers.tmp")

        fileManager.createFile(atPath: transferSpoolURL.path, contents: Data())
        self.spoolHandle = try FileHandle(forWritingTo: transferSpoolURL)
    }

    deinit {
        discardUnfinishedFiles()
    }

    func appendTransfer(sourcePath: String, destinationPath: String, hash: String) throws {
        let payload: [String: String] = [
            "dest": destinationPath,
            "hash": hash,
            "source": sourcePath,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])

        if transferCount > 0 {
            try spoolHandle?.write(contentsOf: Data(",\n".utf8))
        }
        try spoolHandle?.write(contentsOf: Data("    ".utf8))
        try spoolHandle?.write(contentsOf: data)
        transferCount += 1
    }

    func finish(status: String) throws {
        guard !finished else {
            return
        }

        try spoolHandle?.close()
        spoolHandle = nil

        let temporaryReceiptURL = finalReceiptURL.appendingPathExtension("tmp")
        fileManager.createFile(atPath: temporaryReceiptURL.path, contents: Data())
        let receiptHandle = try FileHandle(forWritingTo: temporaryReceiptURL)

        do {
            try receiptHandle.write(contentsOf: Data("{\n".utf8))
            try receiptHandle.write(contentsOf: Data("  \"status\" : \"\(status)\",\n".utf8))
            try receiptHandle.write(contentsOf: Data("  \"timestamp\" : \"\(timestampString)\",\n".utf8))
            try receiptHandle.write(contentsOf: Data("  \"total_jobs\" : \(transferCount),\n".utf8))
            try receiptHandle.write(contentsOf: Data("  \"transfers\" : [\n".utf8))
            try pipeTransferSpool(into: receiptHandle)
            try receiptHandle.write(contentsOf: Data("\n  ]\n}\n".utf8))
            try receiptHandle.close()

            if fileManager.fileExists(atPath: finalReceiptURL.path) {
                try fileManager.removeItem(at: finalReceiptURL)
            }
            try fileManager.moveItem(at: temporaryReceiptURL, to: finalReceiptURL)
            try? fileManager.removeItem(at: transferSpoolURL)
            finished = true
        } catch {
            try? receiptHandle.close()
            try? fileManager.removeItem(at: temporaryReceiptURL)
            throw error
        }
    }

    func discardUnfinishedFiles() {
        guard !finished else {
            return
        }

        try? spoolHandle?.close()
        spoolHandle = nil
        try? fileManager.removeItem(at: transferSpoolURL)
        try? fileManager.removeItem(at: finalReceiptURL.appendingPathExtension("tmp"))
    }

    private func pipeTransferSpool(into receiptHandle: FileHandle) throws {
        let sourceHandle = try FileHandle(forReadingFrom: transferSpoolURL)
        defer {
            try? sourceHandle.close()
        }

        while true {
            let chunk = try sourceHandle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty {
                break
            }
            try receiptHandle.write(contentsOf: chunk)
        }
    }
}

private final class TransferExecutionContext {
    private let executor: TransferExecutor
    private let database: OrganizerDatabase
    private let verifyCopies: Bool
    private let runLogger: PersistentRunLogger
    private let observer: TransferExecutionObserver
    private let isCancelled: @Sendable () -> Bool
    private let totalJobs: Int
    private let bytesTotal: Int64
    private let artifacts: RunArtifactPaths
    private let receiptWriter: StreamingAuditReceiptWriter

    private var copiedCount = 0
    private var failedCount = 0
    private var consecutiveFailures = 0
    private var bytesCopied: Int64 = 0
    private var destinationUpdates: [RawFileCacheRecord]
    private var finished = false

    init(
        executor: TransferExecutor,
        database: OrganizerDatabase,
        destinationRoot: URL,
        verifyCopies: Bool,
        runLogger: PersistentRunLogger,
        observer: TransferExecutionObserver,
        isCancelled: @escaping @Sendable () -> Bool,
        totalJobs: Int,
        bytesTotal: Int64
    ) throws {
        self.executor = executor
        self.database = database
        self.verifyCopies = verifyCopies
        self.runLogger = runLogger
        self.observer = observer
        self.isCancelled = isCancelled
        self.totalJobs = totalJobs
        self.bytesTotal = bytesTotal
        self.artifacts = executor.artifactPaths(destinationRoot: destinationRoot)
        self.receiptWriter = try StreamingAuditReceiptWriter(destinationRoot: destinationRoot)
        self.destinationUpdates = []
        self.destinationUpdates.reserveCapacity(min(TransferExecutor.destinationCacheBatchSize, totalJobs))
    }

    deinit {
        if !finished {
            receiptWriter.discardUnfinishedFiles()
        }
    }

    func start() {
        observer.onPhaseStarted(totalJobs, bytesTotal)
    }

    func process(job: QueuedCopyJob, attemptedJobs: Int) throws -> Bool {
        var emittedProgress = false
        var completedCopy: (destinationPath: String, actualSize: Int64, actualModificationDate: TimeInterval)?

        do {
            let actualDestinationPath = try executor.safeCopyAtomic(
                sourcePath: job.sourcePath,
                requestedDestinationPath: job.destinationPath
            )

            if verifyCopies {
                let verifiedIdentity = try? executor.fileHasher.hashIdentity(at: URL(fileURLWithPath: actualDestinationPath))
                if verifiedIdentity?.rawValue != job.hash {
                    executor.removeUnverifiedCopyIfNeeded(atPath: actualDestinationPath, runLogger: runLogger)
                    try database.updateJobStatus(sourcePath: job.sourcePath, status: .failed)

                    let message = "Verification failed: \(job.sourcePath) -> \(actualDestinationPath)"
                    runLogger.error("Verification failed: \(job.sourcePath) → \(actualDestinationPath)")
                    observer.onIssue(RunIssue(severity: .error, message: message))

                    consecutiveFailures += 1
                    failedCount += 1
                    observer.onPhaseProgress(attemptedJobs, totalJobs, bytesCopied, bytesTotal)
                    emittedProgress = true

                    if executor.shouldAbort(
                        consecutiveFailures: consecutiveFailures,
                        totalFailures: failedCount,
                        attemptedJobs: attemptedJobs,
                        runLogger: runLogger
                    ) {
                        return false
                    }

                    return true
                }
            }

            try database.updateJobStatus(sourcePath: job.sourcePath, status: .copied)
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: actualDestinationPath)
            completedCopy = (
                destinationPath: actualDestinationPath,
                actualSize: (fileAttributes[.size] as? NSNumber)?.int64Value ?? 0,
                actualModificationDate: (fileAttributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            )
        } catch {
            try database.updateJobStatus(sourcePath: job.sourcePath, status: .failed)

            let message = "Copy failed: \(job.sourcePath) -> \(job.destinationPath): \(error.localizedDescription)"
            runLogger.error("Copy failed: \(job.sourcePath) → \(job.destinationPath): \(error.localizedDescription)")
            observer.onIssue(RunIssue(severity: .error, message: message))

            consecutiveFailures += 1
            failedCount += 1
            observer.onPhaseProgress(attemptedJobs, totalJobs, bytesCopied, bytesTotal)
            emittedProgress = true

            if executor.shouldAbort(
                consecutiveFailures: consecutiveFailures,
                totalFailures: failedCount,
                attemptedJobs: attemptedJobs,
                runLogger: runLogger
            ) {
                return false
            }
        }

        guard let completedCopy else {
            return !isCancelled()
        }

        destinationUpdates.append(
            RawFileCacheRecord(
                namespace: .destination,
                path: completedCopy.destinationPath,
                hash: job.hash,
                size: completedCopy.actualSize,
                modificationTime: completedCopy.actualModificationDate
            )
        )
        if destinationUpdates.count >= TransferExecutor.destinationCacheBatchSize {
            try executor.flushDestinationUpdates(destinationUpdates, database: database)
            destinationUpdates.removeAll(keepingCapacity: true)
        }

        try receiptWriter.appendTransfer(
            sourcePath: job.sourcePath,
            destinationPath: completedCopy.destinationPath,
            hash: job.hash
        )
        bytesCopied += executor.safeFileSize(atPath: job.sourcePath) ?? completedCopy.actualSize
        consecutiveFailures = 0
        copiedCount += 1

        if !emittedProgress, totalJobs > 0 {
            observer.onPhaseProgress(attemptedJobs, totalJobs, bytesCopied, bytesTotal)
        }

        return !isCancelled()
    }

    func finish(attemptedJobs: Int) throws -> TransferExecutionResult {
        try executor.flushDestinationUpdates(destinationUpdates, database: database)
        try receiptWriter.finish(status: "COMPLETED")

        if totalJobs > 0, attemptedJobs == 0 {
            observer.onPhaseProgress(attemptedJobs, totalJobs, bytesCopied, bytesTotal)
        }

        finished = true

        return TransferExecutionResult(
            copiedCount: copiedCount,
            failedCount: failedCount,
            bytesCopied: bytesCopied,
            bytesTotal: bytesTotal,
            artifacts: artifacts
        )
    }
}

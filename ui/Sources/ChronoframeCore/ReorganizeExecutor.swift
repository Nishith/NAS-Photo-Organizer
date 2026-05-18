import Foundation

// MARK: - Plan model

/// One file move that the executor will perform. Source and destination are
/// always **inside** the same destination root (this is an in-place layout
/// migration, not a copy across volumes).
public struct ReorganizeMove: Equatable, Sendable {
    public let sourcePath: String
    public let destinationPath: String

    public init(sourcePath: String, destinationPath: String) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
    }
}

public struct ReorganizePlan: Equatable, Sendable {
    public let destinationRoot: String
    public let targetStructure: FolderStructure
    public let moves: [ReorganizeMove]
    /// Files that were inspected but already conformed to the target layout.
    public let unchangedCount: Int
    /// Files that were inspected but whose filenames did not match the
    /// `YYYY-MM-DD_*` or `Unknown_*` patterns Chronoframe writes — left alone.
    public let unrecognizedCount: Int

    public init(
        destinationRoot: String,
        targetStructure: FolderStructure,
        moves: [ReorganizeMove],
        unchangedCount: Int,
        unrecognizedCount: Int
    ) {
        self.destinationRoot = destinationRoot
        self.targetStructure = targetStructure
        self.moves = moves
        self.unchangedCount = unchangedCount
        self.unrecognizedCount = unrecognizedCount
    }

    public var isEmpty: Bool { moves.isEmpty }
}

// MARK: - Result + observer

public struct ReorganizeExecutionResult: Equatable, Sendable {
    public var movedCount: Int
    public var skippedCount: Int
    public var failedCount: Int
    public var totalMoves: Int
    public var receiptPath: String?

    public init(
        movedCount: Int,
        skippedCount: Int,
        failedCount: Int,
        totalMoves: Int,
        receiptPath: String? = nil
    ) {
        self.movedCount = movedCount
        self.skippedCount = skippedCount
        self.failedCount = failedCount
        self.totalMoves = totalMoves
        self.receiptPath = receiptPath
    }
}

public struct ReorganizeAuditReceipt: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var sourcePath: String
        public var destinationPath: String
        public var hash: String
        public var completed: Bool
    }

    public var schemaVersion: Int
    public var runID: UUID
    public var operation: String
    public var status: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var destinationRoot: String
    public var items: [Item]
    public var abortReason: String?
}

public struct ReorganizeExecutionObserver: Sendable {
    public var onTaskStart: @Sendable (_ total: Int) -> Void
    public var onTaskProgress: @Sendable (_ completed: Int, _ total: Int) -> Void
    public var onIssue: @Sendable (_ issue: RunIssue) -> Void

    public init(
        onTaskStart: @escaping @Sendable (_ total: Int) -> Void = { _ in },
        onTaskProgress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void = { _, _ in },
        onIssue: @escaping @Sendable (_ issue: RunIssue) -> Void = { _ in }
    ) {
        self.onTaskStart = onTaskStart
        self.onTaskProgress = onTaskProgress
        self.onIssue = onIssue
    }
}

// MARK: - Errors

public enum ReorganizeExecutorError: LocalizedError, Equatable {
    case destinationNotFound(path: String)
    case destinationNotADirectory(path: String)

    public var errorDescription: String? {
        switch self {
        case let .destinationNotFound(path):
            return "The destination folder is no longer available. Reconnect the drive or choose the destination again. Path: \(path)."
        case let .destinationNotADirectory(path):
            return "The selected destination is not a folder. Choose a folder as the destination. Path: \(path)."
        }
    }
}

// MARK: - Executor

public struct ReorganizeExecutor: Sendable {
    private let namingRules: PlannerNamingRules
    private let hasher: FileIdentityHasher

    public init(
        namingRules: PlannerNamingRules = .chronoframeDefault,
        hasher: FileIdentityHasher = FileIdentityHasher()
    ) {
        self.namingRules = namingRules
        self.hasher = hasher
    }

    private var fileManager: FileManager { .default }

    /// Walk the destination root and produce a plan that describes every file
    /// that needs to move under `targetStructure`. Pure: makes no filesystem
    /// changes. Skips artifact directories (`.organize_logs`, hidden dirs) and
    /// artifact files (`.organize_cache.db`, `.organize_log.txt`, audit
    /// receipts, dry-run reports).
    public func plan(
        destinationRoot: URL,
        targetStructure: FolderStructure
    ) throws -> ReorganizePlan {
        guard fileManager.fileExists(atPath: destinationRoot.path) else {
            throw ReorganizeExecutorError.destinationNotFound(path: destinationRoot.path)
        }
        var isDir: ObjCBool = false
        fileManager.fileExists(atPath: destinationRoot.path, isDirectory: &isDir)
        guard isDir.boolValue else {
            throw ReorganizeExecutorError.destinationNotADirectory(path: destinationRoot.path)
        }

        let rootURL = destinationRoot.standardizedFileURL
        var moves: [ReorganizeMove] = []
        var unchanged = 0
        var unrecognized = 0

        let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
            options: [.skipsPackageDescendants]
        )

        while let item = enumerator?.nextObject() as? URL {
            // Prune artifact directories — never recurse into them.
            if item.hasDirectoryPath {
                if Self.shouldSkipDirectory(name: item.lastPathComponent) {
                    enumerator?.skipDescendants()
                }
                continue
            }

            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey])
            if values?.isSymbolicLink == true || values?.isPackage == true || values?.isRegularFile == false {
                continue
            }

            // Skip artifact files at any level.
            let filename = item.lastPathComponent
            if Self.isArtifactFile(filename: filename) {
                continue
            }
            if filename.hasPrefix(".") {
                continue
            }

            guard let parsed = parseFileBucket(filename: filename) else {
                unrecognized += 1
                continue
            }

            let currentRelativePath = item.standardizedFileURL.path
                .replacingOccurrences(of: rootURL.path + "/", with: "")
            let inDuplicate = currentRelativePath.hasPrefix(namingRules.duplicateDirectoryName + "/")
            let duplicateName = inDuplicate ? namingRules.duplicateDirectoryName : nil

            // Detect the existing event subpath for yyyyMonEvent migrations,
            // so reorganizing INTO yyyyMonEvent preserves the event folder
            // when present in the source layout.
            let detectedEvent = Self.detectEventFolder(
                inRelativePath: currentRelativePath,
                duplicateDirectoryName: namingRules.duplicateDirectoryName
            )

            let newPath = computeDestinationPath(
                sourceFilename: filename,
                rootURL: rootURL,
                bucket: parsed.bucket,
                duplicateName: duplicateName,
                eventFolder: detectedEvent,
                targetStructure: targetStructure
            )

            if newPath == item.standardizedFileURL.path {
                unchanged += 1
            } else {
                moves.append(
                    ReorganizeMove(
                        sourcePath: item.standardizedFileURL.path,
                        destinationPath: newPath
                    )
                )
            }
        }

        // Stable, deterministic order so callers (and tests) can rely on it.
        moves.sort { $0.sourcePath < $1.sourcePath }

        return ReorganizePlan(
            destinationRoot: rootURL.path,
            targetStructure: targetStructure,
            moves: moves,
            unchangedCount: unchanged,
            unrecognizedCount: unrecognized
        )
    }

    /// Execute every move in `plan`. Skips moves whose destination path already
    /// exists (avoids clobbering). Cleans up parent directories that become
    /// empty after a move, mirroring the same best-effort behaviour as
    /// `RevertExecutor`.
    @discardableResult
    public func execute(
        plan: ReorganizePlan,
        observer: ReorganizeExecutionObserver = ReorganizeExecutionObserver(),
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> ReorganizeExecutionResult {
        observer.onTaskStart(plan.moves.count)

        var movedCount = 0
        var skippedCount = 0
        var failedCount = 0
        let rootURL = URL(fileURLWithPath: plan.destinationRoot, isDirectory: true).standardizedFileURL
        let logsDirectoryURL = rootURL.appendingPathComponent(
            EngineArtifactLayout.chronoframeDefault.logsDirectoryName,
            isDirectory: true
        )
        try fileManager.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)

        var executableMoves: [ReorganizeMove] = []
        var receiptItems: [ReorganizeAuditReceipt.Item] = []

        for move in plan.moves {
            let sourceURL = URL(fileURLWithPath: move.sourcePath)
            let destinationURL = URL(fileURLWithPath: move.destinationPath)
            guard Self.isContained(sourceURL, in: rootURL), Self.isContained(destinationURL, in: rootURL) else {
                skippedCount += 1
                observer.onIssue(RunIssue(severity: .warning, message: "Move escaped the destination root, skipping: \(move.sourcePath)"))
                observer.onTaskProgress(movedCount + skippedCount + failedCount, plan.moves.count)
                continue
            }
            guard fileManager.fileExists(atPath: move.sourcePath) else {
                skippedCount += 1
                observer.onIssue(RunIssue(severity: .warning, message: "Source no longer exists: \(move.sourcePath)"))
                observer.onTaskProgress(movedCount + skippedCount + failedCount, plan.moves.count)
                continue
            }
            guard !fileManager.fileExists(atPath: move.destinationPath) else {
                skippedCount += 1
                observer.onIssue(RunIssue(severity: .warning, message: "Destination exists, skipping: \(move.destinationPath)"))
                observer.onTaskProgress(movedCount + skippedCount + failedCount, plan.moves.count)
                continue
            }
            do {
                let identity = try hasher.hashIdentity(at: sourceURL)
                executableMoves.append(move)
                receiptItems.append(
                    ReorganizeAuditReceipt.Item(
                        sourcePath: move.sourcePath,
                        destinationPath: move.destinationPath,
                        hash: identity.rawValue,
                        completed: false
                    )
                )
            } catch {
                skippedCount += 1
                observer.onIssue(RunIssue(severity: .warning, message: "Could not prepare \(move.sourcePath): \(error.localizedDescription)"))
                observer.onTaskProgress(movedCount + skippedCount + failedCount, plan.moves.count)
            }
        }

        let runID = UUID()
        let startedAt = Date()
        let receiptURL = Self.reorganizeReceiptURL(logsDirectory: logsDirectoryURL, runID: runID, createdAt: startedAt)
        try Self.writeReorganizeReceipt(
            to: receiptURL,
            runID: runID,
            status: "PENDING",
            startedAt: startedAt,
            finishedAt: nil,
            destinationRoot: plan.destinationRoot,
            items: receiptItems,
            abortReason: nil
        )

        var abortReason: String?

        // Phase 1 finding: previously the per-move loop rewrote the
        // entire receipt JSON after EVERY move (O(N²) bytes written
        // for N moves). Cap the rewrite cadence at every K moves —
        // on crash, up to K-1 completed moves may be missing from
        // the on-disk receipt (the files are at their new locations;
        // revert simply leaves them alone). Always flush after the
        // loop and on cancellation so the final state is durable.
        let receiptCheckpointInterval = 25

        for (index, move) in executableMoves.enumerated() {
            if isCancelled() {
                abortReason = "Reorganize was cancelled before all planned moves completed."
                break
            }

            let sourceURL = URL(fileURLWithPath: move.sourcePath)
            let destinationURL = URL(fileURLWithPath: move.destinationPath)

            do {
                // Phase 1 finding: re-hash the source immediately
                // before moving so a swap-out between plan-time
                // hashing and move-time can't poison the receipt's
                // recorded `hash` with stale content. The previous
                // code wrote the plan-time hash into the receipt
                // unconditionally; revert would then refuse all such
                // entries as "modified since" with no clear signal.
                if let liveHash = try? hasher.hashIdentity(at: sourceURL) {
                    receiptItems[index].hash = liveHash.rawValue
                }
                try fileManager.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
                movedCount += 1
                receiptItems[index].completed = true
                let shouldCheckpoint = (movedCount % receiptCheckpointInterval == 0)
                if shouldCheckpoint {
                    try Self.writeReorganizeReceipt(
                        to: receiptURL,
                        runID: runID,
                        status: "PENDING",
                        startedAt: startedAt,
                        finishedAt: nil,
                        destinationRoot: plan.destinationRoot,
                        items: receiptItems,
                        abortReason: nil
                    )
                }

                // Best-effort empty-directory cleanup.
                let parentURL = sourceURL.deletingLastPathComponent()
                if Self.isContained(parentURL, in: rootURL),
                   let contents = try? fileManager.contentsOfDirectory(
                    atPath: parentURL.path
                ), contents.isEmpty {
                    try? fileManager.removeItem(at: parentURL)
                }
            } catch {
                failedCount += 1
                observer.onIssue(
                    RunIssue(
                        severity: .error,
                        message: "Could not move \(move.sourcePath): \(error.localizedDescription)"
                    )
                )
            }

            observer.onTaskProgress(movedCount + skippedCount + failedCount, plan.moves.count)
        }

        try Self.writeReorganizeReceipt(
            to: receiptURL,
            runID: runID,
            status: abortReason == nil ? "COMPLETED" : "ABORTED",
            startedAt: startedAt,
            finishedAt: Date(),
            destinationRoot: plan.destinationRoot,
            items: receiptItems,
            abortReason: abortReason
        )

        return ReorganizeExecutionResult(
            movedCount: movedCount,
            skippedCount: skippedCount,
            failedCount: failedCount,
            totalMoves: plan.moves.count,
            receiptPath: receiptURL.path
        )
    }

    @discardableResult
    public func revert(
        receiptURL: URL,
        observer: ReorganizeExecutionObserver = ReorganizeExecutionObserver(),
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> ReorganizeExecutionResult {
        let data = try Data(contentsOf: receiptURL)
        let receipt = try JSONDecoder().decode(ReorganizeAuditReceipt.self, from: data)
        let rootURL = URL(fileURLWithPath: receipt.destinationRoot, isDirectory: true).standardizedFileURL
        let completedItems = receipt.items.filter(\.completed).reversed()
        observer.onTaskStart(completedItems.count)

        var movedCount = 0
        var skippedCount = 0
        var failedCount = 0

        for item in completedItems {
            if isCancelled() { break }
            let currentURL = URL(fileURLWithPath: item.destinationPath)
            let originalURL = URL(fileURLWithPath: item.sourcePath)

            guard Self.isContained(currentURL, in: rootURL), Self.isContained(originalURL, in: rootURL) else {
                skippedCount += 1
                observer.onIssue(RunIssue(severity: .warning, message: "Receipt path escaped the destination root, skipping: \(item.destinationPath)"))
                observer.onTaskProgress(movedCount + skippedCount + failedCount, completedItems.count)
                continue
            }
            guard fileManager.fileExists(atPath: item.destinationPath) else {
                skippedCount += 1
                observer.onIssue(RunIssue(severity: .warning, message: "Moved file is no longer present: \(item.destinationPath)"))
                observer.onTaskProgress(movedCount + skippedCount + failedCount, completedItems.count)
                continue
            }
            guard !fileManager.fileExists(atPath: item.sourcePath) else {
                skippedCount += 1
                observer.onIssue(RunIssue(severity: .warning, message: "Original path already exists, skipping: \(item.sourcePath)"))
                observer.onTaskProgress(movedCount + skippedCount + failedCount, completedItems.count)
                continue
            }

            do {
                let currentIdentity = try hasher.hashIdentity(at: currentURL)
                guard currentIdentity.rawValue == item.hash else {
                    skippedCount += 1
                    observer.onIssue(RunIssue(severity: .info, message: "Preserved reorganized file because it changed: \(item.destinationPath)"))
                    observer.onTaskProgress(movedCount + skippedCount + failedCount, completedItems.count)
                    continue
                }
                try fileManager.createDirectory(at: originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: currentURL, to: originalURL)
                movedCount += 1
            } catch {
                failedCount += 1
                observer.onIssue(RunIssue(severity: .error, message: "Could not restore \(item.destinationPath): \(error.localizedDescription)"))
            }
            observer.onTaskProgress(movedCount + skippedCount + failedCount, completedItems.count)
        }

        return ReorganizeExecutionResult(
            movedCount: movedCount,
            skippedCount: skippedCount,
            failedCount: failedCount,
            totalMoves: completedItems.count,
            receiptPath: receiptURL.path
        )
    }

    // MARK: - Helpers

    /// Filenames Chronoframe writes follow either:
    /// - `YYYY-MM-DD_NNN.ext` (or wider sequence) — dated bucket
    /// - `Unknown_NNN.ext` — unknown-date bucket
    private func parseFileBucket(filename: String) -> (bucket: String, isUnknown: Bool)? {
        let stem = (filename as NSString).deletingPathExtension

        // Unknown_ prefix
        if stem.hasPrefix(namingRules.unknownFilenamePrefix) {
            let sequencePart = String(stem.dropFirst(namingRules.unknownFilenamePrefix.count))
            guard !sequencePart.isEmpty, sequencePart.allSatisfy(\.isNumber) else {
                return nil
            }
            return (namingRules.unknownDateDirectoryName, true)
        }

        // YYYY-MM-DD_<seq>
        let parts = stem.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let datePart = String(parts[0])
        let sequencePart = String(parts[1])
        guard !sequencePart.isEmpty, sequencePart.allSatisfy(\.isNumber) else {
            return nil
        }

        // Validate YYYY-MM-DD shape
        let dateComponents = datePart.split(separator: "-")
        guard dateComponents.count == 3,
              dateComponents[0].count == 4, dateComponents[0].allSatisfy(\.isNumber),
              dateComponents[1].count == 2, dateComponents[1].allSatisfy(\.isNumber),
              dateComponents[2].count == 2, dateComponents[2].allSatisfy(\.isNumber) else {
            return nil
        }
        return (datePart, false)
    }

    private func computeDestinationPath(
        sourceFilename filename: String,
        rootURL: URL,
        bucket: String,
        duplicateName: String?,
        eventFolder: String?,
        targetStructure: FolderStructure
    ) -> String {
        var path = rootURL
        if let duplicateName {
            path.appendPathComponent(duplicateName, isDirectory: true)
        }

        if bucket == namingRules.unknownDateDirectoryName {
            path.appendPathComponent(namingRules.unknownDateDirectoryName, isDirectory: true)
            if targetStructure == .yyyyMonEvent, let eventFolder, !eventFolder.isEmpty {
                path.appendPathComponent(eventFolder, isDirectory: true)
            }
            return path.appendingPathComponent(filename).path
        }

        let components = bucket.split(separator: "-")
        switch targetStructure {
        case .yyyyMMDD where components.count == 3:
            path.appendPathComponent(String(components[0]), isDirectory: true)
            path.appendPathComponent(String(components[1]), isDirectory: true)
            path.appendPathComponent(String(components[2]), isDirectory: true)
        case .yyyyMM where components.count == 3:
            path.appendPathComponent(String(components[0]), isDirectory: true)
            path.appendPathComponent(String(components[1]), isDirectory: true)
        case .yyyy where components.count == 3:
            path.appendPathComponent(String(components[0]), isDirectory: true)
        case .yyyyMonEvent where components.count == 3:
            if let monthInt = Int(components[1]), (1...12).contains(monthInt) {
                path.appendPathComponent(String(components[0]), isDirectory: true)
                path.appendPathComponent(Self.monthAbbreviations[monthInt - 1], isDirectory: true)
                if let eventFolder, !eventFolder.isEmpty {
                    path.appendPathComponent(eventFolder, isDirectory: true)
                }
            }
        case .flat:
            break
        default:
            break
        }

        return path.appendingPathComponent(filename).path
    }

    /// If the file is currently nested under a `YYYY/Mon/Event/` layout, return
    /// the event folder name. Returns nil for any non-Event source layout.
    private static func detectEventFolder(
        inRelativePath relativePath: String,
        duplicateDirectoryName: String
    ) -> String? {
        var components = relativePath.split(separator: "/").map(String.init)
        // Strip the leading Duplicate/ if present.
        if components.first == duplicateDirectoryName {
            components.removeFirst()
        }
        // Drop the filename — we only care about parent folders.
        guard components.count >= 2 else { return nil }
        components.removeLast()

        // Layout: YYYY / Mon / Event / file → 3 components remaining
        // Layout: Unknown_Date / Event / file → 2 components, first is Unknown_Date
        if components.count == 3,
           components[0].count == 4, components[0].allSatisfy(\.isNumber),
           monthAbbreviationSet.contains(components[1]) {
            return components[2]
        }
        if components.count == 2,
           components[0] == "Unknown_Date" {
            return components[1]
        }
        return nil
    }

    private static let monthAbbreviations = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]
    private static let monthAbbreviationSet = Set(monthAbbreviations)

    private static func shouldSkipDirectory(name: String) -> Bool {
        // Don't recurse into Chronoframe artifact directories or hidden dirs.
        return name.hasPrefix(".")
    }

    private static func isArtifactFile(filename: String) -> Bool {
        let layout = EngineArtifactLayout.chronoframeDefault
        if filename == layout.queueDatabaseFilename { return true }
        if filename == layout.runLogFilename { return true }
        if filename.hasPrefix(layout.dryRunReportPrefix) { return true }
        if filename.hasPrefix(layout.auditReceiptPrefix) { return true }
        if filename.hasPrefix("reorganize_audit_receipt_") { return true }
        return false
    }

    private static func reorganizeReceiptURL(logsDirectory: URL, runID: UUID, createdAt: Date) -> URL {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: createdAt)
        return logsDirectory.appendingPathComponent("reorganize_audit_receipt_\(timestamp)_\(runID.uuidString).json")
    }

    private static func writeReorganizeReceipt(
        to url: URL,
        runID: UUID,
        status: String,
        startedAt: Date,
        finishedAt: Date?,
        destinationRoot: String,
        items: [ReorganizeAuditReceipt.Item],
        abortReason: String?
    ) throws {
        let receipt = ReorganizeAuditReceipt(
            schemaVersion: 1,
            runID: runID,
            operation: "reorganize",
            status: status,
            startedAt: startedAt,
            finishedAt: finishedAt,
            destinationRoot: destinationRoot,
            items: items,
            abortReason: abortReason
        )
        let data = try JSONEncoder().encode(receipt)
        try data.write(to: url, options: .atomic)
    }

    private static func isContained(_ url: URL, in rootURL: URL) -> Bool {
        SafePathContainment.isContained(url, in: rootURL)
    }
}

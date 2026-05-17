import Darwin
import Foundation

public enum SafePathContainment {
    public static func isContained(_ candidateURL: URL, in rootURL: URL) -> Bool {
        let rootPath = resolvedPath(for: rootURL, treatAsDirectory: true)
        let candidatePath = resolvedPath(for: candidateURL, treatAsDirectory: false)
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    public static func resolvedPath(for url: URL, treatAsDirectory: Bool) -> String {
        let standardized = url.standardizedFileURL
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: standardized.path) {
            return standardized.resolvingSymlinksInPath().standardizedFileURL.path
        }
        if treatAsDirectory {
            return standardized.resolvingSymlinksInPath().standardizedFileURL.path
        }
        let parent = standardized.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        return parent.appendingPathComponent(standardized.lastPathComponent).path
    }
}

// MARK: - Receipt model (decoded from audit_receipt_*.json)

public struct RevertReceiptTransfer: Equatable, Codable, Sendable {
    public let source: String
    public let dest: String
    public let hash: String

    public init(source: String, dest: String, hash: String) {
        self.source = source
        self.dest = dest
        self.hash = hash
    }
}

public struct RevertReceipt: Equatable, Codable, Sendable {
    public let timestamp: String?
    public let status: String?
    public let totalJobs: Int?
    public let transfers: [RevertReceiptTransfer]

    public init(
        timestamp: String? = nil,
        status: String? = nil,
        totalJobs: Int? = nil,
        transfers: [RevertReceiptTransfer]
    ) {
        self.timestamp = timestamp
        self.status = status
        self.totalJobs = totalJobs
        self.transfers = transfers
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case status
        case totalJobs = "total_jobs"
        case transfers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
        self.status = try container.decodeIfPresent(String.self, forKey: .status)
        self.totalJobs = try container.decodeIfPresent(Int.self, forKey: .totalJobs)
        self.transfers = try container.decodeIfPresent([RevertReceiptTransfer].self, forKey: .transfers) ?? []
    }
}

// MARK: - Result + observer

public struct RevertExecutionResult: Equatable, Sendable {
    /// Files whose destination still hashed to the receipt value and were removed.
    public var revertedCount: Int
    /// Files preserved due to hash mismatch (user-modified) or OS error during remove.
    public var skippedCount: Int
    /// Files already missing from disk are treated as "trivially reverted"
    /// and does not increment either counter. Tracked separately for richer UI.
    public var missingCount: Int
    /// Total receipt entries considered.
    public var totalTransfers: Int

    public init(
        revertedCount: Int,
        skippedCount: Int,
        missingCount: Int,
        totalTransfers: Int
    ) {
        self.revertedCount = revertedCount
        self.skippedCount = skippedCount
        self.missingCount = missingCount
        self.totalTransfers = totalTransfers
    }
}

public struct RevertExecutionObserver: Sendable {
    public var onTaskStart: @Sendable (_ total: Int) -> Void
    /// `completed` is reverted + skipped, not including missing files.
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

public enum RevertExecutorError: LocalizedError, Equatable {
    case receiptNotFound(path: String)
    case receiptUnreadable(path: String, reason: String)
    case invalidReceipt(reason: String)

    public var errorDescription: String? {
        switch self {
        case let .receiptNotFound(path):
            return "The selected revert receipt could not be found. It may have been moved or deleted. Receipt: \(path)."
        case let .receiptUnreadable(path, reason):
            return "Chronoframe could not open this revert receipt. Check that the file is still available and try again. Receipt: \(path). Details: \(reason)"
        case let .invalidReceipt(reason):
            return "Chronoframe could not read this revert receipt. Choose a different receipt or run a new transfer. Details: \(reason)"
        }
    }
}

// MARK: - Executor

public struct RevertExecutor: Sendable {
    private let hasher: FileIdentityHasher

    /// Testability seam: overrides the path resolver used in both the pre-hash and
    /// post-hash boundary checks.  Production callers leave this nil, which falls
    /// through to the real `SafePathContainment.resolvedPath` call.  Tests inject a
    /// closure that can return different values on successive calls to simulate a
    /// symlink-swap race (TOCTOU) without needing OS-level timing control.
    var _boundaryPathResolver: (@Sendable (URL) -> String)?

    public init(hasher: FileIdentityHasher = FileIdentityHasher()) {
        self.hasher = hasher
        self._boundaryPathResolver = nil
    }

    /// Resolve the canonical path for a destination file URL.
    /// Uses the injected resolver when set (tests only); otherwise delegates to
    /// `SafePathContainment.resolvedPath` which follows symlinks via the real FS.
    private func resolveDestPath(_ url: URL) -> String {
        _boundaryPathResolver.map { $0(url) }
            ?? SafePathContainment.resolvedPath(for: url, treatAsDirectory: false)
    }

    /// FileManager.default is process-wide and thread-safe for the read/remove
    /// operations we use; we look it up at call sites to keep the struct Sendable.
    private var fileManager: FileManager { .default }

    /// Load a Chronoframe audit receipt from disk.
    public func loadReceipt(at url: URL) throws -> RevertReceipt {
        guard fileManager.fileExists(atPath: url.path) else {
            throw RevertExecutorError.receiptNotFound(path: url.path)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw RevertExecutorError.receiptUnreadable(
                path: url.path,
                reason: error.localizedDescription
            )
        }

        do {
            return try JSONDecoder().decode(RevertReceipt.self, from: data)
        } catch {
            throw RevertExecutorError.invalidReceipt(
                reason: "Malformed JSON: \(error.localizedDescription)"
            )
        }
    }

    /// Move a corrupt receipt out of the way so it stops appearing as a
    /// revertable history entry. The original file is preserved (renamed
    /// rather than deleted) for diagnostics. The new name strips the `.json`
    /// extension, which means `RunHistoryIndexer.classifyArtifact` no longer
    /// recognises it as a receipt or generic JSON artifact.
    ///
    /// Returns the quarantined URL on success, or nil when no rename is
    /// possible (file already moved, destination exists, sandbox denial).
    /// Errors are swallowed: quarantine is best-effort, never a hard failure.
    @discardableResult
    public func quarantineCorruptReceipt(at url: URL) -> URL? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let baseName = url.deletingPathExtension().lastPathComponent
        let directory = url.deletingLastPathComponent()
        var candidate = directory.appendingPathComponent("\(baseName).corrupt")

        if fileManager.fileExists(atPath: candidate.path) {
            // Collision: tag with seconds-since-epoch to keep both copies.
            let suffix = Int(Date().timeIntervalSince1970)
            candidate = directory.appendingPathComponent("\(baseName).corrupt.\(suffix)")
        }

        do {
            try fileManager.moveItem(at: url, to: candidate)
            return candidate
        } catch {
            return nil
        }
    }

    /// Revert every transfer in `receipt`. Honors the same hash-guard contract as
    /// `chronoframe.core.revert_receipt`: a destination file is removed only when
    /// its current BLAKE2b identity still matches the value recorded at copy time.
    /// Modified or replaced files are left in place.
    ///
    /// When `destinationBoundary` is supplied, any transfer whose `dest` path
    /// resolves outside that directory is refused even if the hash matches.
    /// Production callers should always pass the run's destination root so a
    /// crafted or accidentally edited receipt cannot reach files outside the
    /// organized library.
    @discardableResult
    public func revert(
        receipt: RevertReceipt,
        observer: RevertExecutionObserver = RevertExecutionObserver(),
        destinationBoundary: URL? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> RevertExecutionResult {
        let transfers = receipt.transfers
        observer.onTaskStart(transfers.count)

        var revertedCount = 0
        var skippedCount = 0
        var missingCount = 0

        let boundaryPath: String? = destinationBoundary.map {
            SafePathContainment.resolvedPath(for: $0, treatAsDirectory: true)
        }

        for transfer in transfers {
            if isCancelled() {
                break
            }

            let destinationPath = transfer.dest
            let destinationURL = URL(fileURLWithPath: destinationPath)

            if let boundaryPath {
                let resolvedPath = resolveDestPath(destinationURL)
                let isInside = resolvedPath == boundaryPath
                    || resolvedPath.hasPrefix(boundaryPath + "/")
                if !isInside {
                    skippedCount += 1
                    observer.onIssue(
                        RunIssue(
                            severity: .warning,
                            message: "Refusing to revert path outside destination: \(destinationPath)"
                        )
                    )
                    observer.onTaskProgress(revertedCount + skippedCount, transfers.count)
                    continue
                }
            }

            if !fileManager.fileExists(atPath: destinationPath) {
                // Missing destination is counted as trivially reverted.
                // and does NOT advance the progress counter (which is reverted+skipped).
                missingCount += 1
                continue
            }

            // Open the destination once with O_NOFOLLOW; hash through that fd
            // and unlink via the parent directory fd, gated on the entry's
            // inode still matching the fd we hashed. This collapses the
            // pre-existing race window where a symlink swap between
            // `hashIdentity(at:)` and `removeItem(at:)` could redirect the
            // unlink to a path outside the destination boundary.
            switch safeRevert(
                destinationPath: destinationPath,
                expectedHash: transfer.hash,
                boundaryPath: boundaryPath,
                destinationURL: destinationURL
            ) {
            case .reverted:
                revertedCount += 1
            case let .skipped(issue):
                skippedCount += 1
                observer.onIssue(issue)
            }

            observer.onTaskProgress(revertedCount + skippedCount, transfers.count)
        }

        return RevertExecutionResult(
            revertedCount: revertedCount,
            skippedCount: skippedCount,
            missingCount: missingCount,
            totalTransfers: transfers.count
        )
    }

    // MARK: - Safe revert (TOCTOU-resistant)

    enum SafeRevertOutcome {
        case reverted
        case skipped(RunIssue)
    }

    /// Test seam: invoked just after `open()` succeeds and just before the
    /// fd-based hash starts. Tests inject this to simulate a symlink/inode
    /// swap inside the window so the post-hash inode re-check can be
    /// exercised deterministically. Production callers leave it nil.
    var _postOpenRaceHook: (@Sendable (Int32, String) -> Void)?

    func safeRevert(
        destinationPath: String,
        expectedHash: String,
        boundaryPath: String?,
        destinationURL: URL
    ) -> SafeRevertOutcome {
        // 1. Open the entry with O_NOFOLLOW so a symlink in place of the
        // intended file is refused outright (ELOOP).
        let fd = destinationPath.withCString { ptr in
            Darwin.open(ptr, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fd >= 0 else {
            let code = errno
            if code == ELOOP {
                return .skipped(RunIssue(
                    severity: .warning,
                    message: "Refusing to revert symlink at destination: \(destinationPath)"
                ))
            }
            return .skipped(RunIssue(
                severity: .warning,
                message: "Could not open \(destinationPath): \(String(cString: strerror(code)))"
            ))
        }
        var didClose = false
        defer { if !didClose { _ = Darwin.close(fd) } }

        // 2. fstat the fd. Must be a regular file (defensive — O_NOFOLLOW
        // already rules out symlinks, but the descriptor could still be a
        // FIFO/socket/device that snuck in via a stale path).
        var fdStat = stat()
        guard fstat(fd, &fdStat) == 0 else {
            let code = errno
            return .skipped(RunIssue(
                severity: .warning,
                message: "Could not stat \(destinationPath): \(String(cString: strerror(code)))"
            ))
        }
        guard (fdStat.st_mode & S_IFMT) == S_IFREG else {
            return .skipped(RunIssue(
                severity: .warning,
                message: "Refusing to revert non-regular file at destination: \(destinationPath)"
            ))
        }

        _postOpenRaceHook?(fd, destinationPath)

        // 3. Hash via the open fd so the hash and the unlink can only ever
        // agree about the *same inode*.
        let identity: FileIdentity
        do {
            identity = try hasher.hashIdentity(descriptor: fd, size: Int64(fdStat.st_size))
        } catch {
            return .skipped(RunIssue(
                severity: .warning,
                message: "Could not re-hash \(destinationPath): \(error.localizedDescription)"
            ))
        }

        guard identity.rawValue == expectedHash else {
            return .skipped(RunIssue(
                severity: .info,
                message: "Preserved (modified since copy): \(destinationPath)"
            ))
        }

        // 4. Optional second boundary check on the path (defence in depth).
        // The inode-match check below is the real safety net.
        if let boundaryPath {
            let recheckPath = resolveDestPath(destinationURL)
            let isStillInside = recheckPath == boundaryPath
                || recheckPath.hasPrefix(boundaryPath + "/")
            if !isStillInside {
                return .skipped(RunIssue(
                    severity: .warning,
                    message: "Refusing to revert path outside destination (post-hash re-check): \(destinationPath)"
                ))
            }
        }

        // 5. Open the parent directory and `fstatat` the basename with
        // `AT_SYMLINK_NOFOLLOW`. If a swap happened between hash and unlink,
        // the directory entry's inode no longer matches the fd we hashed —
        // refuse the unlink.
        let parentURL = destinationURL.deletingLastPathComponent()
        let parentPath = parentURL.path
        let baseName = destinationURL.lastPathComponent

        let dirFd = parentPath.withCString { ptr in
            Darwin.open(ptr, O_DIRECTORY | O_RDONLY | O_CLOEXEC)
        }
        guard dirFd >= 0 else {
            let code = errno
            return .skipped(RunIssue(
                severity: .warning,
                message: "Could not open parent directory of \(destinationPath): \(String(cString: strerror(code)))"
            ))
        }
        defer { _ = Darwin.close(dirFd) }

        var entryStat = stat()
        let statRC = baseName.withCString { ptr in
            fstatat(dirFd, ptr, &entryStat, AT_SYMLINK_NOFOLLOW)
        }
        guard statRC == 0 else {
            let code = errno
            return .skipped(RunIssue(
                severity: .warning,
                message: "Could not re-stat \(destinationPath): \(String(cString: strerror(code)))"
            ))
        }
        guard entryStat.st_ino == fdStat.st_ino, entryStat.st_dev == fdStat.st_dev else {
            // The directory entry was replaced (possibly by a symlink or a
            // different file) after we opened it. Do not unlink — that would
            // remove something other than what we hashed.
            return .skipped(RunIssue(
                severity: .warning,
                message: "Refusing to revert: destination entry changed during revert: \(destinationPath)"
            ))
        }

        // 6. Unlink the directory entry by name. `unlinkat` with flags=0 does
        // not follow symlinks on macOS, so even if the entry were
        // concurrently swapped for a symlink pointing outside the boundary,
        // we would only ever remove the symlink itself — never its target.
        let unlinkRC = baseName.withCString { ptr in
            unlinkat(dirFd, ptr, 0)
        }
        guard unlinkRC == 0 else {
            let code = errno
            return .skipped(RunIssue(
                severity: .warning,
                message: "Could not remove \(destinationPath): \(String(cString: strerror(code)))"
            ))
        }

        // Close the data fd explicitly so the empty-parent cleanup below
        // does not hold it open across a possible rmdir.
        _ = Darwin.close(fd)
        didClose = true

        // 7. Best-effort empty-parent cleanup, unchanged in spirit.
        if let contents = try? fileManager.contentsOfDirectory(atPath: parentPath),
           contents.isEmpty {
            try? fileManager.removeItem(at: parentURL)
        }

        return .reverted
    }
}

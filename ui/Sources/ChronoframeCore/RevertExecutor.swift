import Foundation

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
    /// Files already missing from disk — Python treats these as "trivially reverted"
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
    /// `completed` mirrors Python's progress: reverted + skipped (NOT including missing).
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
    case invalidReceipt(reason: String)

    public var errorDescription: String? {
        switch self {
        case let .receiptNotFound(path):
            return "The selected revert receipt could not be found. It may have been moved or deleted. Receipt: \(path)."
        case let .invalidReceipt(reason):
            return "Chronoframe could not read this revert receipt. Choose a different receipt or run a new transfer. Details: \(reason)"
        }
    }
}

// MARK: - Executor

public struct RevertExecutor: Sendable {
    private let hasher: FileIdentityHasher

    public init(hasher: FileIdentityHasher = FileIdentityHasher()) {
        self.hasher = hasher
    }

    /// FileManager.default is process-wide and thread-safe for the read/remove
    /// operations we use; we look it up at call sites to keep the struct Sendable.
    private var fileManager: FileManager { .default }

    /// Load a Python-format audit receipt from disk.
    public func loadReceipt(at url: URL) throws -> RevertReceipt {
        guard fileManager.fileExists(atPath: url.path) else {
            throw RevertExecutorError.receiptNotFound(path: url.path)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw RevertExecutorError.invalidReceipt(
                reason: "Could not read receipt: \(error.localizedDescription)"
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

    /// Revert every transfer in `receipt`. Honors the same hash-guard contract as
    /// `chronoframe.core.revert_receipt`: a destination file is removed only when
    /// its current BLAKE2b identity still matches the value recorded at copy time.
    /// Modified or replaced files are left in place.
    @discardableResult
    public func revert(
        receipt: RevertReceipt,
        observer: RevertExecutionObserver = RevertExecutionObserver(),
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> RevertExecutionResult {
        let transfers = receipt.transfers
        observer.onTaskStart(transfers.count)

        var revertedCount = 0
        var skippedCount = 0
        var missingCount = 0

        for transfer in transfers {
            if isCancelled() {
                break
            }

            let destinationPath = transfer.dest
            let destinationURL = URL(fileURLWithPath: destinationPath)

            if !fileManager.fileExists(atPath: destinationPath) {
                // Python parity: missing destination is counted as trivially reverted
                // and does NOT advance the progress counter (which is reverted+skipped).
                missingCount += 1
                continue
            }

            do {
                let currentIdentity = try hasher.hashIdentity(at: destinationURL)
                if currentIdentity.rawValue == transfer.hash {
                    do {
                        try fileManager.removeItem(at: destinationURL)
                        revertedCount += 1

                        // Best-effort empty-directory cleanup, matching Python's
                        // `os.rmdir` swallow-OSError pattern.
                        let parentURL = destinationURL.deletingLastPathComponent()
                        if let contents = try? fileManager.contentsOfDirectory(
                            atPath: parentURL.path
                        ), contents.isEmpty {
                            try? fileManager.removeItem(at: parentURL)
                        }
                    } catch {
                        skippedCount += 1
                        observer.onIssue(
                            RunIssue(
                                severity: .warning,
                                message: "Could not remove \(destinationPath): \(error.localizedDescription)"
                            )
                        )
                    }
                } else {
                    skippedCount += 1
                    observer.onIssue(
                        RunIssue(
                            severity: .info,
                            message: "Preserved (modified since copy): \(destinationPath)"
                        )
                    )
                }
            } catch {
                skippedCount += 1
                observer.onIssue(
                    RunIssue(
                        severity: .warning,
                        message: "Could not re-hash \(destinationPath): \(error.localizedDescription)"
                    )
                )
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
}

#if canImport(ChronoframeCore)
import ChronoframeCore
#endif
import Foundation

public enum DeduplicateEngineError: LocalizedError {
    case destinationMissing
    case scanFailed(String)
    case commitFailed(String)

    public var errorDescription: String? {
        switch self {
        case .destinationMissing:
            return "Choose a destination folder before running a deduplicate scan."
        case let .scanFailed(message):
            return message
        case let .commitFailed(message):
            return message
        }
    }
}

@MainActor
public protocol DeduplicateEngine: AnyObject {
    func scan(_ configuration: DeduplicateConfiguration) throws -> AsyncThrowingStream<DeduplicateEvent, Error>
    func cancelCurrentScan()
    func commit(
        decisions: DedupeDecisions,
        clusters: [DuplicateCluster],
        configuration: DeduplicateConfiguration
    ) throws -> AsyncThrowingStream<DeduplicateCommitEvent, Error>
    func revert(receiptURL: URL) throws -> AsyncThrowingStream<DeduplicateCommitEvent, Error>
}

@MainActor
public final class NativeDeduplicateEngine: DeduplicateEngine {
    private let scanner: DeduplicateScanner
    private let executor: DeduplicateExecutor

    public init(
        scanner: DeduplicateScanner = DeduplicateScanner(),
        executor: DeduplicateExecutor = DeduplicateExecutor()
    ) {
        self.scanner = scanner
        self.executor = executor
    }

    public func scan(_ configuration: DeduplicateConfiguration) throws -> AsyncThrowingStream<DeduplicateEvent, Error> {
        guard !configuration.destinationPath.isEmpty else {
            throw DeduplicateEngineError.destinationMissing
        }
        return scanner.scan(configuration: configuration)
    }

    public func cancelCurrentScan() {
        scanner.cancel()
        executor.cancel()
    }

    public func commit(
        decisions: DedupeDecisions,
        clusters: [DuplicateCluster],
        configuration: DeduplicateConfiguration
    ) throws -> AsyncThrowingStream<DeduplicateCommitEvent, Error> {
        executor.commit(decisions: decisions, clusters: clusters, configuration: configuration)
    }

    public func revert(receiptURL: URL) throws -> AsyncThrowingStream<DeduplicateCommitEvent, Error> {
        executor.revert(receiptURL: receiptURL)
    }
}

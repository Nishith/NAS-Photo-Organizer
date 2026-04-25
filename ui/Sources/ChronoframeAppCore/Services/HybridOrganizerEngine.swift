#if canImport(ChronoframeCore)
import ChronoframeCore
#endif
import Foundation

@MainActor
public final class HybridOrganizerEngine: OrganizerEngine {
    private let previewEngine: any OrganizerEngine
    private let transferEngine: any OrganizerEngine

    public init(
        previewEngine: any OrganizerEngine,
        transferEngine: any OrganizerEngine
    ) {
        self.previewEngine = previewEngine
        self.transferEngine = transferEngine
    }

    public func preflight(_ configuration: RunConfiguration) async throws -> RunPreflight {
        try await engine(for: configuration.mode).preflight(configuration)
    }

    public func start(_ configuration: RunConfiguration) throws -> AsyncThrowingStream<RunEvent, Error> {
        try engine(for: configuration.mode).start(configuration)
    }

    public func resume(_ configuration: RunConfiguration) throws -> AsyncThrowingStream<RunEvent, Error> {
        try engine(for: configuration.mode).resume(configuration)
    }

    public func cancelCurrentRun() {
        previewEngine.cancelCurrentRun()
        transferEngine.cancelCurrentRun()
    }

    private func engine(for mode: RunMode) -> any OrganizerEngine {
        switch mode {
        case .preview:
            return previewEngine
        case .transfer, .revert, .reorganize:
            return transferEngine
        }
    }
}

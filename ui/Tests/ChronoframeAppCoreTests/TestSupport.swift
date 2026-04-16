import Foundation
@testable import ChronoframeAppCore

enum TestFailure: Error, LocalizedError {
    case expectedFailure(String)

    var errorDescription: String? {
        switch self {
        case let .expectedFailure(message):
            return message
        }
    }
}

@MainActor
final class MockOrganizerEngine: OrganizerEngine {
    enum StreamMode {
        case events([RunEvent])
        case fails(Error)
        case pending
    }

    var preflightResult: Result<RunPreflight, Error>
    var startMode: StreamMode
    var resumeMode: StreamMode
    var startConfigurations: [RunConfiguration] = []
    var resumeConfigurations: [RunConfiguration] = []
    var cancelCallCount = 0
    var pendingContinuation: AsyncThrowingStream<RunEvent, Error>.Continuation?

    init(
        preflightResult: Result<RunPreflight, Error>,
        startMode: StreamMode = .events([]),
        resumeMode: StreamMode = .events([])
    ) {
        self.preflightResult = preflightResult
        self.startMode = startMode
        self.resumeMode = resumeMode
    }

    func preflight(_ configuration: RunConfiguration) async throws -> RunPreflight {
        try preflightResult.get()
    }

    func start(_ configuration: RunConfiguration) throws -> AsyncThrowingStream<RunEvent, Error> {
        startConfigurations.append(configuration)
        return try makeStream(for: startMode)
    }

    func resume(_ configuration: RunConfiguration) throws -> AsyncThrowingStream<RunEvent, Error> {
        resumeConfigurations.append(configuration)
        return try makeStream(for: resumeMode)
    }

    func cancelCurrentRun() {
        cancelCallCount += 1
        pendingContinuation?.finish()
        pendingContinuation = nil
    }

    private func makeStream(for mode: StreamMode) throws -> AsyncThrowingStream<RunEvent, Error> {
        switch mode {
        case let .events(events):
            return AsyncThrowingStream { continuation in
                Task { @MainActor in
                    for event in events {
                        continuation.yield(event)
                    }
                    continuation.finish()
                }
            }
        case let .fails(error):
            throw error
        case .pending:
            return AsyncThrowingStream { continuation in
                self.pendingContinuation = continuation
            }
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

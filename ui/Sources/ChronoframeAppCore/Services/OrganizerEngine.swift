#if canImport(ChronoframeCore)
import ChronoframeCore
#endif
import Foundation

public enum OrganizerEngineError: LocalizedError {
    case backendUnavailable
    case pythonUnavailable
    case profileNotFound(String)
    case sourceDoesNotExist(String)
    case destinationMissing
    case missingDependencies([String])
    case failedToLaunch(String)
    case invalidPreflight(String)
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case .backendUnavailable:
            return "Chronoframe could not find the bundled or repository Python backend."
        case .pythonUnavailable:
            return "Chronoframe could not find a working python3 executable."
        case let .profileNotFound(name):
            return "The profile “\(name)” is not defined in profiles.yaml."
        case let .sourceDoesNotExist(path):
            return "The source folder does not exist at \(path)."
        case .destinationMissing:
            return "Choose a destination folder before starting this run."
        case let .missingDependencies(packages):
            return "Missing Python packages: \(packages.joined(separator: ", "))."
        case let .failedToLaunch(message):
            return message
        case let .invalidPreflight(message):
            return message
        case let .invalidOutput(line):
            return "The backend emitted malformed output: \(line)"
        }
    }
}

@MainActor
public protocol OrganizerEngine: AnyObject {
    func preflight(_ configuration: RunConfiguration) async throws -> RunPreflight
    func start(_ configuration: RunConfiguration) throws -> AsyncThrowingStream<RunEvent, Error>
    func resume(_ configuration: RunConfiguration) throws -> AsyncThrowingStream<RunEvent, Error>
    func cancelCurrentRun()
}

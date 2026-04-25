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
            return "Chronoframe could not find the helper it needs to run. Rebuild or reinstall Chronoframe, then try again."
        case .pythonUnavailable:
            return "Chronoframe is set to use the Python helper, but this Mac could not start Python 3. Install Python 3, then try again."
        case let .profileNotFound(name):
            return "The saved profile \"\(name)\" no longer exists. Choose another profile or save it again."
        case let .sourceDoesNotExist(path):
            return "The source folder is no longer available. Reconnect the drive or choose the source folder again. Path: \(path)."
        case .destinationMissing:
            return "Choose a destination folder before starting this run."
        case let .missingDependencies(packages):
            return "The Python helper is missing required packages: \(packages.joined(separator: ", ")). Install them, then try again."
        case let .failedToLaunch(message):
            return UserFacingErrorMessage.withDetails(
                "Chronoframe could not start the organizer. Try again; if it keeps happening, restart or reinstall Chronoframe.",
                details: message
            )
        case let .invalidPreflight(message):
            return UserFacingErrorMessage.withDetails(
                "Chronoframe could not validate the run settings. Review the source and destination, then try again.",
                details: message
            )
        case let .invalidOutput(line):
            return UserFacingErrorMessage.withDetails(
                "Chronoframe received an unexpected response from its helper. Try again.",
                details: line
            )
        }
    }
}

@MainActor
public protocol OrganizerEngine: AnyObject {
    func preflight(_ configuration: RunConfiguration) async throws -> RunPreflight
    func start(_ configuration: RunConfiguration) throws -> AsyncThrowingStream<RunEvent, Error>
    func resume(_ configuration: RunConfiguration) throws -> AsyncThrowingStream<RunEvent, Error>
    func cancelCurrentRun()

    /// Revert a previous transfer using its on-disk audit receipt. Emits
    /// `RunEvent`s identical in shape to a normal run so the same UI surface
    /// can render progress and the final summary.
    func revert(receiptURL: URL, destinationRoot: String) throws -> AsyncThrowingStream<RunEvent, Error>

    /// In-place layout migration: move every recognised file under
    /// `destinationRoot` so it sits in the directory layout described by
    /// `targetStructure`. No source folder is required — this only touches
    /// files already present in the destination.
    func reorganize(
        destinationRoot: String,
        targetStructure: FolderStructure
    ) throws -> AsyncThrowingStream<RunEvent, Error>
}

extension OrganizerEngine {
    public func revert(receiptURL: URL, destinationRoot: String) throws -> AsyncThrowingStream<RunEvent, Error> {
        throw OrganizerEngineError.failedToLaunch("Revert is not supported by this engine.")
    }

    public func reorganize(
        destinationRoot: String,
        targetStructure: FolderStructure
    ) throws -> AsyncThrowingStream<RunEvent, Error> {
        throw OrganizerEngineError.failedToLaunch("Reorganize is not supported by this engine.")
    }
}

import Foundation
#if canImport(ChronoframeCore)
import ChronoframeCore
#endif

public enum UserFacingErrorContext: Sendable {
    case generic
    case setup
    case droppedItems
    case profiles
    case run
    case history

    fileprivate var fallbackMessage: String {
        switch self {
        case .generic:
            return "Chronoframe ran into a problem. Try again."
        case .setup:
            return "Chronoframe could not update Setup. Choose the folder again, or check that the drive is connected."
        case .droppedItems:
            return "Chronoframe could not use the dropped items. Try choosing the source folder with the picker instead."
        case .profiles:
            return "Chronoframe could not update saved profiles. Check that Chronoframe can write to its settings, then try again."
        case .run:
            return "Chronoframe could not finish this run. Your source files were left untouched. Check that both folders are available, then try again."
        case .history:
            return "Chronoframe could not refresh Run History. Check that the destination drive is connected, then try again."
        }
    }
}

public enum UserFacingErrorMessage {
    public static func message(for error: Error, context: UserFacingErrorContext = .generic) -> String {
        if let message = specificMessage(for: error) {
            return message
        }

        if let message = commonFoundationMessage(for: error as NSError) {
            return message
        }

        if error is DecodingError {
            return "Chronoframe could not read one of its saved files because the file format looked different than expected. Run a new preview or transfer to create a fresh file."
        }

        return withDetails(context.fallbackMessage, details: error.localizedDescription)
    }

    public static func backendPrompt(_ message: String) -> String {
        let message = cleaned(message)
        guard !message.isEmpty else {
            return "Chronoframe needs one more choice before it can continue. Review Setup, then try again."
        }

        if message.localizedCaseInsensitiveContains("Source and Destination must be provided") {
            return "Choose both a source folder and a destination folder before starting."
        }

        if message.localizedCaseInsensitiveContains("No valid media files found in source") {
            return "Chronoframe did not find supported photo or video files in the source. Choose a different source folder, then try again."
        }

        return withDetails(
            "Chronoframe needs attention before it can continue. Review the message below, then try again.",
            details: message
        )
    }

    public static func runIssueMessage(_ message: String, severity: RunSeverity) -> String {
        let message = cleaned(message)
        guard !message.isEmpty else {
            switch severity {
            case .info:
                return "Chronoframe reported an update."
            case .warning:
                return "Chronoframe reported a warning, but did not include details."
            case .error:
                return "Chronoframe reported a problem, but did not include details."
            }
        }

        if message.localizedCaseInsensitiveContains("Source and Destination must be provided") {
            return "Choose both a source folder and a destination folder before starting."
        }

        if message.localizedCaseInsensitiveContains("No valid media files found in source") {
            return "Chronoframe did not find supported photo or video files in the source. Choose a different source folder, then try again."
        }

        if let payload = payload(after: "Verification failed:", in: message) {
            let parts = splitSourceDestination(payload)
            return "Chronoframe copied this file but could not verify the copy, so the destination copy was removed and the source was left untouched. Source: \(parts.source). Destination: \(parts.destination)."
        }

        if let payload = payload(after: "Copy failed:", in: message) {
            let parsed = splitSourceDestinationDetails(payload)
            return withDetails(
                "Chronoframe could not copy this file, so the source was left untouched. Source: \(parsed.source). Destination: \(parsed.destination).",
                details: parsed.details
            )
        }

        if let payload = payload(after: "Unexpected hash error for", in: message) {
            let parsed = splitPathDetails(payload)
            return withDetails(
                "Chronoframe could not check this file, so it skipped it. File: \(parsed.path).",
                details: parsed.details
            )
        }

        if let path = payload(after: "Receipt not found:", in: message) {
            return "The selected revert receipt could not be found. It may have been moved or deleted. Receipt: \(path)."
        }

        if let details = payload(after: "Invalid receipt:", in: message) {
            return withDetails(
                "Chronoframe could not read this revert receipt. Choose a different receipt or run a new transfer.",
                details: details
            )
        }

        if let payload = payload(after: "Could not remove", in: message) {
            let parsed = splitPathDetails(payload)
            return withDetails(
                "Chronoframe could not remove this copied file during revert, so it was left in place. File: \(parsed.path).",
                details: parsed.details
            )
        }

        if let payload = payload(after: "Could not re-hash", in: message) {
            let parsed = splitPathDetails(payload)
            return withDetails(
                "Chronoframe could not check whether this file changed, so it was left in place. File: \(parsed.path).",
                details: parsed.details
            )
        }

        if let path = payload(after: "Preserved (modified since copy):", in: message) {
            return "Chronoframe kept this file because it has changed since the original transfer. File: \(path)."
        }

        if let path = payload(after: "Source no longer exists:", in: message) {
            return "A file disappeared before Chronoframe could move it. File: \(path)."
        }

        if let path = payload(after: "Destination exists, skipping:", in: message) {
            return "A file already exists at the new location, so Chronoframe left the original in place. Destination: \(path)."
        }

        if let payload = payload(after: "Could not move", in: message) {
            let parsed = splitPathDetails(payload)
            return withDetails(
                "Chronoframe could not move this file inside the destination. It was left where it is. File: \(parsed.path).",
                details: parsed.details
            )
        }

        if message.hasPrefix("Cleaned "), message.contains(" orphaned .tmp files") {
            return message
                .replacingOccurrences(of: "orphaned .tmp files", with: "temporary files left by an interrupted run")
        }

        return message
    }

    public static func withDetails(_ message: String, details: String?) -> String {
        let details = cleaned(details ?? "")
        guard !details.isEmpty else { return message }
        guard details != message else { return message }
        return "\(message) Details: \(details)"
    }

    private static func specificMessage(for error: Error) -> String? {
        switch error {
        case let error as OrganizerEngineError:
            return error.errorDescription
        case let error as FolderValidationError:
            return error.errorDescription
        case let error as DroppedItemStagerError:
            return error.errorDescription
        case let error as RevertExecutorError:
            return error.errorDescription
        case let error as ReorganizeExecutorError:
            return error.errorDescription
        case let error as OrganizerDatabaseError:
            return error.errorDescription
        default:
            return nil
        }
    }

    private static func commonFoundationMessage(for error: NSError) -> String? {
        if error.domain == NSPOSIXErrorDomain, let code = POSIXErrorCode(rawValue: Int32(error.code)) {
            switch code {
            case .ENOENT, .ENOTDIR:
                return withPath(
                    "A file or folder Chronoframe needs is no longer available. Reconnect the drive or choose the folder again, then try again.",
                    error: error
                )
            case .EACCES, .EPERM:
                return withPath(
                    "macOS is blocking access to a file or folder. Choose the folder again to grant access, or check Privacy & Security settings.",
                    error: error
                )
            case .ENOSPC:
                return withPath(
                    "The destination drive is out of space. Free up space or choose a different destination, then try again.",
                    error: error
                )
            case .EROFS:
                return withPath(
                    "The destination is read-only. Choose a writable folder or change the drive permissions, then try again.",
                    error: error
                )
            default:
                return nil
            }
        }

        guard error.domain == NSCocoaErrorDomain else { return nil }
        let code = CocoaError.Code(rawValue: error.code)
        switch code {
        case .fileNoSuchFile, .fileReadNoSuchFile:
            return withPath(
                "A file or folder Chronoframe needs is no longer available. Reconnect the drive or choose the folder again, then try again.",
                error: error
            )
        case .fileReadNoPermission, .fileWriteNoPermission:
            return withPath(
                "macOS is blocking access to a file or folder. Choose the folder again to grant access, or check Privacy & Security settings.",
                error: error
            )
        case .fileWriteOutOfSpace:
            return withPath(
                "The destination drive is out of space. Free up space or choose a different destination, then try again.",
                error: error
            )
        case .fileWriteVolumeReadOnly:
            return withPath(
                "The destination is read-only. Choose a writable folder or change the drive permissions, then try again.",
                error: error
            )
        case .fileReadCorruptFile:
            return withPath(
                "Chronoframe could not read a saved file because it appears to be damaged. Run a new preview or transfer to create a fresh file.",
                error: error
            )
        default:
            return nil
        }
    }

    private static func withPath(_ message: String, error: NSError) -> String {
        guard let path = error.userInfo[NSFilePathErrorKey] as? String, !path.isEmpty else {
            return message
        }
        return "\(message) Path: \(path)."
    }

    private static func payload(after prefix: String, in message: String) -> String? {
        guard message.hasPrefix(prefix) else { return nil }
        return cleaned(String(message.dropFirst(prefix.count)))
    }

    private static func splitSourceDestination(_ payload: String) -> (source: String, destination: String) {
        let parts = payload.components(separatedBy: " -> ")
        guard parts.count >= 2 else {
            return (cleaned(payload), "unknown")
        }
        return (cleaned(parts[0]), cleaned(parts.dropFirst().joined(separator: " -> ")))
    }

    private static func splitSourceDestinationDetails(_ payload: String) -> (source: String, destination: String, details: String?) {
        let parts = payload.components(separatedBy: " -> ")
        guard parts.count >= 2 else {
            return (cleaned(payload), "unknown", nil)
        }

        let source = cleaned(parts[0])
        let destinationAndDetails = parts.dropFirst().joined(separator: " -> ")
        let parsed = splitPathDetails(destinationAndDetails)
        return (source, parsed.path, parsed.details)
    }

    private static func splitPathDetails(_ payload: String) -> (path: String, details: String?) {
        let trimmed = cleaned(payload)
        guard let separator = trimmed.lastIndex(of: ":") else {
            return (trimmed, nil)
        }

        let path = cleaned(String(trimmed[..<separator]))
        let details = cleaned(String(trimmed[trimmed.index(after: separator)...]))
        guard !path.isEmpty, !details.isEmpty else {
            return (trimmed, nil)
        }
        return (path, details)
    }

    private static func cleaned(_ message: String) -> String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

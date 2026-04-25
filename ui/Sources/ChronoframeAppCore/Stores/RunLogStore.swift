#if canImport(ChronoframeCore)
import ChronoframeCore
#endif
import Foundation
import Combine

public struct RunLogEntry: Identifiable, Equatable {
    public let id: Int
    public let text: String

    fileprivate let byteCount: Int
    fileprivate let severity: Severity

    fileprivate enum Severity {
        case info
        case warning
        case error
    }
}

public final class RunLogStore: ObservableObject {
    public static let minimumBufferedBytes = 256 * 1024
    public static let estimatedBytesPerConfiguredLine = 512
    private static let compactionThreshold = 512

    @Published private var revision = 0
    @Published public var capacity: Int {
        didSet {
            let clamped = max(PreferencesStore.minimumLogCapacity, min(PreferencesStore.maximumLogCapacity, capacity))
            if clamped != capacity {
                capacity = clamped
                return
            }

            trimIfNeeded()
            revision &+= 1
        }
    }

    private var storage: [RunLogEntry] = []
    private var headIndex = 0
    private var nextIdentifier = 0
    private var bufferedByteCount = 0
    private var warningCountValue = 0
    private var errorCountValue = 0

    public init(capacity: Int = 2_000) {
        self.capacity = max(PreferencesStore.minimumLogCapacity, min(PreferencesStore.maximumLogCapacity, capacity))
    }

    public var entries: ArraySlice<RunLogEntry> {
        storage[headIndex...]
    }

    public var lines: [String] {
        entries.map(\.text)
    }

    public var warningCount: Int {
        warningCountValue
    }

    public var errorCount: Int {
        errorCountValue
    }

    public var infoCount: Int {
        max(0, visibleCount - warningCountValue - errorCountValue)
    }

    public func clear() {
        guard visibleCount > 0 else {
            return
        }

        storage.removeAll(keepingCapacity: true)
        headIndex = 0
        bufferedByteCount = 0
        warningCountValue = 0
        errorCountValue = 0
        revision &+= 1
    }

    public func append(_ line: String) {
        append(line, severity: Self.classifySeverity(for: line))
    }

    public func append(issue: RunIssue) {
        let friendlyIssue = RunIssue(
            id: issue.id,
            severity: issue.severity,
            message: UserFacingErrorMessage.runIssueMessage(issue.message, severity: issue.severity)
        )
        append(friendlyIssue.renderedLine, severity: Self.classifySeverity(for: friendlyIssue.severity))
    }

    private var visibleCount: Int {
        storage.count - headIndex
    }

    private var maximumBufferedByteCount: Int {
        max(Self.minimumBufferedBytes, capacity * Self.estimatedBytesPerConfiguredLine)
    }

    private func append(_ line: String, severity: RunLogEntry.Severity) {
        let byteCount = line.lengthOfBytes(using: .utf8)
        storage.append(
            RunLogEntry(
                id: nextIdentifier,
                text: line,
                byteCount: byteCount,
                severity: severity
            )
        )
        nextIdentifier &+= 1
        bufferedByteCount += byteCount

        switch severity {
        case .info:
            break
        case .warning:
            warningCountValue += 1
        case .error:
            errorCountValue += 1
        }

        trimIfNeeded()
        revision &+= 1
    }

    private func trimIfNeeded() {
        while visibleCount > capacity || bufferedByteCount > maximumBufferedByteCount {
            guard headIndex < storage.count else {
                break
            }

            let removedEntry = storage[headIndex]
            bufferedByteCount -= removedEntry.byteCount

            switch removedEntry.severity {
            case .info:
                break
            case .warning:
                warningCountValue = max(0, warningCountValue - 1)
            case .error:
                errorCountValue = max(0, errorCountValue - 1)
            }

            headIndex += 1
        }

        compactIfNeeded()
    }

    private func compactIfNeeded() {
        guard
            headIndex > 0,
            headIndex >= Self.compactionThreshold,
            headIndex * 2 >= storage.count
        else {
            return
        }

        storage.removeFirst(headIndex)
        headIndex = 0
    }

    private static func classifySeverity(for line: String) -> RunLogEntry.Severity {
        if line.hasPrefix("ERROR:") {
            return .error
        }
        if line.hasPrefix("WARNING:") || line.hasPrefix("⚠") {
            return .warning
        }
        return .info
    }

    private static func classifySeverity(for severity: RunSeverity) -> RunLogEntry.Severity {
        switch severity {
        case .info:
            return .info
        case .warning:
            return .warning
        case .error:
            return .error
        }
    }
}

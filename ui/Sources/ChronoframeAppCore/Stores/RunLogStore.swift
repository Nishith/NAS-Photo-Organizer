#if canImport(ChronoframeCore)
import ChronoframeCore
#endif
import Foundation
import Combine

public final class RunLogStore: ObservableObject {
    @Published public private(set) var lines: [String]
    @Published public var capacity: Int {
        didSet {
            capacity = max(PreferencesStore.minimumLogCapacity, min(PreferencesStore.maximumLogCapacity, capacity))
            trimIfNeeded()
        }
    }

    public init(capacity: Int = 2_000) {
        self.capacity = max(PreferencesStore.minimumLogCapacity, min(PreferencesStore.maximumLogCapacity, capacity))
        self.lines = []
    }

    public var warningCount: Int {
        lines.filter { $0.hasPrefix("⚠") || $0.hasPrefix("WARNING:") }.count
    }

    public var errorCount: Int {
        lines.filter { $0.hasPrefix("ERROR:") }.count
    }

    public var infoCount: Int {
        max(0, lines.count - warningCount - errorCount)
    }

    public func clear() {
        lines.removeAll(keepingCapacity: true)
    }

    public func append(_ line: String) {
        lines.append(line)
        trimIfNeeded()
    }

    public func append(issue: RunIssue) {
        append(issue.renderedLine)
    }

    private func trimIfNeeded() {
        let overflow = lines.count - capacity
        if overflow > 0 {
            lines.removeFirst(overflow)
        }
    }
}

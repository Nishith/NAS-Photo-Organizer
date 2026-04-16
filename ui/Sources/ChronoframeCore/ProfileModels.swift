import Foundation

public struct Profile: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: String { name }
    public var name: String
    public var sourcePath: String
    public var destinationPath: String

    public init(name: String, sourcePath: String, destinationPath: String) {
        self.name = name
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
    }
}

public enum FolderRole: String, Codable, Sendable {
    case source
    case destination
}

public struct FolderBookmark: Codable, Equatable, Sendable {
    public var key: String
    public var path: String
    public var data: Data

    public init(key: String, path: String, data: Data) {
        self.key = key
        self.path = path
        self.data = data
    }
}

public enum RunHistoryEntryKind: String, Codable, CaseIterable, Sendable {
    case dryRunReport
    case auditReceipt
    case runLog
    case queueDatabase
    case csvArtifact
    case jsonArtifact

    public var title: String {
        switch self {
        case .dryRunReport:
            return "Dry Run Report"
        case .auditReceipt:
            return "Audit Receipt"
        case .runLog:
            return "Run Log"
        case .queueDatabase:
            return "Queue Database"
        case .csvArtifact:
            return "CSV Artifact"
        case .jsonArtifact:
            return "JSON Artifact"
        }
    }

    public var systemImage: String {
        switch self {
        case .dryRunReport:
            return "doc.text.magnifyingglass"
        case .auditReceipt:
            return "checklist"
        case .runLog:
            return "text.append"
        case .queueDatabase:
            return "internaldrive"
        case .csvArtifact:
            return "tablecells"
        case .jsonArtifact:
            return "curlybraces"
        }
    }
}

public struct RunHistoryEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: RunHistoryEntryKind
    public let title: String
    public let path: String
    public let relativePath: String
    public let fileSizeBytes: Int64?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: RunHistoryEntryKind,
        title: String,
        path: String,
        relativePath: String? = nil,
        fileSizeBytes: Int64? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.path = path
        self.relativePath = relativePath ?? URL(fileURLWithPath: path).lastPathComponent
        self.fileSizeBytes = fileSizeBytes
        self.createdAt = createdAt
    }
}

public enum SidebarDestination: String, CaseIterable, Identifiable, Hashable, Sendable {
    case setup
    case currentRun
    case history
    case profiles

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .setup:
            return "Setup"
        case .currentRun:
            return "Current Run"
        case .history:
            return "Run History"
        case .profiles:
            return "Profiles"
        }
    }

    public var subtitle: String {
        switch self {
        case .setup:
            return "Choose folders and options"
        case .currentRun:
            return "Watch progress and logs"
        case .history:
            return "Inspect reports and receipts"
        case .profiles:
            return "Reuse source and destination pairs"
        }
    }

    public var systemImage: String {
        switch self {
        case .setup:
            return "slider.horizontal.3"
        case .currentRun:
            return "bolt.horizontal.circle"
        case .history:
            return "clock.arrow.circlepath"
        case .profiles:
            return "person.crop.rectangle.stack"
        }
    }
}

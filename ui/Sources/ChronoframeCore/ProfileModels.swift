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
    case dedupeAuditReceipt
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
        case .dedupeAuditReceipt:
            return "Dedupe Receipt"
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
        case .dedupeAuditReceipt:
            return "rectangle.on.rectangle.angled"
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
    case organize
    case deduplicate
    case profiles

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .organize:
            return "Organize"
        case .deduplicate:
            return "Deduplicate"
        case .profiles:
            return "Profiles"
        }
    }

    public var subtitle: String {
        switch self {
        case .organize:
            return "Setup, run, and run history"
        case .deduplicate:
            return "Find similar shots and prune"
        case .profiles:
            return "Reusable saved setups"
        }
    }

    public var systemImage: String {
        switch self {
        case .organize:
            return "square.stack.3d.up"
        case .deduplicate:
            return "rectangle.on.rectangle.angled"
        case .profiles:
            return "person.crop.rectangle.stack"
        }
    }
}

/// Sub-sections nested inside the Organize sidebar destination. The original
/// Setup / Run / Run History flows live here.
public enum OrganizeSubSection: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
    case setup
    case run
    case history

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .setup:
            return "Setup"
        case .run:
            return "Run"
        case .history:
            return "History"
        }
    }

    public var subtitle: String {
        switch self {
        case .setup:
            return "Source, destination, readiness"
        case .run:
            return "Preview, transfer, inspect"
        case .history:
            return "Reports, receipts, logs"
        }
    }

    public var systemImage: String {
        switch self {
        case .setup:
            return "slider.horizontal.3"
        case .run:
            return "bolt.horizontal.circle"
        case .history:
            return "clock.arrow.circlepath"
        }
    }
}

/// Two-axis routing target. Combines the top-level sidebar destination with
/// the optional Organize sub-section so coordinators can navigate to a
/// specific tab+sub-tab in one call.
public enum AppRoute: Hashable, Sendable {
    case organize(OrganizeSubSection)
    case deduplicate
    case profiles

    public var sidebar: SidebarDestination {
        switch self {
        case .organize: return .organize
        case .deduplicate: return .deduplicate
        case .profiles: return .profiles
        }
    }

    public var organizeSubSection: OrganizeSubSection? {
        if case let .organize(sub) = self { return sub }
        return nil
    }
}

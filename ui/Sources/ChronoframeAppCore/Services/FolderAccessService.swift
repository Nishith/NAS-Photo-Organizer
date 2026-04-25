import AppKit
#if canImport(ChronoframeCore)
import ChronoframeCore
#endif
import Foundation

public struct ResolvedFolderBookmark: Equatable, Sendable {
    public let url: URL
    public let refreshedBookmark: FolderBookmark?

    public init(url: URL, refreshedBookmark: FolderBookmark? = nil) {
        self.url = url
        self.refreshedBookmark = refreshedBookmark
    }
}

public enum FolderValidationError: LocalizedError, Equatable, Sendable {
    case pathDoesNotExist(role: FolderRole, path: String)
    case notDirectory(role: FolderRole, path: String)
    case unreadable(role: FolderRole, path: String)
    case unwritable(role: FolderRole, path: String)

    public var errorDescription: String? {
        switch self {
        case let .pathDoesNotExist(role, path):
            return "The \(role.rawValue) folder is no longer available. Reconnect the drive or choose the \(role.rawValue) folder again. Path: \(path)."
        case let .notDirectory(role, path):
            return "The selected \(role.rawValue) item is not a folder. Choose a folder instead. Path: \(path)."
        case let .unreadable(role, path):
            return "Chronoframe cannot read the \(role.rawValue) folder. Choose it again to grant access, or pick a folder you have permission to open. Path: \(path)."
        case let .unwritable(role, path):
            return "Chronoframe cannot write to the \(role.rawValue) folder. Choose it again to grant access, pick a writable folder, or check that the drive is not read-only. Path: \(path)."
        }
    }
}

@MainActor
public protocol FolderAccessServicing: AnyObject {
    func chooseFolder(startingAt path: String?, prompt: String) -> URL?
    func makeBookmark(for url: URL, key: String) throws -> FolderBookmark
    func resolveBookmark(_ bookmark: FolderBookmark) -> ResolvedFolderBookmark?
    func validateFolder(_ url: URL, role: FolderRole) throws
}

@MainActor
public final class FolderAccessService: FolderAccessServicing {
    public init() {}

    public func chooseFolder(startingAt path: String? = nil, prompt: String = "Choose Folder") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt

        if let path, !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: path)
        }

        return panel.runModal() == .OK ? panel.url : nil
    }

    public func makeBookmark(for url: URL, key: String) throws -> FolderBookmark {
        let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        return FolderBookmark(key: key, path: url.path, data: data)
    }

    public func resolveBookmark(_ bookmark: FolderBookmark) -> ResolvedFolderBookmark? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark.data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return ResolvedFolderBookmark(url: URL(fileURLWithPath: bookmark.path))
        }

        _ = url.startAccessingSecurityScopedResource()
        let refreshedBookmark = isStale ? try? makeBookmark(for: url, key: bookmark.key) : nil
        return ResolvedFolderBookmark(url: url, refreshedBookmark: refreshedBookmark)
    }

    public func validateFolder(_ url: URL, role: FolderRole) throws {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw FolderValidationError.pathDoesNotExist(role: role, path: url.path)
        }
        guard isDirectory.boolValue else {
            throw FolderValidationError.notDirectory(role: role, path: url.path)
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw FolderValidationError.unreadable(role: role, path: url.path)
        }
        if role == .destination && !FileManager.default.isWritableFile(atPath: url.path) {
            throw FolderValidationError.unwritable(role: role, path: url.path)
        }
    }
}

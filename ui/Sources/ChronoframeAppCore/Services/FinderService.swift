import AppKit
import Foundation

@MainActor
public protocol FinderServicing: AnyObject {
    func openPath(_ path: String)
    func revealInFinder(_ path: String)
}

@MainActor
public final class FinderService: FinderServicing {
    public init() {}

    public func openPath(_ path: String) {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    public func revealInFinder(_ path: String) {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

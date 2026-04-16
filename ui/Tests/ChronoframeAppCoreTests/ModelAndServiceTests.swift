import Foundation
import XCTest
@testable import ChronoframeAppCore

final class ModelAndServiceTests: XCTestCase {
    func testRunStatusMappingAndIssueRendering() {
        XCTAssertEqual(RunStatus(backendStatus: "dry_run_finished"), .dryRunFinished)
        XCTAssertEqual(RunStatus(backendStatus: "finished"), .finished)
        XCTAssertEqual(RunStatus(backendStatus: "nothing_to_copy"), .nothingToCopy)
        XCTAssertEqual(RunStatus(backendStatus: "cancelled"), .cancelled)
        XCTAssertEqual(RunStatus(backendStatus: "idle"), .idle)
        XCTAssertEqual(RunStatus(backendStatus: "mystery"), .failed)

        XCTAssertEqual(RunIssue(severity: .info, message: "Started").renderedLine, "ℹ Started")
        XCTAssertEqual(RunIssue(severity: .warning, message: "Slow disk").renderedLine, "⚠ Slow disk")
        XCTAssertEqual(RunIssue(severity: .error, message: "Copy failed").renderedLine, "ERROR: Copy failed")
    }

    func testPhaseAndSidebarMetadataAreNonEmpty() {
        for phase in RunPhase.allCases {
            XCTAssertFalse(phase.title.isEmpty)
            XCTAssertFalse(phase.runningTitle.isEmpty)
        }

        for destination in SidebarDestination.allCases {
            XCTAssertFalse(destination.title.isEmpty)
            XCTAssertFalse(destination.subtitle.isEmpty)
            XCTAssertFalse(destination.systemImage.isEmpty)
        }

        for kind in RunHistoryEntryKind.allCases {
            XCTAssertFalse(kind.title.isEmpty)
            XCTAssertFalse(kind.systemImage.isEmpty)
        }
    }

    func testOrganizerEngineErrorsExposeDescriptions() {
        let errors: [OrganizerEngineError] = [
            .backendUnavailable,
            .pythonUnavailable,
            .profileNotFound("travel"),
            .sourceDoesNotExist("/tmp/source"),
            .destinationMissing,
            .missingDependencies(["rich"]),
            .failedToLaunch("boom"),
            .invalidPreflight("bad input"),
            .invalidOutput("not json"),
        ]

        for error in errors {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty)
        }
    }

    @MainActor
    func testFinderServiceIgnoresEmptyPaths() {
        let service = FinderService()
        service.openPath("")
        service.revealInFinder("")
    }

    @MainActor
    func testFolderAccessServiceFallsBackForInvalidBookmark() {
        let service = FolderAccessService()
        let bookmark = FolderBookmark(key: "manual.source", path: "/tmp/fallback", data: Data([0x00, 0x01]))

        XCTAssertEqual(service.resolveBookmark(bookmark)?.url.path, "/tmp/fallback")
    }

    @MainActor
    func testFolderAccessServiceValidatesDirectoryCapabilities() throws {
        let service = FolderAccessService()
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("item.txt")
        try Data("hello".utf8).write(to: fileURL)

        XCTAssertNoThrow(try service.validateFolder(root, role: .source))
        XCTAssertNoThrow(try service.validateFolder(root, role: .destination))

        XCTAssertThrowsError(try service.validateFolder(fileURL, role: .source)) { error in
            XCTAssertEqual(
                error as? FolderValidationError,
                .notDirectory(role: .source, path: fileURL.path)
            )
        }

        let missingURL = root.appendingPathComponent("missing", isDirectory: true)
        XCTAssertThrowsError(try service.validateFolder(missingURL, role: .destination)) { error in
            XCTAssertEqual(
                error as? FolderValidationError,
                .pathDoesNotExist(role: .destination, path: missingURL.path)
            )
        }
    }
}

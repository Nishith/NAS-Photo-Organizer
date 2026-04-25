#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import Foundation
import XCTest
@testable import ChronoframeApp

final class SetupCoordinatorTests: XCTestCase {
    @MainActor
    func testChooseFoldersUpdatesManualPathsBookmarksAndHistory() async {
        let sourceURL = URL(fileURLWithPath: "/Volumes/Card")
        let destinationURL = URL(fileURLWithPath: "/Volumes/Archive")
        let harness = AppStateHarness()
        let resolver = BookmarkPathResolver(
            preferencesStore: harness.preferencesStore,
            folderAccessService: harness.folderAccessService
        )
        var transientError: String?
        let coordinator = SetupCoordinator(
            preferencesStore: harness.preferencesStore,
            setupStore: harness.setupStore,
            historyStore: harness.historyStore,
            folderAccessService: harness.folderAccessService,
            profilesRepository: harness.repository,
            droppedItemStager: DroppedItemStager(),
            bookmarkPathResolver: resolver,
            setSelection: { _ in },
            setTransientErrorMessage: { transientError = $0 }
        )

        harness.folderAccessService.nextChosenFolder = sourceURL
        await coordinator.chooseSourceFolder()

        XCTAssertNil(transientError)
        XCTAssertEqual(harness.setupStore.sourcePath, sourceURL.path)
        XCTAssertEqual(harness.preferencesStore.lastManualSourcePath, sourceURL.path)
        XCTAssertEqual(harness.preferencesStore.bookmark(for: "manual.source")?.path, sourceURL.path)

        harness.folderAccessService.nextChosenFolder = destinationURL
        await coordinator.chooseDestinationFolder()

        XCTAssertEqual(harness.setupStore.destinationPath, destinationURL.path)
        XCTAssertEqual(harness.preferencesStore.lastManualDestinationPath, destinationURL.path)
        XCTAssertEqual(harness.preferencesStore.bookmark(for: "manual.destination")?.path, destinationURL.path)
        XCTAssertEqual(harness.historyStore.destinationRoot, destinationURL.path)
    }

    @MainActor
    func testChooseFolderValidationFailureSurfacesErrorWithoutChangingState() async {
        let sourceURL = URL(fileURLWithPath: "/Volumes/Locked")
        let harness = AppStateHarness()
        let resolver = BookmarkPathResolver(
            preferencesStore: harness.preferencesStore,
            folderAccessService: harness.folderAccessService
        )
        harness.folderAccessService.nextChosenFolder = sourceURL
        harness.folderAccessService.validationFailures[sourceURL.path] = FolderValidationError.unreadable(
            role: .source,
            path: sourceURL.path
        )
        var transientError: String?
        let coordinator = SetupCoordinator(
            preferencesStore: harness.preferencesStore,
            setupStore: harness.setupStore,
            historyStore: harness.historyStore,
            folderAccessService: harness.folderAccessService,
            profilesRepository: harness.repository,
            droppedItemStager: DroppedItemStager(),
            bookmarkPathResolver: resolver,
            setSelection: { _ in },
            setTransientErrorMessage: { transientError = $0 }
        )

        await coordinator.chooseSourceFolder()

        XCTAssertEqual(
            transientError,
            "Chronoframe cannot read the source folder. Choose it again to grant access, or pick a folder you have permission to open. Path: /Volumes/Locked."
        )
        XCTAssertEqual(harness.setupStore.sourcePath, "")
        XCTAssertNil(harness.preferencesStore.bookmark(for: "manual.source"))
    }

    @MainActor
    func testProfileLifecyclePreservesBookmarksAndSelection() {
        let harness = AppStateHarness()
        let resolver = BookmarkPathResolver(
            preferencesStore: harness.preferencesStore,
            folderAccessService: harness.folderAccessService
        )
        var selection: SidebarDestination?
        let coordinator = SetupCoordinator(
            preferencesStore: harness.preferencesStore,
            setupStore: harness.setupStore,
            historyStore: harness.historyStore,
            folderAccessService: harness.folderAccessService,
            profilesRepository: harness.repository,
            droppedItemStager: DroppedItemStager(),
            bookmarkPathResolver: resolver,
            setSelection: { selection = $0 },
            setTransientErrorMessage: { _ in }
        )

        harness.repository.profiles = [
            Profile(name: "travel", sourcePath: "/Volumes/Card", destinationPath: "/Volumes/Trips")
        ]
        harness.preferencesStore.storeBookmark(FolderBookmark(key: "manual.source", path: "/Volumes/Card", data: Data([0x01])))
        harness.preferencesStore.storeBookmark(FolderBookmark(key: "manual.destination", path: "/Volumes/Trips", data: Data([0x02])))

        coordinator.refreshProfiles()
        coordinator.useProfile(named: "travel")

        XCTAssertEqual(harness.setupStore.selectedProfileName, "travel")
        XCTAssertEqual(harness.historyStore.destinationRoot, "/Volumes/Trips")

        harness.setupStore.newProfileName = "archive"
        coordinator.saveCurrentPathsAsProfile()

        XCTAssertEqual(selection, .profiles)
        XCTAssertEqual(harness.repository.savedProfiles.last?.name, "archive")
        XCTAssertEqual(harness.setupStore.selectedProfileName, "archive")
        XCTAssertEqual(harness.preferencesStore.bookmark(for: "profile.archive.source")?.path, "/Volumes/Card")
        XCTAssertEqual(harness.preferencesStore.bookmark(for: "profile.archive.destination")?.path, "/Volumes/Trips")

        coordinator.deleteProfile(named: "travel")
        XCTAssertEqual(harness.repository.deletedProfileNames, ["travel"])
    }

    @MainActor
    func testUseAndClearProfileRestoreBookmarkedPathsAndHistory() {
        let harness = AppStateHarness()
        let resolver = BookmarkPathResolver(
            preferencesStore: harness.preferencesStore,
            folderAccessService: harness.folderAccessService
        )
        let coordinator = SetupCoordinator(
            preferencesStore: harness.preferencesStore,
            setupStore: harness.setupStore,
            historyStore: harness.historyStore,
            folderAccessService: harness.folderAccessService,
            profilesRepository: harness.repository,
            droppedItemStager: DroppedItemStager(),
            bookmarkPathResolver: resolver,
            setSelection: { _ in },
            setTransientErrorMessage: { _ in }
        )

        harness.repository.profiles = [
            Profile(name: "travel", sourcePath: "/Volumes/YAML-Card", destinationPath: "/Volumes/YAML-Trips")
        ]
        harness.preferencesStore.lastManualSourcePath = "/Volumes/ManualCard"
        harness.preferencesStore.lastManualDestinationPath = "/Volumes/ManualArchive"
        harness.preferencesStore.storeBookmark(
            FolderBookmark(key: "profile.travel.source", path: "/Volumes/Bookmark-Card", data: Data([0x03]))
        )
        harness.preferencesStore.storeBookmark(
            FolderBookmark(key: "profile.travel.destination", path: "/Volumes/Bookmark-Trips", data: Data([0x04]))
        )
        harness.folderAccessService.resolvedBookmarks["profile.travel.source"] = ResolvedFolderBookmark(
            url: URL(fileURLWithPath: "/Volumes/Resolved-Card")
        )
        harness.folderAccessService.resolvedBookmarks["profile.travel.destination"] = ResolvedFolderBookmark(
            url: URL(fileURLWithPath: "/Volumes/Resolved-Trips"),
            refreshedBookmark: FolderBookmark(key: "profile.travel.destination", path: "/Volumes/Resolved-Trips", data: Data([0x44]))
        )

        coordinator.refreshProfiles()
        coordinator.useProfile(named: "travel")

        XCTAssertEqual(harness.setupStore.sourcePath, "/Volumes/Resolved-Card")
        XCTAssertEqual(harness.setupStore.destinationPath, "/Volumes/Resolved-Trips")
        XCTAssertEqual(harness.historyStore.destinationRoot, "/Volumes/Resolved-Trips")

        coordinator.clearSelectedProfile()

        XCTAssertEqual(harness.setupStore.selectedProfileName, "")
        XCTAssertEqual(harness.historyStore.destinationRoot, "/Volumes/ManualArchive")
        XCTAssertEqual(harness.preferencesStore.lastSelectedProfileName, "")
    }

    @MainActor
    func testSaveCurrentPathsAsProfileValidatesInputs() {
        let harness = AppStateHarness()
        let resolver = BookmarkPathResolver(
            preferencesStore: harness.preferencesStore,
            folderAccessService: harness.folderAccessService
        )
        var transientError: String?
        let coordinator = SetupCoordinator(
            preferencesStore: harness.preferencesStore,
            setupStore: harness.setupStore,
            historyStore: harness.historyStore,
            folderAccessService: harness.folderAccessService,
            profilesRepository: harness.repository,
            droppedItemStager: DroppedItemStager(),
            bookmarkPathResolver: resolver,
            setSelection: { _ in },
            setTransientErrorMessage: { transientError = $0 }
        )

        coordinator.saveCurrentPathsAsProfile()
        XCTAssertEqual(transientError, "Enter a profile name before saving.")

        transientError = nil
        harness.setupStore.newProfileName = "travel"
        coordinator.saveCurrentPathsAsProfile()
        XCTAssertEqual(transientError, "Choose both a source and destination before saving a profile.")
    }
}

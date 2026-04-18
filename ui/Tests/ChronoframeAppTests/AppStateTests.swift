#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import Foundation
import XCTest
@testable import ChronoframeApp

final class AppStateTests: XCTestCase {
    @MainActor
    func testChooseFoldersUpdatesManualPathsBookmarksAndHistory() async {
        let sourceURL = URL(fileURLWithPath: "/Volumes/Card")
        let destinationURL = URL(fileURLWithPath: "/Volumes/Archive")
        let harness = AppStateHarness()
        harness.folderAccessService.nextChosenFolder = sourceURL

        let appState = harness.makeAppState()
        await appState.chooseSourceFolder()

        XCTAssertEqual(appState.setupStore.sourcePath, sourceURL.path)
        XCTAssertEqual(appState.preferencesStore.lastManualSourcePath, sourceURL.path)
        XCTAssertEqual(appState.preferencesStore.bookmark(for: "manual.source")?.path, sourceURL.path)

        harness.folderAccessService.nextChosenFolder = destinationURL
        await appState.chooseDestinationFolder()

        XCTAssertEqual(appState.setupStore.destinationPath, destinationURL.path)
        XCTAssertEqual(appState.preferencesStore.lastManualDestinationPath, destinationURL.path)
        XCTAssertEqual(appState.preferencesStore.bookmark(for: "manual.destination")?.path, destinationURL.path)
        XCTAssertEqual(appState.historyStore.destinationRoot, destinationURL.path)
    }

    @MainActor
    func testChooseFolderValidationFailureSurfacesErrorWithoutChangingState() async {
        let sourceURL = URL(fileURLWithPath: "/Volumes/Locked")
        let harness = AppStateHarness()
        harness.folderAccessService.nextChosenFolder = sourceURL
        harness.folderAccessService.validationFailures[sourceURL.path] = FolderValidationError.unreadable(
            role: .source,
            path: sourceURL.path
        )
        let appState = harness.makeAppState()

        await appState.chooseSourceFolder()

        XCTAssertEqual(
            appState.transientErrorMessage,
            "Chronoframe cannot read the selected source folder: /Volumes/Locked"
        )
        XCTAssertEqual(appState.setupStore.sourcePath, "")
        XCTAssertNil(appState.preferencesStore.bookmark(for: "manual.source"))
    }

    @MainActor
    func testInitialStateRestoresManualBookmarksAndRefreshesStaleBookmarkData() {
        let harness = AppStateHarness()
        harness.preferencesStore.storeBookmark(
            FolderBookmark(key: "manual.source", path: "/Volumes/OldCard", data: Data([0x01]))
        )
        harness.preferencesStore.storeBookmark(
            FolderBookmark(key: "manual.destination", path: "/Volumes/OldArchive", data: Data([0x02]))
        )
        harness.folderAccessService.resolvedBookmarks["manual.source"] = ResolvedFolderBookmark(
            url: URL(fileURLWithPath: "/Volumes/NewCard"),
            refreshedBookmark: FolderBookmark(key: "manual.source", path: "/Volumes/NewCard", data: Data([0x11]))
        )
        harness.folderAccessService.resolvedBookmarks["manual.destination"] = ResolvedFolderBookmark(
            url: URL(fileURLWithPath: "/Volumes/NewArchive"),
            refreshedBookmark: FolderBookmark(key: "manual.destination", path: "/Volumes/NewArchive", data: Data([0x22]))
        )

        let appState = harness.makeAppState()

        XCTAssertEqual(appState.setupStore.sourcePath, "/Volumes/NewCard")
        XCTAssertEqual(appState.setupStore.destinationPath, "/Volumes/NewArchive")
        XCTAssertEqual(appState.preferencesStore.lastManualSourcePath, "/Volumes/NewCard")
        XCTAssertEqual(appState.preferencesStore.lastManualDestinationPath, "/Volumes/NewArchive")
        XCTAssertEqual(appState.preferencesStore.bookmark(for: "manual.source")?.path, "/Volumes/NewCard")
        XCTAssertEqual(appState.preferencesStore.bookmark(for: "manual.destination")?.path, "/Volumes/NewArchive")
    }

    @MainActor
    func testUseProfileAndSaveProfileUpdateSelectionRepositoryAndBookmarks() {
        let harness = AppStateHarness()
        harness.repository.profiles = [
            Profile(name: "travel", sourcePath: "/Volumes/Card", destinationPath: "/Volumes/Trips")
        ]
        harness.preferencesStore.storeBookmark(FolderBookmark(key: "manual.source", path: "/Volumes/Card", data: Data([0x01])))
        harness.preferencesStore.storeBookmark(FolderBookmark(key: "manual.destination", path: "/Volumes/Trips", data: Data([0x02])))

        let appState = harness.makeAppState()
        appState.refreshProfiles()
        appState.useProfile(named: "travel")

        XCTAssertEqual(appState.setupStore.selectedProfileName, "travel")
        XCTAssertEqual(appState.setupStore.sourcePath, "/Volumes/Card")
        XCTAssertEqual(appState.historyStore.destinationRoot, "/Volumes/Trips")
        XCTAssertEqual(appState.preferencesStore.lastSelectedProfileName, "travel")

        appState.setupStore.newProfileName = "archive"
        appState.saveCurrentPathsAsProfile()

        XCTAssertEqual(harness.repository.savedProfiles.last?.name, "archive")
        XCTAssertEqual(appState.selection, .profiles)
        XCTAssertEqual(appState.setupStore.selectedProfileName, "archive")
        XCTAssertEqual(appState.preferencesStore.bookmark(for: "profile.archive.source")?.path, "/Volumes/Card")
        XCTAssertEqual(appState.preferencesStore.bookmark(for: "profile.archive.destination")?.path, "/Volumes/Trips")
    }

    @MainActor
    func testUseProfileRestoresBookmarkedPathsAndRefreshesHistory() {
        let harness = AppStateHarness()
        harness.repository.profiles = [
            Profile(name: "travel", sourcePath: "/Volumes/YAML-Card", destinationPath: "/Volumes/YAML-Trips")
        ]
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

        let appState = harness.makeAppState()
        appState.refreshProfiles()
        appState.useProfile(named: "travel")

        XCTAssertEqual(appState.setupStore.sourcePath, "/Volumes/Resolved-Card")
        XCTAssertEqual(appState.setupStore.destinationPath, "/Volumes/Resolved-Trips")
        XCTAssertEqual(appState.historyStore.destinationRoot, "/Volumes/Resolved-Trips")
        XCTAssertEqual(appState.preferencesStore.bookmark(for: "profile.travel.destination")?.path, "/Volumes/Resolved-Trips")
    }

    @MainActor
    func testDeleteProfileClearsBookmarksAndSelection() {
        let harness = AppStateHarness()
        harness.repository.profiles = [
            Profile(name: "travel", sourcePath: "/Volumes/Card", destinationPath: "/Volumes/Trips")
        ]
        harness.preferencesStore.storeBookmark(FolderBookmark(key: "profile.travel.source", path: "/Volumes/Card", data: Data([0x01])))
        harness.preferencesStore.storeBookmark(FolderBookmark(key: "profile.travel.destination", path: "/Volumes/Trips", data: Data([0x02])))

        let appState = harness.makeAppState()
        appState.refreshProfiles()
        appState.useProfile(named: "travel")
        appState.deleteProfile(named: "travel")

        XCTAssertEqual(harness.repository.deletedProfileNames, ["travel"])
        XCTAssertEqual(appState.setupStore.selectedProfileName, "")
        XCTAssertNil(appState.preferencesStore.bookmark(for: "profile.travel.source"))
        XCTAssertNil(appState.preferencesStore.bookmark(for: "profile.travel.destination"))
    }

    @MainActor
    func testClearSelectedProfileReturnsToManualDestinationHistory() {
        let harness = AppStateHarness()
        harness.repository.profiles = [
            Profile(name: "travel", sourcePath: "/Volumes/Card", destinationPath: "/Volumes/Trips")
        ]
        harness.preferencesStore.lastManualSourcePath = "/Volumes/ManualCard"
        harness.preferencesStore.lastManualDestinationPath = "/Volumes/ManualArchive"
        let appState = harness.makeAppState()

        appState.refreshProfiles()
        appState.useProfile(named: "travel")
        XCTAssertEqual(appState.historyStore.destinationRoot, "/Volumes/Trips")

        appState.clearSelectedProfile()

        XCTAssertEqual(appState.setupStore.selectedProfileName, "")
        XCTAssertEqual(appState.historyStore.destinationRoot, "/Volumes/ManualArchive")
        XCTAssertEqual(appState.preferencesStore.lastSelectedProfileName, "")
    }

    @MainActor
    func testStartPreviewSelectsCurrentRunAndFinderActionsUseRunArtifacts() async {
        let harness = AppStateHarness()
        harness.setupStore.sourcePath = "/tmp/source"
        harness.setupStore.destinationPath = "/tmp/destination"
        harness.engine.startMode = .events([
            .complete(
                RunSummary(
                    status: .dryRunFinished,
                    title: "Preview complete",
                    metrics: RunMetrics(plannedCount: 1),
                    artifacts: RunArtifactPaths(
                        destinationRoot: "/tmp/destination",
                        reportPath: "/tmp/destination/.organize_logs/dry_run_report.csv",
                        logFilePath: "/tmp/destination/.organize_log.txt",
                        logsDirectoryPath: "/tmp/destination/.organize_logs"
                    )
                )
            )
        ])
        let appState = harness.makeAppState()
        appState.setupStore.sourcePath = "/tmp/source"
        appState.setupStore.destinationPath = "/tmp/destination"

        await appState.startPreview()
        let finished = await waitForCondition { appState.runSessionStore.summary != nil }

        XCTAssertTrue(finished)
        XCTAssertEqual(appState.selection, .run)
        XCTAssertEqual(harness.engine.startConfigurations.count, 1)

        appState.openDestination()
        appState.openReport()
        appState.openLogsDirectory()

        XCTAssertEqual(harness.finderService.openedPaths, [
            "/tmp/destination",
            "/tmp/destination/.organize_logs/dry_run_report.csv",
            "/tmp/destination/.organize_logs",
        ])
    }

    @MainActor
    func testRefreshProfilesFailureAndSettingsActionSurfaceThroughAppState() {
        let harness = AppStateHarness()
        harness.repository.loadError = AppTestFailure.expectedFailure("profiles failed")
        var settingsOpened = 0

        let appState = harness.makeAppState(showSettingsWindowAction: {
            settingsOpened += 1
        })

        XCTAssertEqual(appState.transientErrorMessage, "profiles failed")
        appState.dismissTransientError()
        XCTAssertNil(appState.transientErrorMessage)

        appState.openSettingsWindow()
        XCTAssertEqual(settingsOpened, 1)
    }

    @MainActor
    func testSaveCurrentPathsAsProfileValidatesInputs() {
        let harness = AppStateHarness()
        let appState = harness.makeAppState()

        appState.saveCurrentPathsAsProfile()
        XCTAssertEqual(appState.transientErrorMessage, "Enter a profile name before saving.")

        appState.setupStore.newProfileName = "travel"
        appState.saveCurrentPathsAsProfile()
        XCTAssertEqual(appState.transientErrorMessage, "Choose both a source and destination before saving a profile.")
    }

    @MainActor
    func testStartTransferPromptRoutingAndHistoryActions() async {
        let harness = AppStateHarness()
        harness.setupStore.sourcePath = "/tmp/source"
        harness.setupStore.destinationPath = "/tmp/destination"
        harness.engine.preflightResult = .success(
            RunPreflight(
                configuration: RunConfiguration(mode: .transfer, sourcePath: "/tmp/source", destinationPath: "/tmp/destination"),
                resolvedSourcePath: "/tmp/source",
                resolvedDestinationPath: "/tmp/destination",
                pendingJobCount: 2
            )
        )
        harness.engine.resumeMode = .events([
            .complete(
                RunSummary(
                    status: .finished,
                    title: "Transfer complete",
                    metrics: RunMetrics(copiedCount: 3),
                    artifacts: RunArtifactPaths(destinationRoot: "/tmp/destination")
                )
            )
        ])
        let appState = harness.makeAppState()
        appState.setupStore.sourcePath = "/tmp/source"
        appState.setupStore.destinationPath = "/tmp/destination"

        await appState.startTransfer()

        XCTAssertEqual(appState.selection, .run)
        XCTAssertEqual(appState.runSessionStore.prompt?.kind, .resumePendingJobs)

        appState.confirmRunPrompt()
        let finished = await waitForCondition { appState.runSessionStore.summary?.status == .finished }

        XCTAssertTrue(finished)
        XCTAssertEqual(harness.engine.resumeConfigurations.count, 1)

        let entry = RunHistoryEntry(kind: .runLog, title: "Run Log", path: "/tmp/destination/.organize_log.txt", createdAt: Date())
        appState.openHistoryEntry(entry)
        appState.revealHistoryEntry(entry)
        appState.cancelRun()

        XCTAssertEqual(harness.finderService.openedPaths.last, "/tmp/destination/.organize_log.txt")
        XCTAssertEqual(harness.finderService.revealedPaths, ["/tmp/destination/.organize_log.txt"])
        XCTAssertEqual(harness.engine.cancelCallCount, 1)
    }

    @MainActor
    func testDismissRunPromptLeavesSessionIdle() async {
        let harness = AppStateHarness()
        harness.setupStore.sourcePath = "/tmp/source"
        harness.setupStore.destinationPath = "/tmp/destination"
        harness.engine.preflightResult = .success(
            RunPreflight(
                configuration: RunConfiguration(mode: .transfer, sourcePath: "/tmp/source", destinationPath: "/tmp/destination"),
                resolvedSourcePath: "/tmp/source",
                resolvedDestinationPath: "/tmp/destination"
            )
        )
        let appState = harness.makeAppState()
        appState.setupStore.sourcePath = "/tmp/source"
        appState.setupStore.destinationPath = "/tmp/destination"

        await appState.startTransfer()
        XCTAssertEqual(appState.runSessionStore.prompt?.kind, .confirmTransfer)

        appState.dismissRunPrompt()

        XCTAssertNil(appState.runSessionStore.prompt)
        XCTAssertEqual(appState.runSessionStore.status, .idle)
    }
}

@MainActor
private final class AppStateHarness {
    let suiteName: String
    let defaults: UserDefaults
    let preferencesStore: PreferencesStore
    let setupStore: SetupStore
    let runLogStore: RunLogStore
    let historyStore: HistoryStore
    let repository: MockProfilesRepository
    let folderAccessService: MockFolderAccessService
    let finderService: MockFinderService
    let engine: MockOrganizerEngine
    let runSessionStore: RunSessionStore

    init() {
        suiteName = "AppStateTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        preferencesStore = PreferencesStore(defaults: defaults)
        setupStore = SetupStore()
        runLogStore = RunLogStore(capacity: 300)
        historyStore = HistoryStore()
        repository = MockProfilesRepository()
        folderAccessService = MockFolderAccessService()
        finderService = MockFinderService()
        engine = MockOrganizerEngine(
            preflightResult: .success(
                RunPreflight(
                    configuration: RunConfiguration(mode: .preview, sourcePath: "/tmp/source", destinationPath: "/tmp/destination"),
                    resolvedSourcePath: "/tmp/source",
                    resolvedDestinationPath: "/tmp/destination"
                )
            ),
            startMode: .events([
                .complete(
                    RunSummary(
                        status: .dryRunFinished,
                        title: "Preview complete",
                        metrics: RunMetrics(plannedCount: 1),
                        artifacts: RunArtifactPaths(destinationRoot: "/tmp/destination")
                    )
                )
            ])
        )
        runSessionStore = RunSessionStore(engine: engine, logStore: runLogStore, historyStore: historyStore)
    }

    func makeAppState(
        showSettingsWindowAction: @escaping @MainActor () -> Void = {}
    ) -> AppState {
        AppState(
            preferencesStore: self.preferencesStore,
            setupStore: self.setupStore,
            runLogStore: self.runLogStore,
            historyStore: self.historyStore,
            runSessionStore: self.runSessionStore,
            folderAccessService: self.folderAccessService,
            finderService: self.finderService,
            profilesRepository: self.repository,
            showSettingsWindowAction: showSettingsWindowAction
        )
    }
}

@MainActor
private final class MockFolderAccessService: FolderAccessServicing {
    var nextChosenFolder: URL?
    var bookmarkURLs: [URL] = []
    var resolvedBookmarks: [String: ResolvedFolderBookmark] = [:]
    var validationFailures: [String: Error] = [:]

    func chooseFolder(startingAt path: String?, prompt: String) -> URL? {
        nextChosenFolder
    }

    func makeBookmark(for url: URL, key: String) throws -> FolderBookmark {
        bookmarkURLs.append(url)
        return FolderBookmark(key: key, path: url.path, data: Data(url.path.utf8))
    }

    func resolveBookmark(_ bookmark: FolderBookmark) -> ResolvedFolderBookmark? {
        resolvedBookmarks[bookmark.key] ?? ResolvedFolderBookmark(url: URL(fileURLWithPath: bookmark.path))
    }

    func validateFolder(_ url: URL, role: FolderRole) throws {
        if let error = validationFailures[url.path] {
            throw error
        }
    }
}

@MainActor
private final class MockFinderService: FinderServicing {
    var openedPaths: [String] = []
    var revealedPaths: [String] = []

    func openPath(_ path: String) {
        openedPaths.append(path)
    }

    func revealInFinder(_ path: String) {
        revealedPaths.append(path)
    }
}

private final class MockProfilesRepository: ProfilesRepositorying {
    var profiles: [Profile] = []
    var savedProfiles: [Profile] = []
    var deletedProfileNames: [String] = []
    var loadError: Error?
    var saveError: Error?
    var deleteError: Error?

    func profilesFileURL() -> URL {
        URL(fileURLWithPath: "/tmp/mock-profiles.yaml")
    }

    func loadProfiles() throws -> [Profile] {
        if let loadError {
            throw loadError
        }
        return profiles
    }

    func save(profile: Profile) throws {
        if let saveError {
            throw saveError
        }
        savedProfiles.append(profile)
        profiles.removeAll { $0.name == profile.name }
        profiles.append(profile)
    }

    func deleteProfile(named name: String) throws {
        if let deleteError {
            throw deleteError
        }
        deletedProfileNames.append(name)
        profiles.removeAll { $0.name == name }
    }
}

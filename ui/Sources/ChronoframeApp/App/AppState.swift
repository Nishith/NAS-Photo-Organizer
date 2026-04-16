import AppKit
#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var selection: SidebarDestination
    @Published var transientErrorMessage: String?

    var preferencesStore: PreferencesStore
    var setupStore: SetupStore
    var runLogStore: RunLogStore
    var historyStore: HistoryStore
    var runSessionStore: RunSessionStore

    private let folderAccessService: any FolderAccessServicing
    private let finderService: any FinderServicing
    private let profilesRepository: any ProfilesRepositorying
    private let showSettingsWindowAction: @MainActor () -> Void

    convenience init() {
        let preferencesStore = PreferencesStore()
        let profilesRepository = ProfilesRepository()
        let folderAccessService = FolderAccessService()
        let finderService = FinderService()
        let setupStore = SetupStore(
            sourcePath: preferencesStore.lastManualSourcePath,
            destinationPath: preferencesStore.lastManualDestinationPath,
            selectedProfileName: preferencesStore.lastSelectedProfileName
        )
        let runLogStore = RunLogStore(capacity: preferencesStore.logBufferCapacity)
        let historyStore = HistoryStore()
        let engine: any OrganizerEngine
        switch RuntimePaths.appEnginePreference() {
        case .swift:
            engine = SwiftOrganizerEngine(profilesRepository: profilesRepository)
        case .python:
            engine = PythonOrganizerEngine(profilesRepository: profilesRepository)
        }
        let runSessionStore = RunSessionStore(engine: engine, logStore: runLogStore, historyStore: historyStore)

        self.init(
            preferencesStore: preferencesStore,
            setupStore: setupStore,
            runLogStore: runLogStore,
            historyStore: historyStore,
            runSessionStore: runSessionStore,
            folderAccessService: folderAccessService,
            finderService: finderService,
            profilesRepository: profilesRepository
        )
    }

    init(
        selection: SidebarDestination = .setup,
        preferencesStore: PreferencesStore,
        setupStore: SetupStore,
        runLogStore: RunLogStore,
        historyStore: HistoryStore,
        runSessionStore: RunSessionStore,
        folderAccessService: any FolderAccessServicing,
        finderService: any FinderServicing,
        profilesRepository: any ProfilesRepositorying,
        showSettingsWindowAction: @escaping @MainActor () -> Void = {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    ) {
        self.selection = selection
        self.transientErrorMessage = nil
        self.preferencesStore = preferencesStore
        self.setupStore = setupStore
        self.runLogStore = runLogStore
        self.historyStore = historyStore
        self.runSessionStore = runSessionStore
        self.folderAccessService = folderAccessService
        self.finderService = finderService
        self.profilesRepository = profilesRepository
        self.showSettingsWindowAction = showSettingsWindowAction

        restoreManualPaths()
        refreshProfiles()
        historyStore.refresh(destinationRoot: setupStore.destinationPath)
    }

    var canStartRun: Bool {
        setupStore.usingProfile || (!setupStore.sourcePath.isEmpty && !setupStore.destinationPath.isEmpty)
    }

    func dismissTransientError() {
        transientErrorMessage = nil
    }

    func chooseSourceFolder() async {
        if let url = folderAccessService.chooseFolder(startingAt: setupStore.sourcePath, prompt: "Choose Source Folder") {
            do {
                try folderAccessService.validateFolder(url, role: .source)
            } catch {
                transientErrorMessage = error.localizedDescription
                return
            }
            setupStore.sourcePath = url.path
            preferencesStore.lastManualSourcePath = url.path
            persistBookmark(for: url, key: bookmarkKey(for: .source, profileName: nil))
            if !setupStore.usingProfile {
                preferencesStore.lastSelectedProfileName = ""
            }
        }
    }

    func chooseDestinationFolder() async {
        if let url = folderAccessService.chooseFolder(startingAt: setupStore.destinationPath, prompt: "Choose Destination Folder") {
            do {
                try folderAccessService.validateFolder(url, role: .destination)
            } catch {
                transientErrorMessage = error.localizedDescription
                return
            }
            setupStore.destinationPath = url.path
            preferencesStore.lastManualDestinationPath = url.path
            persistBookmark(for: url, key: bookmarkKey(for: .destination, profileName: nil))
            historyStore.refresh(destinationRoot: url.path)
            if !setupStore.usingProfile {
                preferencesStore.lastSelectedProfileName = ""
            }
        }
    }

    func useProfile(named name: String) {
        setupStore.selectProfile(named: name)
        preferencesStore.lastSelectedProfileName = setupStore.selectedProfileName
        if let activeProfile = setupStore.activeProfile {
            restoreProfilePaths(named: activeProfile.name)
            historyStore.refresh(destinationRoot: setupStore.destinationPath)
        } else if !setupStore.usingProfile {
            historyStore.refresh(destinationRoot: setupStore.destinationPath)
        }
    }

    func clearSelectedProfile() {
        setupStore.clearProfileSelection()
        preferencesStore.lastSelectedProfileName = ""
        restoreManualPaths()
        historyStore.refresh(destinationRoot: setupStore.destinationPath)
    }

    func refreshProfiles() {
        do {
            let profiles = try profilesRepository.loadProfiles()
            setupStore.updateProfiles(profiles)
            if setupStore.usingProfile {
                setupStore.selectProfile(named: setupStore.selectedProfileName)
            }
        } catch {
            transientErrorMessage = error.localizedDescription
        }
    }

    func saveCurrentPathsAsProfile() {
        let name = setupStore.newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            transientErrorMessage = "Enter a profile name before saving."
            return
        }
        guard !setupStore.sourcePath.isEmpty, !setupStore.destinationPath.isEmpty else {
            transientErrorMessage = "Choose both a source and destination before saving a profile."
            return
        }

        let profile = Profile(name: name, sourcePath: setupStore.sourcePath, destinationPath: setupStore.destinationPath)

        do {
            try profilesRepository.save(profile: profile)
            if let sourceBookmark = preferencesStore.bookmark(for: bookmarkKey(for: .source, profileName: nil)) {
                preferencesStore.storeBookmark(FolderBookmark(key: bookmarkKey(for: .source, profileName: name), path: sourceBookmark.path, data: sourceBookmark.data))
            }
            if let destinationBookmark = preferencesStore.bookmark(for: bookmarkKey(for: .destination, profileName: nil)) {
                preferencesStore.storeBookmark(FolderBookmark(key: bookmarkKey(for: .destination, profileName: name), path: destinationBookmark.path, data: destinationBookmark.data))
            }
            setupStore.newProfileName = ""
            refreshProfiles()
            useProfile(named: name)
            selection = .profiles
        } catch {
            transientErrorMessage = error.localizedDescription
        }
    }

    func overwriteProfile(named name: String) {
        setupStore.newProfileName = name
        saveCurrentPathsAsProfile()
    }

    func deleteProfile(named name: String) {
        do {
            try profilesRepository.deleteProfile(named: name)
            preferencesStore.removeBookmark(for: bookmarkKey(for: .source, profileName: name))
            preferencesStore.removeBookmark(for: bookmarkKey(for: .destination, profileName: name))
            if setupStore.selectedProfileName == name {
                clearSelectedProfile()
            }
            refreshProfiles()
        } catch {
            transientErrorMessage = error.localizedDescription
        }
    }

    func startPreview() async {
        guard canStartRun else { return }
        selection = .currentRun
        await runSessionStore.requestRun(mode: .preview, configuration: setupStore.makeConfiguration(preferences: preferencesStore, mode: .preview))
    }

    func startTransfer() async {
        guard canStartRun else { return }
        selection = .currentRun
        await runSessionStore.requestRun(mode: .transfer, configuration: setupStore.makeConfiguration(preferences: preferencesStore, mode: .transfer))
    }

    func confirmRunPrompt() async {
        runSessionStore.confirmPrompt()
    }

    func dismissRunPrompt() {
        runSessionStore.dismissPrompt()
    }

    func cancelRun() {
        runSessionStore.cancelCurrentRun()
    }

    func openDestination() {
        finderService.openPath(runSessionStore.summary?.artifacts.destinationRoot ?? historyStore.destinationRoot)
    }

    func openReport() {
        if let path = runSessionStore.summary?.artifacts.reportPath {
            finderService.openPath(path)
        }
    }

    func openLogsDirectory() {
        if let path = runSessionStore.summary?.artifacts.logsDirectoryPath {
            finderService.openPath(path)
        }
    }

    func openSettingsWindow() {
        showSettingsWindowAction()
    }

    func revealHistoryEntry(_ entry: RunHistoryEntry) {
        finderService.revealInFinder(entry.path)
    }

    func openHistoryEntry(_ entry: RunHistoryEntry) {
        finderService.openPath(entry.path)
    }

    private func bookmarkKey(for role: FolderRole, profileName: String?) -> String {
        if let profileName {
            return "profile.\(profileName).\(role.rawValue)"
        }
        return "manual.\(role.rawValue)"
    }

    private func persistBookmark(for url: URL, key: String) {
        guard let bookmark = try? folderAccessService.makeBookmark(for: url, key: key) else { return }
        preferencesStore.storeBookmark(bookmark)
    }

    private func restoreManualPaths() {
        setupStore.sourcePath = preferencesStore.lastManualSourcePath
        setupStore.destinationPath = preferencesStore.lastManualDestinationPath

        if let sourcePath = resolveBookmarkedPath(for: .source, profileName: nil) {
            setupStore.sourcePath = sourcePath
            preferencesStore.lastManualSourcePath = sourcePath
        }

        if let destinationPath = resolveBookmarkedPath(for: .destination, profileName: nil) {
            setupStore.destinationPath = destinationPath
            preferencesStore.lastManualDestinationPath = destinationPath
        }
    }

    private func restoreProfilePaths(named profileName: String) {
        if let sourcePath = resolveBookmarkedPath(for: .source, profileName: profileName) {
            setupStore.sourcePath = sourcePath
        }

        if let destinationPath = resolveBookmarkedPath(for: .destination, profileName: profileName) {
            setupStore.destinationPath = destinationPath
        }
    }

    private func resolveBookmarkedPath(for role: FolderRole, profileName: String?) -> String? {
        let key = bookmarkKey(for: role, profileName: profileName)
        guard let bookmark = preferencesStore.bookmark(for: key),
              let resolvedBookmark = folderAccessService.resolveBookmark(bookmark)
        else {
            return nil
        }

        if let refreshedBookmark = resolvedBookmark.refreshedBookmark {
            preferencesStore.storeBookmark(refreshedBookmark)
        }

        return resolvedBookmark.url.path
    }
}

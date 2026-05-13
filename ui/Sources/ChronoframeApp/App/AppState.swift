import AppKit
#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import Foundation

@MainActor
final class AppState: ObservableObject {
    private static let deduplicateDestinationBookmarkKey = "deduplicate.destination"

    @Published var selection: SidebarDestination
    @Published var organizeSubSelection: OrganizeSubSection
    @Published var settingsSelection: SettingsTab
    @Published var transientErrorMessage: String?

    var preferencesStore: PreferencesStore
    var setupStore: SetupStore
    var runLogStore: RunLogStore
    var historyStore: HistoryStore
    var runSessionStore: RunSessionStore
    var previewReviewStore: PreviewReviewStore
    var libraryHealthStore: LibraryHealthStore
    var deduplicateSessionStore: DeduplicateSessionStore

    private let folderAccessService: any FolderAccessServicing
    private let finderService: any FinderServicing
    private let profilesRepository: any ProfilesRepositorying
    private let droppedItemStager: DroppedItemStager
    private let showSettingsWindowAction: @MainActor () -> Void
    private lazy var bookmarkPathResolver = BookmarkPathResolver(
        preferencesStore: preferencesStore,
        folderAccessService: folderAccessService
    )
    private lazy var setupCoordinator = SetupCoordinator(
        preferencesStore: preferencesStore,
        setupStore: setupStore,
        historyStore: historyStore,
        folderAccessService: folderAccessService,
        profilesRepository: profilesRepository,
        droppedItemStager: droppedItemStager,
        bookmarkPathResolver: bookmarkPathResolver,
        navigate: { [weak self] route in
            self?.navigate(to: route)
        },
        setTransientErrorMessage: { [weak self] message in
            self?.transientErrorMessage = message
        }
    )
    private lazy var runCoordinator = RunCoordinator(
        preferencesStore: preferencesStore,
        setupStore: setupStore,
        historyStore: historyStore,
        runSessionStore: runSessionStore,
        finderService: finderService,
        showSettingsWindowAction: showSettingsWindowAction,
        navigate: { [weak self] route in
            self?.navigate(to: route)
        },
        canStartRun: { [weak self] in
            self?.canStartRun ?? false
        },
        makeSecurityScope: { [weak self] _ in
            self?.organizeSecurityScope()
        }
    )
    private lazy var historyCoordinator = HistoryCoordinator(
        preferencesStore: preferencesStore,
        setupStore: setupStore,
        historyStore: historyStore,
        runSessionStore: runSessionStore,
        deduplicateSessionStore: deduplicateSessionStore,
        finderService: finderService,
        navigate: { [weak self] route in
            self?.navigate(to: route)
        },
        makeSecurityScopeForDestination: { [weak self] destinationRoot in
            self?.destinationSecurityScope(destinationRoot: destinationRoot)
        }
    )

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
        #if MAS_BUILD
        engine = SwiftOrganizerEngine(profilesRepository: profilesRepository)
        #else
        switch RuntimePaths.appEnginePreference() {
        case .swift:
            engine = SwiftOrganizerEngine(profilesRepository: profilesRepository)
        case .python:
            engine = PythonOrganizerEngine(profilesRepository: profilesRepository)
        }
        #endif
        let runSessionStore = RunSessionStore(engine: engine, logStore: runLogStore, historyStore: historyStore)
        let previewReviewStore = PreviewReviewStore()
        let libraryHealthStore = LibraryHealthStore()
        let deduplicateEngine = NativeDeduplicateEngine()
        let deduplicateSessionStore = DeduplicateSessionStore(engine: deduplicateEngine)

        self.init(
            preferencesStore: preferencesStore,
            setupStore: setupStore,
            runLogStore: runLogStore,
            historyStore: historyStore,
            runSessionStore: runSessionStore,
            previewReviewStore: previewReviewStore,
            libraryHealthStore: libraryHealthStore,
            deduplicateSessionStore: deduplicateSessionStore,
            folderAccessService: folderAccessService,
            finderService: finderService,
            profilesRepository: profilesRepository,
            restoreBookmarksDuringBootstrap: false
        )
    }

    init(
        route: AppRoute = .organize(.setup),
        preferencesStore: PreferencesStore,
        setupStore: SetupStore,
        runLogStore: RunLogStore,
        historyStore: HistoryStore,
        runSessionStore: RunSessionStore,
        previewReviewStore: PreviewReviewStore? = nil,
        libraryHealthStore: LibraryHealthStore? = nil,
        deduplicateSessionStore: DeduplicateSessionStore? = nil,
        folderAccessService: any FolderAccessServicing,
        finderService: any FinderServicing,
        profilesRepository: any ProfilesRepositorying,
        droppedItemStager: DroppedItemStager = DroppedItemStager(),
        performInitialBootstrap: Bool = true,
        restoreBookmarksDuringBootstrap: Bool = true,
        showSettingsWindowAction: @escaping @MainActor () -> Void = {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    ) {
        self.selection = route.sidebar
        self.organizeSubSelection = route.organizeSubSection ?? .setup
        self.settingsSelection = .general
        self.transientErrorMessage = nil
        self.preferencesStore = preferencesStore
        self.setupStore = setupStore
        self.runLogStore = runLogStore
        self.historyStore = historyStore
        self.runSessionStore = runSessionStore
        self.previewReviewStore = previewReviewStore ?? PreviewReviewStore()
        self.libraryHealthStore = libraryHealthStore ?? LibraryHealthStore()
        self.deduplicateSessionStore = deduplicateSessionStore ?? DeduplicateSessionStore(engine: NativeDeduplicateEngine())
        self.folderAccessService = folderAccessService
        self.finderService = finderService
        self.profilesRepository = profilesRepository
        self.droppedItemStager = droppedItemStager
        self.showSettingsWindowAction = showSettingsWindowAction

        if performInitialBootstrap {
            setupCoordinator.bootstrap(restoreBookmarks: restoreBookmarksDuringBootstrap)
            restoreDeduplicateDestinationBookmark()
        }
    }

    var canStartRun: Bool {
        setupStore.usingProfile || (!setupStore.sourcePath.isEmpty && !setupStore.destinationPath.isEmpty)
    }

    /// Single navigation entry point. Setting both sidebar selection and the
    /// nested Organize sub-section in one place keeps the two-axis routing
    /// consistent across coordinators and views.
    func navigate(to route: AppRoute) {
        selection = route.sidebar
        if let sub = route.organizeSubSection {
            organizeSubSelection = sub
        }
    }

    func dismissTransientError() {
        transientErrorMessage = nil
    }

    func chooseSourceFolder() async {
        await setupCoordinator.chooseSourceFolder()
    }

    /// Handles files/folders dragged onto the app. Single-folder drops
    /// are used directly; file drops and multi-item drops get staged into
    /// a symlink directory so the existing pipeline can walk them. Falls
    /// back to `transientErrorMessage` on failure.
    func applyDrop(urls: [URL]) async {
        await setupCoordinator.applyDrop(urls: urls)
    }

    func chooseDestinationFolder() async {
        await setupCoordinator.chooseDestinationFolder()
    }

    func useProfile(named name: String) {
        setupCoordinator.useProfile(named: name)
    }

    func clearSelectedProfile() {
        setupCoordinator.clearSelectedProfile()
    }

    func refreshProfiles() {
        setupCoordinator.refreshProfiles()
    }

    func saveCurrentPathsAsProfile() {
        setupCoordinator.saveCurrentPathsAsProfile()
    }

    func overwriteProfile(named name: String) {
        setupCoordinator.overwriteProfile(named: name)
    }

    func deleteProfile(named name: String) {
        setupCoordinator.deleteProfile(named: name)
    }

    func startPreview() async {
        previewReviewStore.reset()
        await runCoordinator.startPreview()
    }

    func startTransfer() async {
        if previewReviewStore.isStale {
            transientErrorMessage = "Rebuild the preview before transferring so Chronoframe copies exactly the corrected plan."
            return
        }
        await runCoordinator.startTransfer()
    }

    func confirmRunPrompt() {
        runCoordinator.confirmRunPrompt()
    }

    func confirmRunPromptStartFresh() {
        runCoordinator.confirmRunPromptStartFresh()
    }

    func dismissRunPrompt() {
        runCoordinator.dismissRunPrompt()
    }

    func cancelRun() {
        switch selection {
        case .organize:
            runCoordinator.cancelRun()
        case .deduplicate:
            deduplicateSessionStore.cancel()
        case .profiles:
            runCoordinator.cancelRun()
        }
    }

    /// Where dedupe scans run. A folder chosen from Deduplicate wins; until
    /// then, the app falls back to the active organized destination.
    var deduplicateDestinationPath: String {
        if !preferencesStore.lastDeduplicateDestinationPath.isEmpty {
            return preferencesStore.lastDeduplicateDestinationPath
        }
        if !setupStore.destinationPath.isEmpty {
            return setupStore.destinationPath
        }
        return historyStore.destinationRoot
    }

    var hasDedicatedDeduplicateDestinationPath: Bool {
        !preferencesStore.lastDeduplicateDestinationPath.isEmpty
    }

    var deduplicateDestinationHelper: String {
        if hasDedicatedDeduplicateDestinationPath {
            return "Used only for Deduplicate scans."
        }
        if deduplicateDestinationPath.isEmpty {
            return "Choose the folder to scan for duplicate photos."
        }
        return "Using the Organize destination until you choose a Deduplicate folder."
    }

    func chooseDeduplicateDestinationFolder() async {
        guard let url = folderAccessService.chooseFolder(
            startingAt: deduplicateDestinationPath,
            prompt: "Choose Deduplicate Folder"
        ) else {
            return
        }

        do {
            try folderAccessService.validateFolder(url, role: .destination)
        } catch {
            transientErrorMessage = UserFacingErrorMessage.message(for: error, context: .setup)
            return
        }

        // Persist the bookmark BEFORE the path so the two never drift. If
        // bookmark creation fails (e.g. APFS volume not bookmarkable, sandbox
        // mismatch), surface the error and leave the destination unchanged
        // — the previously-chosen folder, if any, stays valid.
        do {
            let bookmark = try folderAccessService.makeBookmark(for: url, key: Self.deduplicateDestinationBookmarkKey)
            preferencesStore.storeBookmark(bookmark)
            preferencesStore.lastDeduplicateDestinationPath = url.path
        } catch {
            transientErrorMessage = UserFacingErrorMessage.message(for: error, context: .setup)
        }
    }

    /// Drop the dedicated Deduplicate folder and any bookmark backing it.
    /// `deduplicateDestinationPath` then falls back to the active Organize
    /// destination (or the most recently used history root) on next access.
    func clearDeduplicateDestinationFolder() {
        preferencesStore.removeBookmark(for: Self.deduplicateDestinationBookmarkKey)
        preferencesStore.lastDeduplicateDestinationPath = ""
    }

    func useDeduplicateHistoryFolder(_ record: DeduplicateFolderHistoryRecord) {
        let path = record.folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }

        let url = URL(fileURLWithPath: path, isDirectory: true)
        do {
            try folderAccessService.validateFolder(url, role: .destination)
        } catch {
            transientErrorMessage = "That Deduplicate folder is no longer available. Choose it again to continue."
            return
        }

        do {
            let bookmark = try folderAccessService.makeBookmark(for: url, key: Self.deduplicateDestinationBookmarkKey)
            preferencesStore.storeBookmark(bookmark)
            preferencesStore.lastDeduplicateDestinationPath = path
            resetDeduplicate()
        } catch {
            transientErrorMessage = UserFacingErrorMessage.message(for: error, context: .setup)
        }
    }

    /// Open Finder with the active Deduplicate destination selected. Only
    /// meaningful when `hasDedicatedDeduplicateDestinationPath` is true —
    /// the Organize destination already has its own reveal in Setup.
    func revealDeduplicateDestinationInFinder() {
        let path = deduplicateDestinationPath
        guard !path.isEmpty else { return }
        finderService.revealInFinder(path)
    }

    func startDeduplicateScan() {
        let destination = deduplicateDestinationPath
        guard !destination.isEmpty else {
            transientErrorMessage = "Choose a destination folder before running a deduplicate scan."
            return
        }
        let configuration = preferencesStore.makeDeduplicateConfiguration(destinationPath: destination)
        deduplicateSessionStore.startScan(
            configuration: configuration,
            securityScope: deduplicateSecurityScope(destination: destination)
        )
    }

    func commitDeduplicateDecisions() {
        let destination = deduplicateDestinationPath
        guard !destination.isEmpty else { return }
        let configuration = preferencesStore.makeDeduplicateConfiguration(destinationPath: destination)
        deduplicateSessionStore.decisions = DedupeDecisions(
            byPath: deduplicateSessionStore.decisions.byPath
        )
        deduplicateSessionStore.commit(
            configuration: configuration,
            securityScope: deduplicateSecurityScope(destination: destination)
        )
    }

    func commitReviewedDeduplicateDecisions() {
        let destination = deduplicateDestinationPath
        guard !destination.isEmpty else { return }
        let configuration = preferencesStore.makeDeduplicateConfiguration(destinationPath: destination)
        deduplicateSessionStore.commitReviewed(
            configuration: configuration,
            securityScope: deduplicateSecurityScope(destination: destination)
        )
    }

    func resetDeduplicate() {
        deduplicateSessionStore.reset()
    }

    private func restoreDeduplicateDestinationBookmark() {
        guard let bookmark = preferencesStore.bookmark(for: Self.deduplicateDestinationBookmarkKey) else {
            // Never set a Deduplicate folder; nothing to restore.
            return
        }
        let resolvedBookmark = folderAccessService.resolveBookmark(bookmark)
        // FolderAccessService.resolveBookmark returns a fallback URL
        // built from the stored path when the bookmark data is no
        // longer valid. That URL may point at a folder that no longer
        // exists — checking only `resolveBookmark != nil` would leave
        // a dead path persisted. Validate the resolved URL is still a
        // readable, writable directory before keeping it.
        let isLive: Bool = {
            guard let url = resolvedBookmark?.url else { return false }
            do {
                try folderAccessService.validateFolder(url, role: .destination)
                return true
            } catch {
                return false
            }
        }()
        guard let resolvedBookmark, isLive else {
            // Drop both the path and the bookmark so
            // `deduplicateDestinationPath` falls back to the Organize
            // destination instead of silently scanning a stale location.
            preferencesStore.removeBookmark(for: Self.deduplicateDestinationBookmarkKey)
            preferencesStore.lastDeduplicateDestinationPath = ""
            return
        }

        if let refreshedBookmark = resolvedBookmark.refreshedBookmark {
            preferencesStore.storeBookmark(refreshedBookmark)
        }
        preferencesStore.lastDeduplicateDestinationPath = resolvedBookmark.url.path
    }

    func openDestination() {
        runCoordinator.openDestination()
    }

    func openReport() {
        runCoordinator.openReport()
    }

    func openLogsDirectory() {
        runCoordinator.openLogsDirectory()
    }

    func refreshLibraryHealth() async {
        let destination = setupStore.destinationPath.isEmpty
            ? historyStore.destinationRoot
            : setupStore.destinationPath
        await libraryHealthStore.refresh(
            sourceRoot: setupStore.sourcePath,
            destinationRoot: destination,
            folderStructure: preferencesStore.folderStructure
        )
    }

    func performLibraryHealthAction(_ action: LibraryHealthAction) {
        switch action {
        case .runPreview, .refreshDestinationIndex, .reviewUnknownDates:
            navigate(to: .organize(.run))
            Task { await startPreview() }
        case .runDeduplicate:
            selection = .deduplicate
        case .openHistory:
            navigate(to: .organize(.history))
        case .reorganizeDestination:
            reorganizeDestination(targetStructure: preferencesStore.folderStructure)
        }
    }

    func openSettingsWindow() {
        runCoordinator.openSettingsWindow()
    }

    func openProfilesSettings() {
        settingsSelection = .profiles
        openSettingsWindow()
    }

    func revealHistoryEntry(_ entry: RunHistoryEntry) {
        historyCoordinator.revealHistoryEntry(entry)
    }

    func openHistoryEntry(_ entry: RunHistoryEntry) {
        historyCoordinator.openHistoryEntry(entry)
    }

    /// Revert the transfer described by `entry`'s audit receipt. Switches to the
    /// Run workspace and streams progress + the final summary there.
    func revertHistoryEntry(_ entry: RunHistoryEntry) {
        historyCoordinator.revertHistoryEntry(entry)
    }

    /// Reorganize the current destination so its folder layout matches the
    /// preferred `FolderStructure`. Streams progress through the Run workspace.
    func reorganizeDestination(targetStructure: FolderStructure) {
        let destination = historyStore.destinationRoot.isEmpty
            ? setupStore.destinationPath
            : historyStore.destinationRoot
        guard !destination.isEmpty else {
            transientErrorMessage = "Choose a destination folder before reorganizing."
            return
        }
        navigate(to: .organize(.run))
        runSessionStore.requestReorganize(
            destinationRoot: destination,
            targetStructure: targetStructure,
            securityScope: destinationSecurityScope(destinationRoot: destination)
        )
    }

    private func organizeSecurityScope() -> SecurityScopedFolderAccess? {
        scopedAccess(forKeys: activeOrganizeBookmarkKeys())
    }

    private func deduplicateSecurityScope(destination: String) -> SecurityScopedFolderAccess? {
        if hasDedicatedDeduplicateDestinationPath {
            return scopedAccess(forKeys: [Self.deduplicateDestinationBookmarkKey])
        }
        return destinationSecurityScope(destinationRoot: destination)
    }

    private func destinationSecurityScope(destinationRoot: String) -> SecurityScopedFolderAccess? {
        let keys = activeDestinationBookmarkKeys()
        let matchingKeys = keys.filter { key in
            guard let bookmark = preferencesStore.bookmark(for: key) else { return false }
            return pathsOverlap(bookmark.path, destinationRoot)
        }
        return scopedAccess(forKeys: matchingKeys.isEmpty ? keys : matchingKeys)
    }

    private func activeOrganizeBookmarkKeys() -> [String] {
        activeSourceBookmarkKeys() + activeDestinationBookmarkKeys()
    }

    private func activeSourceBookmarkKeys() -> [String] {
        var keys = [bookmarkPathResolver.bookmarkKey(for: .source, profileName: nil)]
        if setupStore.usingProfile, !setupStore.selectedProfileName.isEmpty {
            keys.append(bookmarkPathResolver.bookmarkKey(for: .source, profileName: setupStore.selectedProfileName))
        }
        return keys
    }

    private func activeDestinationBookmarkKeys() -> [String] {
        var keys = [bookmarkPathResolver.bookmarkKey(for: .destination, profileName: nil)]
        if setupStore.usingProfile, !setupStore.selectedProfileName.isEmpty {
            keys.append(bookmarkPathResolver.bookmarkKey(for: .destination, profileName: setupStore.selectedProfileName))
        }
        keys.append(Self.deduplicateDestinationBookmarkKey)
        return keys
    }

    private func scopedAccess(forKeys keys: [String]) -> SecurityScopedFolderAccess? {
        let bookmarks = keys.compactMap { preferencesStore.bookmark(for: $0) }
        guard !bookmarks.isEmpty else { return nil }
        return folderAccessService.scopedAccess(for: bookmarks)
    }

    private func pathsOverlap(_ bookmarkPath: String, _ requestedPath: String) -> Bool {
        let bookmark = URL(fileURLWithPath: bookmarkPath).standardizedFileURL.path
        let requested = URL(fileURLWithPath: requestedPath).standardizedFileURL.path
        return requested == bookmark || requested.hasPrefix(bookmark + "/") || bookmark.hasPrefix(requested + "/")
    }

    /// Repopulates the Setup view with a previously-used source path and switches to it.
    /// Clears any active profile selection so the manual source path takes effect.
    func useHistoricalSource(_ record: TransferredSourceRecord) {
        historyCoordinator.useHistoricalSource(record)
    }

    func revealTransferredSource(_ record: TransferredSourceRecord) {
        historyCoordinator.revealTransferredSource(record)
    }

    func forgetTransferredSource(_ record: TransferredSourceRecord) {
        historyCoordinator.forgetTransferredSource(record)
    }
}

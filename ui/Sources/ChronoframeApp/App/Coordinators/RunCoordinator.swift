import Foundation
#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif

@MainActor
final class RunCoordinator {
    private let preferencesStore: PreferencesStore
    private let setupStore: SetupStore
    private let historyStore: HistoryStore
    private let runSessionStore: RunSessionStore
    private let finderService: any FinderServicing
    private let showSettingsWindowAction: @MainActor () -> Void
    private let navigate: @MainActor (AppRoute) -> Void
    private let canStartRun: @MainActor () -> Bool

    init(
        preferencesStore: PreferencesStore,
        setupStore: SetupStore,
        historyStore: HistoryStore,
        runSessionStore: RunSessionStore,
        finderService: any FinderServicing,
        showSettingsWindowAction: @escaping @MainActor () -> Void,
        navigate: @escaping @MainActor (AppRoute) -> Void,
        canStartRun: @escaping @MainActor () -> Bool
    ) {
        self.preferencesStore = preferencesStore
        self.setupStore = setupStore
        self.historyStore = historyStore
        self.runSessionStore = runSessionStore
        self.finderService = finderService
        self.showSettingsWindowAction = showSettingsWindowAction
        self.navigate = navigate
        self.canStartRun = canStartRun
    }

    func startPreview() async {
        guard canStartRun() else { return }
        navigate(.organize(.run))
        await runSessionStore.requestRun(
            mode: .preview,
            configuration: setupStore.makeConfiguration(preferences: preferencesStore, mode: .preview)
        )
    }

    func startTransfer() async {
        guard canStartRun() else { return }
        navigate(.organize(.run))
        await runSessionStore.requestRun(
            mode: .transfer,
            configuration: setupStore.makeConfiguration(preferences: preferencesStore, mode: .transfer)
        )
    }

    func confirmRunPrompt() {
        runSessionStore.confirmPrompt()
    }

    func confirmRunPromptStartFresh() {
        runSessionStore.confirmPromptStartFresh()
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
        guard let path = runSessionStore.summary?.artifacts.reportPath else { return }
        finderService.openPath(path)
    }

    func openLogsDirectory() {
        guard let path = runSessionStore.summary?.artifacts.logsDirectoryPath else { return }
        finderService.openPath(path)
    }

    func openSettingsWindow() {
        showSettingsWindowAction()
    }
}

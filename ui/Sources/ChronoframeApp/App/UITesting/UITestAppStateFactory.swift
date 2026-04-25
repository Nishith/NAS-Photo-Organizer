import AppKit
import Foundation
#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

@MainActor
enum UITestAppStateFactory {
    static func make(scenario: UITestScenario) -> AppState {
        let suiteName = "Chronoframe-UITest-\(scenario.rawValue)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)

        let preferencesStore = PreferencesStore(defaults: defaults)
        let setupStore = SetupStore()
        let runLogStore = RunLogStore(capacity: 500)
        let repository = MockProfilesRepository()
        let folderAccessService = MockFolderAccessService()
        let finderService = MockFinderService()

        let historyStore: HistoryStore
        let engine: MockOrganizerEngine
        let route: AppRoute

        switch scenario {
        case .setupReady:
            setupStore.sourcePath = "/Volumes/Card/April Session"
            setupStore.destinationPath = "/Volumes/Archive/Chronoframe Library"
            historyStore = HistoryStore(destinationRoot: setupStore.destinationPath)
            engine = previewReviewEngine(sourcePath: setupStore.sourcePath, destinationPath: setupStore.destinationPath)
            route = .organize(.setup)

        case .runPreviewReview:
            setupStore.sourcePath = "/Volumes/Card/April Session"
            setupStore.destinationPath = "/Volumes/Archive/Chronoframe Library"
            historyStore = HistoryStore(destinationRoot: setupStore.destinationPath)
            engine = previewReviewEngine(sourcePath: setupStore.sourcePath, destinationPath: setupStore.destinationPath)
            route = .organize(.run)

        case .historyPopulated:
            setupStore.destinationPath = "/Volumes/Archive/Chronoframe Library"
            historyStore = HistoryStore(
                entries: sampleHistoryEntries(),
                transferredSources: sampleTransferredSources(),
                destinationRoot: setupStore.destinationPath
            )
            engine = previewReviewEngine(sourcePath: "/Volumes/Card/April Session", destinationPath: setupStore.destinationPath)
            route = .organize(.history)

        case .profilesPopulated:
            repository.profiles = sampleProfiles()
            setupStore.updateProfiles(repository.profiles)
            setupStore.selectProfile(named: "Meridian Travel")
            setupStore.newProfileName = "Weekend Archive"
            historyStore = HistoryStore(destinationRoot: setupStore.destinationPath)
            engine = previewReviewEngine(sourcePath: setupStore.sourcePath, destinationPath: setupStore.destinationPath)
            route = .profiles

        case .settingsSections:
            setupStore.sourcePath = "/Volumes/Card/April Session"
            setupStore.destinationPath = "/Volumes/Archive/Chronoframe Library"
            historyStore = HistoryStore(destinationRoot: setupStore.destinationPath)
            engine = previewReviewEngine(sourcePath: setupStore.sourcePath, destinationPath: setupStore.destinationPath)
            route = .organize(.setup)
        }

        let runSessionStore = RunSessionStore(engine: engine, logStore: runLogStore, historyStore: historyStore)
        let appStateBox = AppStateBox()
        let showSettingsWindowAction: @MainActor () -> Void = {
            if scenario == .settingsSections {
                guard let appState = appStateBox.value else { return }
                UITestSettingsWindowPresenter.show(appState: appState)
            } else {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }

        let appState = AppState(
            route: route,
            preferencesStore: preferencesStore,
            setupStore: setupStore,
            runLogStore: runLogStore,
            historyStore: historyStore,
            runSessionStore: runSessionStore,
            folderAccessService: folderAccessService,
            finderService: finderService,
            profilesRepository: repository,
            performInitialBootstrap: false,
            showSettingsWindowAction: showSettingsWindowAction
        )
        appStateBox.value = appState

        if scenario == .runPreviewReview {
            Task { @MainActor in
                await appState.startPreview()
            }
        }

        return appState
    }

    private static func previewReviewEngine(sourcePath: String, destinationPath: String) -> MockOrganizerEngine {
        let preflight = RunPreflight(
            configuration: RunConfiguration(mode: .preview, sourcePath: sourcePath, destinationPath: destinationPath),
            resolvedSourcePath: sourcePath,
            resolvedDestinationPath: destinationPath
        )

        let summary = RunSummary(
            status: .dryRunFinished,
            title: "Preview complete",
            metrics: RunMetrics(
                discoveredCount: 84,
                plannedCount: 42,
                alreadyInDestinationCount: 29,
                duplicateCount: 7,
                hashErrorCount: 1,
                copiedCount: 0,
                failedCount: 0,
                errorCount: 1
            ),
            artifacts: RunArtifactPaths(
                destinationRoot: destinationPath,
                reportPath: "\(destinationPath)/.organize_logs/dry_run_report.csv",
                logFilePath: "\(destinationPath)/.organize_log.txt",
                logsDirectoryPath: "\(destinationPath)/.organize_logs"
            )
        )

        return MockOrganizerEngine(
            preflightResult: .success(preflight),
            startMode: .events([
                .startup,
                .phaseStarted(phase: .discovery, total: 84),
                .phaseCompleted(phase: .sourceHashing, result: RunPhaseResult(found: 84)),
                .phaseCompleted(
                    phase: .classification,
                    result: RunPhaseResult(
                        newCount: 42,
                        alreadyInDestinationCount: 29,
                        duplicateCount: 7,
                        hashErrorCount: 1
                    )
                ),
                .copyPlanReady(count: 42),
                .issue(RunIssue(severity: .warning, message: "1 file had incomplete metadata")),
                .issue(RunIssue(severity: .error, message: "1 file could not be hashed and needs review")),
                .complete(summary),
            ])
        )
    }

    private static func sampleHistoryEntries() -> [RunHistoryEntry] {
        [
            RunHistoryEntry(
                kind: .dryRunReport,
                title: "Dry Run Report",
                path: "/Volumes/Archive/Chronoframe Library/.organize_logs/dry_run_report.csv",
                relativePath: ".organize_logs/dry_run_report.csv",
                fileSizeBytes: 18_240,
                createdAt: Date(timeIntervalSinceReferenceDate: 764_121_600)
            ),
            RunHistoryEntry(
                kind: .auditReceipt,
                title: "Transfer Receipt",
                path: "/Volumes/Archive/Chronoframe Library/.organize_logs/receipt.json",
                relativePath: ".organize_logs/receipt.json",
                fileSizeBytes: 8_192,
                createdAt: Date(timeIntervalSinceReferenceDate: 764_121_600)
            ),
            RunHistoryEntry(
                kind: .runLog,
                title: "Run Log",
                path: "/Volumes/Archive/Chronoframe Library/.organize_log.txt",
                relativePath: ".organize_log.txt",
                fileSizeBytes: 64_000,
                createdAt: Date(timeIntervalSinceReferenceDate: 764_121_600)
            ),
        ]
    }

    private static func sampleTransferredSources() -> [TransferredSourceRecord] {
        [
            TransferredSourceRecord(
                sourcePath: "/Volumes/Card/April Session",
                firstTransferredAt: Date(timeIntervalSinceReferenceDate: 764_035_200),
                lastTransferredAt: Date(timeIntervalSinceReferenceDate: 764_121_600),
                runCount: 3,
                lastCopiedCount: 42,
                totalCopiedCount: 124,
            ),
        ]
    }

    private static func sampleProfiles() -> [Profile] {
        [
            Profile(
                name: "Meridian Travel",
                sourcePath: "/Volumes/Card/Travel",
                destinationPath: "/Volumes/Archive/Travel"
            ),
            Profile(
                name: "Studio Imports",
                sourcePath: "/Volumes/Card/Studio",
                destinationPath: "/Volumes/Archive/Studio"
            ),
        ]
    }
}

private final class AppStateBox {
    var value: AppState?
}

@MainActor
private enum UITestSettingsWindowPresenter {
    private static var settingsWindow: NSWindow?

    static func show(appState: AppState) {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = SettingsView(appState: appState)
            .frame(
                minWidth: DesignTokens.Window.settingsMinWidth,
                idealWidth: max(DesignTokens.Window.settingsIdealWidth, 760),
                minHeight: DesignTokens.Window.settingsMinHeight
            )
            .padding()

        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 680))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }
}

#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import AppKit
import SwiftUI

struct CurrentRunView: View {
    let appState: AppState
    @ObservedObject private var runSessionStore: RunSessionStore
    @ObservedObject private var runLogStore: RunLogStore
    @ObservedObject private var historyStore: HistoryStore
    @ObservedObject private var previewReviewStore: PreviewReviewStore
    @State private var workspaceTab: RunWorkspaceTab = .overview

    init(appState: AppState) {
        self.appState = appState
        self._runSessionStore = ObservedObject(wrappedValue: appState.runSessionStore)
        self._runLogStore = ObservedObject(wrappedValue: appState.runLogStore)
        self._historyStore = ObservedObject(wrappedValue: appState.historyStore)
        self._previewReviewStore = ObservedObject(wrappedValue: appState.previewReviewStore)
    }

    private var model: RunWorkspaceModel {
        RunWorkspaceModel(
            runSessionStore: runSessionStore,
            runLogStore: runLogStore,
            historyStore: historyStore,
            canStartRun: appState.canStartRun,
            previewReviewStore: previewReviewStore
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.sectionSpacing) {
                RunHeroSection(model: model, workspaceTab: $workspaceTab, appState: appState)

                if model.showsPreviewReview {
                    RunPreviewReviewSection(
                        model: model,
                        startTransfer: { Task { await appState.startTransfer() } }
                    )
                }

                if model.isBlankIdle {
                    RunIdleOnboardingCard()
                } else {
                    RunTimelineView(model: model)

                    if showsNowCopying {
                        NowCopyingCard(model: model)
                    }

                    RunTickerSection(model: model)

                    RunWorkspaceShell(
                        model: model,
                        workspaceTab: $workspaceTab,
                        appState: appState,
                        previewReviewStore: previewReviewStore
                    )
                }
            }
            .padding(DesignTokens.Layout.contentPadding)
            .frame(maxWidth: DesignTokens.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .darkroom()
        .navigationTitle("Run")
        .onChange(of: runSessionStore.status) { newValue in
            if newValue == .finished {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
        }
        .task(id: runSessionStore.summary?.artifacts.previewReviewPath) {
            await previewReviewStore.load(
                artifactPath: runSessionStore.summary?.artifacts.previewReviewPath,
                destinationRoot: runSessionStore.summary?.artifacts.destinationRoot
            )
        }
    }

    private var showsNowCopying: Bool {
        switch runSessionStore.status {
        case .running, .preflighting, .finished:
            return true
        default:
            return false
        }
    }
}

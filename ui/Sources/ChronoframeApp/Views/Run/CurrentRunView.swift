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

                if model.showsOutcomeSummary {
                    RunOutcomeSummaryCard(model: model, appState: appState)
                }

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

private struct RunOutcomeSummaryCard: View {
    let model: RunWorkspaceModel
    let appState: AppState

    var body: some View {
        MeridianSurfaceCard(tint: model.heroState.tone.color) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Run Summary")
                        .font(DesignTokens.Typography.cardTitle)
                    Spacer()
                    Button("Open History") {
                        appState.navigate(to: .organize(.history))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    summaryMetric("Copied", value: model.context.metrics.copiedCount.formatted(), tint: DesignTokens.ColorSystem.statusSuccess)
                    summaryMetric("Planned", value: model.context.metrics.plannedCount.formatted(), tint: DesignTokens.ColorSystem.accentAction)
                    summaryMetric("Skipped", value: model.context.metrics.alreadyInDestinationCount.formatted(), tint: DesignTokens.ColorSystem.inkSecondary)
                    summaryMetric("Issues", value: "\(model.context.issueCount)", tint: model.issueTone.color)
                }

                Text(model.outcomeSummaryMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("runOutcomeSummaryCard")
    }

    private func summaryMetric(_ title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit())
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

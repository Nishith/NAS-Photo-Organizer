#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

/// Hosts the Setup, Run, and Run History sub-tabs under the unified Organize
/// sidebar destination. Each sub-tab continues to render the existing view
/// unchanged; this container only owns the segmented picker and the routing.
struct OrganizeContainerView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var setupStore: SetupStore
    @ObservedObject private var runSessionStore: RunSessionStore
    @ObservedObject private var previewReviewStore: PreviewReviewStore
    @ObservedObject private var deduplicateSessionStore: DeduplicateSessionStore

    init(appState: AppState) {
        self.appState = appState
        self._setupStore = ObservedObject(wrappedValue: appState.setupStore)
        self._runSessionStore = ObservedObject(wrappedValue: appState.runSessionStore)
        self._previewReviewStore = ObservedObject(wrappedValue: appState.previewReviewStore)
        self._deduplicateSessionStore = ObservedObject(wrappedValue: appState.deduplicateSessionStore)
    }

    var body: some View {
        VStack(spacing: 0) {
            OrganizeNextActionBanner(
                sourcePath: setupStore.sourcePath,
                destinationPath: setupStore.destinationPath,
                runStatus: runSessionStore.status,
                previewIsStale: previewReviewStore.isStale,
                deduplicateStatus: deduplicateSessionStore.status,
                navigate: appState.navigate(to:),
                startPreview: { Task { await appState.startPreview() } }
            )
            .padding(.horizontal, DesignTokens.Layout.contentPadding)
            .padding(.top, DesignTokens.Spacing.md)

            Picker("Section", selection: $appState.organizeSubSelection) {
                ForEach(OrganizeSubSection.allCases) { sub in
                    // `.segmented` style ignores Label icons on macOS,
                    // so drop the `systemImage` to match what users
                    // actually see and avoid misleading code readers.
                    Text(sub.title).tag(sub)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, DesignTokens.Layout.contentPadding)
            .padding(.top, DesignTokens.Spacing.sm)
            .padding(.bottom, DesignTokens.Spacing.sm)

            Divider()

            content
        }
        .navigationTitle("Organize")
    }

    @ViewBuilder
    private var content: some View {
        switch appState.organizeSubSelection {
        case .setup:
            SetupView(appState: appState)
        case .run:
            CurrentRunView(appState: appState)
        case .health:
            HealthDashboardView(appState: appState)
        case .history:
            RunHistoryView(appState: appState)
        }
    }
}

private struct OrganizeNextActionBanner: View {
    let sourcePath: String
    let destinationPath: String
    let runStatus: RunStatus
    let previewIsStale: Bool
    let deduplicateStatus: DeduplicateSessionStore.Status
    let navigate: (AppRoute) -> Void
    let startPreview: () -> Void

    var body: some View {
        MeridianSurfaceCard(style: .inner, tint: action.tint) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    label
                    Spacer(minLength: 12)
                    actionButton
                }

                VStack(alignment: .leading, spacing: 10) {
                    label
                    actionButton
                }
            }
        }
        .accessibilityIdentifier("organizeNextActionBanner")
    }

    private var label: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: action.systemImage)
                .foregroundStyle(action.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.subheadline.weight(.semibold))
                Text(action.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actionButton: some View {
        Button(action.buttonTitle) {
            switch action.kind {
            case .setup:
                navigate(.organize(.setup))
            case .run:
                navigate(.organize(.run))
            case .history:
                navigate(.organize(.history))
            case .deduplicate:
                navigate(.deduplicate)
            case .preview:
                startPreview()
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .fixedSize()
    }

    private var action: NextAction {
        if sourcePath.isEmpty || destinationPath.isEmpty {
            return NextAction(
                kind: .setup,
                title: "Next: finish setup",
                message: "Choose a source and destination before Chronoframe can build a safe preview.",
                buttonTitle: "Go to Setup",
                systemImage: "slider.horizontal.3",
                tint: DesignTokens.ColorSystem.statusWarning
            )
        }
        if runStatus == .failed {
            return NextAction(
                kind: .run,
                title: "Next: resolve run issues",
                message: "The last run needs attention. Originals were left untouched; review the fixable issues before trying again.",
                buttonTitle: "Review Issues",
                systemImage: "exclamationmark.triangle.fill",
                tint: DesignTokens.ColorSystem.statusDanger
            )
        }
        if previewIsStale {
            return NextAction(
                kind: .run,
                title: "Next: rebuild the preview",
                message: "You saved review corrections. Rebuild the preview so transfer matches the corrected plan.",
                buttonTitle: "Open Review",
                systemImage: "arrow.triangle.2.circlepath",
                tint: DesignTokens.ColorSystem.statusWarning
            )
        }
        if runStatus == .dryRunFinished {
            return NextAction(
                kind: .run,
                title: "Next: inspect the preview",
                message: "Nothing has been copied yet. Review the visual plan, issues, and artifacts before transfer.",
                buttonTitle: "Review Plan",
                systemImage: "doc.text.magnifyingglass",
                tint: DesignTokens.ColorSystem.accentAction
            )
        }
        if case .readyToReview = deduplicateStatus {
            return NextAction(
                kind: .deduplicate,
                title: "Next: review duplicate groups",
                message: "Deduplicate has candidate groups ready. Confirm what should stay before moving anything to Trash.",
                buttonTitle: "Open Deduplicate",
                systemImage: "rectangle.on.rectangle.angled",
                tint: DesignTokens.ColorSystem.accentAction
            )
        }
        if runStatus == .finished {
            return NextAction(
                kind: .history,
                title: "Next: review the run record",
                message: "The latest transfer wrote reports and receipts you can inspect or use for recovery.",
                buttonTitle: "Open History",
                systemImage: "clock.arrow.circlepath",
                tint: DesignTokens.ColorSystem.statusSuccess
            )
        }
        return NextAction(
            kind: .preview,
            title: "Next: preview the plan",
            message: "Preview is non-destructive and shows what will be copied, skipped, or needs attention.",
            buttonTitle: "Preview Plan",
            systemImage: "eye",
            tint: DesignTokens.ColorSystem.statusSuccess
        )
    }

    private struct NextAction {
        enum Kind {
            case setup
            case run
            case history
            case deduplicate
            case preview
        }

        let kind: Kind
        let title: String
        let message: String
        let buttonTitle: String
        let systemImage: String
        let tint: Color
    }
}

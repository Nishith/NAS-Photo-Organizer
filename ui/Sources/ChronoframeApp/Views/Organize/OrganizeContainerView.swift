#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

/// Hosts the Setup, Run, and Run History sub-tabs under the unified Organize
/// sidebar destination. Each sub-tab continues to render the existing view
/// unchanged; this container only owns the segmented picker and the routing.
struct OrganizeContainerView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $appState.organizeSubSelection) {
                ForEach(OrganizeSubSection.allCases) { sub in
                    Label(sub.title, systemImage: sub.systemImage)
                        .tag(sub)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, DesignTokens.Layout.contentPadding)
            .padding(.top, DesignTokens.Spacing.md)
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
        case .history:
            RunHistoryView(appState: appState)
        }
    }
}

#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

struct SidebarView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        List(SidebarDestination.allCases, selection: $appState.selection) { destination in
            HStack(spacing: 10) {
                Image(systemName: destination.systemImage)
                    .foregroundStyle(destination == .currentRun && appState.runSessionStore.isRunning ? .blue : .secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(destination.title)
                        .lineLimit(1)
                    Text(destinationSubtitle(for: destination))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if destination == .currentRun && appState.runSessionStore.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .tag(destination)
        }
        .listStyle(.sidebar)
        .navigationTitle("Chronoframe")
    }

    private func destinationSubtitle(for destination: SidebarDestination) -> String {
        switch destination {
        case .setup:
            return appState.canStartRun ? "Ready to preview" : destination.subtitle
        case .currentRun:
            return appState.runSessionStore.currentTaskTitle
        case .history:
            return appState.historyStore.entries.isEmpty ? destination.subtitle : "\(appState.historyStore.entries.count) artifacts"
        case .profiles:
            return appState.setupStore.profiles.isEmpty ? destination.subtitle : "\(appState.setupStore.profiles.count) saved"
        }
    }
}

#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

struct SidebarView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var setupStore: SetupStore
    @ObservedObject private var historyStore: HistoryStore
    @ObservedObject private var runSessionStore: RunSessionStore

    init(appState: AppState) {
        self.appState = appState
        self._setupStore = ObservedObject(wrappedValue: appState.setupStore)
        self._historyStore = ObservedObject(wrappedValue: appState.historyStore)
        self._runSessionStore = ObservedObject(wrappedValue: appState.runSessionStore)
    }

    var body: some View {
        List(SidebarDestination.allCases, selection: $appState.selection) { destination in
            HStack(spacing: 10) {
                Image(systemName: destination.systemImage)
                    .foregroundStyle(destination == .currentRun && runSessionStore.isRunning ? .blue : .secondary)
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

                if destination == .currentRun && runSessionStore.isRunning {
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
            return canStartRun ? "Ready to preview" : destination.subtitle
        case .currentRun:
            return runSessionStore.currentTaskTitle
        case .history:
            return historyStore.entries.isEmpty ? destination.subtitle : "\(historyStore.entries.count) artifacts"
        case .profiles:
            return setupStore.profiles.isEmpty ? destination.subtitle : "\(setupStore.profiles.count) saved"
        }
    }

    private var canStartRun: Bool {
        setupStore.usingProfile || (!setupStore.sourcePath.isEmpty && !setupStore.destinationPath.isEmpty)
    }
}

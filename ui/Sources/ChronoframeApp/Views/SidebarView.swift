#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

struct SidebarView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var setupStore: SetupStore
    @ObservedObject private var historyStore: HistoryStore
    @ObservedObject private var runSessionStore: RunSessionStore
    @AppStorage("lastSeenHistoryCount") private var lastSeenHistoryCount: Int = 0

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
                    .foregroundStyle(iconTint(for: destination))
                    .frame(width: 16)

                Text(destination.title)
                    .font(DesignTokens.Typography.body)
                    .lineLimit(1)

                Spacer()

                if destination == .run && runSessionStore.isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else if showsStatusDot(for: destination) {
                    Circle()
                        .fill(statusDotTint(for: destination))
                        .frame(width: 6, height: 6)
                }
            }
            .tag(destination)
        }
        .listStyle(.sidebar)
        .navigationTitle("Chronoframe")
        .onChange(of: appState.selection) { selection in
            if selection == .history {
                lastSeenHistoryCount = historyStore.entries.count
            }
        }
    }

    private func iconTint(for destination: SidebarDestination) -> SwiftUI.Color {
        if destination == .run && runSessionStore.isRunning {
            return DesignTokens.ColorSystem.accentAction
        }
        if destination == .setup && appState.canStartRun {
            return DesignTokens.ColorSystem.statusSuccess
        }
        if destination == .run && runSessionStore.status == .failed {
            return DesignTokens.ColorSystem.statusDanger
        }
        return DesignTokens.ColorSystem.inkSecondary
    }

    private func showsStatusDot(for destination: SidebarDestination) -> Bool {
        switch destination {
        case .setup:
            return appState.canStartRun
        case .run:
            return runSessionStore.status == .failed || runSessionStore.status == .dryRunFinished
        case .history:
            return historyStore.entries.count > lastSeenHistoryCount
        case .profiles:
            return setupStore.usingProfile
        }
    }

    private func statusDotTint(for destination: SidebarDestination) -> SwiftUI.Color {
        switch destination {
        case .setup:
            return DesignTokens.ColorSystem.statusSuccess
        case .run:
            return runSessionStore.status == .failed ? DesignTokens.ColorSystem.statusDanger : DesignTokens.ColorSystem.accentAction
        case .history:
            return DesignTokens.ColorSystem.statusActive
        case .profiles:
            return DesignTokens.ColorSystem.accentWaypoint
        }
    }
}

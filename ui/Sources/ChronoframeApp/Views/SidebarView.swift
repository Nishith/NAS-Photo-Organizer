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

                if destination == .organize && runSessionStore.isRunning {
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
        .onChange(of: appState.organizeSubSelection) { sub in
            if appState.selection == .organize && sub == .history {
                lastSeenHistoryCount = historyStore.entries.count
            }
        }
        .onChange(of: appState.selection) { selection in
            if selection == .organize && appState.organizeSubSelection == .history {
                lastSeenHistoryCount = historyStore.entries.count
            }
        }
    }

    private func iconTint(for destination: SidebarDestination) -> SwiftUI.Color {
        switch destination {
        case .organize:
            if runSessionStore.isRunning {
                return DesignTokens.ColorSystem.accentAction
            }
            if runSessionStore.status == .failed {
                return DesignTokens.ColorSystem.statusDanger
            }
            if appState.canStartRun {
                return DesignTokens.ColorSystem.statusSuccess
            }
            return DesignTokens.ColorSystem.inkSecondary
        case .deduplicate, .profiles:
            return DesignTokens.ColorSystem.inkSecondary
        }
    }

    private func showsStatusDot(for destination: SidebarDestination) -> Bool {
        switch destination {
        case .organize:
            return runSessionStore.status == .failed
                || runSessionStore.status == .dryRunFinished
                || historyStore.entries.count > lastSeenHistoryCount
                || appState.canStartRun
        case .deduplicate:
            return false
        case .profiles:
            return setupStore.usingProfile
        }
    }

    private func statusDotTint(for destination: SidebarDestination) -> SwiftUI.Color {
        switch destination {
        case .organize:
            if runSessionStore.status == .failed {
                return DesignTokens.ColorSystem.statusDanger
            }
            if runSessionStore.status == .dryRunFinished {
                return DesignTokens.ColorSystem.accentAction
            }
            if historyStore.entries.count > lastSeenHistoryCount {
                return DesignTokens.ColorSystem.statusActive
            }
            return DesignTokens.ColorSystem.statusSuccess
        case .deduplicate:
            return DesignTokens.ColorSystem.inkSecondary
        case .profiles:
            return DesignTokens.ColorSystem.accentWaypoint
        }
    }
}

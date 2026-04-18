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
                ZStack {
                    Image(systemName: destination.systemImage)
                        .foregroundStyle(iconTint(for: destination))
                        .frame(width: 16)

                    if showsStatusDot(for: destination) {
                        Circle()
                            .fill(statusDotTint(for: destination))
                            .frame(width: 7, height: 7)
                            .offset(x: 9, y: 8)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(destination.title)
                        .lineLimit(1)
                    Text(destinationSubtitle(for: destination))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if destination == .run && runSessionStore.isRunning {
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
            if setupStore.usingProfile {
                return "Saved setup selected"
            }
            if appState.canStartRun {
                return "Ready to preview"
            }
            if setupStore.sourcePath.isEmpty || setupStore.destinationPath.isEmpty {
                return "Source and destination needed"
            }
            return destination.subtitle

        case .run:
            if runSessionStore.isRunning {
                return runSessionStore.currentTaskTitle
            }
            switch runSessionStore.status {
            case .dryRunFinished:
                return "Preview ready to review"
            case .finished:
                return "Artifacts ready to inspect"
            case .failed:
                return "Review issues and logs"
            case .cancelled:
                return "Run stopped before completion"
            case .nothingToCopy:
                return "Destination already up to date"
            case .idle, .preflighting, .running:
                return destination.subtitle
            }

        case .history:
            if historyStore.entries.isEmpty {
                return destination.subtitle
            }
            return "\(historyStore.entries.count) artifact\(historyStore.entries.count == 1 ? "" : "s")"

        case .profiles:
            if setupStore.profiles.isEmpty {
                return destination.subtitle
            }
            return "\(setupStore.profiles.count) saved setup\(setupStore.profiles.count == 1 ? "" : "s")"
        }
    }

    private func iconTint(for destination: SidebarDestination) -> SwiftUI.Color {
        if destination == .run && runSessionStore.isRunning {
            return DesignTokens.Color.sky
        }
        if destination == .setup && appState.canStartRun {
            return DesignTokens.Color.success
        }
        if destination == .run && runSessionStore.status == .failed {
            return DesignTokens.Color.danger
        }
        return DesignTokens.Color.inkMuted
    }

    private func showsStatusDot(for destination: SidebarDestination) -> Bool {
        switch destination {
        case .setup:
            return appState.canStartRun
        case .run:
            return runSessionStore.status == .failed || runSessionStore.status == .dryRunFinished
        case .history:
            return !historyStore.entries.isEmpty
        case .profiles:
            return setupStore.usingProfile
        }
    }

    private func statusDotTint(for destination: SidebarDestination) -> SwiftUI.Color {
        switch destination {
        case .setup:
            return DesignTokens.Color.success
        case .run:
            return runSessionStore.status == .failed ? DesignTokens.Color.danger : DesignTokens.Color.sky
        case .history:
            return DesignTokens.Color.aqua
        case .profiles:
            return DesignTokens.Color.amberWaypoint
        }
    }
}

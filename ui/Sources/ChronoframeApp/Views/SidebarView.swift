#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

struct SidebarView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var setupStore: SetupStore
    @ObservedObject private var historyStore: HistoryStore
    @ObservedObject private var runSessionStore: RunSessionStore
    @ObservedObject private var deduplicateSessionStore: DeduplicateSessionStore
    @AppStorage("lastSeenHistoryCount") private var lastSeenHistoryCount: Int = 0
    @AppStorage("lastSeenDeduplicateAttentionToken") private var lastSeenDeduplicateAttentionToken: String = ""

    init(appState: AppState) {
        self.appState = appState
        self._setupStore = ObservedObject(wrappedValue: appState.setupStore)
        self._historyStore = ObservedObject(wrappedValue: appState.historyStore)
        self._runSessionStore = ObservedObject(wrappedValue: appState.runSessionStore)
        self._deduplicateSessionStore = ObservedObject(wrappedValue: appState.deduplicateSessionStore)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(SidebarDestination.primaryNavigationCases) { destination in
                let isSelected = appState.selection == destination
                Button {
                    appState.selection = destination
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isSelected ? DesignTokens.ColorSystem.accentAction.opacity(0.16) : DesignTokens.ColorSystem.elevated.opacity(0.52))
                            Image(systemName: destination.systemImage)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(isSelected ? DesignTokens.ColorSystem.accentAction : iconTint(for: destination))
                        }
                        .frame(width: 30, height: 30)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(destination.title)
                                .font(.system(size: 14, weight: .semibold, design: .default))
                                .foregroundStyle(isSelected ? DesignTokens.ColorSystem.accentAction : DesignTokens.ColorSystem.inkPrimary)
                                .lineLimit(1)

                            Text(destination.subtitle)
                                .font(.caption)
                                .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        if showsProgress(for: destination) {
                            ProgressView()
                                .controlSize(.small)
                        } else if showsStatusDot(for: destination) {
                            Circle()
                                .fill(statusDotTint(for: destination))
                                .frame(width: 6, height: 6)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isSelected ? DesignTokens.ColorSystem.accentAction.opacity(0.12) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isSelected ? DesignTokens.ColorSystem.accentAction.opacity(0.22) : Color.clear, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                .tag(destination)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            if selection == .deduplicate {
                markCurrentDeduplicateStatusSeen()
            }
        }
        .onChange(of: deduplicateSessionStore.status) { _ in
            refreshDeduplicateAttentionMarker()
        }
        .onAppear {
            refreshDeduplicateAttentionMarker()
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
        case .deduplicate:
            if deduplicateSessionStore.isWorking {
                return DesignTokens.ColorSystem.accentAction
            }
            return DesignTokens.ColorSystem.inkSecondary
        case .profiles:
            return DesignTokens.ColorSystem.inkSecondary
        }
    }

    private func showsProgress(for destination: SidebarDestination) -> Bool {
        switch destination {
        case .organize: return runSessionStore.isRunning
        case .deduplicate: return deduplicateSessionStore.isWorking
        case .profiles: return false
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
            return Self.shouldShowDeduplicateStatusDot(
                status: deduplicateSessionStore.status,
                lastSeenToken: lastSeenDeduplicateAttentionToken
            )
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
            switch deduplicateSessionStore.status {
            case .failed:
                return DesignTokens.ColorSystem.statusDanger
            case .completed, .reverted:
                return DesignTokens.ColorSystem.statusSuccess
            case .readyToReview:
                return DesignTokens.ColorSystem.accentAction
            default:
                return DesignTokens.ColorSystem.inkSecondary
            }
        case .profiles:
            return DesignTokens.ColorSystem.accentWaypoint
        }
    }

    private func markCurrentDeduplicateStatusSeen() {
        if let token = Self.deduplicateAttentionToken(for: deduplicateSessionStore.status) {
            lastSeenDeduplicateAttentionToken = token
        }
    }

    private func refreshDeduplicateAttentionMarker() {
        lastSeenDeduplicateAttentionToken = Self.nextDeduplicateLastSeenToken(
            status: deduplicateSessionStore.status,
            isSelected: appState.selection == .deduplicate,
            currentToken: lastSeenDeduplicateAttentionToken
        )
    }
}

extension SidebarView {
    static func shouldShowDeduplicateStatusDot(
        status: DeduplicateSessionStore.Status,
        lastSeenToken: String
    ) -> Bool {
        guard let token = deduplicateAttentionToken(for: status) else {
            return false
        }
        return token != lastSeenToken
    }

    static func deduplicateAttentionToken(for status: DeduplicateSessionStore.Status) -> String? {
        switch status {
        case .readyToReview:
            return "readyToReview"
        case .completed:
            return "completed"
        case .reverted:
            return "reverted"
        case .failed:
            return "failed"
        case .idle, .scanning, .committing, .reverting:
            return nil
        }
    }

    static func nextDeduplicateLastSeenToken(
        status: DeduplicateSessionStore.Status,
        isSelected: Bool,
        currentToken: String
    ) -> String {
        guard let token = deduplicateAttentionToken(for: status) else {
            return ""
        }
        return isSelected ? token : currentToken
    }
}

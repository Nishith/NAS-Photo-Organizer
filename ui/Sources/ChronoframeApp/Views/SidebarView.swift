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
            sectionHeader("Workspace")

            ForEach(SidebarDestination.primaryNavigationCases) { destination in
                let isSelected = appState.selection == destination
                Button {
                    appState.selection = destination
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: destination.systemImage)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(isSelected ? DesignTokens.ColorSystem.accentAction : iconTint(for: destination))
                            .frame(width: 20, height: 22)
                            .overlay(alignment: .bottomTrailing) {
                                if isSelected {
                                    Circle()
                                        .fill(DesignTokens.ColorSystem.accentWaypoint)
                                        .frame(width: 5, height: 5)
                                        .offset(x: 3, y: 1)
                                }
                            }

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
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(isSelected ? DesignTokens.ColorSystem.accentAction.opacity(0.10) : Color.clear)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(isSelected ? DesignTokens.ColorSystem.accentAction.opacity(0.18) : Color.clear, lineWidth: 0.5)
                    )
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                .tag(destination)
            }

            Spacer()

            if hasLibraryStats {
                libraryGlanceFooter
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 8)
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

    // MARK: - Section header (grouping primitive)

    /// A small uppercase group label. Introduces sidebar sectioning so future
    /// destinations can be grouped (e.g. "Workspace" vs "Library") without a
    /// structural rewrite.
    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(DesignTokens.Typography.label)
            .tracking(0.8)
            .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Library at a glance

    private var framesArchived: Int {
        historyStore.transferredSources.reduce(0) { $0 + $1.totalCopiedCount }
    }

    private var archivedSourceCount: Int {
        historyStore.transferredSources.count
    }

    private var hasLibraryStats: Bool {
        framesArchived > 0
    }

    /// A quiet footer that fills the empty lower sidebar with a sense of what
    /// the user has built so far. Reads from history records — no health scan.
    private var libraryGlanceFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LIBRARY")
                .font(DesignTokens.Typography.label)
                .tracking(0.8)
                .foregroundStyle(DesignTokens.ColorSystem.inkMuted)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(framesArchived.formatted())
                    .font(DesignTokens.Typography.cardTitle)
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.ColorSystem.inkPrimary)
                Text("frames archived")
                    .font(.caption)
                    .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)
            }

            Text("\(archivedSourceCount) source\(archivedSourceCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DesignTokens.ColorSystem.hairline.opacity(0.35))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(framesArchived) frames archived across \(archivedSourceCount) sources")
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

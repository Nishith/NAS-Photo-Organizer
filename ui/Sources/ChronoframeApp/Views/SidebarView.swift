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
        VStack(alignment: .leading, spacing: 12) {
            ForEach(visibleSections) { section in
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title)
                        .font(.caption.weight(.semibold))
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 2)

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(destinations(in: section)) { destination in
                            destinationButton(destination)
                        }
                    }
                }
            }

            Spacer()

            LibraryAtAGlanceFooter(
                destinationRoot: historyStore.destinationRoot,
                runCount: historyStore.entries.count,
                totalArchived: historyStore.transferredSources.reduce(0) { $0 + $1.totalCopiedCount }
            )
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

    private var visibleSections: [SidebarSection] {
        let active = Set(SidebarDestination.primaryNavigationCases.map { $0.section })
        return SidebarSection.allCases.filter { active.contains($0) }
    }

    private func destinations(in section: SidebarSection) -> [SidebarDestination] {
        SidebarDestination.primaryNavigationCases.filter { $0.section == section }
    }

    @ViewBuilder
    private func destinationButton(_ destination: SidebarDestination) -> some View {
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

/// Pinned footer below the destination list. Shows the active destination
/// root and at-a-glance counters so the sidebar carries identity even when
/// the workspace is empty. Hidden when there is no destination configured
/// yet — the rest of the UI guides setup in that case.
private struct LibraryAtAGlanceFooter: View {
    let destinationRoot: String
    let runCount: Int
    let totalArchived: Int

    var body: some View {
        if destinationRoot.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Library at a glance")
                    .font(.caption.weight(.semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(DesignTokens.ColorSystem.inkMuted)

                HStack(spacing: 8) {
                    Image(systemName: "externaldrive")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.ColorSystem.accentWaypoint)
                    Text(URL(fileURLWithPath: destinationRoot).lastPathComponent)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(DesignTokens.ColorSystem.inkPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 12) {
                    metric(value: "\(totalArchived.formatted(.number))", label: "archived")
                    metric(value: "\(runCount.formatted(.number))", label: "runs")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(DesignTokens.ColorSystem.utilityBand)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(DesignTokens.ColorSystem.hairline, lineWidth: 0.5)
            )
            .padding(.horizontal, 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Library at a glance: \(totalArchived) photos archived across \(runCount) runs to \(URL(fileURLWithPath: destinationRoot).lastPathComponent)")
        }
    }

    private func metric(value: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(DesignTokens.ColorSystem.inkPrimary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)
        }
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

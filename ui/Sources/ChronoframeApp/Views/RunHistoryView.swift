#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all
    case reports
    case receipts
    case logs
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .reports:
            return "Reports"
        case .receipts:
            return "Receipts"
        case .logs:
            return "Logs"
        case .other:
            return "Other"
        }
    }

    func matches(_ entry: RunHistoryEntry) -> Bool {
        switch self {
        case .all:
            return true
        case .reports:
            return entry.kind == .dryRunReport || entry.kind == .csvArtifact
        case .receipts:
            return entry.kind == .auditReceipt
                || entry.kind == .dedupeAuditReceipt
                || entry.kind == .reorganizeAuditReceipt
                || entry.kind == .jsonArtifact
        case .logs:
            return entry.kind == .runLog || entry.kind == .queueDatabase
        case .other:
            return !(matchesCategory(.reports, entry) || matchesCategory(.receipts, entry) || matchesCategory(.logs, entry))
        }
    }

    private func matchesCategory(_ category: HistoryFilter, _ entry: RunHistoryEntry) -> Bool {
        switch category {
        case .all, .other:
            return false
        case .reports:
            return entry.kind == .dryRunReport || entry.kind == .csvArtifact
        case .receipts:
            return entry.kind == .auditReceipt
                || entry.kind == .dedupeAuditReceipt
                || entry.kind == .reorganizeAuditReceipt
                || entry.kind == .jsonArtifact
        case .logs:
            return entry.kind == .runLog || entry.kind == .queueDatabase
        }
    }
}

private struct HistorySection: Identifiable {
    let id = UUID()
    let date: Date
    let entries: [RunHistoryEntry]
}

struct RunHistoryView: View {
    let appState: AppState
    @ObservedObject private var historyStore: HistoryStore
    @State private var searchText = ""
    @State private var historyFilter: HistoryFilter = .all
    @State private var pendingRevertEntry: RunHistoryEntry?

    private static let fileSizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    init(appState: AppState) {
        self.appState = appState
        self._historyStore = ObservedObject(wrappedValue: appState.historyStore)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.sectionSpacing) {
                headerStrip

                if let error = historyStore.lastRefreshError, !error.isEmpty {
                    refreshErrorStrip(error)
                }

                reusableSourcesSection
                recoveryCenterSection
                archiveSection
            }
            .padding(DesignTokens.Layout.contentPadding)
            .frame(maxWidth: DesignTokens.Layout.archiveMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .darkroom()
        .navigationTitle("Run History")
        .searchable(text: $searchText, prompt: "Search artifacts")
        .confirmationDialog(
            Self.confirmationTitle(for: pendingRevertEntry),
            isPresented: Binding(
                get: { pendingRevertEntry != nil },
                set: { if !$0 { pendingRevertEntry = nil } }
            ),
            presenting: pendingRevertEntry
        ) { entry in
            Button(Self.confirmationActionLabel(for: entry), role: Self.confirmationActionRole(for: entry)) {
                appState.revertHistoryEntry(entry)
                pendingRevertEntry = nil
            }
            Button("Cancel", role: .cancel) {
                pendingRevertEntry = nil
            }
        } message: { entry in
            Text(Self.confirmationMessage(for: entry))
        }
    }

    // MARK: - Confirmation copy

    /// Dedupe revert restores files from the Trash; the prior single
    /// hardcoded message used transfer-revert language ("remove the
    /// files this receipt copied, but only if their contents still
    /// match…") which was wrong for dedupe receipts. Branch by
    /// `entry.kind` so the dialog matches the actual operation. The
    /// helpers are static + pure so they can be tested without
    /// rendering SwiftUI.
    static func confirmationTitle(for entry: RunHistoryEntry?) -> String {
        switch entry?.kind {
        case .dedupeAuditReceipt: return "Restore deduplicated files?"
        case .reorganizeAuditReceipt: return "Undo this reorganize?"
        default: return "Revert this transfer?"
        }
    }

    static func confirmationActionLabel(for entry: RunHistoryEntry) -> String {
        switch entry.kind {
        case .dedupeAuditReceipt: return "Restore"
        case .reorganizeAuditReceipt: return "Undo"
        default: return "Revert"
        }
    }

    static func confirmationActionRole(for entry: RunHistoryEntry) -> ButtonRole? {
        switch entry.kind {
        case .dedupeAuditReceipt, .reorganizeAuditReceipt: return nil
        default: return .destructive
        }
    }

    static func confirmationMessage(for entry: RunHistoryEntry) -> String {
        switch entry.kind {
        case .dedupeAuditReceipt:
            return "Chronoframe will move the files this dedupe run sent to the Trash back to their original locations. Files that have since been emptied from the Trash cannot be restored.\n\nReceipt: \(entry.relativePath)"
        case .reorganizeAuditReceipt:
            return "Chronoframe will move the files this reorganize run changed back to their previous locations, but only if their contents still match the receipt.\n\nReceipt: \(entry.relativePath)"
        default:
            return "Chronoframe will remove the files this receipt copied, but only if their contents still match the original transfer. Files modified after the original copy will be preserved.\n\nReceipt: \(entry.relativePath)"
        }
    }

    // MARK: - Header strip

    private var headerStrip: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Archive")
                    .font(DesignTokens.Typography.title)
                    .foregroundStyle(DesignTokens.ColorSystem.inkPrimary)

                Text(headerMessage)
                    .font(DesignTokens.Typography.subtitle)
                    .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: DesignTokens.Spacing.md)

            Button {
                appState.openDestination()
            } label: {
                Label("Open Destination", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .disabled(historyStore.destinationRoot.isEmpty)
        }
    }

    private var headerMessage: String {
        if historyStore.entries.isEmpty {
            return historyStore.destinationRoot.isEmpty
                ? "Choose a destination in Setup, then a preview will create the first report here."
                : "Run a preview or transfer to build the first entries in this archive."
        }
        return "\(historyStore.entries.count) artifacts · \(historyStore.transferredSources.count) reusable sources."
    }

    private func refreshErrorStrip(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignTokens.ColorSystem.statusWarning)
            Text(message)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.ColorSystem.statusWarning)
        }
        .padding(DesignTokens.Layout.compactPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.innerCard, style: .continuous)
                .fill(DesignTokens.ColorSystem.statusWarning.opacity(0.08))
        )
    }

    // MARK: - Recovery center

    private var recoveryCenterSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            SectionHeading(
                title: "Undo Center",
                message: "Recent runs that have a recovery receipt."
            )

            let receipts = filteredRecoveryReceipts
            if receipts.isEmpty {
                EmptyStateView(
                    title: "No Revertable Runs Yet",
                    message: "Transfers, dedupe commits, and reorganize runs write receipts here when they can be undone safely.",
                    systemImage: "arrow.uturn.backward.circle"
                )
            } else {
                DarkroomPanel(variant: .panel) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(receipts.prefix(5).enumerated()), id: \.element.id) { index, entry in
                            if index != 0 {
                                Rectangle()
                                    .fill(DesignTokens.ColorSystem.hairline.opacity(0.5))
                                    .frame(height: 0.5)
                            }
                            recoveryRow(for: entry)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("recoveryCenterSection")
    }

    private var filteredRecoveryReceipts: [RunHistoryEntry] {
        historyStore.entries
            .filter {
                $0.kind == .auditReceipt
                    || $0.kind == .dedupeAuditReceipt
                    || $0.kind == .reorganizeAuditReceipt
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func recoveryRow(for entry: RunHistoryEntry) -> some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
            Image(systemName: recoverySymbol(for: entry.kind))
                .foregroundStyle(tint(for: entry.kind))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(recoveryTitle(for: entry))
                    .font(.subheadline.weight(.semibold))
                Text("\(entry.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(entry.relativePath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: DesignTokens.Spacing.md)

            Button(Self.confirmationActionLabel(for: entry)) {
                pendingRevertEntry = entry
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, DesignTokens.Spacing.sm)
    }

    private func recoverySymbol(for kind: RunHistoryEntryKind) -> String {
        switch kind {
        case .dedupeAuditReceipt:
            return "trash.slash"
        case .reorganizeAuditReceipt:
            return "rectangle.3.offgrid"
        default:
            return "arrow.uturn.backward.circle"
        }
    }

    private func recoveryTitle(for entry: RunHistoryEntry) -> String {
        switch entry.kind {
        case .dedupeAuditReceipt:
            return "Deduplicate run can be restored"
        case .reorganizeAuditReceipt:
            return "Reorganize run can be undone"
        default:
            return "Transfer can be reverted"
        }
    }

    // MARK: - Reusable sources

    private var reusableSourcesSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            SectionHeading(
                title: "Reusable Sources",
                message: "Paths from completed transfers into this destination."
            )

            if historyStore.transferredSources.isEmpty {
                EmptyStateView(
                    title: "No Reusable Sources Yet",
                    message: "After a completed transfer, the source folder will appear here so you can use it again without re-entering the path.",
                    systemImage: "folder.badge.questionmark"
                )
            } else {
                DarkroomPanel(variant: .panel) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(historyStore.transferredSources.enumerated()), id: \.element.id) { index, record in
                            if index != 0 {
                                Rectangle()
                                    .fill(DesignTokens.ColorSystem.hairline)
                                    .frame(height: 0.5)
                            }
                            transferredSourceRow(for: record)
                        }
                    }
                }
            }
        }
    }

    static func sourceFolderLabel(for sourcePath: String) -> String {
        URL(fileURLWithPath: sourcePath).lastPathComponent
    }

    private func transferredSourceRow(for record: TransferredSourceRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.sourceFolderLabel(for: record.sourcePath))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignTokens.ColorSystem.inkPrimary)
                    .lineLimit(1)
                Text(record.sourcePath)
                    .font(DesignTokens.Typography.mono)
                    .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text("Last used \(record.lastTransferredAt.formatted(date: .abbreviated, time: .shortened))")
                    Text("·")
                        .foregroundStyle(DesignTokens.ColorSystem.inkMuted.opacity(0.5))
                    Text("\(record.runCount) run\(record.runCount == 1 ? "" : "s")")
                    Text("·")
                        .foregroundStyle(DesignTokens.ColorSystem.inkMuted.opacity(0.5))
                    Text("\(record.totalCopiedCount) copied")
                }
                .font(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
            }

            Spacer(minLength: DesignTokens.Spacing.md)

            Button("Use Again") {
                appState.useHistoricalSource(record)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("useHistoricalSourceButton")

            Menu {
                Button("Reveal in Finder") {
                    appState.revealTransferredSource(record)
                }
                .accessibilityIdentifier("revealHistoricalSourceButton")
                Divider()
                Button("Forget This Source", role: .destructive) {
                    appState.forgetTransferredSource(record)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for source")
        }
        .padding(.horizontal, 2)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Archive (artifact list)

    private var archiveSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.md) {
                SectionHeading(
                    title: "Artifacts",
                    message: "Reports, receipts, and logs from every preview and transfer."
                )

                Spacer(minLength: DesignTokens.Spacing.md)

                Picker("Filter", selection: $historyFilter) {
                    ForEach(HistoryFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                .accessibilityIdentifier("historyFilterControl")
            }

            if filteredEntries.isEmpty {
                EmptyStateView(
                    title: historyStore.entries.isEmpty ? "No Artifacts Yet" : "No Matching Artifacts",
                    message: historyStore.entries.isEmpty
                        ? "Run a preview or transfer, then return here to inspect reports, receipts, and logs."
                        : "Try a different filter or search term.",
                    systemImage: "doc.text.magnifyingglass"
                )
            } else {
                DarkroomPanel(variant: .panel) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(groupedEntries.enumerated()), id: \.element.id) { sectionIndex, section in
                            if sectionIndex != 0 {
                                Rectangle()
                                    .fill(DesignTokens.ColorSystem.hairline)
                                    .frame(height: 0.5)
                                    .padding(.vertical, DesignTokens.Spacing.sm)
                            }

                            VStack(alignment: .leading, spacing: 0) {
                                sectionHeader(for: section.date)

                                ForEach(Array(section.entries.enumerated()), id: \.element.id) { entryIndex, entry in
                                    if entryIndex != 0 {
                                        Rectangle()
                                            .fill(DesignTokens.ColorSystem.hairline.opacity(0.5))
                                            .frame(height: 0.5)
                                    }
                                    artifactRow(for: entry)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func sectionHeader(for date: Date) -> some View {
        Text(date.formatted(date: .abbreviated, time: .omitted).uppercased())
            .font(DesignTokens.Typography.label)
            .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
            .tracking(0.8)
            .padding(.bottom, DesignTokens.Spacing.xs)
            .padding(.top, DesignTokens.Spacing.xs)
    }

    private func artifactRow(for entry: RunHistoryEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.md) {
            Image(systemName: entry.kind.systemImage)
                .font(.system(size: 14))
                .foregroundStyle(tint(for: entry.kind))
                .frame(width: 20, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(DesignTokens.Typography.body)
                    .fontWeight(.medium)
                    .foregroundStyle(DesignTokens.ColorSystem.inkPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text(entry.kind.title)
                    Text("·")
                        .foregroundStyle(DesignTokens.ColorSystem.inkMuted.opacity(0.5))
                    Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                    if let size = entry.fileSizeBytes {
                        Text("·")
                            .foregroundStyle(DesignTokens.ColorSystem.inkMuted.opacity(0.5))
                        Text(Self.fileSizeFormatter.string(fromByteCount: size))
                    }
                }
                .font(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            Text(entry.relativePath)
                .font(DesignTokens.Typography.mono)
                .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 260, alignment: .trailing)

            Button("Open") {
                appState.openHistoryEntry(entry)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Open \(entry.title)")
            .accessibilityIdentifier("openArtifact_\(entry.id)")

            Menu {
                Button("Reveal in Finder") {
                    appState.revealHistoryEntry(entry)
                }
                .accessibilityIdentifier("revealArtifact_\(entry.id)")
                if entry.kind == .auditReceipt || entry.kind == .dedupeAuditReceipt || entry.kind == .reorganizeAuditReceipt {
                    Divider()
                    Button("Revert this run…") {
                        pendingRevertEntry = entry
                    }
                    .accessibilityIdentifier("revertArtifact_\(entry.id)")
                }
                Divider()
                Button("Move to Trash", role: .destructive) {
                    historyStore.remove(entry: entry)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(entry.title)")
        }
        .padding(.vertical, DesignTokens.Spacing.sm)
        .accessibilityElement(children: .contain)
    }

    private var filteredEntries: [RunHistoryEntry] {
        historyStore.entries
            .filter { historyFilter.matches($0) }
            .filter { entry in
                guard !searchText.isEmpty else { return true }
                let query = searchText.lowercased()
                return entry.title.lowercased().contains(query)
                    || entry.relativePath.lowercased().contains(query)
                    || entry.kind.title.lowercased().contains(query)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var groupedEntries: [HistorySection] {
        let grouped = Dictionary(grouping: filteredEntries) { entry in
            Calendar.current.startOfDay(for: entry.createdAt)
        }

        return grouped
            .keys
            .sorted(by: >)
            .map { date in
                HistorySection(
                    date: date,
                    entries: grouped[date]?.sorted(by: { $0.createdAt > $1.createdAt }) ?? []
                )
            }
    }

    private func tint(for kind: RunHistoryEntryKind) -> SwiftUI.Color {
        switch kind {
        case .dryRunReport, .csvArtifact:
            return DesignTokens.ColorSystem.accentAction
        case .auditReceipt, .jsonArtifact:
            return DesignTokens.ColorSystem.statusSuccess
        case .dedupeAuditReceipt, .reorganizeAuditReceipt:
            return DesignTokens.ColorSystem.accentWaypoint
        case .runLog:
            return DesignTokens.ColorSystem.accentWaypoint
        case .queueDatabase:
            return DesignTokens.ColorSystem.statusActive
        }
    }
}

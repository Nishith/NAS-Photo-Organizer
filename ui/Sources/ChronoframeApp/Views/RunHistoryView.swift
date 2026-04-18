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
            return entry.kind == .auditReceipt || entry.kind == .jsonArtifact
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
            return entry.kind == .auditReceipt || entry.kind == .jsonArtifact
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
                heroCard

                if let error = historyStore.lastRefreshError, !error.isEmpty {
                    MeridianSurfaceCard(tint: DesignTokens.Color.warning) {
                        Text(error)
                            .foregroundStyle(DesignTokens.Color.warning)
                    }
                }

                reusableSourcesCard
                archiveCard
            }
            .padding(DesignTokens.Layout.contentPadding)
            .frame(maxWidth: DesignTokens.Layout.archiveMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Run History")
        .searchable(text: $searchText, prompt: "Search artifacts")
    }

    private var heroCard: some View {
        DetailHeroCard(
            eyebrow: "Archive",
            title: "Inspect Reports, Receipts, and Logs",
            message: "Every preview and transfer leaves behind artifacts that make the run auditable and easy to revisit later.",
            badgeTitle: historyStore.entries.isEmpty ? "Waiting for First Artifact" : "Archive Active",
            badgeSystemImage: historyStore.entries.isEmpty ? "clock" : "archivebox.fill",
            tint: historyStore.entries.isEmpty ? DesignTokens.Color.inkMuted : DesignTokens.Color.aqua,
            systemImage: "archivebox"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                SummaryLine(title: "Destination", value: historyStore.destinationRoot.isEmpty ? "Choose a destination in Setup to build an archive" : historyStore.destinationRoot)
                SummaryLine(title: "Artifacts", value: "\(historyStore.entries.count)")
                SummaryLine(title: "Reusable Sources", value: "\(historyStore.transferredSources.count)")
                SummaryLine(title: "Focus", value: historyStore.entries.isEmpty ? "Run a preview to create the first report" : "Search, filter, or reopen prior run outputs")
            }
        } actions: {
            Button {
                appState.openDestination()
            } label: {
                Label("Open Destination", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(historyStore.destinationRoot.isEmpty)
        }
    }

    private var reusableSourcesCard: some View {
        MeridianSurfaceCard {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.cardSpacing) {
                SectionHeading(
                    eyebrow: "Reusable Sources",
                    title: "Start Again from a Trusted Source",
                    message: "Completed source paths are saved here so you can quickly reuse a library that already transferred into this destination."
                )

                if historyStore.transferredSources.isEmpty {
                    EmptyStateView(
                        title: "No Reusable Sources Yet",
                        message: "After a completed transfer, the source folder will appear here so you can use it again without re-entering the path.",
                        systemImage: "folder.badge.questionmark"
                    )
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(historyStore.transferredSources) { record in
                            transferredSourceRow(for: record)
                        }
                    }
                }
            }
        }
    }

    private func transferredSourceRow(for record: TransferredSourceRecord) -> some View {
        MeridianSurfaceCard(style: .inner, tint: DesignTokens.Color.amber) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.sourcePath)
                            .font(.body.monospaced())
                            .foregroundStyle(DesignTokens.Color.inkPrimary)
                            .lineLimit(2)
                            .truncationMode(.middle)

                        Text("Last used \(record.lastTransferredAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    MeridianStatusBadge(
                        title: "\(record.runCount) run\(record.runCount == 1 ? "" : "s")",
                        systemImage: "clock.arrow.circlepath",
                        tint: DesignTokens.Color.amberWaypoint
                    )
                }

                SummaryLine(title: "Total Copied", value: "\(record.totalCopiedCount) file\(record.totalCopiedCount == 1 ? "" : "s")")
                SummaryLine(title: "Last Run", value: "\(record.lastCopiedCount) file\(record.lastCopiedCount == 1 ? "" : "s") copied")

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Button("Use Again") {
                            appState.useHistoricalSource(record)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Reveal") {
                            appState.revealTransferredSource(record)
                        }

                        Menu("More") {
                            Button("Forget This Source", role: .destructive) {
                                appState.forgetTransferredSource(record)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Button("Use Again") {
                            appState.useHistoricalSource(record)
                        }
                        .buttonStyle(.borderedProminent)

                        HStack(spacing: 8) {
                            Button("Reveal") {
                                appState.revealTransferredSource(record)
                            }

                            Menu("More") {
                                Button("Forget This Source", role: .destructive) {
                                    appState.forgetTransferredSource(record)
                                }
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Source \(record.sourcePath), last transferred \(record.lastTransferredAt.formatted()), \(record.runCount) runs, \(record.totalCopiedCount) files copied")
    }

    private var archiveCard: some View {
        MeridianSurfaceCard {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.cardSpacing) {
                HStack(alignment: .top, spacing: 12) {
                    SectionHeading(
                        eyebrow: "Artifacts",
                        title: "Browse the Archive",
                        message: "Filter by artifact type and search by name or path to find the exact output you need."
                    )

                    Spacer(minLength: 12)

                    Picker("Filter", selection: $historyFilter) {
                        ForEach(HistoryFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                }

                if filteredEntries.isEmpty {
                    EmptyStateView(
                        title: historyStore.entries.isEmpty ? "No Artifacts Yet" : "No Matching Artifacts",
                        message: historyStore.entries.isEmpty
                            ? "Run a preview or transfer, then return here to inspect reports, receipts, and logs."
                            : "Try a different filter or search term to surface another part of the archive.",
                        systemImage: "doc.text.magnifyingglass"
                    )
                } else {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(groupedEntries) { section in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(section.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(DesignTokens.Typography.cardTitle)
                                    .foregroundStyle(DesignTokens.Color.inkPrimary)

                                ForEach(section.entries) { entry in
                                    historyRow(for: entry)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func historyRow(for entry: RunHistoryEntry) -> some View {
        MeridianSurfaceCard(style: .inner, tint: tint(for: entry.kind)) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label {
                            Text(entry.title)
                                .font(.headline)
                        } icon: {
                            Image(systemName: entry.kind.systemImage)
                                .foregroundStyle(tint(for: entry.kind))
                        }

                        Text(entry.relativePath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 12)

                    MeridianStatusBadge(
                        title: entry.kind.title,
                        systemImage: entry.kind.systemImage,
                        tint: tint(for: entry.kind)
                    )
                }

                SummaryLine(title: "Created", value: entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                SummaryLine(title: "Size", value: entry.fileSizeBytes.map { Self.fileSizeFormatter.string(fromByteCount: $0) } ?? "—")

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Button("Open") {
                            appState.openHistoryEntry(entry)
                        }
                        .accessibilityLabel("Open \(entry.title)")
                        .accessibilityIdentifier("openArtifact_\(entry.id)")

                        Button("Reveal") {
                            appState.revealHistoryEntry(entry)
                        }
                        .accessibilityLabel("Reveal \(entry.title) in Finder")
                        .accessibilityIdentifier("revealArtifact_\(entry.id)")

                        Menu("More") {
                            Button("Move to Trash", role: .destructive) {
                                historyStore.remove(entry: entry)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Button("Open") {
                            appState.openHistoryEntry(entry)
                        }
                        .accessibilityLabel("Open \(entry.title)")
                        .accessibilityIdentifier("openArtifact_\(entry.id)")

                        HStack(spacing: 8) {
                            Button("Reveal") {
                                appState.revealHistoryEntry(entry)
                            }
                            .accessibilityLabel("Reveal \(entry.title) in Finder")
                            .accessibilityIdentifier("revealArtifact_\(entry.id)")

                            Menu("More") {
                                Button("Move to Trash", role: .destructive) {
                                    historyStore.remove(entry: entry)
                                }
                            }
                        }
                    }
                }
            }
        }
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
            return DesignTokens.Color.sky
        case .auditReceipt, .jsonArtifact:
            return DesignTokens.Color.success
        case .runLog:
            return DesignTokens.Color.amber
        case .queueDatabase:
            return DesignTokens.Color.amberWaypoint
        }
    }
}

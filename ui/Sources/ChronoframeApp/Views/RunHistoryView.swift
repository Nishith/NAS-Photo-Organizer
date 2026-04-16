#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

struct RunHistoryView: View {
    let appState: AppState
    @ObservedObject private var historyStore: HistoryStore

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
        List {
            if !historyStore.destinationRoot.isEmpty {
                Section("Destination") {
                    Text(historyStore.destinationRoot)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            Section("Artifacts") {
                if historyStore.entries.isEmpty {
                    EmptyStateView(
                        title: "No Artifacts Yet",
                        message: "Run a preview or transfer, then open this section to inspect reports, receipts, and logs.",
                        systemImage: "clock.arrow.circlepath"
                    )
                    .listRowInsets(EdgeInsets())
                } else {
                    ForEach(historyStore.entries) { entry in
                        historyRow(for: entry)
                            .padding(.vertical, 4)
                            .contextMenu {
                                Button("Open") { appState.openHistoryEntry(entry) }
                                Button("Reveal in Finder") { appState.revealHistoryEntry(entry) }
                                Divider()
                                Button("Move to Trash", role: .destructive) {
                                    historyStore.remove(entry: entry)
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle("Run History")
        .toolbar {
            if !historyStore.entries.isEmpty {
                ToolbarItem(placement: .automatic) {
                    Button(role: .destructive) {
                        historyStore.removeAll()
                    } label: {
                        Label("Clear All", systemImage: "trash")
                    }
                    .accessibilityLabel("Move all artifacts to Trash")
                    .accessibilityIdentifier("clearAllArtifactsButton")
                }
            }
        }
    }

    private func historyRow(for entry: RunHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Label {
                    Text(entry.title)
                        .font(.headline)
                } icon: {
                    Image(systemName: entry.kind.systemImage)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(entry.relativePath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    historyMetadata(for: entry)
                    Spacer(minLength: 12)
                    historyActions(for: entry)
                }

                VStack(alignment: .leading, spacing: 8) {
                    historyMetadata(for: entry)
                    historyActions(for: entry)
                }
            }
        }
    }

    private func historyMetadata(for entry: RunHistoryEntry) -> some View {
        HStack(spacing: 10) {
            Text(entry.kind.title)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())

            if let fileSizeBytes = entry.fileSizeBytes {
                Text(Self.fileSizeFormatter.string(fromByteCount: fileSizeBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func historyActions(for entry: RunHistoryEntry) -> some View {
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
            }

            Menu("Actions") {
                Button("Open") {
                    appState.openHistoryEntry(entry)
                }
                .accessibilityLabel("Open \(entry.title)")

                Button("Reveal") {
                    appState.revealHistoryEntry(entry)
                }
                .accessibilityLabel("Reveal \(entry.title) in Finder")
            }
            .accessibilityLabel("Actions for \(entry.title)")
        }
    }
}

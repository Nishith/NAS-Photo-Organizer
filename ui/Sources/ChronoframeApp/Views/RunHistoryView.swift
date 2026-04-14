#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

struct RunHistoryView: View {
    @ObservedObject var appState: AppState
    private static let fileSizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        List {
            if !appState.historyStore.destinationRoot.isEmpty {
                Section("Destination") {
                    Text(appState.historyStore.destinationRoot)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            Section("Artifacts") {
                if appState.historyStore.entries.isEmpty {
                    EmptyStateView(
                        title: "No Artifacts Yet",
                        message: "Run a preview or transfer, then open this section to inspect reports, receipts, and logs.",
                        systemImage: "clock.arrow.circlepath"
                    )
                    .listRowInsets(EdgeInsets())
                } else {
                    ForEach(appState.historyStore.entries) { entry in
                        historyRow(for: entry)
                            .padding(.vertical, 4)
                    }
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle("Run History")
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

                Button("Reveal") {
                    appState.revealHistoryEntry(entry)
                }
            }

            Menu("Actions") {
                Button("Open") {
                    appState.openHistoryEntry(entry)
                }

                Button("Reveal") {
                    appState.revealHistoryEntry(entry)
                }
            }
        }
    }
}

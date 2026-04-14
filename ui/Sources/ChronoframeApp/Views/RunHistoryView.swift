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
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Run History")
                    .font(.largeTitle.weight(.bold))
                Text("Chronoframe reads existing artifacts from the destination root without changing them.")
                    .foregroundStyle(.secondary)
            }

            if appState.historyStore.entries.isEmpty {
                EmptyStateView(
                    title: "No Artifacts Yet",
                    message: "Run a preview or transfer, then open this section to inspect reports, receipts, and logs.",
                    systemImage: "clock.arrow.circlepath"
                )
            } else {
                List(appState.historyStore.entries) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Label {
                                Text(entry.title)
                                    .font(.headline)
                            } icon: {
                                Image(systemName: entry.kind.systemImage)
                                    .foregroundStyle(.secondary)
                            }

                            Text(entry.relativePath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)

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

                        Spacer()

                        VStack(alignment: .trailing, spacing: 8) {
                            Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 8) {
                                Button("Open") {
                                    appState.openHistoryEntry(entry)
                                }

                                Button("Reveal") {
                                    appState.revealHistoryEntry(entry)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
        .padding(24)
        .navigationTitle("Run History")
    }
}

#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

/// Left pane: scrollable list of all clusters grouped by kind. Each row
/// shows a thumbnail strip of the cluster's members, member count, and
/// recoverable bytes. Selecting a row sets the focused cluster in the
/// parent view.
struct ClusterListPane: View {
    let clusters: [DuplicateCluster]
    let decisions: DedupeDecisions
    @Binding var focusedClusterID: UUID?
    @Binding var focusedMemberPath: String?
    @ObservedObject var thumbnailLoader: DedupeThumbnailLoader

    private var grouped: [(ClusterKind, [DuplicateCluster])] {
        let order: [ClusterKind] = [.exactDuplicate, .burst, .nearDuplicate]
        return order.compactMap { kind in
            let matching = clusters.filter { $0.kind == kind }
            return matching.isEmpty ? nil : (kind, matching)
        }
    }

    var body: some View {
        List(selection: $focusedClusterID) {
            ForEach(grouped, id: \.0) { kind, list in
                Section(header: Text("\(kind.title) (\(list.count))")) {
                    ForEach(list) { cluster in
                        ClusterRow(
                            cluster: cluster,
                            decisions: decisions,
                            thumbnailLoader: thumbnailLoader
                        )
                        .tag(cluster.id)
                        .contentShape(Rectangle())
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: focusedClusterID) { newID in
            guard let newID, let cluster = clusters.first(where: { $0.id == newID }) else { return }
            focusedMemberPath = cluster.members.first?.path
        }
    }
}

private struct ClusterRow: View {
    let cluster: DuplicateCluster
    let decisions: DedupeDecisions
    @ObservedObject var thumbnailLoader: DedupeThumbnailLoader

    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(cluster.members.prefix(5)) { member in
                    DedupeThumbnailView(
                        path: member.path,
                        size: CGSize(width: 44, height: 44),
                        loader: thumbnailLoader
                    )
                    .opacity(decisionFor(member) == .delete ? 0.45 : 1.0)
                    .overlay(alignment: .topTrailing) {
                        if cluster.suggestedKeeperIDs.contains(member.id) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(DesignTokens.ColorSystem.statusSuccess)
                                .padding(2)
                        }
                    }
                }
                if cluster.members.count > 5 {
                    Text("+\(cluster.members.count - 5)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 4) {
                Text("\(cluster.members.count) photos")
                    .font(.caption)
                Text("·")
                    .foregroundStyle(.secondary)
                Text(Self.formatter.string(fromByteCount: cluster.bytesIfPruned))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isFullyReviewed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.ColorSystem.statusSuccess)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func decisionFor(_ member: PhotoCandidate) -> DedupeDecision {
        decisions.byPath[member.path] ?? (cluster.suggestedKeeperIDs.contains(member.id) ? .keep : .delete)
    }

    private var isFullyReviewed: Bool {
        cluster.members.allSatisfy { decisions.byPath[$0.path] != nil }
    }
}

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
    let deletionPlan: DeduplicationPlan
    @Binding var focusedClusterID: UUID?
    @Binding var focusedMemberPath: String?
    @ObservedObject var thumbnailLoader: DedupeThumbnailLoader
    @State private var confidenceFilter: ConfidenceFilter = .all

    private enum ConfidenceFilter: String, CaseIterable {
        case all
        case high
        case medium
        case low

        var label: String {
            switch self {
            case .all: return "All"
            case .high: return "Auto"
            case .medium: return "Review"
            case .low: return "Careful"
            }
        }
    }

    private var filteredClusters: [DuplicateCluster] {
        switch confidenceFilter {
        case .all: return clusters
        case .high: return clusters.filter { ($0.annotation?.confidence ?? .medium) == .high }
        case .medium: return clusters.filter { ($0.annotation?.confidence ?? .medium) == .medium }
        case .low: return clusters.filter { ($0.annotation?.confidence ?? .medium) == .low }
        }
    }

    private var grouped: [(ClusterKind, [DuplicateCluster])] {
        let order: [ClusterKind] = [.exactDuplicate, .burst, .nearDuplicate, .editedVariant]
        return order.compactMap { kind in
            let matching = filteredClusters.filter { $0.kind == kind }
            return matching.isEmpty ? nil : (kind, matching)
        }
    }

    private func bucketCount(_ filter: ConfidenceFilter) -> Int {
        switch filter {
        case .all: return clusters.count
        case .high: return clusters.filter { ($0.annotation?.confidence ?? .medium) == .high }.count
        case .medium: return clusters.filter { ($0.annotation?.confidence ?? .medium) == .medium }.count
        case .low: return clusters.filter { ($0.annotation?.confidence ?? .medium) == .low }.count
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Filter", selection: $confidenceFilter) {
                ForEach(ConfidenceFilter.allCases, id: \.self) { filter in
                    Text("\(filter.label) (\(bucketCount(filter)))")
                        .tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)

            List(selection: $focusedClusterID) {
                ForEach(grouped, id: \.0) { kind, list in
                    Section(header: Text("\(kind.title) (\(list.count))")) {
                        ForEach(list) { cluster in
                            ClusterRow(
                                cluster: cluster,
                                decisions: decisions,
                                recoverableBytes: recoverableBytes(for: cluster),
                                thumbnailLoader: thumbnailLoader
                            )
                            .tag(cluster.id)
                            .contentShape(Rectangle())
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .accessibilityIdentifier("dedupeReviewClusterList")
        .onChange(of: focusedClusterID) { newID in
            guard let newID, let cluster = clusters.first(where: { $0.id == newID }) else { return }
            focusedMemberPath = cluster.members.first?.path
        }
    }

    private func recoverableBytes(for cluster: DuplicateCluster) -> Int64 {
        deletionPlan.items
            .filter { $0.owningClusterID == cluster.id }
            .reduce(0) { $0 + $1.sizeBytes }
    }
}

private struct ClusterRow: View {
    let cluster: DuplicateCluster
    let decisions: DedupeDecisions
    let recoverableBytes: Int64
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
                        // Once the user has touched a decision the
                        // scanner's suggestion is no longer actionable
                        // signal — the decision badge / opacity already
                        // communicate keep vs delete. Hide the seal so
                        // the thumbnail doesn't carry three signals.
                        let hasExplicitDecision = decisions.byPath[member.path] != nil
                        if !hasExplicitDecision && isSuggestedKeeper(member) {
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
                confidenceDot
                Text("\(cluster.members.count) photos")
                    .font(.caption)
                Text("·")
                    .foregroundStyle(.secondary)
                Text(Self.formatter.string(fromByteCount: recoverableBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if hasWarnings {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                Spacer()
                if isFullyReviewed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.ColorSystem.statusSuccess)
                }
            }
            if let annotation = cluster.annotation {
                Text(MatchReasonFormatter.oneLiner(annotation))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private func decisionFor(_ member: PhotoCandidate) -> DedupeDecision {
        decisions.byPath[member.path] ?? (isSuggestedKeeper(member) ? .keep : .delete)
    }

    private var isFullyReviewed: Bool {
        cluster.members.allSatisfy { decisions.byPath[$0.path] != nil }
    }

    private var hasWarnings: Bool {
        guard let annotation = cluster.annotation else { return false }
        return !annotation.warnings.isEmpty
    }

    @ViewBuilder
    private var confidenceDot: some View {
        let level = cluster.annotation?.confidence ?? .medium
        Circle()
            .fill(confidenceColor(level))
            .frame(width: 6, height: 6)
    }

    private func confidenceColor(_ level: ConfidenceLevel) -> Color {
        switch level {
        case .high: return .green
        case .medium: return .yellow
        case .low: return .orange
        }
    }

    private func isSuggestedKeeper(_ member: PhotoCandidate) -> Bool {
        cluster.suggestedKeeperIDs.prefix(1).contains(member.id)
    }
}

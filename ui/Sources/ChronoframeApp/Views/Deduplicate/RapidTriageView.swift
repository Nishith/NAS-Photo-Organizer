#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

struct RapidTriageView: View {
    @ObservedObject var sessionStore: DeduplicateSessionStore
    @ObservedObject var thumbnailLoader: DedupeThumbnailLoader
    @State private var currentIndex: Int = 0
    @State private var showingComparison = false
    @State private var dragOffset: CGSize = .zero
    @Environment(\.dismiss) private var dismiss

    var clustersToReview: [DuplicateCluster]

    private var currentCluster: DuplicateCluster? {
        guard currentIndex < clustersToReview.count else { return nil }
        return clustersToReview[currentIndex]
    }

    private var progress: Double {
        guard !clustersToReview.isEmpty else { return 1.0 }
        return Double(currentIndex) / Double(clustersToReview.count)
    }

    private var reclaimableBytes: Int64 {
        let plan = sessionStore.currentDeletionPlan()
        return plan.totalBytes
    }

    private static let bytesFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let cluster = currentCluster {
                clusterCard(cluster)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                completionView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            actionBar
        }
        .background(DesignTokens.ColorSystem.panel)
        .frame(minWidth: 700, minHeight: 550)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Rapid Triage")
                    .font(.headline)
                Spacer()
                Text("\(currentIndex) of \(clustersToReview.count) reviewed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.secondary)
                Text("\(Self.bytesFormatter.string(fromByteCount: reclaimableBytes)) reclaimable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Exit") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            ProgressView(value: progress)
                .tint(DesignTokens.ColorSystem.accentAction)
        }
        .padding(DesignTokens.Spacing.md)
    }

    // MARK: - Cluster Card

    private func clusterCard(_ cluster: DuplicateCluster) -> some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            if let annotation = cluster.annotation, !annotation.warnings.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("Review carefully — \(MatchReasonFormatter.warningSummary(annotation.warnings[0]))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.1))
                .clipShape(Capsule())
            }

            heroImage(for: cluster)
                .offset(dragOffset)
                .gesture(swipeGesture)
                .animation(.spring(response: 0.3), value: dragOffset)

            memberStrip(for: cluster)

            if let annotation = cluster.annotation {
                Text(MatchReasonFormatter.oneLiner(annotation))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(DesignTokens.Spacing.lg)
    }

    private func heroImage(for cluster: DuplicateCluster) -> some View {
        let keeper = cluster.members.first { cluster.suggestedKeeperIDs.prefix(1).contains($0.id) }
            ?? cluster.members.first
        return Group {
            if let keeper {
                DedupeThumbnailView(
                    path: keeper.path,
                    size: CGSize(width: 400, height: 300),
                    loader: thumbnailLoader
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(radius: 4)
            }
        }
    }

    private func memberStrip(for cluster: DuplicateCluster) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(cluster.members) { member in
                    let isKeeper = cluster.suggestedKeeperIDs.prefix(1).contains(member.id)
                    DedupeThumbnailView(
                        path: member.path,
                        size: CGSize(width: 56, height: 56),
                        loader: thumbnailLoader
                    )
                    .opacity(isKeeper ? 1.0 : 0.6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(isKeeper ? DesignTokens.ColorSystem.statusSuccess : Color.clear, lineWidth: 2)
                    )
                }
            }
        }
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: DesignTokens.Spacing.lg) {
            Button {
                skipCurrent()
            } label: {
                Label("Skip", systemImage: "arrow.right")
            }
            .keyboardShortcut(.leftArrow, modifiers: [])

            Button {
                showingComparison = true
            } label: {
                Label("Compare", systemImage: "rectangle.on.rectangle")
            }
            .keyboardShortcut(.space, modifiers: [])
            .sheet(isPresented: $showingComparison) {
                if let cluster = currentCluster,
                   let keeper = cluster.members.first(where: { cluster.suggestedKeeperIDs.prefix(1).contains($0.id) }),
                   let other = cluster.members.first(where: { !cluster.suggestedKeeperIDs.prefix(1).contains($0.id) }) {
                    ComparisonOverlayView(leftPath: keeper.path, rightPath: other.path)
                }
            }

            Button {
                acceptCurrent()
            } label: {
                Label("Accept", systemImage: "checkmark.circle")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.rightArrow, modifiers: [])
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(DesignTokens.Spacing.md)
    }

    // MARK: - Completion

    private var completionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(DesignTokens.ColorSystem.statusSuccess)
            Text("All clusters reviewed")
                .font(.title3.weight(.semibold))
            Text("Return to the main review to commit your decisions.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Actions

    private func acceptCurrent() {
        guard let cluster = currentCluster else { return }
        sessionStore.acceptSuggestionsForCluster(cluster)
        advance()
    }

    private func skipCurrent() {
        advance()
    }

    private func advance() {
        withAnimation(.easeInOut(duration: 0.2)) {
            dragOffset = .zero
            currentIndex += 1
        }
    }

    private var swipeGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                if value.translation.width > 100 {
                    acceptCurrent()
                } else if value.translation.width < -100 {
                    skipCurrent()
                }
                dragOffset = .zero
            }
    }
}

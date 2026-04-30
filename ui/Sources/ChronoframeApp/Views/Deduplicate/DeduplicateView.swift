#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

/// Top-level workspace for the Deduplicate sidebar destination. Branches
/// between idle / scanning / reviewing / committing / completed states and
/// hosts the cluster review split-pane.
struct DeduplicateView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var sessionStore: DeduplicateSessionStore
    @ObservedObject private var preferencesStore: PreferencesStore
    @StateObject private var thumbnailLoader = DedupeThumbnailLoader()

    @State private var focusedClusterID: UUID?
    @State private var focusedMemberPath: String?
    @State private var showingCommitConfirmation = false
    @State private var hardDeleteForThisCommit = false
    @AppStorage("didOnboardDeduplicate") private var didOnboardDeduplicate = false

    init(appState: AppState) {
        self.appState = appState
        self._sessionStore = ObservedObject(wrappedValue: appState.deduplicateSessionStore)
        self._preferencesStore = ObservedObject(wrappedValue: appState.preferencesStore)
    }

    var body: some View {
        Group {
            switch sessionStore.status {
            case .idle:
                idleView
            case .scanning:
                scanningView
            case .readyToReview, .committing:
                if sessionStore.clusters.isEmpty {
                    emptyResultsView
                } else {
                    reviewView
                }
            case .completed:
                completedView
            case .reverting:
                revertingView
            case .reverted:
                revertedView
            case .failed(let message):
                failureView(message: message)
            }
        }
        .navigationTitle("Deduplicate")

        .onChange(of: preferencesStore.dedupeAllowHardDelete) { allowHardDelete in
            if !allowHardDelete {
                hardDeleteForThisCommit = false
            }
        }
    }

    // MARK: - Idle

    private var destinationCard: some View {
        MeridianSurfaceCard(
            style: .inner,
            tint: appState.deduplicateDestinationPath.isEmpty ? DesignTokens.ColorSystem.statusDanger : DesignTokens.ColorSystem.statusSuccess
        ) {
            ViewThatFits(in: .horizontal) {
                DeduplicateDestinationCardContent(appState: appState, isVertical: false)
                DeduplicateDestinationCardContent(appState: appState, isVertical: true)
            }
        }
    }

    private var idleView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.sectionSpacing) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Deduplicate")
                        .font(DesignTokens.Typography.title)
                    Text("Find similar shots and prune.")
                        .font(DesignTokens.Typography.subtitle)
                        .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)
                }

                if !didOnboardDeduplicate {
                    OnboardingCard(
                        icon: "square.stack.3d.up",
                        title: "How Deduplicate works",
                        subtitle: "Three steps before anything moves.",
                        bullets: [
                            "We group similar photos.",
                            "We pick a likely keeper using sharpness, faces, and resolution.",
                            "You approve; others go to the Trash and can be restored from Run History."
                        ],
                        accessibilitySummary: "How Deduplicate works. We group similar photos, suggest a keeper, and you approve.",
                        onDismiss: { didOnboardDeduplicate = true }
                    )
                }

                destinationCard

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Detection")
                        .font(.headline)
                    Picker("Similarity preset", selection: $preferencesStore.dedupeSimilarityPreset) {
                        ForEach(DedupeSimilarityPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(preferencesStore.dedupeSimilarityPreset.subtitle)
                        .font(.caption)
                        .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)
                    Stepper(value: $preferencesStore.dedupeTimeWindowSeconds, in: 5...600, step: 5) {
                        LabeledContent("Burst window") {
                            Text("\(preferencesStore.dedupeTimeWindowSeconds)s")
                                .monospacedDigit()
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button {
                        startScan()
                    } label: {
                        Label("Start Scan", systemImage: "magnifyingglass")
                            .padding(.horizontal, 4)
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.deduplicateDestinationPath.isEmpty)
                }
            }
            .padding(DesignTokens.Layout.contentPadding)
            .frame(maxWidth: DesignTokens.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Scanning

    private var scanningView: some View {
        DeduplicateStatusView(
            style: .progress,
            title: sessionStore.currentPhase?.title ?? "Scanning",
            message: sessionStore.clusters.isEmpty
                ? nil
                : "Found \(sessionStore.clusters.count) group\(sessionStore.clusters.count == 1 ? "" : "s") so far…",
            detail: sessionStore.phaseTotal > 0
                ? "\(sessionStore.phaseCompleted) of \(sessionStore.phaseTotal)"
                : nil,
            primary: {
                Button("Cancel", role: .destructive) {
                    appState.cancelRun()
                }
            }
        )
    }

    // MARK: - Empty

    private var emptyResultsView: some View {
        DeduplicateStatusView(
            style: .success,
            title: "Nothing to deduplicate",
            message: sessionStore.summary.map { summary in
                "Scanned \(summary.totalCandidatesScanned) file\(summary.totalCandidatesScanned == 1 ? "" : "s") in \(formattedDuration(summary.scanDuration)). No similar groups found."
            },
            primary: {
                Button("Scan Again") {
                    startScan()
                }
                .buttonStyle(.borderedProminent)
            }
        )
    }

    // MARK: - Review

    private var reviewView: some View {
        HSplitView {
            ClusterListPane(
                clusters: sessionStore.clusters,
                decisions: sessionStore.decisions,
                focusedClusterID: $focusedClusterID,
                focusedMemberPath: $focusedMemberPath,
                thumbnailLoader: thumbnailLoader
            )
            .frame(minWidth: 280, idealWidth: 360, maxWidth: 460)

            ClusterDetailPane(
                cluster: focusedCluster,
                focusedMemberPath: $focusedMemberPath,
                sessionStore: sessionStore,
                thumbnailLoader: thumbnailLoader
            )
            .frame(minWidth: 480)
        }
        .safeAreaInset(edge: .bottom) {
            commitFooter
        }
        .onAppear { ensureInitialFocus() }
        .onChange(of: sessionStore.clusters.map(\.id)) { _ in ensureInitialFocus() }
    }

    private var commitFooter: some View {
        // Single source of truth: ask the session store for the actual
        // deletion plan the executor would build, so the count + byte
        // total here include pair-expanded partners (e.g. Live Photo
        // MOV halves, RAW partners). Previously these only counted
        // direct cluster-member Delete decisions and could understate
        // both the file count and the recovered bytes.
        let plan = sessionStore.currentDeletionPlan()
        let toDelete = plan.count
        let bytes = plan.totalBytes
        let hardDelete = isHardDeleteSelected
        return HStack(spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.commitFooterTitle(fileCount: toDelete, hardDelete: hardDelete))
                    .font(.subheadline.weight(.semibold))
                Text(Self.commitFooterDetail(byteCount: bytes, hardDelete: hardDelete))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if preferencesStore.dedupeAllowHardDelete {
                Menu {
                    Toggle("Permanently delete (skip Trash)", isOn: $hardDeleteForThisCommit)
                } label: {
                    Label("Options", systemImage: "ellipsis.circle")
                        .accessibilityLabel("Commit options")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Commit options, including whether selected files move to Trash or are permanently deleted")
            }
            Button("Accept All Suggestions") {
                sessionStore.acceptAllSuggestions()
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .accessibilityHint("Marks every cluster's suggested keeper as keep and the rest as delete")
            Button("Commit", role: .destructive) {
                showingCommitConfirmation = true
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(toDelete == 0 || sessionStore.status == .committing)
            .accessibilityHint(hardDelete
                ? "Permanently deletes the selected files after confirmation"
                : "Moves the selected files to the Trash after confirmation")
        }
        .padding(DesignTokens.Spacing.md)
        .background(.ultraThinMaterial)
        .confirmationDialog(
            hardDelete
                ? "Permanently delete \(toDelete) file\(toDelete == 1 ? "" : "s")?"
                : "Move \(toDelete) file\(toDelete == 1 ? "" : "s") to Trash?",
            isPresented: $showingCommitConfirmation
        ) {
            Button(hardDelete ? "Permanently Delete" : "Move to Trash", role: .destructive) {
                sessionStore.decisions = DedupeDecisions(
                    byPath: sessionStore.decisions.byPath,
                    hardDelete: hardDelete
                )
                appState.commitDeduplicateDecisions()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(hardDelete
                ? "Files will be unlinked from disk immediately and cannot be recovered."
                : "Files will move to the macOS Trash. The dedupe receipt in Run History can revert this.")
        }
    }

    // MARK: - Completed

    private var completedView: some View {
        let copy = Self.completedStatusCopy(for: sessionStore.commitSummary)
        return DeduplicateStatusView(
            style: .success,
            title: "Deduplicate complete",
            message: copy.message,
            warning: copy.warning,
            primary: {
                Button("Close") {
                    resetDeduplicate()
                }
                .buttonStyle(.borderedProminent)
            },
            secondary: {
                Button("Scan Again") {
                    startScan()
                }
            }
        )
    }

    /// In-flight Run-History revert. Distinct from `scanningView` so the
    /// copy can say "Restoring …" instead of "Scanning". The empty
    /// cluster list intentionally never appears here — revert doesn't
    /// produce clusters.
    private var revertingView: some View {
        DeduplicateStatusView<EmptyView, EmptyView>(
            style: .progress,
            title: "Restoring files from Trash…",
            detail: sessionStore.phaseTotal > 0
                ? "\(sessionStore.phaseCompleted) of \(sessionStore.phaseTotal)"
                : nil
        )
    }

    /// Run-History revert finished. Distinct from `completedView` —
    /// dedupe revert restores files, it does not delete them, so the
    /// copy must not read "Removed N · reclaimed N MB".
    private var revertedView: some View {
        let copy = Self.revertedStatusCopy(for: sessionStore.commitSummary)
        return DeduplicateStatusView(
            style: .restored,
            title: "Files restored from Trash",
            message: copy.message,
            warning: copy.warning,
            primary: {
                Button("Done") {
                    resetDeduplicate()
                }
                .buttonStyle(.borderedProminent)
            }
        )
    }

    private func failureView(message: String) -> some View {
        DeduplicateStatusView(
            style: .warning,
            title: "Deduplicate failed",
            message: message,
            primary: {
                Button("Try Again") {
                    resetDeduplicate()
                }
                .buttonStyle(.borderedProminent)
            }
        )
    }

    // MARK: - Helpers

    private var focusedCluster: DuplicateCluster? {
        guard let id = focusedClusterID else { return nil }
        return sessionStore.clusters.first { $0.id == id }
    }

    private func ensureInitialFocus() {
        if focusedClusterID == nil, let first = sessionStore.clusters.first {
            focusedClusterID = first.id
            focusedMemberPath = first.members.first?.path
        }
    }

    private var isHardDeleteSelected: Bool {
        preferencesStore.dedupeAllowHardDelete && hardDeleteForThisCommit
    }

    private func startScan() {
        hardDeleteForThisCommit = false
        didOnboardDeduplicate = true
        appState.startDeduplicateScan()
    }

    private func resetDeduplicate() {
        hardDeleteForThisCommit = false
        appState.resetDeduplicate()
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "\(Int(seconds))s"
    }

    private var byteCountFormatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }
}

struct DeduplicateStatusCopy: Equatable {
    var message: String?
    var warning: String?
}

extension DeduplicateView {
    static func commitFooterTitle(fileCount: Int, hardDelete: Bool) -> String {
        "\(fileCount) file\(fileCount == 1 ? "" : "s") will be \(hardDelete ? "permanently deleted" : "moved to Trash")"
    }

    static func commitFooterDetail(byteCount: Int64, hardDelete: Bool) -> String {
        let formattedBytes = statusByteCountFormatter.string(fromByteCount: byteCount)
        return hardDelete
            ? "≈ \(formattedBytes) will be permanently removed"
            : "≈ \(formattedBytes) recoverable"
    }

    static func completedStatusCopy(for summary: DeduplicateCommitSummary?) -> DeduplicateStatusCopy {
        guard let summary else {
            return DeduplicateStatusCopy(message: nil, warning: nil)
        }

        return DeduplicateStatusCopy(
            message: "Removed \(summary.deletedCount) file\(summary.deletedCount == 1 ? "" : "s") · reclaimed \(statusByteCountFormatter.string(fromByteCount: summary.bytesReclaimed))",
            warning: summary.failedCount > 0
                ? "\(summary.failedCount) item\(summary.failedCount == 1 ? "" : "s") failed — see Run History for details."
                : nil
        )
    }

    static func revertedStatusCopy(for summary: DeduplicateCommitSummary?) -> DeduplicateStatusCopy {
        guard let summary else {
            return DeduplicateStatusCopy(message: nil, warning: nil)
        }

        return DeduplicateStatusCopy(
            message: "Restored \(summary.deletedCount) file\(summary.deletedCount == 1 ? "" : "s") · \(statusByteCountFormatter.string(fromByteCount: summary.bytesReclaimed)) returned to the destination",
            warning: summary.failedCount > 0
                ? "\(summary.failedCount) item\(summary.failedCount == 1 ? "" : "s") could not be restored — see Run History for details."
                : nil
        )
    }

    private static var statusByteCountFormatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }
}

/// Content of the Deduplicate destination card. Hosted twice inside a
/// `ViewThatFits` (horizontal vs vertical) so the layout adapts to a
/// narrow main column. The `Reveal` and `Use Organize Destination`
/// buttons appear only when a dedicated dedupe folder is set; otherwise
/// the card just shows the fallback (Organize destination) and the
/// `Choose Folder…` action.
private struct DeduplicateDestinationCardContent: View {
    @ObservedObject var appState: AppState
    let isVertical: Bool

    var body: some View {
        if isVertical {
            VStack(alignment: .leading, spacing: 12) {
                pathView
                actionRow
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                pathView
                Spacer(minLength: 12)
                actionRow
            }
        }
    }

    private var pathView: some View {
        PathValueView(
            title: "Scan Folder",
            value: appState.deduplicateDestinationPath,
            helper: appState.deduplicateDestinationHelper
        )
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button("Choose Folder…") {
                Task { await appState.chooseDeduplicateDestinationFolder() }
            }
            .accessibilityHint("Opens a folder picker for Deduplicate scans")

            if appState.hasDedicatedDeduplicateDestinationPath {
                Menu {
                    Button("Reveal in Finder") {
                        appState.revealDeduplicateDestinationInFinder()
                    }
                    Button("Use Organize Destination") {
                        appState.clearDeduplicateDestinationFolder()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("More destination actions")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }
}

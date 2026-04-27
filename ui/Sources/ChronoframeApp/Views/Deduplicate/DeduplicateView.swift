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
            case .failed(let message):
                failureView(message: message)
            }
        }
        .navigationTitle("Deduplicate")
        .onDisappear { thumbnailLoader.cancelAll() }
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
                VStack(alignment: .leading, spacing: 8) {
                    Text("Deduplicate")
                        .font(DesignTokens.Typography.title)
                    Text("Find groups of nearly-identical photos in your destination, pick the keeper, and prune the rest. Suggestions are based on sharpness, faces, and resolution. Files move to the Trash so you can recover them.")
                        .font(DesignTokens.Typography.subtitle)
                        .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)
                }

                destinationCard

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Detection")
                        .font(.headline)
                    Picker("", selection: $preferencesStore.dedupeSimilarityPreset) {
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
                        appState.startDeduplicateScan()
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
        VStack(spacing: DesignTokens.Spacing.lg) {
            ProgressView()
                .controlSize(.large)
            VStack(spacing: 6) {
                Text(sessionStore.currentPhase?.title ?? "Scanning")
                    .font(.headline)
                if sessionStore.phaseTotal > 0 {
                    Text("\(sessionStore.phaseCompleted) of \(sessionStore.phaseTotal)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if !sessionStore.clusters.isEmpty {
                Text("Found \(sessionStore.clusters.count) groups so far…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Cancel", role: .destructive) {
                appState.cancelRun()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty

    private var emptyResultsView: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 48))
                .foregroundStyle(DesignTokens.ColorSystem.statusSuccess)
            Text("Nothing to deduplicate")
                .font(.headline)
            if let summary = sessionStore.summary {
                Text("Scanned \(summary.totalCandidatesScanned) photos in \(formattedDuration(summary.scanDuration)). No similar groups found.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Button("Scan Again") {
                appState.startDeduplicateScan()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
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
        return HStack(spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(toDelete) file\(toDelete == 1 ? "" : "s") will be \(hardDeleteForThisCommit ? "deleted" : "moved to Trash")")
                    .font(.subheadline.weight(.semibold))
                Text("≈ \(byteCountFormatter.string(fromByteCount: bytes)) recoverable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if preferencesStore.dedupeAllowHardDelete {
                Toggle("Hard delete", isOn: $hardDeleteForThisCommit)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            Button("Accept All Suggestions") {
                sessionStore.acceptAllSuggestions()
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("Commit", role: .destructive) {
                showingCommitConfirmation = true
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(toDelete == 0 || sessionStore.status == .committing)
        }
        .padding(DesignTokens.Spacing.md)
        .background(.ultraThinMaterial)
        .confirmationDialog(
            hardDeleteForThisCommit ? "Hard-delete \(toDelete) files?" : "Move \(toDelete) files to Trash?",
            isPresented: $showingCommitConfirmation
        ) {
            Button(hardDeleteForThisCommit ? "Hard Delete" : "Move to Trash", role: .destructive) {
                sessionStore.decisions = DedupeDecisions(
                    byPath: sessionStore.decisions.byPath,
                    hardDelete: hardDeleteForThisCommit
                )
                appState.commitDeduplicateDecisions()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(hardDeleteForThisCommit
                ? "Files will be unlinked from disk immediately and cannot be recovered."
                : "Files will move to the macOS Trash. The dedupe receipt in Run History can revert this.")
        }
    }

    // MARK: - Completed

    private var completedView: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(DesignTokens.ColorSystem.statusSuccess)
            Text("Deduplicate complete")
                .font(.headline)
            if let summary = sessionStore.commitSummary {
                Text("Removed \(summary.deletedCount) photos · reclaimed \(byteCountFormatter.string(fromByteCount: summary.bytesReclaimed))")
                    .foregroundStyle(.secondary)
                if summary.failedCount > 0 {
                    Text("\(summary.failedCount) item\(summary.failedCount == 1 ? "" : "s") failed — see Run History for details.")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.ColorSystem.statusDanger)
                }
            }
            HStack {
                Button("Scan Again") {
                    appState.startDeduplicateScan()
                }
                Button("Close") {
                    appState.resetDeduplicate()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func failureView(message: String) -> some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(DesignTokens.ColorSystem.statusDanger)
            Text("Deduplicate failed")
                .font(.headline)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Button("Try Again") {
                appState.resetDeduplicate()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
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
                Button("Reveal") {
                    appState.revealDeduplicateDestinationInFinder()
                }
                .accessibilityHint("Reveals the Deduplicate folder in Finder")

                Button("Use Organize Destination") {
                    appState.clearDeduplicateDestinationFolder()
                }
                .accessibilityHint("Clears the Deduplicate folder so scans use the Organize destination")
            }
        }
    }
}

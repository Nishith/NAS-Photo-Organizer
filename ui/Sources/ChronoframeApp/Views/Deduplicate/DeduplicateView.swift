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
    @State private var showingCommitReviewedConfirmation = false
    @State private var showingRapidTriage = false
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
        .onDisappear { thumbnailLoader.purgeCache() }
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
                            "We pick one likely keeper using sharpness, faces, file size, and resolution.",
                            "You approve; others go to the Trash and can be restored from Run History."
                        ],
                        accessibilitySummary: "How Deduplicate works. We group similar photos, suggest a keeper, and you approve.",
                        onDismiss: { didOnboardDeduplicate = true }
                    )
                }

                destinationCard

                pausedReviewSection

                deduplicateRunHistorySection

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

    @ViewBuilder
    private var deduplicateRunHistorySection: some View {
        if !sessionStore.runHistory.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recent Deduplicate Folders")
                        .font(.headline)
                    Spacer()
                }

                VStack(spacing: 8) {
                    ForEach(sessionStore.runHistory.prefix(5)) { record in
                        DeduplicateRunHistoryRow(record: record) {
                            appState.useDeduplicateHistoryFolder(record)
                        }
                    }
                }
            }
            .accessibilityIdentifier("dedupeFolderHistorySection")
        }
    }

    @ViewBuilder
    private var pausedReviewSection: some View {
        if sessionStore.hasPausedReview {
            let canResume = canResumePausedReview
            PausedDeduplicateReviewCard(
                groupCount: sessionStore.clusters.count,
                fileCount: sessionStore.pendingDeleteCount,
                recoverableBytes: sessionStore.totalRecoverableBytes,
                settingsChanged: !canResume,
                resume: resumePausedReview,
                discard: resetDeduplicate
            )
            .accessibilityIdentifier("dedupePausedScanSection")
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
            },
            secondary: {
                Button("Change Folder") {
                    resetDeduplicate()
                }
                .accessibilityIdentifier("dedupeChangeFolderButton")
            }
        )
    }

    // MARK: - Review

    private var reviewView: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                reviewBody(for: geometry.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                commitFooter
            }
        }
        .onAppear { ensureInitialFocus() }
        .onChange(of: sessionStore.clusters.map(\.id)) { _ in ensureInitialFocus() }
    }

    @ViewBuilder
    private func reviewBody(for availableSize: CGSize) -> some View {
        switch DeduplicateReviewLayout.mode(forWidth: availableSize.width) {
        case .wide:
            HSplitView {
                reviewClusterList
                    .frame(
                        minWidth: DesignTokens.DeduplicateLayout.clusterListMinWidth,
                        idealWidth: DesignTokens.DeduplicateLayout.clusterListIdealWidth,
                        maxWidth: DesignTokens.DeduplicateLayout.clusterListMaxWidth
                    )

                reviewClusterDetail
                    .frame(minWidth: DesignTokens.DeduplicateLayout.detailMinWidth)
            }
        case .compact:
            VStack(spacing: 0) {
                reviewClusterList
                    .frame(height: DeduplicateReviewLayout.compactClusterListHeight(forAvailableHeight: availableSize.height))
                Divider()
                reviewClusterDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minHeight: DesignTokens.DeduplicateLayout.compactPreviewMinHeight)
            }
        }
    }

    private var reviewClusterList: some View {
        ClusterListPane(
            clusters: sessionStore.clusters,
            decisions: sessionStore.decisions,
            approvedClusterIDs: sessionStore.approvedClusterIDs,
            deletionPlan: sessionStore.currentDeletionPlan(),
            focusedClusterID: $focusedClusterID,
            focusedMemberPath: $focusedMemberPath,
            thumbnailLoader: thumbnailLoader,
            onKeepAll: { sessionStore.keepAllInCluster($0) },
            onAcceptSuggestion: { sessionStore.acceptSuggestionsForCluster($0) },
            onDeleteAll: { sessionStore.deleteAllInCluster($0) }
        )
    }

    private var reviewClusterDetail: some View {
        ClusterDetailPane(
            cluster: focusedCluster,
            focusedMemberPath: $focusedMemberPath,
            sessionStore: sessionStore,
            thumbnailLoader: thumbnailLoader,
            onAcceptAndAdvance: advanceToNextCluster
        )
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
        let hardDelete = false
        return ViewThatFits(in: .horizontal) {
            commitFooterWide(toDelete: toDelete, bytes: bytes, hardDelete: hardDelete)
            commitFooterMedium(toDelete: toDelete, bytes: bytes, hardDelete: hardDelete)
            commitFooterCompact(toDelete: toDelete, bytes: bytes, hardDelete: hardDelete)
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dedupeCommitFooter")
        .confirmationDialog(
            "Move \(toDelete) file\(toDelete == 1 ? "" : "s") to Trash?",
            isPresented: $showingCommitConfirmation
        ) {
            Button("Move to Trash", role: .destructive) {
                sessionStore.decisions = DedupeDecisions(
                    byPath: sessionStore.decisions.byPath
                )
                appState.commitDeduplicateDecisions()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Files will move to the macOS Trash. The dedupe receipt in Run History can revert this.")
        }
        .confirmationDialog(
            reviewedCommitDialogTitle,
            isPresented: $showingCommitReviewedConfirmation
        ) {
            Button("Move to Trash", role: .destructive) {
                appState.commitReviewedDeduplicateDecisions()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only groups you have fully reviewed will be affected. Unreviewed groups stay untouched. The dedupe receipt in Run History can revert this.")
        }
    }

    private var reviewedCommitDialogTitle: String {
        let plan = sessionStore.reviewedDeletionPlan()
        let count = plan.count
        let reviewed = sessionStore.reviewedClusters.count
        if count == 0 {
            return "No deletions in reviewed groups"
        }
        return "Move \(count) file\(count == 1 ? "" : "s") from \(reviewed) reviewed group\(reviewed == 1 ? "" : "s") to Trash?"
    }

    private func commitFooterWide(toDelete: Int, bytes: Int64, hardDelete: Bool) -> some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            commitFooterStatus(toDelete: toDelete, bytes: bytes, hardDelete: hardDelete)
            Spacer()
            commitFooterButtons(toDelete: toDelete, density: .full)
        }
    }

    private func commitFooterMedium(toDelete: Int, bytes: Int64, hardDelete: Bool) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            commitFooterStatus(toDelete: toDelete, bytes: bytes, hardDelete: hardDelete)
            HStack {
                Spacer(minLength: 0)
                commitFooterButtons(toDelete: toDelete, density: .full)
            }
        }
    }

    private func commitFooterCompact(toDelete: Int, bytes: Int64, hardDelete: Bool) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            commitFooterStatus(toDelete: toDelete, bytes: bytes, hardDelete: hardDelete)
            HStack(spacing: DesignTokens.Spacing.sm) {
                Spacer(minLength: 0)
                commitFooterButtons(toDelete: toDelete, density: .compact)
            }
        }
    }

    @ViewBuilder
    private func commitFooterStatus(toDelete: Int, bytes: Int64, hardDelete: Bool) -> some View {
        let reviewedCount = sessionStore.reviewedClusters.count
        let suggestedCount = max(0, sessionStore.clusters.count - reviewedCount)
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.commitFooterTitle(fileCount: toDelete, hardDelete: hardDelete))
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Text(Self.commitFooterDetail(byteCount: bytes, hardDelete: hardDelete))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text("\(reviewedCount) group\(reviewedCount == 1 ? "" : "s") reviewed · \(suggestedCount) still suggested")
                .font(.caption2)
                .foregroundStyle(suggestedCount > 0 ? DesignTokens.ColorSystem.statusWarning : DesignTokens.ColorSystem.statusSuccess)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func commitFooterButtons(
        toDelete: Int,
        density: CommitFooterButtonDensity
    ) -> some View {
        let highCount = sessionStore.triageBuckets[.high]?.count ?? 0
        switch density {
        case .full:
            VStack(alignment: .trailing, spacing: DesignTokens.Spacing.xs) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    commitFooterSecondaryButtons(highCount: highCount, density: density)
                }
                .fixedSize(horizontal: true, vertical: false)

                HStack(spacing: DesignTokens.Spacing.sm) {
                    commitFooterPrimaryButtons(toDelete: toDelete, density: density)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .fixedSize(horizontal: true, vertical: false)
        case .compact:
            VStack(alignment: .trailing, spacing: DesignTokens.Spacing.xs) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    commitFooterSecondaryButtons(highCount: highCount, density: density)
                }
                .fixedSize(horizontal: true, vertical: false)

                HStack(spacing: DesignTokens.Spacing.xs) {
                    commitFooterPrimaryButtons(toDelete: toDelete, density: density)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    @ViewBuilder
    private func commitFooterSecondaryButtons(
        highCount: Int,
        density: CommitFooterButtonDensity
    ) -> some View {
        Menu {
            Button("Change Folder") {
                abandonReview()
            }
            .accessibilityIdentifier("dedupeReviewChangeFolderButton")

            Button("Adjust Settings") {
                pauseReviewAndOpenSettings()
            }
            .accessibilityIdentifier("dedupeReviewSettingsButton")

            Divider()

            Button("Quick Review") {
                showingRapidTriage = true
            }
            .accessibilityIdentifier("dedupeRapidTriageButton")

            if highCount > 0 {
                Button("Auto-Accept Safe (\(highCount))") {
                    sessionStore.acceptAllHighConfidence()
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .accessibilityLabel("Accept High-Confidence Clusters")
                .accessibilityIdentifier("dedupeAcceptHighConfidenceButton")
                .accessibilityHint("Accepts suggestions for all high-confidence clusters")
            }

            let reviewedCount = sessionStore.reviewedClusters.count
            if reviewedCount > 0 {
                Divider()
                Button("Move Reviewed to Trash (\(reviewedCount) group\(reviewedCount == 1 ? "" : "s"))") {
                    showingCommitReviewedConfirmation = true
                }
                .accessibilityIdentifier("dedupeCommitReviewedButton")
            }
        } label: {
            Label("Options", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("dedupeReviewActionsMenu")
        .sheet(isPresented: $showingRapidTriage) {
            let reviewClusters = sessionStore.clusters.filter {
                let level = $0.annotation?.confidence ?? .medium
                return level == .medium || level == .low
            }
            RapidTriageView(
                sessionStore: sessionStore,
                thumbnailLoader: thumbnailLoader,
                clustersToReview: reviewClusters
            )
        }
    }

    @ViewBuilder
    private func commitFooterPrimaryButtons(
        toDelete: Int,
        density: CommitFooterButtonDensity
    ) -> some View {
        Button(density.acceptAllTitle) {
            sessionStore.acceptAllSuggestions()
        }
        .keyboardShortcut(.return, modifiers: [.command, .shift])
        .buttonStyle(.bordered)
        .fixedSize()
        .accessibilityLabel("Accept All Suggestions")
        .accessibilityIdentifier("dedupeAcceptAllSuggestionsButton")
        .accessibilityHint("Marks every cluster's suggested keeper as keep and the rest as delete")

        Spacer().frame(width: DesignTokens.Spacing.lg)

        Button(density.commitTitle(fileCount: toDelete), role: .destructive) {
            showingCommitConfirmation = true
        }
        .keyboardShortcut(.return, modifiers: .command)
        .buttonStyle(.borderedProminent)
        .fixedSize()
        .disabled(toDelete == 0 || sessionStore.status == .committing)
        .accessibilityIdentifier("dedupeCommitButton")
        .accessibilityHint("Moves the selected files to the Trash after confirmation")
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
        guard let id = focusedClusterID else { return sessionStore.clusters.first }
        return sessionStore.clusters.first { $0.id == id } ?? sessionStore.clusters.first
    }

    private func ensureInitialFocus() {
        if focusedClusterID == nil, let first = sessionStore.clusters.first {
            focusedClusterID = first.id
            focusedMemberPath = first.members.first?.path
        }
    }

    private func advanceToNextCluster() {
        let clusters = sessionStore.clusters
        guard let currentID = focusedClusterID,
              let currentIndex = clusters.firstIndex(where: { $0.id == currentID }),
              currentIndex + 1 < clusters.count else { return }
        let next = clusters[currentIndex + 1]
        focusedClusterID = next.id
        focusedMemberPath = next.members.first?.path
    }

    private var currentDeduplicateConfiguration: DeduplicateConfiguration? {
        let destination = appState.deduplicateDestinationPath
        guard !destination.isEmpty else { return nil }
        return preferencesStore.makeDeduplicateConfiguration(destinationPath: destination)
    }

    private var canResumePausedReview: Bool {
        guard let configuration = currentDeduplicateConfiguration else { return false }
        return sessionStore.pausedReviewMatches(configuration: configuration)
    }

    private func startScan() {
        didOnboardDeduplicate = true
        appState.startDeduplicateScan()
    }

    private func resetDeduplicate() {
        appState.resetDeduplicate()
    }

    private func abandonReview() {
        focusedClusterID = nil
        focusedMemberPath = nil
        resetDeduplicate()
    }

    private func pauseReviewAndOpenSettings() {
        sessionStore.pauseReview()
        appState.openSettingsWindow()
    }

    private func resumePausedReview() {
        guard canResumePausedReview else { return }
        sessionStore.resumePausedReview()
        ensureInitialFocus()
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
        "\(fileCount) file\(fileCount == 1 ? "" : "s") will be moved to Trash"
    }

    static func commitFooterDetail(byteCount: Int64, hardDelete: Bool) -> String {
        let formattedBytes = statusByteCountFormatter.string(fromByteCount: byteCount)
        return "≈ \(formattedBytes) recoverable"
    }

    static func completedStatusCopy(for summary: DeduplicateCommitSummary?) -> DeduplicateStatusCopy {
        guard let summary else {
            return DeduplicateStatusCopy(message: nil, warning: nil)
        }

        return DeduplicateStatusCopy(
            message: "Moved \(summary.deletedCount) file\(summary.deletedCount == 1 ? "" : "s") to Trash · \(statusByteCountFormatter.string(fromByteCount: summary.bytesReclaimed)) recoverable",
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

enum DeduplicateReviewLayout {
    enum Mode: Equatable {
        case wide
        case compact
    }

    static func mode(forWidth width: CGFloat) -> Mode {
        width >= DesignTokens.DeduplicateLayout.reviewWideBreakpoint ? .wide : .compact
    }

    static func compactClusterListHeight(forAvailableHeight height: CGFloat) -> CGFloat {
        min(
            max(height * 0.32, DesignTokens.DeduplicateLayout.compactClusterListMinHeight),
            DesignTokens.DeduplicateLayout.compactClusterListMaxHeight
        )
    }
}

enum CommitFooterButtonDensity {
    case full
    case compact

    var acceptAllTitle: String {
        switch self {
        case .full: return "Accept All"
        case .compact: return "Accept All"
        }
    }

    var changeFolderTitle: String {
        switch self {
        case .full: return "Change Folder"
        case .compact: return "Folder"
        }
    }

    var settingsTitle: String {
        switch self {
        case .full: return "Adjust Settings"
        case .compact: return "Settings"
        }
    }

    func commitTitle(fileCount: Int) -> String {
        switch self {
        case .full:
            return fileCount > 0 ? "Move \(fileCount) File\(fileCount == 1 ? "" : "s") to Trash" : "Move to Trash"
        case .compact:
            return "Move to Trash"
        }
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

private struct PausedDeduplicateReviewCard: View {
    let groupCount: Int
    let fileCount: Int
    let recoverableBytes: Int64
    let settingsChanged: Bool
    let resume: () -> Void
    let discard: () -> Void

    private static let bytesFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        MeridianSurfaceCard(
            style: .inner,
            tint: settingsChanged ? DesignTokens.ColorSystem.statusWarning : DesignTokens.ColorSystem.accentAction
        ) {
            ViewThatFits(in: .horizontal) {
                horizontalLayout
                verticalLayout
            }
        }
    }

    private var horizontalLayout: some View {
        HStack(alignment: .center, spacing: 12) {
            label
            Spacer(minLength: 16)
            metrics
            actions
        }
    }

    private var verticalLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            label
            HStack(alignment: .center, spacing: 12) {
                metrics
                Spacer(minLength: 8)
                actions
            }
        }
    }

    private var label: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: settingsChanged ? "exclamationmark.triangle" : "rectangle.stack")
                .foregroundStyle(settingsChanged ? DesignTokens.ColorSystem.statusWarning : DesignTokens.ColorSystem.accentAction)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text("Paused Scan")
                    .font(.subheadline.weight(.semibold))
                Text(settingsChanged ? "Settings changed since this scan." : "Ready to review.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var metrics: some View {
        HStack(spacing: 16) {
            metric("\(groupCount)", label: groupCount == 1 ? "group" : "groups")
            metric("\(fileCount)", label: "selected")
            metric(Self.bytesFormatter.string(fromByteCount: recoverableBytes), label: "recoverable")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Discard", role: .destructive) {
                discard()
            }
            Button("Return to Scan") {
                resume()
            }
            .buttonStyle(.borderedProminent)
            .disabled(settingsChanged)
            .accessibilityIdentifier("dedupeResumePausedScanButton")
        }
        .fixedSize()
    }

    private func metric(_ value: String, label: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DeduplicateRunHistoryRow: View {
    let record: DeduplicateFolderHistoryRecord
    let useFolder: () -> Void

    private static let bytesFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        MeridianSurfaceCard(style: .inner, tint: DesignTokens.ColorSystem.accentAction) {
            ViewThatFits(in: .horizontal) {
                horizontalLayout
                verticalLayout
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var horizontalLayout: some View {
        HStack(alignment: .center, spacing: 12) {
            folderLabel
            Spacer(minLength: 16)
            metrics
            useFolderButton
        }
    }

    private var verticalLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            folderLabel
            HStack {
                metrics
                Spacer(minLength: 8)
                useFolderButton
            }
        }
    }

    private var folderLabel: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(DesignTokens.ColorSystem.accentAction)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(URL(fileURLWithPath: record.folderPath).lastPathComponent)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(record.folderPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Last run \(Self.dateFormatter.string(from: record.lastRunAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var metrics: some View {
        HStack(spacing: 16) {
            metric("\(record.lastDeletedCount)", label: "files removed")
            metric(Self.bytesFormatter.string(fromByteCount: record.lastBytesReclaimed), label: "saved")
            if record.runCount > 1 {
                metric("\(record.runCount)", label: "runs")
            }
            if record.lastFailedCount > 0 {
                metric("\(record.lastFailedCount)", label: "failed")
                    .foregroundStyle(DesignTokens.ColorSystem.statusDanger)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var useFolderButton: some View {
        Button {
            useFolder()
        } label: {
            Label("Use", systemImage: "arrow.turn.down.right")
        }
        .controlSize(.small)
        .accessibilityIdentifier("dedupeUseHistoryFolderButton")
    }

    private func metric(_ value: String, label: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

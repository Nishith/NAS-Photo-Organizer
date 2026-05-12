#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import AppKit
import ImageIO
import SwiftUI

/// Right pane: large preview of the focused photo plus the cluster member
/// strip. Each strip thumbnail shows a Keep/Delete badge and exposes
/// keyboard-friendly toggles. The "Accept suggestion" button applies the
/// scanner's suggested keeper for the current cluster.
struct ClusterDetailPane: View {
    let cluster: DuplicateCluster?
    @Binding var focusedMemberPath: String?
    @ObservedObject var sessionStore: DeduplicateSessionStore
    @ObservedObject var thumbnailLoader: DedupeThumbnailLoader
    var onAcceptAndAdvance: (() -> Void)? = nil
    @State private var thumbnailStripHeight = DeduplicateDetailPreviewLayout.defaultThumbnailStripHeight
    @State private var dragStartThumbnailStripHeight: CGFloat?
    @State private var showingReasonDetail = false
    @State private var showingComparisonOverlay = false

    var body: some View {
        Group {
            if let cluster {
                VStack(spacing: 0) {
                    detailContent(for: cluster)
                }
                .background {
                    VStack {
                        Button("Previous") { navigateMember(by: -1, in: cluster) }
                            .keyboardShortcut(.leftArrow, modifiers: [])
                        Button("Next") { navigateMember(by: 1, in: cluster) }
                            .keyboardShortcut(.rightArrow, modifiers: [])
                    }
                    .opacity(0)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.on.rectangle.angled")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Select a cluster on the left")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityIdentifier("dedupeReviewDetail")
    }

    @ViewBuilder
    private func detailContent(for cluster: DuplicateCluster) -> some View {
        let focused = focusedMember(in: cluster)

        GeometryReader { geometry in
            let stripHeight = DeduplicateDetailPreviewLayout.clampedThumbnailStripHeight(
                thumbnailStripHeight,
                availableHeight: geometry.size.height
            )
            let previewHeight = max(
                0,
                geometry.size.height - stripHeight - DeduplicateDetailPreviewLayout.resizeHandleHeight
            )
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    warningBanner(for: cluster)
                    detailContentWide(focused: focused, cluster: cluster)
                }
                .frame(height: previewHeight)

                PreviewResizeHandle(
                    dragChanged: { translation in
                        resizeThumbnailStrip(by: translation, availableHeight: geometry.size.height)
                    },
                    dragEnded: { translation in
                        finishResizingThumbnailStrip(by: translation, availableHeight: geometry.size.height)
                    },
                    adjust: { delta in
                        thumbnailStripHeight = DeduplicateDetailPreviewLayout.clampedThumbnailStripHeight(
                            stripHeight + delta,
                            availableHeight: geometry.size.height
                        )
                    }
                )

                memberStripArea(cluster: cluster, height: stripHeight)
            }
        }
    }

    private func memberStripArea(cluster: DuplicateCluster, height: CGFloat) -> some View {
        let thumbnailSize = DeduplicateDetailPreviewLayout.thumbnailSize(forStripHeight: height)
        return ViewThatFits(in: .horizontal) {
            memberStripWide(cluster: cluster, thumbnailSize: thumbnailSize)
            memberStripCompact(cluster: cluster, thumbnailSize: thumbnailSize)
        }
        .padding(.vertical, DesignTokens.Spacing.sm)
        .frame(height: height)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dedupeMemberStrip")
    }

    private func memberStripWide(cluster: DuplicateCluster, thumbnailSize: CGFloat) -> some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            memberThumbnailStrip(cluster: cluster, thumbnailSize: thumbnailSize)
            acceptSuggestionButton(for: cluster)
                .padding(.trailing, DesignTokens.Spacing.md)
        }
    }

    private func memberStripCompact(cluster: DuplicateCluster, thumbnailSize: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: DesignTokens.Spacing.sm) {
            memberThumbnailStrip(cluster: cluster, thumbnailSize: thumbnailSize)
            acceptSuggestionButton(for: cluster)
                .padding(.trailing, DesignTokens.Spacing.md)
        }
    }

    private func memberThumbnailStrip(cluster: DuplicateCluster, thumbnailSize: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 8) {
                ForEach(cluster.members) { member in
                    memberThumb(member: member, cluster: cluster, thumbnailSize: thumbnailSize)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
        }
    }

    private func acceptSuggestionButton(for cluster: DuplicateCluster) -> some View {
        Button("Accept & Next") {
            sessionStore.acceptSuggestionsForCluster(cluster)
            onAcceptAndAdvance?()
        }
        .fixedSize()
        .keyboardShortcut(.return, modifiers: [])
        .accessibilityIdentifier("dedupeAcceptClusterSuggestionButton")
        .accessibilityLabel("Accept suggestion and move to next group")
        .accessibilityHint("Confirms the suggested keep and delete choices for this group, then selects the next group")
    }

    private func detailContentWide(focused: PhotoCandidate?, cluster: DuplicateCluster) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.lg) {
            preview(for: focused)
                .frame(minWidth: 160, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            if let focused {
                metadataPanel(for: focused, cluster: cluster)
                    .frame(width: 200)
            }
        }
        .padding(DesignTokens.Spacing.lg)
    }

    private func preview(for member: PhotoCandidate?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DesignTokens.ColorSystem.panel)
            if let member {
                LargePreviewImage(path: member.path)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func metadataPanel(for member: PhotoCandidate, cluster: DuplicateCluster) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(URL(fileURLWithPath: member.path).lastPathComponent)
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.middle)

            metaRow("Captured", value: dateString(member.captureDate))
            metaRow("Size", value: byteCountFormatter.string(fromByteCount: member.size))
            if let width = member.pixelWidth, let height = member.pixelHeight {
                metaRow("Dimensions", value: "\(width) × \(height)")
            }

            Divider().padding(.vertical, 2)

            qualityRow("Quality", score: member.qualityScore)
            sharpnessRow("Sharpness", score: member.sharpness)
            if let face = member.faceScore {
                faceRow("Face", detected: face > 0.5)
            }
            if member.isRaw {
                Label("RAW", systemImage: "camera.aperture")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let pairedPath = member.pairedPath {
                Label("Paired with \(URL(fileURLWithPath: pairedPath).lastPathComponent)", systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Divider().padding(.vertical, 2)

            decisionControls(for: member, cluster: cluster)

            if let annotation = cluster.annotation {
                Divider().padding(.vertical, 2)
                reasoningSection(annotation: annotation, cluster: cluster)
            }
        }
        .padding(DesignTokens.Spacing.md)
        .background(DesignTokens.ColorSystem.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func metaRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
        }
    }

    private func qualityRow(_ label: String, score: Double) -> some View {
        let (filled, text) = Self.qualityLabel(score)
        return HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    Circle()
                        .fill(i < filled ? DesignTokens.ColorSystem.accentAction : DesignTokens.ColorSystem.hairline)
                        .frame(width: 5, height: 5)
                }
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)
        }
        .help(String(format: "Raw score: %.2f", score))
    }

    private func sharpnessRow(_ label: String, score: Double) -> some View {
        let text = Self.sharpnessLabel(score)
        return HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(text)
                .font(.caption)
                .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)
        }
        .help(String(format: "Raw score: %.2f", score))
    }

    private func faceRow(_ label: String, detected: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Label(detected ? "Detected" : "None", systemImage: detected ? "person.fill" : "person.slash")
                .font(.caption)
                .foregroundStyle(detected ? DesignTokens.ColorSystem.statusSuccess : DesignTokens.ColorSystem.inkMuted)
        }
    }

    static func qualityLabel(_ score: Double) -> (Int, String) {
        switch score {
        case 0.8...: return (5, "Excellent")
        case 0.6..<0.8: return (4, "Good")
        case 0.4..<0.6: return (3, "Fair")
        case 0.2..<0.4: return (2, "Poor")
        default: return (1, "Very poor")
        }
    }

    static func sharpnessLabel(_ score: Double) -> String {
        switch score {
        case 0.5...: return "Sharp"
        case 0.25..<0.5: return "Soft"
        default: return "Motion blur"
        }
    }

    private func decisionControls(for member: PhotoCandidate, cluster: DuplicateCluster) -> some View {
        let current = sessionStore.decisions.byPath[member.path] ?? (isSuggestedKeeper(member, in: cluster) ? .keep : .delete)
        return Picker("Decision", selection: Binding<DedupeDecision>(
            get: { current },
            set: { newValue in sessionStore.setDecision(newValue, forPath: member.path) }
        )) {
            Label("Keep", systemImage: "tray.and.arrow.down")
                .tag(DedupeDecision.keep)
            Label("Delete", systemImage: "trash")
                .tag(DedupeDecision.delete)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private func memberThumb(member: PhotoCandidate, cluster: DuplicateCluster, thumbnailSize: CGFloat) -> some View {
        let decision = sessionStore.decisions.byPath[member.path] ?? (isSuggestedKeeper(member, in: cluster) ? .keep : .delete)
        let isFocused = member.path == focusedMemberPath
        return ZStack(alignment: .bottomTrailing) {
            DedupeThumbnailView(
                path: member.path,
                size: CGSize(width: thumbnailSize, height: thumbnailSize),
                loader: thumbnailLoader
            )
            .opacity(decision == .delete ? 0.55 : 1.0)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isFocused ? DesignTokens.ColorSystem.accentAction : Color.clear, lineWidth: 2)
            )

            Image(systemName: decision == .keep ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(decision == .keep ? DesignTokens.ColorSystem.statusSuccess : DesignTokens.ColorSystem.statusDanger)
                .padding(3)
        }
        .onTapGesture {
            focusedMemberPath = member.path
        }
        .contextMenu {
            Button("Keep") { sessionStore.setDecision(.keep, forPath: member.path) }
            Button("Delete", role: .destructive) { sessionStore.setDecision(.delete, forPath: member.path) }
        }
        .help(URL(fileURLWithPath: member.path).lastPathComponent)
    }

    // MARK: - Warning Banner

    @ViewBuilder
    private func warningBanner(for cluster: DuplicateCluster) -> some View {
        if let annotation = cluster.annotation, !annotation.warnings.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("These photos may be intentionally different")
                        .font(.caption.weight(.semibold))
                    ForEach(Array(annotation.warnings.enumerated()), id: \.offset) { _, warning in
                        Text(MatchReasonFormatter.warningSummary(warning))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(8)
            .background(Color.orange.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.top, DesignTokens.Spacing.sm)
        }
    }

    // MARK: - Reasoning Section

    @ViewBuilder
    private func reasoningSection(annotation: ClusterAnnotation, cluster: DuplicateCluster) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showingReasonDetail.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showingReasonDetail ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text("Why matched")
                        .font(.caption.weight(.medium))
                    Spacer()
                    confidenceBadge(annotation.confidence)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showingReasonDetail {
                VStack(alignment: .leading, spacing: 4) {
                    Text(MatchReasonFormatter.summary(annotation.matchReason))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let keeperReason = annotation.keeperReason {
                        Text(MatchReasonFormatter.keeperSummary(keeperReason))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        if cluster.members.count >= 2 {
            Button {
                showingComparisonOverlay = true
            } label: {
                Label("Compare", systemImage: "rectangle.on.rectangle")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("c", modifiers: [])
            .sheet(isPresented: $showingComparisonOverlay) {
                if let keeper = cluster.members.first(where: { isSuggestedKeeper($0, in: cluster) }),
                   let other = cluster.members.first(where: { !isSuggestedKeeper($0, in: cluster) }) {
                    ComparisonOverlayView(leftPath: keeper.path, rightPath: other.path)
                }
            }
        }
    }

    private func confidenceBadge(_ level: ConfidenceLevel) -> some View {
        Text(MatchReasonFormatter.confidenceLabel(level))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(confidenceColor(level).opacity(0.15))
            .foregroundStyle(confidenceColor(level))
            .clipShape(Capsule())
    }

    private func confidenceColor(_ level: ConfidenceLevel) -> Color {
        switch level {
        case .high: return .green
        case .medium: return .yellow
        case .low: return .orange
        }
    }

    private func focusedMember(in cluster: DuplicateCluster) -> PhotoCandidate? {
        if let path = focusedMemberPath, let match = cluster.members.first(where: { $0.path == path }) {
            return match
        }
        return cluster.members.first
    }

    private func navigateMember(by delta: Int, in cluster: DuplicateCluster) {
        let members = cluster.members
        guard !members.isEmpty else { return }
        let currentIndex = members.firstIndex(where: { $0.path == focusedMemberPath }) ?? 0
        let nextIndex = (currentIndex + delta + members.count) % members.count
        focusedMemberPath = members[nextIndex].path
    }

    private func isSuggestedKeeper(_ member: PhotoCandidate, in cluster: DuplicateCluster) -> Bool {
        cluster.suggestedKeeperIDs.prefix(1).contains(member.id)
    }

    private func resizeThumbnailStrip(by translation: CGFloat, availableHeight: CGFloat) {
        let currentHeight = DeduplicateDetailPreviewLayout.clampedThumbnailStripHeight(
            thumbnailStripHeight,
            availableHeight: availableHeight
        )
        let startHeight = dragStartThumbnailStripHeight ?? currentHeight
        dragStartThumbnailStripHeight = startHeight
        thumbnailStripHeight = DeduplicateDetailPreviewLayout.clampedThumbnailStripHeight(
            startHeight - translation,
            availableHeight: availableHeight
        )
    }

    private func finishResizingThumbnailStrip(by translation: CGFloat, availableHeight: CGFloat) {
        resizeThumbnailStrip(by: translation, availableHeight: availableHeight)
        dragStartThumbnailStripHeight = nil
    }

    private func dateString(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var byteCountFormatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }
}

enum DeduplicateDetailPreviewLayout {
    static let defaultThumbnailStripHeight: CGFloat = 126
    static let minimumThumbnailStripHeight: CGFloat = 112
    static let maximumThumbnailStripHeight: CGFloat = 320
    static let minimumPreviewHeight: CGFloat = 260
    static let resizeHandleHeight: CGFloat = 10
    static let minimumThumbnailSize: CGFloat = 88
    static let maximumThumbnailSize: CGFloat = 240
    private static let thumbnailVerticalChrome: CGFloat = 38

    static func thumbnailStripHeightBounds(forAvailableHeight availableHeight: CGFloat) -> ClosedRange<CGFloat> {
        let usableHeight = max(0, availableHeight - resizeHandleHeight)
        let lowerBound = min(minimumThumbnailStripHeight, usableHeight)
        let previewMinimum = min(minimumPreviewHeight, max(0, usableHeight - lowerBound))
        let upperBound = max(lowerBound, min(maximumThumbnailStripHeight, usableHeight - previewMinimum))
        return lowerBound...upperBound
    }

    static func clampedThumbnailStripHeight(_ height: CGFloat, availableHeight: CGFloat) -> CGFloat {
        let bounds = thumbnailStripHeightBounds(forAvailableHeight: availableHeight)
        return min(max(height, bounds.lowerBound), bounds.upperBound)
    }

    static func thumbnailSize(forStripHeight stripHeight: CGFloat) -> CGFloat {
        min(
            max(stripHeight - thumbnailVerticalChrome, minimumThumbnailSize),
            maximumThumbnailSize
        )
    }
}

private struct PreviewResizeHandle: View {
    let dragChanged: (CGFloat) -> Void
    let dragEnded: (CGFloat) -> Void
    let adjust: (CGFloat) -> Void
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(DesignTokens.ColorSystem.hairline)
                .frame(height: 1)

            Capsule(style: .continuous)
                .fill(isHovering ? DesignTokens.ColorSystem.accentAction : DesignTokens.ColorSystem.hairline.opacity(0.6))
                .frame(width: 44, height: isHovering ? 4 : 3)
        }
        .frame(height: DeduplicateDetailPreviewLayout.resizeHandleHeight)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    dragChanged(value.translation.height)
                }
                .onEnded { value in
                    dragEnded(value.translation.height)
                }
        )
        .onHover { isHovering = $0 }
        .help("Drag to resize the preview and duplicate thumbnails")
        .accessibilityLabel("Resize preview and duplicate thumbnails")
        .accessibilityHint("Drag up to make thumbnails larger, or down to make the preview larger")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                adjust(24)
            case .decrement:
                adjust(-24)
            @unknown default:
                break
            }
        }
    }
}

private struct LargePreviewImage: View {
    let path: String
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if failed {
                Image(systemName: "photo")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: path) {
            image = nil
            failed = false
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            let cgImage = await Self.loadPreviewCGImage(at: path, scale: scale)
            guard !Task.isCancelled else { return }
            guard let cgImage else {
                failed = true
                return
            }
            let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
            image = NSImage(cgImage: cgImage, size: pixelSize)
        }
    }

    private nonisolated static func loadPreviewCGImage(at path: String, scale: CGFloat) async -> CGImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let maxPixelSize = Int(1200 * scale)
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

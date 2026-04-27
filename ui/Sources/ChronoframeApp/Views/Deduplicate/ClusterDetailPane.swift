#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import AppKit
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

    var body: some View {
        if let cluster {
            VStack(spacing: 0) {
                detailContent(for: cluster)
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

    @ViewBuilder
    private func detailContent(for cluster: DuplicateCluster) -> some View {
        let focused = focusedMember(in: cluster)

        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.lg) {
                preview(for: focused)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let focused {
                    metadataPanel(for: focused, cluster: cluster)
                        .frame(width: 240)
                }
            }
            .padding(DesignTokens.Spacing.lg)

            Divider()

            HStack(spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(cluster.members) { member in
                            memberThumb(member: member, cluster: cluster)
                        }
                    }
                    .padding(.horizontal, DesignTokens.Spacing.md)
                }

                Spacer()

                Button("Accept Suggestion") {
                    sessionStore.acceptSuggestionsForCluster(cluster)
                }
                .keyboardShortcut(.return, modifiers: [])
                .padding(.trailing, DesignTokens.Spacing.md)
            }
            .padding(.vertical, DesignTokens.Spacing.sm)
        }
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

            metaRow("Quality", value: String(format: "%.2f", member.qualityScore))
            metaRow("Sharpness", value: String(format: "%.2f", member.sharpness))
            if let face = member.faceScore {
                metaRow("Face score", value: String(format: "%.2f", face))
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

    private func decisionControls(for member: PhotoCandidate, cluster: DuplicateCluster) -> some View {
        let current = sessionStore.decisions.byPath[member.path] ?? (cluster.suggestedKeeperIDs.contains(member.id) ? .keep : .delete)
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

    private func memberThumb(member: PhotoCandidate, cluster: DuplicateCluster) -> some View {
        let decision = sessionStore.decisions.byPath[member.path] ?? (cluster.suggestedKeeperIDs.contains(member.id) ? .keep : .delete)
        let isFocused = member.path == focusedMemberPath
        return ZStack(alignment: .bottomTrailing) {
            DedupeThumbnailView(
                path: member.path,
                size: CGSize(width: 88, height: 88),
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

    private func focusedMember(in cluster: DuplicateCluster) -> PhotoCandidate? {
        if let path = focusedMemberPath, let match = cluster.members.first(where: { $0.path == path }) {
            return match
        }
        return cluster.members.first
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

private struct LargePreviewImage: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: path) {
            image = nil
            let cgImage = await ThumbnailRenderer.cgImage(
                for: URL(fileURLWithPath: path),
                size: CGSize(width: 1200, height: 1200),
                scale: NSScreen.main?.backingScaleFactor ?? 2.0
            )
            guard !Task.isCancelled, let cgImage else { return }
            let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
            image = NSImage(cgImage: cgImage, size: pixelSize)
        }
    }
}

#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import AppKit
import SwiftUI

/// A compact, quiet card that surfaces what Chronoframe is doing right now.
/// During a transfer this shows the current task title ("Copying 30 of 100
/// files…") alongside a live QuickLook thumbnail of the frame most recently
/// placed at its destination — the emotional "a memory found its place" beat.
struct NowCopyingCard: View {
    let model: RunWorkspaceModel

    @State private var thumbnail: NSImage?
    @State private var loadedURL: URL?

    private let thumbnailSide: CGFloat = 56

    var body: some View {
        DarkroomPanel(variant: .inset) {
            HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
                thumbnailView

                VStack(alignment: .leading, spacing: 4) {
                    Text("Now")
                        .font(DesignTokens.Typography.label)
                        .foregroundStyle(DesignTokens.ColorSystem.inkMuted)

                    Text(model.context.currentTaskTitle)
                        .font(DesignTokens.Typography.body.weight(.medium))
                        .foregroundStyle(DesignTokens.ColorSystem.inkPrimary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .contentTransition(.identity)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: DesignTokens.Spacing.sm)

                tonePill
            }
        }
        .task(id: model.context.currentFileURL) {
            await loadThumbnail(for: model.context.currentFileURL)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Now: \(model.context.currentTaskTitle)")
    }

    @ViewBuilder
    private var thumbnailView: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(DesignTokens.ColorSystem.hairline.opacity(0.6))
            .frame(width: thumbnailSide, height: thumbnailSide)
            .overlay {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: thumbnailSide, height: thumbnailSide)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .transition(.opacity)
                        .id(loadedURL)
                } else {
                    Image(systemName: heroSymbol)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(model.heroState.tone.color)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(DesignTokens.ColorSystem.photoEdgeHighlight, lineWidth: 0.5)
            )
            .animation(Motion.instant, value: loadedURL)
    }

    private func loadThumbnail(for url: URL?) async {
        guard let url else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let cgImage = await ThumbnailRenderer.cgImage(
            for: url,
            size: CGSize(width: thumbnailSide, height: thumbnailSide),
            scale: scale
        ) else {
            return
        }
        thumbnail = NSImage(cgImage: cgImage, size: NSSize(width: thumbnailSide, height: thumbnailSide))
        loadedURL = url
    }

    private var tonePill: some View {
        Text(model.heroState.badgeTitle)
            .font(DesignTokens.Typography.label)
            .foregroundStyle(model.heroState.tone.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(model.heroState.tone.color.opacity(0.12))
            )
    }

    private var heroSymbol: String {
        switch model.context.status {
        case .running: return "arrow.triangle.2.circlepath"
        case .finished: return "checkmark.circle.fill"
        case .dryRunFinished: return "eye"
        case .preflighting: return "clock.arrow.circlepath"
        case .cancelled: return "pause.circle"
        case .failed: return "exclamationmark.triangle"
        case .nothingToCopy, .nothingToReorganize: return "checkmark.seal"
        case .reverted: return "arrow.uturn.backward.circle.fill"
        case .revertEmpty: return "tray"
        case .reorganized: return "rectangle.3.offgrid.fill"
        case .idle: return "circle.dashed"
        }
    }
}

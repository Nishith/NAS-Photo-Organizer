#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

/// A compact, quiet card that surfaces what Chronoframe is doing right now.
/// During a transfer this shows the current task title ("Copying IMG_0421.HEIC
/// → 2021/08/14") and an icon placeholder. A per-file URL and QuickLook
/// thumbnail are intentionally not wired yet — the engine does not stream
/// the active file path today, and adding that channel is an engine change
/// (out of scope per the plan's non-goals).
struct NowCopyingCard: View {
    let model: RunWorkspaceModel

    var body: some View {
        DarkroomPanel(variant: .inset) {
            HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
                thumbnail

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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Now: \(model.context.currentTaskTitle)")
    }

    private var thumbnail: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(DesignTokens.ColorSystem.hairline.opacity(0.6))
            .frame(width: 44, height: 44)
            .overlay {
                Image(systemName: heroSymbol)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(model.heroState.tone.color)
            }
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
        case .nothingToCopy: return "checkmark.seal"
        case .idle: return "circle.dashed"
        }
    }
}

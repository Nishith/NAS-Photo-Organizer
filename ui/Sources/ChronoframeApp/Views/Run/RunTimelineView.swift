#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

/// The emotional centerpiece of the Run view: a grid of dots, each one
/// representing a frame (or a small batch of frames) finding its place.
///
/// Data model caveat: the full year×month version envisioned in the plan
/// needs per-(year,month) aggregation streamed from the engine, which does
/// not ship today. Until that data is available, we render a fixed grid
/// proportional to `plannedCount`, lit from `copiedCount`. Visually this
/// already delivers the "frames finding their place" moment; the data
/// binding can be upgraded without rewriting the view.
struct RunTimelineView: View {
    let model: RunWorkspaceModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAnimatedCompletion = false

    private let columnCount = 24
    private let rowCount = 6
    private var dotCount: Int { columnCount * rowCount }

    var body: some View {
        DarkroomPanel(variant: .panel) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Timeline")
                        .font(DesignTokens.Typography.cardTitle)
                        .foregroundStyle(DesignTokens.ColorSystem.inkPrimary)

                    Spacer()

                    Text(progressCaption)
                        .font(DesignTokens.Typography.label)
                        .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                grid

                Text(subtitle)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Run timeline")
        .accessibilityValue(accessibilityValue)
    }

    private var grid: some View {
        let active = activeIndex
        let completed = completedIndex

        return GeometryReader { geo in
            let totalSpacing = CGFloat(columnCount - 1) * 4
            let dotSize = max(6, (geo.size.width - totalSpacing) / CGFloat(columnCount))

            VStack(spacing: 4) {
                ForEach(0..<rowCount, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(0..<columnCount, id: \.self) { column in
                            let index = row * columnCount + column
                            dot(at: index, active: active, completed: completed)
                                .frame(width: dotSize, height: dotSize)
                        }
                    }
                }
            }
        }
        .frame(height: CGFloat(rowCount) * 16 + CGFloat(rowCount - 1) * 4)
    }

    private func dot(at index: Int, active: Int, completed: Int) -> some View {
        let state: DotState
        if hasAnimatedCompletion || model.context.status == .finished {
            state = .complete
        } else if index < completed {
            state = .complete
        } else if index == active && model.context.status == .running {
            state = .active
        } else if index < active {
            state = .active
        } else {
            state = .pending
        }

        return Circle()
            .fill(fill(for: state))
            .overlay {
                if state == .active {
                    Circle()
                        .stroke(DesignTokens.ColorSystem.accentWaypoint.opacity(0.5), lineWidth: 1)
                        .scaleEffect(pulseScale(for: state))
                }
            }
            .motion(Motion.filmic, value: state)
    }

    private func fill(for state: DotState) -> Color {
        switch state {
        case .pending:
            return DesignTokens.ColorSystem.inkMuted.opacity(0.18)
        case .active:
            return DesignTokens.ColorSystem.accentWaypoint
        case .complete:
            return DesignTokens.ColorSystem.statusSuccess
        }
    }

    private func pulseScale(for state: DotState) -> CGFloat {
        state == .active && !reduceMotion ? 1.15 : 1.0
    }

    // MARK: - Data mapping

    private var completedIndex: Int {
        guard model.context.metrics.plannedCount > 0 else { return 0 }
        let ratio = min(1.0, Double(model.context.metrics.copiedCount) / Double(model.context.metrics.plannedCount))
        return Int((Double(dotCount) * ratio).rounded(.down))
    }

    private var activeIndex: Int {
        switch model.context.status {
        case .running:
            return min(completedIndex + 1, dotCount - 1)
        case .finished, .nothingToCopy:
            return dotCount
        case .dryRunFinished:
            return 0
        case .idle, .preflighting, .cancelled, .failed:
            return completedIndex
        }
    }

    private var progressCaption: String {
        let copied = model.context.metrics.copiedCount
        let planned = model.context.metrics.plannedCount
        guard planned > 0 else { return "—" }
        return "\(copied.formatted()) / \(planned.formatted())"
    }

    private var subtitle: String {
        switch model.context.status {
        case .running:
            return "Each dot is a frame finding its place."
        case .dryRunFinished:
            return "Preview is ready. Start the transfer when the plan looks right."
        case .finished:
            return "Every frame is home."
        case .nothingToCopy:
            return "The destination already has everything it needs."
        case .failed:
            return "The run stopped early. Review issues to continue."
        case .cancelled:
            return "Run cancelled. Start again when ready."
        case .preflighting:
            return "Preparing the run."
        case .idle:
            return "Run something to see frames appear here."
        }
    }

    private var accessibilityValue: String {
        "\(model.context.metrics.copiedCount) of \(model.context.metrics.plannedCount) frames placed."
    }

    private enum DotState: Equatable {
        case pending
        case active
        case complete
    }
}

/// A slim 4pt capsule replacing the old five-dot phase timeline. Lives at
/// the bottom of the hero card, colored per current phase, using the same
/// tone tokens as the rest of the Run surfaces.
struct RunPhaseStrip: View {
    let model: RunWorkspaceModel

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let phases = model.phaseEntries
            let segmentWidth = width / CGFloat(max(phases.count, 1))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DesignTokens.ColorSystem.hairline.opacity(0.6))

                HStack(spacing: 0) {
                    ForEach(Array(phases.enumerated()), id: \.element.id) { _, entry in
                        Capsule()
                            .fill(color(for: entry.state))
                            .frame(width: segmentWidth)
                            .motion(Motion.mechanical, value: entry.state)
                    }
                }
                .mask(Capsule())
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Phase progress")
            .accessibilityValue(phasesAccessibilityValue)
        }
        .frame(height: 4)
    }

    private func color(for state: RunPhaseTimelineEntry.State) -> Color {
        switch state {
        case .complete:
            return DesignTokens.ColorSystem.statusSuccess
        case .current:
            return DesignTokens.ColorSystem.accentWaypoint
        case .pending:
            return Color.clear
        }
    }

    private var phasesAccessibilityValue: String {
        let completed = model.phaseEntries.filter { $0.state == .complete }.count
        let total = model.phaseEntries.count
        return "\(completed) of \(total) phases complete"
    }
}

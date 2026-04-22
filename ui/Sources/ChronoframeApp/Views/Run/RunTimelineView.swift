#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

/// Compact strip of dots, each one representing a slice of the planned work.
///
/// Per-(year, month) aggregation isn't streamed from the engine yet, so each
/// dot maps to a contiguous range of frames in the planned set. Hover any dot
/// to see exactly which frames it stands for and whether they've been copied.
/// The data binding can be upgraded to true year×month buckets later without
/// touching the layout.
struct RunTimelineView: View {
    let model: RunWorkspaceModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredIndex: Int?

    private let columnCount = 36
    private let rowCount = 2
    private let dotSpacing: CGFloat = 3
    private let dotMaxSize: CGFloat = 9
    private var dotCount: Int { columnCount * rowCount }

    var body: some View {
        DarkroomPanel(variant: .panel) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Timeline")
                        .font(DesignTokens.Typography.label)
                        .foregroundStyle(DesignTokens.ColorSystem.inkMuted)

                    Spacer()

                    Text(detailCaption)
                        .font(DesignTokens.Typography.label)
                        .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                }

                grid
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
            let totalSpacing = CGFloat(columnCount - 1) * dotSpacing
            let computed = (geo.size.width - totalSpacing) / CGFloat(columnCount)
            let dotSize = max(5, min(dotMaxSize, computed))

            VStack(spacing: dotSpacing) {
                ForEach(0..<rowCount, id: \.self) { row in
                    HStack(spacing: dotSpacing) {
                        ForEach(0..<columnCount, id: \.self) { column in
                            let index = row * columnCount + column
                            dot(at: index, active: active, completed: completed)
                                .frame(width: dotSize, height: dotSize)
                        }
                    }
                }
            }
        }
        .frame(height: CGFloat(rowCount) * dotMaxSize + CGFloat(rowCount - 1) * dotSpacing)
    }

    private func dot(at index: Int, active: Int, completed: Int) -> some View {
        let state = dotState(at: index, active: active, completed: completed)
        let isHovered = hoveredIndex == index

        return Circle()
            .fill(fill(for: state))
            .overlay {
                if state == .active {
                    Circle()
                        .stroke(DesignTokens.ColorSystem.accentWaypoint.opacity(0.5), lineWidth: 1)
                        .scaleEffect(reduceMotion ? 1.0 : 1.35)
                }
            }
            .scaleEffect(isHovered ? 1.6 : 1.0)
            .motion(Motion.mechanical, value: state)
            .motion(Motion.mechanical, value: isHovered)
            .onHover { inside in
                hoveredIndex = inside ? index : (hoveredIndex == index ? nil : hoveredIndex)
            }
            .help(tooltip(for: index, state: state))
    }

    private func dotState(at index: Int, active: Int, completed: Int) -> DotState {
        if model.context.status == .finished { return .complete }
        if index < completed { return .complete }
        if index == active && model.context.status == .running { return .active }
        if index < active { return .active }
        return .pending
    }

    private func fill(for state: DotState) -> Color {
        switch state {
        case .pending:
            return DesignTokens.ColorSystem.inkMuted.opacity(0.22)
        case .active:
            return DesignTokens.ColorSystem.accentWaypoint
        case .complete:
            return DesignTokens.ColorSystem.statusSuccess
        }
    }

    // MARK: - Per-dot meaning

    private var framesPerDot: Int {
        let planned = model.context.metrics.plannedCount
        guard planned > 0 else { return 0 }
        return max(1, Int((Double(planned) / Double(dotCount)).rounded(.up)))
    }

    private func frameRange(for index: Int) -> (start: Int, end: Int)? {
        let planned = model.context.metrics.plannedCount
        guard planned > 0 else { return nil }
        let per = framesPerDot
        let start = index * per + 1
        guard start <= planned else { return nil }
        let end = min(planned, (index + 1) * per)
        return (start, end)
    }

    private func tooltip(for index: Int, state: DotState) -> String {
        guard let range = frameRange(for: index) else {
            return "No frames planned yet"
        }
        let label: String
        if range.start == range.end {
            label = "Frame \(range.start.formatted())"
        } else {
            label = "Frames \(range.start.formatted())–\(range.end.formatted())"
        }
        switch state {
        case .complete:
            return "\(label) · copied"
        case .active:
            return "\(label) · copying now"
        case .pending:
            return "\(label) · waiting"
        }
    }

    private var detailCaption: String {
        if let hovered = hoveredIndex {
            return tooltip(for: hovered, state: dotState(at: hovered, active: activeIndex, completed: completedIndex))
        }
        return progressCaption
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

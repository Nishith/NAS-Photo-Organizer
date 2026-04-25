#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

/// The emotional centerpiece of the Run view: a chronological histogram of
/// the photos and videos found in the source. Each bar is one year-month;
/// height scales with the file count for that month.
///
/// During a transfer the bars fill in left-to-right (oldest → newest) as
/// `copiedCount` advances, giving the "frames finding their place" moment
/// while also showing the actual shape of the user's library.
///
/// Source: `RunMetrics.dateHistogram`, populated from the Python engine's
/// `date_histogram` event after the classification phase completes.
struct RunTimelineView: View {
    let model: RunWorkspaceModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let chartHeight: CGFloat = 96
    private let minBarHeight: CGFloat = 3

    var body: some View {
        DarkroomPanel(variant: .panel) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                header

                if buckets.isEmpty {
                    emptyState
                } else {
                    chart
                }

                Text(subtitle)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Source timeline")
        .accessibilityValue(accessibilityValue)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Timeline")
                .font(DesignTokens.Typography.cardTitle)
                .foregroundStyle(DesignTokens.ColorSystem.inkPrimary)

            Spacer()

            Text(rangeCaption)
                .font(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }

    // MARK: - Chart

    private var chart: some View {
        let fills = barFills
        let maxCount = max(buckets.map(\.plannedCount).max() ?? 1, 1)

        return GeometryReader { geo in
            let spacing: CGFloat = max(1, min(4, geo.size.width / CGFloat(buckets.count) * 0.15))
            let totalSpacing = spacing * CGFloat(max(0, buckets.count - 1))
            let barWidth = max(2, (geo.size.width - totalSpacing) / CGFloat(buckets.count))

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(buckets.enumerated()), id: \.element.id) { index, bucket in
                    bar(
                        for: bucket,
                        fill: fills[index],
                        maxCount: maxCount,
                        width: barWidth,
                        availableHeight: geo.size.height
                    )
                }
            }
        }
        .frame(height: chartHeight)
    }

    private func bar(
        for bucket: DateHistogramBucket,
        fill: Double,
        maxCount: Int,
        width: CGFloat,
        availableHeight: CGFloat
    ) -> some View {
        let ratio = Double(bucket.plannedCount) / Double(maxCount)
        let height = max(minBarHeight, CGFloat(ratio) * availableHeight)
        let cornerRadius = min(width, height) / 2

        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(DesignTokens.ColorSystem.inkMuted.opacity(0.18))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(fillColor(for: fill))
                .frame(height: max(0, height * CGFloat(fill)))
                .motion(reduceMotion ? Motion.mechanical : Motion.filmic, value: fill)
        }
        .frame(width: width, height: height)
        .accessibilityLabel(label(for: bucket))
    }

    private func fillColor(for fill: Double) -> Color {
        if fill >= 1.0 {
            return DesignTokens.ColorSystem.statusSuccess
        }
        if fill > 0 {
            return DesignTokens.ColorSystem.accentWaypoint
        }
        return .clear
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DesignTokens.ColorSystem.hairline.opacity(0.4))

            Text(emptyStateMessage)
                .font(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignTokens.Spacing.md)
        }
        .frame(height: chartHeight)
    }

    private var emptyStateMessage: String {
        switch model.context.status {
        case .idle:
            return "Run a preview to see the source timeline."
        case .preflighting, .running:
            return "Scanning source — bars will appear as files are dated."
        default:
            return "No dated files found in this source."
        }
    }

    // MARK: - Data mapping

    private var buckets: [DateHistogramBucket] {
        model.context.metrics.dateHistogram
    }

    /// Distributes `copiedCount` across buckets left-to-right. Each bucket gets
    /// a fill ratio in [0, 1]. This is an approximation — the engine doesn't
    /// emit per-file completion order, but the copy phase iterates buckets in
    /// chronological order, so left-to-right fill matches reality closely.
    private var barFills: [Double] {
        let copied = model.context.metrics.copiedCount
        var remaining = copied
        return buckets.map { bucket in
            guard bucket.plannedCount > 0 else { return 0 }
            let used = min(remaining, bucket.plannedCount)
            remaining -= used
            let ratio = Double(used) / Double(bucket.plannedCount)
            // After the run finishes, treat every planned bar as complete so
            // a successful run reads as fully green even if the engine reports
            // a slightly different copiedCount (e.g. duplicates folded in).
            if model.context.status == .finished || model.context.status == .nothingToCopy {
                return 1.0
            }
            return ratio
        }
    }

    private var rangeCaption: String {
        let dated = buckets.filter { $0.key != "Unknown" }
        guard let first = dated.first, let last = dated.last else {
            let total = buckets.reduce(0) { $0 + $1.plannedCount }
            return total > 0 ? "\(total.formatted()) files" : "—"
        }
        let firstYear = String(first.key.prefix(4))
        let lastYear = String(last.key.prefix(4))
        let total = buckets.reduce(0) { $0 + $1.plannedCount }
        if firstYear == lastYear {
            return "\(firstYear) · \(total.formatted()) files"
        }
        return "\(firstYear)–\(lastYear) · \(total.formatted()) files"
    }

    private var subtitle: String {
        switch model.context.status {
        case .running:
            if model.context.currentPhase == .copy {
                return "Each bar fills as those frames find their place."
            }
            return "Reading dates from the source."
        case .dryRunFinished:
            return "Here's the shape of your source — every bar a month of frames waiting to land."
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
            return "Run a preview to see the timeline of your source."
        case .reverted:
            return "Files restored to their original state."
        case .revertEmpty:
            return "This receipt had no transfers to undo."
        case .reorganized:
            return "Layout updated in place."
        case .nothingToReorganize:
            return "The destination already matches this layout."
        }
    }

    private var accessibilityValue: String {
        let total = buckets.reduce(0) { $0 + $1.plannedCount }
        let copied = model.context.metrics.copiedCount
        return "\(copied) of \(total) frames placed across \(buckets.count) months."
    }

    private func label(for bucket: DateHistogramBucket) -> String {
        let label = bucket.key == "Unknown" ? "Unknown date" : bucket.key
        return "\(label): \(bucket.plannedCount) files"
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
        .help(model.phaseStripTooltip)
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

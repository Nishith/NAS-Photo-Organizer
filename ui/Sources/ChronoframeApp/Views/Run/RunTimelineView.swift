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
/// Source: `RunMetrics.dateHistogram`, populated from the organizer engine's
/// `date_histogram` event after the classification phase completes.
struct RunTimelineView: View {
    let model: RunWorkspaceModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let chartHeight: CGFloat = 136
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

            ZStack(alignment: .bottomLeading) {
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

                yearMarkers(width: geo.size.width)
            }
        }
        .frame(height: chartHeight)
        .padding(DesignTokens.Spacing.md)
        .background(DesignTokens.ColorSystem.imageStage, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        let track = seasonalTint(for: bucket.key)

        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(track)

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

    /// Low-saturation seasonal tint for the bar track. Winter months read cool
    /// blue, summer months warm amber, spring/autumn transition between. Keeps
    /// the chart legible at a glance as a calendar of the library's shape.
    private func seasonalTint(for key: String) -> Color {
        guard key.count >= 7, key != "Unknown" else {
            return DesignTokens.ColorSystem.inkMuted.opacity(0.18)
        }
        let monthPart = key.dropFirst(5).prefix(2)
        guard let month = Int(monthPart), (1...12).contains(month) else {
            return DesignTokens.ColorSystem.inkMuted.opacity(0.18)
        }
        // Cosine-shaped warmth curve centered on July: coldest at Jan
        // (~220°, deep blue), warmest at Jul (~35°, warm amber), with smooth
        // periodicity through Dec ↔ Jan.
        let warmth = (cos(Double(month - 7) / 6.0 * .pi) + 1) / 2
        let hue = (220 - warmth * 185) / 360
        return Color(hue: hue, saturation: 0.32, brightness: 0.66, opacity: 0.32)
    }

    private func yearMarkers(width: CGFloat) -> some View {
        let markers = yearMarkerEntries
        return ZStack(alignment: .topLeading) {
            ForEach(markers, id: \.index) { marker in
                VStack(alignment: .leading, spacing: 4) {
                    Rectangle()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: 0.5, height: chartHeight - 20)
                    Text(marker.year)
                        .font(.system(size: 10, weight: .medium, design: .default))
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.52))
                }
                .offset(x: markerOffset(for: marker.index, width: width), y: 0)
            }
        }
        .allowsHitTesting(false)
    }

    private var yearMarkerEntries: [(index: Int, year: String)] {
        var lastYear: String?
        return buckets.enumerated().compactMap { index, bucket in
            guard bucket.key.count >= 4, bucket.key != "Unknown" else { return nil }
            let year = String(bucket.key.prefix(4))
            guard year != lastYear else { return nil }
            lastYear = year
            return (index, year)
        }
    }

    private func markerOffset(for index: Int, width: CGFloat) -> CGFloat {
        guard buckets.count > 1 else { return 0 }
        let ratio = CGFloat(index) / CGFloat(max(buckets.count - 1, 1))
        return min(max(0, ratio * width), max(0, width - 32))
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DesignTokens.ColorSystem.imageStage)

            GhostTimelineBars()
                .padding(DesignTokens.Spacing.md)

            Text(emptyStateMessage)
                .font(DesignTokens.Typography.label)
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(DesignTokens.ColorSystem.imageStage.opacity(0.65))
                )
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

/// Placeholder row of low-opacity bars for the timeline empty state. Heights
/// are seeded once so the silhouette is stable, and the whole layer pulses
/// gently between two opacities on a slow filmic loop so the surface reads
/// as "waiting for data" rather than "broken".
private struct GhostTimelineBars: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let heights: [CGFloat] = {
        var rng = SeededTimelineRNG(seed: 0x4368726F6E6F31)
        return (0..<36).map { _ in CGFloat.random(in: 0.18...0.95, using: &rng) }
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pulse = (sin(t * .pi / 2) + 1) / 2 // 4-second cycle, 0..1
            let opacity = 0.10 + pulse * 0.06

            GeometryReader { geo in
                let spacing: CGFloat = 3
                let count = Self.heights.count
                let barWidth = (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count)

                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(0..<count, id: \.self) { i in
                        let h = Self.heights[i]
                        let height = max(2, h * geo.size.height)
                        RoundedRectangle(cornerRadius: min(barWidth, height) / 2, style: .continuous)
                            .fill(Color.white.opacity(opacity))
                            .frame(width: barWidth, height: height)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Tiny splitmix-style RNG so the ghost-bar silhouette is stable across redraws.
private struct SeededTimelineRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z &>> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z &>> 31)
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

                if let currentIndex {
                    Circle()
                        .fill(DesignTokens.ColorSystem.accentWaypoint)
                        .frame(width: 8, height: 8)
                        .shadow(color: DesignTokens.ColorSystem.accentWaypoint.opacity(0.42), radius: 5)
                        .offset(x: min(max(0, CGFloat(currentIndex) * segmentWidth + segmentWidth - 4), max(0, width - 8)))
                        .motion(Motion.mechanical, value: currentIndex)
                }
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

    private var currentIndex: Int? {
        model.phaseEntries.firstIndex { $0.state == .current }
    }
}

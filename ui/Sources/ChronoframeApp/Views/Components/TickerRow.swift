import SwiftUI

/// A single-line inline ticker replacing the metric tile grid on the Run view.
/// Six figures separated by middots, monospaced digits so numbers don't
/// shimmy while updating live. Designed for the quiet-darkroom aesthetic:
/// the data is the information; no tiles, no tints, no captions.
struct TickerRow: View {
    struct Entry: Identifiable {
        let id: String
        let value: String
        let label: String
        let tone: TickerTone
    }

    enum TickerTone {
        case neutral
        case warning
        case danger
        case success
    }

    let entries: [Entry]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalLayout
            wrappedLayout
        }
        .font(DesignTokens.Typography.body)
        .monospacedDigit()
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DesignTokens.ColorSystem.hairline)
                .frame(height: 0.5)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DesignTokens.ColorSystem.hairline)
                .frame(height: 0.5)
        }
    }

    private var horizontalLayout: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                entryView(entry)
                    .contentTransition(.numericText())
                if index != entries.indices.last {
                    Text("·")
                        .foregroundStyle(DesignTokens.ColorSystem.inkMuted.opacity(0.5))
                }
            }
        }
    }

    private var wrappedLayout: some View {
        FlowLayout(horizontalSpacing: DesignTokens.Spacing.sm, verticalSpacing: 4) {
            ForEach(entries) { entry in
                entryView(entry)
            }
        }
    }

    private func entryView(_ entry: Entry) -> some View {
        HStack(spacing: 4) {
            Text(entry.value)
                .fontWeight(.medium)
                .foregroundStyle(color(for: entry.tone))
            Text(entry.label)
                .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.label): \(entry.value)")
    }

    private func color(for tone: TickerTone) -> Color {
        switch tone {
        case .neutral: return DesignTokens.ColorSystem.inkPrimary
        case .warning: return DesignTokens.ColorSystem.statusWarning
        case .danger: return DesignTokens.ColorSystem.statusDanger
        case .success: return DesignTokens.ColorSystem.statusSuccess
        }
    }
}

/// Minimal flow layout for the fallback wrapped ticker — SwiftUI's `Layout`
/// protocol requires iOS 16/macOS 13, which matches our deployment minimum.
private struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGSize]] = [[]]
        var currentRowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let needsBreak = currentRowWidth + size.width > maxWidth && !rows[rows.count - 1].isEmpty
            if needsBreak {
                totalHeight += rowHeight + verticalSpacing
                rows.append([])
                currentRowWidth = 0
                rowHeight = 0
            }
            rows[rows.count - 1].append(size)
            currentRowWidth += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }

        totalHeight += rowHeight
        var maxRowWidth: CGFloat = 0
        for row in rows {
            var rowWidth: CGFloat = 0
            for size in row {
                rowWidth += size.width
            }
            let gaps = CGFloat(max(row.count - 1, 0))
            rowWidth += horizontalSpacing * gaps
            if rowWidth > maxRowWidth { maxRowWidth = rowWidth }
        }
        let width = proposal.width ?? maxRowWidth
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x != bounds.minX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

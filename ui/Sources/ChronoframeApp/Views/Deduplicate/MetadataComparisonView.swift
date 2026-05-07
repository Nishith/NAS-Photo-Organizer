#if canImport(ChronoframeCore)
import ChronoframeCore
#endif
import SwiftUI

struct MetadataComparisonView: View {
    let left: PhotoCandidate
    let right: PhotoCandidate
    let leftIsKeeper: Bool

    private static let bytesFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            Divider()
            comparisonRows
        }
        .background(DesignTokens.ColorSystem.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var headerRow: some View {
        HStack {
            Text(leftIsKeeper ? "Keeper" : "A")
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
            Divider().frame(height: 16)
            Text("Attribute")
                .font(.caption.weight(.semibold))
                .frame(width: 80)
            Divider().frame(height: 16)
            Text(leftIsKeeper ? "Other" : "B")
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }

    private var comparisonRows: some View {
        VStack(spacing: 0) {
            row("Size", leftValue: Self.bytesFormatter.string(fromByteCount: left.size),
                rightValue: Self.bytesFormatter.string(fromByteCount: right.size),
                leftWins: left.size > right.size)

            if let lw = left.pixelWidth, let lh = left.pixelHeight,
               let rw = right.pixelWidth, let rh = right.pixelHeight {
                let lArea = lw * lh
                let rArea = rw * rh
                row("Dimensions", leftValue: "\(lw)×\(lh)", rightValue: "\(rw)×\(rh)",
                    leftWins: lArea > rArea)
            }

            row("Quality", leftValue: String(format: "%.2f", left.qualityScore),
                rightValue: String(format: "%.2f", right.qualityScore),
                leftWins: left.qualityScore > right.qualityScore)

            row("Sharpness", leftValue: String(format: "%.2f", left.sharpness),
                rightValue: String(format: "%.2f", right.sharpness),
                leftWins: left.sharpness > right.sharpness)

            if left.faceScore != nil || right.faceScore != nil {
                row("Face", leftValue: left.faceScore.map { String(format: "%.2f", $0) } ?? "—",
                    rightValue: right.faceScore.map { String(format: "%.2f", $0) } ?? "—",
                    leftWins: (left.faceScore ?? 0) > (right.faceScore ?? 0))
            }

            row("Date", leftValue: dateString(left.captureDate),
                rightValue: dateString(right.captureDate), leftWins: nil)
        }
    }

    private func row(_ label: String, leftValue: String, rightValue: String, leftWins: Bool?) -> some View {
        HStack {
            Text(leftValue)
                .font(.caption.monospacedDigit())
                .foregroundStyle(leftWins == true ? DesignTokens.ColorSystem.statusSuccess : .primary)
                .frame(maxWidth: .infinity)
            Divider().frame(height: 16)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 80)
            Divider().frame(height: 16)
            Text(rightValue)
                .font(.caption.monospacedDigit())
                .foregroundStyle(leftWins == false ? DesignTokens.ColorSystem.statusSuccess : .primary)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }

    private func dateString(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }
}

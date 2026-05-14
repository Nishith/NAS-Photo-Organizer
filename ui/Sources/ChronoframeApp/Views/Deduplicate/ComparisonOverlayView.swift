#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import AppKit
import SwiftUI

struct ComparisonOverlayView: View {
    let leftPath: String
    let rightPath: String
    @State private var mode: ComparisonMode = .slider
    @State private var sliderPosition: CGFloat = 0.5
    @Environment(\.dismiss) private var dismiss

    enum ComparisonMode: String, CaseIterable {
        case slider
        case difference
        case flicker

        var label: String {
            switch self {
            case .slider: return "Slider"
            case .difference: return "Difference"
            case .flicker: return "Flicker"
            }
        }

        var icon: String {
            switch self {
            case .slider: return "rectangle.split.2x1"
            case .difference: return "square.stack.3d.up"
            case .flicker: return "bolt.square"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            comparisonContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 600, minHeight: 500)
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
                imagePairLabel
                Spacer()
                modePicker
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                imagePairLabel
                HStack {
                    modePicker
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.escape, modifiers: [])
                }
            }
        }
        .padding(DesignTokens.Spacing.md)
    }

    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            ForEach(ComparisonMode.allCases, id: \.self) { m in
                Label(m.label, systemImage: m.icon).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 300)
    }

    private var imagePairLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            Label(URL(fileURLWithPath: leftPath).lastPathComponent, systemImage: "a.circle")
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "arrow.left.arrow.right")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label(URL(fileURLWithPath: rightPath).lastPathComponent, systemImage: "b.circle")
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var comparisonContent: some View {
        switch mode {
        case .slider:
            SliderComparisonView(leftPath: leftPath, rightPath: rightPath, position: $sliderPosition)
        case .difference:
            DifferenceComparisonView(leftPath: leftPath, rightPath: rightPath)
        case .flicker:
            FlickerComparisonView(leftPath: leftPath, rightPath: rightPath)
        }
    }
}

// MARK: - Slider Comparison

private struct SliderComparisonView: View {
    let leftPath: String
    let rightPath: String
    @Binding var position: CGFloat
    @State private var leftImage: NSImage?
    @State private var rightImage: NSImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let rightImage {
                    Image(nsImage: rightImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                if let leftImage {
                    Image(nsImage: leftImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipShape(
                            HorizontalClip(fraction: position)
                        )
                }
                Rectangle()
                    .fill(DesignTokens.ColorSystem.dividerEmphasis)
                    .frame(width: 2)
                    .position(x: geometry.size.width * position, y: geometry.size.height / 2)
                    .shadow(radius: 2)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        position = min(1, max(0, value.location.x / geometry.size.width))
                    }
            )
        }
        .task { leftImage = loadImage(at: leftPath) }
        .task { rightImage = loadImage(at: rightPath) }
    }
}

private struct HorizontalClip: Shape {
    var fraction: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: 0, y: 0, width: rect.width * fraction, height: rect.height))
    }
}

// MARK: - Difference Comparison

private struct DifferenceComparisonView: View {
    let leftPath: String
    let rightPath: String
    @State private var differenceImage: NSImage?
    @State private var loading = true

    var body: some View {
        ZStack {
            if let differenceImage {
                Image(nsImage: differenceImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if loading {
                ProgressView("Computing difference…")
            } else {
                Text("Could not generate difference image")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            differenceImage = DifferenceImageGenerator.generate(
                leftURL: URL(fileURLWithPath: leftPath),
                rightURL: URL(fileURLWithPath: rightPath)
            )
            loading = false
        }
    }
}

// MARK: - Flicker Comparison

private struct FlickerComparisonView: View {
    let leftPath: String
    let rightPath: String
    @State private var showingLeft = true
    @State private var leftImage: NSImage?
    @State private var rightImage: NSImage?
    @State private var flickerTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if showingLeft, let leftImage {
                Image(nsImage: leftImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if !showingLeft, let rightImage {
                Image(nsImage: rightImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            Text(showingLeft ? "A (Keeper)" : "B")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(.bottom, 12)
        }
        .task {
            leftImage = loadImage(at: leftPath)
            rightImage = loadImage(at: rightPath)
        }
        .onAppear { startFlicker() }
        .onDisappear { flickerTask?.cancel() }
    }

    private func startFlicker() {
        flickerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { break }
                showingLeft.toggle()
            }
        }
    }
}

// MARK: - Helpers

private func loadImage(at path: String) -> NSImage? {
    NSImage(contentsOfFile: path)
}

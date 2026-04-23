import SwiftUI

// MARK: - Darkroom Panel (the new preferred surface component)

/// Variant of the new Darkroom-language panel.
enum DarkroomPanelVariant {
    /// Sits directly on the window canvas; transparent, no chrome.
    case canvas
    /// Vibrant panel with hairline border. The default.
    case panel
    /// Nested inset area: no background, just an indent.
    case inset
    /// Quiet elevated popover-style (used sparingly).
    case elevated
}

/// The new Darkroom panel. Replaces ``MeridianSurfaceCard``.
///
/// Rules:
/// - One elevated surface per screen max.
/// - Inner groupings use hairlines instead of nested panels.
/// - Shadows are reserved for modals/popovers.
struct DarkroomPanel<Content: View>: View {
    let variant: DarkroomPanelVariant
    let content: Content

    init(variant: DarkroomPanelVariant = .panel, @ViewBuilder content: () -> Content) {
        self.variant = variant
        self.content = content()
    }

    var body: some View {
        let corner = cornerRadius
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)

        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundFor: variant, in: shape)
            .overlay(borderFor: variant, in: shape)
    }

    private var cornerRadius: CGFloat {
        switch variant {
        case .canvas, .inset:
            return 0
        case .panel:
            return DesignTokens.Corner.card
        case .elevated:
            return DesignTokens.Corner.hero
        }
    }

    private var padding: CGFloat {
        switch variant {
        case .canvas, .inset:
            return 0
        case .panel:
            return DesignTokens.Layout.cardPadding
        case .elevated:
            return DesignTokens.Layout.heroPadding
        }
    }
}

private extension View {
    @ViewBuilder
    func background(backgroundFor variant: DarkroomPanelVariant, in shape: some InsettableShape) -> some View {
        switch variant {
        case .canvas, .inset:
            self
        case .panel:
            background(.thinMaterial, in: shape)
        case .elevated:
            background(DesignTokens.ColorSystem.elevated, in: shape)
                .background(.regularMaterial, in: shape)
                .shadow(color: DesignTokens.ColorSystem.shadow, radius: 18, x: 0, y: 10)
        }
    }

    @ViewBuilder
    func overlay(borderFor variant: DarkroomPanelVariant, in shape: RoundedRectangle) -> some View {
        switch variant {
        case .canvas, .inset:
            self
        case .panel, .elevated:
            overlay(shape.strokeBorder(DesignTokens.ColorSystem.hairline, lineWidth: 0.5))
        }
    }
}

// MARK: - MeridianSurfaceCard (legacy — routed through DarkroomPanel)

enum MeridianSurfaceCardStyle {
    case hero
    case standard
    case inner

    var cornerRadius: CGFloat {
        switch self {
        case .hero:
            return DesignTokens.Corner.hero
        case .standard:
            return DesignTokens.Corner.card
        case .inner:
            return DesignTokens.Corner.innerCard
        }
    }

    var padding: CGFloat {
        switch self {
        case .hero, .standard:
            return DesignTokens.Layout.cardPadding
        case .inner:
            return DesignTokens.Layout.compactPadding
        }
    }
}

/// Legacy card component. Kept for source compatibility; visuals are now
/// routed through the Darkroom surface system — no gradients, no shadows,
/// just vibrancy + hairline.
struct MeridianSurfaceCard<Content: View>: View {
    let style: MeridianSurfaceCardStyle
    let tint: SwiftUI.Color?
    let content: Content

    init(
        style: MeridianSurfaceCardStyle = .standard,
        tint: SwiftUI.Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.style = style
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)

        content
            .padding(style.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                backgroundView
                    .clipShape(shape)
            }
            .overlay(shape.strokeBorder(borderColor, lineWidth: 0.5))
    }

    @ViewBuilder
    private var backgroundView: some View {
        switch style {
        case .hero:
            ZStack {
                Rectangle().fill(.thinMaterial)
                if let tint {
                    Rectangle().fill(tint.opacity(0.06))
                }
            }
        case .standard:
            Rectangle().fill(.thinMaterial)
        case .inner:
            if let tint {
                Rectangle().fill(tint.opacity(0.05))
            } else {
                Rectangle().fill(DesignTokens.ColorSystem.hairline.opacity(0.6))
            }
        }
    }

    private var borderColor: SwiftUI.Color {
        if let tint, style == .inner {
            return tint.opacity(0.18)
        }
        return DesignTokens.ColorSystem.hairline
    }
}

// MARK: - Lead icon

struct MeridianLeadIcon: View {
    let systemImage: String
    let tint: SwiftUI.Color
    var usesBrandMark = false
    var size: CGFloat = DesignTokens.Layout.heroIconSize

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(tint.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .strokeBorder(tint.opacity(0.22), lineWidth: 0.5)
                )

            if usesBrandMark {
                MeridianMark()
                    .padding(size * 0.22)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.44, weight: .medium))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Brand mark

struct MeridianMark: View {
    var body: some View {
        ZStack {
            Image(systemName: "camera.aperture")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(DesignTokens.ColorSystem.inkPrimary.opacity(0.95))

            Circle()
                .fill(DesignTokens.ColorSystem.accentWaypoint)
                .frame(width: 6, height: 6)
                .offset(x: 10, y: 10)
        }
    }
}

// MARK: - Status badge

struct MeridianStatusBadge: View {
    let title: String
    let systemImage: String?
    let tint: SwiftUI.Color

    init(title: String, systemImage: String? = nil, tint: SwiftUI.Color) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
            }
            Text(title)
                .font(DesignTokens.Typography.label)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .foregroundStyle(tint)
        .background(tint.opacity(0.15), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.28), lineWidth: 0.5))
    }
}

// MARK: - Section heading

struct SectionHeading: View {
    let eyebrow: String?
    let title: String
    let message: String

    init(eyebrow: String? = nil, title: String, message: String) {
        self.eyebrow = eyebrow
        self.title = title
        self.message = message
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let eyebrow, !eyebrow.isEmpty {
                Text(eyebrow.uppercased())
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
                    .tracking(0.8)
            }

            Text(title)
                .font(DesignTokens.Typography.cardTitle)
                .foregroundStyle(DesignTokens.ColorSystem.inkPrimary)

            if !message.isEmpty {
                Text(message)
                    .font(DesignTokens.Typography.subtitle)
                    .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Hero card

/// Compact hero card. Retuned for Darkroom: no colored gradient, no oversized
/// icon block, shorter titles. Still useful as a top-of-screen anchor until
/// fully replaced by toolbar-embedded status in later phases.
struct DetailHeroCard<Summary: View, Actions: View>: View {
    let eyebrow: String?
    let title: String
    let message: String
    let badgeTitle: String
    let badgeSystemImage: String?
    let tint: SwiftUI.Color
    let systemImage: String
    let usesBrandMark: Bool
    let summary: Summary
    let actions: Actions

    init(
        eyebrow: String? = nil,
        title: String,
        message: String,
        badgeTitle: String,
        badgeSystemImage: String? = nil,
        tint: SwiftUI.Color,
        systemImage: String,
        usesBrandMark: Bool = false,
        @ViewBuilder summary: () -> Summary,
        @ViewBuilder actions: () -> Actions
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.message = message
        self.badgeTitle = badgeTitle
        self.badgeSystemImage = badgeSystemImage
        self.tint = tint
        self.systemImage = systemImage
        self.usesBrandMark = usesBrandMark
        self.summary = summary()
        self.actions = actions()
    }

    var body: some View {
        MeridianSurfaceCard(style: .hero) {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.cardSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    MeridianLeadIcon(
                        systemImage: systemImage,
                        tint: tint,
                        usesBrandMark: usesBrandMark,
                        size: 36
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(DesignTokens.Typography.title)
                            .foregroundStyle(DesignTokens.ColorSystem.inkPrimary)

                        if !message.isEmpty {
                            Text(message)
                                .font(DesignTokens.Typography.subtitle)
                                .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 12)

                    MeridianStatusBadge(title: badgeTitle, systemImage: badgeSystemImage, tint: tint)
                }

                summary
                actions
            }
        }
    }
}

// MARK: - Summary line

struct SummaryLine: View {
    let title: String
    let value: String
    let valueColor: SwiftUI.Color?
    let onTap: (() -> Void)?

    init(title: String, value: String, valueColor: SwiftUI.Color? = nil, onTap: (() -> Void)? = nil) {
        self.title = title
        self.value = value
        self.valueColor = valueColor
        self.onTap = onTap
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.ColorSystem.inkMuted)

            Spacer(minLength: 12)

            if let onTap {
                Button(action: onTap) {
                    Text(value)
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(valueColor ?? DesignTokens.ColorSystem.inkPrimary)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                }
                .buttonStyle(.plain)
            } else {
                Text(value)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(valueColor ?? DesignTokens.ColorSystem.inkPrimary)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
            }
        }
    }
}

// MARK: - Metric tile

struct MetricTile: View {
    let title: String
    let value: String
    let caption: String
    let tint: SwiftUI.Color

    var body: some View {
        MeridianSurfaceCard(style: .inner, tint: tint) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased())
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
                    .tracking(0.6)

                Text(value)
                    .font(DesignTokens.Typography.metric)
                    .foregroundStyle(DesignTokens.ColorSystem.inkPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())

                Text(caption)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value). \(caption)")
    }
}

// MARK: - Path value view

struct PathValueView: View {
    let title: String
    let value: String
    let helper: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
                .tracking(0.6)

            Text(value.isEmpty ? "Not set" : value)
                .font(DesignTokens.Typography.mono)
                .foregroundStyle(value.isEmpty ? DesignTokens.ColorSystem.inkMuted : DesignTokens.ColorSystem.inkPrimary)
                .lineLimit(DesignTokens.Layout.pathLineLimit)
                .truncationMode(.middle)

            if !helper.isEmpty {
                Text(helper)
                    .font(.footnote)
                    .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        MeridianSurfaceCard(style: .standard) {
            VStack(spacing: 10) {
                MeridianLeadIcon(systemImage: systemImage, tint: DesignTokens.ColorSystem.accentAction, size: 40)
                Text(title)
                    .font(DesignTokens.Typography.cardTitle)
                    .foregroundStyle(DesignTokens.ColorSystem.inkPrimary)
                Text(message)
                    .font(DesignTokens.Typography.subtitle)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 160)
        }
    }
}

// MARK: - Hairline divider

/// A 0.5pt hairline divider using the Darkroom line token.
struct HairlineDivider: View {
    var body: some View {
        Rectangle()
            .fill(DesignTokens.ColorSystem.hairline)
            .frame(height: 0.5)
    }
}

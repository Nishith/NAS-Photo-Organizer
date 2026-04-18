import SwiftUI

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
            .background(
                LinearGradient(
                    colors: gradientColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: shape
            )
            .background(.thinMaterial, in: shape)
            .overlay(
                shape.strokeBorder(DesignTokens.Surface.stroke, lineWidth: 1)
            )
            .shadow(color: DesignTokens.Surface.shadowColor, radius: 18, x: 0, y: 10)
    }

    private var gradientColors: [SwiftUI.Color] {
        if let tint {
            return [
                tint.opacity(0.18),
                DesignTokens.Surface.heroGradientStart,
                DesignTokens.Surface.heroGradientEnd,
            ]
        }

        switch style {
        case .hero:
            return [
                DesignTokens.Surface.heroGradientStart,
                DesignTokens.Surface.heroGradientEnd,
            ]
        case .standard, .inner:
            return [
                DesignTokens.Color.cloud,
                DesignTokens.Color.cloud.opacity(0.3),
            ]
        }
    }
}

struct MeridianLeadIcon: View {
    let systemImage: String
    let tint: SwiftUI.Color
    var usesBrandMark = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            tint.opacity(0.22),
                            tint.opacity(0.08),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(tint.opacity(0.18), lineWidth: 1)
                )

            if usesBrandMark {
                MeridianMark()
                    .padding(11)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: DesignTokens.Layout.heroIconSize, height: DesignTokens.Layout.heroIconSize)
    }
}

struct MeridianMark: View {
    var body: some View {
        ZStack {
            Image(systemName: "camera.aperture")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(DesignTokens.Color.inkPrimary.opacity(0.95))

            Circle()
                .fill(DesignTokens.Color.amberWaypoint)
                .frame(width: 6, height: 6)
                .offset(x: 10, y: 10)
        }
    }
}

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
        HStack(spacing: 7) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
                .fontWeight(.semibold)
        }
        .font(.caption)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .foregroundStyle(tint)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

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
        VStack(alignment: .leading, spacing: 6) {
            if let eyebrow, !eyebrow.isEmpty {
                Text(eyebrow.uppercased())
                    .font(DesignTokens.Typography.eyebrow)
                    .foregroundStyle(DesignTokens.Color.inkMuted)
                    .tracking(0.5)
            }

            Text(title)
                .font(DesignTokens.Typography.cardTitle)
                .foregroundStyle(DesignTokens.Color.inkPrimary)

            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

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
        MeridianSurfaceCard(style: .hero, tint: tint) {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.cardSpacing) {
                HStack(alignment: .top, spacing: 16) {
                    MeridianLeadIcon(
                        systemImage: systemImage,
                        tint: tint,
                        usesBrandMark: usesBrandMark
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        if let eyebrow, !eyebrow.isEmpty {
                            Text(eyebrow.uppercased())
                                .font(DesignTokens.Typography.eyebrow)
                                .foregroundStyle(DesignTokens.Color.inkMuted)
                                .tracking(0.5)
                        }

                        Text(title)
                            .font(DesignTokens.Typography.heroTitle)
                            .foregroundStyle(DesignTokens.Color.inkPrimary)

                        Text(message)
                            .font(.title3)
                            .foregroundStyle(DesignTokens.Color.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
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

struct SummaryLine: View {
    let title: String
    let value: String
    let valueColor: SwiftUI.Color?

    init(title: String, value: String, valueColor: SwiftUI.Color? = nil) {
        self.title = title
        self.value = value
        self.valueColor = valueColor
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            Text(value)
                .foregroundStyle(valueColor ?? DesignTokens.Color.inkPrimary)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
        }
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let caption: String
    let tint: SwiftUI.Color

    var body: some View {
        MeridianSurfaceCard(style: .inner, tint: tint) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased())
                    .font(DesignTokens.Typography.eyebrow)
                    .foregroundStyle(DesignTokens.Color.inkMuted)
                    .tracking(0.4)

                Text(value)
                    .font(DesignTokens.Typography.metricValue)
                    .foregroundStyle(DesignTokens.Color.inkPrimary)

                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value). \(caption)")
    }
}

struct PathValueView: View {
    let title: String
    let value: String
    let helper: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DesignTokens.Color.inkPrimary)

            Text(value.isEmpty ? "Not set" : value)
                .foregroundStyle(value.isEmpty ? .secondary : .primary)
                .font(.callout.monospaced())
                .lineLimit(DesignTokens.Layout.pathLineLimit)
                .truncationMode(.middle)

            Text(helper)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        MeridianSurfaceCard(style: .standard) {
            VStack(spacing: 12) {
                MeridianLeadIcon(systemImage: systemImage, tint: DesignTokens.Color.sky)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(DesignTokens.Color.inkPrimary)
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        }
    }
}

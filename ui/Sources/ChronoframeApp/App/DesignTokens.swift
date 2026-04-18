import AppKit
import CoreGraphics
import SwiftUI

/// Semantic design tokens for Chronoframe's macOS surfaces.
///
/// "Darkroom" design language: dark-first dynamic palette, SF Pro (not Rounded),
/// hairline-and-vibrancy surfaces. The live app stays rooted in native macOS
/// materials; these tokens provide semantic hierarchy and brand consistency.
///
/// Backward-compatibility notes:
/// - The legacy token names (`Color.sky`, `.aqua`, `.amber`, `.amberWaypoint`,
///   `.mist`, `.cloud`, `.inkPrimary`, etc.) are preserved as aliases that
///   resolve to the new semantic palette, so existing call sites keep
///   compiling. They will be migrated out during later phases.
enum DesignTokens {

    // MARK: - Layout (unchanged)

    enum Layout {
        static let contentMaxWidth: CGFloat = 1_160
        static let setupMaxWidth: CGFloat = 1_120
        static let archiveMaxWidth: CGFloat = 1_120
        static let contentPadding: CGFloat = 28
        static let heroPadding: CGFloat = 24
        static let cardPadding: CGFloat = 20
        static let compactPadding: CGFloat = 14
        static let sectionSpacing: CGFloat = 20
        static let cardSpacing: CGFloat = 16
        static let inlineSpacing: CGFloat = 10
        static let consoleFontSize: CGFloat = 13
        static let consoleMinHeight: CGFloat = 220
        static let consoleIdealHeight: CGFloat = 320
        static let phaseIndicatorSize: CGFloat = 18
        static let phaseConnectorHeight: CGFloat = 4
        static let heroIconSize: CGFloat = 54
        static let metricMinWidth: CGFloat = 176
        static let narrowMetricMinWidth: CGFloat = 152
        static let pathLineLimit: Int = 3
    }

    enum Window {
        static let mainMinWidth: CGFloat = 900
        static let mainIdealWidth: CGFloat = 1_180
        static let mainMinHeight: CGFloat = 700
        static let mainIdealHeight: CGFloat = 820

        static let settingsMinWidth: CGFloat = 460
        static let settingsIdealWidth: CGFloat = 520
        static let settingsMinHeight: CGFloat = 380
    }

    enum Sidebar {
        static let minWidth: CGFloat = 220
        static let idealWidth: CGFloat = 248
        static let maxWidth: CGFloat = 304
    }

    enum Corner {
        static let hero: CGFloat = 20
        static let card: CGFloat = 14
        static let innerCard: CGFloat = 10
        static let badge: CGFloat = 999
    }

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - Color system (the new, dynamic, dark-first palette)

    /// Semantic color system. New code should use these.
    /// Legacy names under ``DesignTokens/Color`` resolve here for compatibility.
    enum ColorSystem {

        // Surfaces
        /// Window/canvas background. Warm paper in light, graphite in dark.
        static let canvas = dynamicColor(
            light: NSColor(srgbRed: 246.0 / 255, green: 245.0 / 255, blue: 242.0 / 255, alpha: 1),
            dark: NSColor(srgbRed: 14.0 / 255, green: 15.0 / 255, blue: 18.0 / 255, alpha: 1)
        )

        /// Content panel behind lists; sits above canvas with vibrancy optional.
        static let panel = dynamicColor(
            light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.72),
            dark: NSColor(srgbRed: 23.0 / 255, green: 24.0 / 255, blue: 28.0 / 255, alpha: 0.88)
        )

        /// Elevated surface — used sparingly for focus states / popovers.
        static let elevated = dynamicColor(
            light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92),
            dark: NSColor(srgbRed: 32.0 / 255, green: 34.0 / 255, blue: 40.0 / 255, alpha: 0.96)
        )

        // Ink (text)
        /// Primary text — headings, metric values.
        static let inkPrimary = dynamicColor(
            light: NSColor(srgbRed: 14.0 / 255, green: 17.0 / 255, blue: 22.0 / 255, alpha: 1),
            dark: NSColor(srgbRed: 237.0 / 255, green: 238.0 / 255, blue: 242.0 / 255, alpha: 1)
        )
        /// Secondary text — body copy, labels.
        static let inkSecondary = dynamicColor(
            light: NSColor(srgbRed: 71.0 / 255, green: 80.0 / 255, blue: 99.0 / 255, alpha: 1),
            dark: NSColor(srgbRed: 169.0 / 255, green: 175.0 / 255, blue: 188.0 / 255, alpha: 1)
        )
        /// Muted text — helper captions, eyebrow labels.
        static let inkMuted = dynamicColor(
            light: NSColor(srgbRed: 123.0 / 255, green: 131.0 / 255, blue: 149.0 / 255, alpha: 1),
            dark: NSColor(srgbRed: 112.0 / 255, green: 118.0 / 255, blue: 132.0 / 255, alpha: 1)
        )

        // Lines
        /// 0.5pt hairline separators.
        static let hairline = dynamicColor(
            light: NSColor.black.withAlphaComponent(0.08),
            dark: NSColor.white.withAlphaComponent(0.10)
        )

        // Accents
        /// The waypoint amber — brand, the "moment a memory finds its place".
        static let accentWaypoint = dynamicColor(
            light: NSColor(srgbRed: 232.0 / 255, green: 163.0 / 255, blue: 23.0 / 255, alpha: 1),
            dark: NSColor(srgbRed: 246.0 / 255, green: 185.0 / 255, blue: 74.0 / 255, alpha: 1)
        )
        /// Action indigo — primary buttons, progress fill.
        static let accentAction = dynamicColor(
            light: NSColor(srgbRed: 62.0 / 255, green: 91.0 / 255, blue: 255.0 / 255, alpha: 1),
            dark: NSColor(srgbRed: 123.0 / 255, green: 142.0 / 255, blue: 255.0 / 255, alpha: 1)
        )

        // Status
        static let statusReady = accentAction
        static let statusActive = dynamicColor(
            light: NSColor(srgbRed: 47.0 / 255, green: 182.0 / 255, blue: 160.0 / 255, alpha: 1),
            dark: NSColor(srgbRed: 75.0 / 255, green: 208.0 / 255, blue: 182.0 / 255, alpha: 1)
        )
        static let statusSuccess = dynamicColor(
            light: NSColor(srgbRed: 47.0 / 255, green: 143.0 / 255, blue: 91.0 / 255, alpha: 1),
            dark: NSColor(srgbRed: 88.0 / 255, green: 201.0 / 255, blue: 140.0 / 255, alpha: 1)
        )
        static let statusWarning = dynamicColor(
            light: NSColor(srgbRed: 208.0 / 255, green: 138.0 / 255, blue: 36.0 / 255, alpha: 1),
            dark: NSColor(srgbRed: 240.0 / 255, green: 180.0 / 255, blue: 89.0 / 255, alpha: 1)
        )
        static let statusDanger = dynamicColor(
            light: NSColor(srgbRed: 199.0 / 255, green: 70.0 / 255, blue: 60.0 / 255, alpha: 1),
            dark: NSColor(srgbRed: 244.0 / 255, green: 113.0 / 255, blue: 102.0 / 255, alpha: 1)
        )
        static let statusIdle = inkMuted

        // Deep shadow (modals/popovers only)
        static let shadow = dynamicColor(
            light: NSColor.black.withAlphaComponent(0.10),
            dark: NSColor.black.withAlphaComponent(0.42)
        )
    }

    // MARK: - Legacy Color namespace (backward-compatible aliases)

    /// Legacy token namespace. These resolve to ``ColorSystem`` equivalents.
    /// New code should prefer ``ColorSystem``.
    enum Color {
        static let inkPrimary = ColorSystem.inkPrimary
        static let inkSecondary = ColorSystem.inkSecondary
        static let inkMuted = ColorSystem.inkMuted

        /// Was "bright blue"; now action indigo (primary actions, ready state).
        static let sky = ColorSystem.accentAction
        /// Was "light cyan"; now status.active teal.
        static let aqua = ColorSystem.statusActive
        /// Was "soft gold"; now the waypoint amber itself.
        static let amber = ColorSystem.accentWaypoint
        /// Was "deep gold"; identical to ``amber`` in the new system.
        static let amberWaypoint = ColorSystem.accentWaypoint

        static let success = ColorSystem.statusSuccess
        static let warning = ColorSystem.statusWarning
        static let danger = ColorSystem.statusDanger

        /// Legacy overlay token, still white-on-tint for compatibility.
        /// Prefer ``ColorSystem/panel`` or ``ColorSystem/elevated``.
        static let mist = SwiftUI.Color.white.opacity(0.54)
        static let cloud = SwiftUI.Color.white.opacity(0.24)
        static let hairline = ColorSystem.hairline
        static let shadow = ColorSystem.shadow
    }

    enum Status {
        static let ready = ColorSystem.statusReady
        static let active = ColorSystem.statusActive
        static let success = ColorSystem.statusSuccess
        static let warning = ColorSystem.statusWarning
        static let danger = ColorSystem.statusDanger
        static let idle = ColorSystem.statusIdle
    }

    // MARK: - Typography (SF Pro, not SF Rounded)

    /// Semantic typography system. SF Pro (`.default` design) replaces the
    /// previous SF Rounded scale. Sizes and weights are tuned for a pro tool
    /// feel (think Final Cut / Darkroom), not a consumer/health app feel.
    enum Typography {
        /// Large display — run-hero status ("Transferring 248 frames").
        static let display = Font.system(size: 40, weight: .semibold, design: .default)
        /// Section/title headings.
        static let title = Font.system(size: 22, weight: .semibold, design: .default)
        /// Card/panel titles.
        static let cardTitle = Font.system(size: 20, weight: .semibold, design: .default)
        /// Subtitle paragraph copy.
        static let subtitle = Font.system(size: 15, weight: .regular, design: .default)
        /// Default body text.
        static let body = Font.system(size: 13, weight: .regular, design: .default)
        /// Uppercase eyebrow labels.
        static let label = Font.system(size: 12, weight: .medium, design: .default)
        /// Large metric numbers — use with `.monospacedDigit()`.
        static let metric = Font.system(size: 32, weight: .light, design: .default)
        /// Monospaced paths, hashes, console output.
        static let mono = Font.system(size: 12, weight: .regular, design: .monospaced)

        // Legacy aliases
        static let heroTitle = Font.system(size: 34, weight: .semibold, design: .default)
        static let sectionTitle = title
        static let statusValue = Font.system(size: 40, weight: .semibold, design: .default)
        static let metricValue = Font.system(size: 28, weight: .semibold, design: .default)
        static let eyebrow = label
    }

    // MARK: - Surface (legacy; retained for transition)

    enum Surface {
        static let heroGradientStart = Color.mist
        static let heroGradientEnd = Color.cloud
        static let stroke = ColorSystem.hairline
        static let shadowColor = ColorSystem.shadow
    }
}

// MARK: - Dynamic color helper

/// Returns a SwiftUI.Color that resolves differently in light vs dark
/// appearance, without requiring macOS 14's `Color(light:dark:)` initializer.
private func dynamicColor(light: NSColor, dark: NSColor) -> SwiftUI.Color {
    let resolved = NSColor(name: nil) { appearance in
        let match = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight])
        switch match {
        case .darkAqua, .vibrantDark:
            return dark
        default:
            return light
        }
    }
    return SwiftUI.Color(nsColor: resolved)
}

// MARK: - Darkroom view modifier

extension View {
    /// Applies the canvas background + default ink color that the Darkroom
    /// design language assumes. Use on top-level workspace views.
    func darkroom() -> some View {
        self
            .background(DesignTokens.ColorSystem.canvas.ignoresSafeArea())
            .foregroundStyle(DesignTokens.ColorSystem.inkPrimary)
    }
}

import CoreGraphics
import SwiftUI

/// Semantic design tokens for Chronoframe's macOS surfaces.
///
/// The live app stays rooted in native macOS materials and structure, while
/// these tokens provide a restrained Meridian layer for hierarchy, status, and
/// brand consistency.
enum DesignTokens {
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
        static let consoleFontSize: CGFloat = 12
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
        static let hero: CGFloat = 24
        static let card: CGFloat = 20
        static let innerCard: CGFloat = 16
        static let badge: CGFloat = 999
    }

    enum Color {
        static let inkPrimary = SwiftUI.Color(red: 0.14, green: 0.18, blue: 0.24)
        static let inkSecondary = SwiftUI.Color(red: 0.32, green: 0.39, blue: 0.48)
        static let inkMuted = SwiftUI.Color(red: 0.48, green: 0.55, blue: 0.64)

        static let sky = SwiftUI.Color(red: 0.18, green: 0.47, blue: 0.90)
        static let aqua = SwiftUI.Color(red: 0.39, green: 0.74, blue: 0.93)
        static let amber = SwiftUI.Color(red: 0.96, green: 0.72, blue: 0.43)
        static let amberWaypoint = SwiftUI.Color(red: 0.96, green: 0.62, blue: 0.04)

        static let success = SwiftUI.Color(red: 0.18, green: 0.64, blue: 0.39)
        static let warning = SwiftUI.Color(red: 0.85, green: 0.55, blue: 0.18)
        static let danger = SwiftUI.Color(red: 0.84, green: 0.29, blue: 0.26)

        static let mist = SwiftUI.Color.white.opacity(0.54)
        static let cloud = SwiftUI.Color.white.opacity(0.24)
        static let hairline = SwiftUI.Color.white.opacity(0.20)
        static let shadow = SwiftUI.Color.black.opacity(0.08)
    }

    enum Status {
        static let ready = DesignTokens.Color.sky
        static let active = DesignTokens.Color.aqua
        static let success = DesignTokens.Color.success
        static let warning = DesignTokens.Color.warning
        static let danger = DesignTokens.Color.danger
        static let idle = DesignTokens.Color.inkMuted
    }

    enum Typography {
        static let heroTitle = Font.system(size: 34, weight: .bold, design: .rounded)
        static let sectionTitle = Font.system(size: 24, weight: .bold, design: .rounded)
        static let cardTitle = Font.system(size: 20, weight: .semibold, design: .rounded)
        static let metricValue = Font.system(size: 28, weight: .bold, design: .rounded)
        static let statusValue = Font.system(size: 40, weight: .bold, design: .rounded)
        static let eyebrow = Font.system(size: 12, weight: .semibold, design: .rounded)
    }

    enum Surface {
        static let heroGradientStart = DesignTokens.Color.mist
        static let heroGradientEnd = DesignTokens.Color.cloud
        static let stroke = DesignTokens.Color.hairline
        static let shadowColor = DesignTokens.Color.shadow
    }
}

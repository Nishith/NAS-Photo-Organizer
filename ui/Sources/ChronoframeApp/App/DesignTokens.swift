import CoreGraphics

/// Centralised layout constants for Chronoframe's SwiftUI views.
///
/// Using named tokens instead of scattered numeric literals makes design
/// changes a single-file operation and surfaces intent at the call site.
enum DesignTokens {
    enum Layout {
        /// Maximum content width for the main run/progress view.
        static let contentMaxWidth: CGFloat = 1_120
        /// Maximum content width for the setup view.
        static let setupMaxWidth: CGFloat = 1_040
        /// Standard outer padding applied to full-width scroll content.
        static let contentPadding: CGFloat = 24
        /// Padding inside library/setup card sections.
        static let cardPadding: CGFloat = 20
        /// Point size for the monospaced console log font.
        static let consoleFontSize: CGFloat = 12
        /// Minimum height for the console log scroll panel.
        static let consoleMinHeight: CGFloat = 220
        /// Ideal height for the console log scroll panel.
        static let consoleIdealHeight: CGFloat = 280
        /// Diameter of a phase indicator circle.
        static let phaseIndicatorSize: CGFloat = 20
        /// Height of the connector capsule between phase indicator circles.
        static let phaseConnectorHeight: CGFloat = 4
    }

    enum Window {
        static let mainMinWidth:   CGFloat = 860
        static let mainIdealWidth: CGFloat = 1_160
        static let mainMinHeight:   CGFloat = 680
        static let mainIdealHeight: CGFloat = 800

        static let settingsMinWidth:   CGFloat = 420
        static let settingsIdealWidth: CGFloat = 460
        static let settingsMinHeight:   CGFloat = 280
    }

    enum Sidebar {
        static let minWidth:   CGFloat = 220
        static let idealWidth: CGFloat = 250
        static let maxWidth:   CGFloat = 300
    }
}

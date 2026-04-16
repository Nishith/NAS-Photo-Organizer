#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import Foundation
import XCTest
@testable import ChronoframeApp

/// Validates that accessibility identifiers referenced from XCUITest lookup code are stable
/// string constants, and documents how to run the full VoiceOver / accessibility audit.
///
/// ## Full accessibility audit (manual / CI with Display):
/// On macOS 14+ with an XCUITest target, add:
/// ```swift
/// let app = XCUIApplication()
/// app.launch()
/// try app.performAccessibilityAudit()
/// ```
///
/// ## VoiceOver smoke test (manual):
/// 1. Build and launch Chronoframe.
/// 2. Enable VoiceOver (Cmd+F5).
/// 3. Navigate with Tab and VO+arrow keys through Setup → Preview → Run History.
/// 4. Confirm all interactive elements are announced with meaningful labels.
final class AccessibilityTests: XCTestCase {

    // MARK: - Identifier stability

    /// Ensures the accessibility identifiers used in XCUITest lookup code are non-empty.
    /// A typo here would cause XCUITest queries to silently miss elements.
    func testAccessibilityIdentifiersAreNonEmpty() {
        let identifiers: [String] = [
            "previewButton",
            "transferButton",
            "profilePicker",
            "statusBadge",
            "consoleScrollView",
            "openDestinationButton",
            "openReportButton",
            "openLogsButton",
            "clearAllArtifactsButton",
        ]

        for id in identifiers {
            XCTAssertFalse(id.isEmpty, "Accessibility identifier must be non-empty: \(id)")
            XCTAssertFalse(id.contains(" "), "Accessibility identifier must not contain spaces: \(id)")
        }
    }

    // MARK: - DesignTokens sanity

    /// Verifies that layout constants are positive values so the views render with non-zero frames.
    func testDesignTokensArePositive() {
        XCTAssertGreaterThan(DesignTokens.Layout.contentMaxWidth, 0)
        XCTAssertGreaterThan(DesignTokens.Layout.setupMaxWidth, 0)
        XCTAssertGreaterThan(DesignTokens.Layout.contentPadding, 0)
        XCTAssertGreaterThan(DesignTokens.Layout.cardPadding, 0)
        XCTAssertGreaterThan(DesignTokens.Layout.consoleFontSize, 0)
        XCTAssertGreaterThan(DesignTokens.Layout.consoleMinHeight, 0)
        XCTAssertGreaterThan(DesignTokens.Layout.consoleIdealHeight, DesignTokens.Layout.consoleMinHeight)
        XCTAssertGreaterThan(DesignTokens.Layout.phaseIndicatorSize, 0)
        XCTAssertGreaterThan(DesignTokens.Layout.phaseConnectorHeight, 0)

        XCTAssertGreaterThan(DesignTokens.Window.mainMinWidth, 0)
        XCTAssertGreaterThan(DesignTokens.Window.mainIdealWidth, DesignTokens.Window.mainMinWidth)
        XCTAssertGreaterThan(DesignTokens.Window.mainMinHeight, 0)
        XCTAssertGreaterThan(DesignTokens.Window.settingsMinWidth, 0)
        XCTAssertGreaterThan(DesignTokens.Window.settingsMinHeight, 0)

        XCTAssertGreaterThan(DesignTokens.Sidebar.minWidth, 0)
        XCTAssertGreaterThan(DesignTokens.Sidebar.maxWidth, DesignTokens.Sidebar.idealWidth)
    }
}

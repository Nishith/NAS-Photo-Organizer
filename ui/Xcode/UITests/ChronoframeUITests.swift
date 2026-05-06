import XCTest

final class ChronoframeUITests: XCTestCase {
    private enum Scenario: String {
        case setupReady
        case runPreviewReview
        case historyPopulated
        case profilesPopulated
        case settingsSections
        case deduplicateReviewWide
        case deduplicateReviewCompact
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSetupReadyScenarioRendersHeroReadinessAndPrimaryCta() async {
        await MainActor.run {
            let app = Self.launchApp(.setupReady)

            XCTAssertTrue(app.staticTexts["Profiles for Repeatable Runs"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["previewButton"].exists)
            XCTAssertTrue(app.staticTexts["1. Source"].exists)
            XCTAssertTrue(app.staticTexts["2. Destination"].exists)
            XCTAssertTrue(app.staticTexts["Run"].exists)
        }
    }

    func testRunPreviewReviewScenarioShowsTransferArtifactsAndTabs() async {
        await MainActor.run {
            let app = Self.launchApp(.runPreviewReview)

            XCTAssertTrue(app.staticTexts["Preview Ready for Review"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["startTransferFromPreviewButton"].exists)
            XCTAssertTrue(app.buttons["openDestinationButton"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["runWorkspaceTabs"].exists)
            XCTAssertTrue(app.staticTexts["Artifacts"].exists)
        }
    }

    func testHistoryScenarioShowsArchiveSearchAndArtifactActions() async {
        await MainActor.run {
            let app = Self.launchApp(.historyPopulated)

            XCTAssertTrue(app.staticTexts["Reusable Sources"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.searchFields.firstMatch.exists)
            XCTAssertTrue(app.descendants(matching: .any)["historyFilterControl"].exists)
            XCTAssertTrue(app.buttons["useHistoricalSourceButton"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Artifacts"].exists)
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Open")).firstMatch.exists)
        }
    }

    func testProfilesScenarioShowsActiveProfileAndUseAction() async {
        await MainActor.run {
            let app = Self.launchApp(.profilesPopulated)

            XCTAssertTrue(app.staticTexts["Save Current Paths"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.descendants(matching: .any)["profileName-Meridian Travel"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["activeProfileBadge"].exists)
            XCTAssertTrue(app.buttons["Open in Setup"].exists)
            XCTAssertTrue(app.staticTexts["Saved Profiles"].exists)
            XCTAssertTrue(app.buttons["Save"].exists)
        }
    }

    func testSettingsScenarioOpensSectionedSettingsWindow() async {
        await MainActor.run {
            let app = Self.launchApp(.settingsSections)

            XCTAssertTrue(app.windows["com_apple_SwiftUI_Settings_window"].waitForExistence(timeout: 5))
            Self.selectSettingsTab(named: "Performance", in: app)
            XCTAssertTrue(app.staticTexts["Safety"].waitForExistence(timeout: 5))
            Self.selectSettingsTab(named: "Diagnostics", in: app)
            XCTAssertTrue(app.descendants(matching: .any)["diagnosticsLogBufferStepper"].waitForExistence(timeout: 5))
        }
    }

    func testDeduplicateReviewKeepsActionsVisibleAtWideAndCompactSizes() async {
        await MainActor.run {
            for scenario in [Scenario.deduplicateReviewWide, .deduplicateReviewCompact] {
                let app = Self.launchApp(scenario)

                let clusterList = Self.element(identifier: "dedupeReviewClusterList", in: app)
                XCTAssertTrue(clusterList.waitForExistence(timeout: 5), "Cluster list should render for \(scenario.rawValue)")

                let footer = Self.element(identifier: "dedupeCommitFooter", in: app)
                let memberStrip = Self.element(identifier: "dedupeMemberStrip", in: app)
                let acceptCluster = Self.hittableElement(identifier: "dedupeAcceptClusterSuggestionButton", in: app)
                let acceptAll = Self.hittableElement(identifier: "dedupeAcceptAllSuggestionsButton", in: app)
                let commit = Self.hittableElement(identifier: "dedupeCommitButton", in: app)

                XCTAssertTrue(footer.waitForExistence(timeout: 5), "Commit footer should render for \(scenario.rawValue)")
                XCTAssertTrue(memberStrip.waitForExistence(timeout: 5), "Member strip should render for \(scenario.rawValue)")
                XCTAssertTrue(acceptCluster.isHittable, "Accept Suggestion should stay hittable for \(scenario.rawValue)")
                XCTAssertTrue(acceptAll.isHittable, "Accept All Suggestions should stay hittable for \(scenario.rawValue)")
                XCTAssertTrue(commit.isHittable, "Commit should stay hittable for \(scenario.rawValue)")

                let window = app.windows.firstMatch
                XCTAssertTrue(window.exists)
                for element in [clusterList, footer, acceptCluster, acceptAll, commit] {
                    Self.assertFrame(element.frame, isInside: window.frame, scenario: scenario.rawValue)
                }
                XCTAssertLessThanOrEqual(
                    memberStrip.frame.maxY,
                    footer.frame.minY + 1,
                    "Member strip must not overlap the commit footer for \(scenario.rawValue)"
                )

                app.terminate()
            }
        }
    }

    @MainActor
    private static func launchApp(_ scenario: Scenario) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CHRONOFRAME_UI_TEST_SCENARIO"] = scenario.rawValue
        app.launchEnvironment["CHRONOFRAME_UI_TEST_DISABLE_NOTIFICATIONS"] = "1"
        app.launch()
        app.activate()
        ensurePrimaryWindowExists(in: app)
        if scenario == .settingsSections {
            ensureSettingsWindowExists(in: app)
        }
        return app
    }

    @MainActor
    private static func ensurePrimaryWindowExists(in app: XCUIApplication) {
        if app.windows.firstMatch.waitForExistence(timeout: 2) {
            return
        }

        app.typeKey("n", modifierFlags: .command)
        _ = app.windows.firstMatch.waitForExistence(timeout: 5)
    }

    @MainActor
    private static func ensureSettingsWindowExists(in app: XCUIApplication) {
        if app.windows["com_apple_SwiftUI_Settings_window"].waitForExistence(timeout: 2) {
            return
        }

        app.typeKey(",", modifierFlags: .command)
        _ = app.windows["com_apple_SwiftUI_Settings_window"].waitForExistence(timeout: 5)
    }

    @MainActor
    private static func selectSettingsTab(named title: String, in app: XCUIApplication) {
        let tab = matchingElement(named: title, in: app, type: .tab)
        if tab.waitForExistence(timeout: 1) {
            tab.click()
            return
        }

        let radioButton = matchingElement(named: title, in: app, type: .radioButton)
        if radioButton.waitForExistence(timeout: 1) {
            radioButton.click()
            return
        }

        let button = matchingElement(named: title, in: app, type: .button)
        if button.waitForExistence(timeout: 1) {
            button.click()
            return
        }

        let staticText = matchingElement(named: title, in: app, type: .staticText)
        if staticText.waitForExistence(timeout: 1) {
            staticText.click()
            return
        }

        XCTFail("Could not find settings tab named \(title)")
    }

    @MainActor
    private static func matchingElement(
        named title: String,
        in app: XCUIApplication,
        type: XCUIElement.ElementType
    ) -> XCUIElement {
        let predicate = NSPredicate(format: "label == %@", title)
        return app.descendants(matching: type).matching(predicate).firstMatch
    }

    @MainActor
    private static func element(identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private static func hittableElement(identifier: String, in app: XCUIApplication) -> XCUIElement {
        let query = app.descendants(matching: .any).matching(identifier: identifier)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let hittable = query.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) {
                return hittable
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return query.firstMatch
    }

    private static func assertFrame(
        _ frame: CGRect,
        isInside windowFrame: CGRect,
        scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(frame.minX, windowFrame.minX, "Element should not clip left in \(scenario)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, windowFrame.minY, "Element should not clip above the window in \(scenario)", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, windowFrame.maxX, "Element should not clip right in \(scenario)", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, windowFrame.maxY, "Element should not clip below the window in \(scenario)", file: file, line: line)
    }
}

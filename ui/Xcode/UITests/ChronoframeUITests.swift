import XCTest

final class ChronoframeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsSetupWorkspace() {
        let app = XCUIApplication()
        app.launch()

        let setupLabel = app.staticTexts["Setup"]
        XCTAssertTrue(setupLabel.waitForExistence(timeout: 5))
    }
}

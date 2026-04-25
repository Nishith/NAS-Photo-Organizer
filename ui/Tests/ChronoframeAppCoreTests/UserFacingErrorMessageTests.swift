import Foundation
import XCTest
@testable import ChronoframeAppCore

final class UserFacingErrorMessageTests: XCTestCase {
    func testRunContextAddsPlainLanguageAroundUnexpectedErrors() {
        let message = UserFacingErrorMessage.message(
            for: TestFailure.expectedFailure("backend launch failed"),
            context: .run
        )

        XCTAssertTrue(message.contains("Your source files were left untouched"))
        XCTAssertTrue(message.contains("backend launch failed"))
    }

    func testCommonFoundationErrorsExplainMissingFiles() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.Code.fileReadNoSuchFile.rawValue,
            userInfo: [NSFilePathErrorKey: "/Volumes/Card/DCIM"]
        )

        let message = UserFacingErrorMessage.message(for: error, context: .run)

        XCTAssertTrue(message.contains("no longer available"))
        XCTAssertTrue(message.contains("/Volumes/Card/DCIM"))
    }

    func testBackendPromptExplainsMissingSetupInput() {
        let message = UserFacingErrorMessage.backendPrompt(
            "Source and Destination must be provided via --source/--dest or a profile."
        )

        XCTAssertEqual(message, "Choose both a source folder and a destination folder before starting.")
    }

    func testRunIssueMessagesExplainCopyFailureWithoutBlamingTheUser() {
        let message = UserFacingErrorMessage.runIssueMessage(
            "Copy failed: /Volumes/Card/IMG_0001.JPG -> /Volumes/Archive/2026/IMG_0001.JPG: Permission denied",
            severity: .error
        )

        XCTAssertTrue(message.contains("could not copy this file"))
        XCTAssertTrue(message.contains("source was left untouched"))
        XCTAssertTrue(message.contains("Permission denied"))
    }

    func testRunIssueMessagesExplainVerificationFailure() {
        let message = UserFacingErrorMessage.runIssueMessage(
            "Verification failed: /Volumes/Card/IMG_0001.JPG -> /Volumes/Archive/2026/IMG_0001.JPG",
            severity: .error
        )

        XCTAssertTrue(message.contains("could not verify the copy"))
        XCTAssertTrue(message.contains("destination copy was removed"))
        XCTAssertTrue(message.contains("source was left untouched"))
    }
}

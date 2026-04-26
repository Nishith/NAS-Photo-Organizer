import Foundation
import XCTest
@testable import ChronoframeCore
@testable import ChronoframeAppCore

final class UserFacingErrorMessageTests: XCTestCase {
    func testFallbackMessagesAreContextSpecificAndKeepOriginalDetails() {
        let cases: [(UserFacingErrorContext, String)] = [
            (.generic, "Chronoframe ran into a problem"),
            (.setup, "could not update Setup"),
            (.droppedItems, "could not use the dropped items"),
            (.profiles, "could not update saved profiles"),
            (.run, "Your source files were left untouched"),
            (.history, "could not refresh Run History"),
        ]

        for (context, expectedText) in cases {
            let message = UserFacingErrorMessage.message(
                for: TestFailure.expectedFailure("underlying storage error"),
                context: context
            )

            XCTAssertTrue(message.contains(expectedText), message)
            XCTAssertTrue(message.contains("underlying storage error"), message)
        }
    }

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

    func testCommonFoundationErrorsExplainPermissionSpaceAndReadOnlyProblems() {
        let cases: [(NSError, String)] = [
            (
                NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(POSIXErrorCode.EACCES.rawValue),
                    userInfo: [NSFilePathErrorKey: "/Volumes/Card"]
                ),
                "macOS is blocking access"
            ),
            (
                NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(POSIXErrorCode.ENOSPC.rawValue),
                    userInfo: [NSFilePathErrorKey: "/Volumes/Archive"]
                ),
                "out of space"
            ),
            (
                NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(POSIXErrorCode.EROFS.rawValue),
                    userInfo: [NSFilePathErrorKey: "/Volumes/Archive"]
                ),
                "read-only"
            ),
            (
                NSError(
                    domain: NSCocoaErrorDomain,
                    code: CocoaError.Code.fileReadNoPermission.rawValue,
                    userInfo: [NSFilePathErrorKey: "/Volumes/Card"]
                ),
                "macOS is blocking access"
            ),
            (
                NSError(
                    domain: NSCocoaErrorDomain,
                    code: CocoaError.Code.fileWriteOutOfSpace.rawValue,
                    userInfo: [:]
                ),
                "out of space"
            ),
            (
                NSError(
                    domain: NSCocoaErrorDomain,
                    code: CocoaError.Code.fileWriteVolumeReadOnly.rawValue,
                    userInfo: [NSFilePathErrorKey: "/Volumes/Archive"]
                ),
                "read-only"
            ),
            (
                NSError(
                    domain: NSCocoaErrorDomain,
                    code: CocoaError.Code.fileReadCorruptFile.rawValue,
                    userInfo: [NSFilePathErrorKey: "/Volumes/Archive/.organize_cache.db"]
                ),
                "appears to be damaged"
            ),
        ]

        for (error, expectedText) in cases {
            let message = UserFacingErrorMessage.message(for: error, context: .run)

            XCTAssertTrue(message.contains(expectedText), message)
        }
    }

    func testDecodingErrorsExplainSavedFileRecovery() {
        let error = DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "bad json")
        )

        let message = UserFacingErrorMessage.message(for: error, context: .history)

        XCTAssertTrue(message.contains("could not read one of its saved files"), message)
        XCTAssertTrue(message.contains("Run a new preview or transfer"), message)
    }

    func testKnownChronoframeErrorsPassThroughPlainLanguageDescriptions() {
        let cases: [(Error, String)] = [
            (OrganizerEngineError.destinationMissing, "Choose a destination folder"),
            (DroppedItemStagerError.noItems, "Drag files or folders from Finder"),
            (RevertExecutorError.receiptNotFound(path: "/tmp/missing.json"), "could not be found"),
            (ReorganizeExecutorError.destinationNotADirectory(path: "/tmp/file.jpg"), "not a folder"),
            (OrganizerDatabaseError.databaseClosed, "lost access to its transfer queue"),
        ]

        for (error, expectedText) in cases {
            let message = UserFacingErrorMessage.message(for: error, context: .generic)

            XCTAssertTrue(message.contains(expectedText), message)
        }
    }

    func testBackendPromptExplainsMissingSetupInput() {
        let message = UserFacingErrorMessage.backendPrompt(
            "Source and Destination must be provided via --source/--dest or a profile."
        )

        XCTAssertEqual(message, "Choose both a source folder and a destination folder before starting.")
    }

    func testBackendPromptExplainsEmptyNoMediaAndUnknownMessages() {
        XCTAssertEqual(
            UserFacingErrorMessage.backendPrompt("   \n "),
            "Chronoframe needs one more choice before it can continue. Review Setup, then try again."
        )

        let noMediaMessage = UserFacingErrorMessage.backendPrompt("No valid media files found in source")
        XCTAssertTrue(noMediaMessage.contains("supported photo or video files"), noMediaMessage)

        let unknownMessage = UserFacingErrorMessage.backendPrompt("Profile file is locked")
        XCTAssertTrue(unknownMessage.contains("needs attention"), unknownMessage)
        XCTAssertTrue(unknownMessage.contains("Profile file is locked"), unknownMessage)
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

    func testRunIssueMessagesExplainEmptyIssuesBySeverity() {
        XCTAssertEqual(
            UserFacingErrorMessage.runIssueMessage(" ", severity: .info),
            "Chronoframe reported an update."
        )
        XCTAssertEqual(
            UserFacingErrorMessage.runIssueMessage(" ", severity: .warning),
            "Chronoframe reported a warning, but did not include details."
        )
        XCTAssertEqual(
            UserFacingErrorMessage.runIssueMessage(" ", severity: .error),
            "Chronoframe reported a problem, but did not include details."
        )
    }

    func testRunIssueMessagesCoverKnownBackendPatterns() {
        let cases: [(String, RunSeverity, [String])] = [
            (
                "Source and Destination must be provided",
                .error,
                ["Choose both a source folder", "destination folder"]
            ),
            (
                "No valid media files found in source",
                .warning,
                ["did not find supported photo or video files"]
            ),
            (
                "Unexpected hash error for /Volumes/Card/IMG_0001.JPG: read failed",
                .warning,
                ["could not check this file", "/Volumes/Card/IMG_0001.JPG", "read failed"]
            ),
            (
                "Receipt not found: /Volumes/Archive/.organize_logs/audit_receipt.json",
                .error,
                ["selected revert receipt could not be found"]
            ),
            (
                "Invalid receipt: Malformed JSON at line 1",
                .error,
                ["could not read this revert receipt", "Malformed JSON"]
            ),
            (
                "Could not remove /Volumes/Archive/IMG_0001.JPG: Permission denied",
                .warning,
                ["could not remove this copied file", "Permission denied"]
            ),
            (
                "Could not re-hash /Volumes/Archive/IMG_0001.JPG: Permission denied",
                .warning,
                ["could not check whether this file changed", "Permission denied"]
            ),
            (
                "Preserved (modified since copy): /Volumes/Archive/IMG_0001.JPG",
                .warning,
                ["kept this file because it has changed"]
            ),
            (
                "Source no longer exists: /Volumes/Archive/IMG_0001.JPG",
                .warning,
                ["file disappeared before Chronoframe could move it"]
            ),
            (
                "Destination exists, skipping: /Volumes/Archive/IMG_0001.JPG",
                .warning,
                ["file already exists at the new location"]
            ),
            (
                "Could not move /Volumes/Archive/IMG_0001.JPG: Permission denied",
                .warning,
                ["could not move this file inside the destination", "Permission denied"]
            ),
            (
                "Cleaned 2 orphaned .tmp files",
                .info,
                ["temporary files left by an interrupted run"]
            ),
        ]

        for (input, severity, expectedParts) in cases {
            let message = UserFacingErrorMessage.runIssueMessage(input, severity: severity)

            for expectedPart in expectedParts {
                XCTAssertTrue(message.contains(expectedPart), message)
            }
        }
    }

    func testRunIssueMessageParsingHandlesMalformedPayloadsWithoutTechnicalFallbacks() {
        let verificationMessage = UserFacingErrorMessage.runIssueMessage(
            "Verification failed: /Volumes/Card/IMG_0001.JPG",
            severity: .error
        )
        XCTAssertTrue(verificationMessage.contains("Source: /Volumes/Card/IMG_0001.JPG"), verificationMessage)
        XCTAssertTrue(verificationMessage.contains("Destination: unknown"), verificationMessage)

        let copyMessage = UserFacingErrorMessage.runIssueMessage(
            "Copy failed: /Volumes/Card/IMG_0001.JPG",
            severity: .error
        )
        XCTAssertTrue(copyMessage.contains("Destination: unknown"), copyMessage)

        let hashMessage = UserFacingErrorMessage.runIssueMessage(
            "Unexpected hash error for /Volumes/Card/IMG_0001.JPG",
            severity: .warning
        )
        XCTAssertTrue(hashMessage.contains("could not check this file"), hashMessage)
        XCTAssertFalse(hashMessage.contains("Details:"), hashMessage)

        let moveMessage = UserFacingErrorMessage.runIssueMessage(
            "Could not move : Permission denied",
            severity: .warning
        )
        XCTAssertTrue(moveMessage.contains("File: : Permission denied"), moveMessage)
        XCTAssertFalse(moveMessage.contains("Details:"), moveMessage)
    }

    func testWithDetailsSkipsEmptyAndDuplicateDetails() {
        XCTAssertEqual(
            UserFacingErrorMessage.withDetails("Try again.", details: "  "),
            "Try again."
        )
        XCTAssertEqual(
            UserFacingErrorMessage.withDetails("Try again.", details: "Try again."),
            "Try again."
        )
        XCTAssertEqual(
            UserFacingErrorMessage.withDetails("Try again.", details: "Disk is full"),
            "Try again. Details: Disk is full"
        )
    }
}

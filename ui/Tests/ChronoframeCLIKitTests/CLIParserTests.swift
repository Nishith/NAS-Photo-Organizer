import ChronoframeCLIKit
import ChronoframeCore
import XCTest

final class CLIParserTests: XCTestCase {
    func testParsesTransferOptions() throws {
        let options = try CLIParser.parse([
            "--source", "/photos/in",
            "--dest", "/photos/out",
            "--skip-verify",
            "--workers", "4",
            "--folder-structure", "YYYY/MM",
            "--json",
            "--yes",
        ])

        XCTAssertEqual(options.sourcePath, "/photos/in")
        XCTAssertEqual(options.destinationPath, "/photos/out")
        XCTAssertFalse(options.verifyCopies)
        XCTAssertEqual(options.workerCount, 4)
        XCTAssertEqual(options.folderStructure, .yyyyMM)
        XCTAssertTrue(options.jsonOutput)
        XCTAssertTrue(options.assumeYes)
        XCTAssertEqual(options.mode, .transfer)
    }

    func testParsesProfilePreview() throws {
        let options = try CLIParser.parse(["--profile", "travel", "--dry-run"])

        XCTAssertEqual(options.profileName, "travel")
        XCTAssertTrue(options.dryRun)
        XCTAssertEqual(options.mode, .preview)
    }

    func testParsesDefaultWorkerCountWithoutExplicitWorkerFlag() throws {
        let options = try CLIParser.parse(["--source", "/photos/in", "--dest", "/photos/out"])

        XCTAssertEqual(options.workerCount, CLIOptions.defaultWorkerCount)
    }

    func testParsesRevertWithBoundaryOverride() throws {
        let options = try CLIParser.parse(["--revert", "/tmp/receipt.json", "--dest", "/tmp/destination"])

        XCTAssertEqual(options.revertReceiptPath, "/tmp/receipt.json")
        XCTAssertEqual(options.destinationPath, "/tmp/destination")
        XCTAssertEqual(options.mode, .revert)
    }

    func testRejectsNormalRunWithoutSourceDestinationOrProfile() {
        XCTAssertThrowsError(try CLIParser.parse(["--dry-run"])) { error in
            XCTAssertEqual(error as? CLIError, .usage("Provide --source and --dest, or use --profile."))
        }
    }

    func testRejectsUnsupportedFolderStructure() {
        XCTAssertThrowsError(
            try CLIParser.parse(["--source", "/in", "--dest", "/out", "--folder-structure", "Month"])
        ) { error in
            XCTAssertEqual(error as? CLIError, .usage("Unsupported folder structure: Month."))
        }
    }

    func testRejectsRevertWithNormalRunOptions() {
        XCTAssertThrowsError(
            try CLIParser.parse(["--revert", "/tmp/receipt.json", "--source", "/in"])
        ) { error in
            XCTAssertEqual(
                error as? CLIError,
                .usage("--revert can be combined only with --dest, --json, --workers, and --yes.")
            )
        }
    }
}

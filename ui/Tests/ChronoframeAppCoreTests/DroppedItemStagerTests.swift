import Foundation
import XCTest
@testable import ChronoframeAppCore

final class DroppedItemStagerTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var stagingRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroppedItemStagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        stagingRoot = temporaryDirectory.appendingPathComponent("drops", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        stagingRoot = nil
        try super.tearDownWithError()
    }

    func testStageSingleFolderReturnsFolderWithoutCreatingStagingDirectory() throws {
        let folder = temporaryDirectory.appendingPathComponent("Camera Roll", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let stager = DroppedItemStager(stagingRoot: stagingRoot)
        let result = try stager.stage(urls: [folder])

        XCTAssertEqual(result.sourceDirectory, folder.standardizedFileURL)
        XCTAssertTrue(result.wasSingleFolder)
        XCTAssertEqual(result.itemCount, 1)
        XCTAssertEqual(result.displayLabel, folder.standardizedFileURL.path)
        XCTAssertFalse(stager.isStagingPath(result.sourceDirectory.path))
    }

    func testStageFilesCreatesSymlinkSourceWithUniqueNamesAndHumanLabel() throws {
        let firstFolder = temporaryDirectory.appendingPathComponent("A", isDirectory: true)
        let secondFolder = temporaryDirectory.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        let firstPhoto = firstFolder.appendingPathComponent("IMG_0001.JPG")
        let secondPhoto = secondFolder.appendingPathComponent("IMG_0001.JPG")
        try Data([0x01]).write(to: firstPhoto)
        try Data([0x02]).write(to: secondPhoto)

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let stager = DroppedItemStager(stagingRoot: stagingRoot)
        let result = try stager.stage(
            urls: [firstPhoto, secondPhoto, firstPhoto, temporaryDirectory.appendingPathComponent("missing.jpg")],
            at: date
        )

        XCTAssertTrue(result.wasSingleFolder == false)
        XCTAssertEqual(result.itemCount, 2)
        XCTAssertTrue(stager.isStagingPath(result.sourceDirectory.path))
        XCTAssertTrue(result.displayLabel.contains("2 items"))

        let stagedNames = try FileManager.default.contentsOfDirectory(atPath: result.sourceDirectory.path).sorted()
        XCTAssertEqual(stagedNames, ["IMG_0001 (2).JPG", "IMG_0001.JPG"])

        let firstDestination = try FileManager.default.destinationOfSymbolicLink(
            atPath: result.sourceDirectory.appendingPathComponent("IMG_0001.JPG").path
        )
        let secondDestination = try FileManager.default.destinationOfSymbolicLink(
            atPath: result.sourceDirectory.appendingPathComponent("IMG_0001 (2).JPG").path
        )
        XCTAssertEqual(URL(fileURLWithPath: firstDestination).standardizedFileURL, firstPhoto.standardizedFileURL)
        XCTAssertEqual(URL(fileURLWithPath: secondDestination).standardizedFileURL, secondPhoto.standardizedFileURL)
    }

    func testStageThrowsNoItemsForEmptyOrMissingDrops() throws {
        let stager = DroppedItemStager(stagingRoot: stagingRoot)
        XCTAssertThrowsError(try stager.stage(urls: [])) { error in
            XCTAssertTrue(error is DroppedItemStagerError)
            XCTAssertEqual(error.localizedDescription, DroppedItemStagerError.noItems.localizedDescription)
        }

        XCTAssertThrowsError(
            try stager.stage(urls: [temporaryDirectory.appendingPathComponent("missing.jpg")])
        ) { error in
            XCTAssertEqual(error.localizedDescription, DroppedItemStagerError.noItems.localizedDescription)
        }
    }

    func testCleanupOnlyRemovesStagingPaths() throws {
        let stagedFolder = stagingRoot
            .appendingPathComponent("drop-test", isDirectory: true)
        let externalFolder = temporaryDirectory.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalFolder, withIntermediateDirectories: true)

        let stager = DroppedItemStager(stagingRoot: stagingRoot)
        stager.cleanup(stagingDirectory: externalFolder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalFolder.path))

        stager.cleanup(stagingDirectory: stagedFolder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedFolder.path))
    }

    func testCleanupAllStagingDirectoriesRemovesStagingRoot() throws {
        let marker = stagingRoot
            .appendingPathComponent("drop-test", isDirectory: true)
            .appendingPathComponent("marker")
        try FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: marker)

        DroppedItemStager(stagingRoot: stagingRoot).cleanupAllStagingDirectories()

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingRoot.path))
    }
}

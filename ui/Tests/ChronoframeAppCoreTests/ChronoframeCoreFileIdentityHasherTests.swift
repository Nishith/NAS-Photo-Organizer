import Foundation
import XCTest
@testable import ChronoframeCore

final class ChronoframeCoreFileIdentityHasherTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChronoframeCoreFileIdentityHasherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        try super.tearDownWithError()
    }

    func testHashIdentityMatchesPythonFastHashReference() throws {
        let fileURL = try writeFile(named: "alpha.jpg", contents: "alpha")

        let identity = try FileIdentityHasher().hashIdentity(at: fileURL)

        XCTAssertEqual(
            identity.rawValue,
            "5_1a486e31c373793e04ad3981405201d7b52e8e85c07bcc79c51704918e6a1a311dc9ceebba0eb132e2d638b3ae09fd4ad9913a75674f59fabf5287fa0c436fd6"
        )
    }

    func testProcessFileReusesCachedIdentityWhenSizeAndMtimeMatch() throws {
        let fileURL = try writeFile(named: "cached.mov", contents: "alpha")
        let metadata = try fileMetadata(for: fileURL)
        let cachedRecord = FileCacheRecord(
            namespace: .source,
            path: fileURL.path,
            identity: FileIdentity(size: 5, digest: "cached-digest"),
            size: metadata.size,
            modificationTime: metadata.modificationTime
        )

        let outcome = FileIdentityHasher().processFile(at: fileURL.path, cachedRecord: cachedRecord)

        XCTAssertEqual(outcome.identity, cachedRecord.identity)
        XCTAssertEqual(outcome.size, metadata.size)
        XCTAssertEqual(outcome.modificationTime, metadata.modificationTime, accuracy: 0.000_1)
        XCTAssertFalse(outcome.wasHashed)
    }

    func testProcessFileRehashesWhenMetadataChanges() throws {
        let fileURL = try writeFile(named: "rehash.jpg", contents: "alpha")
        let staleRecord = FileCacheRecord(
            namespace: .source,
            path: fileURL.path,
            identity: FileIdentity(size: 5, digest: "stale"),
            size: 5,
            modificationTime: 0
        )

        let outcome = FileIdentityHasher().processFile(at: fileURL.path, cachedRecord: staleRecord)

        XCTAssertTrue(outcome.wasHashed)
        XCTAssertEqual(
            outcome.identity?.rawValue,
            "5_1a486e31c373793e04ad3981405201d7b52e8e85c07bcc79c51704918e6a1a311dc9ceebba0eb132e2d638b3ae09fd4ad9913a75674f59fabf5287fa0c436fd6"
        )
    }

    func testProcessFileReturnsMissingResultForUnreadablePath() {
        let outcome = FileIdentityHasher().processFile(
            at: temporaryDirectoryURL.appendingPathComponent("missing.jpg").path,
            cachedRecord: nil
        )

        XCTAssertNil(outcome.identity)
        XCTAssertEqual(outcome.size, 0)
        XCTAssertEqual(outcome.modificationTime, 0)
        XCTAssertFalse(outcome.wasHashed)
    }

    private func writeFile(named name: String, contents: String) throws -> URL {
        let fileURL = temporaryDirectoryURL.appendingPathComponent(name)
        try Data(contents.utf8).write(to: fileURL)
        return fileURL
    }

    private func fileMetadata(for url: URL) throws -> (size: Int64, modificationTime: TimeInterval) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modificationTime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return (size, modificationTime)
    }
}

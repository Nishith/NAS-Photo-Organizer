import Foundation
import XCTest
@testable import ChronoframeCore

final class ChronoframeCoreDryRunPlannerParityTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChronoframeCoreDryRunPlannerParityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        try super.tearDownWithError()
    }

    func testPlanningFixturesMatchPythonGoldenOutputs() throws {
        for scenario in [
            "planning_fast_dest_cache_reuse",
            "planning_mixed_inputs",
            "planning_sequence_overflow",
            "planning_sequence_reuse",
            "planning_layout_yyyy_mm",
            "planning_layout_yyyy",
            "planning_layout_yyyy_mon_event",
            "planning_layout_flat",
        ] {
            try assertScenario(named: scenario)
        }
    }

    func testPlannerUsesWideSequenceForGreenfieldCrowdedDayWithInfoAndHistogram() throws {
        let sourceRoot = temporaryDirectoryURL.appendingPathComponent("crowded-source", isDirectory: true)
        let destinationRoot = temporaryDirectoryURL.appendingPathComponent("crowded-dest", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        for index in 1...1_001 {
            let fileURL = sourceRoot.appendingPathComponent(
                String(format: "batch/IMG_20260419_%06d.jpg", index)
            )
            try writeMediaFile(at: fileURL, contents: "source-\(index)")
        }

        let result = try DryRunPlanner().plan(sourceRoot: sourceRoot, destinationRoot: destinationRoot)
        let destinations = result.copyJobs.map(\.destinationPath)

        XCTAssertEqual(destinations.first, destinationRoot.appendingPathComponent("2026/04/19/2026-04-19_0001.jpg").path)
        XCTAssertEqual(destinations[998], destinationRoot.appendingPathComponent("2026/04/19/2026-04-19_0999.jpg").path)
        XCTAssertEqual(destinations[999], destinationRoot.appendingPathComponent("2026/04/19/2026-04-19_1000.jpg").path)
        XCTAssertEqual(destinations.last, destinationRoot.appendingPathComponent("2026/04/19/2026-04-19_1001.jpg").path)
        XCTAssertEqual(result.warningMessages, [])
        XCTAssertEqual(
            result.infoMessages,
            ["Day 2026-04-19: 1,001 files — using 4-digit sequence numbers."]
        )
        XCTAssertEqual(result.dateHistogram, [DateHistogramBucket(key: "2026-04", plannedCount: 1_001)])
    }

    func testPlannerWarnsOnlyWhenExistingDateCrossesSequenceWidth() throws {
        let sourceRoot = temporaryDirectoryURL.appendingPathComponent("crossing-source", isDirectory: true)
        let destinationRoot = temporaryDirectoryURL.appendingPathComponent("crossing-dest", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        try writeMediaFile(
            at: destinationRoot.appendingPathComponent("2024/02/14/2024-02-14_999.jpg"),
            contents: "existing"
        )
        try writeMediaFile(
            at: sourceRoot.appendingPathComponent("batch/IMG_20240214_230000.jpg"),
            contents: "new"
        )

        let result = try DryRunPlanner().plan(sourceRoot: sourceRoot, destinationRoot: destinationRoot)

        XCTAssertEqual(
            result.copyJobs.map(\.destinationPath),
            [destinationRoot.appendingPathComponent("2024/02/14/2024-02-14_1000.jpg").path]
        )
        XCTAssertEqual(result.infoMessages, [])
        XCTAssertEqual(result.warningMessages, ["Sequence overflow on dates (>999 files/day): 2024-02-14"])
    }

    func testPlannerUsesWideSequenceForCrowdedDuplicateBucket() throws {
        let sourceRoot = temporaryDirectoryURL.appendingPathComponent("duplicate-source", isDirectory: true)
        let destinationRoot = temporaryDirectoryURL.appendingPathComponent("duplicate-dest", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        for index in 0...1_000 {
            let fileURL = sourceRoot.appendingPathComponent(
                String(format: "dups/IMG_20260419_%06d.jpg", index)
            )
            try writeMediaFile(at: fileURL, contents: "same")
        }

        let result = try DryRunPlanner().plan(sourceRoot: sourceRoot, destinationRoot: destinationRoot)
        let duplicateDestinations = result.transfers
            .filter(\.isDuplicate)
            .map(\.destinationPath)

        XCTAssertEqual(result.counts.newCount, 1)
        XCTAssertEqual(result.counts.duplicateCount, 1_000)
        XCTAssertEqual(duplicateDestinations.first, destinationRoot.appendingPathComponent("Duplicate/2026/04/19/2026-04-19_0001.jpg").path)
        XCTAssertEqual(duplicateDestinations[998], destinationRoot.appendingPathComponent("Duplicate/2026/04/19/2026-04-19_0999.jpg").path)
        XCTAssertEqual(duplicateDestinations[999], destinationRoot.appendingPathComponent("Duplicate/2026/04/19/2026-04-19_1000.jpg").path)
        XCTAssertEqual(result.dateHistogram, [DateHistogramBucket(key: "2026-04", plannedCount: 1_001)])
    }

    func testPlannerDateHistogramIncludesDatedAndUnknownTransfers() throws {
        let sourceRoot = temporaryDirectoryURL.appendingPathComponent("histogram-source", isDirectory: true)
        let destinationRoot = temporaryDirectoryURL.appendingPathComponent("histogram-dest", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        try writeMediaFile(at: sourceRoot.appendingPathComponent("b/IMG_20260201_010101.jpg"), contents: "feb")
        try writeMediaFile(at: sourceRoot.appendingPathComponent("a/IMG_20260131_010101.jpg"), contents: "jan")
        try writeMediaFile(at: sourceRoot.appendingPathComponent("unknown/orphan.jpg"), contents: "unknown")

        let result = try DryRunPlanner(
            dateResolver: FileDateResolver(metadataReader: NoDateMetadataReader())
        ).plan(sourceRoot: sourceRoot, destinationRoot: destinationRoot)

        XCTAssertEqual(
            result.dateHistogram,
            [
                DateHistogramBucket(key: "2026-01", plannedCount: 1),
                DateHistogramBucket(key: "2026-02", plannedCount: 1),
                DateHistogramBucket(key: "Unknown", plannedCount: 1),
            ]
        )
    }

    private func assertScenario(named scenario: String) throws {
        let scenarioRoot = fixtureRoot.appendingPathComponent(scenario, isDirectory: true)
        let manifest = try decode(Manifest.self, from: scenarioRoot.appendingPathComponent("manifest.json"))
        let expected = try decode(ExpectedOutput.self, from: scenarioRoot.appendingPathComponent("expected.json"))

        let scenarioTempRoot = temporaryDirectoryURL.appendingPathComponent(scenario, isDirectory: true)
        let sourceRoot = scenarioTempRoot.appendingPathComponent("source", isDirectory: true)
        let destinationRoot = scenarioTempRoot.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        for file in manifest.files {
            let root = file.root == "source" ? sourceRoot : destinationRoot
            let fileURL = root.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((file.contentText ?? "").utf8).write(to: fileURL)

            if let mtimeEpoch = file.mtimeEpoch {
                let timestamp = Date(timeIntervalSince1970: mtimeEpoch)
                try FileManager.default.setAttributes(
                    [.modificationDate: timestamp, .creationDate: timestamp],
                    ofItemAtPath: fileURL.path
                )
            }
        }

        if let seedRows = manifest.seedDestinationCache {
            let databaseURL = destinationRoot.appendingPathComponent(EngineArtifactLayout.pythonReference.queueDatabaseFilename)
            let database = try OrganizerDatabase(url: databaseURL)
            defer { database.close() }

            var records: [FileCacheRecord] = []
            for row in seedRows {
                records.append(
                    FileCacheRecord(
                        namespace: .destination,
                        path: resolveFixturePath(row.path, sourceRoot: sourceRoot, destinationRoot: destinationRoot).path,
                        identity: try resolveHash(
                            row.hash,
                            size: row.size,
                            sourceRoot: sourceRoot,
                            destinationRoot: destinationRoot
                        ),
                        size: row.size,
                        modificationTime: row.mtime
                    )
                )
            }
            try database.saveCacheRecords(records)
        }

        let folderStructure = manifest.folderStructure.flatMap(FolderStructure.init(rawValue:)) ?? .yyyyMMDD
        let result = try DryRunPlanner().plan(
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            fastDestination: manifest.fastDest ?? false,
            folderStructure: folderStructure
        )

        XCTAssertEqual(result.phaseSequence, expected.phaseSequence, scenario)
        XCTAssertEqual(result.discoveredSourceCount, expected.counts.discoveryFound, scenario)
        XCTAssertEqual(result.destinationIndexedCount, expected.counts.destHashTotal, scenario)
        XCTAssertEqual(result.sourceHashedCount, expected.counts.srcHashTotal, scenario)
        XCTAssertEqual(result.counts.alreadyInDestinationCount, expected.counts.classificationAlreadyInDestination, scenario)
        XCTAssertEqual(result.counts.newCount, expected.counts.classificationNew, scenario)
        XCTAssertEqual(result.counts.duplicateCount, expected.counts.classificationDuplicates, scenario)
        XCTAssertEqual(result.counts.hashErrorCount, expected.counts.classificationErrors, scenario)
        XCTAssertEqual(result.copyJobs.count, expected.counts.copyPlanReady, scenario)
        XCTAssertEqual(result.completeStatus, expected.counts.completeStatus, scenario)
        XCTAssertEqual(result.warningMessages, expected.warningMessages, scenario)

        XCTAssertEqual(
            normalize(result.copyJobs, sourceRoot: sourceRoot, destinationRoot: destinationRoot),
            expected.reportRows,
            scenario
        )
    }

    private func resolveHash(
        _ spec: String,
        size: Int64,
        sourceRoot: URL,
        destinationRoot: URL
    ) throws -> FileIdentity {
        if spec.hasPrefix("actual:") {
            let path = resolveFixturePath(String(spec.dropFirst("actual:".count)), sourceRoot: sourceRoot, destinationRoot: destinationRoot)
            return try FileIdentityHasher().hashIdentity(at: path)
        }

        if let identity = FileIdentity(rawValue: spec) {
            return identity
        }

        return FileIdentity(size: size, digest: spec)
    }

    private func resolveFixturePath(_ spec: String, sourceRoot: URL, destinationRoot: URL) -> URL {
        if spec.hasPrefix("source/") {
            return sourceRoot.appendingPathComponent(String(spec.dropFirst("source/".count)))
        }
        if spec.hasPrefix("dest/") {
            return destinationRoot.appendingPathComponent(String(spec.dropFirst("dest/".count)))
        }
        return destinationRoot.appendingPathComponent(spec)
    }

    private func normalize(
        _ rows: [CopyJobRecord],
        sourceRoot: URL,
        destinationRoot: URL
    ) -> [ExpectedReportRow] {
        rows.map {
            ExpectedReportRow(
                source: normalizePath($0.sourcePath, sourceRoot: sourceRoot, destinationRoot: destinationRoot),
                destination: normalizePath($0.destinationPath, sourceRoot: sourceRoot, destinationRoot: destinationRoot),
                hash: $0.identity.rawValue,
                status: $0.status.rawValue
            )
        }
    }

    private func normalizePath(_ path: String, sourceRoot: URL, destinationRoot: URL) -> String {
        let resolvedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let sourcePrefix = sourceRoot.standardizedFileURL.path + "/"
        if resolvedPath.hasPrefix(sourcePrefix) {
            return "source/" + String(resolvedPath.dropFirst(sourcePrefix.count))
        }

        let destinationPrefix = destinationRoot.standardizedFileURL.path + "/"
        if resolvedPath.hasPrefix(destinationPrefix) {
            return "dest/" + String(resolvedPath.dropFirst(destinationPrefix.count))
        }

        return path
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(type, from: data)
    }

    private func writeMediaFile(at url: URL, contents: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private var fixtureRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures/parity", isDirectory: true)
    }
}

private struct Manifest: Decodable {
    var fastDest: Bool?
    var files: [ManifestFile]
    var seedDestinationCache: [SeedDestinationCacheRow]?
    var folderStructure: String?

    private enum CodingKeys: String, CodingKey {
        case fastDest = "fast_dest"
        case files
        case seedDestinationCache = "seed_destination_cache"
        case folderStructure = "folder_structure"
    }
}

private struct ManifestFile: Decodable {
    var root: String
    var path: String
    var contentText: String?
    var mtimeEpoch: Double?

    private enum CodingKeys: String, CodingKey {
        case root
        case path
        case contentText = "content_text"
        case mtimeEpoch = "mtime_epoch"
    }
}

private struct SeedDestinationCacheRow: Decodable {
    var path: String
    var hash: String
    var size: Int64
    var mtime: TimeInterval
}

private struct ExpectedOutput: Decodable, Equatable {
    var phaseSequence: [String]
    var counts: ExpectedCounts
    var warningMessages: [String]
    var reportRows: [ExpectedReportRow]

    private enum CodingKeys: String, CodingKey {
        case phaseSequence = "phase_sequence"
        case counts
        case warningMessages = "warning_messages"
        case reportRows = "report_rows"
    }
}

private struct ExpectedCounts: Decodable, Equatable {
    var discoveryFound: Int
    var destHashTotal: Int
    var srcHashTotal: Int
    var classificationAlreadyInDestination: Int
    var classificationNew: Int
    var classificationDuplicates: Int
    var classificationErrors: Int
    var copyPlanReady: Int
    var completeStatus: String

    private enum CodingKeys: String, CodingKey {
        case discoveryFound = "discovery_found"
        case destHashTotal = "dest_hash_total"
        case srcHashTotal = "src_hash_total"
        case classificationAlreadyInDestination = "classification_already_in_dst"
        case classificationNew = "classification_new"
        case classificationDuplicates = "classification_dups"
        case classificationErrors = "classification_errors"
        case copyPlanReady = "copy_plan_ready"
        case completeStatus = "complete_status"
    }
}

private struct ExpectedReportRow: Decodable, Equatable {
    var source: String
    var destination: String
    var hash: String
    var status: String
}

private struct NoDateMetadataReader: MediaMetadataDateReading {
    func photoMetadataDate(at url: URL) -> Date? { nil }
    func fileSystemCreationDate(at url: URL) -> Date? { nil }
    func fileSystemModificationDate(at url: URL) -> Date? { nil }
}

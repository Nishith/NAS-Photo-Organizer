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

    func testPlannerAppliesReviewOverridesToDateAndEventPath() throws {
        let sourceRoot = temporaryDirectoryURL.appendingPathComponent("override-source", isDirectory: true)
        let destinationRoot = temporaryDirectoryURL.appendingPathComponent("override-dest", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let sourceFile = sourceRoot.appendingPathComponent("DCIM/orphan.jpg")
        try writeMediaFile(at: sourceFile, contents: "override-me")
        let identity = try FileIdentityHasher().hashIdentity(at: sourceFile)
        let databaseURL = destinationRoot.appendingPathComponent(EngineArtifactLayout.pythonReference.queueDatabaseFilename)
        let database = try OrganizerDatabase(url: databaseURL)
        try database.saveReviewOverride(
            ReviewOverride(
                identity: identity,
                sourcePath: sourceFile.path,
                captureDate: makeDate("2024-04-30"),
                eventName: "April Trip"
            )
        )
        XCTAssertEqual(try database.loadReviewOverrides().map(\.identity), [identity])
        database.close()

        let result = try DryRunPlanner(
            dateResolver: FileDateResolver(metadataReader: NoDateMetadataReader())
        ).plan(
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            folderStructure: .yyyyMonEvent,
            eventSuggestionMode: .suggest
        )

        XCTAssertEqual(result.previewReviewItems.first?.identityRawValue, identity.rawValue)
        XCTAssertEqual(URL(fileURLWithPath: result.previewReviewItems.first?.sourcePath ?? "").standardizedFileURL.path, sourceFile.standardizedFileURL.path)
        XCTAssertEqual(
            result.copyJobs.map(\.destinationPath),
            [destinationRoot.appendingPathComponent("2024/Apr/April Trip/2024-04-30_001.jpg").path]
        )
        let reviewItem = try XCTUnwrap(result.previewReviewItems.first)
        XCTAssertEqual(reviewItem.dateSource, .userOverride)
        XCTAssertEqual(reviewItem.dateConfidence, .high)
        XCTAssertEqual(reviewItem.acceptedEventName, "April Trip")
        XCTAssertNil(reviewItem.eventSuggestion)
        XCTAssertEqual(reviewItem.issues, [])
    }

    func testPlannerAddsSmartEventSuggestionsWithoutApplyingThem() throws {
        let sourceRoot = temporaryDirectoryURL.appendingPathComponent("event-source", isDirectory: true)
        let destinationRoot = temporaryDirectoryURL.appendingPathComponent("event-dest", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        try writeMediaFile(at: sourceRoot.appendingPathComponent("Beach Day/IMG_20240501_090000.jpg"), contents: "a")
        try writeMediaFile(at: sourceRoot.appendingPathComponent("Beach Day/IMG_20240501_100000.jpg"), contents: "b")

        let result = try DryRunPlanner().plan(
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            folderStructure: .yyyyMonEvent,
            eventSuggestionMode: .suggest
        )

        XCTAssertEqual(
            result.copyJobs.map { URL(fileURLWithPath: $0.destinationPath).pathComponents.suffix(2).first },
            ["Beach Day", "Beach Day"],
            "Suggestions are review metadata only; existing source-folder event routing remains the applied path until the user saves an override."
        )
        XCTAssertEqual(Set(result.previewReviewItems.compactMap(\.eventSuggestion?.suggestedName)), ["Beach Day"])
        XCTAssertEqual(result.previewReviewSummary.readyCount, 2)
    }

    func testPlannerMultiWorkerOutputMatchesSerialOutputAndCacheRows() throws {
        let serialRoots = try makeConcurrencyScenario(named: "serial")
        let parallelRoots = try makeConcurrencyScenario(named: "parallel")
        let planner = DryRunPlanner(
            dateResolver: FileDateResolver(metadataReader: NoDateMetadataReader())
        )

        let serial = try planner.plan(
            sourceRoot: serialRoots.source,
            destinationRoot: serialRoots.destination,
            workerCount: 1
        )
        let parallel = try planner.plan(
            sourceRoot: parallelRoots.source,
            destinationRoot: parallelRoots.destination,
            workerCount: 4
        )

        XCTAssertEqual(serial.counts, parallel.counts)
        XCTAssertEqual(serial.dateHistogram, parallel.dateHistogram)
        XCTAssertEqual(serial.warningMessages, parallel.warningMessages)
        XCTAssertEqual(serial.infoMessages, parallel.infoMessages)
        XCTAssertEqual(
            normalize(serial.copyJobs, sourceRoot: serialRoots.source, destinationRoot: serialRoots.destination),
            normalize(parallel.copyJobs, sourceRoot: parallelRoots.source, destinationRoot: parallelRoots.destination)
        )
        XCTAssertEqual(
            try normalizedCacheRows(namespace: .source, destinationRoot: serialRoots.destination, sourceRoot: serialRoots.source),
            try normalizedCacheRows(namespace: .source, destinationRoot: parallelRoots.destination, sourceRoot: parallelRoots.source)
        )
        XCTAssertEqual(
            try normalizedCacheRows(namespace: .destination, destinationRoot: serialRoots.destination, sourceRoot: serialRoots.source),
            try normalizedCacheRows(namespace: .destination, destinationRoot: parallelRoots.destination, sourceRoot: parallelRoots.source)
        )
    }

    func testPlannerCheckpointsSourceHashesDuringHashingPhase() throws {
        let sourceRoot = temporaryDirectoryURL.appendingPathComponent("checkpoint-source", isDirectory: true)
        let destinationRoot = temporaryDirectoryURL.appendingPathComponent("checkpoint-dest", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        for index in 1...600 {
            try writeMediaFile(
                at: sourceRoot.appendingPathComponent(String(format: "IMG_20240101_%06d.jpg", index)),
                contents: "checkpoint-\(index)"
            )
        }

        let databaseURL = destinationRoot.appendingPathComponent(EngineArtifactLayout.pythonReference.queueDatabaseFilename)
        let probe = SourceHashCheckpointProbe(databaseURL: databaseURL, triggerCompletedCount: 600)
        let result = try DryRunPlanner(
            dateResolver: FileDateResolver(metadataReader: NoDateMetadataReader())
        ).plan(
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            workerCount: 1,
            onEvent: { event in
                probe.observe(event)
            }
        )

        XCTAssertNil(probe.errorDescription)
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(probe.sourceRowsAtCheckpoint),
            512,
            "Source hashes should be durable before the source-hash phase completes."
        )
        XCTAssertEqual(result.sourceHashedCount, 600)
        XCTAssertEqual(
            try normalizedCacheRows(namespace: .source, destinationRoot: destinationRoot, sourceRoot: sourceRoot).count,
            600
        )
    }

    func testPlannerEmitsSourceAndDestinationHashTotals() throws {
        let sourceRoot = temporaryDirectoryURL.appendingPathComponent("total-source", isDirectory: true)
        let destinationRoot = temporaryDirectoryURL.appendingPathComponent("total-dest", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        for index in 1...3 {
            try writeMediaFile(
                at: sourceRoot.appendingPathComponent("IMG_20240101_\(index).jpg"),
                contents: "source-\(index)"
            )
        }
        for index in 1...2 {
            try writeMediaFile(
                at: destinationRoot.appendingPathComponent("2024/01/01/2024-01-01_00\(index).jpg"),
                contents: "destination-\(index)"
            )
        }

        let totals = HashProgressTotalsProbe()
        _ = try DryRunPlanner(
            dateResolver: FileDateResolver(metadataReader: NoDateMetadataReader())
        ).plan(
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            workerCount: 1,
            onEvent: { event in
                totals.observe(event)
            }
        )

        XCTAssertEqual(totals.sourceProgressTotal, 3)
        XCTAssertEqual(totals.destinationProgressTotal, 2)
    }

    func testPlannerStopsWhenCancelledDuringSourceHashing() throws {
        let sourceRoot = temporaryDirectoryURL.appendingPathComponent("cancel-source", isDirectory: true)
        let destinationRoot = temporaryDirectoryURL.appendingPathComponent("cancel-dest", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        for index in 1...150 {
            try writeMediaFile(
                at: sourceRoot.appendingPathComponent(String(format: "IMG_20240101_%06d.jpg", index)),
                contents: "cancel-\(index)"
            )
        }

        let cancellation = CancellationProbe()
        XCTAssertThrowsError(
            try DryRunPlanner(
                dateResolver: FileDateResolver(metadataReader: NoDateMetadataReader())
            ).plan(
                sourceRoot: sourceRoot,
                destinationRoot: destinationRoot,
                workerCount: 1,
                isCancelled: { cancellation.isCancelled },
                onEvent: { event in
                    if case let .phaseProgress(phase, completed, _, _, _) = event,
                       phase == .sourceHashing,
                       completed >= 100 {
                        cancellation.cancel()
                    }
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
        }
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

    private func makeDate(_ rawValue: String) -> Date {
        Self.dayFormatter.date(from: rawValue)!
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func makeConcurrencyScenario(named name: String) throws -> (source: URL, destination: URL) {
        let root = temporaryDirectoryURL.appendingPathComponent("concurrency-\(name)", isDirectory: true)
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let files: [(URL, String)] = [
            (destinationRoot.appendingPathComponent("2024/01/01/2024-01-01_001.jpg"), "already"),
            (sourceRoot.appendingPathComponent("a/IMG_20240101_010101.jpg"), "already"),
            (sourceRoot.appendingPathComponent("b/IMG_20240102_010101.jpg"), "new-b"),
            (sourceRoot.appendingPathComponent("c/IMG_20240103_010101.jpg"), "dup"),
            (sourceRoot.appendingPathComponent("d/IMG_20240104_010101.jpg"), "dup"),
            (sourceRoot.appendingPathComponent("z/orphan.jpg"), "unknown"),
        ]
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        for (url, contents) in files {
            try writeMediaFile(at: url, contents: contents)
            try FileManager.default.setAttributes(
                [.modificationDate: timestamp, .creationDate: timestamp],
                ofItemAtPath: url.path
            )
        }
        return (sourceRoot, destinationRoot)
    }

    private func normalizedCacheRows(
        namespace: CacheNamespace,
        destinationRoot: URL,
        sourceRoot: URL
    ) throws -> [NormalizedCacheRow] {
        let database = try OrganizerDatabase(
            url: destinationRoot.appendingPathComponent(EngineArtifactLayout.pythonReference.queueDatabaseFilename),
            readOnly: true
        )
        defer { database.close() }

        return try database.loadRawCacheRecords(namespace: namespace)
            .map {
                NormalizedCacheRow(
                    path: normalizePath($0.path, sourceRoot: sourceRoot, destinationRoot: destinationRoot),
                    hash: $0.hash,
                    size: $0.size,
                    modificationTime: $0.modificationTime
                )
            }
            .sorted { $0.path < $1.path }
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
    var files: [ManifestFile]
    var seedDestinationCache: [SeedDestinationCacheRow]?
    var folderStructure: String?

    private enum CodingKeys: String, CodingKey {
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

private struct NormalizedCacheRow: Equatable {
    var path: String
    var hash: String
    var size: Int64
    var modificationTime: TimeInterval
}

private final class SourceHashCheckpointProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let databaseURL: URL
    private let triggerCompletedCount: Int
    private var _sourceRowsAtCheckpoint: Int?
    private var _errorDescription: String?

    init(databaseURL: URL, triggerCompletedCount: Int) {
        self.databaseURL = databaseURL
        self.triggerCompletedCount = triggerCompletedCount
    }

    var sourceRowsAtCheckpoint: Int? {
        lock.lock()
        let count = _sourceRowsAtCheckpoint
        lock.unlock()
        return count
    }

    var errorDescription: String? {
        lock.lock()
        let description = _errorDescription
        lock.unlock()
        return description
    }

    func observe(_ event: RunEvent) {
        guard case let .phaseProgress(phase, completed, _, _, _) = event,
              phase == .sourceHashing,
              completed >= triggerCompletedCount else {
            return
        }

        lock.lock()
        let alreadyObserved = _sourceRowsAtCheckpoint != nil || _errorDescription != nil
        lock.unlock()
        guard !alreadyObserved else { return }

        do {
            let database = try OrganizerDatabase(url: databaseURL, readOnly: true)
            defer { database.close() }
            let count = try database.loadRawCacheRecords(namespace: .source).count
            lock.lock()
            _sourceRowsAtCheckpoint = count
            lock.unlock()
        } catch {
            lock.lock()
            _errorDescription = error.localizedDescription
            lock.unlock()
        }
    }
}

private final class HashProgressTotalsProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _sourceProgressTotal: Int?
    private var _destinationProgressTotal: Int?

    var sourceProgressTotal: Int? {
        lock.lock()
        let total = _sourceProgressTotal
        lock.unlock()
        return total
    }

    var destinationProgressTotal: Int? {
        lock.lock()
        let total = _destinationProgressTotal
        lock.unlock()
        return total
    }

    func observe(_ event: RunEvent) {
        guard case let .phaseProgress(phase, _, total, _, _) = event else {
            return
        }

        lock.lock()
        switch phase {
        case .sourceHashing:
            _sourceProgressTotal = total
        case .destinationIndexing:
            _destinationProgressTotal = total
        default:
            break
        }
        lock.unlock()
    }
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private struct NoDateMetadataReader: MediaMetadataDateReading {
    func photoMetadataDate(at url: URL) -> Date? { nil }
    func fileSystemCreationDate(at url: URL) -> Date? { nil }
    func fileSystemModificationDate(at url: URL) -> Date? { nil }
}

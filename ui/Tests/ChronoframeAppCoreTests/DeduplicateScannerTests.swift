import Foundation
import XCTest
@testable import ChronoframeCore

final class DeduplicateScannerTests: XCTestCase {

    // AGENTS-INVARIANT: 5
    func testScannerE2EExactDuplicate() async throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ScannerE2E-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let file1 = temporaryDirectory.appendingPathComponent("img1.jpg")
        let file2 = temporaryDirectory.appendingPathComponent("img2.jpg")

        try Data(repeating: 0x11, count: 100).write(to: file1)
        try Data(repeating: 0x11, count: 100).write(to: file2)

        let config = DeduplicateConfiguration(
            destinationPath: temporaryDirectory.path,
            timeWindowSeconds: 30,
            similarityThreshold: 1.0,
            dhashHammingThreshold: 5,
            treatRawJpegPairsAsUnit: true,
            treatLivePhotoPairsAsUnit: true
        )

        let scanner = DeduplicateScanner()
        let stream = scanner.scan(configuration: config)

        var finalSummary: DeduplicateSummary?
        for try await event in stream {
            if case .complete(let summary) = event {
                finalSummary = summary
            }
        }

        let summary = try XCTUnwrap(finalSummary)
        XCTAssertEqual(summary.clusterCounts[.exactDuplicate], 1)
    }

    func testScannerDiscoversCr3AndRw2RawFiles() async throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ScannerRawDiscovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let cr3 = temporaryDirectory.appendingPathComponent("IMG_20260401_120000.CR3")
        let rw2 = temporaryDirectory.appendingPathComponent("P1000420.RW2")

        try Data("same-raw-bytes".utf8).write(to: cr3)
        try Data("same-raw-bytes".utf8).write(to: rw2)

        let config = DeduplicateConfiguration(
            destinationPath: temporaryDirectory.path,
            timeWindowSeconds: 30,
            similarityThreshold: 1.0,
            dhashHammingThreshold: 5,
            treatRawJpegPairsAsUnit: true,
            treatLivePhotoPairsAsUnit: true
        )

        let scanner = DeduplicateScanner()
        let stream = scanner.scan(configuration: config)

        var discoveryTotal: Int?
        var finalSummary: DeduplicateSummary?
        for try await event in stream {
            switch event {
            case let .phaseStarted(phase, total) where phase == .discovery:
                discoveryTotal = total
            case let .complete(summary):
                finalSummary = summary
            default:
                break
            }
        }

        XCTAssertEqual(discoveryTotal, 2)
        let summary = try XCTUnwrap(finalSummary)
        XCTAssertEqual(summary.totalCandidatesScanned, 2)
        XCTAssertEqual(summary.clusterCounts[.exactDuplicate], 1)
    }

    // AGENTS-INVARIANT: 16
    func testWarmCacheScanDoesNotInvokeImageAnalyzer() async throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ScannerWarmCache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let file1 = temporaryDirectory.appendingPathComponent("img1.jpg")
        let file2 = temporaryDirectory.appendingPathComponent("img2.jpg")

        try Data(repeating: 0x22, count: 100).write(to: file1)
        try Data(repeating: 0x22, count: 100).write(to: file2)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        for url in [file1, file2] {
            try FileManager.default.setAttributes(
                [.modificationDate: timestamp, .creationDate: timestamp],
                ofItemAtPath: url.path
            )
        }

        let db = try OrganizerDatabase(url: temporaryDirectory.appendingPathComponent(".organize_cache.db"))
        try db.ensureDedupeFeaturesSchema()
        let records = try [file1, file2].map { url -> DedupeFeatureRecord in
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return DedupeFeatureRecord(
                path: url.path,
                size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                modificationTime: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                dhash: 0xAAAA,
                featurePrintData: Data([1, 2, 3]),
                sharpness: 0.8,
                faceScore: nil,
                pixelWidth: 16,
                pixelHeight: 16,
                captureDate: Date(timeIntervalSince1970: 1_700_000_000),
                pairedPath: nil,
                eyesOpenScore: 0.9,
                smileScore: 0.7,
                subjectSharpness: 0.6,
                subjectMotionBlur: 0.1,
                folderRoot: temporaryDirectory.path
            )
        }
        try db.saveDedupeFeatureRecords(records)
        XCTAssertEqual(try db.loadDedupeFeatureMetadataRecords().count, 2)
        db.close()

        let analyzer = CountingDedupeImageAnalyzer()
        let scanner = DeduplicateScanner(imageAnalyzer: analyzer)
        let stream = scanner.scan(
            configuration: DeduplicateConfiguration(
                destinationPath: temporaryDirectory.path,
                timeWindowSeconds: 30,
                similarityThreshold: 1.0,
                dhashHammingThreshold: 5,
                workerCount: 4
            )
        )

        var finalSummary: DeduplicateSummary?
        var discoveredCluster: DuplicateCluster?
        for try await event in stream {
            if case .clusterDiscovered(let cluster) = event {
                discoveredCluster = cluster
            } else if case .complete(let summary) = event {
                finalSummary = summary
            }
        }

        XCTAssertEqual(analyzer.callCount, 0)
        let summary = try XCTUnwrap(finalSummary)
        XCTAssertEqual(summary.clusterCounts[.exactDuplicate], 1)
        // Both files served from cache → 2 hits, 0 misses. Surfaces a
        // direct regression signal if a code change accidentally
        // invalidates the cache key on every scan.
        XCTAssertEqual(summary.cacheMetrics.hits, 2)
        XCTAssertEqual(summary.cacheMetrics.misses, 0)
        XCTAssertEqual(summary.cacheMetrics.hitRate, 1.0)
        let member = try XCTUnwrap(discoveredCluster?.members.first)
        XCTAssertEqual(member.eyesOpenScore, 0.9)
        XCTAssertEqual(member.smileScore, 0.7)
        XCTAssertEqual(member.subjectSharpness, 0.6)
        XCTAssertEqual(member.subjectMotionBlur, 0.1)
        XCTAssertEqual(member.folderRoot, temporaryDirectory.path)
    }

    func testScannerScansAdditionalSourcesAndPersistsFolderRootExpressionMetadata() async throws {
        let destinationDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ScannerCrossFolderDest-\(UUID().uuidString)")
            .standardizedFileURL
        let additionalDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ScannerCrossFolderSource-\(UUID().uuidString)")
            .standardizedFileURL
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: additionalDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: destinationDirectory)
            try? FileManager.default.removeItem(at: additionalDirectory)
        }

        let destinationFile = destinationDirectory.appendingPathComponent("dest.jpg")
        let additionalFile = additionalDirectory.appendingPathComponent("incoming.jpg")
        try Data("same-cross-folder-bytes".utf8).write(to: destinationFile)
        try Data("same-cross-folder-bytes".utf8).write(to: additionalFile)
        let pathVariants: (String) -> Set<String> = { path in
            var variants: Set<String> = [path]
            if path.hasPrefix("/var/") {
                variants.insert("/private" + path)
            }
            if path.hasPrefix("/private/var/") {
                variants.insert(String(path.dropFirst("/private".count)))
            }
            return variants
        }

        let analyzer = CountingDedupeImageAnalyzer(
            analysis: DedupeImageAnalysis(
                captureDate: Date(timeIntervalSince1970: 1_700_000_000),
                pixelWidth: 32,
                pixelHeight: 24,
                dhash: 0xAAAA,
                featurePrintData: Data([4, 5, 6]),
                featurePrintFailureMessage: nil,
                quality: PhotoQualityScore(composite: 0.85, sharpness: 0.75, faceScore: 0.6),
                eyesOpenScore: 0.93,
                smileScore: 0.81,
                subjectSharpness: 0.72,
                subjectMotionBlur: 0.08
            )
        )
        let scanner = DeduplicateScanner(imageAnalyzer: analyzer)
        let stream = scanner.scan(
            configuration: DeduplicateConfiguration(
                destinationPath: destinationDirectory.path,
                timeWindowSeconds: 30,
                similarityThreshold: 1.0,
                dhashHammingThreshold: 5,
                workerCount: 1,
                additionalSources: [
                    CrossFolderSource(path: additionalDirectory.path, priority: 1, label: "Import"),
                ]
            )
        )

        var discoveredCluster: DuplicateCluster?
        var finalSummary: DeduplicateSummary?
        for try await event in stream {
            switch event {
            case let .clusterDiscovered(cluster):
                discoveredCluster = cluster
            case let .complete(summary):
                finalSummary = summary
            default:
                break
            }
        }

        XCTAssertEqual(analyzer.callCount, 2)
        let summary = try XCTUnwrap(finalSummary)
        XCTAssertEqual(summary.totalCandidatesScanned, 2)
        XCTAssertEqual(summary.clusterCounts[.exactDuplicate], 1)

        let cluster = try XCTUnwrap(discoveredCluster)
        let memberPaths = Set(cluster.members.map(\.path))
        XCTAssertFalse(memberPaths.isDisjoint(with: pathVariants(destinationFile.path)))
        XCTAssertFalse(memberPaths.isDisjoint(with: pathVariants(additionalFile.path)))
        XCTAssertEqual(Set(cluster.members.compactMap(\.folderRoot)), Set([destinationDirectory.path, additionalDirectory.path]))
        XCTAssertTrue(cluster.members.allSatisfy { $0.eyesOpenScore == 0.93 })
        XCTAssertTrue(cluster.members.allSatisfy { $0.smileScore == 0.81 })
        XCTAssertTrue(cluster.members.allSatisfy { $0.subjectSharpness == 0.72 })
        XCTAssertTrue(cluster.members.allSatisfy { $0.subjectMotionBlur == 0.08 })

        let db = try OrganizerDatabase(url: destinationDirectory.appendingPathComponent(".organize_cache.db"))
        defer { db.close() }
        let cached = try db.loadDedupeFeatureMetadataRecords()
        let cachedDestination = try XCTUnwrap(pathVariants(destinationFile.path).compactMap { cached[$0] }.first)
        let cachedAdditional = try XCTUnwrap(pathVariants(additionalFile.path).compactMap { cached[$0] }.first)
        XCTAssertEqual(cachedDestination.folderRoot, destinationDirectory.path)
        XCTAssertEqual(cachedAdditional.folderRoot, additionalDirectory.path)
        XCTAssertEqual(cachedAdditional.eyesOpenScore, 0.93)
        XCTAssertEqual(cachedAdditional.smileScore, 0.81)
        XCTAssertEqual(cachedAdditional.subjectSharpness, 0.72)
        XCTAssertEqual(cachedAdditional.subjectMotionBlur, 0.08)
    }
}

private final class CountingDedupeImageAnalyzer: DedupeImageAnalyzing, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let analysis: DedupeImageAnalysis

    init(
        analysis: DedupeImageAnalysis = DedupeImageAnalysis(
            captureDate: Date(timeIntervalSince1970: 1_700_000_000),
            pixelWidth: 16,
            pixelHeight: 16,
            dhash: 0xAAAA,
            featurePrintData: Data([1, 2, 3]),
            featurePrintFailureMessage: nil,
            quality: PhotoQualityScore(composite: 0.8, sharpness: 0.8, faceScore: nil)
        )
    ) {
        self.analysis = analysis
    }

    var callCount: Int {
        lock.lock()
        let calls = calls
        lock.unlock()
        return calls
    }

    func analyze(url: URL, size: Int64) -> DedupeImageAnalysis {
        lock.lock()
        calls += 1
        lock.unlock()
        return analysis
    }
}

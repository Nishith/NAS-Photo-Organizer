import Foundation
import XCTest
@testable import ChronoframeCore

final class DeduplicateScannerTests: XCTestCase {

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
                pairedPath: nil
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
        for try await event in stream {
            if case .complete(let summary) = event {
                finalSummary = summary
            }
        }

        XCTAssertEqual(analyzer.callCount, 0)
        let summary = try XCTUnwrap(finalSummary)
        XCTAssertEqual(summary.clusterCounts[.exactDuplicate], 1)
    }
}

private final class CountingDedupeImageAnalyzer: DedupeImageAnalyzing, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

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
        return DedupeImageAnalysis(
            captureDate: Date(timeIntervalSince1970: 1_700_000_000),
            pixelWidth: 16,
            pixelHeight: 16,
            dhash: 0xAAAA,
            featurePrintData: Data([1, 2, 3]),
            featurePrintFailureMessage: nil,
            quality: PhotoQualityScore(composite: 0.8, sharpness: 0.8, faceScore: nil)
        )
    }
}

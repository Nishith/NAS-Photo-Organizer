import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ChronoframeCore

final class DeduplicateScannerExtraTests: XCTestCase {

    private func makeTemp(_ label: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DeduplicateScannerExtra-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeJPEG(
        at url: URL,
        width: Int = 32,
        height: Int = 32,
        fillByte: UInt8 = 0x80,
        exifDateTimeOriginal: String? = nil
    ) throws {
        let bytesPerPixel = 4
        let bytes = [UInt8](repeating: fillByte, count: width * height * bytesPerPixel)
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * bytesPerPixel,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!

        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        )!

        var properties: [CFString: Any] = [:]
        if let exifDateTimeOriginal {
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: exifDateTimeOriginal,
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testCancelBeforeFirstStreamIterationShortCircuitsTheScan() async throws {
        let temporaryDirectory = try makeTemp("cancel-pre-iter")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try Data(repeating: 0x01, count: 64)
            .write(to: temporaryDirectory.appendingPathComponent("a.jpg"))
        try Data(repeating: 0x01, count: 64)
            .write(to: temporaryDirectory.appendingPathComponent("b.jpg"))

        let scanner = DeduplicateScanner()
        let config = DeduplicateConfiguration(
            destinationPath: temporaryDirectory.path,
            timeWindowSeconds: 30,
            similarityThreshold: 1.0,
            dhashHammingThreshold: 5
        )
        let stream = scanner.scan(configuration: config)
        // Set the cancel flag BEFORE the consumer starts pulling from the
        // stream, which is when the producer Task actually runs. The first
        // cancellation checkpoint inside the scan body fires and finishes
        // the stream without emitting clusters.
        scanner.cancel()

        var clusterCount = 0
        var sawComplete = false
        for try await event in stream {
            if case .clusterDiscovered = event { clusterCount += 1 }
            if case .complete = event { sawComplete = true }
        }
        XCTAssertEqual(clusterCount, 0, "cancel-before-iter should suppress cluster events")
        XCTAssertFalse(sawComplete, "cancel-before-iter should end the stream before .complete")
    }

    func testCancelMethodIsACallableNoOpWithoutAScan() {
        let scanner = DeduplicateScanner()
        scanner.cancel() // pure flag flip, must not throw or crash.
    }

    func testRealAnalyzerRunsAgainstValidJPEGFixturesAndProducesCacheRows() async throws {
        let temporaryDirectory = try makeTemp("real-analyzer")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let jpegA = temporaryDirectory.appendingPathComponent("photo-a.jpg")
        let jpegB = temporaryDirectory.appendingPathComponent("photo-b.jpg")
        let jpegC = temporaryDirectory.appendingPathComponent("photo-c.jpg")
        // Two visually-distinct images plus one bit-identical copy of the
        // first so the exact-duplicate cluster path also fires.
        try writeJPEG(at: jpegA, fillByte: 0x10, exifDateTimeOriginal: "2024:06:15 10:00:00")
        try FileManager.default.copyItem(at: jpegA, to: jpegC)
        try writeJPEG(at: jpegB, fillByte: 0xF0, exifDateTimeOriginal: "2024:06:15 10:00:30")

        let config = DeduplicateConfiguration(
            destinationPath: temporaryDirectory.path,
            timeWindowSeconds: 60,
            similarityThreshold: 0.9,
            dhashHammingThreshold: 5
        )

        // Default initializer uses the production DefaultDedupeImageAnalyzer
        // which exercises CGImageSource metadata reading, thumbnail dHash,
        // and Vision feature print + face landmark requests.
        let scanner = DeduplicateScanner()
        let stream = scanner.scan(configuration: config)

        var sawClustering = false
        var finalSummary: DeduplicateSummary?
        for try await event in stream {
            switch event {
            case .phaseCompleted(.clustering):
                sawClustering = true
            case let .complete(summary):
                finalSummary = summary
            default:
                break
            }
        }
        XCTAssertTrue(sawClustering)
        let summary = try XCTUnwrap(finalSummary)
        XCTAssertEqual(summary.totalCandidatesScanned, 3)
        // jpegA and jpegC are byte-identical copies → exact-duplicate cluster.
        XCTAssertEqual(summary.clusterCounts[.exactDuplicate], 1)

        // The scan should have written feature-print rows for all three
        // images into the on-disk cache.
        let db = try OrganizerDatabase(url: temporaryDirectory.appendingPathComponent(".organize_cache.db"))
        try db.ensureDedupeFeaturesSchema()
        let cached = try db.loadDedupeFeatureMetadataRecords()
        XCTAssertEqual(cached.count, 3)
    }

    func testCacheHitBranchRehydratesPairedPathFromCurrentPairs() async throws {
        let temporaryDirectory = try makeTemp("cache-paired")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        // RAW + JPEG sidecar pair. The first scan populates the cache; the
        // second scan reads from the cache and must pick up the current
        // pairedPath from the fresh pair-detection pass.
        let raw = temporaryDirectory.appendingPathComponent("IMG_5500.CR3")
        let jpeg = temporaryDirectory.appendingPathComponent("IMG_5500.jpg")
        try Data("raw-bytes-content".utf8).write(to: raw)
        try writeJPEG(at: jpeg, fillByte: 0x44)

        // Pre-seed feature cache rows so the next scan takes the cache-hit
        // branch including the `pairedPath` rehydration at lines 144-145.
        let dbURL = temporaryDirectory.appendingPathComponent(".organize_cache.db")
        let preDB = try OrganizerDatabase(url: dbURL)
        try preDB.ensureDedupeFeaturesSchema()
        let attrs = try FileManager.default.attributesOfItem(atPath: jpeg.path)
        try preDB.saveDedupeFeatureRecords([
            DedupeFeatureRecord(
                path: jpeg.path,
                size: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
                modificationTime: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                dhash: 0xBEEF,
                featurePrintData: Data([4, 5, 6]),
                sharpness: 0.5,
                faceScore: nil,
                pixelWidth: 32,
                pixelHeight: 32,
                captureDate: nil,
                pairedPath: nil, // intentionally stale; current pair detection should override
                eyesOpenScore: nil,
                smileScore: nil,
                subjectSharpness: nil,
                subjectMotionBlur: nil,
                folderRoot: nil // forces the `cached.folderRoot ?? folderRoot` fallback (line 183)
            )
        ])
        preDB.close()

        let analyzer = StubDedupeImageAnalyzerForExtraTests()
        let scanner = DeduplicateScanner(imageAnalyzer: analyzer)
        let stream = scanner.scan(
            configuration: DeduplicateConfiguration(
                destinationPath: temporaryDirectory.path,
                timeWindowSeconds: 30,
                similarityThreshold: 1.0,
                dhashHammingThreshold: 5,
                treatRawJpegPairsAsUnit: true
            )
        )

        var finalSummary: DeduplicateSummary?
        for try await event in stream {
            if case .complete(let summary) = event {
                finalSummary = summary
            }
        }
        let summary = try XCTUnwrap(finalSummary)
        // Both the RAW (.CR3) and the JPEG count as photos. The JPEG was
        // pre-cached; the RAW must miss and run through the analyzer.
        XCTAssertEqual(summary.totalCandidatesScanned, 2)
        XCTAssertEqual(summary.cacheMetrics.hits, 1, "JPEG should be served from cache")
        XCTAssertEqual(summary.cacheMetrics.misses, 1, "RAW has no cached row")
    }

    func testScannerSkipsPathsThatStandardizeIntoAnAlreadySeenRoot() async throws {
        let temporaryDirectory = try makeTemp("overlap")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let file = temporaryDirectory.appendingPathComponent("only.jpg")
        try Data(repeating: 0x07, count: 32).write(to: file)

        // Same physical root listed as destinationPath AND as an
        // additionalSources entry. MediaDiscovery enumerates each scan root,
        // and the scanner's seenPaths guard ensures the same standardized
        // path isn't visited twice.
        let config = DeduplicateConfiguration(
            destinationPath: temporaryDirectory.path,
            timeWindowSeconds: 30,
            similarityThreshold: 1.0,
            dhashHammingThreshold: 5,
            additionalSources: [
                CrossFolderSource(path: temporaryDirectory.path, priority: 0, label: "overlap")
            ]
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
        XCTAssertEqual(discoveryTotal, 1, "overlap root should not double-count the same file")
        let summary = try XCTUnwrap(finalSummary)
        XCTAssertEqual(summary.totalCandidatesScanned, 1)
    }
}

private final class StubDedupeImageAnalyzerForExtraTests: DedupeImageAnalyzing, @unchecked Sendable {
    func analyze(url: URL, size: Int64) -> DedupeImageAnalysis {
        DedupeImageAnalysis(
            captureDate: Date(timeIntervalSince1970: 1_700_000_000),
            pixelWidth: 32,
            pixelHeight: 32,
            dhash: 0xCAFE,
            featurePrintData: Data([1, 2, 3]),
            featurePrintFailureMessage: nil,
            quality: PhotoQualityScore(composite: 0.7, sharpness: 0.7, faceScore: nil)
        )
    }
}

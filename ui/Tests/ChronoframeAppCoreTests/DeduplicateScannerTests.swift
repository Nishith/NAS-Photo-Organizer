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
}

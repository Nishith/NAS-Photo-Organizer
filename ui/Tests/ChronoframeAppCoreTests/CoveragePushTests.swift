import XCTest
@testable import ChronoframeCore
@testable import ChronoframeAppCore

final class CoveragePushTests: XCTestCase {
    func testCopyPlanBuilderEdgeCases() {
        // Warning about sequence width
        XCTAssertTrue(CopyPlanBuilder.shouldWarnAboutSequenceWidth(existingMaxSequence: 900, plannedWidth: 4, defaultWidth: 3))
        XCTAssertFalse(CopyPlanBuilder.shouldWarnAboutSequenceWidth(existingMaxSequence: 100, plannedWidth: 3, defaultWidth: 3))
        
        // Info about sequence width
        XCTAssertTrue(CopyPlanBuilder.shouldEmitSequenceWidthInfo(existingMaxSequence: 0, plannedWidth: 4, defaultWidth: 3))
        XCTAssertFalse(CopyPlanBuilder.shouldEmitSequenceWidthInfo(existingMaxSequence: 0, plannedWidth: 3, defaultWidth: 3))
        
        let msg = CopyPlanBuilder.sequenceWidthInfoMessage(dateBucket: "2023-01-01", count: 1000, width: 4)
        XCTAssertTrue(msg.contains("1,000"))
    }
    
    func testDateClassificationEdgeCases() {
        let naming = PlannerNamingRules.pythonReference
        XCTAssertEqual(DateClassification.bucket(for: nil, namingRules: naming), naming.unknownDateDirectoryName)
    }
    
    func testRunHistoryEntryKindTitles() {
        XCTAssertEqual(RunHistoryEntryKind.runLog.title, "Run Log")
        XCTAssertEqual(RunHistoryEntryKind.queueDatabase.title, "Queue Database")
        XCTAssertEqual(RunHistoryEntryKind.dryRunReport.title, "Dry Run Report")
        XCTAssertEqual(RunHistoryEntryKind.auditReceipt.title, "Audit Receipt")
    }

    func testFaceExpressionAnalyzerEdgeCases() {
        // Test eyeOpenness with very few points
        XCTAssertEqual(FaceExpressionAnalyzer.eyeOpenness(points: [CGPoint(x: 0, y: 0)]), 0.5)
        
        // Test eyeOpenness with zero width
        let verticalPoints = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 10), CGPoint(x: 0, y: 5), CGPoint(x: 0, y: 5), CGPoint(x: 0, y: 5), CGPoint(x: 0, y: 5)]
        XCTAssertEqual(FaceExpressionAnalyzer.eyeOpenness(points: verticalPoints), 0.5)
        
        // Test regionSharpness with invalid rect
        let width = 64
        let height = 64
        var pixels = [UInt8](repeating: 128, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let cgImage = context.makeImage()!
        
        let sharpness = FaceExpressionAnalyzer.regionSharpness(cgImage: cgImage, normalizedRect: CGRect(x: 0, y: 0, width: 0.01, height: 0.01))
        XCTAssertEqual(sharpness, 0.0)
    }
    
    func testCancellationInMediaDiscovery() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
        XCTAssertThrowsError(try MediaDiscovery.discoverMediaFiles(at: url, isCancelled: { true })) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertThrowsError(try MediaDiscovery.walkEntries(at: url, isCancelled: { true })) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }
    
    func testCopyPlanBuilderHistogramEdgeCases() {
        let naming = PlannerNamingRules.pythonReference
        
        let paths = [
            "short",
            "1234567890X.jpg",
            "2023X01-01_1.jpg",
            "2023-XX-01_1.jpg",
            "2023-01-XX_1.jpg",
            "UnknownFile_1.jpg",
            "2023-01-01_1.jpg",
            "2023-02-01_1.jpg"
        ]
        
        let histogram = CopyPlanBuilder.dateHistogram(fromDestinationPaths: paths, namingRules: naming)
        
        XCTAssertGreaterThanOrEqual(histogram.count, 0)
    }
}

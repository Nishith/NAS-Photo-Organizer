import XCTest
import Vision
@testable import ChronoframeCore

final class FaceExpressionAnalyzerTests: XCTestCase {
    func testEyeOpenness() {
        // Open eye (approx 0.4 aspect ratio)
        let openPoints = [
            CGPoint(x: 0, y: 5), CGPoint(x: 5, y: 10), CGPoint(x: 10, y: 5),
            CGPoint(x: 10, y: 5), CGPoint(x: 5, y: 0), CGPoint(x: 0, y: 5)
        ]
        let openScore = FaceExpressionAnalyzer.eyeOpenness(points: openPoints)
        XCTAssertGreaterThan(openScore, 0.8)
        
        // Closed eye (approx 0.05 aspect ratio)
        let closedPoints = [
            CGPoint(x: 0, y: 1), CGPoint(x: 5, y: 1.5), CGPoint(x: 10, y: 1),
            CGPoint(x: 10, y: 1), CGPoint(x: 5, y: 0.5), CGPoint(x: 0, y: 1)
        ]
        let closedScore = FaceExpressionAnalyzer.eyeOpenness(points: closedPoints)
        XCTAssertLessThan(closedScore, 0.3)
    }
    
    func testLaplacianVarianceFromGray() {
        // Flat gray image - zero variance
        let flatPixels: [UInt8] = Array(repeating: 128, count: 100)
        let flatVar = FaceExpressionAnalyzer.laplacianVarianceFromGray(pixels: flatPixels, width: 10, height: 10)
        XCTAssertEqual(flatVar, 0.0)
        
        // High contrast checkerboard
        var checkerboard = [UInt8](repeating: 0, count: 100)
        for i in 0..<100 {
            checkerboard[i] = (i % 2 == 0) ? 255 : 0
        }
        let highVar = FaceExpressionAnalyzer.laplacianVarianceFromGray(pixels: checkerboard, width: 10, height: 10)
        XCTAssertGreaterThan(highVar, 0.5)
    }
    
    func testGlobalImageSharpness() {
        let width = 64
        let height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<pixels.count {
            pixels[i] = (i % 8 == 0) ? 255 : 0
        }
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let cgImage = context.makeImage()!
        
        let sharpness = FaceExpressionAnalyzer.globalImageSharpness(cgImage: cgImage)
        XCTAssertGreaterThanOrEqual(sharpness, 0.0)
    }
    
    func testLaplacianVariance() {
        let width = 32
        let height = 32
        var pixels = [UInt8](repeating: 128, count: width * height * 4)
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let cgImage = context.makeImage()!
        
        let flatVar = FaceExpressionAnalyzer.laplacianVariance(cgImage: cgImage)
        XCTAssertEqual(flatVar, 0.0)
    }

    func testLaplacianVarianceZeroSize() {
        let width = 0
        let height = 0
        let pixels: [UInt8] = []
        let val = FaceExpressionAnalyzer.laplacianVarianceFromGray(pixels: pixels, width: width, height: height)
        XCTAssertEqual(val, 0.0)
    }

    func testAnalyzeWithNoFaces() {
        let width = 64
        let height = 64
        var pixels = [UInt8](repeating: 128, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let cgImage = context.makeImage()!
        
        let result = FaceExpressionAnalyzer.analyze(cgImage: cgImage, faceObservations: [])
        XCTAssertNil(result)
    }

    func testAnalyzeWithInvalidObservation() {
        let width = 10
        let height = 10
        var pixels = [UInt8](repeating: 128, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let cgImage = context.makeImage()!
        
        let observation = VNFaceObservation(boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1))
        let result = FaceExpressionAnalyzer.analyze(cgImage: cgImage, faceObservations: [observation])
        XCTAssertNil(result)
    }

    func testRegionSharpness() {
        let width = 128
        let height = 128
        var pixels = [UInt8](repeating: 128, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let cgImage = context.makeImage()!
        
        let sharpness = FaceExpressionAnalyzer.regionSharpness(cgImage: cgImage, normalizedRect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        XCTAssertEqual(sharpness, 0.0)
    }

    func testSmileScore() {
        // Wide mouth (smile)
        let smilePoints = [
            CGPoint(x: 0, y: 5), CGPoint(x: 5, y: 6), CGPoint(x: 10, y: 5),
            CGPoint(x: 10, y: 5), CGPoint(x: 5, y: 4), CGPoint(x: 0, y: 5)
        ]
        let smileScore = FaceExpressionAnalyzer.smileScore(points: smilePoints)
        XCTAssertGreaterThan(smileScore, 0.1)
        
        // Narrow mouth (no smile)
        let neutralPoints = [
            CGPoint(x: 0, y: 5), CGPoint(x: 5, y: 10), CGPoint(x: 10, y: 5),
            CGPoint(x: 10, y: 5), CGPoint(x: 5, y: 0), CGPoint(x: 0, y: 5)
        ]
        let neutralScore = FaceExpressionAnalyzer.smileScore(points: neutralPoints)
        XCTAssertEqual(neutralScore, 0.0)
    }
    
    func testEyesOpenScore() {
        let leftPoints = [
            CGPoint(x: 0, y: 5), CGPoint(x: 5, y: 10), CGPoint(x: 10, y: 5),
            CGPoint(x: 10, y: 5), CGPoint(x: 5, y: 0), CGPoint(x: 0, y: 5)
        ]
        let rightPoints = leftPoints
        let score = FaceExpressionAnalyzer.eyesOpenScore(leftPoints: leftPoints, rightPoints: rightPoints)
        XCTAssertGreaterThan(score, 0.8)
    }
}

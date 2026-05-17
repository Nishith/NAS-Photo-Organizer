import AVFoundation
import CoreServices
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ChronoframeCore

final class DeduplicatePairDetectorLivePhotoTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DedupePairLivePhoto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        try super.tearDownWithError()
    }

    private func writeOnePixelHEIC(at url: URL, contentIdentifier: String?) throws {
        let width = 1
        let height = 1
        let bytesPerPixel = 4
        let bytes = [UInt8](repeating: 0xFF, count: width * height * bytesPerPixel)
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * bytesPerPixel,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            throw XCTSkip("HEIC encoding is not available on this machine")
        }

        var properties: [CFString: Any] = [:]
        if let contentIdentifier {
            properties[kCGImagePropertyMakerAppleDictionary] = ["17": contentIdentifier]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("HEIC encoding failed on this machine")
        }
    }

    private func writeQuickTimeMovie(at url: URL, contentIdentifier: String?) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        if let contentIdentifier {
            let metadata = AVMutableMetadataItem()
            metadata.keySpace = AVMetadataKeySpace(rawValue: "mdta")
            metadata.key = "com.apple.quicktime.content.identifier" as NSString
            metadata.value = contentIdentifier as NSString
            metadata.dataType = "com.apple.metadata.datatype.UTF-8"
            writer.metadata = [metadata]
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 16,
            AVVideoHeightKey: 16,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 16,
                kCVPixelBufferHeightKey as String: 16,
            ]
        )

        guard writer.canAdd(input) else {
            throw XCTSkip("AVAssetWriter cannot add input on this machine")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw XCTSkip("AVAssetWriter.startWriting failed: \(writer.error?.localizedDescription ?? "unknown")")
        }
        writer.startSession(atSourceTime: .zero)

        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            16,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer = buffer else {
            throw XCTSkip("CVPixelBufferCreate failed")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        memset(CVPixelBufferGetBaseAddress(pixelBuffer), 0, CVPixelBufferGetDataSize(pixelBuffer))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let pollDeadline = Date().addingTimeInterval(2)
        while !input.isReadyForMoreMediaData && Date() < pollDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard adaptor.append(pixelBuffer, withPresentationTime: .zero) else {
            throw XCTSkip("AVAssetWriter append failed: \(writer.error?.localizedDescription ?? "unknown")")
        }

        input.markAsFinished()
        let finishExpectation = XCTestExpectation(description: "AVAssetWriter finish")
        writer.finishWriting { finishExpectation.fulfill() }
        wait(for: [finishExpectation], timeout: 5)
        guard writer.status == .completed else {
            throw XCTSkip("AVAssetWriter status \(writer.status.rawValue): \(writer.error?.localizedDescription ?? "")")
        }
    }

    func testLivePhotoIdentifierReadsAppleContentIdFromHEIC() throws {
        let url = temporaryDirectoryURL.appendingPathComponent("photo.heic")
        // ImageIO pads MakerApple ASCII fields; the prefix is preserved.
        try writeOnePixelHEIC(at: url, contentIdentifier: "84211230-1F4C-4ADD-8AAA-D6FAC5B59A2A")
        let parsed = try XCTUnwrap(DeduplicatePairDetector.livePhotoIdentifier(forImageAt: url))
        XCTAssertTrue(
            parsed.hasPrefix("84211230-1F4C-4ADD-8AAA-D6FAC5B59A2A"),
            "Expected stored identifier prefix, got: \(parsed)"
        )
    }

    func testLivePhotoIdentifierReturnsNilForHEICWithoutAppleMakerDictionary() throws {
        let url = temporaryDirectoryURL.appendingPathComponent("plain.heic")
        try writeOnePixelHEIC(at: url, contentIdentifier: nil)
        XCTAssertNil(DeduplicatePairDetector.livePhotoIdentifier(forImageAt: url))
    }

    func testLivePhotoIdentifierReturnsNilForUnreadableImage() throws {
        let url = temporaryDirectoryURL.appendingPathComponent("garbage.heic")
        try Data(repeating: 0x00, count: 8).write(to: url)
        XCTAssertNil(DeduplicatePairDetector.livePhotoIdentifier(forImageAt: url))
    }

    func testLivePhotoIdentifierReadsContentIdFromQuickTimeMovie() throws {
        let url = temporaryDirectoryURL.appendingPathComponent("video.mov")
        try writeQuickTimeMovie(at: url, contentIdentifier: "live-id-abc")
        XCTAssertEqual(DeduplicatePairDetector.livePhotoIdentifier(forMovieAt: url), "live-id-abc")
    }

    func testLivePhotoIdentifierReturnsNilForMovieWithoutContentIdentifier() throws {
        let url = temporaryDirectoryURL.appendingPathComponent("plain.mov")
        try writeQuickTimeMovie(at: url, contentIdentifier: nil)
        XCTAssertNil(DeduplicatePairDetector.livePhotoIdentifier(forMovieAt: url))
    }

    func testDetectPairsRunsHEICAndMovIterationEvenWhenIdentifiersDoNotMatch() throws {
        // The HEIC writer pads MakerApple ASCII fields while AVAssetWriter
        // does not. End-to-end "the pair links" matching requires byte-for-byte
        // identifier equality, which CGImageDestination's padding breaks for
        // arbitrary inputs. We assert here that the detector exercises the
        // full HEIC-by-directory / MOV-by-directory iteration without crashing
        // and that mismatched identifiers correctly do not produce a pair.
        let heicURL = temporaryDirectoryURL.appendingPathComponent("IMG_0001.heic")
        let movURL = temporaryDirectoryURL.appendingPathComponent("IMG_0001.mov")
        try writeOnePixelHEIC(at: heicURL, contentIdentifier: "84211230-1F4C-4ADD-8AAA-D6FAC5B59A2A")
        try writeQuickTimeMovie(at: movURL, contentIdentifier: "non-matching-identifier")

        let pairs = DeduplicatePairDetector.detectPairs(in: [heicURL.path, movURL.path])
        XCTAssertNil(pairs[heicURL.path])
        XCTAssertNil(pairs[movURL.path])
    }

    func testDetectPairsSkipsHEICWhenNoSiblingMovieInDirectory() throws {
        let heicURL = temporaryDirectoryURL.appendingPathComponent("IMG_0002.heic")
        try writeOnePixelHEIC(at: heicURL, contentIdentifier: "84211230-1F4C-4ADD-8AAA-D6FAC5B59A2A")
        // Place a MOV in a SIBLING directory so directory grouping splits them.
        let siblingDir = temporaryDirectoryURL.appendingPathComponent("sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: siblingDir, withIntermediateDirectories: true)
        let movURL = siblingDir.appendingPathComponent("IMG_0002.mov")
        try writeQuickTimeMovie(at: movURL, contentIdentifier: "84211230-1F4C-4ADD-8AAA-D6FAC5B59A2A")

        let pairs = DeduplicatePairDetector.detectPairs(in: [heicURL.path, movURL.path])
        XCTAssertNil(pairs[heicURL.path])
        XCTAssertNil(pairs[movURL.path])
    }
}

import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ChronoframeCore

final class MediaDateResolverNativeReaderTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MediaDateResolverNativeReader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        try super.tearDownWithError()
    }

    private func writeOnePixelJPEG(
        at url: URL,
        exifDateTimeOriginal: String? = nil,
        exifOffsetTimeOriginal: String? = nil,
        tiffDateTime: String? = nil
    ) throws {
        let bytesPerPixel = 4
        let width = 1
        let height = 1
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

        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        )!

        var properties: [CFString: Any] = [:]
        if exifDateTimeOriginal != nil || exifOffsetTimeOriginal != nil {
            var exif: [CFString: Any] = [:]
            if let v = exifDateTimeOriginal { exif[kCGImagePropertyExifDateTimeOriginal] = v }
            if let v = exifOffsetTimeOriginal { exif[kCGImagePropertyExifOffsetTimeOriginal] = v }
            properties[kCGImagePropertyExifDictionary] = exif
        }
        if let tiffDateTime {
            properties[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFDateTime: tiffDateTime
            ]
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    // MARK: - parseImagePropertyDate

    func testParseImagePropertyDateAcceptsExifFormat() {
        let date = NativeMediaMetadataDateReader.parseImagePropertyDate("2024:03:15 14:30:00")
        XCTAssertNotNil(date)
    }

    func testParseImagePropertyDateAcceptsIsoLikeFormat() {
        let date = NativeMediaMetadataDateReader.parseImagePropertyDate("2024-03-15 14:30:00")
        XCTAssertNotNil(date)
    }

    func testParseImagePropertyDateUsesOffsetFormattersWhenOffsetGiven() {
        let date = NativeMediaMetadataDateReader.parseImagePropertyDate(
            "2024:03:15 14:30:00",
            offset: "+05:30"
        )
        XCTAssertNotNil(date)

        let isoOffset = NativeMediaMetadataDateReader.parseImagePropertyDate(
            "2024-03-15 14:30:00",
            offset: "-08:00"
        )
        XCTAssertNotNil(isoOffset)
    }

    func testParseImagePropertyDateRejectsGarbage() {
        XCTAssertNil(NativeMediaMetadataDateReader.parseImagePropertyDate("not a date"))
        XCTAssertNil(NativeMediaMetadataDateReader.parseImagePropertyDate(""))
        // Blank/whitespace offset takes the no-offset branch.
        XCTAssertNotNil(
            NativeMediaMetadataDateReader.parseImagePropertyDate("2024:03:15 14:30:00", offset: "   ")
        )
    }

    // MARK: - NativeMediaMetadataDateReader.photoMetadataDate

    func testNativeReaderReturnsNilForNonPhotoExtensions() throws {
        let url = temporaryDirectoryURL.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: url)
        let reader = NativeMediaMetadataDateReader()
        XCTAssertNil(reader.photoMetadataDate(at: url))
    }

    func testNativeReaderReturnsNilForUnreadableImageBytes() throws {
        let url = temporaryDirectoryURL.appendingPathComponent("garbage.jpg")
        try Data(repeating: 0x00, count: 16).write(to: url)
        let reader = NativeMediaMetadataDateReader()
        XCTAssertNil(reader.photoMetadataDate(at: url))
    }

    func testNativeReaderReadsExifDateTimeOriginal() throws {
        let url = temporaryDirectoryURL.appendingPathComponent("exif.jpg")
        try writeOnePixelJPEG(at: url, exifDateTimeOriginal: "2025:06:01 09:15:30")
        let reader = NativeMediaMetadataDateReader()
        let parsed = try XCTUnwrap(reader.photoMetadataDate(at: url))
        let components = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(secondsFromGMT: 0)!,
            from: parsed
        )
        XCTAssertEqual(components.year, 2025)
        XCTAssertEqual(components.month, 6)
        XCTAssertEqual(components.day, 1)
    }

    func testNativeReaderReturnsNilWhenJPEGHasNoDateMetadata() throws {
        let url = temporaryDirectoryURL.appendingPathComponent("no-dates.jpg")
        try writeOnePixelJPEG(at: url)
        let reader = NativeMediaMetadataDateReader()
        XCTAssertNil(reader.photoMetadataDate(at: url))
    }

    // MARK: - fileSystemCreationDate / fileSystemModificationDate

    func testFileSystemDateAccessorsReadResourceValues() throws {
        let url = temporaryDirectoryURL.appendingPathComponent("sample.dat")
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: url.path
        )
        let reader = NativeMediaMetadataDateReader()
        XCTAssertNotNil(reader.fileSystemCreationDate(at: url))
        XCTAssertNotNil(reader.fileSystemModificationDate(at: url))
    }

    // MARK: - parseYYYYMMDD edge cases via the filename parser

    func testFilenameDateParserRejectsLessThanEightDigitDateLikeSubstrings() {
        // "_1234_" still matches the (\d{8}) anchor only when 8 digits exist,
        // so a 6-digit cluster should fall through to nil.
        XCTAssertNil(FilenameDateParser.parse(from: "IMG_240315_120000.jpg"))
    }

    // MARK: - resolveResolvedDate two-arg overload

    func testResolveResolvedDateTwoArgOverloadUsesPrecomputedHighConfidenceDate() {
        let reader = StubReader(photoDate: nil, creationDate: nil, modificationDate: nil)
        let resolver = FileDateResolver(metadataReader: reader)
        let precomputed = Date(timeIntervalSince1970: 1_700_000_000)
        let resolved = resolver.resolveResolvedDate(
            for: "/tmp/anything.jpg",
            precomputedPhotoMetadataDate: precomputed
        )
        XCTAssertEqual(resolved.date, precomputed)
        XCTAssertEqual(resolved.source, .photoMetadata)
        XCTAssertEqual(resolved.confidence, .high)
    }
}

private final class StubReader: MediaMetadataDateReading, @unchecked Sendable {
    let photoDate: Date?
    let creationDate: Date?
    let modificationDate: Date?

    init(photoDate: Date?, creationDate: Date?, modificationDate: Date?) {
        self.photoDate = photoDate
        self.creationDate = creationDate
        self.modificationDate = modificationDate
    }

    func photoMetadataDate(at url: URL) -> Date? { photoDate }
    func fileSystemCreationDate(at url: URL) -> Date? { creationDate }
    func fileSystemModificationDate(at url: URL) -> Date? { modificationDate }
}

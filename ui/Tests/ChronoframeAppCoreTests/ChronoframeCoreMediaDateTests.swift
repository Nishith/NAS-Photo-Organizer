import Foundation
import XCTest
@testable import ChronoframeCore

final class ChronoframeCoreMediaDateTests: XCTestCase {
    func testExtensionSetsAndSkipRulesRemainStable() {
        XCTAssertTrue(MediaLibraryRules.isPhotoFile(path: "/photos/test.jpg"))
        XCTAssertTrue(MediaLibraryRules.isPhotoFile(path: "/photos/test.HEIC"))
        XCTAssertTrue(MediaLibraryRules.isVideoFile(path: "/videos/test.mov"))
        XCTAssertTrue(MediaLibraryRules.isSupportedMediaFile(path: "/videos/test.mp4"))
        XCTAssertFalse(MediaLibraryRules.isSupportedMediaFile(path: "/docs/readme.txt"))
        XCTAssertTrue(MediaLibraryRules.shouldSkipDiscoveredFile(named: ".DS_Store"))
        XCTAssertTrue(MediaLibraryRules.shouldSkipDiscoveredFile(named: "profiles.yaml"))
        XCTAssertFalse(MediaLibraryRules.shouldSkipDiscoveredFile(named: "IMG_20240101_120000.jpg"))
    }

    func testFilenameDateParserMatchesPythonPatterns() {
        XCTAssertEqual(dayString(FilenameDateParser.parse(from: "/photos/IMG_20210417_120000.jpg")), "2021-04-17")
        XCTAssertEqual(dayString(FilenameDateParser.parse(from: "/photos/VID_20200101_235959.mp4")), "2020-01-01")
        XCTAssertEqual(dayString(FilenameDateParser.parse(from: "/photos/PANO_20190615_080000.jpg")), "2019-06-15")
        XCTAssertEqual(dayString(FilenameDateParser.parse(from: "/photos/BURST_20180312_143000.jpg")), "2018-03-12")
        XCTAssertEqual(dayString(FilenameDateParser.parse(from: "/photos/MVIMG_20170820_090000.jpg")), "2017-08-20")
        XCTAssertEqual(dayString(FilenameDateParser.parse(from: "/photos/20210101_120000.jpg")), "2021-01-01")
        XCTAssertEqual(dayString(FilenameDateParser.parse(from: "/photos/signal_20201225_photo.jpg")), "2020-12-25")
    }

    func testFilenameDateParserRejectsInvalidAndOutOfRangeDates() {
        XCTAssertNil(FilenameDateParser.parse(from: "/photos/IMG_20211301_120000.jpg"))
        XCTAssertNil(FilenameDateParser.parse(from: "/photos/IMG_20210132_120000.jpg"))
        XCTAssertNil(FilenameDateParser.parse(from: "/photos/IMG_19990101_120000.jpg"))
        XCTAssertNil(FilenameDateParser.parse(from: "/photos/IMG_20310101_120000.jpg"))
        XCTAssertNil(FilenameDateParser.parse(from: "/photos/family_photo.jpg"))
        XCTAssertNil(FilenameDateParser.parse(from: "/photos/DSC_1234.jpg"))
    }

    func testDateClassificationUsesUnknownDateForNilAndOldYears() {
        XCTAssertEqual(DateClassification.bucket(for: nil), "Unknown_Date")
        XCTAssertEqual(DateClassification.bucket(for: makeDate("1970-01-01")), "Unknown_Date")
        XCTAssertEqual(DateClassification.bucket(for: makeDate("2023-06-15")), "2023-06-15")
    }

    func testFileDateResolverUsesPhotoMetadataForPhotosBeforeFilenameFallback() {
        let reader = StubMetadataReader(
            photoDate: makeDate("2023-06-15"),
            creationDate: makeDate("2020-01-01"),
            modificationDate: makeDate("2024-01-01")
        )
        let resolver = FileDateResolver(metadataReader: reader)

        XCTAssertEqual(dayString(resolver.resolveDate(for: "/photos/IMG_20210501_120000.jpg")), "2023-06-15")
        XCTAssertEqual(reader.photoMetadataCallCount, 1)
    }

    func testFileDateResolverUsesFilenameWhenMetadataUnavailable() {
        let reader = StubMetadataReader(
            photoDate: nil,
            creationDate: makeDate("2020-06-15"),
            modificationDate: makeDate("2024-01-01")
        )
        let resolver = FileDateResolver(metadataReader: reader)

        XCTAssertEqual(dayString(resolver.resolveDate(for: "/photos/IMG_20210501_120000.jpg")), "2021-05-01")
        XCTAssertEqual(reader.creationDateCallCount, 0)
    }

    func testFileDateResolverUsesCreationDateWhenFilenameFails() {
        let reader = StubMetadataReader(
            photoDate: nil,
            creationDate: makeDate("2020-06-15"),
            modificationDate: makeDate("2024-01-01")
        )
        let resolver = FileDateResolver(metadataReader: reader)

        XCTAssertEqual(dayString(resolver.resolveDate(for: "/photos/random_name.jpg")), "2020-06-15")
        XCTAssertEqual(reader.creationDateCallCount, 1)
    }

    func testFileDateResolverRejectsOldCreationDateAndFallsBackToModificationDate() {
        let reader = StubMetadataReader(
            photoDate: nil,
            creationDate: makeDate("1970-01-01"),
            modificationDate: makeDate("2024-01-01")
        )
        let resolver = FileDateResolver(metadataReader: reader)

        XCTAssertEqual(dayString(resolver.resolveDate(for: "/photos/random_name.jpg")), "2024-01-01")
        XCTAssertEqual(reader.creationDateCallCount, 1)
        XCTAssertEqual(reader.modificationDateCallCount, 1)
    }

    func testFileDateResolverSkipsPhotoMetadataLookupForVideos() {
        let reader = StubMetadataReader(
            photoDate: makeDate("2023-06-15"),
            creationDate: nil,
            modificationDate: makeDate("2024-01-01")
        )
        let resolver = FileDateResolver(metadataReader: reader)

        XCTAssertEqual(dayString(resolver.resolveDate(for: "/videos/IMG_20230615_120000.mov")), "2023-06-15")
        XCTAssertEqual(reader.photoMetadataCallCount, 0)
    }

    // MARK: - Complete fallback chain coverage

    /// All metadata sources are unavailable → resolver returns nil → bucket = Unknown_Date.
    func testFileDateResolverReturnsNilWhenAllSourcesUnavailable() {
        let reader = StubMetadataReader(
            photoDate: nil,
            creationDate: nil,
            modificationDate: nil
        )
        let resolver = FileDateResolver(metadataReader: reader)
        let result = resolver.resolveDate(for: "/photos/DSC_4321.jpg")

        XCTAssertNil(result, "Expected nil when no date source is available")
        XCTAssertEqual(DateClassification.bucket(for: result), "Unknown_Date")
    }

    /// Modification date is also epoch/old → resolver returns nil.
    func testFileDateResolverReturnsNilWhenModificationDateIsAlsoAncient() {
        let reader = StubMetadataReader(
            photoDate: nil,
            creationDate: makeDate("1970-01-01"),
            modificationDate: makeDate("1970-01-01")
        )
        let resolver = FileDateResolver(metadataReader: reader)
        let result = resolver.resolveDate(for: "/photos/no_date.jpg")

        XCTAssertNil(result)
        XCTAssertEqual(DateClassification.bucket(for: result), "Unknown_Date")
    }

    /// Verifies the full priority order on a photo: EXIF > filename > creation > mtime.
    /// Removing higher-priority sources one by one should fall through to the next.
    func testFileDateResolverFullFallbackOrderForPhoto() {
        // 1. EXIF beats filename.
        let r1 = StubMetadataReader(photoDate: makeDate("2022-03-01"), creationDate: makeDate("2020-01-01"), modificationDate: makeDate("2019-01-01"))
        XCTAssertEqual(dayString(FileDateResolver(metadataReader: r1).resolveDate(for: "/photos/IMG_20210101_120000.jpg")), "2022-03-01")

        // 2. No EXIF → filename wins over creation date.
        let r2 = StubMetadataReader(photoDate: nil, creationDate: makeDate("2020-01-01"), modificationDate: makeDate("2019-01-01"))
        XCTAssertEqual(dayString(FileDateResolver(metadataReader: r2).resolveDate(for: "/photos/IMG_20210101_120000.jpg")), "2021-01-01")

        // 3. No EXIF, no filename date → creation date.
        let r3 = StubMetadataReader(photoDate: nil, creationDate: makeDate("2020-01-01"), modificationDate: makeDate("2019-01-01"))
        XCTAssertEqual(dayString(FileDateResolver(metadataReader: r3).resolveDate(for: "/photos/DSC_4321.jpg")), "2020-01-01")

        // 4. No EXIF, no filename, old creation → mtime.
        let r4 = StubMetadataReader(photoDate: nil, creationDate: makeDate("1970-01-01"), modificationDate: makeDate("2019-06-15"))
        XCTAssertEqual(dayString(FileDateResolver(metadataReader: r4).resolveDate(for: "/photos/DSC_4321.jpg")), "2019-06-15")

        // 5. All unavailable/old → nil → Unknown_Date.
        let r5 = StubMetadataReader(photoDate: nil, creationDate: makeDate("1970-01-01"), modificationDate: makeDate("1970-01-01"))
        XCTAssertNil(FileDateResolver(metadataReader: r5).resolveDate(for: "/photos/DSC_4321.jpg"))
    }

    /// Video files should NOT consult EXIF metadata (expensive + unreliable for video).
    func testFileDateResolverDoesNotCallPhotoMetadataForMp4() {
        let reader = StubMetadataReader(
            photoDate: makeDate("2023-01-01"),
            creationDate: nil,
            modificationDate: makeDate("2021-01-01")
        )
        let resolver = FileDateResolver(metadataReader: reader)
        _ = resolver.resolveDate(for: "/videos/clip.mp4")

        XCTAssertEqual(reader.photoMetadataCallCount, 0, "EXIF lookup must not be invoked for .mp4 files")
    }

    private func makeDate(_ rawValue: String) -> Date {
        Self.dayFormatter.date(from: rawValue)!
    }

    private func dayString(_ date: Date?) -> String? {
        guard let date else { return nil }
        return Self.dayFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private final class StubMetadataReader: MediaMetadataDateReading, @unchecked Sendable {
    var photoDate: Date?
    var creationDate: Date?
    var modificationDate: Date?
    private(set) var photoMetadataCallCount = 0
    private(set) var creationDateCallCount = 0
    private(set) var modificationDateCallCount = 0

    init(photoDate: Date?, creationDate: Date?, modificationDate: Date?) {
        self.photoDate = photoDate
        self.creationDate = creationDate
        self.modificationDate = modificationDate
    }

    func photoMetadataDate(at url: URL) -> Date? {
        photoMetadataCallCount += 1
        return photoDate
    }

    func fileSystemCreationDate(at url: URL) -> Date? {
        creationDateCallCount += 1
        return creationDate
    }

    func fileSystemModificationDate(at url: URL) -> Date? {
        modificationDateCallCount += 1
        return modificationDate
    }
}

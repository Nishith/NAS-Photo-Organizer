import Foundation
import ImageIO

public enum MediaLibraryRules {
    public static let photoExtensions: Set<String> = [
        ".jpg", ".jpeg", ".heic", ".png", ".gif", ".bmp", ".tiff", ".tif",
        ".dng", ".nef", ".cr2", ".cr3", ".arw", ".raf", ".orf", ".rw2",
    ]

    public static let videoExtensions: Set<String> = [
        ".mov", ".mp4", ".m4v", ".avi", ".mkv", ".wmv", ".3gp",
    ]

    public static let allExtensions = photoExtensions.union(videoExtensions)

    public static let skippedFilenames: Set<String> = [
        "chronoframe.py", "chronoframe_v2.py", "run_organize.sh",
        "run_new_folder.sh", "reorganize_structure.sh",
        "profiles.yaml", "requirements.txt", "README.md",
        "test_chronoframe.py",
    ]

    public static func normalizedExtension(for path: String) -> String {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ext.isEmpty ? "" : ".\(ext)"
    }

    public static func isPhotoFile(path: String) -> Bool {
        photoExtensions.contains(normalizedExtension(for: path))
    }

    public static func isVideoFile(path: String) -> Bool {
        videoExtensions.contains(normalizedExtension(for: path))
    }

    public static func isSupportedMediaFile(path: String) -> Bool {
        allExtensions.contains(normalizedExtension(for: path))
    }

    public static func shouldSkipDiscoveredFile(named name: String) -> Bool {
        name.hasPrefix(".") || skippedFilenames.contains(name)
    }
}

public enum FilenameDateParser {
    public static func parse(from path: String) -> Date? {
        let filename = URL(fileURLWithPath: path).lastPathComponent

        for pattern in patterns {
            let searchRange = NSRange(filename.startIndex..<filename.endIndex, in: filename)
            guard let match = pattern.firstMatch(in: filename, range: searchRange) else {
                continue
            }

            let rawDate: String?
            if match.numberOfRanges > 3,
               let yearRange = Range(match.range(at: 1), in: filename),
               let monthRange = Range(match.range(at: 2), in: filename),
               let dayRange = Range(match.range(at: 3), in: filename) {
                rawDate = "\(filename[yearRange])\(filename[monthRange])\(filename[dayRange])"
            } else if let range = Range(match.range(at: 1), in: filename) {
                rawDate = String(filename[range])
            } else {
                rawDate = nil
            }

            guard let rawDate, let date = parseYYYYMMDD(rawDate) else { continue }

            return date
        }

        return nil
    }

    private static func parseYYYYMMDD(_ rawValue: String) -> Date? {
        guard rawValue.count == 8 else { return nil }

        guard
            let year = Int(rawValue.prefix(4)),
            let month = Int(rawValue.dropFirst(4).prefix(2)),
            let day = Int(rawValue.suffix(2)),
            (1900...2100).contains(year)
        else {
            return nil
        }

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        guard let date = components.date else {
            return nil
        }

        let resolved = calendar.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date)
        guard
            resolved.year == year,
            resolved.month == month,
            resolved.day == day
        else {
            return nil
        }

        return date
    }

    private static let calendar = Calendar(identifier: .gregorian)

    private static let patterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(?:IMG|VID|PANO|BURST|MVIMG|PXL)_(\d{8})[_-]\d{6}"#),
        try! NSRegularExpression(pattern: #"^(?:IMG|VID)-(\d{8})-WA\d+"#),
        try! NSRegularExpression(pattern: #"^(\d{8})[_-]\d{6}"#),
        try! NSRegularExpression(pattern: #"(\d{4})-(\d{2})-(\d{2})"#),
        try! NSRegularExpression(pattern: #"_(\d{8})_"#),
    ]
}

public enum DateClassification {
    public static func isUnknown(_ date: Date) -> Bool {
        let year = Calendar(identifier: .gregorian).component(.year, from: date)
        return year < 1900
    }

    public static func bucket(
        for date: Date?,
        namingRules: PlannerNamingRules = .pythonReference
    ) -> String {
        guard let date, !isUnknown(date) else {
            return namingRules.unknownDateDirectoryName
        }
        return dayFormatter.string(from: date)
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

public protocol MediaMetadataDateReading: Sendable {
    func photoMetadataDate(at url: URL) -> Date?
    func fileSystemCreationDate(at url: URL) -> Date?
    func fileSystemModificationDate(at url: URL) -> Date?
}

public struct NativeMediaMetadataDateReader: MediaMetadataDateReading {
    public init() {}

    public func photoMetadataDate(at url: URL) -> Date? {
        guard MediaLibraryRules.isPhotoFile(path: url.path) else {
            return nil
        }

        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return nil
        }

        if
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
            let rawValue = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
            let parsed = Self.parseImagePropertyDate(
                rawValue,
                offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
            )
        {
            return parsed
        }

        if
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
            let rawValue = tiff[kCGImagePropertyTIFFDateTime] as? String,
            let parsed = Self.parseImagePropertyDate(rawValue)
        {
            return parsed
        }

        return nil
    }

    public func fileSystemCreationDate(at url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    public func fileSystemModificationDate(at url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    static func parseImagePropertyDate(_ rawValue: String, offset: String? = nil) -> Date? {
        if let offset, !offset.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for formatter in offsetDateFormatters {
                if let date = formatter.date(from: "\(rawValue) \(offset)") {
                    return date
                }
            }
        }
        for formatter in dateFormatters {
            if let date = formatter.date(from: rawValue) {
                return date
            }
        }
        return nil
    }

    private static var dateFormatters: [DateFormatter] {
        [
            Self.exifFormatter,
            Self.isoLikeFormatter,
        ]
    }

    private static var offsetDateFormatters: [DateFormatter] {
        [
            Self.exifOffsetFormatter,
            Self.isoLikeOffsetFormatter,
        ]
    }

    private static let exifFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    private static let isoLikeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let exifOffsetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss XXX"
        return formatter
    }()

    private static let isoLikeOffsetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss XXX"
        return formatter
    }()
}

public struct FileDateResolver: Sendable {
    public var metadataReader: any MediaMetadataDateReading

    public init(metadataReader: any MediaMetadataDateReading = NativeMediaMetadataDateReader()) {
        self.metadataReader = metadataReader
    }

    public func resolveDate(for path: String) -> Date? {
        resolveResolvedDate(for: path).date
    }

    public func resolveResolvedDate(for path: String) -> ResolvedMediaDate {
        resolveResolvedDate(for: path, precomputedPhotoMetadataDate: nil, shouldReadPhotoMetadata: true)
    }

    func resolveDate(for path: String, precomputedPhotoMetadataDate: Date?) -> Date? {
        resolveResolvedDate(
            for: path,
            precomputedPhotoMetadataDate: precomputedPhotoMetadataDate,
            shouldReadPhotoMetadata: !(metadataReader is NativeMediaMetadataDateReader)
        ).date
    }

    func resolveResolvedDate(for path: String, precomputedPhotoMetadataDate: Date?) -> ResolvedMediaDate {
        resolveResolvedDate(
            for: path,
            precomputedPhotoMetadataDate: precomputedPhotoMetadataDate,
            shouldReadPhotoMetadata: !(metadataReader is NativeMediaMetadataDateReader)
        )
    }

    private func resolveResolvedDate(
        for path: String,
        precomputedPhotoMetadataDate: Date?,
        shouldReadPhotoMetadata: Bool
    ) -> ResolvedMediaDate {
        let url = URL(fileURLWithPath: path)

        if MediaLibraryRules.isPhotoFile(path: path) {
            if let precomputedPhotoMetadataDate,
               !DateClassification.isUnknown(precomputedPhotoMetadataDate) {
                return ResolvedMediaDate(
                    date: precomputedPhotoMetadataDate,
                    source: .photoMetadata,
                    confidence: .high
                )
            }

            if shouldReadPhotoMetadata,
               let metadataDate = metadataReader.photoMetadataDate(at: url),
               !DateClassification.isUnknown(metadataDate) {
                return ResolvedMediaDate(
                    date: metadataDate,
                    source: .photoMetadata,
                    confidence: .high
                )
            }
        }

        if let filenameDate = FilenameDateParser.parse(from: path) {
            return ResolvedMediaDate(
                date: filenameDate,
                source: .filename,
                confidence: .medium
            )
        }

        if let creationDate = metadataReader.fileSystemCreationDate(at: url),
           !DateClassification.isUnknown(creationDate) {
            return ResolvedMediaDate(
                date: creationDate,
                source: .fileSystemCreation,
                confidence: .low
            )
        }

        if let modificationDate = metadataReader.fileSystemModificationDate(at: url),
           !DateClassification.isUnknown(modificationDate) {
            return ResolvedMediaDate(
                date: modificationDate,
                source: .fileSystemModification,
                confidence: .low
            )
        }

        return .unknown
    }
}

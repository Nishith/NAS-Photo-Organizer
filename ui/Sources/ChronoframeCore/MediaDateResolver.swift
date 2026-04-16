import Foundation
import ImageIO

public enum MediaLibraryRules {
    public static let photoExtensions: Set<String> = [
        ".jpg", ".jpeg", ".heic", ".png", ".gif", ".bmp", ".tiff", ".tif",
        ".dng", ".nef", ".cr2", ".arw", ".raf", ".orf",
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

            guard
                let range = Range(match.range(at: 1), in: filename),
                let date = parseYYYYMMDD(String(filename[range]))
            else {
                continue
            }

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
            (2000...2030).contains(year)
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
        try! NSRegularExpression(pattern: #"(?:IMG|VID|PANO|BURST|MVIMG)_(\d{8})_\d{6}"#),
        try! NSRegularExpression(pattern: #"^(\d{8})_\d{6}"#),
        try! NSRegularExpression(pattern: #"_(\d{8})_"#),
    ]
}

public enum DateClassification {
    public static func isUnknown(_ date: Date) -> Bool {
        let year = Calendar(identifier: .gregorian).component(.year, from: date)
        return year <= 1971
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
            let parsed = parseImagePropertyDate(rawValue)
        {
            return parsed
        }

        if
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
            let rawValue = tiff[kCGImagePropertyTIFFDateTime] as? String,
            let parsed = parseImagePropertyDate(rawValue)
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

    private func parseImagePropertyDate(_ rawValue: String) -> Date? {
        for formatter in dateFormatters {
            if let date = formatter.date(from: rawValue) {
                return date
            }
        }
        return nil
    }

    private var dateFormatters: [DateFormatter] {
        [
            Self.exifFormatter,
            Self.isoLikeFormatter,
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
}

public struct FileDateResolver: Sendable {
    public var metadataReader: any MediaMetadataDateReading

    public init(metadataReader: any MediaMetadataDateReading = NativeMediaMetadataDateReader()) {
        self.metadataReader = metadataReader
    }

    public func resolveDate(for path: String) -> Date? {
        let url = URL(fileURLWithPath: path)

        if MediaLibraryRules.isPhotoFile(path: path),
           let metadataDate = metadataReader.photoMetadataDate(at: url),
           !DateClassification.isUnknown(metadataDate) {
            return metadataDate
        }

        if let filenameDate = FilenameDateParser.parse(from: path) {
            return filenameDate
        }

        if let creationDate = metadataReader.fileSystemCreationDate(at: url),
           !DateClassification.isUnknown(creationDate) {
            return creationDate
        }

        if let modificationDate = metadataReader.fileSystemModificationDate(at: url),
           !DateClassification.isUnknown(modificationDate) {
            return modificationDate
        }

        return nil
    }
}

import Foundation

enum PlanningPathBuilder {
    static func buildDestinationPath(
        for sourcePath: String,
        destinationRoot: String,
        dateBucket: String,
        sequence: Int,
        duplicateDirectoryName: String?,
        namingRules: PlannerNamingRules,
        folderStructure: FolderStructure = .yyyyMMDD,
        sourceRoot: String? = nil,
        minimumSequenceWidth: Int? = nil
    ) -> String {
        let fileExtension = URL(fileURLWithPath: sourcePath).pathExtension
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        let sequenceString = formatSequence(
            sequence,
            minimumWidth: minimumSequenceWidth ?? namingRules.sequenceWidth
        )

        var path = URL(fileURLWithPath: destinationRoot, isDirectory: true)
        if let duplicateDirectoryName {
            path.appendPathComponent(duplicateDirectoryName, isDirectory: true)
        }

        if dateBucket == namingRules.unknownDateDirectoryName {
            path.appendPathComponent(namingRules.unknownDateDirectoryName, isDirectory: true)
            if folderStructure == .yyyyMonEvent, let sourceRoot {
                let event = eventSubpath(sourcePath: sourcePath, sourceRoot: sourceRoot)
                if !event.isEmpty {
                    path.appendPathComponent(event, isDirectory: true)
                }
            }
            let filename = "\(namingRules.unknownFilenamePrefix)\(sequenceString)\(suffix)"
            return path.appendingPathComponent(filename).path
        }

        let filename = "\(dateBucket)_\(sequenceString)\(suffix)"
        let components = dateBucket.split(separator: "-")

        switch folderStructure {
        case .yyyyMMDD:
            if components.count == 3 {
                path.appendPathComponent(String(components[0]), isDirectory: true)
                path.appendPathComponent(String(components[1]), isDirectory: true)
                path.appendPathComponent(String(components[2]), isDirectory: true)
            }
        case .yyyyMM:
            if components.count == 3 {
                path.appendPathComponent(String(components[0]), isDirectory: true)
                path.appendPathComponent(String(components[1]), isDirectory: true)
            }
        case .yyyy:
            if components.count == 3 {
                path.appendPathComponent(String(components[0]), isDirectory: true)
            }
        case .yyyyMonEvent:
            if components.count == 3,
               let monthInt = Int(components[1]),
               (1...12).contains(monthInt) {
                path.appendPathComponent(String(components[0]), isDirectory: true)
                path.appendPathComponent(monthAbbreviation(monthInt), isDirectory: true)
                if let sourceRoot {
                    let event = eventSubpath(sourcePath: sourcePath, sourceRoot: sourceRoot)
                    if !event.isEmpty {
                        path.appendPathComponent(event, isDirectory: true)
                    }
                }
            }
        case .flat:
            break
        }

        return path.appendingPathComponent(filename).path
    }

    static func formatSequence(_ sequence: Int, minimumWidth: Int) -> String {
        let width = max(minimumWidth, String(sequence).count)
        return String(format: "%0\(width)d", sequence)
    }

    static func maxSequence(for width: Int) -> Int {
        Int(pow(10.0, Double(width))) - 1
    }

    /// Mirrors Python `_event_subpath` in `chronoframe/core.py`: returns the immediate
    /// parent folder name of `sourcePath` relative to `sourceRoot`, or "" when the
    /// file sits directly inside `sourceRoot`.
    static func eventSubpath(sourcePath: String, sourceRoot: String) -> String {
        let parentURL = URL(fileURLWithPath: sourcePath)
            .deletingLastPathComponent()
            .standardizedFileURL
        let rootURL = URL(fileURLWithPath: sourceRoot, isDirectory: true)
            .standardizedFileURL

        if parentURL.path == rootURL.path {
            return ""
        }
        return parentURL.lastPathComponent
    }

    private static let monthAbbreviations = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    private static func monthAbbreviation(_ month: Int) -> String {
        monthAbbreviations[month - 1]
    }
}

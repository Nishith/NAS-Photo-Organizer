import Foundation

enum PlanningPathBuilder {
    static func buildDestinationPath(
        for sourcePath: String,
        destinationRoot: String,
        dateBucket: String,
        sequence: Int,
        duplicateDirectoryName: String?,
        namingRules: PlannerNamingRules
    ) -> String {
        let fileExtension = URL(fileURLWithPath: sourcePath).pathExtension
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        let sequenceString = formatSequence(sequence, minimumWidth: namingRules.sequenceWidth)

        var path = URL(fileURLWithPath: destinationRoot, isDirectory: true)
        if let duplicateDirectoryName {
            path.appendPathComponent(duplicateDirectoryName, isDirectory: true)
        }

        if dateBucket == namingRules.unknownDateDirectoryName {
            path.appendPathComponent(namingRules.unknownDateDirectoryName, isDirectory: true)
            return path
                .appendingPathComponent("\(namingRules.unknownFilenamePrefix)\(sequenceString)\(suffix)")
                .path
        }

        let components = dateBucket.split(separator: "-")
        if components.count == 3 {
            path.appendPathComponent(String(components[0]), isDirectory: true)
            path.appendPathComponent(String(components[1]), isDirectory: true)
            path.appendPathComponent(String(components[2]), isDirectory: true)
        }
        return path
            .appendingPathComponent("\(dateBucket)_\(sequenceString)\(suffix)")
            .path
    }

    static func formatSequence(_ sequence: Int, minimumWidth: Int) -> String {
        let width = max(minimumWidth, String(sequence).count)
        return String(format: "%0\(width)d", sequence)
    }

    static func maxSequence(for width: Int) -> Int {
        Int(pow(10.0, Double(width))) - 1
    }
}

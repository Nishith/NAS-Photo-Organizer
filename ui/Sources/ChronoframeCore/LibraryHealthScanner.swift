import Foundation

public enum LibraryHealthSeverity: String, Codable, Sendable {
    case good
    case attention
    case critical
}

public enum LibraryHealthAction: String, Codable, Sendable, CaseIterable {
    case runPreview
    case reviewUnknownDates
    case runDeduplicate
    case openHistory
    case reorganizeDestination
    case refreshDestinationIndex

    public var title: String {
        switch self {
        case .runPreview:
            return "Run Preview"
        case .reviewUnknownDates:
            return "Review Unknown Dates"
        case .runDeduplicate:
            return "Run Deduplicate"
        case .openHistory:
            return "Open History"
        case .reorganizeDestination:
            return "Reorganize Destination"
        case .refreshDestinationIndex:
            return "Refresh Destination Index"
        }
    }
}

public struct LibraryHealthCard: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var title: String
    public var value: String
    public var message: String
    public var severity: LibraryHealthSeverity
    public var action: LibraryHealthAction?

    public init(
        id: String,
        title: String,
        value: String,
        message: String,
        severity: LibraryHealthSeverity,
        action: LibraryHealthAction? = nil
    ) {
        self.id = id
        self.title = title
        self.value = value
        self.message = message
        self.severity = severity
        self.action = action
    }
}

public struct LibraryHealthSummary: Equatable, Codable, Sendable {
    public var generatedAt: Date
    public var destinationRoot: String
    public var overallSeverity: LibraryHealthSeverity
    public var cards: [LibraryHealthCard]

    public init(
        generatedAt: Date = Date(),
        destinationRoot: String,
        overallSeverity: LibraryHealthSeverity,
        cards: [LibraryHealthCard]
    ) {
        self.generatedAt = generatedAt
        self.destinationRoot = destinationRoot
        self.overallSeverity = overallSeverity
        self.cards = cards
    }
}

public struct LibraryHealthScanner: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func scan(
        sourceRoot: String,
        destinationRoot: String,
        folderStructure: FolderStructure,
        namingRules: PlannerNamingRules = .pythonReference
    ) -> LibraryHealthSummary {
        let destination = destinationRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else {
            return LibraryHealthSummary(
                destinationRoot: "",
                overallSeverity: .attention,
                cards: [
                    LibraryHealthCard(
                        id: "ready",
                        title: "Ready to Organize",
                        value: "Needs destination",
                        message: "Choose a destination folder before checking library health.",
                        severity: .attention,
                        action: .runPreview
                    ),
                ]
            )
        }

        let destinationURL = URL(fileURLWithPath: destination, isDirectory: true)
        var isDirectory: ObjCBool = false
        let destinationExists = fileManager.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory) && isDirectory.boolValue

        var cards: [LibraryHealthCard] = [
            readyCard(
                sourceRoot: sourceRoot,
                destinationRoot: destination,
                destinationExists: destinationExists
            ),
        ]

        let singlePass = collectStats(destinationURL: destinationURL, namingRules: namingRules)

        let unknownStats = (count: singlePass.unknownCount, bytes: singlePass.unknownBytes)
        cards.append(
            LibraryHealthCard(
                id: "unknown-dates",
                title: "Unknown Dates",
                value: unknownStats.count.formatted(),
                message: unknownStats.count == 0
                    ? "No files are currently parked in Unknown_Date."
                    : "\(formattedBytes(unknownStats.bytes)) need a date decision.",
                severity: unknownStats.count == 0 ? .good : .attention,
                action: unknownStats.count == 0 ? nil : .reviewUnknownDates
            )
        )

        let duplicateStats = (count: singlePass.duplicateCount, bytes: singlePass.duplicateBytes)
        let cachedDuplicateStats = cachedDuplicateStats(destinationURL: destinationURL)
        let duplicateBytes = max(duplicateStats.bytes, cachedDuplicateStats.bytes)
        let duplicateCount = max(duplicateStats.count, cachedDuplicateStats.count)
        cards.append(
            LibraryHealthCard(
                id: "duplicates",
                title: "Duplicates",
                value: duplicateCount.formatted(),
                message: duplicateCount == 0
                    ? "No exact duplicate hints are visible from the destination cache."
                    : "\(formattedBytes(duplicateBytes)) may be recoverable after review.",
                severity: duplicateCount == 0 ? .good : .attention,
                action: duplicateCount == 0 ? nil : .runDeduplicate
            )
        )

        let queueStats = copyQueueStats(destinationURL: destinationURL)
        cards.append(
            LibraryHealthCard(
                id: "interrupted-work",
                title: "Interrupted Work",
                value: "\(queueStats.pending + queueStats.failed)",
                message: queueStats.pending + queueStats.failed == 0
                    ? "There are no pending or failed copy jobs in the queue."
                    : "\(queueStats.pending) pending, \(queueStats.failed) failed jobs need attention.",
                severity: queueStats.failed > 0 ? .critical : (queueStats.pending > 0 ? .attention : .good),
                action: queueStats.pending + queueStats.failed == 0 ? nil : .runPreview
            )
        )

        let receiptCount = receiptCount(destinationURL: destinationURL)
        cards.append(
            LibraryHealthCard(
                id: "history",
                title: "History & Revert Safety",
                value: receiptCount.formatted(),
                message: receiptCount == 0
                    ? "No audit receipts were found for this destination yet."
                    : "Audit receipts are available for recent organized runs.",
                severity: receiptCount == 0 ? .attention : .good,
                action: .openHistory
            )
        )

        let driftCount = singlePass.driftCount
        cards.append(
            LibraryHealthCard(
                id: "structure-drift",
                title: "Structure Drift",
                value: driftCount.formatted(),
                message: driftCount == 0
                    ? "Recognized media filenames match Chronoframe's naming pattern."
                    : "Some media files do not look like Chronoframe-planned destinations.",
                severity: driftCount == 0 ? .good : .attention,
                action: driftCount == 0 ? nil : .reorganizeDestination
            )
        )

        let overall: LibraryHealthSeverity
        if cards.contains(where: { $0.severity == .critical }) {
            overall = .critical
        } else if cards.contains(where: { $0.severity == .attention }) {
            overall = .attention
        } else {
            overall = .good
        }

        return LibraryHealthSummary(
            destinationRoot: destination,
            overallSeverity: overall,
            cards: cards
        )
    }

    private func readyCard(
        sourceRoot: String,
        destinationRoot: String,
        destinationExists: Bool
    ) -> LibraryHealthCard {
        let hasSource = !sourceRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if destinationExists && hasSource {
            return LibraryHealthCard(
                id: "ready",
                title: "Ready to Organize",
                value: "Ready",
                message: "Source and destination are configured.",
                severity: .good,
                action: .runPreview
            )
        }

        return LibraryHealthCard(
            id: "ready",
            title: "Ready to Organize",
            value: destinationExists ? "Needs source" : "Needs destination",
            message: destinationExists
                ? "Choose a source folder before the next preview."
                : "The destination folder is missing or unavailable.",
            severity: .attention,
            action: .runPreview
        )
    }

    private struct SinglePassStats {
        var unknownCount: Int = 0
        var unknownBytes: Int64 = 0
        var duplicateCount: Int = 0
        var duplicateBytes: Int64 = 0
        var driftCount: Int = 0
    }

    private func collectStats(
        destinationURL: URL,
        namingRules: PlannerNamingRules
    ) -> SinglePassStats {
        var stats = SinglePassStats()
        let unknownComponent = "/" + namingRules.unknownDateDirectoryName + "/"
        let duplicateComponent = "/" + namingRules.duplicateDirectoryName + "/"
        let destPrefix = destinationURL.path.hasSuffix("/")
            ? destinationURL.path
            : destinationURL.path + "/"

        guard let enumerator = fileManager.enumerator(
            at: destinationURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return stats }

        for case let fileURL as URL in enumerator {
            guard MediaLibraryRules.isSupportedMediaFile(path: fileURL.path) else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }

            let filePath = fileURL.path
            let relativePath = filePath.hasPrefix(destPrefix)
                ? String(filePath.dropFirst(destPrefix.count))
                : filePath
            let fileSize = Int64(values.fileSize ?? 0)

            if relativePath.contains(unknownComponent) || relativePath.hasPrefix(namingRules.unknownDateDirectoryName + "/") {
                stats.unknownCount += 1
                stats.unknownBytes += fileSize
            } else if relativePath.contains(duplicateComponent) || relativePath.hasPrefix(namingRules.duplicateDirectoryName + "/") {
                stats.duplicateCount += 1
                stats.duplicateBytes += fileSize
            }

            if !isChronoframePlannedFile(fileURL.lastPathComponent, namingRules: namingRules) {
                stats.driftCount += 1
            }
        }
        return stats
    }

    private func cachedDuplicateStats(destinationURL: URL) -> (count: Int, bytes: Int64) {
        let databaseURL = destinationURL.appendingPathComponent(EngineArtifactLayout.pythonReference.queueDatabaseFilename)
        guard fileManager.fileExists(atPath: databaseURL.path),
              let database = try? OrganizerDatabase(url: databaseURL, readOnly: true) else {
            return (0, 0)
        }
        defer { database.close() }

        guard let records = try? database.loadRawCacheRecords(namespace: .destination) else {
            return (0, 0)
        }

        let groups = Dictionary(grouping: records) { $0.hash }
        var duplicateCount = 0
        var duplicateBytes: Int64 = 0
        for records in groups.values where records.count > 1 {
            let sorted = records.sorted { $0.size > $1.size }
            duplicateCount += max(0, sorted.count - 1)
            duplicateBytes += sorted.dropFirst().reduce(Int64(0)) { $0 + $1.size }
        }
        return (duplicateCount, duplicateBytes)
    }

    private func copyQueueStats(destinationURL: URL) -> (pending: Int, failed: Int) {
        let databaseURL = destinationURL.appendingPathComponent(EngineArtifactLayout.pythonReference.queueDatabaseFilename)
        guard fileManager.fileExists(atPath: databaseURL.path),
              let database = try? OrganizerDatabase(url: databaseURL, readOnly: true) else {
            return (0, 0)
        }
        defer { database.close() }

        return (
            (try? database.queuedJobCount(status: .pending)) ?? 0,
            (try? database.queuedJobCount(status: .failed)) ?? 0
        )
    }

    private func receiptCount(destinationURL: URL) -> Int {
        let logsURL = destinationURL.appendingPathComponent(EngineArtifactLayout.pythonReference.logsDirectoryName, isDirectory: true)
        guard let contents = try? fileManager.contentsOfDirectory(at: logsURL, includingPropertiesForKeys: nil) else {
            return 0
        }
        return contents.filter {
            let name = $0.lastPathComponent
            return name.hasPrefix("audit_receipt_") || name.hasPrefix("dedupe_audit_receipt_")
        }.count
    }

    private func isChronoframePlannedFile(_ filename: String, namingRules: PlannerNamingRules) -> Bool {
        if filename.hasPrefix(namingRules.unknownFilenamePrefix) {
            return true
        }
        guard filename.count >= 15 else { return false }
        let dateEndIndex = filename.index(filename.startIndex, offsetBy: 10)
        let datePart = filename[..<dateEndIndex]
        let separatorIndex = filename.index(filename.startIndex, offsetBy: 10)
        guard filename[separatorIndex] == "_" else { return false }
        return isISODay(datePart)
    }

    private func isISODay(_ value: Substring) -> Bool {
        guard value.count == 10 else { return false }
        for (offset, character) in value.enumerated() {
            switch offset {
            case 4, 7:
                guard character == "-" else { return false }
            default:
                guard character.isASCII && character.isNumber else { return false }
            }
        }
        return true
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

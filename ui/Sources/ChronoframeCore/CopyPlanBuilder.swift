import Foundation

public struct PlanningFileCandidate: Equatable, Codable, Sendable {
    public var sourcePath: String
    public var identity: FileIdentity?
    public var capturedAt: Date?

    public init(
        sourcePath: String,
        identity: FileIdentity?,
        capturedAt: Date?
    ) {
        self.sourcePath = sourcePath
        self.identity = identity
        self.capturedAt = capturedAt
    }
}

public struct CopyPlanCounts: Equatable, Codable, Sendable {
    public var alreadyInDestinationCount: Int
    public var newCount: Int
    public var duplicateCount: Int
    public var hashErrorCount: Int

    public init(
        alreadyInDestinationCount: Int = 0,
        newCount: Int = 0,
        duplicateCount: Int = 0,
        hashErrorCount: Int = 0
    ) {
        self.alreadyInDestinationCount = alreadyInDestinationCount
        self.newCount = newCount
        self.duplicateCount = duplicateCount
        self.hashErrorCount = hashErrorCount
    }
}

public struct CopyPlanResult: Equatable, Codable, Sendable {
    public var transfers: [PlannedTransfer]
    public var counts: CopyPlanCounts
    public var warningMessages: [String]
    public var sequenceState: SequenceCounterState
    public var infoMessages: [String]
    public var dateHistogram: [DateHistogramBucket]

    public init(
        transfers: [PlannedTransfer],
        counts: CopyPlanCounts,
        warningMessages: [String],
        sequenceState: SequenceCounterState,
        infoMessages: [String] = [],
        dateHistogram: [DateHistogramBucket] = []
    ) {
        self.transfers = transfers
        self.counts = counts
        self.warningMessages = warningMessages
        self.sequenceState = sequenceState
        self.infoMessages = infoMessages
        self.dateHistogram = dateHistogram
    }

    private enum CodingKeys: String, CodingKey {
        case transfers, counts, warningMessages, sequenceState, infoMessages, dateHistogram
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.transfers = try container.decode([PlannedTransfer].self, forKey: .transfers)
        self.counts = try container.decode(CopyPlanCounts.self, forKey: .counts)
        self.warningMessages = try container.decodeIfPresent([String].self, forKey: .warningMessages) ?? []
        self.sequenceState = try container.decode(SequenceCounterState.self, forKey: .sequenceState)
        self.infoMessages = try container.decodeIfPresent([String].self, forKey: .infoMessages) ?? []
        self.dateHistogram = try container.decodeIfPresent([DateHistogramBucket].self, forKey: .dateHistogram) ?? []
    }

    public var transferCount: Int {
        transfers.count
    }

    public var copyJobs: [CopyJobRecord] {
        transfers.map { transfer in
            CopyJobRecord(
                sourcePath: transfer.sourcePath,
                destinationPath: transfer.destinationPath,
                identity: transfer.identity,
                status: .pending
            )
        }
    }
}

public enum CopyPlanBuilder {
    public static func build(
        sourceFiles: [PlanningFileCandidate],
        destinationSnapshot: DestinationIndexSnapshot,
        destinationRoot: String,
        namingRules: PlannerNamingRules = .pythonReference,
        folderStructure: FolderStructure = .yyyyMMDD,
        sourceRoot: String? = nil
    ) -> CopyPlanResult {
        var counts = CopyPlanCounts()
        var sourceSeen: [FileIdentity: PlanningFileCandidate] = [:]
        var newFilesByDate: [String: [(PlanningFileCandidate, FileIdentity)]] = [:]
        var duplicatesByDate: [String: [(PlanningFileCandidate, FileIdentity)]] = [:]

        for file in sourceFiles {
            guard let identity = file.identity else {
                counts.hashErrorCount += 1
                continue
            }

            let dateBucket = dateBucket(for: file.capturedAt, namingRules: namingRules)

            if destinationSnapshot.pathsByIdentity[identity] != nil {
                counts.alreadyInDestinationCount += 1
                continue
            }

            if sourceSeen[identity] != nil {
                duplicatesByDate[dateBucket, default: []].append((file, identity))
                counts.duplicateCount += 1
                continue
            }

            sourceSeen[identity] = file
            newFilesByDate[dateBucket, default: []].append((file, identity))
            counts.newCount += 1
        }

        var primarySequences = destinationSnapshot.sequenceState.primaryByDate
        var duplicateSequences = destinationSnapshot.sequenceState.duplicatesByDate
        var overflowDates: [String] = []
        var infoMessages: [String] = []
        var plannedTransfers: [PlannedTransfer] = []

        for dateBucket in newFilesByDate.keys.sorted() {
            let groupedFiles = newFilesByDate[dateBucket] ?? []
            let existingMaxSequence = primarySequences[dateBucket] ?? 0
            let startSequence = existingMaxSequence + 1
            let endSequence = startSequence + groupedFiles.count - 1
            let dayWidth = plannedSequenceWidth(
                existingMaxSequence: existingMaxSequence,
                newItemCount: groupedFiles.count,
                defaultWidth: namingRules.sequenceWidth
            )

            if shouldWarnAboutSequenceWidth(
                existingMaxSequence: existingMaxSequence,
                plannedWidth: dayWidth,
                defaultWidth: namingRules.sequenceWidth
            ) {
                overflowDates.append(dateBucket)
            } else if shouldEmitSequenceWidthInfo(
                existingMaxSequence: existingMaxSequence,
                plannedWidth: dayWidth,
                defaultWidth: namingRules.sequenceWidth
            ) {
                infoMessages.append(
                    sequenceWidthInfoMessage(
                        dateBucket: dateBucket,
                        count: groupedFiles.count,
                        width: dayWidth
                    )
                )
            }

            for (offset, item) in groupedFiles.enumerated() {
                let sequence = startSequence + offset
                let destinationPath = buildDestinationPath(
                    for: item.0.sourcePath,
                    destinationRoot: destinationRoot,
                    dateBucket: dateBucket,
                    sequence: sequence,
                    duplicateDirectoryName: nil,
                    namingRules: namingRules,
                    folderStructure: folderStructure,
                    sourceRoot: sourceRoot,
                    minimumSequenceWidth: dayWidth
                )
                plannedTransfers.append(
                    PlannedTransfer(
                        sourcePath: item.0.sourcePath,
                        destinationPath: destinationPath,
                        identity: item.1,
                        dateBucket: dateBucket,
                        isDuplicate: false
                    )
                )
            }

            primarySequences[dateBucket] = endSequence
        }

        for dateBucket in duplicatesByDate.keys.sorted() {
            let groupedFiles = duplicatesByDate[dateBucket] ?? []
            let existingMaxSequence = duplicateSequences[dateBucket] ?? 0
            let startSequence = existingMaxSequence + 1
            let endSequence = startSequence + groupedFiles.count - 1
            let dayWidth = plannedSequenceWidth(
                existingMaxSequence: existingMaxSequence,
                newItemCount: groupedFiles.count,
                defaultWidth: namingRules.sequenceWidth
            )

            for (offset, item) in groupedFiles.enumerated() {
                let sequence = startSequence + offset
                let destinationPath = buildDestinationPath(
                    for: item.0.sourcePath,
                    destinationRoot: destinationRoot,
                    dateBucket: dateBucket,
                    sequence: sequence,
                    duplicateDirectoryName: namingRules.duplicateDirectoryName,
                    namingRules: namingRules,
                    folderStructure: folderStructure,
                    sourceRoot: sourceRoot,
                    minimumSequenceWidth: dayWidth
                )
                plannedTransfers.append(
                    PlannedTransfer(
                        sourcePath: item.0.sourcePath,
                        destinationPath: destinationPath,
                        identity: item.1,
                        dateBucket: dateBucket,
                        isDuplicate: true
                    )
                )
            }

            duplicateSequences[dateBucket] = endSequence
        }

        let warningMessages = overflowDates.isEmpty
            ? []
            : [
                "Sequence overflow on dates (>\(maxSequence(for: namingRules.sequenceWidth)) files/day): \(overflowDates.joined(separator: ", "))",
            ]

        return CopyPlanResult(
            transfers: plannedTransfers,
            counts: counts,
            warningMessages: warningMessages,
            sequenceState: SequenceCounterState(
                primaryByDate: primarySequences,
                duplicatesByDate: duplicateSequences
            ),
            infoMessages: infoMessages,
            dateHistogram: dateHistogram(from: plannedTransfers, namingRules: namingRules)
        )
    }

    static func dateHistogram(
        from transfers: [PlannedTransfer],
        namingRules: PlannerNamingRules
    ) -> [DateHistogramBucket] {
        var countsByBucket: [String: Int] = [:]
        for transfer in transfers {
            countsByBucket[histogramKey(for: transfer.dateBucket, namingRules: namingRules), default: 0] += 1
        }

        return countsByBucket.keys.sorted(by: histogramSort).map { key in
            DateHistogramBucket(key: key, plannedCount: countsByBucket[key] ?? 0)
        }
    }

    static func plannedSequenceWidth(
        existingMaxSequence: Int,
        newItemCount: Int,
        defaultWidth: Int
    ) -> Int {
        guard newItemCount > 0 else {
            return existingSequenceWidth(existingMaxSequence, defaultWidth: defaultWidth)
        }
        let endSequence = existingMaxSequence + newItemCount
        return max(defaultWidth, digitCount(endSequence))
    }

    static func shouldWarnAboutSequenceWidth(
        existingMaxSequence: Int,
        plannedWidth: Int,
        defaultWidth: Int
    ) -> Bool {
        guard existingMaxSequence > 0 else {
            return false
        }
        return plannedWidth > existingSequenceWidth(existingMaxSequence, defaultWidth: defaultWidth)
    }

    static func shouldEmitSequenceWidthInfo(
        existingMaxSequence: Int,
        plannedWidth: Int,
        defaultWidth: Int
    ) -> Bool {
        existingMaxSequence == 0 && plannedWidth > defaultWidth
    }

    static func sequenceWidthInfoMessage(
        dateBucket: String,
        count: Int,
        width: Int
    ) -> String {
        "Day \(dateBucket): \(decimalString(count)) files — using \(width)-digit sequence numbers."
    }

    private static func buildDestinationPath(
        for sourcePath: String,
        destinationRoot: String,
        dateBucket: String,
        sequence: Int,
        duplicateDirectoryName: String?,
        namingRules: PlannerNamingRules,
        folderStructure: FolderStructure,
        sourceRoot: String?,
        minimumSequenceWidth: Int
    ) -> String {
        PlanningPathBuilder.buildDestinationPath(
            for: sourcePath,
            destinationRoot: destinationRoot,
            dateBucket: dateBucket,
            sequence: sequence,
            duplicateDirectoryName: duplicateDirectoryName,
            namingRules: namingRules,
            folderStructure: folderStructure,
            sourceRoot: sourceRoot,
            minimumSequenceWidth: minimumSequenceWidth
        )
    }

    private static func maxSequence(for width: Int) -> Int {
        PlanningPathBuilder.maxSequence(for: width)
    }

    private static func dateBucket(
        for capturedAt: Date?,
        namingRules: PlannerNamingRules
    ) -> String {
        DateClassification.bucket(for: capturedAt, namingRules: namingRules)
    }

    private static func histogramKey(
        for dateBucket: String,
        namingRules: PlannerNamingRules
    ) -> String {
        guard dateBucket != namingRules.unknownDateDirectoryName else {
            return "Unknown"
        }

        let components = dateBucket.split(separator: "-")
        guard components.count >= 2 else {
            return "Unknown"
        }

        return "\(components[0])-\(components[1])"
    }

    private static func histogramSort(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == "Unknown" {
            return false
        }
        if rhs == "Unknown" {
            return true
        }
        return lhs < rhs
    }

    private static func existingSequenceWidth(
        _ existingMaxSequence: Int,
        defaultWidth: Int
    ) -> Int {
        max(defaultWidth, digitCount(existingMaxSequence))
    }

    private static func digitCount(_ value: Int) -> Int {
        String(max(0, value)).count
    }

    private static func decimalString(_ value: Int) -> String {
        var result = ""
        for (index, character) in String(value).reversed().enumerated() {
            if index > 0, index.isMultiple(of: 3) {
                result.insert(",", at: result.startIndex)
            }
            result.insert(character, at: result.startIndex)
        }
        return result
    }
}

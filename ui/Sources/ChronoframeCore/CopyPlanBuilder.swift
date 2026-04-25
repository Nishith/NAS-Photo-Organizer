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

    public init(
        transfers: [PlannedTransfer],
        counts: CopyPlanCounts,
        warningMessages: [String],
        sequenceState: SequenceCounterState
    ) {
        self.transfers = transfers
        self.counts = counts
        self.warningMessages = warningMessages
        self.sequenceState = sequenceState
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
        var duplicates: [(PlanningFileCandidate, FileIdentity)] = []

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
                duplicates.append((file, identity))
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
        var plannedTransfers: [PlannedTransfer] = []

        for dateBucket in newFilesByDate.keys.sorted() {
            let groupedFiles = newFilesByDate[dateBucket] ?? []
            let startSequence = (primarySequences[dateBucket] ?? 0) + 1

            for (offset, item) in groupedFiles.enumerated() {
                let sequence = startSequence + offset
                if sequence > maxSequence(for: namingRules.sequenceWidth), !overflowDates.contains(dateBucket) {
                    overflowDates.append(dateBucket)
                }

                let destinationPath = buildDestinationPath(
                    for: item.0.sourcePath,
                    destinationRoot: destinationRoot,
                    dateBucket: dateBucket,
                    sequence: sequence,
                    duplicateDirectoryName: nil,
                    namingRules: namingRules,
                    folderStructure: folderStructure,
                    sourceRoot: sourceRoot
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

            primarySequences[dateBucket] = startSequence + groupedFiles.count - 1
        }

        for (file, identity) in duplicates {
            let dateBucket = dateBucket(for: file.capturedAt, namingRules: namingRules)
            let sequence = (duplicateSequences[dateBucket] ?? 0) + 1
            duplicateSequences[dateBucket] = sequence

            let destinationPath = buildDestinationPath(
                for: file.sourcePath,
                destinationRoot: destinationRoot,
                dateBucket: dateBucket,
                sequence: sequence,
                duplicateDirectoryName: namingRules.duplicateDirectoryName,
                namingRules: namingRules,
                folderStructure: folderStructure,
                sourceRoot: sourceRoot
            )
            plannedTransfers.append(
                PlannedTransfer(
                    sourcePath: file.sourcePath,
                    destinationPath: destinationPath,
                    identity: identity,
                    dateBucket: dateBucket,
                    isDuplicate: true
                )
            )
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
            )
        )
    }

    private static func buildDestinationPath(
        for sourcePath: String,
        destinationRoot: String,
        dateBucket: String,
        sequence: Int,
        duplicateDirectoryName: String?,
        namingRules: PlannerNamingRules,
        folderStructure: FolderStructure,
        sourceRoot: String?
    ) -> String {
        PlanningPathBuilder.buildDestinationPath(
            for: sourcePath,
            destinationRoot: destinationRoot,
            dateBucket: dateBucket,
            sequence: sequence,
            duplicateDirectoryName: duplicateDirectoryName,
            namingRules: namingRules,
            folderStructure: folderStructure,
            sourceRoot: sourceRoot
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
}

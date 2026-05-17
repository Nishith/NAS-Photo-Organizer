import XCTest
@testable import ChronoframeCore

final class ChronoframeCoreEngineDomainModelsTests: XCTestCase {
    func testFileIdentityRoundTripsThroughRawValue() {
        let identity = FileIdentity(size: 1234, digest: "deadbeef")
        XCTAssertEqual(identity.rawValue, "1234_deadbeef")

        let parsed = FileIdentity(rawValue: "1234_deadbeef")
        XCTAssertEqual(parsed, identity)
    }

    func testFileIdentityRejectsMalformedRawValues() {
        XCTAssertNil(FileIdentity(rawValue: ""))
        XCTAssertNil(FileIdentity(rawValue: "nodigest"))
        XCTAssertNil(FileIdentity(rawValue: "1234_"))
        XCTAssertNil(FileIdentity(rawValue: "abc_digest"))
    }

    func testFileCacheRecordIdentityStringMirrorsIdentity() {
        let identity = FileIdentity(size: 7, digest: "abc")
        let record = FileCacheRecord(
            namespace: .source,
            path: "/tmp/a.jpg",
            identity: identity,
            size: 7,
            modificationTime: 100.5
        )
        XCTAssertEqual(record.identityString, "7_abc")
        XCTAssertEqual(record.namespace, .source)
    }

    func testRawFileCacheRecordParsesAndPromotesValidHash() throws {
        let raw = RawFileCacheRecord(
            namespace: .destination,
            path: "/dst/a.jpg",
            hash: "42_cafef00d",
            size: 42,
            modificationTime: 999.0
        )
        XCTAssertEqual(raw.parsedIdentity, FileIdentity(size: 42, digest: "cafef00d"))
        let typed = try XCTUnwrap(raw.typedRecord)
        XCTAssertEqual(typed.namespace, .destination)
        XCTAssertEqual(typed.path, "/dst/a.jpg")
        XCTAssertEqual(typed.identity.digest, "cafef00d")
    }

    func testRawFileCacheRecordRejectsMalformedHash() {
        let raw = RawFileCacheRecord(
            namespace: .source,
            path: "/x",
            hash: "not-an-identity",
            size: 1,
            modificationTime: 0
        )
        XCTAssertNil(raw.parsedIdentity)
        XCTAssertNil(raw.typedRecord)
    }

    func testRawFileCacheRecordCopiesFromCacheRecord() {
        let identity = FileIdentity(size: 9, digest: "xyz")
        let typed = FileCacheRecord(
            namespace: .source,
            path: "/p",
            identity: identity,
            size: 9,
            modificationTime: 11.0
        )
        let raw = RawFileCacheRecord(cacheRecord: typed)
        XCTAssertEqual(raw.hash, "9_xyz")
        XCTAssertEqual(raw.namespace, .source)
        XCTAssertEqual(raw.path, "/p")
        XCTAssertEqual(raw.size, 9)
        XCTAssertEqual(raw.modificationTime, 11.0)
    }

    func testCopyJobRecordBuildsFromPlannedTransfer() {
        let planned = PlannedTransfer(
            sourcePath: "/s",
            destinationPath: "/d",
            identity: FileIdentity(size: 3, digest: "hh"),
            dateBucket: "2024/01/01",
            isDuplicate: false
        )
        let job = CopyJobRecord(plannedTransfer: planned)
        XCTAssertEqual(job.sourcePath, "/s")
        XCTAssertEqual(job.destinationPath, "/d")
        XCTAssertEqual(job.identity.rawValue, "3_hh")
        XCTAssertEqual(job.status, .pending)
        XCTAssertEqual(job.identityString, "3_hh")

        let copied = CopyJobRecord(plannedTransfer: planned, status: .copied)
        XCTAssertEqual(copied.status, .copied)
    }

    func testQueuedCopyJobConvertsBetweenShapes() throws {
        let identity = FileIdentity(size: 10, digest: "aa")
        let job = CopyJobRecord(
            sourcePath: "/s",
            destinationPath: "/d",
            identity: identity,
            status: .failed
        )
        let queued = QueuedCopyJob(copyJob: job)
        XCTAssertEqual(queued.hash, "10_aa")
        XCTAssertEqual(queued.status, .failed)
        XCTAssertEqual(queued.parsedIdentity, identity)
        let typed = try XCTUnwrap(queued.typedRecord)
        XCTAssertEqual(typed, job)

        let planned = PlannedTransfer(
            sourcePath: "/s2",
            destinationPath: "/d2",
            identity: FileIdentity(size: 5, digest: "bb"),
            dateBucket: "2024/02",
            isDuplicate: true
        )
        let fromPlanned = QueuedCopyJob(plannedTransfer: planned, status: .skipped)
        XCTAssertEqual(fromPlanned.hash, "5_bb")
        XCTAssertEqual(fromPlanned.status, .skipped)

        let fromPlannedDefault = QueuedCopyJob(plannedTransfer: planned)
        XCTAssertEqual(fromPlannedDefault.status, .pending)
    }

    func testQueuedCopyJobReportsNilForMalformedHash() {
        let queued = QueuedCopyJob(
            sourcePath: "/s",
            destinationPath: "/d",
            hash: "garbage",
            status: .pending
        )
        XCTAssertNil(queued.parsedIdentity)
        XCTAssertNil(queued.typedRecord)
    }

    func testSequenceCounterStateInitialisesEmpty() {
        let empty = SequenceCounterState()
        XCTAssertTrue(empty.primaryByDate.isEmpty)
        XCTAssertTrue(empty.duplicatesByDate.isEmpty)

        let populated = SequenceCounterState(
            primaryByDate: ["2024/01/01": 3],
            duplicatesByDate: ["2024/01/01": 1]
        )
        XCTAssertEqual(populated.primaryByDate["2024/01/01"], 3)
        XCTAssertEqual(populated.duplicatesByDate["2024/01/01"], 1)
    }

    func testEngineArtifactLayoutAndPlannerNamingRulesDefaultsAreStable() {
        let layout = EngineArtifactLayout(
            queueDatabaseFilename: "queue.db",
            runLogFilename: "log.txt",
            logsDirectoryName: "logs",
            dryRunReportPrefix: "dry_",
            auditReceiptPrefix: "audit_"
        )
        XCTAssertEqual(layout.queueDatabaseFilename, "queue.db")
        XCTAssertEqual(layout.auditReceiptPrefix, "audit_")
        XCTAssertEqual(EngineArtifactLayout.chronoframeDefault.queueDatabaseFilename, ".organize_cache.db")
        XCTAssertEqual(EngineArtifactLayout.chronoframeDefault.logsDirectoryName, ".organize_logs")

        let rules = PlannerNamingRules(
            sequenceWidth: 4,
            duplicateDirectoryName: "Dup",
            unknownDateDirectoryName: "Unknown",
            unknownFilenamePrefix: "U_",
            collisionSuffixPrefix: "_c_"
        )
        XCTAssertEqual(rules.sequenceWidth, 4)
        XCTAssertEqual(PlannerNamingRules.chronoframeDefault.sequenceWidth, 3)
        XCTAssertEqual(PlannerNamingRules.chronoframeDefault.duplicateDirectoryName, "Duplicate")
        XCTAssertEqual(PlannerNamingRules.chronoframeDefault.unknownDateDirectoryName, "Unknown_Date")
    }

    func testFolderStructureDefaultAndCasesAreStable() {
        XCTAssertEqual(FolderStructure.default, .yyyyMMDD)
        XCTAssertEqual(FolderStructure(rawValue: "YYYY/MM/DD"), .yyyyMMDD)
        XCTAssertEqual(FolderStructure(rawValue: "Flat"), .flat)
        XCTAssertNil(FolderStructure(rawValue: "Unknown"))
        XCTAssertTrue(FolderStructure.allCases.contains(.yyyyMonEvent))
    }

    func testRetryPolicyAndFailureThresholdsCustomShapes() {
        let policy = RetryPolicy(
            maxAttempts: 7,
            minimumBackoffSeconds: 0.5,
            maximumBackoffSeconds: 20,
            nonRetryableErrnos: [42]
        )
        XCTAssertEqual(policy.maxAttempts, 7)
        XCTAssertEqual(policy.nonRetryableErrnos, [42])
        XCTAssertEqual(RetryPolicy.chronoframeDefault.maxAttempts, 5)
        XCTAssertTrue(RetryPolicy.chronoframeDefault.nonRetryableErrnos.contains(28))

        let thresholds = FailureThresholds(consecutive: 2, total: 8)
        XCTAssertEqual(thresholds.consecutive, 2)
        XCTAssertEqual(thresholds.total, 8)
        XCTAssertEqual(FailureThresholds.chronoframeDefault.consecutive, 5)
        XCTAssertEqual(FailureThresholds.chronoframeDefault.total, 20)
    }
}

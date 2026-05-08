import Foundation
import XCTest
@testable import ChronoframeAppCore
@testable import ChronoframeCore

final class DeduplicateSessionStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "DeduplicateSessionStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// The commit footer's "X files will be moved to Trash" + recoverable
    /// bytes are read from `currentDeletionPlan()`. That plan must be the
    /// same one the executor consumes at commit time, so what the user
    /// sees in the footer is what actually happens. This regression test
    /// pins down the contract by constructing a cluster whose
    /// pair-expanded MOV partner is NOT a cluster member, then asserting
    /// the count + bytes include the partner.
    @MainActor
    func testCurrentDeletionPlanIncludesPairExpandedPartners() async throws {
        let clusterID = UUID()
        let heic = PhotoCandidate(
            path: "/dest/IMG.HEIC",
            size: 100,
            modificationTime: 0,
            isLivePhotoStill: true,
            pairedPath: "/dest/IMG.MOV"
        )
        let other = PhotoCandidate(
            path: "/dest/OTHER.HEIC",
            size: 50,
            modificationTime: 0,
            qualityScore: 0.9
        )
        let cluster = DuplicateCluster(
            id: clusterID,
            kind: .burst,
            members: [heic, other],
            suggestedKeeperIDs: ["/dest/OTHER.HEIC"],
            bytesIfPruned: 100
        )

        let engine = MockDeduplicateEngine(
            clusters: [cluster],
            summary: DeduplicateSummary(totalCandidatesScanned: 2)
        )
        let store = DeduplicateSessionStore(engine: engine)
        let configuration = DeduplicateConfiguration(
            destinationPath: "/dest",
            treatRawJpegPairsAsUnit: true,
            treatLivePhotoPairsAsUnit: true
        )

        store.startScan(configuration: configuration)
        let scanned = await waitForCondition { store.status == .readyToReview }
        XCTAssertTrue(scanned)
        XCTAssertEqual(store.clusters.count, 1)

        // The session store accepts suggestions on scan complete, so
        // OTHER.HEIC is keep and IMG.HEIC is delete by default.
        let plan = store.currentDeletionPlan()
        XCTAssertEqual(plan.count, 2, "Plan must include the MOV partner via pair expansion")
        let paths = Set(plan.pathsToDelete)
        XCTAssertTrue(paths.contains("/dest/IMG.HEIC"))
        XCTAssertTrue(paths.contains("/dest/IMG.MOV"))
        XCTAssertEqual(store.pendingDeleteCount, plan.count, "pendingDeleteCount must mirror the plan count")
        XCTAssertEqual(store.totalRecoverableBytes, plan.totalBytes, "totalRecoverableBytes must mirror the plan total")
    }

    @MainActor
    func testSecurityScopeClosesAfterScanAndCommitCompletion() async throws {
        let scanTracker = SecurityScopeCloseTracker()
        let commitTracker = SecurityScopeCloseTracker()
        let engine = MockDeduplicateEngine(
            summary: DeduplicateSummary(totalCandidatesScanned: 0),
            commitEvents: [
                .started(totalToDelete: 0),
                .complete(DeduplicateCommitSummary(
                    deletedCount: 0,
                    failedCount: 0,
                    bytesReclaimed: 0,
                    receiptPath: nil,
                    hardDelete: false
                )),
            ]
        )
        let store = DeduplicateSessionStore(engine: engine)
        let configuration = DeduplicateConfiguration(destinationPath: "/dest")

        store.startScan(configuration: configuration, securityScope: scanTracker.makeScope())
        let scanned = await waitForCondition { store.status == .readyToReview }
        XCTAssertTrue(scanned)
        XCTAssertEqual(scanTracker.closeCount, 1)

        store.commit(configuration: configuration, securityScope: commitTracker.makeScope())
        let committed = await waitForCondition { store.status == .completed }
        XCTAssertTrue(committed)
        XCTAssertEqual(commitTracker.closeCount, 1)
        store.reset()
        XCTAssertEqual(commitTracker.closeCount, 1, "Reset after completion must not double-close the security scope")
    }

    /// The same plan-driven count must reflect a user toggle in real
    /// time: flipping the JPEG from delete back to keep removes both
    /// the JPEG and its RAW partner from the count.
    @MainActor
    func testCurrentDeletionPlanReactsToDecisionFlips() async throws {
        let clusterID = UUID()
        let raw = PhotoCandidate(
            path: "/dest/IMG.CR2",
            size: 200,
            modificationTime: 0,
            qualityScore: 0.5,
            isRaw: true,
            pairedPath: "/dest/IMG.JPG"
        )
        let jpeg = PhotoCandidate(
            path: "/dest/IMG.JPG",
            size: 100,
            modificationTime: 0,
            qualityScore: 0.4,
            pairedPath: "/dest/IMG.CR2"
        )
        let other = PhotoCandidate(
            path: "/dest/OTHER.JPG",
            size: 50,
            modificationTime: 0,
            qualityScore: 0.9
        )
        let cluster = DuplicateCluster(
            id: clusterID,
            kind: .nearDuplicate,
            members: [raw, jpeg, other],
            suggestedKeeperIDs: ["/dest/OTHER.JPG"],
            bytesIfPruned: 300
        )
        let engine = MockDeduplicateEngine(clusters: [cluster])
        let store = DeduplicateSessionStore(engine: engine)
        store.startScan(configuration: DeduplicateConfiguration(
            destinationPath: "/dest",
            treatRawJpegPairsAsUnit: true,
            treatLivePhotoPairsAsUnit: true
        ))
        _ = await waitForCondition { store.status == .readyToReview }

        // Default after suggestions: keep OTHER.JPG, delete RAW + JPEG.
        XCTAssertEqual(store.pendingDeleteCount, 2)
        XCTAssertEqual(store.totalRecoverableBytes, 300)

        // User explicitly flips the JPEG to keep — pair Keep-wins must
        // also protect the RAW partner.
        store.setDecision(.keep, forPath: "/dest/IMG.JPG")
        XCTAssertEqual(store.pendingDeleteCount, 0, "Pair Keep-wins must drop both RAW and JPEG from the plan")
        XCTAssertEqual(store.totalRecoverableBytes, 0)
    }

    @MainActor
    func testDefaultSuggestionsKeepOnlyOnePrimaryAndPreservePairWhenEnabled() async throws {
        let raw = PhotoCandidate(
            path: "/dest/IMG.CR2",
            size: 200,
            modificationTime: 0,
            qualityScore: 0.9,
            isRaw: true,
            pairedPath: "/dest/IMG.JPG"
        )
        let jpeg = PhotoCandidate(
            path: "/dest/IMG.JPG",
            size: 100,
            modificationTime: 0,
            qualityScore: 0.8,
            pairedPath: "/dest/IMG.CR2"
        )
        let other = PhotoCandidate(
            path: "/dest/OTHER.JPG",
            size: 50,
            modificationTime: 0,
            qualityScore: 0.7
        )
        let cluster = DuplicateCluster(
            kind: .nearDuplicate,
            members: [raw, jpeg, other],
            suggestedKeeperIDs: [raw.path],
            bytesIfPruned: 150
        )
        let store = DeduplicateSessionStore(engine: MockDeduplicateEngine(clusters: [cluster]))

        store.startScan(configuration: DeduplicateConfiguration(
            destinationPath: "/dest",
            treatRawJpegPairsAsUnit: true
        ))
        _ = await waitForCondition { store.status == .readyToReview }

        XCTAssertEqual(store.decisions.byPath[raw.path], .keep)
        XCTAssertEqual(store.decisions.byPath[jpeg.path], .keep, "Pair partner should be kept with the suggested primary")
        XCTAssertEqual(store.decisions.byPath[other.path], .delete)
        XCTAssertEqual(store.pendingDeleteCount, 1)
        XCTAssertEqual(store.totalRecoverableBytes, 50)
    }

    @MainActor
    func testDefaultSuggestionsDeletePairPartnerWhenPairingDisabled() async throws {
        let raw = PhotoCandidate(
            path: "/dest/IMG.CR2",
            size: 200,
            modificationTime: 0,
            qualityScore: 0.9,
            isRaw: true,
            pairedPath: "/dest/IMG.JPG"
        )
        let jpeg = PhotoCandidate(
            path: "/dest/IMG.JPG",
            size: 100,
            modificationTime: 0,
            qualityScore: 0.8,
            pairedPath: "/dest/IMG.CR2"
        )
        let other = PhotoCandidate(
            path: "/dest/OTHER.JPG",
            size: 50,
            modificationTime: 0,
            qualityScore: 0.7
        )
        let cluster = DuplicateCluster(
            kind: .nearDuplicate,
            members: [raw, jpeg, other],
            suggestedKeeperIDs: [raw.path],
            bytesIfPruned: 150
        )
        let store = DeduplicateSessionStore(engine: MockDeduplicateEngine(clusters: [cluster]))

        store.startScan(configuration: DeduplicateConfiguration(
            destinationPath: "/dest",
            treatRawJpegPairsAsUnit: false
        ))
        _ = await waitForCondition { store.status == .readyToReview }

        XCTAssertEqual(store.decisions.byPath[raw.path], .keep)
        XCTAssertEqual(store.decisions.byPath[jpeg.path], .delete)
        XCTAssertEqual(store.decisions.byPath[other.path], .delete)
        XCTAssertEqual(store.pendingDeleteCount, 2)
        XCTAssertEqual(store.totalRecoverableBytes, 150)
    }

    @MainActor
    func testTriageBucketsGroupAnnotatedClustersAndDefaultMissingToMedium() async throws {
        let high = DuplicateCluster(
            kind: .exactDuplicate,
            members: [
                PhotoCandidate(path: "/dest/high-a.jpg", size: 100, modificationTime: 0, qualityScore: 0.9),
                PhotoCandidate(path: "/dest/high-b.jpg", size: 100, modificationTime: 0, qualityScore: 0.4),
            ],
            suggestedKeeperIDs: ["/dest/high-a.jpg"],
            bytesIfPruned: 100,
            annotation: ClusterAnnotation(confidence: .high, matchReason: MatchReason(kind: .exactDuplicate))
        )
        let low = DuplicateCluster(
            kind: .nearDuplicate,
            members: [
                PhotoCandidate(path: "/dest/low-a.jpg", size: 100, modificationTime: 0, qualityScore: 0.9),
                PhotoCandidate(path: "/dest/low-b.jpg", size: 100, modificationTime: 0, qualityScore: 0.4),
            ],
            suggestedKeeperIDs: ["/dest/low-a.jpg"],
            bytesIfPruned: 100,
            annotation: ClusterAnnotation(confidence: .low, matchReason: MatchReason(kind: .nearDuplicate))
        )
        let unannotated = DuplicateCluster(
            kind: .burst,
            members: [
                PhotoCandidate(path: "/dest/mid-a.jpg", size: 100, modificationTime: 0, qualityScore: 0.9),
                PhotoCandidate(path: "/dest/mid-b.jpg", size: 100, modificationTime: 0, qualityScore: 0.4),
            ],
            suggestedKeeperIDs: ["/dest/mid-a.jpg"],
            bytesIfPruned: 100
        )
        let store = DeduplicateSessionStore(engine: MockDeduplicateEngine(clusters: [high, low, unannotated]))

        store.startScan(configuration: DeduplicateConfiguration(destinationPath: "/dest"))
        _ = await waitForCondition { store.status == .readyToReview }

        XCTAssertEqual(store.triageBuckets[.high]?.map(\.id), [high.id])
        XCTAssertEqual(store.triageBuckets[.low]?.map(\.id), [low.id])
        XCTAssertEqual(store.triageBuckets[.medium]?.map(\.id), [unannotated.id])
    }

    @MainActor
    func testAcceptAllHighConfidenceOnlyAppliesHighBucketSuggestions() async throws {
        let high = DuplicateCluster(
            kind: .exactDuplicate,
            members: [
                PhotoCandidate(path: "/dest/high-a.jpg", size: 100, modificationTime: 0, qualityScore: 0.9),
                PhotoCandidate(path: "/dest/high-b.jpg", size: 100, modificationTime: 0, qualityScore: 0.4),
            ],
            suggestedKeeperIDs: ["/dest/high-a.jpg"],
            bytesIfPruned: 100,
            annotation: ClusterAnnotation(confidence: .high, matchReason: MatchReason(kind: .exactDuplicate))
        )
        let medium = DuplicateCluster(
            kind: .nearDuplicate,
            members: [
                PhotoCandidate(path: "/dest/medium-a.jpg", size: 100, modificationTime: 0, qualityScore: 0.9),
                PhotoCandidate(path: "/dest/medium-b.jpg", size: 100, modificationTime: 0, qualityScore: 0.4),
            ],
            suggestedKeeperIDs: ["/dest/medium-a.jpg"],
            bytesIfPruned: 100,
            annotation: ClusterAnnotation(confidence: .medium, matchReason: MatchReason(kind: .nearDuplicate))
        )
        let store = DeduplicateSessionStore(engine: MockDeduplicateEngine(clusters: [high, medium]))

        store.startScan(configuration: DeduplicateConfiguration(destinationPath: "/dest"))
        _ = await waitForCondition { store.status == .readyToReview }
        store.setDecision(.keep, forPath: "/dest/high-b.jpg")
        store.setDecision(.keep, forPath: "/dest/medium-b.jpg")

        store.acceptAllHighConfidence()

        XCTAssertEqual(store.decisions.byPath["/dest/high-a.jpg"], .keep)
        XCTAssertEqual(store.decisions.byPath["/dest/high-b.jpg"], .delete)
        XCTAssertEqual(store.decisions.byPath["/dest/medium-a.jpg"], .keep)
        XCTAssertEqual(store.decisions.byPath["/dest/medium-b.jpg"], .keep)
    }

    @MainActor
    func testPauseReviewPreservesScanAndOnlyResumesForMatchingConfiguration() async throws {
        let keeper = PhotoCandidate(
            path: "/dest/keeper.jpg",
            size: 500,
            modificationTime: 0,
            qualityScore: 0.9
        )
        let duplicate = PhotoCandidate(
            path: "/dest/duplicate.jpg",
            size: 250,
            modificationTime: 0,
            qualityScore: 0.4
        )
        let cluster = DuplicateCluster(
            kind: .nearDuplicate,
            members: [keeper, duplicate],
            suggestedKeeperIDs: [keeper.path],
            bytesIfPruned: duplicate.size
        )
        let store = DeduplicateSessionStore(engine: MockDeduplicateEngine(clusters: [cluster]))
        let configuration = DeduplicateConfiguration(destinationPath: "/dest", timeWindowSeconds: 25)

        store.startScan(configuration: configuration)
        _ = await waitForCondition { store.status == .readyToReview }
        store.setDecision(.keep, forPath: duplicate.path)

        store.pauseReview()

        XCTAssertEqual(store.status, .idle)
        XCTAssertTrue(store.hasPausedReview)
        XCTAssertEqual(store.pausedReviewConfiguration, configuration)
        XCTAssertTrue(store.pausedReviewMatches(configuration: configuration))
        XCTAssertFalse(store.pausedReviewMatches(configuration: DeduplicateConfiguration(
            destinationPath: "/dest",
            timeWindowSeconds: 60
        )))
        XCTAssertEqual(store.clusters, [cluster])
        XCTAssertEqual(store.decisions.byPath[duplicate.path], .keep)

        store.resumePausedReview()

        XCTAssertEqual(store.status, .readyToReview)
        XCTAssertFalse(store.hasPausedReview)
        XCTAssertEqual(store.clusters, [cluster])
        XCTAssertEqual(store.decisions.byPath[duplicate.path], .keep)
    }

    @MainActor
    func testResetDiscardsPausedReview() async {
        let cluster = DuplicateCluster(
            kind: .nearDuplicate,
            members: [
                PhotoCandidate(path: "/dest/a.jpg", size: 100, modificationTime: 0, qualityScore: 0.9),
                PhotoCandidate(path: "/dest/b.jpg", size: 100, modificationTime: 0, qualityScore: 0.4),
            ],
            suggestedKeeperIDs: ["/dest/a.jpg"],
            bytesIfPruned: 100
        )
        let store = DeduplicateSessionStore(engine: MockDeduplicateEngine(clusters: [cluster]))

        store.startScan(configuration: DeduplicateConfiguration(destinationPath: "/dest"))
        _ = await waitForCondition { store.status == .readyToReview }
        store.pauseReview()

        XCTAssertTrue(store.hasPausedReview)

        store.reset()

        XCTAssertFalse(store.hasPausedReview)
        XCTAssertNil(store.pausedReviewConfiguration)
        XCTAssertTrue(store.clusters.isEmpty)
    }

    /// The footer uses the scan-time configuration captured in
    /// `lastScanConfiguration`. Commit must use that same configuration,
    /// even if Settings changed after review began, otherwise the previewed
    /// count/bytes can drift from the executor's final plan.
    @MainActor
    func testCommitUsesScanConfigurationWhenSettingsChangeAfterReview() async throws {
        let heic = PhotoCandidate(
            path: "/dest/IMG.HEIC",
            size: 100,
            modificationTime: 0,
            isLivePhotoStill: true,
            pairedPath: "/dest/IMG.MOV"
        )
        let other = PhotoCandidate(
            path: "/dest/OTHER.HEIC",
            size: 50,
            modificationTime: 0,
            qualityScore: 0.9
        )
        let cluster = DuplicateCluster(
            kind: .burst,
            members: [heic, other],
            suggestedKeeperIDs: ["/dest/OTHER.HEIC"],
            bytesIfPruned: 100
        )
        let engine = MockDeduplicateEngine(clusters: [cluster])
        let store = DeduplicateSessionStore(engine: engine)
        let scanConfiguration = DeduplicateConfiguration(
            destinationPath: "/dest",
            treatRawJpegPairsAsUnit: true,
            treatLivePhotoPairsAsUnit: true
        )

        store.startScan(configuration: scanConfiguration)
        _ = await waitForCondition { store.status == .readyToReview }
        let previewPlan = store.currentDeletionPlan()
        XCTAssertTrue(Set(previewPlan.pathsToDelete).contains("/dest/IMG.MOV"))

        let changedSettingsConfiguration = DeduplicateConfiguration(
            destinationPath: "/dest",
            treatRawJpegPairsAsUnit: true,
            treatLivePhotoPairsAsUnit: false
        )
        store.commit(configuration: changedSettingsConfiguration)

        XCTAssertEqual(engine.lastCommitConfiguration?.treatLivePhotoPairsAsUnit, true)
        XCTAssertEqual(engine.lastCommitConfiguration?.treatRawJpegPairsAsUnit, true)
        let commitDecisions = try XCTUnwrap(engine.lastCommitDecisions)
        let commitConfiguration = try XCTUnwrap(engine.lastCommitConfiguration)
        let commitPlan = DeduplicationPlanner.plan(
            decisions: commitDecisions,
            clusters: engine.lastCommitClusters,
            configuration: commitConfiguration
        )
        XCTAssertEqual(Set(commitPlan.pathsToDelete), Set(previewPlan.pathsToDelete))
    }

    /// Regression for review rec #3: `revert(receiptURL:)` previously
    /// reused `.committing` and landed in `.completed`, so the dedupe
    /// view briefly showed "Nothing to deduplicate" mid-revert and
    /// then "Removed N · reclaimed N MB" — wrong copy for an
    /// operation that restores trashed files. The new statuses
    /// `.reverting` and `.reverted` give the view a clean signal.
    @MainActor
    func testRevertEntersRevertingThenLandsInReverted() async {
        let engine = MockDeduplicateEngine(revertEvents: [
            .started(totalToDelete: 2),
            .itemTrashed(originalPath: "/dest/IMG.HEIC", trashURL: nil, sizeBytes: 100),
            .itemTrashed(originalPath: "/dest/IMG.MOV", trashURL: nil, sizeBytes: 200),
            .complete(DeduplicateCommitSummary(
                deletedCount: 2,
                failedCount: 0,
                bytesReclaimed: 300,
                receiptPath: nil,
                hardDelete: false
            )),
        ])
        let store = DeduplicateSessionStore(engine: engine)

        store.revert(receiptURL: URL(fileURLWithPath: "/tmp/receipt.json"))
        XCTAssertEqual(store.status, .reverting, "revert(...) must enter .reverting immediately, not .committing")

        let landed = await waitForCondition { store.status == .reverted }
        XCTAssertTrue(landed, "revert stream completion must land in .reverted")
        XCTAssertEqual(store.commitSummary?.deletedCount, 2)
    }

    /// Forward-commit regression: the new `isHandlingRevert` flag must
    /// reset cleanly so a commit that follows a revert still lands in
    /// `.completed` (not `.reverted`).
    @MainActor
    func testCommitStillLandsInCompletedAfterPriorRevert() async {
        let cluster = DuplicateCluster(
            kind: .burst,
            members: [
                PhotoCandidate(path: "/dest/a.jpg", size: 100, modificationTime: 0, qualityScore: 0.9),
                PhotoCandidate(path: "/dest/b.jpg", size: 100, modificationTime: 0, qualityScore: 0.4),
            ],
            suggestedKeeperIDs: ["/dest/a.jpg"],
            bytesIfPruned: 100
        )
        let engine = MockDeduplicateEngine(
            clusters: [cluster],
            commitEvents: [
                .started(totalToDelete: 1),
                .itemTrashed(originalPath: "/dest/b.jpg", trashURL: nil, sizeBytes: 100),
                .complete(DeduplicateCommitSummary(
                    deletedCount: 1, failedCount: 0, bytesReclaimed: 100,
                    receiptPath: nil, hardDelete: false
                )),
            ],
            revertEvents: [
                .started(totalToDelete: 0),
                .complete(DeduplicateCommitSummary(
                    deletedCount: 0, failedCount: 0, bytesReclaimed: 0,
                    receiptPath: nil, hardDelete: false
                )),
            ]
        )
        let store = DeduplicateSessionStore(engine: engine)

        // First a revert lands in .reverted, then a fresh scan + commit
        // must still reach .completed (not be sticky on revert).
        store.revert(receiptURL: URL(fileURLWithPath: "/tmp/r.json"))
        _ = await waitForCondition { store.status == .reverted }

        store.startScan(configuration: DeduplicateConfiguration(destinationPath: "/dest"))
        _ = await waitForCondition { store.status == .readyToReview }
        store.commit(configuration: DeduplicateConfiguration(destinationPath: "/dest"))

        XCTAssertEqual(store.status, .committing)
        let completed = await waitForCondition { store.status == .completed }
        XCTAssertTrue(completed, "Forward commit after a revert must land in .completed")
    }

    @MainActor
    func testCommitRecordsDeduplicateFolderHistory() async {
        let historyStore = UserDefaultsDeduplicateRunHistoryStore(defaults: defaults)
        let engine = MockDeduplicateEngine(
            commitEvents: [
                .started(totalToDelete: 2),
                .itemTrashed(originalPath: "/dest/a.jpg", trashURL: nil, sizeBytes: 100),
                .complete(DeduplicateCommitSummary(
                    deletedCount: 2,
                    failedCount: 1,
                    bytesReclaimed: 1_024,
                    receiptPath: "/dest/.organize_logs/dedupe_audit_receipt.json",
                    hardDelete: false
                )),
            ]
        )
        let store = DeduplicateSessionStore(engine: engine, runHistoryStore: historyStore)

        store.commit(configuration: DeduplicateConfiguration(destinationPath: "/Volumes/Dedupe"))
        _ = await waitForCondition { store.status == .completed }

        XCTAssertEqual(store.runHistory.count, 1)
        XCTAssertEqual(store.runHistory.first?.folderPath, "/Volumes/Dedupe")
        XCTAssertEqual(store.runHistory.first?.lastDeletedCount, 2)
        XCTAssertEqual(store.runHistory.first?.lastFailedCount, 1)
        XCTAssertEqual(store.runHistory.first?.lastBytesReclaimed, 1_024)
        XCTAssertEqual(store.runHistory.first?.runCount, 1)
        XCTAssertEqual(UserDefaultsDeduplicateRunHistoryStore(defaults: defaults).load(), store.runHistory)
    }

    @MainActor
    func testDeduplicateFolderHistoryAggregatesAndMovesRecentFolderFirst() {
        let historyStore = UserDefaultsDeduplicateRunHistoryStore(defaults: defaults, limit: 3)
        let firstSummary = DeduplicateCommitSummary(
            deletedCount: 2,
            failedCount: 0,
            bytesReclaimed: 2_000,
            receiptPath: "/a/receipt-1.json",
            hardDelete: false
        )
        let secondSummary = DeduplicateCommitSummary(
            deletedCount: 3,
            failedCount: 1,
            bytesReclaimed: 3_000,
            receiptPath: "/b/receipt.json",
            hardDelete: true
        )
        let thirdSummary = DeduplicateCommitSummary(
            deletedCount: 4,
            failedCount: 0,
            bytesReclaimed: 4_000,
            receiptPath: "/a/receipt-2.json",
            hardDelete: false
        )

        _ = historyStore.recordRun(
            destinationPath: " /Volumes/A ",
            summary: firstSummary,
            completedAt: Date(timeIntervalSince1970: 1)
        )
        _ = historyStore.recordRun(
            destinationPath: "/Volumes/B",
            summary: secondSummary,
            completedAt: Date(timeIntervalSince1970: 2)
        )
        let records = historyStore.recordRun(
            destinationPath: "/Volumes/A",
            summary: thirdSummary,
            completedAt: Date(timeIntervalSince1970: 3)
        )

        XCTAssertEqual(records.map(\.folderPath), ["/Volumes/A", "/Volumes/B"])
        XCTAssertEqual(records.first?.runCount, 2)
        XCTAssertEqual(records.first?.lastDeletedCount, 4)
        XCTAssertEqual(records.first?.totalDeletedCount, 6)
        XCTAssertEqual(records.first?.totalBytesReclaimed, 6_000)
        XCTAssertEqual(records.first?.lastReceiptPath, "/a/receipt-2.json")
        XCTAssertEqual(records[1].lastHardDelete, true)
    }
}

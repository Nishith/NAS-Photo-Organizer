import Foundation
import XCTest
@testable import ChronoframeAppCore
@testable import ChronoframeCore

final class DeduplicateSessionStoreTests: XCTestCase {
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
}

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ChronoframeCore

final class DeduplicateTests: XCTestCase {
    // MARK: - PerceptualHash

    func testHammingDistance() {
        XCTAssertEqual(PerceptualHash.hammingDistance(0, 0), 0)
        XCTAssertEqual(PerceptualHash.hammingDistance(0, 0xFFFFFFFFFFFFFFFF), 64)
        XCTAssertEqual(PerceptualHash.hammingDistance(0b1010, 0b0101), 4)
        XCTAssertEqual(PerceptualHash.hammingDistance(0b1010, 0b1011), 1)
    }

    func testDhashDistinguishesSyntheticGradientsAndLoadsFromURL() throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DhashTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let ascending = makeGradientImage(reversed: false)
        let descending = makeGradientImage(reversed: true)
        let ascendingHash = try XCTUnwrap(PerceptualHash.dhash(from: ascending))
        let descendingHash = try XCTUnwrap(PerceptualHash.dhash(from: descending))

        XCTAssertGreaterThan(
            PerceptualHash.hammingDistance(ascendingHash, descendingHash),
            0,
            "Opposite gradients should not collapse to the same dHash"
        )

        let imageURL = temporaryDirectory.appendingPathComponent("gradient.png")
        try writePNG(ascending, to: imageURL)
        XCTAssertEqual(PerceptualHash.dhash(at: imageURL), ascendingHash)

        let invalidURL = temporaryDirectory.appendingPathComponent("not-an-image.jpg")
        try Data("nope".utf8).write(to: invalidURL)
        XCTAssertNil(PerceptualHash.dhash(at: invalidURL))
    }

    func testPhotoQualityScorerFallsBackForUndecodableImage() throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("QualityFallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let invalidURL = temporaryDirectory.appendingPathComponent("not-an-image.jpg")
        try Data("not image data".utf8).write(to: invalidURL)

        let score = PhotoQualityScorer.score(at: invalidURL, sizeBytes: 0, pixelWidth: nil, pixelHeight: nil)

        XCTAssertEqual(score.sharpness, 0.05, accuracy: 0.0001)
        XCTAssertNil(score.faceScore)
        XCTAssertEqual(score.composite, 0.1125, accuracy: 0.0001)
    }

    func testPhotoQualityScorerScoresSyntheticImageWithinExpectedBounds() throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("QualitySynthetic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let imageURL = temporaryDirectory.appendingPathComponent("checker.png")
        try writePNG(makeCheckerboardImage(), to: imageURL)

        let sharpness = try XCTUnwrap(PhotoQualityScorer.sharpnessLaplacian(at: imageURL))
        let score = PhotoQualityScorer.score(
            at: imageURL,
            sizeBytes: 16_384,
            pixelWidth: 32,
            pixelHeight: 32
        )

        XCTAssertGreaterThanOrEqual(sharpness, 0)
        XCTAssertLessThanOrEqual(sharpness, 1)
        XCTAssertEqual(score.sharpness, sharpness, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(score.composite, 0)
        XCTAssertLessThanOrEqual(score.composite, 1)
    }

    // MARK: - DuplicateClusterer

    func testClustersBurstWithinTimeWindow() {
        let baseDate = Date(timeIntervalSinceReferenceDate: 0)
        let print1 = Data([1, 2, 3])
        let print2 = Data([4, 5, 6])
        let print3 = Data([7, 8, 9])

        let candidates = [
            candidate(path: "/dest/a.jpg", captureDate: baseDate, dhash: 0xAAAA, featurePrintData: print1, qualityScore: 0.9),
            candidate(path: "/dest/b.jpg", captureDate: baseDate.addingTimeInterval(2), dhash: 0xAAAA, featurePrintData: print2, qualityScore: 0.4),
            candidate(path: "/dest/c.jpg", captureDate: baseDate.addingTimeInterval(5), dhash: 0xAAAB, featurePrintData: print3, qualityScore: 0.5),
            candidate(path: "/dest/distant.jpg", captureDate: baseDate.addingTimeInterval(3600), dhash: 0xAAAA, featurePrintData: print1, qualityScore: 0.8),
        ]
        let config = DeduplicateConfiguration(
            destinationPath: "/dest",
            timeWindowSeconds: 30,
            similarityThreshold: 1.0,
            dhashHammingThreshold: 5
        )

        let clusters = DuplicateClusterer.cluster(
            candidates: candidates,
            configuration: config,
            burstWindowSeconds: 10,
            featurePrintDistance: { _, _ in 0.1 }
        )

        XCTAssertEqual(clusters.count, 1, "Distant photo should not cluster with the burst")
        XCTAssertEqual(clusters.first?.kind, .burst)
        XCTAssertEqual(clusters.first?.members.count, 3)
        // Highest qualityScore is /dest/a.jpg, so it should be the suggested keeper.
        XCTAssertEqual(clusters.first?.suggestedKeeperIDs, ["/dest/a.jpg"])
        // bytesIfPruned excludes the keeper.
        XCTAssertEqual(clusters.first?.bytesIfPruned, 200)
    }

    func testClustersNearDuplicateWhenOutsideBurstWindow() {
        let baseDate = Date(timeIntervalSinceReferenceDate: 0)
        let candidates = [
            candidate(path: "/dest/a.jpg", captureDate: baseDate, dhash: 0xAAAA, qualityScore: 0.5),
            candidate(path: "/dest/b.jpg", captureDate: baseDate.addingTimeInterval(25), dhash: 0xAAAA, qualityScore: 0.4),
        ]
        let config = DeduplicateConfiguration(destinationPath: "/dest", timeWindowSeconds: 30, dhashHammingThreshold: 5)

        let clusters = DuplicateClusterer.cluster(
            candidates: candidates,
            configuration: config,
            burstWindowSeconds: 10,
            featurePrintDistance: { _, _ in nil }
        )

        XCTAssertEqual(clusters.first?.kind, .nearDuplicate)
    }

    func testRejectsPairsThatExceedDhashThreshold() {
        let baseDate = Date(timeIntervalSinceReferenceDate: 0)
        let candidates = [
            candidate(path: "/dest/a.jpg", captureDate: baseDate, dhash: 0x0000),
            candidate(path: "/dest/b.jpg", captureDate: baseDate.addingTimeInterval(2), dhash: 0xFFFF),
        ]
        let config = DeduplicateConfiguration(destinationPath: "/dest", timeWindowSeconds: 30, dhashHammingThreshold: 4)

        let clusters = DuplicateClusterer.cluster(
            candidates: candidates,
            configuration: config,
            featurePrintDistance: { _, _ in 0.0 }
        )
        XCTAssertTrue(clusters.isEmpty)
    }

    func testExactDuplicateClusterEmits() {
        let identity = FileIdentity(size: 100, digest: "deadbeef")
        let candidates = [
            candidate(path: "/dest/a.jpg", captureDate: nil, qualityScore: 0.9),
            candidate(path: "/dest/b.jpg", captureDate: nil, qualityScore: 0.4),
        ]
        let clusters = DuplicateClusterer.exactDuplicateClusters(candidatesByIdentity: [identity: candidates])
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters.first?.kind, .exactDuplicate)
        XCTAssertEqual(clusters.first?.suggestedKeeperIDs, ["/dest/a.jpg"])
    }

    // MARK: - DeduplicationPlanner

    func testPlannerExpandsRawJpegPairWhenToggleEnabled() {
        let raw = candidate(path: "/dest/IMG.CR2", pairedPath: "/dest/IMG.JPG")
        let jpeg = candidate(path: "/dest/IMG.JPG", pairedPath: "/dest/IMG.CR2")
        let other = candidate(path: "/dest/OTHER.JPG")

        let cluster = DuplicateCluster(
            kind: .nearDuplicate,
            members: [raw, jpeg, other],
            suggestedKeeperIDs: ["/dest/OTHER.JPG"],
            bytesIfPruned: 200
        )
        let decisions = DedupeDecisions(byPath: [
            "/dest/IMG.JPG": .delete,
            "/dest/OTHER.JPG": .keep,
        ])
        let config = DeduplicateConfiguration(destinationPath: "/dest", treatRawJpegPairsAsUnit: true)

        let plan = DeduplicationPlanner.plan(decisions: decisions, clusters: [cluster], configuration: config)
        let paths = Set(plan.pathsToDelete)
        XCTAssertTrue(paths.contains("/dest/IMG.JPG"))
        XCTAssertTrue(paths.contains("/dest/IMG.CR2"), "Pair partner must be deleted alongside")
        XCTAssertFalse(paths.contains("/dest/OTHER.JPG"))
    }

    func testPlannerRefusesAllDelete() {
        let a = candidate(path: "/dest/a.jpg")
        let b = candidate(path: "/dest/b.jpg")
        let cluster = DuplicateCluster(
            kind: .burst,
            members: [a, b],
            suggestedKeeperIDs: [],
            bytesIfPruned: 200
        )
        let decisions = DedupeDecisions(byPath: [
            "/dest/a.jpg": .delete,
            "/dest/b.jpg": .delete,
        ])
        let plan = DeduplicationPlanner.plan(
            decisions: decisions,
            clusters: [cluster],
            configuration: DeduplicateConfiguration(destinationPath: "/dest")
        )
        XCTAssertTrue(plan.items.isEmpty, "Safety rail: never delete every member of a cluster")
    }

    /// Regression: previously the executor collapsed both pair toggles
    /// into a single `pairs` boolean, so disabling RAW pairing while
    /// Live Photo pairing remained enabled still deleted RAW partners.
    /// With the planner each toggle is honored independently.
    ///
    /// To isolate the toggle's effect on *pair expansion* (the partner
    /// is otherwise outside the cluster), this test uses a setup where
    /// only the JPEG is a cluster member; the RAW is referenced via
    /// `pairedPath` only.
    func testPlannerHonorsPairTogglesIndependently() {
        let jpeg = candidate(path: "/dest/IMG.JPG", pairedPath: "/dest/IMG.CR2")
        let other = candidate(path: "/dest/OTHER.JPG", qualityScore: 0.9)
        let cluster = DuplicateCluster(
            kind: .nearDuplicate,
            members: [jpeg, other],
            suggestedKeeperIDs: ["/dest/OTHER.JPG"],
            bytesIfPruned: 100
        )
        let decisions = DedupeDecisions(byPath: [
            "/dest/IMG.JPG": .delete,
            "/dest/OTHER.JPG": .keep,
        ])

        // RAW pairing OFF; Live Photo ON. RAW partner must stay.
        let configRawOff = DeduplicateConfiguration(
            destinationPath: "/dest",
            treatRawJpegPairsAsUnit: false,
            treatLivePhotoPairsAsUnit: true
        )
        let planRawOff = DeduplicationPlanner.plan(
            decisions: decisions,
            clusters: [cluster],
            configuration: configRawOff
        )
        XCTAssertTrue(Set(planRawOff.pathsToDelete).contains("/dest/IMG.JPG"))
        XCTAssertFalse(
            Set(planRawOff.pathsToDelete).contains("/dest/IMG.CR2"),
            "RAW partner must NOT be expanded when RAW pairing is off"
        )

        // RAW pairing ON: partner is expanded.
        let configRawOn = DeduplicateConfiguration(
            destinationPath: "/dest",
            treatRawJpegPairsAsUnit: true,
            treatLivePhotoPairsAsUnit: true
        )
        let planRawOn = DeduplicationPlanner.plan(
            decisions: decisions,
            clusters: [cluster],
            configuration: configRawOn
        )
        XCTAssertTrue(Set(planRawOn.pathsToDelete).contains("/dest/IMG.CR2"))
    }

    /// Live Photo pairing toggle is honored independently of the
    /// RAW+JPEG toggle: with Live Photo OFF and RAW ON, a deleted HEIC
    /// must not pull the MOV partner into the plan via expansion.
    func testPlannerHonorsLivePhotoToggleIndependently() {
        let heic = candidate(
            path: "/dest/IMG.HEIC",
            pairedPath: "/dest/IMG.MOV",
            isLivePhotoStill: true
        )
        let other = candidate(path: "/dest/OTHER.HEIC", qualityScore: 0.9)
        let cluster = DuplicateCluster(
            kind: .burst,
            members: [heic, other],
            suggestedKeeperIDs: ["/dest/OTHER.HEIC"],
            bytesIfPruned: 100
        )
        let decisions = DedupeDecisions(byPath: [
            "/dest/IMG.HEIC": .delete,
            "/dest/OTHER.HEIC": .keep,
        ])

        let configLivePhotoOff = DeduplicateConfiguration(
            destinationPath: "/dest",
            treatRawJpegPairsAsUnit: true,
            treatLivePhotoPairsAsUnit: false
        )
        let plan = DeduplicationPlanner.plan(
            decisions: decisions,
            clusters: [cluster],
            configuration: configLivePhotoOff
        )
        XCTAssertTrue(Set(plan.pathsToDelete).contains("/dest/IMG.HEIC"))
        XCTAssertFalse(
            Set(plan.pathsToDelete).contains("/dest/IMG.MOV"),
            "MOV partner must not be expanded when Live Photo pairing is off"
        )
    }

    /// Both pair toggles off: pairs are completely independent, no
    /// expansion of any kind. Whatever the user (or the suggestion
    /// engine) decided per path is what happens.
    func testPlannerHonorsBothPairTogglesOff() {
        let jpeg = candidate(path: "/dest/IMG.JPG", pairedPath: "/dest/IMG.CR2")
        let heic = candidate(
            path: "/dest/LIVE.HEIC",
            pairedPath: "/dest/LIVE.MOV",
            isLivePhotoStill: true
        )
        let other = candidate(path: "/dest/OTHER.JPG", qualityScore: 0.9)
        let cluster = DuplicateCluster(
            kind: .nearDuplicate,
            members: [jpeg, heic, other],
            suggestedKeeperIDs: ["/dest/OTHER.JPG"],
            bytesIfPruned: 200
        )
        let decisions = DedupeDecisions(byPath: [
            "/dest/IMG.JPG": .delete,
            "/dest/LIVE.HEIC": .delete,
            "/dest/OTHER.JPG": .keep,
        ])

        let configBothOff = DeduplicateConfiguration(
            destinationPath: "/dest",
            treatRawJpegPairsAsUnit: false,
            treatLivePhotoPairsAsUnit: false
        )
        let plan = DeduplicationPlanner.plan(
            decisions: decisions,
            clusters: [cluster],
            configuration: configBothOff
        )
        let paths = Set(plan.pathsToDelete)
        XCTAssertTrue(paths.contains("/dest/IMG.JPG"))
        XCTAssertTrue(paths.contains("/dest/LIVE.HEIC"))
        XCTAssertFalse(paths.contains("/dest/IMG.CR2"), "RAW partner must not be expanded")
        XCTAssertFalse(paths.contains("/dest/LIVE.MOV"), "MOV partner must not be expanded")
    }

    /// Symmetric to `testPlannerKeepWinsOverDeleteOnPairConflict`: this
    /// time the JPEG is the explicit Keep and the RAW is the explicit
    /// Delete. Pair Keep-wins must protect the RAW too.
    func testPlannerJpegKeepProtectsRawPartner() {
        let raw = candidate(path: "/dest/IMG.CR2", pairedPath: "/dest/IMG.JPG", isRaw: true)
        let jpeg = candidate(path: "/dest/IMG.JPG", pairedPath: "/dest/IMG.CR2")
        let other = candidate(path: "/dest/OTHER.JPG", qualityScore: 0.9)
        let cluster = DuplicateCluster(
            kind: .nearDuplicate,
            members: [raw, jpeg, other],
            suggestedKeeperIDs: ["/dest/OTHER.JPG"],
            bytesIfPruned: 200
        )
        let decisions = DedupeDecisions(byPath: [
            "/dest/IMG.CR2": .delete,
            "/dest/IMG.JPG": .keep,
            "/dest/OTHER.JPG": .keep,
        ])
        let config = DeduplicateConfiguration(destinationPath: "/dest", treatRawJpegPairsAsUnit: true)

        let plan = DeduplicationPlanner.plan(decisions: decisions, clusters: [cluster], configuration: config)
        let paths = Set(plan.pathsToDelete)
        XCTAssertFalse(paths.contains("/dest/IMG.JPG"), "Explicit Keep must never be deleted")
        XCTAssertFalse(paths.contains("/dest/IMG.CR2"), "Pair Keep-wins must protect the RAW partner")
    }

    /// Regression: the executor previously inserted any partner into
    /// `toDelete` after the safety check, so an explicit Keep on one
    /// half of a pair could be silently flipped to Delete by the other
    /// half's decision. Keep wins.
    func testPlannerKeepWinsOverDeleteOnPairConflict() {
        let raw = candidate(path: "/dest/IMG.CR2", pairedPath: "/dest/IMG.JPG", isRaw: true)
        let jpeg = candidate(path: "/dest/IMG.JPG", pairedPath: "/dest/IMG.CR2")
        let other = candidate(path: "/dest/OTHER.JPG", qualityScore: 0.9)
        let cluster = DuplicateCluster(
            kind: .nearDuplicate,
            members: [raw, jpeg, other],
            suggestedKeeperIDs: ["/dest/OTHER.JPG"],
            bytesIfPruned: 200
        )
        let decisions = DedupeDecisions(byPath: [
            "/dest/IMG.CR2": .keep,    // user explicitly kept the RAW
            "/dest/IMG.JPG": .delete,  // and (perhaps accidentally) marked the JPEG for deletion
            "/dest/OTHER.JPG": .keep,
        ])
        let config = DeduplicateConfiguration(destinationPath: "/dest", treatRawJpegPairsAsUnit: true)

        let plan = DeduplicationPlanner.plan(decisions: decisions, clusters: [cluster], configuration: config)
        let paths = Set(plan.pathsToDelete)
        XCTAssertFalse(paths.contains("/dest/IMG.CR2"), "Explicit Keep must never be deleted")
        XCTAssertFalse(paths.contains("/dest/IMG.JPG"), "Pair Keep-wins must protect the partner too")
        XCTAssertFalse(paths.contains("/dest/OTHER.JPG"))
    }

    /// Regression: receipt entries were only written for paths that
    /// were cluster members. Live Photo MOV halves aren't candidates
    /// (the scanner only enumerates image paths), so they could be
    /// trashed without a receipt entry — and Run History would then be
    /// unable to revert them. The plan now carries owning-cluster
    /// metadata for every mutation.
    func testPlannerCarriesOwningClusterForLivePhotoSidecar() {
        let heic = candidate(
            path: "/dest/IMG.HEIC",
            pairedPath: "/dest/IMG.MOV",
            isLivePhotoStill: true
        )
        let other = candidate(path: "/dest/OTHER.HEIC", qualityScore: 0.9)
        let cluster = DuplicateCluster(
            kind: .burst,
            members: [heic, other],
            suggestedKeeperIDs: ["/dest/OTHER.HEIC"],
            bytesIfPruned: 100
        )
        let decisions = DedupeDecisions(byPath: [
            "/dest/IMG.HEIC": .delete,
            "/dest/OTHER.HEIC": .keep,
        ])
        let config = DeduplicateConfiguration(destinationPath: "/dest", treatLivePhotoPairsAsUnit: true)

        let plan = DeduplicationPlanner.plan(decisions: decisions, clusters: [cluster], configuration: config)
        let movItem = plan.items.first { $0.path == "/dest/IMG.MOV" }
        XCTAssertNotNil(movItem, "Live Photo MOV partner must be in the plan")
        XCTAssertEqual(movItem?.owningClusterID, cluster.id, "MOV partner must inherit cluster ownership for receipt")
        XCTAssertEqual(movItem?.owningClusterKind, .burst)
        XCTAssertEqual(movItem?.pairOrigin, .livePhoto)
    }

    /// Pair-expanded partners may be outside `cluster.members`; Live Photo
    /// MOV halves are the common case. The planner must still account for
    /// their real filesystem size so the footer's recoverable-bytes value
    /// matches the executor's receipt summary.
    func testPlannerUsesFilesystemSizeForExternalLivePhotoSidecar() throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let heicURL = temporaryDirectory.appendingPathComponent("IMG.HEIC")
        let movURL = temporaryDirectory.appendingPathComponent("IMG.MOV")
        try Data(repeating: 0xAA, count: 32).write(to: heicURL)
        try Data(repeating: 0xBB, count: 64).write(to: movURL)

        let heic = candidate(
            path: heicURL.path,
            size: 32,
            pairedPath: movURL.path,
            isLivePhotoStill: true
        )
        let other = candidate(
            path: temporaryDirectory.appendingPathComponent("OTHER.HEIC").path,
            qualityScore: 0.9,
            size: 50
        )
        let cluster = DuplicateCluster(
            kind: .burst,
            members: [heic, other],
            suggestedKeeperIDs: [other.path],
            bytesIfPruned: 32
        )
        let decisions = DedupeDecisions(byPath: [
            heic.path: .delete,
            other.path: .keep,
        ])

        let plan = DeduplicationPlanner.plan(
            decisions: decisions,
            clusters: [cluster],
            configuration: DeduplicateConfiguration(destinationPath: temporaryDirectory.path, treatLivePhotoPairsAsUnit: true)
        )
        let movItem = try XCTUnwrap(plan.items.first { $0.path == movURL.path })
        XCTAssertEqual(movItem.sizeBytes, 64)
        XCTAssertEqual(plan.totalBytes, 96)
    }

    // MARK: - Executor preflight

    /// Regression: a receipt-write failure used to be a non-fatal issue
    /// reported AFTER deletion had completed. The executor now
    /// preflights the receipt directory; an unwritable destination
    /// aborts the commit before any file is touched.
    func testCommitAbortsBeforeMutationWhenReceiptDirectoryIsUnwritable() async throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fileURL = temporaryDirectory.appendingPathComponent("victim.jpg")
        try Data(repeating: 0xAB, count: 16).write(to: fileURL)

        // Block the receipt directory: create `.organize_logs` as a FILE,
        // so `createDirectory` and `write` both fail.
        let blockingFileURL = temporaryDirectory.appendingPathComponent(".organize_logs")
        try Data().write(to: blockingFileURL)

        let plan = DeduplicationPlan(items: [
            DeduplicationPlan.Item(
                path: fileURL.path,
                sizeBytes: 16,
                owningClusterID: UUID(),
                owningClusterKind: .burst,
                pairOrigin: nil
            )
        ])

        let executor = DeduplicateExecutor()
        let stream = executor.commit(
            plan: plan,
            destinationRoot: temporaryDirectory.path,
            hardDelete: true
        )

        var sawError = false
        do {
            for try await _ in stream {
                XCTFail("Stream should not yield any events when preflight fails")
            }
        } catch is ReceiptPreflightError {
            sawError = true
        } catch {
            XCTFail("Expected ReceiptPreflightError, got \(error)")
        }
        XCTAssertTrue(sawError, "Commit must fail with ReceiptPreflightError")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fileURL.path),
            "Victim file must be untouched when preflight aborts the commit"
        )
    }

    /// End-to-end: a deleted Live Photo HEIC carries its MOV partner
    /// through commit + receipt + revert. Verifies that
    ///   1. both files leave their original location,
    ///   2. the audit receipt records both items with cluster ownership,
    ///   3. revert restores both files from the Trash.
    /// Uses an injected Trash stand-in so the test is deterministic in
    /// sandboxed and headless environments where Finder Trash can fail.
    func testCommitAndRevertLivePhotoPair() async throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DedupeLivePhotoE2E-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let heicURL = temporaryDirectory.appendingPathComponent("IMG.HEIC")
        let movURL = temporaryDirectory.appendingPathComponent("IMG.MOV")
        try Data(repeating: 0xAA, count: 32).write(to: heicURL)
        try Data(repeating: 0xBB, count: 64).write(to: movURL)

        let clusterID = UUID()
        let plan = DeduplicationPlan(items: [
            DeduplicationPlan.Item(
                path: heicURL.path,
                sizeBytes: 32,
                owningClusterID: clusterID,
                owningClusterKind: .burst,
                pairOrigin: nil
            ),
            DeduplicationPlan.Item(
                path: movURL.path,
                sizeBytes: 64,
                owningClusterID: clusterID,
                owningClusterKind: .burst,
                pairOrigin: .livePhoto
            ),
        ])

        let fakeTrashRoot = temporaryDirectory.appendingPathComponent("FakeTrash", isDirectory: true)
        let executor = DeduplicateExecutor(
            fileOperations: MockDeduplicateFileOperations(trashRoot: fakeTrashRoot)
        )
        let trashed = TrashedURLBag()
        var commitSummary: DeduplicateCommitSummary?

        let commitStream = executor.commit(
            plan: plan,
            destinationRoot: temporaryDirectory.path,
            hardDelete: false
        )
        for try await event in commitStream {
            switch event {
            case let .itemTrashed(originalPath, trashURL, _):
                if let trashURL { trashed.add(originalPath: originalPath, trashURL: trashURL) }
            case let .complete(summary):
                commitSummary = summary
            default:
                break
            }
        }

        // Cleanup hook in case revert doesn't run — trashed items must
        // not pile up in the user's Trash across test runs.
        let cleanupDirectory = temporaryDirectory
        addTeardownBlock {
            for url in trashed.snapshot().values {
                try? FileManager.default.removeItem(at: url)
            }
            try? FileManager.default.removeItem(at: cleanupDirectory)
        }

        XCTAssertEqual(commitSummary?.deletedCount, 2)
        XCTAssertEqual(commitSummary?.failedCount, 0)
        XCTAssertEqual(commitSummary?.bytesReclaimed, 96)
        XCTAssertFalse(FileManager.default.fileExists(atPath: heicURL.path), "HEIC must leave its original path")
        XCTAssertFalse(FileManager.default.fileExists(atPath: movURL.path), "MOV partner must leave its original path")

        let receiptPath = try XCTUnwrap(commitSummary?.receiptPath, "Receipt must be written for both items")
        let receiptData = try Data(contentsOf: URL(fileURLWithPath: receiptPath))
        let receipt = try JSONDecoder.dedupe.decode(DeduplicateAuditReceipt.self, from: receiptData)
        let receiptPaths = Set(receipt.items.map(\.originalPath))
        XCTAssertTrue(receiptPaths.contains(heicURL.path))
        XCTAssertTrue(receiptPaths.contains(movURL.path), "MOV partner must have a receipt entry, otherwise Run History cannot revert it")
        for item in receipt.items {
            XCTAssertEqual(item.method, .trash)
            XCTAssertEqual(item.clusterID, clusterID)
            XCTAssertEqual(item.clusterKind, .burst)
            XCTAssertNotNil(item.trashURL, "Trash URL must be captured for revert")
        }

        // Revert and verify both files come back.
        let revertStream = executor.revert(receiptURL: URL(fileURLWithPath: receiptPath))
        for try await _ in revertStream {}

        XCTAssertTrue(FileManager.default.fileExists(atPath: heicURL.path), "Revert must restore HEIC")
        XCTAssertTrue(FileManager.default.fileExists(atPath: movURL.path), "Revert must restore MOV partner")
        // Restored files came back, so the trashURLs no longer point at
        // anything to clean up.
        trashed.clear()
    }

    func testCommitHardDeleteWritesReceiptAndRevertReportsNonRestorableItem() async throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DedupeHardDelete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fileURL = temporaryDirectory.appendingPathComponent("victim.jpg")
        try Data(repeating: 0xA1, count: 24).write(to: fileURL)
        let plan = DeduplicationPlan(items: [
            DeduplicationPlan.Item(
                path: fileURL.path,
                sizeBytes: 24,
                owningClusterID: UUID(),
                owningClusterKind: .exactDuplicate,
                pairOrigin: nil
            ),
        ])

        let executor = DeduplicateExecutor()
        var commitSummary: DeduplicateCommitSummary?
        for try await event in executor.commit(plan: plan, destinationRoot: temporaryDirectory.path, hardDelete: true) {
            if case let .complete(summary) = event {
                commitSummary = summary
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(commitSummary?.deletedCount, 1)
        XCTAssertEqual(commitSummary?.failedCount, 0)
        let receiptURL = URL(fileURLWithPath: try XCTUnwrap(commitSummary?.receiptPath))

        var failures: [String] = []
        var revertSummary: DeduplicateCommitSummary?
        for try await event in executor.revert(receiptURL: receiptURL) {
            switch event {
            case let .itemFailed(_, message):
                failures.append(message)
            case let .complete(summary):
                revertSummary = summary
            default:
                break
            }
        }

        XCTAssertEqual(failures, ["Hard-deleted items cannot be restored."])
        XCTAssertEqual(revertSummary?.deletedCount, 0)
        XCTAssertEqual(revertSummary?.failedCount, 1)
        XCTAssertEqual(revertSummary?.receiptPath, receiptURL.path)
    }

    func testCommitContinuesAfterHardDeleteFailureAndReportsFailedItem() async throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DedupePartialFailure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let failingURL = temporaryDirectory.appendingPathComponent("locked.jpg")
        let okURL = temporaryDirectory.appendingPathComponent("ok.jpg")
        try Data([0x01]).write(to: failingURL)
        try Data([0x02, 0x03]).write(to: okURL)

        let fileOperations = MockDeduplicateFileOperations(
            removeErrors: [failingURL.path: TestDedupeFileError("permission denied")]
        )
        let executor = DeduplicateExecutor(fileOperations: fileOperations)
        let plan = DeduplicationPlan(items: [
            DeduplicationPlan.Item(
                path: failingURL.path,
                sizeBytes: 1,
                owningClusterID: UUID(),
                owningClusterKind: .exactDuplicate,
                pairOrigin: nil
            ),
            DeduplicationPlan.Item(
                path: okURL.path,
                sizeBytes: 2,
                owningClusterID: UUID(),
                owningClusterKind: .exactDuplicate,
                pairOrigin: nil
            ),
        ])

        var failedMessages: [String] = []
        var summary: DeduplicateCommitSummary?
        for try await event in executor.commit(plan: plan, destinationRoot: temporaryDirectory.path, hardDelete: true) {
            switch event {
            case let .itemFailed(path, message):
                failedMessages.append("\(URL(fileURLWithPath: path).lastPathComponent): \(message)")
            case let .complete(commitSummary):
                summary = commitSummary
            default:
                break
            }
        }

        XCTAssertEqual(failedMessages, ["locked.jpg: permission denied"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: failingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: okURL.path))
        XCTAssertEqual(summary?.deletedCount, 1)
        XCTAssertEqual(summary?.failedCount, 1)
        XCTAssertEqual(summary?.bytesReclaimed, 2)
        XCTAssertNotNil(summary?.receiptPath, "Successful mutations should still get a receipt")
    }

    func testRevertReportsMissingTrashURLAndMoveFailures() async throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DedupeRevertFailures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let missingTrashOriginal = temporaryDirectory.appendingPathComponent("missing-trash.jpg")
        let moveFailureOriginal = temporaryDirectory.appendingPathComponent("move-failure.jpg")
        let fakeTrashURL = temporaryDirectory.appendingPathComponent("fake-trash.jpg")
        try Data([0xAA]).write(to: fakeTrashURL)
        let receipt = DeduplicateAuditReceipt(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            destinationRoot: temporaryDirectory.path,
            items: [
                DeduplicateAuditReceipt.Item(
                    originalPath: missingTrashOriginal.path,
                    sizeBytes: 1,
                    trashURL: nil,
                    method: .trash,
                    clusterID: UUID(),
                    clusterKind: .burst
                ),
                DeduplicateAuditReceipt.Item(
                    originalPath: moveFailureOriginal.path,
                    sizeBytes: 2,
                    trashURL: fakeTrashURL.absoluteString,
                    method: .trash,
                    clusterID: UUID(),
                    clusterKind: .burst
                ),
            ],
            bytesReclaimed: 3
        )
        let receiptURL = temporaryDirectory.appendingPathComponent("dedupe_audit_receipt.json")
        try JSONEncoder.dedupe.encode(receipt).write(to: receiptURL)

        let executor = DeduplicateExecutor(
            fileOperations: MockDeduplicateFileOperations(
                moveErrors: [fakeTrashURL.path: TestDedupeFileError("cannot restore")]
            )
        )
        var failures: [String] = []
        var summary: DeduplicateCommitSummary?
        for try await event in executor.revert(receiptURL: receiptURL) {
            switch event {
            case let .itemFailed(path, message):
                failures.append("\(URL(fileURLWithPath: path).lastPathComponent): \(message)")
            case let .complete(revertSummary):
                summary = revertSummary
            default:
                break
            }
        }

        XCTAssertEqual(failures, [
            "missing-trash.jpg: Receipt is missing the Trash URL for this item.",
            "move-failure.jpg: cannot restore",
        ])
        XCTAssertEqual(summary?.deletedCount, 0)
        XCTAssertEqual(summary?.failedCount, 2)
        XCTAssertEqual(summary?.bytesReclaimed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fakeTrashURL.path))
    }

    /// Regression for review rec #5: receipt filenames used only
    /// second-precision timestamps, so two commits within the same
    /// second produced identical paths. With `data.write(.atomic)`
    /// the second receipt would silently destroy the first, losing
    /// the Run History/revert trail. The UUID suffix added in the
    /// fix must guarantee distinct paths even when both calls happen
    /// in the same second.
    func testWriteReceiptProducesUniqueFilenamesForBackToBackCommits() throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DedupeReceiptCollision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let logsDirectory = try DeduplicateExecutor.preflightReceiptDirectory(destinationRoot: temporaryDirectory.path)

        let item = DeduplicateAuditReceipt.Item(
            originalPath: temporaryDirectory.appendingPathComponent("a.jpg").path,
            sizeBytes: 1,
            trashURL: nil,
            method: .hardDelete,
            clusterID: UUID(),
            clusterKind: .burst
        )

        var paths: [String] = []
        for _ in 0..<2 {
            let receiptPath = try DeduplicateExecutor.writeReceipt(
                logsDirectory: logsDirectory,
                destinationRoot: temporaryDirectory.path,
                items: [item],
                bytesReclaimed: 1
            )
            paths.append(receiptPath)
        }

        XCTAssertEqual(Set(paths).count, 2, "Two same-second writes must produce distinct receipt filenames")
        for path in paths {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: path),
                "Both receipts must remain on disk; second write must not have replaced the first"
            )
        }

        let logsContents = try FileManager.default.contentsOfDirectory(atPath: logsDirectory.path)
            .filter { $0.hasPrefix("dedupe_audit_receipt_") && $0.hasSuffix(".json") }
        XCTAssertEqual(logsContents.count, 2, "Logs directory must contain exactly two dedupe receipts")
    }

    // MARK: - DedupeFeatureCache round-trip

    func testDedupeFeatureCacheRoundTrip() throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let dbURL = temporaryDirectory.appendingPathComponent(".organize_cache.db")
        let db = try OrganizerDatabase(url: dbURL)
        defer { db.close() }
        try db.ensureDedupeFeaturesSchema()

        let fixturePath = temporaryDirectory.appendingPathComponent("a.jpg").path
        let record = DedupeFeatureRecord(
            path: fixturePath,
            size: 1234,
            modificationTime: 100.5,
            dhash: 0xDEADBEEFCAFEBABE,
            featurePrintData: Data([1, 2, 3, 4]),
            sharpness: 0.8,
            faceScore: 0.6,
            pixelWidth: 4032,
            pixelHeight: 3024,
            captureDate: Date(timeIntervalSince1970: 1_700_000_000),
            pairedPath: "/dest/a.cr2"
        )
        try db.saveDedupeFeatureRecords([record])

        let loaded = try db.loadDedupeFeatureRecords()
        XCTAssertEqual(loaded.count, 1)
        let restored = try XCTUnwrap(loaded[fixturePath])
        XCTAssertEqual(restored.size, 1234)
        XCTAssertEqual(restored.dhash, 0xDEADBEEFCAFEBABE)
        XCTAssertEqual(restored.featurePrintData, Data([1, 2, 3, 4]))
        XCTAssertEqual(restored.sharpness, 0.8, accuracy: 0.0001)
        XCTAssertEqual(restored.faceScore, 0.6)
        XCTAssertEqual(restored.pixelWidth, 4032)
        XCTAssertEqual(restored.pixelHeight, 3024)
        XCTAssertEqual(try XCTUnwrap(restored.captureDate?.timeIntervalSince1970), 1_700_000_000, accuracy: 0.0001)
        XCTAssertEqual(restored.pairedPath, "/dest/a.cr2")

        // Pruning removes paths absent from the fresh set.
        try db.pruneDedupeFeatureRecords(notIn: [])
        XCTAssertTrue(try db.loadDedupeFeatureRecords().isEmpty)
    }

    // MARK: - DedupeSimilarityPreset

    func testSimilarityPresetsAreOrdered() {
        XCTAssertLessThan(
            DedupeSimilarityPreset.strict.similarityThreshold,
            DedupeSimilarityPreset.balanced.similarityThreshold
        )
        XCTAssertLessThan(
            DedupeSimilarityPreset.balanced.similarityThreshold,
            DedupeSimilarityPreset.loose.similarityThreshold
        )
        XCTAssertLessThan(
            DedupeSimilarityPreset.strict.dhashHammingThreshold,
            DedupeSimilarityPreset.loose.dhashHammingThreshold
        )
        for preset in DedupeSimilarityPreset.allCases {
            XCTAssertFalse(preset.title.isEmpty)
            XCTAssertFalse(preset.subtitle.isEmpty)
        }
    }

    // MARK: - Helpers

    private func candidate(
        path: String,
        captureDate: Date? = nil,
        dhash: UInt64? = nil,
        featurePrintData: Data? = nil,
        qualityScore: Double = 0.5,
        size: Int64 = 100,
        pairedPath: String? = nil,
        isRaw: Bool = false,
        isLivePhotoStill: Bool = false
    ) -> PhotoCandidate {
        PhotoCandidate(
            path: path,
            size: size,
            modificationTime: 0,
            captureDate: captureDate,
            dhash: dhash,
            featurePrintData: featurePrintData,
            qualityScore: qualityScore,
            isRaw: isRaw,
            isLivePhotoStill: isLivePhotoStill,
            pairedPath: pairedPath
        )
    }

    private func makeGradientImage(reversed: Bool) -> CGImage {
        makeImage(width: 18, height: 16) { x, _, width, _ in
            let value = UInt8((Double(reversed ? width - 1 - x : x) / Double(width - 1)) * 255.0)
            return (value, value, value, 255)
        }
    }

    private func makeCheckerboardImage() -> CGImage {
        makeImage(width: 32, height: 32) { x, y, _, _ in
            let value: UInt8 = ((x / 4 + y / 4).isMultiple(of: 2)) ? 255 : 0
            return (value, value, value, 255)
        }
    }

    private func makeImage(
        width: Int,
        height: Int,
        pixel: (Int, Int, Int, Int) -> (UInt8, UInt8, UInt8, UInt8)
    ) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let (r, g, b, a) = pixel(x, y, width, height)
                bytes[offset] = r
                bytes[offset + 1] = g
                bytes[offset + 2] = b
                bytes[offset + 3] = a
            }
        }

        let data = Data(bytes) as CFData
        let provider = CGDataProvider(data: data)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw TestFailure.expectedFailure("Could not create image destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

private final class TrashedURLBag: @unchecked Sendable {
    private let lock = NSLock()
    private var urlsByOriginalPath: [String: URL] = [:]

    func add(originalPath: String, trashURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        urlsByOriginalPath[originalPath] = trashURL
    }

    func snapshot() -> [String: URL] {
        lock.lock()
        defer { lock.unlock() }
        return urlsByOriginalPath
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        urlsByOriginalPath.removeAll()
    }
}

private struct TestDedupeFileError: Error, LocalizedError, Equatable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private final class MockDeduplicateFileOperations: DeduplicateFileOperations, @unchecked Sendable {
    private let trashRoot: URL?
    private let removeErrors: [String: TestDedupeFileError]
    private let moveErrors: [String: TestDedupeFileError]

    init(
        trashRoot: URL? = nil,
        removeErrors: [String: TestDedupeFileError] = [:],
        moveErrors: [String: TestDedupeFileError] = [:]
    ) {
        self.trashRoot = trashRoot
        self.removeErrors = removeErrors
        self.moveErrors = moveErrors
    }

    func removeItem(at url: URL) throws {
        if let error = removeErrors[url.path] {
            throw error
        }
        try FileManager.default.removeItem(at: url)
    }

    func trashItem(at url: URL) throws -> URL? {
        let root = trashRoot ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MockDedupeTrash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let trashURL = root.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: trashURL)
        return trashURL
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        if let error = moveErrors[sourceURL.path] {
            throw error
        }
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }

    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: createIntermediates)
    }
}

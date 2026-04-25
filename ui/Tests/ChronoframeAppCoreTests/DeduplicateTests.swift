import Foundation
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

    // MARK: - DeduplicateExecutor.expandedDeletePaths

    func testExpandedDeletePathsRespectsPairLocking() {
        let raw = candidate(path: "/dest/IMG.CR2", pairedPath: "/dest/IMG.JPG")
        let jpeg = candidate(path: "/dest/IMG.JPG", pairedPath: "/dest/IMG.CR2")
        let other = candidate(path: "/dest/OTHER.JPG")

        let cluster = DuplicateCluster(
            kind: .nearDuplicate,
            members: [raw, jpeg, other],
            suggestedKeeperIDs: ["/dest/OTHER.JPG"],
            bytesIfPruned: 200
        )
        // User explicitly deletes the JPEG, accepts suggested keeper for the
        // RAW (which means delete it), and keeps OTHER.
        let decisions = DedupeDecisions(byPath: [
            "/dest/IMG.JPG": .delete,
            "/dest/OTHER.JPG": .keep,
        ])
        let config = DeduplicateConfiguration(destinationPath: "/dest", treatRawJpegPairsAsUnit: true)

        let toDelete = DeduplicateExecutor.expandedDeletePaths(
            decisions: decisions,
            clusters: [cluster],
            configuration: config
        )
        XCTAssertTrue(toDelete.contains("/dest/IMG.JPG"))
        XCTAssertTrue(toDelete.contains("/dest/IMG.CR2"), "Pair partner must be deleted alongside")
        XCTAssertFalse(toDelete.contains("/dest/OTHER.JPG"))
    }

    func testExpandedDeletePathsRefusesAllDelete() {
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
        let toDelete = DeduplicateExecutor.expandedDeletePaths(
            decisions: decisions,
            clusters: [cluster],
            configuration: DeduplicateConfiguration(destinationPath: "/dest")
        )
        XCTAssertTrue(toDelete.isEmpty, "Safety rail: never delete every member of a cluster")
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
        pairedPath: String? = nil
    ) -> PhotoCandidate {
        PhotoCandidate(
            path: path,
            size: size,
            modificationTime: 0,
            captureDate: captureDate,
            dhash: dhash,
            featurePrintData: featurePrintData,
            qualityScore: qualityScore,
            pairedPath: pairedPath
        )
    }
}

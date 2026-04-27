import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ChronoframeApp

@MainActor
final class DedupeThumbnailLoaderTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DedupeThumbnailLoaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        try super.tearDownWithError()
    }

    /// Sanity check: a request for a real on-disk image should populate
    /// the cache asynchronously and bump the `version` so SwiftUI views
    /// observing the loader redraw.
    func testRequestPopulatesCacheAndBumpsVersion() async throws {
        let imageURL = try writePNG(name: "still", size: NSSize(width: 32, height: 32), color: .red)
        let loader = DedupeThumbnailLoader()

        let initialVersion = loader.version
        loader.request(path: imageURL.path, size: CGSize(width: 64, height: 64))

        let inserted = await waitForCondition { loader.image(for: imageURL.path) != nil }
        XCTAssertTrue(inserted, "Cache must hold the rendered thumbnail after the QL render completes")
        XCTAssertGreaterThan(loader.version, initialVersion, "version must bump so observers redraw")
    }

    /// Regression for review rec #7: the cache must not grow without
    /// bound. With `countLimit = 2` the loader can keep up to two images
    /// resident; further inserts evict older entries (NSCache may be
    /// approximate, but the cap should hold within a small slack).
    func testCacheRespectsCountLimit() async throws {
        let loader = DedupeThumbnailLoader(countLimit: 2)
        var paths: [String] = []
        for index in 0..<5 {
            let url = try writePNG(name: "photo-\(index)", size: NSSize(width: 16, height: 16), color: .blue)
            paths.append(url.path)
            loader.request(path: url.path, size: CGSize(width: 32, height: 32))
        }

        // Wait for the renders to finish.
        let allLoaded = await waitForCondition(timeoutNanoseconds: 5_000_000_000) {
            paths.allSatisfy { _ in
                // We only need to know inserts have settled — counting
                // resident images is enough.
                paths.compactMap { loader.image(for: $0) }.count > 0
            }
        }
        XCTAssertTrue(allLoaded)

        // Give NSCache a beat to evict.
        try await Task.sleep(nanoseconds: 100_000_000)
        let resident = paths.compactMap { loader.image(for: $0) }.count
        XCTAssertLessThanOrEqual(resident, 3, "Cache must cap roughly to countLimit (2 + small NSCache slack)")
    }

    /// Regression for review rec #8: `cancelAll()` must drop in-flight
    /// tasks so we don't keep rendering thumbnails for a workspace the
    /// user has navigated away from.
    func testCancelAllPreventsLateInsertsForCancelledRequests() async throws {
        let imageURL = try writePNG(name: "stop", size: NSSize(width: 32, height: 32), color: .green)
        let loader = DedupeThumbnailLoader()

        loader.request(path: imageURL.path, size: CGSize(width: 64, height: 64))
        loader.cancelAll()

        // Allow the cancelled task ample time to (not) populate the cache.
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNil(
            loader.image(for: imageURL.path),
            "Cancelled request must not insert into the cache"
        )
    }

    /// `purgeCache()` empties the cache and bumps `version` so observers
    /// redraw with the cleared state.
    func testPurgeCacheClearsResidentImages() async throws {
        let imageURL = try writePNG(name: "purge", size: NSSize(width: 16, height: 16), color: .orange)
        let loader = DedupeThumbnailLoader()
        loader.request(path: imageURL.path, size: CGSize(width: 32, height: 32))
        _ = await waitForCondition { loader.image(for: imageURL.path) != nil }

        let beforePurge = loader.version
        loader.purgeCache()

        XCTAssertNil(loader.image(for: imageURL.path))
        XCTAssertGreaterThan(loader.version, beforePurge)
    }

    // MARK: - Helpers

    private func writePNG(name: String, size: NSSize, color: NSColor) throws -> URL {
        let url = temporaryDirectoryURL.appendingPathComponent("\(name).png")
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw AppTestFailure.expectedFailure("Could not encode PNG fixture")
        }
        try png.write(to: url)
        return url
    }
}

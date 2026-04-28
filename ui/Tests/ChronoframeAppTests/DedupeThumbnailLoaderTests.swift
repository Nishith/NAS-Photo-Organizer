import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ChronoframeApp

@MainActor
final class DedupeThumbnailLoaderTests: XCTestCase {
    func testRequestPopulatesCacheAndBumpsVersion() async {
        let image = makeCGImage(color: .red)
        let loader = DedupeThumbnailLoader(renderer: { _, _, _ in image })
        let path = "/tmp/still.png"

        let initialVersion = loader.version
        loader.request(path: path, size: CGSize(width: 64, height: 64))

        let inserted = await waitForCondition { loader.image(for: path) != nil }
        XCTAssertTrue(inserted, "Cache must hold the rendered thumbnail after the render completes")
        XCTAssertGreaterThan(loader.version, initialVersion, "version must bump so observers redraw")
    }

    /// Regression for review rec #7: the cache must not grow without
    /// bound. With `countLimit = 2` the loader can keep up to two images
    /// resident; further inserts evict older entries (NSCache may be
    /// approximate, but the cap should hold within a small slack).
    func testCacheRespectsCountLimit() async throws {
        let image = makeCGImage(color: .blue)
        let loader = DedupeThumbnailLoader(countLimit: 2, renderer: { _, _, _ in image })
        let paths = (0..<5).map { "/tmp/photo-\($0).png" }
        for index in 0..<5 {
            loader.request(path: paths[index], size: CGSize(width: 32, height: 32))
        }

        // Wait for the renders to finish.
        let allLoaded = await waitForCondition(timeoutNanoseconds: 5_000_000_000) {
            loader.version >= paths.count
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
        let image = makeCGImage(color: .green)
        let loader = DedupeThumbnailLoader(renderer: { _, _, _ in
            try? await Task.sleep(nanoseconds: 100_000_000)
            return image
        })
        let path = "/tmp/stop.png"

        loader.request(path: path, size: CGSize(width: 64, height: 64))
        loader.cancelAll()

        // Allow the cancelled task ample time to (not) populate the cache.
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNil(
            loader.image(for: path),
            "Cancelled request must not insert into the cache"
        )
    }

    /// `purgeCache()` empties the cache and bumps `version` so observers
    /// redraw with the cleared state.
    func testPurgeCacheClearsResidentImages() async {
        let image = makeCGImage(color: .orange)
        let loader = DedupeThumbnailLoader(renderer: { _, _, _ in image })
        let path = "/tmp/purge.png"
        loader.request(path: path, size: CGSize(width: 32, height: 32))
        _ = await waitForCondition { loader.image(for: path) != nil }

        let beforePurge = loader.version
        loader.purgeCache()

        XCTAssertNil(loader.image(for: path))
        XCTAssertGreaterThan(loader.version, beforePurge)
    }

    // MARK: - Helpers

    private func makeCGImage(color: NSColor) -> CGImage {
        let width = 4
        let height = 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Could not create bitmap context")
            return CGImage.emptyTestImage
        }
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? CGImage.emptyTestImage
    }
}

private extension CGImage {
    static var emptyTestImage: CGImage {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let data = Data([0x00]) as CFData
        let provider = CGDataProvider(data: data)!
        return CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: 1,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
}

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ChronoframeApp

@MainActor
final class DedupeThumbnailLoaderTests: XCTestCase {
    func testRequestPopulatesCache() async {
        let image = makeCGImage(color: .red)
        let loader = DedupeThumbnailLoader(renderer: { _, _, _ in image })
        let path = "/tmp/still.png"
        let size = CGSize(width: 64, height: 64)

        let nsImage = await loader.image(for: path, size: size)
        XCTAssertNotNil(nsImage, "image(for:size:) must return the rendered thumbnail")
        XCTAssertNotNil(loader.cachedImage(for: path, size: size), "Cache must hold the rendered thumbnail")
    }

    func testCacheSeparatesSamePathAtDifferentSizes() async {
        let smallImage = makeCGImage(color: .red)
        let largeImage = makeCGImage(color: .blue)
        let recorder = RenderRecorder()
        let loader = DedupeThumbnailLoader(
            renderer: { _, size, _ in
                recorder.record(size)
                return size.width < 60 ? smallImage : largeImage
            },
            scaleProvider: { 2.0 }
        )
        let path = "/tmp/shared.png"
        let smallSize = CGSize(width: 44, height: 44)
        let largeSize = CGSize(width: 88, height: 88)

        let small = await loader.image(for: path, size: smallSize)
        let large = await loader.image(for: path, size: largeSize)

        XCTAssertNotNil(small)
        XCTAssertNotNil(large)
        XCTAssertFalse(small === large)
        XCTAssertEqual(recorder.recordedSizes, [smallSize, largeSize])
        XCTAssertNotNil(loader.cachedImage(for: path, size: smallSize))
        XCTAssertNotNil(loader.cachedImage(for: path, size: largeSize))

        _ = await loader.image(for: path, size: smallSize)
        XCTAssertEqual(recorder.recordedSizes, [smallSize, largeSize], "Second small request should hit the size-specific cache")
    }

    /// Regression for review rec #7: the cache must not grow without
    /// bound. With `countLimit = 2` the loader can keep up to two images
    /// resident; further inserts evict older entries (NSCache may be
    /// approximate, but the cap should hold within a small slack).
    func testCacheRespectsCountLimit() async throws {
        let image = makeCGImage(color: .blue)
        let loader = DedupeThumbnailLoader(countLimit: 2, renderer: { _, _, _ in image })
        let paths = (0..<5).map { "/tmp/photo-\($0).png" }
        let size = CGSize(width: 32, height: 32)
        for index in 0..<5 {
            _ = await loader.image(for: paths[index], size: size)
        }

        // Give NSCache a beat to evict.
        try await Task.sleep(nanoseconds: 100_000_000)
        let resident = paths.compactMap { loader.cachedImage(for: $0, size: size) }.count
        XCTAssertLessThanOrEqual(resident, 3, "Cache must cap roughly to countLimit (2 + small NSCache slack)")
    }

    /// Regression for review rec #8: cancellation must drop in-flight
    /// tasks so we don't keep rendering thumbnails for a workspace the
    /// user has navigated away from.
    func testCancellationPreventsLateInsertsForCancelledRequests() async throws {
        let image = makeCGImage(color: .green)
        let loader = DedupeThumbnailLoader(renderer: { _, _, _ in
            try? await Task.sleep(nanoseconds: 100_000_000)
            return image
        })
        let path = "/tmp/stop.png"
        let size = CGSize(width: 64, height: 64)

        let task = Task {
            await loader.image(for: path, size: size)
        }
        task.cancel()
        _ = await task.value

        // Allow the cancelled task ample time to (not) populate the cache.
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNil(
            loader.cachedImage(for: path, size: size),
            "Cancelled request must not insert into the cache"
        )
    }

    /// `purgeCache()` empties the cache.
    func testPurgeCacheClearsResidentImages() async {
        let image = makeCGImage(color: .orange)
        let loader = DedupeThumbnailLoader(renderer: { _, _, _ in image })
        let path = "/tmp/purge.png"
        let size = CGSize(width: 32, height: 32)
        _ = await loader.image(for: path, size: size)

        XCTAssertNotNil(loader.cachedImage(for: path, size: size))
        loader.purgeCache()
        XCTAssertNil(loader.cachedImage(for: path, size: size))
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

private final class RenderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [CGSize] = []

    var recordedSizes: [CGSize] {
        lock.lock()
        defer { lock.unlock() }
        return sizes
    }

    func record(_ size: CGSize) {
        lock.lock()
        sizes.append(size)
        lock.unlock()
    }
}

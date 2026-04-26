import AppKit
import SwiftUI
import XCTest
@testable import ChronoframeApp

@MainActor
final class ContactSheetViewTests: XCTestCase {
    func testThumbnailCellClipsWideImagesToCellBounds() throws {
        let cellSize: CGFloat = 80
        let thumbnail = Self.makeImage(
            size: NSSize(width: 320, height: 80),
            color: NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1)
        )
        let rendered = try render(
            HStack(spacing: 0) {
                ContactSheetThumbnailCell(thumbnail: thumbnail, cellSize: cellSize)
                Color.clear.frame(width: cellSize, height: cellSize)
            }
            .frame(width: cellSize * 2, height: cellSize, alignment: .leading)
            .background(Color.black),
            size: NSSize(width: cellSize * 2, height: cellSize)
        )

        let thumbnailProbe = try XCTUnwrap(
            rendered.colorAt(x: Int(Double(rendered.pixelsWide) * 0.25), y: Int(Double(rendered.pixelsHigh) * 0.5))
        )
        XCTAssertGreaterThan(thumbnailProbe.redComponent, 0.90)

        let spilloverProbe = try XCTUnwrap(
            rendered.colorAt(x: Int(Double(rendered.pixelsWide) * 0.75), y: Int(Double(rendered.pixelsHigh) * 0.5))
        )
        XCTAssertLessThan(spilloverProbe.redComponent, 0.10)
        XCTAssertLessThan(spilloverProbe.greenComponent, 0.10)
        XCTAssertLessThan(spilloverProbe.blueComponent, 0.10)
    }

    func testThumbnailCellKeepsStableSquareLayout() {
        let cellSize: CGFloat = 80
        let thumbnail = Self.makeImage(
            size: NSSize(width: 80, height: 80),
            color: NSColor(calibratedRed: 0, green: 0, blue: 1, alpha: 1)
        )
        let hostingView = NSHostingView(
            rootView: ContactSheetThumbnailCell(thumbnail: thumbnail, cellSize: cellSize)
        )

        XCTAssertEqual(hostingView.fittingSize.width, cellSize, accuracy: 0.5)
        XCTAssertEqual(hostingView.fittingSize.height, cellSize, accuracy: 0.5)
    }

    func testThumbnailPipelineSkipsFailedCandidatesAndKeepsSuccessfulOrder() async {
        let urls = (0..<8).map { URL(fileURLWithPath: "/tmp/frame-\($0).jpg") }

        let imageData = await ContactSheetThumbnailPipeline.loadThumbnailData(
            from: urls,
            count: 3,
            size: CGSize(width: 80, height: 80),
            scale: 2
        ) { url, _, _ in
            let rawIndex = url
                .deletingPathExtension()
                .lastPathComponent
                .replacingOccurrences(of: "frame-", with: "")
            guard let index = UInt8(rawIndex), !index.isMultiple(of: 2) else {
                return nil
            }
            return Data([index])
        }

        XCTAssertEqual(imageData.compactMap(\.first), [1, 3, 5])
        XCTAssertEqual(ContactSheetThumbnailPipeline.candidateLimit(for: 12), 48)
    }

    private func render<V: View>(_ view: V, size: NSSize) throws -> NSBitmapImageRep {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bounds = hostingView.bounds
        let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: bounds))
        hostingView.cacheDisplay(in: bounds, to: bitmap)
        return bitmap
    }

    private static func makeImage(size: NSSize, color: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }
}

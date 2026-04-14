#!/usr/bin/env swift

import AppKit
import Foundation

struct IconPalette {
    let sky = NSColor(srgbRed: 0.18, green: 0.47, blue: 0.90, alpha: 1.0)
    let aqua = NSColor(srgbRed: 0.39, green: 0.74, blue: 0.93, alpha: 1.0)
    let warm = NSColor(srgbRed: 0.96, green: 0.72, blue: 0.43, alpha: 1.0)
    let ink = NSColor(srgbRed: 0.15, green: 0.20, blue: 0.28, alpha: 1.0)
    let glass = NSColor.white.withAlphaComponent(0.24)
    let card = NSColor.white.withAlphaComponent(0.72)
    let cardStroke = NSColor.white.withAlphaComponent(0.56)
    let shadow = NSColor.black.withAlphaComponent(0.10)
}

let palette = IconPalette()

let outputPath = CommandLine.arguments.dropFirst().first ?? "build/AppIcon.iconset"
let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

let iconSpecs: [(base: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

for spec in iconSpecs {
    let actualSize = spec.base * spec.scale
    let image = drawIcon(size: actualSize)
    let filename = spec.scale == 1
        ? "icon_\(spec.base)x\(spec.base).png"
        : "icon_\(spec.base)x\(spec.base)@2x.png"
    try savePNG(image, to: outputURL.appendingPathComponent(filename))
}

func drawIcon(size: Int) -> NSImage {
    let canvas = NSSize(width: size, height: size)
    let image = NSImage(size: canvas)

    image.lockFocus()
    defer { image.unlockFocus() }

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        return image
    }

    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    let rect = CGRect(origin: .zero, size: canvas)
    let inset = CGFloat(size) * 0.05
    let shellRect = rect.insetBy(dx: inset, dy: inset)
    let shellRadius = CGFloat(size) * 0.23
    let shellPath = NSBezierPath(roundedRect: shellRect, xRadius: shellRadius, yRadius: shellRadius)

    let shellGradient = NSGradient(colorsAndLocations:
        (palette.sky, 0.0),
        (palette.aqua, 0.56),
        (palette.warm, 1.0)
    )!
    shellGradient.draw(in: shellPath, angle: -52)

    palette.shadow.setFill()
    NSBezierPath(roundedRect: shellRect.offsetBy(dx: 0, dy: -CGFloat(size) * 0.01),
                 xRadius: shellRadius, yRadius: shellRadius).fill()

    NSColor.white.withAlphaComponent(0.18).setFill()
    NSBezierPath(ovalIn: CGRect(
        x: CGFloat(size) * 0.12,
        y: CGFloat(size) * 0.54,
        width: CGFloat(size) * 0.58,
        height: CGFloat(size) * 0.56
    )).fill()

    palette.glass.setFill()
    NSBezierPath(roundedRect: CGRect(
        x: CGFloat(size) * 0.18,
        y: CGFloat(size) * 0.22,
        width: CGFloat(size) * 0.64,
        height: CGFloat(size) * 0.50
    ), xRadius: CGFloat(size) * 0.12, yRadius: CGFloat(size) * 0.12).fill()

    drawPhotoCards(size: size)
    drawDrive(size: size)

    palette.cardStroke.setStroke()
    shellPath.lineWidth = max(2, CGFloat(size) * 0.01)
    shellPath.stroke()

    return image
}

func drawPhotoCards(size: Int) {
    let total = CGFloat(size)
    let cardSize = CGSize(width: total * 0.32, height: total * 0.26)
    let origin = CGPoint(x: total * 0.20, y: total * 0.38)
    let offsets: [CGPoint] = [
        CGPoint(x: total * 0.08, y: total * 0.06),
        CGPoint(x: total * 0.04, y: total * 0.03),
        .zero,
    ]

    for (index, offset) in offsets.enumerated() {
        let rect = CGRect(origin: CGPoint(x: origin.x + offset.x, y: origin.y + offset.y), size: cardSize)
        let path = NSBezierPath(roundedRect: rect, xRadius: total * 0.045, yRadius: total * 0.045)
        let alpha = 0.32 + (Double(index) * 0.16)
        NSColor.white.withAlphaComponent(alpha).setFill()
        path.fill()
        palette.cardStroke.setStroke()
        path.lineWidth = max(1, total * 0.006)
        path.stroke()

        if index == offsets.count - 1 {
            drawPhotoDetails(in: rect, size: total)
        }
    }
}

func drawPhotoDetails(in rect: CGRect, size: CGFloat) {
    let sunSize = size * 0.045
    let sunRect = CGRect(x: rect.minX + size * 0.05, y: rect.maxY - size * 0.08, width: sunSize, height: sunSize)
    NSColor(srgbRed: 1.0, green: 0.84, blue: 0.50, alpha: 0.95).setFill()
    NSBezierPath(ovalIn: sunRect).fill()

    let hillPath = NSBezierPath()
    hillPath.move(to: CGPoint(x: rect.minX + size * 0.03, y: rect.minY + size * 0.05))
    hillPath.line(to: CGPoint(x: rect.minX + size * 0.12, y: rect.minY + size * 0.12))
    hillPath.line(to: CGPoint(x: rect.minX + size * 0.18, y: rect.minY + size * 0.08))
    hillPath.line(to: CGPoint(x: rect.minX + size * 0.24, y: rect.minY + size * 0.15))
    hillPath.line(to: CGPoint(x: rect.maxX - size * 0.03, y: rect.minY + size * 0.06))
    hillPath.line(to: CGPoint(x: rect.maxX - size * 0.03, y: rect.minY + size * 0.03))
    hillPath.line(to: CGPoint(x: rect.minX + size * 0.03, y: rect.minY + size * 0.03))
    hillPath.close()
    NSColor(srgbRed: 0.14, green: 0.28, blue: 0.43, alpha: 0.52).setFill()
    hillPath.fill()
}

func drawDrive(size: Int) {
    let total = CGFloat(size)
    let driveRect = CGRect(
        x: total * 0.22,
        y: total * 0.14,
        width: total * 0.56,
        height: total * 0.16
    )

    let drivePath = NSBezierPath(roundedRect: driveRect, xRadius: total * 0.08, yRadius: total * 0.08)
    let driveGradient = NSGradient(colorsAndLocations:
        (palette.ink.withAlphaComponent(0.86), 0.0),
        (NSColor(srgbRed: 0.22, green: 0.27, blue: 0.36, alpha: 0.92), 1.0)
    )!
    driveGradient.draw(in: drivePath, angle: 90)

    NSColor.white.withAlphaComponent(0.22).setFill()
    NSBezierPath(roundedRect: CGRect(
        x: driveRect.minX + total * 0.03,
        y: driveRect.maxY - total * 0.04,
        width: driveRect.width - total * 0.06,
        height: total * 0.015
    ), xRadius: total * 0.01, yRadius: total * 0.01).fill()

    NSColor(srgbRed: 0.53, green: 0.91, blue: 0.60, alpha: 1.0).setFill()
    NSBezierPath(ovalIn: CGRect(
        x: driveRect.maxX - total * 0.08,
        y: driveRect.midY - total * 0.018,
        width: total * 0.022,
        height: total * 0.022
    )).fill()
}

func savePNG(_ image: NSImage, to url: URL) throws {
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [.compressionFactor: 1.0]) else {
        throw NSError(domain: "IconGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }

    try pngData.write(to: url)
}

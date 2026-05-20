// Procedural macOS app-icon renderer for Chronoframe.
//
// One source of truth for the icon: every color, blade angle, and corner
// radius lives in this file. Re-run after editing to regenerate the
// asset catalog:
//
//     swift run --package-path ui ChronoframeIconTool \
//         ui/Resources/Assets.xcassets/AppIcon.appiconset
//
// The tool emits 30 PNGs — Any/Dark/Tinted × 10 (size × scale) pairs —
// plus the catalog's `Contents.json` declaring the appearance variants
// the macOS 14+ icon-tinting system requires.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Variants

enum IconVariant: String, CaseIterable {
    case any
    case dark
    case tinted

    /// Filename suffix used by the asset catalog convention.
    var filenameSuffix: String {
        switch self {
        case .any: return ""
        case .dark: return "_dark"
        case .tinted: return "_tinted"
        }
    }

    /// Asset-catalog `appearances` array. `nil` for the default ("Any") slot.
    var appearancesJSON: String? {
        switch self {
        case .any: return nil
        case .dark: return "[{\"appearance\":\"luminosity\",\"value\":\"dark\"}]"
        case .tinted: return "[{\"appearance\":\"luminosity\",\"value\":\"tinted\"}]"
        }
    }
}

// MARK: - Sizes

/// macOS AppIcon expects the conventional 10 entries: 16/32/128/256/512
/// at 1x and 2x. We render each pixel size *independently* (no upscaling),
/// so file-size duplication of the previous iconset is fixed at the source.
struct IconSlot {
    let nominalPoints: Int
    let scale: Int

    var pixelSize: Int { nominalPoints * scale }

    var sizeJSON: String { "\(nominalPoints)x\(nominalPoints)" }
    var scaleJSON: String { "\(scale)x" }

    /// Catalog filename — variant suffix is appended by the caller.
    var baseFilename: String {
        let suffix = scale == 2 ? "@2x" : ""
        return "icon_\(nominalPoints)x\(nominalPoints)\(suffix)"
    }

    static let all: [IconSlot] = [
        IconSlot(nominalPoints: 16, scale: 1),
        IconSlot(nominalPoints: 16, scale: 2),
        IconSlot(nominalPoints: 32, scale: 1),
        IconSlot(nominalPoints: 32, scale: 2),
        IconSlot(nominalPoints: 128, scale: 1),
        IconSlot(nominalPoints: 128, scale: 2),
        IconSlot(nominalPoints: 256, scale: 1),
        IconSlot(nominalPoints: 256, scale: 2),
        IconSlot(nominalPoints: 512, scale: 1),
        IconSlot(nominalPoints: 512, scale: 2),
    ]
}

// MARK: - Color palette

/// All colors used by the icon. Sourced to match the app's Darkroom design
/// tokens (action indigo + waypoint amber), pushed a touch toward purple
/// per the design refresh ask. Both Light and Dark variants land in the
/// same visual family — Dark is slightly deeper for legibility against
/// system Dark mode menubar/Dock backgrounds.
enum Palette {
    struct RGB {
        let r: Double
        let g: Double
        let b: Double
        let a: Double

        init(_ r: Int, _ g: Int, _ b: Int, _ a: Double = 1.0) {
            self.r = Double(r) / 255
            self.g = Double(g) / 255
            self.b = Double(b) / 255
            self.a = a
        }

        var cgColor: CGColor {
            CGColor(srgbRed: r, green: g, blue: b, alpha: a)
        }
    }

    struct BackgroundGradient {
        let topLeft: RGB
        let bottomRight: RGB
    }

    // Brighter amethyst → deeper indigo-purple. Replaces the prior
    // navy-to-near-black which the user found too dark.
    static let lightBackground = BackgroundGradient(
        topLeft: RGB(120, 88, 245),
        bottomRight: RGB(74, 46, 196)
    )

    static let darkBackground = BackgroundGradient(
        topLeft: RGB(101, 73, 226),
        bottomRight: RGB(58, 34, 168)
    )

    // For the Tinted appearance the system applies its own monochrome
    // tinting on top of a grayscale source. We render the body in white
    // on a near-black square (no rounded corners — system reshapes).
    static let tintedBackground = BackgroundGradient(
        topLeft: RGB(28, 28, 32),
        bottomRight: RGB(14, 14, 18)
    )

    static let apertureBladeTop = RGB(245, 245, 248)
    static let apertureBladeBottom = RGB(178, 180, 192)
    static let apertureRimOuter = RGB(255, 255, 255, 0.18)
    static let apertureInnerShadow = RGB(0, 0, 0, 0.45)

    static let waypointAmber = RGB(246, 185, 74)   // matches DesignTokens.accentWaypoint (dark)
    static let waypointHighlight = RGB(255, 224, 168)

    static let horizonLine = RGB(255, 255, 255, 0.52)

    static let monogramInk = RGB(255, 255, 255, 0.72)

    // Tinted (monochrome) silhouette colors. System applies the user's
    // tint on top, so values closer to white give brighter tinting.
    static let tintedForeground = RGB(255, 255, 255)
    static let tintedSecondary = RGB(255, 255, 255, 0.78)
    static let tintedDim = RGB(255, 255, 255, 0.42)
}

// MARK: - Renderer

struct IconRenderer {
    let variant: IconVariant
    let pixelSize: Int

    func render() -> Data {
        let size = pixelSize
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("Failed to allocate CGContext at \(size)x\(size)")
        }

        // CoreGraphics origin is bottom-left. Flip so we can reason about
        // the canvas in top-left coordinates without inverting every Y.
        context.translateBy(x: 0, y: CGFloat(size))
        context.scaleBy(x: 1, y: -1)

        let canvas = CGRect(x: 0, y: 0, width: size, height: size)
        drawBackground(in: canvas, context: context)
        drawAperture(in: canvas, context: context)
        // Horizon and monogram clutter the silhouette below 64 px — at
        // Dock/menubar sizes the icon should read as "purple squircle,
        // bright iris, amber center." Detail layers come back at the
        // sizes where they can actually be seen.
        if size >= 64 {
            drawHorizon(in: canvas, context: context)
        }
        drawCenterDot(in: canvas, context: context)
        if size >= 128 {
            drawMonogram(in: canvas, context: context)
        }

        guard let cgImage = context.makeImage() else {
            fatalError("Failed to produce CGImage at \(size)x\(size)")
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Failed to encode PNG at \(size)x\(size)")
        }
        return data
    }

    // MARK: - Layers

    private func drawBackground(in rect: CGRect, context: CGContext) {
        let cornerRadius = rect.width * 0.225

        // Tinted variant: no rounded mask (system reshapes for menu bar).
        // Light/Dark: classic squircle with diagonal gradient.
        let path: CGPath
        if variant == .tinted {
            path = CGPath(rect: rect, transform: nil)
        } else {
            path = CGPath(
                roundedRect: rect,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            )
        }

        context.saveGState()
        context.addPath(path)
        context.clip()

        let gradient = backgroundGradient(in: rect)
        let start = CGPoint(x: rect.minX, y: rect.minY)
        let end = CGPoint(x: rect.maxX, y: rect.maxY)
        context.drawLinearGradient(
            gradient,
            start: start,
            end: end,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        context.restoreGState()
    }

    private func backgroundGradient(in rect: CGRect) -> CGGradient {
        let palette: Palette.BackgroundGradient
        switch variant {
        case .any: palette = Palette.lightBackground
        case .dark: palette = Palette.darkBackground
        case .tinted: palette = Palette.tintedBackground
        }
        let colors = [palette.topLeft.cgColor, palette.bottomRight.cgColor] as CFArray
        let locations: [CGFloat] = [0, 1]
        return CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: locations
        )!
    }

    private func drawAperture(in rect: CGRect, context: CGContext) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // Slightly smaller than before (0.34 → 0.31) — gives the squircle
        // visible breathing room at every size and keeps the amber center
        // dominant rather than the blades.
        let radius = rect.width * 0.31
        let bladeCount = 6
        // Each blade is a triangular wedge; the chord between adjacent
        // outer vertices forms the apparent hexagonal aperture edge.
        let bladeFill = blades(center: center, radius: radius, count: bladeCount, rect: rect)

        context.saveGState()

        if variant == .tinted {
            // Tinted: solid white iris ring + slightly dimmer blade fill.
            context.setFillColor(Palette.tintedForeground.cgColor)
            context.fillEllipse(in: CGRect(
                x: center.x - radius * 1.04,
                y: center.y - radius * 1.04,
                width: radius * 2.08,
                height: radius * 2.08
            ))
            context.setFillColor(Palette.tintedBackground.topLeft.cgColor)
            context.fillEllipse(in: CGRect(
                x: center.x - radius * 0.92,
                y: center.y - radius * 0.92,
                width: radius * 1.84,
                height: radius * 1.84
            ))
            context.setFillColor(Palette.tintedSecondary.cgColor)
            for blade in bladeFill {
                context.addPath(blade)
                context.fillPath()
            }
            context.restoreGState()
            return
        }

        // Outer rim (subtle bright ring).
        context.setFillColor(Palette.apertureRimOuter.cgColor)
        context.fillEllipse(in: CGRect(
            x: center.x - radius * 1.07,
            y: center.y - radius * 1.07,
            width: radius * 2.14,
            height: radius * 2.14
        ))

        // Blade gradient — vertical, top brighter than bottom.
        let bladeGradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                Palette.apertureBladeTop.cgColor,
                Palette.apertureBladeBottom.cgColor,
            ] as CFArray,
            locations: [0, 1]
        )!

        for blade in bladeFill {
            context.saveGState()
            context.addPath(blade)
            context.clip()
            context.drawLinearGradient(
                bladeGradient,
                start: CGPoint(x: rect.midX, y: rect.midY - radius),
                end: CGPoint(x: rect.midX, y: rect.midY + radius),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
            context.restoreGState()
        }

        // Inner shadow well — a darker disk that suggests depth and
        // separates the amber waypoint from the blade fill so the
        // center dot reads at every size.
        let wellRadius = radius * 0.28
        context.setFillColor(Palette.apertureInnerShadow.cgColor)
        context.fillEllipse(in: CGRect(
            x: center.x - wellRadius,
            y: center.y - wellRadius,
            width: wellRadius * 2,
            height: wellRadius * 2
        ))

        context.restoreGState()
    }

    /// Six trapezoidal blades arranged radially around the optical center.
    /// Each blade overlaps its neighbor slightly so the hexagonal outline
    /// reads cleanly even at small sizes.
    private func blades(
        center: CGPoint,
        radius: CGFloat,
        count: Int,
        rect: CGRect
    ) -> [CGPath] {
        var paths: [CGPath] = []
        let outerR = radius
        // Blades open inward to a small aperture; the inner hole is the
        // amber waypoint dot's radius.
        let innerR = radius * 0.22

        for index in 0..<count {
            let theta = (CGFloat(index) / CGFloat(count)) * .pi * 2 - .pi / 2
            let nextTheta = (CGFloat(index + 1) / CGFloat(count)) * .pi * 2 - .pi / 2

            let outerA = CGPoint(
                x: center.x + cos(theta) * outerR,
                y: center.y + sin(theta) * outerR
            )
            let outerB = CGPoint(
                x: center.x + cos(nextTheta) * outerR,
                y: center.y + sin(nextTheta) * outerR
            )
            let innerB = CGPoint(
                x: center.x + cos(nextTheta) * innerR,
                y: center.y + sin(nextTheta) * innerR
            )
            let innerA = CGPoint(
                x: center.x + cos(theta) * innerR,
                y: center.y + sin(theta) * innerR
            )

            let path = CGMutablePath()
            path.move(to: outerA)
            path.addLine(to: outerB)
            path.addLine(to: innerB)
            path.addLine(to: innerA)
            path.closeSubpath()
            paths.append(path)
            _ = rect // keep the parameter live for future bounds-aware tweaks
        }
        return paths
    }

    private func drawHorizon(in rect: CGRect, context: CGContext) {
        let lineColor = variant == .tinted ? Palette.tintedDim : Palette.horizonLine
        let lineWidth = max(rect.width * 0.012, 1)
        let y = rect.midY
        let inset = rect.width * 0.12

        context.saveGState()
        context.setStrokeColor(lineColor.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: rect.minX + inset, y: y))
        context.addLine(to: CGPoint(x: rect.maxX - inset, y: y))
        context.strokePath()
        context.restoreGState()
    }

    private func drawCenterDot(in rect: CGRect, context: CGContext) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // The waypoint is the icon's signature element — it must read as
        // a single warm bead at 16 px. Bumped from 0.046 → 0.078.
        let dotRadius = rect.width * 0.078

        if variant == .tinted {
            context.setFillColor(Palette.tintedForeground.cgColor)
            context.fillEllipse(in: CGRect(
                x: center.x - dotRadius,
                y: center.y - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            ))
            return
        }

        // Amber waypoint with a brighter highlight on the upper-left to
        // suggest a polished bead.
        context.setFillColor(Palette.waypointAmber.cgColor)
        context.fillEllipse(in: CGRect(
            x: center.x - dotRadius,
            y: center.y - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        ))

        let highlightRadius = dotRadius * 0.55
        context.setFillColor(Palette.waypointHighlight.cgColor)
        context.fillEllipse(in: CGRect(
            x: center.x - dotRadius * 0.55,
            y: center.y - dotRadius * 0.55,
            width: highlightRadius * 2,
            height: highlightRadius * 2
        ))
    }

    private func drawMonogram(in rect: CGRect, context: CGContext) {
        // "CF" lower-right. Skipped at small sizes (< 128) where the
        // glyphs would only blur the silhouette.
        let inkColor = variant == .tinted ? Palette.tintedSecondary : Palette.monogramInk
        let pointSize = rect.width * 0.13

        let font = NSFont.systemFont(ofSize: pointSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: inkColor.cgColor) ?? .white,
            .kern: -pointSize * 0.05,
        ]
        let string = NSAttributedString(string: "CF", attributes: attributes)
        let line = CTLineCreateWithAttributedString(string)

        let bounds = CTLineGetImageBounds(line, context)
        let padding = rect.width * 0.07
        let originX = rect.maxX - bounds.width - padding
        let originY = rect.maxY - bounds.height - padding

        context.saveGState()
        // Undo the global flip locally so the glyphs render right-side up.
        context.translateBy(x: 0, y: rect.height)
        context.scaleBy(x: 1, y: -1)
        let flippedY = rect.height - originY - bounds.height
        context.textPosition = CGPoint(x: originX - bounds.minX, y: flippedY - bounds.minY)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

// MARK: - Asset catalog assembly

struct AssetCatalogWriter {
    let outputDirectory: URL

    func write() throws {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        for slot in IconSlot.all {
            for variant in IconVariant.allCases {
                let renderer = IconRenderer(variant: variant, pixelSize: slot.pixelSize)
                let data = renderer.render()
                let filename = "\(slot.baseFilename)\(variant.filenameSuffix).png"
                let url = outputDirectory.appendingPathComponent(filename)
                try data.write(to: url)
                FileHandle.standardError.write(Data("Rendered \(filename) (\(slot.pixelSize)px)\n".utf8))
            }
        }

        let contentsURL = outputDirectory.appendingPathComponent("Contents.json")
        try contentsJSON().write(to: contentsURL, atomically: true, encoding: .utf8)
        FileHandle.standardError.write(Data("Wrote Contents.json\n".utf8))
    }

    private func contentsJSON() -> String {
        var imageEntries: [String] = []
        for slot in IconSlot.all {
            for variant in IconVariant.allCases {
                let filename = "\(slot.baseFilename)\(variant.filenameSuffix).png"
                var fields: [String] = [
                    "\"filename\" : \"\(filename)\"",
                    "\"idiom\" : \"mac\"",
                    "\"scale\" : \"\(slot.scaleJSON)\"",
                    "\"size\" : \"\(slot.sizeJSON)\"",
                ]
                if let appearances = variant.appearancesJSON {
                    fields.insert("\"appearances\" : \(appearances)", at: 0)
                }
                let entry = "    {\n      " + fields.joined(separator: ",\n      ") + "\n    }"
                imageEntries.append(entry)
            }
        }
        let images = imageEntries.joined(separator: ",\n")
        return """
        {
          "images" : [
        \(images)
          ],
          "info" : {
            "author" : "ChronoframeIconTool",
            "version" : 1
          }
        }

        """
    }
}

// MARK: - Entry point

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    let exe = (arguments.first as NSString?)?.lastPathComponent ?? "ChronoframeIconTool"
    FileHandle.standardError.write(Data("usage: \(exe) <output-appiconset-directory>\n".utf8))
    exit(64)
}

let outputDirectory = URL(fileURLWithPath: arguments[1])
do {
    let writer = AssetCatalogWriter(outputDirectory: outputDirectory)
    try writer.write()
} catch {
    FileHandle.standardError.write(Data("Failed: \(error)\n".utf8))
    exit(1)
}

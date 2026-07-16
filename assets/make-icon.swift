// Generates AppIcon.icns for GW Switch.
// Draws a rounded "squircle" tile with a blue→teal gradient and a white
// swap-arrows glyph (⇄) — the "switch the gateway" motif — plus a small status
// dot echoing the menu-bar indicator.
//
// Usage: swift make-icon.swift [output-dir]   (default: this file's directory)

import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = outDir + "/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px)

    // Rounded-rect tile (macOS squircle ≈ 22.37% corner radius) with slight inset.
    let inset = s * 0.055
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = rect.width * 0.2237
    let tile = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    let colors = [
        NSColor(calibratedRed: 0.16, green: 0.51, blue: 0.96, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.09, green: 0.72, blue: 0.66, alpha: 1).cgColor,
    ] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    ctx.restoreGState()

    // Swap-arrows glyph in white: top arrow points right, bottom arrow points left.
    let lineW = s * 0.052
    let head = s * 0.095
    let left = s * 0.30
    let right = s * 0.70
    let topY = s * 0.585
    let botY = s * 0.415
    ctx.setLineCap(.round)
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.setLineWidth(lineW)

    // Top line + right-pointing head.
    ctx.move(to: CGPoint(x: left, y: topY))
    ctx.addLine(to: CGPoint(x: right, y: topY))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: right + head, y: topY))
    ctx.addLine(to: CGPoint(x: right - head * 0.2, y: topY + head * 0.85))
    ctx.addLine(to: CGPoint(x: right - head * 0.2, y: topY - head * 0.85))
    ctx.closePath()
    ctx.fillPath()

    // Bottom line + left-pointing head.
    ctx.move(to: CGPoint(x: right, y: botY))
    ctx.addLine(to: CGPoint(x: left, y: botY))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: left - head, y: botY))
    ctx.addLine(to: CGPoint(x: left + head * 0.2, y: botY + head * 0.85))
    ctx.addLine(to: CGPoint(x: left + head * 0.2, y: botY - head * 0.85))
    ctx.closePath()
    ctx.fillPath()

    // Small status dot (green) bottom-right, echoing the tray indicator.
    let dotR = s * 0.075
    let dotC = CGPoint(x: s * 0.735, y: s * 0.265)
    ctx.setFillColor(NSColor(calibratedRed: 0.30, green: 0.86, blue: 0.42, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: dotC.x - dotR, y: dotC.y - dotR, width: dotR * 2, height: dotR * 2))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// iconset entries: (pixels, filename)
let entries: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (px, name) in entries {
    try! render(px).write(to: URL(fileURLWithPath: iconset + "/" + name))
}
// Also drop a standalone 512 preview.
try! render(512).write(to: URL(fileURLWithPath: outDir + "/preview.png"))
print("Wrote \(iconset) and preview.png")

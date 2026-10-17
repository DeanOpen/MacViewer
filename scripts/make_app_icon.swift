import AppKit
import Foundation

// Render each icon size from the same vector geometry.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        let cg = context.cgContext
        cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        cg.addPath(CGPath(roundedRect: CGRect(x: 32, y: 32, width: 960, height: 960),
                         cornerWidth: 220, cornerHeight: 220, transform: nil)); cg.clip()
        let colors = [NSColor(red: 0.13, green: 0.63, blue: 1, alpha: 1).cgColor,
                      NSColor(red: 0.01, green: 0.32, blue: 0.94, alpha: 1).cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        cg.drawLinearGradient(gradient, start: CGPoint(x: 350, y: 1024), end: CGPoint(x: 650, y: 0), options: [])
        cg.setStrokeColor(NSColor.white.cgColor); cg.setFillColor(NSColor.white.cgColor)
        cg.setLineWidth(34); cg.setLineJoin(.round)
        cg.addPath(CGPath(roundedRect: CGRect(x: 166, y: 390, width: 615, height: 390),
                         cornerWidth: 28, cornerHeight: 28, transform: nil)); cg.strokePath()
        cg.fill(CGRect(x: 420, y: 302, width: 75, height: 73))
        cg.fill(CGRect(x: 335, y: 280, width: 245, height: 32))
        cg.setFillColor(NSColor(red: 0.08, green: 0.49, blue: 0.97, alpha: 1).cgColor)
        cg.addPath(CGPath(roundedRect: CGRect(x: 497, y: 270, width: 358, height: 260),
                         cornerWidth: 22, cornerHeight: 22, transform: nil)); cg.drawPath(using: .fillStroke)
        cg.setFillColor(NSColor.white.cgColor)
        cg.fill(CGRect(x: 645, y: 220, width: 58, height: 32))
        cg.fill(CGRect(x: 580, y: 197, width: 190, height: 28))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(
            to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}

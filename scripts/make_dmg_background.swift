import AppKit

// Draw the DMG window background: a drag-to-install guide between the app icon
// (left) and the Applications link (right). Writes 1x and 2x PNGs.
let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: make_dmg_background.swift <output-directory>\n".utf8))
    exit(2)
}
let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

// Keep these in sync with the icon positions in make_dmg.sh.
let size = CGSize(width: 660, height: 420)
let appCenter = CGPoint(x: 170, y: 190)
let applicationsCenter = CGPoint(x: 490, y: 190)

func render(scale: CGFloat, to url: URL) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { throw CocoaError(.fileWriteUnknown) }
    bitmap.size = size

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // Finder uses top-left coordinates for icon positions; flip to match.
    let context = NSGraphicsContext.current!.cgContext
    context.translateBy(x: 0, y: size.height)
    context.scaleBy(x: 1, y: -1)
    let flipped = NSGraphicsContext(cgContext: context, flipped: true)
    NSGraphicsContext.current = flipped

    let background = NSGradient(
        starting: NSColor(calibratedRed: 0.97, green: 0.98, blue: 1.0, alpha: 1),
        ending: NSColor(calibratedRed: 0.90, green: 0.93, blue: 0.98, alpha: 1))!
    background.draw(in: CGRect(origin: .zero, size: size), angle: 90)

    func drawCentered(_ text: String, y: CGFloat, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let height = (text as NSString).size(withAttributes: attributes).height
        (text as NSString).draw(in: CGRect(x: 0, y: y, width: size.width, height: height), withAttributes: attributes)
    }

    let ink = NSColor(calibratedRed: 0.11, green: 0.13, blue: 0.18, alpha: 1)
    let muted = NSColor(calibratedRed: 0.36, green: 0.40, blue: 0.48, alpha: 1)
    let accent = NSColor(calibratedRed: 0.16, green: 0.47, blue: 0.96, alpha: 1)

    drawCentered("Kéo MacViewer vào Applications để cài đặt", y: 40,
                 font: .systemFont(ofSize: 20, weight: .semibold), color: ink)
    drawCentered("Drag MacViewer to Applications to install", y: 70,
                 font: .systemFont(ofSize: 14, weight: .regular), color: muted)

    // Dashed arrow between the two icons.
    let arrow = NSBezierPath()
    let startX = appCenter.x + 78, endX = applicationsCenter.x - 78, y = appCenter.y
    arrow.move(to: CGPoint(x: startX, y: y))
    arrow.line(to: CGPoint(x: endX - 14, y: y))
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    arrow.setLineDash([12, 10], count: 2, phase: 0)
    accent.setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: CGPoint(x: endX, y: y))
    head.line(to: CGPoint(x: endX - 22, y: y - 14))
    head.line(to: CGPoint(x: endX - 22, y: y + 14))
    head.close()
    accent.setFill()
    head.fill()

    // Short next-steps guide under the icons.
    let steps = [
        "1. Mở MacViewer từ Applications  ·  Open MacViewer from Applications",
        "2. Kết nối: nhập ID và mật khẩu của đối tác  ·  Connect: enter the partner's ID and password",
        "3. Chia sẻ: cấp quyền Ghi màn hình và Trợ năng  ·  Share: allow Screen Recording and Accessibility",
    ]
    for (index, step) in steps.enumerated() {
        drawCentered(step, y: 320 + CGFloat(index) * 22, font: .systemFont(ofSize: 11.5), color: muted)
    }

    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url)
}

try render(scale: 1, to: outputDirectory.appendingPathComponent("background.png"))
try render(scale: 2, to: outputDirectory.appendingPathComponent("background@2x.png"))
print("DMG background written to \(outputDirectory.path)")

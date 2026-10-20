import CoreGraphics
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit
import UltraViewerProtocol

/// Captured coordinates use a top-left origin and the transmitted image size.
/// CG display bounds use global logical points, independent of Retina backing
/// pixels. AppKit's bottom-left screen coordinates are not used for injection.
struct MacCaptureGeometry: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let width: Int
    let height: Int
    let displayBounds: CGRect
    var displayRegions: [CGRect] = []

    func mapPoint(x: Int32, y: Int32) -> CGPoint {
        let px = min(max(0, Double(x)), Double(max(0, width - 1)))
        let py = min(max(0, Double(y)), Double(max(0, height - 1)))
        return clampGlobalPoint(CGPoint(x: displayBounds.minX + px * displayBounds.width / Double(max(1, width)),
                                        y: displayBounds.minY + py * displayBounds.height / Double(max(1, height))))
    }

    func clampGlobalPoint(_ point: CGPoint) -> CGPoint {
        // Blank space between arranged monitors has no desktop to control.
        let regions = displayRegions.isEmpty ? [displayBounds] : displayRegions
        return regions.map { rect in
            CGPoint(x: min(max(rect.minX, point.x), rect.maxX - 0.001),
                    y: min(max(rect.minY, point.y), rect.maxY - 0.001))
        }.min { lhs, rhs in
            hypot(lhs.x - point.x, lhs.y - point.y) < hypot(rhs.x - point.x, rhs.y - point.y)
        } ?? point
    }
}

enum MacScreenCaptureError: LocalizedError, Equatable {
    case screenRecordingRequired
    case displayUnavailable
    case displayConfigurationChanged
    case invalidFrame
    case cannotRender

    var errorDescription: String? {
        switch self {
        case .screenRecordingRequired: "Allow Screen Recording for MacViewer before sharing this Mac."
        case .displayUnavailable: "The selected Mac display is unavailable for screen sharing."
        case .displayConfigurationChanged: "The Mac display arrangement changed. Try sharing again."
        case .invalidFrame: "The Mac display returned an invalid screen image."
        case .cannotRender: "The Mac screen image could not be converted for UltraViewer."
        }
    }
}

/// Stateless conversion helpers are testable without requesting/capturing a
/// screen. The transport encoder reverses these bottom-up rows into wire order.
enum MacScreenPixels {
    /// Canvas dimensions are bounded by the protocol limit and the host frame
    /// budget; arrangements are no longer forced into a 16:9 box, so a
    /// 5760x1080 desktop (three 1080p displays side by side) is valid.
    static let maximumDimension = HostedScreenMessage.maximumDimension
    static let maximumOutputBytes = HostedScreenMessage.maximumPayloadBytes

    static func validOutputSize(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0,
              width <= maximumDimension, height <= maximumDimension else { return false }
        // Division first keeps the product from overflowing for hostile sizes.
        guard width <= maximumOutputBytes / height else { return false }
        return width * height * 2 <= maximumOutputBytes
    }

    /// Compatibility helper retained for callers that scale a single captured
    /// image to 1080p; the host capture path uses `MacDisplayLayout` budgets.
    static func scaledSize(width: Int, height: Int) throws -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { throw MacScreenCaptureError.invalidFrame }
        let scale = min(1, min(1920 / Double(width), 1080 / Double(height)))
        return (max(1, Int((Double(width) * scale).rounded(.down))),
                max(1, Int((Double(height) * scale).rounded(.down))))
    }

    static func rgb555BottomUp(rgbaTopDown: Data, width: Int, height: Int, bytesPerRow: Int) throws -> Data {
        guard validOutputSize(width: width, height: height),
              bytesPerRow >= width * 4, bytesPerRow <= Int.max / height,
              rgbaTopDown.count >= bytesPerRow * height else { throw MacScreenCaptureError.invalidFrame }
        var result = Data(count: width * height * 2)
        rgbaTopDown.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            result.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
                for y in 0..<height {
                    for x in 0..<width {
                        let input = y * bytesPerRow + x * 4
                        let word = UInt16(source[input] >> 3) << 10
                            | UInt16(source[input + 1] >> 3) << 5 | UInt16(source[input + 2] >> 3)
                        let output = ((height - 1 - y) * width + x) * 2
                        destination[output] = UInt8(truncatingIfNeeded: word)
                        destination[output + 1] = UInt8(word >> 8)
                    }
                }
            }
        }
        return result
    }

    static func rgb555BottomUp(image: CGImage) throws -> Data {
        let width = image.width
        let height = image.height
        guard validOutputSize(width: width, height: height),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw MacScreenCaptureError.invalidFrame }
        var rgba = Data(count: width * height * 4)
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                return false
            }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw MacScreenCaptureError.cannotRender }
        return try rgb555BottomUp(rgbaTopDown: rgba, width: width, height: height, bytesPerRow: width * 4)
    }

    static func composite(images: [CGImage], layout: MacDisplayLayout) throws -> Data {
        guard images.count == layout.surfaces.count,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw MacScreenCaptureError.invalidFrame }
        var rgba = Data(count: layout.width * layout.height * 4)
        try rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: layout.width, height: layout.height,
                bitsPerComponent: 8, bytesPerRow: layout.width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw MacScreenCaptureError.cannotRender
            }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: layout.width, height: layout.height))
            for (surface, image) in zip(layout.surfaces, images) {
                let rect = surface.pixelRect
                guard image.width == Int(rect.width), image.height == Int(rect.height) else {
                    throw MacScreenCaptureError.invalidFrame
                }
                context.draw(image, in: CGRect(x: rect.minX, y: Double(layout.height) - rect.maxY,
                                               width: rect.width, height: rect.height))
            }
        }
        return try rgb555BottomUp(rgbaTopDown: rgba, width: layout.width, height: layout.height, bytesPerRow: layout.width * 4)
    }
}

@MainActor
final class MacScreenCapture {
    private struct PreparedSurface {
        let captureImage: @MainActor () async throws -> CGImage
    }

    private struct PreparedCapture {
        let layout: MacDisplayLayout
        let surfaces: [PreparedSurface]
    }

    private(set) var geometry: MacCaptureGeometry?
    private var preparedCapture: PreparedCapture?
    private var revision = UUID()

    func capture(selection: String = MacDisplayLayout.allDisplaysKey) async throws -> HostedScreenFrame {
        // Calling ScreenCaptureKit without this gate can present a prompt.
        // The host UI requests permission explicitly before starting capture.
        guard CGPreflightScreenCaptureAccess() else { throw MacScreenCaptureError.screenRecordingRequired }
        try Task.checkCancellation()
        let token = revision
        let layout = try MacDisplayLayout(displays: MacSharingDisplay.current(), selection: selection)
        let target = try await prepare(layout, token: token)
        try Task.checkCancellation()
        guard revision == token else { throw CancellationError() }
        var images: [CGImage] = []
        do {
            for surface in target.surfaces {
                try Task.checkCancellation()
                images.append(try await surface.captureImage())
            }
        } catch {
            if revision == token { preparedCapture = nil }
            throw error
        }
        try Task.checkCancellation()
        guard revision == token else { throw CancellationError() }
        let currentLayout = try? MacDisplayLayout(displays: MacSharingDisplay.current(), selection: selection)
        guard layout == currentLayout else {
            preparedCapture = nil
            geometry = nil
            throw MacScreenCaptureError.displayConfigurationChanged
        }
        guard CGPreflightScreenCaptureAccess() else { throw MacScreenCaptureError.screenRecordingRequired }
        let pixels = try MacScreenPixels.composite(images: images, layout: layout)
        geometry = layout.geometry
        return HostedScreenFrame(width: layout.width, height: layout.height,
                                 rgb555BottomUp: pixels, monitors: layout.monitors,
                                 layoutIdentifier: layout.surfaces.map { "\($0.display.key):\($0.display.bounds)" }.joined(separator: ";"))
    }

    func reset() {
        revision = UUID()
        geometry = nil
        preparedCapture = nil
    }

    private func prepare(_ layout: MacDisplayLayout, token: UUID) async throws -> PreparedCapture {
        if let preparedCapture, preparedCapture.layout == layout { return preparedCapture }
        preparedCapture = nil
        let surfaces: [PreparedSurface]
        if #available(macOS 14, *) {
            surfaces = try await screenCaptureKitSurfaces(layout, token: token)
        } else {
            surfaces = layout.surfaces.map { surface in
                let id = surface.display.id
                let size = (Int(surface.pixelRect.width), Int(surface.pixelRect.height))
                return PreparedSurface { try Self.displayImage(id, width: size.0, height: size.1) }
            }
        }
        let result = PreparedCapture(layout: layout, surfaces: surfaces)
        preparedCapture = result
        return result
    }

    @available(macOS 14, *)
    private func screenCaptureKitSurfaces(_ layout: MacDisplayLayout, token: UUID) async throws -> [PreparedSurface] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard revision == token else { throw CancellationError() }
        var surfaces: [PreparedSurface] = []
        for surface in layout.surfaces {
            guard let display = content.displays.first(where: { $0.displayID == surface.display.id }) else {
                throw MacScreenCaptureError.displayConfigurationChanged
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(surface.pixelRect.width)
            config.height = Int(surface.pixelRect.height)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = true
            config.capturesAudio = false
            config.scalesToFit = true
            config.preservesAspectRatio = true
            surfaces.append(PreparedSurface {
                try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            })
        }
        return surfaces
    }

    /// macOS 12-13 have no ScreenCaptureKit screenshot API; CoreGraphics
    /// captures the display, scaled here to the transmitted surface size.
    private static func displayImage(_ id: CGDirectDisplayID, width: Int, height: Int) throws -> CGImage {
        guard let image = CGDisplayCreateImage(id) else { throw MacScreenCaptureError.displayUnavailable }
        if image.width == width, image.height == height { return image }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw MacScreenCaptureError.cannotRender }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { throw MacScreenCaptureError.cannotRender }
        return scaled
    }
}

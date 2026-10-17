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

    func mapPoint(x: Int32, y: Int32) -> CGPoint {
        let px = min(max(0, Double(x)), Double(max(0, width - 1)))
        let py = min(max(0, Double(y)), Double(max(0, height - 1)))
        return CGPoint(x: displayBounds.minX + px * displayBounds.width / Double(max(1, width)),
                       y: displayBounds.minY + py * displayBounds.height / Double(max(1, height)))
    }

    func clampGlobalPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(displayBounds.minX, point.x), displayBounds.maxX - 0.001),
                y: min(max(displayBounds.minY, point.y), displayBounds.maxY - 0.001))
    }
}

enum MacScreenCaptureError: LocalizedError, Equatable {
    case screenRecordingRequired
    case displayUnavailable
    case invalidFrame
    case cannotRender

    var errorDescription: String? {
        switch self {
        case .screenRecordingRequired: "Allow Screen Recording for MacViewer before sharing this Mac."
        case .displayUnavailable: "The main Mac display is unavailable for screen sharing."
        case .invalidFrame: "The Mac display returned an invalid screen image."
        case .cannotRender: "The Mac screen image could not be converted for UltraViewer."
        }
    }
}

/// Stateless conversion helpers are testable without requesting/capturing a
/// screen. The transport encoder reverses these bottom-up rows into wire order.
enum MacScreenPixels {
    static func scaledSize(width: Int, height: Int) throws -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { throw MacScreenCaptureError.invalidFrame }
        let scale = min(1, min(1920 / Double(width), 1080 / Double(height)))
        return (max(1, Int((Double(width) * scale).rounded(.down))),
                max(1, Int((Double(height) * scale).rounded(.down))))
    }

    static func rgb555BottomUp(rgbaTopDown: Data, width: Int, height: Int, bytesPerRow: Int) throws -> Data {
        guard width > 0, height > 0, width <= 1920, height <= 1080,
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
        guard width > 0, height > 0, width <= 1920, height <= 1080,
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
}

@MainActor
final class MacScreenCapture {
    private struct DisplayKey: Equatable {
        let id: CGDirectDisplayID
        let bounds: CGRect
        let pixelsWide: Int
        let pixelsHigh: Int
    }

    private struct PreparedCapture {
        let key: DisplayKey
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
        let width: Int
        let height: Int
    }

    private(set) var geometry: MacCaptureGeometry?
    private var preparedCapture: PreparedCapture?
    private var revision = UUID()

    func capture() async throws -> HostedScreenFrame {
        // Calling ScreenCaptureKit without this gate can present a prompt.
        // The host UI requests permission explicitly before starting capture.
        guard CGPreflightScreenCaptureAccess() else { throw MacScreenCaptureError.screenRecordingRequired }
        try Task.checkCancellation()
        let token = revision
        let key = try currentDisplayKey()
        let target = try await prepare(key, token: token)
        try Task.checkCancellation()
        guard revision == token else { throw CancellationError() }
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: target.filter,
                                                             configuration: target.configuration)
        } catch {
            if revision == token { preparedCapture = nil }
            throw error
        }
        try Task.checkCancellation()
        guard revision == token else { throw CancellationError() }
        guard key == (try currentDisplayKey()) else {
            preparedCapture = nil
            geometry = nil
            throw MacScreenCaptureError.displayUnavailable
        }
        guard CGPreflightScreenCaptureAccess() else { throw MacScreenCaptureError.screenRecordingRequired }
        guard image.width == target.width, image.height == target.height else { throw MacScreenCaptureError.invalidFrame }
        let pixels = try MacScreenPixels.rgb555BottomUp(image: image)
        geometry = MacCaptureGeometry(displayID: key.id, width: target.width, height: target.height,
                                      displayBounds: key.bounds)
        return HostedScreenFrame(width: target.width, height: target.height, rgb555BottomUp: pixels)
    }

    func reset() {
        revision = UUID()
        geometry = nil
        preparedCapture = nil
    }

    private func currentDisplayKey() throws -> DisplayKey {
        let id = CGMainDisplayID()
        let bounds = CGDisplayBounds(id)
        guard bounds.width > 0, bounds.height > 0, !bounds.isInfinite, !bounds.isNull,
              bounds.width.isFinite, bounds.height.isFinite else { throw MacScreenCaptureError.displayUnavailable }
        return DisplayKey(id: id, bounds: bounds, pixelsWide: CGDisplayPixelsWide(id), pixelsHigh: CGDisplayPixelsHigh(id))
    }

    private func prepare(_ key: DisplayKey, token: UUID) async throws -> PreparedCapture {
        if let preparedCapture, preparedCapture.key == key { return preparedCapture }
        preparedCapture = nil
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard revision == token else { throw CancellationError() }
        guard key == (try currentDisplayKey()),
              let display = content.displays.first(where: { $0.displayID == key.id }) else {
            throw MacScreenCaptureError.displayUnavailable
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let pixelScale = Double(filter.pointPixelScale)
        guard pixelScale.isFinite, pixelScale > 0,
              filter.contentRect.width.isFinite, filter.contentRect.height.isFinite else {
            throw MacScreenCaptureError.invalidFrame
        }
        let size = try MacScreenPixels.scaledSize(
            width: Int((Double(filter.contentRect.width) * pixelScale).rounded()),
            height: Int((Double(filter.contentRect.height) * pixelScale).rounded()))
        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.capturesAudio = false
        config.scalesToFit = true
        config.preservesAspectRatio = true
        let result = PreparedCapture(key: key, filter: filter, configuration: config, width: size.width, height: size.height)
        preparedCapture = result
        return result
    }
}

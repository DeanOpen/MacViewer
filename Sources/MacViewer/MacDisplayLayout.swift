import AppKit
import CoreGraphics
import UltraViewerProtocol

struct MacSharingDisplay: Equatable, Sendable, Identifiable {
    let id: CGDirectDisplayID
    let key: String
    let name: String
    let bounds: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
    let isMain: Bool

    /// True backing-pixel size for a display's point bounds. `CGDisplayPixelsWide`
    /// reports the current mode's width in points for Retina modes, so the
    /// backing scale from `NSScreen` is the reliable source. A missing scale is
    /// treated as 1 so a display can never be captured above its logical size.
    static func pixelSize(bounds: CGRect, backingScale: CGFloat) -> (width: Int, height: Int) {
        let scale = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        return (max(1, Int((bounds.width * scale).rounded())),
                max(1, Int((bounds.height * scale).rounded())))
    }

    @MainActor static func current() -> [Self] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 64)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        // AppKit owns the localized name and the true backing scale; both are keyed
        // by NSScreenNumber, which is the same display ID CoreGraphics returns.
        var names: [CGDirectDisplayID: String] = [:]
        var backingScales: [CGDirectDisplayID: CGFloat] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            names[number.uint32Value] = screen.localizedName
            backingScales[number.uint32Value] = screen.backingScaleFactor
        }
        return ids.prefix(Int(count)).compactMap { id in
            // Mirrored outputs have the same desktop. Advertise their source once.
            guard CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
            let bounds = CGDisplayBounds(id)
            guard valid(bounds) else { return nil }
            // Prefer AppKit's backing scale; fall back to the current display mode,
            // then to CoreGraphics' point-sized mode value for an unknown display.
            let pixel: (width: Int, height: Int)
            if let backingScale = backingScales[id] {
                pixel = Self.pixelSize(bounds: bounds, backingScale: backingScale)
            } else if let mode = CGDisplayCopyDisplayMode(id), mode.pixelWidth > 0, mode.pixelHeight > 0 {
                pixel = (mode.pixelWidth, mode.pixelHeight)
            } else {
                pixel = (CGDisplayPixelsWide(id), CGDisplayPixelsHigh(id))
            }
            return Self(id: id, key: CFUUIDCreateString(nil, uuid) as String,
                        name: names[id] ?? L("Display"), bounds: bounds,
                        pixelWidth: pixel.width, pixelHeight: pixel.height,
                        isMain: id == CGMainDisplayID())
        }.sorted {
            if $0.isMain != $1.isMain { return $0.isMain }
            if $0.bounds.minX != $1.bounds.minX { return $0.bounds.minX < $1.bounds.minX }
            if $0.bounds.minY != $1.bounds.minY { return $0.bounds.minY < $1.bounds.minY }
            return $0.key < $1.key
        }
    }

    static func valid(_ bounds: CGRect) -> Bool {
        !bounds.isNull && !bounds.isInfinite && bounds.width > 0 && bounds.height > 0
            && [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY].allSatisfy { $0.isFinite && abs($0) <= 1_000_000 }
    }
}

/// One uniform scale preserves the desktop arrangement across mixed Retina and
/// standard displays. Monitor edges are rounded once and reused for capture,
/// composition and UltraViewer's local monitor crop menu.
///
/// UltraViewer transmits the arranged desktop as one RGB555 frame, so the canvas
/// is limited by a total pixel budget instead of a fixed 16:9 shape: the relay
/// bandwidth ceilings stay the same (1920x1080 for one display, 3840x2160 for
/// the arranged desktop) but any arrangement may use its whole budget. Capture
/// never upscales a display above its logical point resolution; capturing Retina
/// displays at 2x device pixels is a possible future bandwidth opt-in, not the
/// default, because it would quadruple the transmitted pixel count.
struct MacDisplayLayout: Equatable, Sendable {
    static let allDisplaysKey = "all"
    /// Shape-agnostic replacements for the old 1920x1080 and 3840x2160 boxes.
    static let singleDisplayPixelBudget = 2_073_600
    static let multipleDisplayPixelBudget = 8_294_400

    struct Surface: Equatable, Sendable {
        let display: MacSharingDisplay
        let pixelRect: CGRect
    }
    let surfaces: [Surface]
    let bounds: CGRect
    let width: Int
    let height: Int

    init(displays: [MacSharingDisplay], selection: String) throws {
        let selected = selection == Self.allDisplaysKey ? displays : displays.filter { $0.key == selection }
        guard !selected.isEmpty, selected.count <= 64,
              selected.allSatisfy({ MacSharingDisplay.valid($0.bounds) && $0.pixelWidth > 0 && $0.pixelHeight > 0 }) else {
            throw MacScreenCaptureError.displayUnavailable
        }
        let bounds = selected.dropFirst().reduce(selected[0].bounds) { $0.union($1.bounds) }
        let area = Double(bounds.width) * Double(bounds.height)
        let budget = Double(selected.count > 1 ? Self.multipleDisplayPixelBudget : Self.singleDisplayPixelBudget)
        let dimensionLimit = Double(HostedScreenMessage.maximumDimension)
        // Explicit Double steps keep older compilers from timing out on the inference.
        let scale = min(1, (budget / area).squareRoot(),
                        dimensionLimit / Double(bounds.width), dimensionLimit / Double(bounds.height))
        let width = max(1, Int((bounds.width * scale).rounded(.down)))
        let height = max(1, Int((bounds.height * scale).rounded(.down)))
        guard width <= HostedScreenMessage.maximumDimension, height <= HostedScreenMessage.maximumDimension,
              width * height * 2 <= HostedScreenMessage.maximumPayloadBytes else {
            throw MacScreenCaptureError.invalidFrame
        }
        func pixel(_ point: CGFloat, from origin: CGFloat, over length: CGFloat, pixels: Int) -> Int {
            let fraction: Double = Double(point - origin) / Double(length)
            return Int((fraction * Double(pixels)).rounded())
        }
        let surfaces = try selected.map { display -> Surface in
            let left = pixel(display.bounds.minX, from: bounds.minX, over: bounds.width, pixels: width)
            let top = pixel(display.bounds.minY, from: bounds.minY, over: bounds.height, pixels: height)
            let right = pixel(display.bounds.maxX, from: bounds.minX, over: bounds.width, pixels: width)
            let bottom = pixel(display.bounds.maxY, from: bounds.minY, over: bounds.height, pixels: height)
            guard left >= 0, top >= 0, right > left, bottom > top, right <= width, bottom <= height else {
                throw MacScreenCaptureError.invalidFrame
            }
            return Surface(display: display, pixelRect: CGRect(x: left, y: top, width: right - left, height: bottom - top))
        }
        self.surfaces = surfaces; self.bounds = bounds; self.width = width; self.height = height
    }

    var monitors: [HostedScreenMonitor] {
        surfaces.map { .init(left: Int32($0.pixelRect.minX), top: Int32($0.pixelRect.minY),
                             right: Int32($0.pixelRect.maxX), bottom: Int32($0.pixelRect.maxY)) }
    }

    var geometry: MacCaptureGeometry {
        MacCaptureGeometry(displayID: surfaces[0].display.id, width: width, height: height,
                           displayBounds: bounds, displayRegions: surfaces.map(\.display.bounds))
    }
}

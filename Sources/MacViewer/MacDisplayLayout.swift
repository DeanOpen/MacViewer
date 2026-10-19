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

    @MainActor static func current() -> [Self] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 64)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        let names = Dictionary(NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, String)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (number.uint32Value, screen.localizedName)
        }, uniquingKeysWith: { first, _ in first })
        return ids.prefix(Int(count)).compactMap { id in
            // Mirrored outputs have the same desktop. Advertise their source once.
            guard CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
            let bounds = CGDisplayBounds(id)
            guard valid(bounds) else { return nil }
            return Self(id: id, key: CFUUIDCreateString(nil, uuid) as String,
                        name: names[id] ?? L("Display"), bounds: bounds,
                        pixelWidth: CGDisplayPixelsWide(id), pixelHeight: CGDisplayPixelsHigh(id),
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
struct MacDisplayLayout: Equatable, Sendable {
    static let allDisplaysKey = "all"
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
        let backingScale = selected.map {
            max(Double($0.pixelWidth) / $0.bounds.width, Double($0.pixelHeight) / $0.bounds.height)
        }.max() ?? 1
        let maxWidth = selected.count > 1 ? 3840.0 : 1920.0
        let maxHeight = selected.count > 1 ? 2160.0 : 1080.0
        let scale = min(backingScale, min(maxWidth / bounds.width, maxHeight / bounds.height))
        let width = max(1, Int((bounds.width * scale).rounded(.down)))
        let height = max(1, Int((bounds.height * scale).rounded(.down)))
        let surfaces = try selected.map { display -> Surface in
            let left = Int(((display.bounds.minX - bounds.minX) / bounds.width * Double(width)).rounded())
            let top = Int(((display.bounds.minY - bounds.minY) / bounds.height * Double(height)).rounded())
            let right = Int(((display.bounds.maxX - bounds.minX) / bounds.width * Double(width)).rounded())
            let bottom = Int(((display.bounds.maxY - bounds.minY) / bounds.height * Double(height)).rounded())
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

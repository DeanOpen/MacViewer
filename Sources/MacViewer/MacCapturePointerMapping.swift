import CoreGraphics

/// Stateful pointer mapping across the arranged displays of one captured
/// canvas. Kept as an extension in a separate file so `MacCaptureGeometry`'s
/// existing `mapPoint`/`clampGlobalPoint` semantics stay untouched for every
/// other caller.
extension MacCaptureGeometry {
    /// The injected global point and the display region it was clamped into.
    struct PointerMapping: Equatable {
        let point: CGPoint
        let regionIndex: Int
    }

    /// Maps one transmitted canvas pixel to a global display point while
    /// remembering which display produced it.
    ///
    /// A blank canvas pixel (the black gap between arranged displays) has no
    /// desktop to control. Instead of the stateless nearest-display projection
    /// of `clampGlobalPoint`, a gap pixel stays clamped to `preferredRegionIndex`
    /// (the region the pointer came from), so walking from one display into a
    /// gap cannot teleport the injected pointer across the desktop. The
    /// preferred region is replaced as soon as the pixel lands inside a display.
    func mapPointer(x: Int32, y: Int32, preferredRegionIndex: Int?) -> PointerMapping {
        let regions = displayRegions.isEmpty ? [displayBounds] : displayRegions
        let global = Self.unclampedGlobalPoint(x: x, y: y, width: width, height: height,
                                               displayBounds: displayBounds)
        let containing = regions.indices.filter { Self.contains(regions[$0], global) }
        if let preferredRegionIndex, containing.contains(preferredRegionIndex) {
            return PointerMapping(point: global, regionIndex: preferredRegionIndex)
        }
        if let first = containing.first {
            return PointerMapping(point: global, regionIndex: first)
        }
        if let preferredRegionIndex, regions.indices.contains(preferredRegionIndex) {
            return PointerMapping(point: Self.clampedPoint(global, into: regions[preferredRegionIndex]),
                                  regionIndex: preferredRegionIndex)
        }
        let nearest = Self.nearestRegion(global, in: regions)
        return PointerMapping(point: nearest.point, regionIndex: nearest.index)
    }

    /// The unclamped formula shared by `mapPoint`: one canvas pixel is one
    /// proportional step inside the captured desktop bounds.
    private static func unclampedGlobalPoint(x: Int32, y: Int32, width: Int, height: Int,
                                             displayBounds: CGRect) -> CGPoint {
        let px = min(max(0, Double(x)), Double(max(0, width - 1)))
        let py = min(max(0, Double(y)), Double(max(0, height - 1)))
        return CGPoint(x: displayBounds.minX + px * displayBounds.width / Double(max(1, width)),
                       y: displayBounds.minY + py * displayBounds.height / Double(max(1, height)))
    }

    /// Same inclusive test as the existing nearest-region clamp; a seam point
    /// counts for both neighbouring displays and returns the raw point.
    private static func contains(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }

    private static func clampedPoint(_ point: CGPoint, into rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(rect.minX, point.x), rect.maxX - 0.001),
                y: min(max(rect.minY, point.y), rect.maxY - 0.001))
    }

    /// Mirrors `clampGlobalPoint` (including its first-region tie break and
    /// `maxX/maxY - 0.001` inset) while also reporting the chosen region.
    private static func nearestRegion(_ point: CGPoint, in regions: [CGRect]) -> (point: CGPoint, index: Int) {
        var best = clampedPoint(point, into: regions[0])
        var bestIndex = 0
        var bestDistance = hypot(best.x - point.x, best.y - point.y)
        for index in regions.indices.dropFirst() {
            let candidate = clampedPoint(point, into: regions[index])
            let distance = hypot(candidate.x - point.x, candidate.y - point.y)
            if distance < bestDistance {
                best = candidate
                bestIndex = index
                bestDistance = distance
            }
        }
        return (best, bestIndex)
    }
}

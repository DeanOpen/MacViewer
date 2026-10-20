import CoreGraphics
import Testing
@testable import MacViewer

/// Pure mapping tests for the arranged-display pointer helper. No AppKit UI
/// state, no accessibility permission and no real display hardware required.
struct MacPointerMappingTests {
    private func geometry(width: Int, height: Int, bounds: CGRect,
                          _ regions: [CGRect]) -> MacCaptureGeometry {
        MacCaptureGeometry(displayID: 1, width: width, height: height,
                           displayBounds: bounds, displayRegions: regions)
    }

    private func step(_ geometry: MacCaptureGeometry) -> (x: Double, y: Double) {
        (Double(geometry.displayBounds.width) / Double(geometry.width),
         Double(geometry.displayBounds.height) / Double(geometry.height))
    }

    /// The shared `mapPoint` formula, independent of any clamping.
    private func rawPoint(_ geometry: MacCaptureGeometry, x: Int32, y: Int32) -> CGPoint {
        let px = min(max(0, Double(x)), Double(max(0, geometry.width - 1)))
        let py = min(max(0, Double(y)), Double(max(0, geometry.height - 1)))
        return CGPoint(x: geometry.displayBounds.minX + px * geometry.displayBounds.width / Double(max(1, geometry.width)),
                       y: geometry.displayBounds.minY + py * geometry.displayBounds.height / Double(max(1, geometry.height)))
    }

    private func regionIndex(_ geometry: MacCaptureGeometry, containing point: CGPoint) -> Int? {
        let regions = geometry.displayRegions.isEmpty ? [geometry.displayBounds] : geometry.displayRegions
        return regions.indices.first {
            point.x >= regions[$0].minX && point.x <= regions[$0].maxX
                && point.y >= regions[$0].minY && point.y <= regions[$0].maxY
        }
    }

    private func contains(_ geometry: MacCaptureGeometry, _ index: Int, _ point: CGPoint) -> Bool {
        let regions = geometry.displayRegions.isEmpty ? [geometry.displayBounds] : geometry.displayRegions
        guard regions.indices.contains(index) else { return false }
        let rect = regions[index]
        return point.x >= rect.minX - 0.002 && point.x <= rect.maxX + 0.002
            && point.y >= rect.minY - 0.002 && point.y <= rect.maxY + 0.002
    }

    // MARK: - Fixtures (the numeric arrangements from the coordinate audit)

    /// Retina 1728×1117 logical (2x) at (0,0) and a 1920×1080 1x display at
    /// (1728,200): a real Retina+standard side-by-side arrangement with a black
    /// step gap above the right display. Union 3648×1280, canvas 3840×1347.
    private var mixedRetinaAndStandard: MacCaptureGeometry {
        geometry(width: 3840, height: 1347, bounds: CGRect(x: 0, y: 0, width: 3648, height: 1280),
                 [CGRect(x: 0, y: 0, width: 1728, height: 1117),
                  CGRect(x: 1728, y: 200, width: 1920, height: 1080)])
    }

    /// Vertical stack with a negative y origin, like this Mac's built-in display
    /// plus the display arranged above it. Regions: main (0), above (1).
    private var verticalStackWithNegativeY: MacCaptureGeometry {
        geometry(width: 1887, height: 2160, bounds: CGRect(x: -124, y: -1080, width: 1920, height: 2197),
                 [CGRect(x: 0, y: 0, width: 1728, height: 1117),
                  CGRect(x: -124, y: -1080, width: 1920, height: 1080)])
    }

    /// Main (0), display above it with negative y (1), portrait display on the
    /// right (2): the three-display L-shape used for the gap jump measurement.
    private var threeDisplayLShape: MacCaptureGeometry {
        geometry(width: 2160, height: 2160, bounds: CGRect(x: 0, y: -1080, width: 3000, height: 3000),
                 [CGRect(x: 0, y: 0, width: 1920, height: 1080),
                  CGRect(x: 0, y: -1080, width: 1920, height: 1080),
                  CGRect(x: 1920, y: 0, width: 1080, height: 1920)])
    }

    /// Single scaled Retina display: 1670×1080 canvas over a 1728×1117 desktop.
    private var singleDisplay: MacCaptureGeometry {
        geometry(width: 1670, height: 1080, bounds: CGRect(x: -1728, y: -100, width: 1728, height: 1117),
                 [CGRect(x: -1728, y: -100, width: 1728, height: 1117)])
    }

    private var allFixtures: [(String, MacCaptureGeometry)] {
        [("mixedRetinaAndStandard", mixedRetinaAndStandard),
         ("verticalStackWithNegativeY", verticalStackWithNegativeY),
         ("threeDisplayLShape", threeDisplayLShape),
         ("singleDisplay", singleDisplay)]
    }

    // MARK: - Gap behaviour

    @Test("Crossing the black gap keeps the source display instead of teleporting")
    func gapKeepsPreferredDisplay() {
        let screen = mixedRetinaAndStandard
        let scale = step(screen)
        var previous = screen.mapPointer(x: 1810, y: 100, preferredRegionIndex: nil)
        #expect(previous.regionIndex == 0)
        #expect(abs(previous.point.x - 1719.5) < 0.01)
        for x in Int32(1811)...Int32(1829) {
            let next = screen.mapPointer(x: x, y: 100, preferredRegionIndex: previous.regionIndex)
            #expect(next.regionIndex == 0, "gap pixel at x=\(x) must stay on the source display")
            #expect(abs(next.point.x - previous.point.x) <= scale.x + 0.01,
                    "1-px step at x=\(x) jumped \(next.point.x - previous.point.x) pt horizontally")
            #expect(abs(next.point.y - previous.point.y) <= scale.y + 0.01)
            #expect(next.point.x <= 1728 + 0.002)
            previous = next
        }
        // The source display's right edge is where the pointer parks.
        #expect(abs(previous.point.x - 1727.999) < 0.01)
        #expect(abs(previous.point.y - 95.026) < 0.01)

        // Without a preferred region the legacy nearest-display projection is
        // unchanged: this is the teleport the stateful helper removes.
        let legacy = screen.mapPointer(x: 1930, y: 100, preferredRegionIndex: nil)
        #expect(legacy.regionIndex == 1)
        #expect(abs(legacy.point.x - 1833.5) < 0.01)
        #expect(abs(legacy.point.y - 200.0) < 0.01)
    }

    @Test("Gap in the three-display L-shape keeps the region, then re-enters the display under the pointer")
    func lShapeGapThenReentry() {
        let screen = threeDisplayLShape
        var mapping = screen.mapPointer(x: 1300, y: 400, preferredRegionIndex: nil)
        #expect(mapping.regionIndex == 1)
        #expect(abs(mapping.point.x - 1805.556) < 0.01)
        #expect(abs(mapping.point.y - -524.444) < 0.01)
        for x in Int32(1301)...Int32(1400) {
            mapping = screen.mapPointer(x: x, y: 400, preferredRegionIndex: mapping.regionIndex)
            #expect(mapping.regionIndex == 1, "gap pixel at x=\(x) must not switch display")
            #expect(mapping.point.x <= 1920 + 0.002)
            #expect(mapping.point.y <= 0 + 0.002)
        }
        #expect(abs(mapping.point.x - 1919.999) < 0.01)

        // Moving down re-enters the portrait display on the right; the region
        // switches to it and the raw point is used again.
        var entering = screen.mapPointer(x: 1400, y: 777, preferredRegionIndex: 1)
        #expect(entering.regionIndex == 1)
        entering = screen.mapPointer(x: 1400, y: 778, preferredRegionIndex: entering.regionIndex)
        #expect(entering.regionIndex == 2)
        #expect(abs(entering.point.x - 1944.444) < 0.01)
        #expect(abs(entering.point.y - 0.556) < 0.01)
    }

    @Test("Negative-y stack parks gap pixels on the display the pointer came from")
    func negativeYStackGap() {
        let screen = verticalStackWithNegativeY
        let topLeft = screen.mapPointer(x: 0, y: 0, preferredRegionIndex: nil)
        #expect(topLeft.regionIndex == 1)
        #expect(topLeft.point == CGPoint(x: -124, y: -1080))

        // Gap left of the main display: preferred keeps it on the above display.
        let preferred = screen.mapPointer(x: 50, y: 1500, preferredRegionIndex: 1)
        #expect(preferred.regionIndex == 1)
        #expect(abs(preferred.point.x - -73.125) < 0.01)
        #expect(abs(preferred.point.y - -0.001) < 0.01)
        #expect(contains(screen, preferred.regionIndex, preferred.point))

        // No preference falls back to the nearest display (unchanged legacy).
        let fallback = screen.mapPointer(x: 50, y: 1500, preferredRegionIndex: nil)
        #expect(fallback.regionIndex == 0)
        #expect(abs(fallback.point.x - 0) < 0.01)
        #expect(abs(fallback.point.y - 445.694) < 0.01)
    }

    // MARK: - Continuity and fallback properties

    @Test("One-canvas-pixel steps inside displays and inside a gap stay continuous")
    func continuityWithinDisplaysAndGaps() {
        for (name, screen) in allFixtures {
            let scale = step(screen)
            let rows = [Int32(0), Int32(screen.height / 3), Int32(2 * screen.height / 3), Int32(screen.height - 1)]
            var violations: [String] = []
            for y in rows {
                var preferred: Int?
                var previousPoint: CGPoint?
                var previousRawInside: Int?
                for x in 0..<screen.width {
                    let raw = rawPoint(screen, x: Int32(x), y: y)
                    let rawInside = regionIndex(screen, containing: raw)
                    let mapping = screen.mapPointer(x: Int32(x), y: y, preferredRegionIndex: preferred)
                    preferred = mapping.regionIndex
                    if let rawInside {
                        if abs(mapping.point.x - raw.x) > 1e-9 || abs(mapping.point.y - raw.y) > 1e-9 {
                            violations.append("\(name) x=\(x) y=\(y) inside display \(rawInside) but mapped \(mapping.point) != raw \(raw)")
                        }
                    }
                    if let previousPoint {
                        let dx = abs(mapping.point.x - previousPoint.x)
                        let dy = abs(mapping.point.y - previousPoint.y)
                        if previousRawInside != nil || rawInside == nil {
                            if dx > scale.x + 0.01 || dy > scale.y + 0.01 {
                                violations.append("\(name) x=\(x) y=\(y) jumped (\(dx), \(dy)) > step (\(scale.x), \(scale.y))")
                            }
                        }
                    }
                    previousPoint = mapping.point
                    previousRawInside = rawInside
                }
            }
            #expect(violations.isEmpty, "\(violations.prefix(5))")
        }
    }

    @Test("Without a preferred region mapPointer is exactly the existing mapPoint behaviour")
    func fallbackMatchesMapPointAndClampsIntoADisplay() {
        for (name, screen) in allFixtures {
            var mismatches: [String] = []
            var outside: [String] = []
            for y in stride(from: 0, through: screen.height - 1, by: 47) {
                for x in stride(from: 0, through: screen.width - 1, by: 53) {
                    let mapping = screen.mapPointer(x: Int32(x), y: Int32(y), preferredRegionIndex: nil)
                    let legacy = screen.mapPoint(x: Int32(x), y: Int32(y))
                    if abs(mapping.point.x - legacy.x) > 1e-9 || abs(mapping.point.y - legacy.y) > 1e-9 {
                        mismatches.append("\(name) (\(x),\(y)): \(mapping.point) != \(legacy)")
                    }
                    if !contains(screen, mapping.regionIndex, mapping.point) {
                        outside.append("\(name) (\(x),\(y)): \(mapping.point) not in region \(mapping.regionIndex)")
                    }
                    // An out-of-range preference behaves like no preference.
                    let invalid = screen.mapPointer(x: Int32(x), y: Int32(y), preferredRegionIndex: 99)
                    if invalid != mapping {
                        mismatches.append("\(name) (\(x),\(y)): invalid preference changed mapping")
                    }
                }
            }
            #expect(mismatches.isEmpty, "\(mismatches.prefix(5))")
            #expect(outside.isEmpty, "\(outside.prefix(5))")
        }
    }

    @Test("Single display maps every canvas pixel to its proportional desktop point")
    func singleDisplayMapping() {
        let screen = singleDisplay
        #expect(screen.mapPointer(x: 0, y: 0, preferredRegionIndex: nil) == .init(point: CGPoint(x: -1728, y: -100), regionIndex: 0))
        for y in [Int32(0), 540, 1079] {
            for x in stride(from: 0, through: 1669, by: 37) {
                let mapping = screen.mapPointer(x: Int32(x), y: y, preferredRegionIndex: 0)
                #expect(mapping.regionIndex == 0)
                #expect(contains(screen, 0, mapping.point))
            }
        }
        let last = screen.mapPointer(x: 1669, y: 1079, preferredRegionIndex: nil)
        #expect(last.point.x >= -1728 && last.point.x < 0)
        #expect(last.point.y > -100 && last.point.y < 1017)
    }
}

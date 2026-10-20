import Foundation

/// One canvas rectangle in transmitted top-down pixels: the coordinate space of
/// `HostedScreenMessage.frame` part 1 and UltraViewer's single main rectangle.
public struct HostedScreenRegion: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    /// True when this region is the entire transmitted canvas.
    public let isFull: Bool

    public init(x: Int, y: Int, width: Int, height: Int, isFull: Bool = false) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.isFull = isFull
    }

    public var area: Int { width * height }

    public static func full(width: Int, height: Int) -> HostedScreenRegion {
        HostedScreenRegion(x: 0, y: 0, width: width, height: height, isFull: true)
    }
}

/// Pure dirty-region detection for one captured canvas. The host may transmit
/// only the changed rectangle instead of the whole screen; the receiver draws a
/// single main rectangle at part 1's coordinate. Bounding box is tile aligned so
/// small edits still cost a predictable rectangle, and any broad or structural
/// change falls back to the full frame.
public enum HostedScreenFrameDiff {
    public static let defaultTileSize = 32
    /// Safety cap: never build a region larger than this canvas would allow.
    public static let defaultFullFrameThreshold = 0.5

    /// Returns nil when the frames are pixel-identical, a full-canvas region when
    /// the layout changed or dirty tiles cover at least `fullFrameThreshold`, and
    /// otherwise the tile-aligned bounding box of the dirty pixels.
    public static func changedRegion(previous: HostedScreenFrame, current: HostedScreenFrame,
                                     tileSize: Int = defaultTileSize,
                                     fullFrameThreshold: Double = defaultFullFrameThreshold) -> HostedScreenRegion? {
        guard previous.hasSameLayout(as: current) else {
            return .full(width: current.width, height: current.height)
        }
        let width = current.width
        let height = current.height
        let bytesPerRow = width * 2
        guard width > 0, height > 0,
              previous.rgb555BottomUp.count == bytesPerRow * height,
              current.rgb555BottomUp.count == bytesPerRow * height else {
            return .full(width: max(1, width), height: max(1, height))
        }
        if previous.rgb555BottomUp == current.rgb555BottomUp { return nil }
        let tile = max(1, tileSize)
        let tilesX = (width + tile - 1) / tile
        let tilesY = (height + tile - 1) / tile
        // Source rows are bottom-up; a transmitted top-down row y lives at
        // bottom-up row (height - 1 - y).
        let bounds: (minX: Int, maxX: Int, minY: Int, maxY: Int)? =
            previous.rgb555BottomUp.withUnsafeBytes { previousRaw -> (Int, Int, Int, Int)? in
                current.rgb555BottomUp.withUnsafeBytes { currentRaw -> (Int, Int, Int, Int)? in
                    guard let previousBase = previousRaw.baseAddress,
                          let currentBase = currentRaw.baseAddress else { return nil }
                    var minX = tilesX, maxX = -1, minY = tilesY, maxY = -1
                    for tileY in 0..<tilesY {
                        let firstRow = tileY * tile
                        let lastRow = min(height, firstRow + tile)
                        for tileX in 0..<tilesX {
                            let firstColumn = tileX * tile
                            let lastColumn = min(width, firstColumn + tile)
                            let columnOffset = firstColumn * 2
                            let columnBytes = (lastColumn - firstColumn) * 2
                            var dirty = false
                            for y in firstRow..<lastRow {
                                let rowOffset = (height - 1 - y) * bytesPerRow
                                if memcmp(previousBase + rowOffset + columnOffset,
                                          currentBase + rowOffset + columnOffset,
                                          columnBytes) != 0 {
                                    dirty = true
                                    break
                                }
                            }
                            if dirty {
                                minX = min(minX, tileX); maxX = max(maxX, tileX)
                                minY = min(minY, tileY); maxY = max(maxY, tileY)
                            }
                        }
                    }
                    guard maxX >= minX, maxY >= minY else { return nil }
                    return (minX, maxX, minY, maxY)
                }
            }
        guard let bounds else { return nil }
        let x = bounds.minX * tile
        let y = bounds.minY * tile
        let right = min(width, (bounds.maxX + 1) * tile)
        let bottom = min(height, (bounds.maxY + 1) * tile)
        let region = HostedScreenRegion(x: x, y: y, width: max(1, right - x),
                                        height: max(1, bottom - y))
        let canvasArea = max(1, width * height)
        let coverage = Double(region.area) / Double(canvasArea)
        let threshold = min(1, max(0, fullFrameThreshold))
        if coverage >= threshold {
            return .full(width: width, height: height)
        }
        return region
    }
}

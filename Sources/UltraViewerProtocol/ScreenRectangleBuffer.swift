import Foundation

/// Raw row-copy operation recovered from uvc.dll ordinal 24 (VA 0x100016b0).
/// This is a drawing primitive after decompression, not a screen-message decoder.
/// Pixel channels are opaque: this type does not assume RGB/BGR/alpha ordering.
public struct ScreenRectangleBuffer: Equatable, Sendable {
    public enum Error: Swift.Error, Equatable {
        case invalidGeometry
        case invalidStride
        case invalidDestinationLength
        case truncatedSource
        case sizeOverflow
    }

    public let width: Int
    public let height: Int
    public let bytesPerPixel: Int
    public let rowStride: Int
    /// Destination rows are stored bottom-up, including caller-supplied row padding.
    public private(set) var pixels: Data

    /// Geometry/length checks are local validation policies, not recovered wire limits.
    public init(width: Int, height: Int, bytesPerPixel: Int, rowStride: Int, pixels: Data) throws {
        guard width > 0, height > 0, bytesPerPixel > 0 else { throw Error.invalidGeometry }
        let minimumStride = try Self.product(width, bytesPerPixel)
        guard rowStride >= minimumStride else { throw Error.invalidStride }
        let size = try Self.product(height, rowStride)
        guard pixels.count == size else { throw Error.invalidDestinationLength }
        self.width = width
        self.height = height
        self.bytesPerPixel = bytesPerPixel
        self.rowStride = rowStride
        self.pixels = pixels
    }

    /// Copies a tightly packed, top-down source rectangle at top-left coordinates.
    /// Clips against destination bounds and preserves all untouched bytes/padding.
    /// Additional bytes following the source rectangle are not read.
    public mutating func copyRectangle(
        _ source: Data,
        width sourceWidth: Int,
        height sourceHeight: Int,
        atX x: Int,
        atY y: Int
    ) throws {
        guard sourceWidth > 0, sourceHeight > 0 else { throw Error.invalidGeometry }
        let sourceStride = try Self.product(sourceWidth, bytesPerPixel)
        let requiredSourceBytes = try Self.product(sourceStride, sourceHeight)
        guard source.count >= requiredSourceBytes else { throw Error.truncatedSource }

        // Compare before negating coordinates or adding extents to avoid overflow.
        guard x < width, y < height, x > -sourceWidth, y > -sourceHeight else { return }
        let sourceX = x < 0 ? -x : 0
        let sourceY = y < 0 ? -y : 0
        let destinationX = max(0, x)
        let destinationY = max(0, y)
        let copyWidth = min(sourceWidth - sourceX, width - destinationX)
        let copyHeight = min(sourceHeight - sourceY, height - destinationY)
        let copyBytes = copyWidth * bytesPerPixel

        for row in 0..<copyHeight {
            let sourceOffset = (sourceY + row) * sourceStride + sourceX * bytesPerPixel
            let destinationOffset = (height - 1 - (destinationY + row)) * rowStride + destinationX * bytesPerPixel
            let sourceStart = source.startIndex + sourceOffset
            let destinationStart = pixels.startIndex + destinationOffset
            pixels.replaceSubrange(
                destinationStart..<(destinationStart + copyBytes),
                with: source[sourceStart..<(sourceStart + copyBytes)]
            )
        }
    }

    private static func product(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw Error.sizeOverflow }
        return value
    }
}

import CoreGraphics
import Foundation
import OSLog
import ImageIO

/// A completed software-rendered frame. The BGR24 compatibility view is top-down
/// and tightly packed. Renderer frames retain native BGRA pixels for display.
public struct ModernScreenBitmap: Equatable, Sendable {
    public let width: Int
    public let height: Int
    private let pixels: Data
    private let isBGRA: Bool
    public var bgrPixels: Data {
        isBGRA ? ScreenPixelStorage.bgr24(fromBGRA: pixels, width: width, height: height) : pixels
    }
    public var rowStride: Int { width * 3 }

    init(width: Int, height: Int, bgrPixels: Data) {
        self.width = width
        self.height = height
        self.pixels = bgrPixels
        self.isBGRA = false
    }

    init(width: Int, height: Int, bgraPixels: Data) {
        self.width = width
        self.height = height
        self.pixels = bgraPixels
        self.isBGRA = true
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.width == rhs.width, lhs.height == rhs.height else { return false }
        if lhs.isBGRA == rhs.isBGRA { return lhs.pixels == rhs.pixels }
        return lhs.bgrPixels == rhs.bgrPixels
    }

    public func makeCGImage() -> CGImage? {
        guard width > 0, height > 0, width <= Int.max / height,
              width * height <= Int.max / 4,
              pixels.count == width * height * (isBGRA ? 4 : 3) else { return nil }
        // CGDataProvider retains the immutable Data snapshot. The common
        // renderer path has no full-frame channel conversion or extra buffer.
        let native = isBGRA ? pixels : ScreenPixelStorage.bgra32(fromBGR: pixels, width: width, height: height)
        guard let provider = CGDataProvider(data: native as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Implements the recovered >=6.0.0 desktop pipeline using the 16bpp temporary
/// converter mode (DisplayColors != 1). Use from one serial executor.
/// Initialization and image decoding do not establish a remote session.
public final class ModernScreenRenderer {
    /// Form1.ResetLastMsgNumber, VA 0x6eb050: push 0x80000001 at
    /// 0x6eb08b, then LastMsgNumber setter 0x7bc at 0x6eb091.
    /// OnConnected and inbound command 26 invoke this reset. Initialization
    /// remains explicit so callers cannot silently reset an active stream.
    public static let resetFrameNumber: Int32 = -2_147_483_647

    public let width: Int
    public let height: Int
    public private(set) var tileSize: Int
    public private(set) var lastFrameNumber: Int32
    public let limits: ModernScreenLimits

    private struct CachedRectangle {
        let width: Int
        let height: Int
        let pixels: Data // tightly packed top-down RGB555, little endian
    }

    private struct State {
        var mainPixels: Data // top-down opaque BGRA32, separate from the converter buffer
        var temporary: ScreenRectangleBuffer // bottom-up RGB555 with DWORD row stride
        var cache: [Int32: CachedRectangle] = [:]
        var cacheOrder: [Int32] = [] // oldest first, native maximum is 1000
        var cacheBytes = 0
    }

    private var state: State
    private let decompressor: ZstdScreenDecoder

    /// lastFrameNumber is explicit: the desktop requires incoming == previous+1
    /// in modern live mode. Session orchestration must supply its actual baseline.
    /// displayColors == 1 is rejected because that mode needs the custom palette.
    public init(width: Int, height: Int, tileSize: Int = 16, displayColors: Int,
                lastFrameNumber: Int32, limits: ModernScreenLimits = .init(),
                dictionary: Data? = nil) throws {
        try limits.validate()
        try limits.checkGeometry(width: width, height: height)
        guard displayColors != 1 else { throw ModernScreenMessageError.unsupportedColorMode }
        guard (1...255).contains(tileSize) else { throw ModernScreenMessageError.invalidGeometry }
        let pixelCount = try Self.product(width, height)
        _ = try Self.product(pixelCount, 4) // also makeCGImage's bounded allocation
        let rawRow = try Self.product(width, 2)
        guard rawRow <= Int.max - 3 else { throw ModernScreenMessageError.sizeLimitExceeded }
        let stride = (rawRow + 3) & ~3
        self.width = width
        self.height = height
        self.tileSize = tileSize
        self.lastFrameNumber = lastFrameNumber
        self.limits = limits
        self.state = State(mainPixels: ScreenPixelStorage.opaqueBlack(width: width, height: height),
                           temporary: try ScreenRectangleBuffer(
                            width: width, height: height, bytesPerPixel: 2, rowStride: stride,
                            pixels: Data(count: try Self.product(stride, height))))
        self.decompressor = try ZstdScreenDecoder(maximumOutputBytes: limits.maximumDecompressedBytes,
                                                dictionary: dictionary)
    }

    public var bitmap: ModernScreenBitmap {
        ModernScreenBitmap(width: width, height: height, bgraPixels: state.mainPixels)
    }

    public var cacheEntryCount: Int { state.cache.count }
    public var cacheByteCount: Int { state.cacheBytes }

    /// Command 48 carries the new tile size in the first byte of part 1.
    public func setTileSize(parts: [Data]) throws {
        try limits.checkParts(parts)
        guard let header = parts.first, let command = header.first else {
            throw ModernScreenMessageError.malformedPart(0)
        }
        guard command == 48 else { throw ModernScreenMessageError.unsupportedCommand(command) }
        guard parts.count > 1 else { throw ModernScreenMessageError.missingPart(1) }
        guard let value = parts[1].first, value > 0 else {
            throw ModernScreenMessageError.malformedPart(1)
        }
        tileSize = Int(value)
    }

    /// The original clears its ordered cache on color-change/clear missions.
    /// Session code must call this when changing converter mode or resetting it.
    public func clearCache() {
        state.cache.removeAll()
        state.cacheOrder.removeAll()
        state.cacheBytes = 0
    }

    /// Atomic local application: malformed/unsupported frames leave bitmap,
    /// temporary pixels, sequence, and cache unchanged. Native code often catches
    /// and continues on corrupt input; this implementation rejects it explicitly.
    @discardableResult
    public func apply(_ message: ModernScreenFrameMessage) throws -> ModernScreenBitmap {
        let expectedSequence = Int64(lastFrameNumber) + 1
        guard Int64(message.frameNumber) == expectedSequence else {
            throw ModernScreenMessageError.sequenceMismatch(expected: expectedSequence, received: message.frameNumber)
        }
        let rawPixels = try decodeMainPixels(message)
        var next = state

        // 0x06000c65 IL_01c9..032c: capture main→converter, then converter→main.
        if let scroll = message.scroll {
            try copyMainToTemporary(&next, source: scroll.capture,
                                    destinationX: scroll.capture.x,
                                    destinationY: scroll.capture.y - scroll.verticalDelta)
            for region in scroll.copyBack {
                copyTemporaryToMain(&next, sourceX: region.x, sourceY: region.y, destination: region)
            }
        }

        // IL_032c..0443: cache references write the converter, not the main DIB.
        for reference in message.cacheReferences {
            guard let item = next.cache[reference.hash] else {
                throw ModernScreenMessageError.cacheMiss(reference.hash)
            }
            try next.temporary.copyRectangle(item.pixels, width: item.width, height: item.height,
                                             atX: reference.x, atY: reference.y)
            next.cacheOrder.removeAll { $0 == reference.hash }
            next.cacheOrder.append(reference.hash)
        }

        // IL_0443..0512: expose selected converter rectangles to the main DIB.
        for region in message.copyFromTemporary {
            copyTemporaryToMain(&next, sourceX: region.x, sourceY: region.y, destination: region)
        }

        // IL_0512..0886: JPEG atlas tiles write full color directly to main.
        if !message.auxiliaryRectangles.isEmpty {
            let atlas = try decodeAuxiliaryJPEG(message.auxiliaryJPEG)
            try applyAuxiliary(atlas, rectangles: message.auxiliaryRectangles, to: &next)
        }

        // IL_0995..0d8a: each packed raw rectangle stages at converter (0,0).
        var offset = 0
        for rectangle in message.mainRectangles {
            let count = try Self.product(try Self.product(rectangle.width, rectangle.height), 2)
            let bytes = rawPixels[(rawPixels.startIndex + offset)..<(rawPixels.startIndex + offset + count)]
            try next.temporary.copyRectangle(bytes, width: rectangle.width, height: rectangle.height, atX: 0, atY: 0)
            copyTemporaryToMain(&next, sourceX: 0, sourceY: 0, destination: rectangle)
            offset += count
        }

        // IL_0d8a..0f3d: cache captures occur after every drawing operation.
        for addition in message.cacheAdditions {
            let region = addition.region
            // Ordinal 15's out-of-bounds extraction is not established. Do not
            // emulate unsafe reads or manufacture missing cache pixels.
            guard isInside(region, width: width, height: height) else {
                throw ModernScreenMessageError.invalidGeometry
            }
            try copyMainToTemporary(&next, source: region, destinationX: region.x, destinationY: region.y)
            let captured = try extractTemporary(next.temporary, region: region)
            if next.cache[addition.hash] == nil {
                guard captured.count <= limits.maximumCacheBytes - next.cacheBytes else {
                    throw ModernScreenMessageError.cacheBudgetExceeded
                }
                next.cache[addition.hash] = CachedRectangle(width: region.width, height: region.height, pixels: captured)
                next.cacheOrder.append(addition.hash)
                next.cacheBytes += captured.count
            }
        }
        // Preserve native trim timing and insertion/reference order.
        while next.cacheOrder.count > 1000 {
            let hash = next.cacheOrder.removeFirst()
            if let removed = next.cache.removeValue(forKey: hash) { next.cacheBytes -= removed.pixels.count }
        }

        state = next
        lastFrameNumber = message.frameNumber
        return bitmap
    }

    private func decodeMainPixels(_ message: ModernScreenFrameMessage) throws -> Data {
        var expected = 0
        for region in message.mainRectangles {
            try limits.checkGeometry(width: region.width, height: region.height)
            let count = try Self.product(try Self.product(region.width, region.height), 2)
            guard count <= limits.maximumDecompressedBytes - expected else {
                throw ModernScreenMessageError.sizeLimitExceeded
            }
            expected += count
        }
        try decompressor.reset() // UVC #25 before #16, for every drawing mission.
        let decoded = try decompressor.append(message.compressedPixels)
        try decompressor.finish()
        guard decoded.count == expected else {
            throw ModernScreenMessageError.decompressedLengthMismatch(expected: expected, received: decoded.count)
        }
        return decoded
    }

    private struct CopyWindow {
        let sourceX: Int
        let sourceY: Int
        let destinationX: Int
        let destinationY: Int
        let width: Int
        let height: Int
    }

    /// Clips source and destination together, preserving their coordinate offset.
    private func clippedCopy(sourceX: Int, sourceY: Int, destinationX: Int, destinationY: Int,
                             width requestedWidth: Int, height requestedHeight: Int) -> CopyWindow? {
        let left = max(0, -sourceX, -destinationX)
        let top = max(0, -sourceY, -destinationY)
        let right = min(requestedWidth, width - sourceX, width - destinationX)
        let bottom = min(requestedHeight, height - sourceY, height - destinationY)
        guard left < right, top < bottom else { return nil }
        return CopyWindow(sourceX: sourceX + left, sourceY: sourceY + top,
                          destinationX: destinationX + left, destinationY: destinationY + top,
                          width: right - left, height: bottom - top)
    }

    private func copyMainToTemporary(_ state: inout State, source: ScreenRegion,
                                     destinationX: Int, destinationY: Int) throws {
        guard let copy = clippedCopy(sourceX: source.x, sourceY: source.y,
                                     destinationX: destinationX, destinationY: destinationY,
                                     width: source.width, height: source.height) else { return }
        var packed = Data(count: try Self.product(try Self.product(copy.width, copy.height), 2))
        let mainWidth = width
        state.mainPixels.withUnsafeBytes { (main: UnsafeRawBufferPointer) in
            packed.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                ScreenPixelStorage.packRGB555(
                    source: main.baseAddress!.advanced(by: (copy.sourceY * mainWidth + copy.sourceX) * 4),
                    sourceRowBytes: mainWidth * 4, destination: target.baseAddress!,
                    destinationRowBytes: copy.width * 2, width: copy.width, height: copy.height)
            }
        }
        try state.temporary.copyRectangle(packed, width: copy.width, height: copy.height,
                                           atX: copy.destinationX, atY: copy.destinationY)
    }

    private func copyTemporaryToMain(_ state: inout State, sourceX: Int, sourceY: Int,
                                     destination: ScreenRegion) {
        guard let copy = clippedCopy(sourceX: sourceX, sourceY: sourceY,
                                     destinationX: destination.x, destinationY: destination.y,
                                     width: destination.width, height: destination.height) else { return }
        let tempHeight = height
        let tempStride = state.temporary.rowStride
        let mainWidth = width
        state.temporary.pixels.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            state.mainPixels.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                ScreenPixelStorage.expandRGB555(
                    source: source.baseAddress!.advanced(by: (tempHeight - 1 - copy.sourceY) * tempStride + copy.sourceX * 2),
                    sourceRowBytes: -tempStride,
                    destination: target.baseAddress!.advanced(by: (copy.destinationY * mainWidth + copy.destinationX) * 4),
                    destinationRowBytes: mainWidth * 4, width: copy.width, height: copy.height)
            }
        }
    }

    private func extractTemporary(_ temporary: ScreenRectangleBuffer, region: ScreenRegion) throws -> Data {
        let rowBytes = region.width * 2
        var result = Data(count: try Self.product(rowBytes, region.height))
        temporary.pixels.withUnsafeBytes { source in
            result.withUnsafeMutableBytes { target in
                for row in 0..<region.height {
                    let start = (height - 1 - region.y - row) * temporary.rowStride + region.x * 2
                    target.baseAddress!.advanced(by: row * rowBytes).copyMemory(
                        from: source.baseAddress!.advanced(by: start), byteCount: rowBytes)
                }
            }
        }
        return result
    }

    private struct AuxiliaryAtlas {
        let width: Int
        let height: Int
        let pixels: Data // BGRA32, top-down; physical native rows are addressed in reverse
    }

    private func decodeAuxiliaryJPEG(_ jpeg: Data) throws -> AuxiliaryAtlas {
        guard jpeg.count <= limits.maximumPayloadBytes,
              let source = CGImageSourceCreateWithData(jpeg as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source), type as String == "public.jpeg",
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw ModernScreenMessageError.invalidJPEG
        }
        let imageWidth = widthNumber.intValue
        let imageHeight = heightNumber.intValue
        try limits.checkAtlasGeometry(width: imageWidth, height: imageHeight)
        let pixelCount = try Self.product(imageWidth, imageHeight)
        let byteCount = try Self.product(pixelCount, 4)
        guard let image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              image.width == imageWidth, image.height == imageHeight else {
            throw ModernScreenMessageError.invalidJPEG
        }
        var rgba = Data(count: byteCount)
        let success = rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: imageWidth, height: imageHeight,
                                          bitsPerComponent: 8, bytesPerRow: imageWidth * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                                            | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
            return true
        }
        guard success else { throw ModernScreenMessageError.unsupportedJPEG }
        return AuxiliaryAtlas(width: imageWidth, height: imageHeight, pixels: rgba)
    }

    private func applyAuxiliary(_ atlas: AuxiliaryAtlas, rectangles: [ScreenRegion], to state: inout State) throws {
        var sourceColumn = 0
        var sourceY = 0
        var tileCount = 0
        for rectangle in rectangles {
            guard isInside(rectangle, width: width, height: height) else {
                throw ModernScreenMessageError.invalidGeometry
            }
            // Recovered loop order: destination x outside, destination y inside.
            for dx in stride(from: 0, to: rectangle.width, by: tileSize) {
                for dy in stride(from: 0, to: rectangle.height, by: tileSize) {
                    guard tileCount < limits.maximumAuxiliaryTiles else {
                        throw ModernScreenMessageError.sizeLimitExceeded
                    }
                    tileCount += 1
                    let tileWidth = min(tileSize, rectangle.width - dx)
                    let tileHeight = min(tileSize, rectangle.height - dy)
                    if sourceY + tileHeight > atlas.height {
                        sourceY = 0
                        sourceColumn += 1
                    }
                    let sourceX = try Self.product(sourceColumn, tileSize)
                    guard tileWidth <= atlas.width, tileHeight <= atlas.height,
                          sourceX <= atlas.width - tileWidth, sourceY <= atlas.height - tileHeight else {
                        Logger(subsystem: "dev.macviewer.app", category: "screen").error(
                            "Atlas bounds: atlas=\(atlas.width)x\(atlas.height) tile=\(self.tileSize) source=\(sourceX),\(sourceY) size=\(tileWidth)x\(tileHeight) rectangle=\(rectangle.x),\(rectangle.y),\(rectangle.width),\(rectangle.height)")
                        throw ModernScreenMessageError.auxiliaryAtlasOutOfBounds
                    }
                    let mainWidth = width
                    atlas.pixels.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                        state.mainPixels.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                            for row in 0..<tileHeight {
                                // Native TurboJPEG flags1026 are bottom-up. An
                                // address reversal preserves that order without
                                // converting/copying the complete decoded atlas.
                                let sourceOffset = ((atlas.height - 1 - sourceY - row) * atlas.width + sourceX) * 4
                                let destination = ((rectangle.y + dy + row) * mainWidth + rectangle.x + dx) * 4
                                target.baseAddress!.advanced(by: destination).copyMemory(
                                    from: source.baseAddress!.advanced(by: sourceOffset), byteCount: tileWidth * 4)
                            }
                        }
                    }
                    sourceY += tileHeight
                }
            }
        }
    }

    private func isInside(_ region: ScreenRegion, width: Int, height: Int) -> Bool {
        region.x >= 0 && region.y >= 0 && region.width > 0 && region.height > 0
            && region.width <= width && region.height <= height
            && region.x <= width - region.width && region.y <= height - region.height
    }

    private static func product(_ a: Int, _ b: Int) throws -> Int {
        let (result, overflow) = a.multipliedReportingOverflow(by: b)
        guard !overflow, result >= 0 else { throw ModernScreenMessageError.sizeLimitExceeded }
        return result
    }
}

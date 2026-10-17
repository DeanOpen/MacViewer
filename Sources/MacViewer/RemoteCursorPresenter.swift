import AppKit
import ImageIO
import UltraViewerProtocol

/// Cursor presentation state only. Never installs a cursor or moves the local
/// pointer; the owner decides whether/how to present it and send shape requests.
@MainActor
final class RemoteCursorPresenter {
    struct Snapshot {
        let image: CGImage
        /// Coordinates in image pixels, matching the validated CUR resource.
        let hotSpot: CGPoint
        /// Unscaled Windows virtual-desktop coordinates, not Mac screen points.
        let position: CGPoint?
        let isFallback: Bool
    }

    static let maximumShapeCount = 64
    static let maximumDecodedBytes = 16 * 1024 * 1024
    static let maximumEncodedBytes = 2 * 1024 * 1024

    private struct Shape {
        let image: CGImage
        let hotSpot: CGPoint
        let bytes: Int
        let isFallback: Bool
    }

    private(set) var snapshot: Snapshot
    private(set) var selectedHash: Int32?
    var cacheEntryCount: Int { cache.count }
    private(set) var cacheByteCount = 0
    var pendingRequestCount: Int { pending.count }

    private let maximumShapes: Int
    private let maximumBytes: Int
    private let fallback: Shape
    private var cache: [Int32: Shape] = [:]
    private var recency: [Int32] = []
    private var pending: Set<Int32> = []
    private var pendingOrder: [Int32] = []

    init(maximumShapes: Int = RemoteCursorPresenter.maximumShapeCount,
         maximumBytes: Int = RemoteCursorPresenter.maximumDecodedBytes) {
        precondition((1...Self.maximumShapeCount).contains(maximumShapes))
        precondition((1...Self.maximumDecodedBytes).contains(maximumBytes))
        self.maximumShapes = maximumShapes
        self.maximumBytes = maximumBytes
        let arrow = Self.arrowShape()
        self.fallback = arrow
        self.snapshot = Snapshot(image: arrow.image, hotSpot: arrow.hotSpot, position: nil, isFallback: true)
    }

    /// Returns a newly missing selection hash for CursorMessage.shapeRequest.
    /// Duplicate requests are suppressed in a bounded set. Late shape replies
    /// are cached but only update presentation if their hash remains selected.
    @discardableResult
    func consume(_ message: CursorMessage) -> Int32? {
        switch message {
        case let .selection(hash):
            guard hash != CursorMessage.ignoredSelectionHash else { return nil }
            selectedHash = hash
            if let shape = cache[hash] {
                touch(hash)
                present(shape)
                return nil
            }
            guard !pending.contains(hash) else { return nil }
            while pendingOrder.count >= maximumShapes {
                pending.remove(pendingOrder.removeFirst())
            }
            pending.insert(hash)
            pendingOrder.append(hash)
            return hash
        case let .shape(hash, cursor):
            pending.remove(hash)
            pendingOrder.removeAll { $0 == hash }
            var shape = Self.decode(cursor) ?? fallback
            if shape.bytes > maximumBytes { shape = fallback }
            if let previous = cache.removeValue(forKey: hash) { cacheByteCount -= previous.bytes }
            recency.removeAll { $0 == hash }
            while !recency.isEmpty && (cache.count >= maximumShapes || shape.bytes > maximumBytes - cacheByteCount) {
                let oldest = recency.removeFirst()
                if let removed = cache.removeValue(forKey: oldest) { cacheByteCount -= removed.bytes }
            }
            cache[hash] = shape
            cacheByteCount += shape.bytes
            recency.append(hash)
            if selectedHash == hash { present(shape) }
        case let .position(x, y):
            snapshot = Snapshot(image: snapshot.image, hotSpot: snapshot.hotSpot,
                position: CGPoint(x: CGFloat(x), y: CGFloat(y)), isFallback: snapshot.isFallback)
        }
        return nil
    }

    func reset() {
        cache.removeAll()
        recency.removeAll()
        pending.removeAll()
        pendingOrder.removeAll()
        cacheByteCount = 0
        selectedHash = nil
        snapshot = Snapshot(image: fallback.image, hotSpot: fallback.hotSpot, position: nil, isFallback: true)
    }

    private func present(_ shape: Shape) {
        snapshot = Snapshot(image: shape.image, hotSpot: shape.hotSpot,
            position: snapshot.position, isFallback: shape.isFallback)
    }

    private func touch(_ hash: Int32) {
        recency.removeAll { $0 == hash }
        recency.append(hash)
    }

    private static func decode(_ cursor: CursorFile) -> Shape? {
        guard cursor.fileData.count <= maximumEncodedBytes, cursor.resourceData.count <= maximumEncodedBytes,
              (1...256).contains(cursor.width), (1...256).contains(cursor.height),
              Int(cursor.hotSpotX) < cursor.width, Int(cursor.hotSpotY) < cursor.height,
              resourceGeometryIsSafe(cursor) else { return nil }
        if !cursor.resourceData.starts(with: pngSignature) {
            let bytes = [UInt8](cursor.resourceData)
            if long(bytes, 0) == 12 || long(bytes, 16) == 0 {
                // ImageIO rejects some valid small CUR/ICO bitmap resources.
                // Decode their uncompressed DIB directly, including its mask.
                guard let image = decodeUncompressedDIB(bytes, width: cursor.width, height: cursor.height) else {
                    return nil
                }
                return Shape(image: image,
                    hotSpot: CGPoint(x: CGFloat(cursor.hotSpotX), y: CGFloat(cursor.hotSpotY)),
                    bytes: cursor.width * cursor.height * 4, isFallback: false)
            }
        }
        var candidates = [cursor.fileData]
        if cursor.resourceData.starts(with: pngSignature) { candidates.append(cursor.resourceData) }
        candidates.append(singleImageIcon(cursor))
        for bytes in candidates {
            guard let source = CGImageSourceCreateWithData(bytes as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) > 0,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  (1...256).contains(width), (1...256).contains(height),
                  width == cursor.width, height == cursor.height,
                  let image = CGImageSourceCreateImageAtIndex(source, 0,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
                  image.width == width, image.height == height,
                  let raster = rasterize(image) else { continue }
            // The returned raster owns only bounded decoded pixels, so caching
            // it does not retain a potentially 2 MiB encoded CUR for each hash.
            return Shape(image: raster, hotSpot: CGPoint(x: CGFloat(cursor.hotSpotX), y: CGFloat(cursor.hotSpotY)),
                         bytes: width * height * 4, isFallback: false)
        }
        return nil
    }

    private static let pngSignature = Data([137, 80, 78, 71, 13, 10, 26, 10])

    /// Packed CUR DIB: header, optional BGR palette, DWORD-padded XOR rows,
    /// then DWORD-padded1bpp AND rows. The directory height is half the DIB
    /// height. All arithmetic follows the256px preflight bound above.
    /// https://learn.microsoft.com/en-us/windows/win32/gdi/bitmap-header-types
    /// https://devblogs.microsoft.com/oldnewthing/20101021-00/?p=12483/
    private static func decodeUncompressedDIB(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        let header = Int(long(bytes, 0))
        guard [12, 40, 52, 56, 108, 124].contains(header), header <= bytes.count else { return nil }
        let core = header == 12
        let bits = Int(word(bytes, core ? 10 : 14))
        guard [1, 4, 8, 16, 24, 32].contains(bits), core || long(bytes, 16) == 0 else { return nil }
        let topDown = !core && Int32(bitPattern: long(bytes, 8)) < 0
        let declaredColors = core ? 0 : Int(long(bytes, 32))
        let colorCount: Int
        if bits <= 8 {
            colorCount = declaredColors == 0 ? 1 << bits : declaredColors
            guard colorCount > 0, colorCount <= 1 << bits else { return nil }
        } else {
            // High-color DIBs can carry an optional optimization palette.
            guard declaredColors <= 256 else { return nil }
            colorCount = declaredColors
        }
        let paletteStride = core ? 3 : 4
        let pixelsOffset = header + colorCount * paletteStride
        let stride = ((width * bits + 31) / 32) * 4
        let maskStride = ((width + 31) / 32) * 4
        let maskOffset = pixelsOffset + stride * height
        guard pixelsOffset <= bytes.count, maskOffset <= bytes.count,
              maskStride * height <= bytes.count - maskOffset else { return nil }

        // Windows interprets32bpp all-zero alpha as legacy0RGB+AND/XOR;
        // otherwise alpha is authoritative and the AND mask is ignored.
        var usesAlpha = false
        if bits == 32 {
            for row in 0..<height {
                for x in 0..<width where bytes[pixelsOffset + row * stride + x * 4 + 3] != 0 {
                    usesAlpha = true
                }
            }
        }
        var pixels = Data(count: width * height * 4)
        let valid = pixels.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) -> Bool in
            for y in 0..<height {
                let sourceY = topDown ? y : height - 1 - y
                let row = pixelsOffset + sourceY * stride
                let maskRow = maskOffset + sourceY * maskStride
                for x in 0..<width {
                    var blue: UInt8, green: UInt8, red: UInt8
                    var alpha: UInt8 = 255
                    switch bits {
                    case 1, 4, 8:
                        let index: Int
                        if bits == 1 { index = Int((bytes[row + x / 8] >> (7 - x % 8)) & 1) }
                        else if bits == 4 { index = Int((bytes[row + x / 2] >> (x % 2 == 0 ? 4 : 0)) & 15) }
                        else { index = Int(bytes[row + x]) }
                        guard index < colorCount else { return false }
                        let entry = header + index * paletteStride
                        blue = bytes[entry]; green = bytes[entry + 1]; red = bytes[entry + 2]
                    case 16:
                        let value = word(bytes, row + x * 2)
                        func expand(_ value: UInt16) -> UInt8 { UInt8((value << 3) | (value >> 2)) }
                        blue = expand(value & 31)
                        green = expand((value >> 5) & 31)
                        red = expand((value >> 10) & 31)
                    default:
                        let offset = row + x * (bits / 8)
                        blue = bytes[offset]; green = bytes[offset + 1]; red = bytes[offset + 2]
                        if usesAlpha { alpha = bytes[offset + 3] }
                    }
                    if !usesAlpha, bytes[maskRow + x / 8] & (0x80 >> (x % 8)) != 0 {
                        // AND=1/XOR!=0 requires compositing with the desktop
                        // (e.g. an inverted I-beam), not a static cursor image.
                        guard blue == 0, green == 0, red == 0 else { return false }
                        alpha = 0
                    }
                    let offset = (y * width + x) * 4
                    output[offset] = alpha == 0 ? 0 : blue
                    output[offset + 1] = alpha == 0 ? 0 : green
                    output[offset + 2] = alpha == 0 ? 0 : red
                    output[offset + 3] = alpha
                }
            }
            return true
        }
        guard valid, let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        // Resource ARGB channels are kept straight; CGImage performs any
        // required premultiplication when the image is drawn by AppKit.
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue)],
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Check underlying resource dimensions before an ICO/CUR decoder could
    /// trust a smaller directory entry. Embedded JPEG/PNG-compressed DIBs are
    /// unsupported; raw DIB and bitfield forms have bounded pixel dimensions.
    private static func resourceGeometryIsSafe(_ cursor: CursorFile) -> Bool {
        let data = cursor.resourceData
        if data.starts(with: pngSignature) {
            guard let source = CGImageSourceCreateWithData(data as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return false }
            return (1...256).contains(width) && (1...256).contains(height)
                && width == cursor.width && height == cursor.height
        }
        guard data.count >= 12 else { return false }
        let bytes = [UInt8](data.prefix(40))
        let headerSize = Int(long(bytes, 0))
        if headerSize == 12 {
            return Int(word(bytes, 4)) == cursor.width && Int(word(bytes, 6)) == cursor.height * 2
                && word(bytes, 8) == 1 && [1, 4, 8, 24].contains(Int(word(bytes, 10)))
        }
        guard headerSize >= 40, headerSize <= data.count, bytes.count >= 40 else { return false }
        let width = Int32(bitPattern: long(bytes, 4))
        let doubledHeight = Int32(bitPattern: long(bytes, 8))
        return Int(width) == cursor.width
            && (Int(doubledHeight) == cursor.height * 2 || Int(doubledHeight) == -cursor.height * 2)
            && word(bytes, 12) == 1 && [1, 4, 8, 16, 24, 32].contains(Int(word(bytes, 14)))
            && [0, 3, 6].contains(Int(long(bytes, 16)))
    }

    private static func singleImageIcon(_ cursor: CursorFile) -> Data {
        var bits: UInt16 = 32
        if !cursor.resourceData.starts(with: pngSignature), cursor.resourceData.count >= 16 {
            let bytes = [UInt8](cursor.resourceData.prefix(16))
            bits = word(bytes, long(bytes, 0) == 12 ? 10 : 14)
        }
        var icon = Data([0, 0, 1, 0, 1, 0,
            UInt8(truncatingIfNeeded: cursor.width), UInt8(truncatingIfNeeded: cursor.height), 0, 0, 1, 0,
            UInt8(truncatingIfNeeded: bits), UInt8(bits >> 8)])
        for value in [UInt32(cursor.resourceData.count), 22] {
            icon.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        icon.append(cursor.resourceData)
        return icon
    }

    private static func rasterize(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard (1...256).contains(width), (1...256).contains(height) else { return nil }
        var pixels = Data(count: width * height * 4)
        let success = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
                else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success, let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func arrowShape() -> Shape {
        let cursor = NSCursor.arrow
        var rect = CGRect(origin: .zero, size: cursor.image.size)
        if let image = cursor.image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
           let raster = rasterize(image) {
            let size = cursor.image.size
            let xScale = CGFloat(image.width) / max(1, size.width)
            let yScale = CGFloat(image.height) / max(1, size.height)
            return Shape(image: raster, hotSpot: CGPoint(x: cursor.hotSpot.x * xScale, y: cursor.hotSpot.y * yScale),
                         bytes: 0, isFallback: true)
        }
        // A bounded arrow remains available in an AppKit test process where
        // the system cursor's image representation is not supplied.
        let context = CGContext(data: nil, width: 16, height: 20, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(1)
        context.move(to: CGPoint(x: 1, y: 19))
        context.addLines(between: [CGPoint(x: 1, y: 3), CGPoint(x: 5, y: 7), CGPoint(x: 9, y: 1),
                                  CGPoint(x: 12, y: 3), CGPoint(x: 8, y: 9), CGPoint(x: 14, y: 9)])
        context.closePath()
        context.drawPath(using: .fillStroke)
        return Shape(image: context.makeImage()!, hotSpot: CGPoint(x: 1, y: 1), bytes: 0, isFallback: true)
    }

    private static func word(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func long(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
    }
}

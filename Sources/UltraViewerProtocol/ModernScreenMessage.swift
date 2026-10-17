import Foundation

/// Recovered desktop screen command layouts for targets at least version 6.0.0.
/// This accepts an already decrypted and split multipart payload, not TCP bytes.
public enum ModernScreenMessageError: Error, Equatable, LocalizedError {
    case unsupportedCommand(UInt8)
    case missingPart(Int)
    case malformedPart(Int)
    case invalidGeometry
    case sizeLimitExceeded
    case unsupportedColorMode
    case sequenceMismatch(expected: Int64, received: Int32)
    case decompressedLengthMismatch(expected: Int, received: Int)
    case cacheMiss(Int32)
    case cacheBudgetExceeded
    case invalidJPEG
    case unsupportedJPEG
    case auxiliaryAtlasOutOfBounds

    public var errorDescription: String? {
        switch self {
        case .unsupportedCommand: "Windows sent an unsupported screen update."
        case .missingPart, .malformedPart: "Windows sent an incomplete screen update."
        case .invalidGeometry: "Windows sent an invalid screen rectangle."
        case .sizeLimitExceeded: "The Windows screen update exceeds the supported size."
        case .unsupportedColorMode: "The Windows screen color mode is not supported."
        case .sequenceMismatch: "Windows screen updates arrived out of order. Reconnect to refresh the screen."
        case .decompressedLengthMismatch: "The Windows screen update has an invalid pixel count."
        case .cacheMiss: "A Windows screen update refers to a missing image tile."
        case .cacheBudgetExceeded: "The Windows screen image cache is full."
        case .invalidJPEG, .unsupportedJPEG: "Windows sent a screen image that could not be decoded."
        case .auxiliaryAtlasOutOfBounds: "A Windows screen update contains an invalid image tile."
        }
    }
}

/// Implementation limits, not protocol constants recovered from the client.
public struct ModernScreenLimits: Equatable, Sendable {
    public let maximumDimension: Int
    public let maximumPixels: Int
    public let maximumPayloadBytes: Int
    public let maximumDecompressedBytes: Int
    public let maximumRecordsPerPart: Int
    public let maximumCacheBytes: Int
    public let maximumAuxiliaryTiles: Int
    public let maximumAtlasDimension: Int

    public init(maximumDimension: Int = 8192,
                maximumPixels: Int = 16 * 1024 * 1024,
                maximumPayloadBytes: Int = 64 * 1024 * 1024,
                maximumDecompressedBytes: Int = 128 * 1024 * 1024,
                maximumRecordsPerPart: Int = 16_384,
                maximumCacheBytes: Int = 64 * 1024 * 1024,
                maximumAuxiliaryTiles: Int = 1_048_576,
                maximumAtlasDimension: Int = 65_535) {
        self.maximumDimension = maximumDimension
        self.maximumPixels = maximumPixels
        self.maximumPayloadBytes = maximumPayloadBytes
        self.maximumDecompressedBytes = maximumDecompressedBytes
        self.maximumRecordsPerPart = maximumRecordsPerPart
        self.maximumCacheBytes = maximumCacheBytes
        self.maximumAuxiliaryTiles = maximumAuxiliaryTiles
        self.maximumAtlasDimension = maximumAtlasDimension
    }

    func validate() throws {
        guard maximumDimension > 0, maximumPixels > 0, maximumPayloadBytes > 0,
              maximumDecompressedBytes > 0, maximumRecordsPerPart > 0,
              maximumCacheBytes > 0, maximumAuxiliaryTiles > 0, maximumAtlasDimension > 0 else {
            throw ModernScreenMessageError.sizeLimitExceeded
        }
    }

    /// Atlas tiles are packed into a narrow, tall JPEG. Its dimensions are
    /// independent of screen geometry; actual Windows frames can exceed 8192
    /// rows while remaining small in total pixel count.
    func checkAtlasGeometry(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw ModernScreenMessageError.invalidGeometry }
        guard width <= maximumAtlasDimension, height <= maximumAtlasDimension,
              width <= maximumPixels / height else {
            throw ModernScreenMessageError.sizeLimitExceeded
        }
    }

    func checkGeometry(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw ModernScreenMessageError.invalidGeometry }
        guard width <= maximumDimension, height <= maximumDimension,
              width <= maximumPixels / height else {
            throw ModernScreenMessageError.sizeLimitExceeded
        }
    }

    func checkParts(_ parts: [Data]) throws {
        try validate()
        var total = 0
        for part in parts {
            guard part.count <= maximumPayloadBytes - total else {
                throw ModernScreenMessageError.sizeLimitExceeded
            }
            total += part.count
        }
    }
}

public struct ScreenRegion: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// The known screen fields of command 0. Unknown init parts remain uninterpreted.
/// A version byte string is retained because the Windows ANSI code page is not
/// encoded on the wire. Session keys/authentication are not inferred from it.
public struct ModernScreenInitialization: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let tileSize: Int
    public let targetVersionBytes: Data?
    public let monitorInformationBytes: Data?
    public let virtualLeft: Int32?
    public let virtualTop: Int32?

    public static func decode(parts: [Data], limits: ModernScreenLimits = .init()) throws -> Self {
        try limits.checkParts(parts)
        try ScreenPartReader.command(parts, expected: 0)
        let width = Int(try ScreenPartReader.int32Part(parts, index: 1))
        let height = Int(try ScreenPartReader.int32Part(parts, index: 2))
        try limits.checkGeometry(width: width, height: height)
        // Native optional branches consume these slots' first values whenever
        // present, regardless of the previous screen geometry.
        // Validate their lengths even though this screen-metadata type does not
        // interpret licensing/capability/initial-display flags.
        for index in [5, 11] where parts.count > index {
            guard !parts[index].isEmpty else { throw ModernScreenMessageError.malformedPart(index) }
        }
        if parts.count > 6 {
            guard parts.count > 7 else { throw ModernScreenMessageError.missingPart(7) }
            guard !parts[7].isEmpty else { throw ModernScreenMessageError.malformedPart(7) }
        }
        if parts.count > 12, parts[12].count < 2 {
            throw ModernScreenMessageError.malformedPart(12)
        }
        // Part 13 is consumed only when native width/height changed. This
        // stateless screen-fields decoder leaves that capability uninterpreted;
        // its presence alone does not establish that the byte is consumed.
        var left: Int32?
        var top: Int32?
        if parts.count > 8 {
            left = try ScreenPartReader.int32Part(parts, index: 9)
            top = try ScreenPartReader.int32Part(parts, index: 10)
        }
        let tileSize: Int
        if parts.count > 14 {
            guard let value = parts[14].first, value > 0 else {
                throw ModernScreenMessageError.malformedPart(14)
            }
            tileSize = Int(value)
        } else {
            tileSize = 16
        }
        return Self(width: width, height: height, tileSize: tileSize,
                    targetVersionBytes: parts.count > 6 ? parts[6] : nil,
                    monitorInformationBytes: parts.count > 8 ? parts[8] : nil,
                    virtualLeft: left, virtualTop: top)
    }
}

public struct ModernScreenFrameMessage: Equatable, Sendable {
    public struct Scroll: Equatable, Sendable {
        public let verticalDelta: Int
        public let capture: ScreenRegion
        public let copyBack: [ScreenRegion]
    }

    public struct CacheReference: Equatable, Sendable {
        public let x: Int
        public let y: Int
        public let hash: Int32
    }

    public struct CacheAddition: Equatable, Sendable {
        public let region: ScreenRegion
        public let hash: Int32
    }

    public let frameNumber: Int32
    public let mainRectangles: [ScreenRegion]
    public let compressedPixels: Data
    public let copyFromTemporary: [ScreenRegion]
    public let scroll: Scroll?
    public let auxiliaryJPEG: Data
    public let auxiliaryRectangles: [ScreenRegion]
    public let cacheReferences: [CacheReference]
    public let cacheAdditions: [CacheAddition]

    /// At least eleven slots are consumed by the original modern branch.
    /// Part 3, extra header bytes, and trailing slots are ignored by that branch;
    /// they are not interpreted as undocumented flags or image data here.
    public static func decode(parts: [Data], limits: ModernScreenLimits = .init()) throws -> Self {
        try limits.checkParts(parts)
        try ScreenPartReader.command(parts, expected: 1)
        guard parts.count > 10 else { throw ModernScreenMessageError.missingPart(parts.count) }
        let main = try ScreenPartReader.regions(parts[1], part: 1, signed: false, limits: limits)
        let copy = try ScreenPartReader.regions(parts[5], part: 5, signed: true, limits: limits)
        let auxiliary = try ScreenPartReader.regions(parts[8], part: 8, signed: true, limits: limits)
        let scroll: Scroll?
        if parts[6].isEmpty {
            scroll = nil
        } else {
            guard parts[6].count >= 10, (parts[6].count - 10) % 8 == 0,
                  (parts[6].count - 10) / 8 <= limits.maximumRecordsPerPart else {
                throw ModernScreenMessageError.malformedPart(6)
            }
            let bytes = [UInt8](parts[6])
            let capture = try ScreenPartReader.region(bytes, offset: 2, signed: true, limits: limits)
            let tail = Data(bytes.dropFirst(10))
            scroll = Scroll(verticalDelta: ScreenPartReader.int16(bytes, 0), capture: capture,
                            copyBack: try ScreenPartReader.regions(tail, part: 6, signed: true, limits: limits))
        }
        try ScreenPartReader.records(parts[9], part: 9, size: 8, limits: limits)
        let referenceBytes = [UInt8](parts[9])
        let references = stride(from: 0, to: referenceBytes.count, by: 8).map {
            CacheReference(x: ScreenPartReader.int16(referenceBytes, $0),
                           y: ScreenPartReader.int16(referenceBytes, $0 + 2),
                           hash: ScreenPartReader.int32(referenceBytes, $0 + 4))
        }
        try ScreenPartReader.records(parts[10], part: 10, size: 12, limits: limits)
        let additionBytes = [UInt8](parts[10])
        let additions = try stride(from: 0, to: additionBytes.count, by: 12).map {
            CacheAddition(region: try ScreenPartReader.region(additionBytes, offset: $0, signed: true, limits: limits),
                          hash: ScreenPartReader.int32(additionBytes, $0 + 8))
        }
        return Self(frameNumber: try ScreenPartReader.int32Part(parts, index: 4),
                    mainRectangles: main, compressedPixels: parts[2], copyFromTemporary: copy,
                    scroll: scroll, auxiliaryJPEG: parts[7], auxiliaryRectangles: auxiliary,
                    cacheReferences: references, cacheAdditions: additions)
    }
}

private enum ScreenPartReader {
    static func command(_ parts: [Data], expected: UInt8) throws {
        guard let first = parts.first else { throw ModernScreenMessageError.missingPart(0) }
        guard let command = first.first else { throw ModernScreenMessageError.malformedPart(0) }
        guard command == expected else { throw ModernScreenMessageError.unsupportedCommand(command) }
    }

    static func int32Part(_ parts: [Data], index: Int) throws -> Int32 {
        guard parts.count > index else { throw ModernScreenMessageError.missingPart(index) }
        // Minimum consumed length is recovered; trailing bytes are ignored by native code.
        guard parts[index].count >= 4 else { throw ModernScreenMessageError.malformedPart(index) }
        return int32([UInt8](parts[index].prefix(4)), 0)
    }

    static func records(_ data: Data, part: Int, size: Int, limits: ModernScreenLimits) throws {
        guard data.count % size == 0 else { throw ModernScreenMessageError.malformedPart(part) }
        guard data.count / size <= limits.maximumRecordsPerPart else {
            throw ModernScreenMessageError.sizeLimitExceeded
        }
    }

    static func regions(_ data: Data, part: Int, signed: Bool, limits: ModernScreenLimits) throws -> [ScreenRegion] {
        try records(data, part: part, size: 8, limits: limits)
        let bytes = [UInt8](data)
        return try stride(from: 0, to: bytes.count, by: 8).map {
            try region(bytes, offset: $0, signed: signed, limits: limits)
        }
    }

    static func region(_ bytes: [UInt8], offset: Int, signed: Bool, limits: ModernScreenLimits) throws -> ScreenRegion {
        let read: (Int) -> Int = { signed ? int16(bytes, $0) : Int(uint16(bytes, $0)) }
        let result = ScreenRegion(x: read(offset), y: read(offset + 2),
                                  width: read(offset + 4), height: read(offset + 6))
        try limits.checkGeometry(width: result.width, height: result.height)
        return result
    }

    static func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    static func int16(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(Int16(bitPattern: uint16(bytes, offset)))
    }

    static func int32(_ bytes: [UInt8], _ offset: Int) -> Int32 {
        Int32(bitPattern: UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
              | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24))
    }
}

import Foundation

public enum CursorMessageError: Error, Equatable {
    case unsupportedCommand(UInt8)
    case missingPart(Int)
    case malformedPart(Int)
    case sizeLimitExceeded
    case decompressedLengthMismatch(expected: Int, received: Int)
    case invalidCursorFile
}

/// One CUR directory entry and its original image resource. Local validation
/// reads the complete 16-bit hotspots and 32-bit offset; the inspected Windows
/// loader truncates those values to their low byte. See desktop-cursor.md.
public struct CursorFile: Equatable, Sendable {
    public let fileData: Data
    public let resourceData: Data
    public let imageCount: UInt16
    public let width: Int
    public let height: Int
    public let hotSpotX: UInt16
    public let hotSpotY: UInt16

    public static func decode(_ data: Data, maximumBytes: Int = 2 * 1024 * 1024) throws -> Self {
        guard maximumBytes > 0, data.count <= maximumBytes else {
            throw CursorMessageError.sizeLimitExceeded
        }
        let bytes = [UInt8](data)
        guard bytes.count >= 22, Self.word(bytes, 0) == 0,
              Self.word(bytes, 2) == 2 else { throw CursorMessageError.invalidCursorFile }
        let count = Self.word(bytes, 4)
        let directoryEnd = 6 + Int(count) * 16
        guard count > 0, directoryEnd <= bytes.count else {
            throw CursorMessageError.invalidCursorFile
        }
        let width = bytes[6] == 0 ? 256 : Int(bytes[6])
        let height = bytes[7] == 0 ? 256 : Int(bytes[7])
        let hotSpotX = Self.word(bytes, 10)
        let hotSpotY = Self.word(bytes, 12)
        let size = Int(Self.long(bytes, 14))
        let offset = Int(Self.long(bytes, 18))
        guard bytes[9] == 0, Int(hotSpotX) < width, Int(hotSpotY) < height,
              size > 0, offset >= directoryEnd, offset <= bytes.count,
              size <= bytes.count - offset else { throw CursorMessageError.invalidCursorFile }
        return Self(fileData: data, resourceData: Data(bytes[offset..<(offset + size)]),
                    imageCount: count, width: width, height: height,
                    hotSpotX: hotSpotX, hotSpotY: hotSpotY)
    }

    private static func word(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func long(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
    }
}

/// Already decrypted multipart cursor messages. Shape selection, shape transfer
/// and remote pointer position are separate commands; this type owns no cache,
/// native cursor, clipboard, network connection or session state.
public enum CursorMessage: Equatable, Sendable {
    case selection(hash: Int32)
    case shape(hash: Int32, cursor: CursorFile)
    /// Signed virtual-desktop coordinates, before subtracting virtualLeft/Top.
    case position(x: Int16, y: Int16)

    /// This command-3 hash exits the inspected desktop branch without updating
    /// its cursor. Its sender-side meaning is not established.
    public static let ignoredSelectionHash = Int32(bitPattern: 0xb84d1a70)

    public static func decode(parts: [Data], modern: Bool = true,
                              maximumBytes: Int = 2 * 1024 * 1024) throws -> Self {
        guard maximumBytes > 0 else { throw CursorMessageError.sizeLimitExceeded }
        var total = 0
        for part in parts {
            guard part.count <= maximumBytes - total else {
                throw CursorMessageError.sizeLimitExceeded
            }
            total += part.count
        }
        guard let command = parts.first?.first else { throw CursorMessageError.missingPart(0) }
        switch command {
        case 3:
            return .selection(hash: try int32(parts, index: 1))
        case 4:
            let hash = try int32(parts, index: 1)
            let data: Data
            if modern {
                let expected = Int(try int32(parts, index: 2))
                guard expected > 0, expected <= maximumBytes else {
                    throw CursorMessageError.sizeLimitExceeded
                }
                let compressed = try part(parts, index: 3, minimum: 1)
                // UVC ordinal50 creates a fresh decoder and has no dictionary
                // argument. Never reuse the screen decoder/dictionary here.
                let decoder = try ZstdScreenDecoder(maximumOutputBytes: maximumBytes)
                data = try decoder.append(compressed)
                try decoder.finish()
                guard data.count == expected else {
                    throw CursorMessageError.decompressedLengthMismatch(expected: expected,
                                                                         received: data.count)
                }
            } else {
                data = try part(parts, index: 2, minimum: 1)
            }
            return .shape(hash: hash, cursor: try CursorFile.decode(data, maximumBytes: maximumBytes))
        case 28:
            return .position(x: try int16(parts, index: 1), y: try int16(parts, index: 2))
        default:
            throw CursorMessageError.unsupportedCommand(command)
        }
    }

    /// Native cache-miss request: decimal ASCII through SendData with false
    /// format flag, before the separate relay routing/framing layer.
    public static func shapeRequest(hash: Int32) -> Data {
        Data("4|||\(hash)".utf8)
    }

    private static func part(_ parts: [Data], index: Int, minimum: Int) throws -> Data {
        guard index < parts.count else { throw CursorMessageError.missingPart(index) }
        guard parts[index].count >= minimum else { throw CursorMessageError.malformedPart(index) }
        return parts[index]
    }

    private static func int16(_ parts: [Data], index: Int) throws -> Int16 {
        let bytes = [UInt8](try part(parts, index: index, minimum: 2).prefix(2))
        return Int16(bitPattern: UInt16(bytes[0]) | UInt16(bytes[1]) << 8)
    }

    private static func int32(_ parts: [Data], index: Int) throws -> Int32 {
        let bytes = [UInt8](try part(parts, index: index, minimum: 4).prefix(4))
        let bits = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[$1]) << ($1 * 8) }
        return Int32(bitPattern: bits)
    }
}

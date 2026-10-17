import Foundation

/// Host→viewer multipart43 contains raw G.722 bytes; multipart42 supplies an
/// Int32LE count of zero PCM bytes. Silence does not advance G.722 state.
public enum ComputerAudioMessage: Sendable, Equatable {
    case encoded(Data)
    case silence(pcmByteCount: Int)

    public enum Error: Swift.Error, Equatable {
        case malformedMessage, unsupportedCommand, packetTooLarge, invalidSilenceLength
    }

    public static func decode(parts: [Data]) throws -> Self {
        guard parts.count >= 2, let command = parts.first?.first else { throw Error.malformedMessage }
        var total = 0
        for part in parts {
            guard part.count <= G722Decoder.maximumPCMPacketBytes - total else { throw Error.packetTooLarge }
            total += part.count
        }
        switch command {
        case 43:
            guard parts[1].count <= G722Decoder.maximumEncodedPacketBytes else { throw Error.packetTooLarge }
            return .encoded(parts[1])
        case 42:
            guard parts[1].count >= 4 else { throw Error.malformedMessage }
            let value = parts[1].prefix(4).enumerated().reduce(UInt32(0)) { result, item in
                result | UInt32(item.element) << (item.offset * 8)
            }
            let count = Int32(bitPattern: value)
            guard count >= 0, Int(count) <= G722Decoder.maximumPCMPacketBytes else { throw Error.invalidSilenceLength }
            return .silence(pcmByteCount: Int(count))
        default:
            throw Error.unsupportedCommand
        }
    }
}

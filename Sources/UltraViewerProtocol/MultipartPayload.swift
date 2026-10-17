import Foundation

/// Application parts reconstructed from RemoteControl.dll helpers 0x06000850
/// and 0x06000852. This sits inside the relay/direct envelope; it has no count,
/// command interpretation, encryption or outer transport length of its own.
public enum MultipartPayload {
    public struct Limits: Sendable {
        public let maximumPayloadLength: Int
        public let maximumPartLength: Int
        public let maximumPartCount: Int

        /// These are local resource limits, not negotiated UltraViewer values.
        public init(maximumPayloadLength: Int = 16 * 1024 * 1024,
                    maximumPartLength: Int = 16 * 1024 * 1024,
                    maximumPartCount: Int = 4096) {
            precondition((4...Int(Int32.max)).contains(maximumPayloadLength))
            precondition((0...Int(Int32.max)).contains(maximumPartLength))
            precondition(maximumPartCount > 0)
            self.maximumPayloadLength = maximumPayloadLength
            self.maximumPartLength = maximumPartLength
            self.maximumPartCount = maximumPartCount
        }
    }

    public enum Error: Swift.Error, Equatable {
        case emptyPayload
        case payloadTooLarge
        case partTooLarge
        case tooManyParts
        case invalidLength
        case truncatedLength
        case truncatedPart
    }

    /// Each part is UInt32LE length followed by those bytes. A Windows null
    /// entry and an empty byte array both serialize as a zero-length part.
    public static func encode(_ parts: [Data], limits: Limits = Limits()) throws -> Data {
        guard !parts.isEmpty else { throw Error.emptyPayload }
        guard parts.count <= limits.maximumPartCount else { throw Error.tooManyParts }
        var totalLength = 0
        for part in parts {
            guard part.count <= limits.maximumPartLength else { throw Error.partTooLarge }
            let (withHeader, headerOverflow) = totalLength.addingReportingOverflow(4)
            let (next, partOverflow) = withHeader.addingReportingOverflow(part.count)
            guard !headerOverflow, !partOverflow, next <= limits.maximumPayloadLength else {
                throw Error.payloadTooLarge
            }
            totalLength = next
        }
        var result = Data()
        result.reserveCapacity(totalLength)
        for part in parts {
            let length = UInt32(part.count)
            result.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: length >> ($0 * 8)) })
            result.append(part)
        }
        return result
    }

    /// Decodes a complete application payload. Truncated records are errors,
    /// since transport framing has already established the payload boundary.
    /// Empty payload rejection is local policy; empty individual parts are valid.
    public static func decode(_ payload: Data, limits: Limits = Limits()) throws -> [Data] {
        guard !payload.isEmpty else { throw Error.emptyPayload }
        guard payload.count <= limits.maximumPayloadLength else { throw Error.payloadTooLarge }
        var parts: [Data] = []
        var cursor = payload.startIndex
        while cursor < payload.endIndex {
            guard parts.count < limits.maximumPartCount else { throw Error.tooManyParts }
            guard payload.endIndex - cursor >= 4 else { throw Error.truncatedLength }
            let length = (0..<4).reduce(UInt32(0)) {
                $0 | UInt32(payload[cursor + $1]) << ($1 * 8)
            }
            cursor += 4
            // The Windows reader uses an overflow-checked UInt32-to-Int32 cast.
            guard length <= UInt32(Int32.max) else { throw Error.invalidLength }
            guard Int(length) <= limits.maximumPartLength else { throw Error.partTooLarge }
            guard Int(length) <= payload.endIndex - cursor else { throw Error.truncatedPart }
            let end = cursor + Int(length)
            parts.append(Data(payload[cursor..<end]))
            cursor = end
        }
        return parts
    }
}

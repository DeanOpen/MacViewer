import Foundation

/// Reconstructed from RemoteControl.P2P_TCPSocket, method 0x06000302.
/// This envelope alone does not implement the UltraViewer session protocol.
public enum LengthPrefixedFrame {
    public enum Error: Swift.Error, Equatable {
        case invalidLength
        case frameTooLarge
    }

    public static func encode(_ payload: Data) throws -> Data {
        guard payload.count <= Int(Int32.max) else { throw Error.frameTooLarge }
        let length = UInt32(payload.count)
        var frame = Data((0..<4).map { UInt8(truncatingIfNeeded: length >> ($0 * 8)) })
        frame.append(payload)
        return frame
    }

    /// Handles partial headers, partial bodies, and coalesced frames.
    /// The caller chooses a local memory budget; it is not a recovered wire limit.
    public struct Decoder {
        public let maximumPayloadLength: Int
        private var buffer = Data()

        public init(maximumPayloadLength: Int = 16 * 1024 * 1024) {
            precondition(maximumPayloadLength >= 0 && maximumPayloadLength <= Int(Int32.max))
            self.maximumPayloadLength = maximumPayloadLength
        }

        public mutating func append(_ bytes: Data) throws -> [Data] {
            var frames: [Data] = []
            var cursor = bytes.startIndex
            do {
                while cursor < bytes.endIndex {
                    if buffer.count < 4 {
                        let count = min(4 - buffer.count, bytes.endIndex - cursor)
                        buffer.append(bytes[cursor..<(cursor + count)])
                        cursor += count
                        if buffer.count < 4 { break }
                    }
                    let length = buffer.prefix(4).enumerated().reduce(UInt32(0)) {
                        $0 | UInt32($1.element) << ($1.offset * 8)
                    }
                    guard length <= UInt32(Int32.max) else { throw Error.invalidLength }
                    guard length <= maximumPayloadLength else { throw Error.frameTooLarge }
                    let totalLength = 4 + Int(length)
                    let count = min(totalLength - buffer.count, bytes.endIndex - cursor)
                    if count > 0 {
                        buffer.append(bytes[cursor..<(cursor + count)])
                        cursor += count
                    }
                    if buffer.count < totalLength { break }
                    frames.append(Data(buffer.dropFirst(4)))
                    buffer.removeAll(keepingCapacity: true)
                }
                return frames
            } catch {
                // A failed stream must be closed by its owner. Do not retain hostile bytes.
                buffer.removeAll(keepingCapacity: false)
                throw error
            }
        }

        public var hasIncompleteFrame: Bool { !buffer.isEmpty }
        public mutating func reset() { buffer.removeAll(keepingCapacity: false) }
    }
}

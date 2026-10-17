import Foundation

/// Captured RGB555 pixels: tightly packed bottom-up rows, UInt16 little endian,
/// blue bits0...4, green5...9, red10...14. No DWORD row padding is included.
public struct HostedScreenFrame: Sendable {
    public let width: Int
    public let height: Int
    public let rgb555BottomUp: Data

    public init(width: Int, height: Int, rgb555BottomUp: Data) {
        self.width = width
        self.height = height
        self.rgb555BottomUp = rgb555BottomUp
    }
}

/// Screen application payloads for the recovered modern Windows viewer path.
/// Returns LE32 multipart bytes before relay routing/encryption/TCP framing.
/// Authentication, capture permission, frame scheduling and sequence ownership
/// remain with the host session. This encoder advertises no optional capability.
public enum HostedScreenMessage {
    public enum Compression: Sendable {
        /// Level 1, standard Zstd, no dictionary. Production default.
        case zstandard
        /// Standard Zstd RAW blocks for independent wire fixtures/fallback.
        case raw
    }

    public enum Error: Swift.Error, Equatable {
        case invalidGeometry
        case invalidPixelLength(expected: Int, received: Int)
        case invalidVersion
        case sizeLimitExceeded
    }

    public static let firstFrameNumber: Int32 = -2_147_483_646
    /// Local policy, including multipart and Zstd overhead, not a wire constant.
    public static let maximumPayloadBytes = 16 * 1024 * 1024
    public static let maximumDimension = 8192
    private static let maximumBlockBytes = 128 * 1024

    /// One monitor rectangle has a trailing separator because native InitMonitor
    /// splits on '|', uses UBound as the count, and iterates count-1 entries.
    /// Version must select the recovered >=6.0.0 command1 drawing contract.
    public static func initialization(width: Int, height: Int, version: String,
                                      virtualLeft: Int32 = 0, virtualTop: Int32 = 0) throws -> Data {
        _ = try checkedPixelCount(width: width, height: height)
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard version.utf8.count <= 64, components.count == 3,
              components.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }),
              let major = Int(components[0]), major >= 6,
              Int(components[1]) != nil, Int(components[2]) != nil else { throw Error.invalidVersion }
        // No licensing/sound/default-tile slots are needed for this RGB555
        // sender. Omitted part14 selects native default tile16.
        let right = Int64(virtualLeft) + Int64(width), bottom = Int64(virtualTop) + Int64(height)
        guard right <= Int64(Int32.max), bottom <= Int64(Int32.max) else { throw Error.invalidGeometry }
        let monitor = "\(virtualLeft):\(virtualTop):\(right):\(bottom)|"
        let parts = [Data([0]), long(Int32(width)), long(Int32(height)), Data(), Data(),
                     Data([0]), Data(version.utf8), Data([1]), Data(monitor.utf8),
                     long(virtualLeft), long(virtualTop)]
        return try MultipartPayload.encode(parts)
    }

    /// A single full-screen main rectangle, with no JPEG, scroll or cache data.
    /// Source rows are reversed because UVC ordinal24 consumes top-down packed
    /// rectangle rows before writing the Windows bottom-up converter DIB.
    public static func fullFrame(_ frame: HostedScreenFrame, sequence: Int32,
                                 compression: Compression = .zstandard) throws -> Data {
        let byteCount = try checkedPixelCount(width: frame.width, height: frame.height)
        guard frame.rgb555BottomUp.count == byteCount else {
            throw Error.invalidPixelLength(expected: byteCount, received: frame.rgb555BottomUp.count)
        }
        // 11 length words + command + rectangle + sequence. The compressed
        // part gets the remaining budget, including its own Zstd frame header.
        let maximumCompressedBytes = maximumPayloadBytes - (44 + 1 + 8 + 4)
        if case .raw = compression {
            let blockCount = (byteCount + maximumBlockBytes - 1) / maximumBlockBytes
            guard byteCount <= maximumCompressedBytes - 9 - blockCount * 3 else {
                throw Error.sizeLimitExceeded
            }
        }
        let stride = frame.width * 2
        var topDown = Data(count: byteCount)
        frame.rgb555BottomUp.withUnsafeBytes { source in
            topDown.withUnsafeMutableBytes { target in
                for row in 0..<frame.height {
                    target.baseAddress!.advanced(by: row * stride).copyMemory(
                        from: source.baseAddress!.advanced(by: (frame.height - row - 1) * stride),
                        byteCount: stride)
                }
            }
        }
        var rectangle = Data()
        for value in [UInt16(0), 0, UInt16(frame.width), UInt16(frame.height)] {
            rectangle.append(UInt8(truncatingIfNeeded: value))
            rectangle.append(UInt8(value >> 8))
        }
        let compressed: Data
        switch compression {
        case .zstandard:
            do {
                compressed = try ZstdScreenEncoder.encode(topDown,
                    maximumOutputBytes: maximumCompressedBytes)
            } catch ZstdScreenEncoder.Error.outputLimitExceeded {
                throw Error.sizeLimitExceeded
            }
        case .raw:
            compressed = rawZstdFrame(topDown)
        }
        let parts = [Data([1]), rectangle, compressed, Data(), long(sequence),
                     Data(), Data(), Data(), Data(), Data(), Data()]
        return try MultipartPayload.encode(parts)
    }

    /// Reply to the viewer's raw ASCII20 keepalive, as the original host does.
    public static func keepaliveReply() throws -> Data {
        try MultipartPayload.encode([Data([20])])
    }

    /// Standard Zstd frame: no dictionary ID/checksum, single segment, explicit
    /// four-byte content size, and final-bit-marked raw blocks <=128 KiB.
    /// Called only after the bounded nonempty frame validation above.
    private static func rawZstdFrame(_ bytes: Data) -> Data {
        var result = Data([0x28, 0xb5, 0x2f, 0xfd, 0xa0])
        result.append(long(Int32(bytes.count)))
        var cursor = 0
        while cursor < bytes.count {
            let count = min(maximumBlockBytes, bytes.count - cursor)
            let isLast = cursor + count == bytes.count
            let header = UInt32(count << 3) | (isLast ? 1 : 0)
            result.append(contentsOf: (0..<3).map { UInt8(truncatingIfNeeded: header >> ($0 * 8)) })
            result.append(bytes.subdata(in: cursor..<(cursor + count)))
            cursor += count
        }
        return result
    }

    private static func checkedPixelCount(width: Int, height: Int) throws -> Int {
        guard (1...maximumDimension).contains(width), (1...maximumDimension).contains(height) else {
            throw Error.invalidGeometry
        }
        let count = width * height * 2 // Bounded dimensions keep this within Int.
        guard count <= maximumPayloadBytes else { throw Error.sizeLimitExceeded }
        return count
    }

    private static func long(_ value: Int32) -> Data {
        let bits = UInt32(bitPattern: value)
        return Data((0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) })
    }
}

import Foundation

/// Text clipboard application payloads. The caller owns consent, session/route
/// authentication, direction permissions, clipboard access and echo suppression.
public enum ClipboardProtocol {
    public struct WireMessage: Equatable, Sendable {
        public let payload: Data
        public let formatFlag: Bool
    }

    public enum ViewerEncoding: Sendable {
        /// Modern host: ASCII header followed by dictionary-free Zstd UTF-16LE.
        case compressed
        /// Legacy host: UTF-16LE command5, including its delimiter prefix.
        case legacyUnicode
    }

    public enum Error: Swift.Error, Equatable {
        case malformedMessage
        case unsupportedCommand
        case invalidText
        case unsupportedLegacyDelimiter
        case sizeLimitExceeded
        case decompressedLengthMismatch(expected: Int, received: Int)
    }

    /// Local text-only limits, independent of the Windows implementation limits.
    public static let maximumTextBytes = 1024 * 1024
    public static let maximumPayloadBytes = 2 * 1024 * 1024
    private static let legacyPrefix = "5|||"
    private static let compressedPrefix = Data("33|||".utf8)

    /// Controller→host. Modern bytes are NOT LE32 multipart; only the ASCII
    /// header is text. Keep the appended compressed bytes intact in transport.
    public static func viewerToHost(_ text: String,
                                    encoding: ViewerEncoding = .compressed) throws -> WireMessage {
        let utf16 = try encodeText(text)
        // The original host retries its ANSI fallback when modern33 expands
        // to zero bytes. Empty text uses the established legacy command5 path.
        if utf16.isEmpty {
            return WireMessage(payload: utf16Bytes(legacyPrefix), formatFlag: true)
        }
        switch encoding {
        case .compressed:
            let compressed = try ZstdScreenEncoder.encode(utf16,
                maximumOutputBytes: maximumPayloadBytes - 32)
            return WireMessage(payload: Data("33|||\(utf16.count)|||".utf8) + compressed,
                               formatFlag: false)
        case .legacyUnicode:
            // Windows' command5 IPC splits every delimiter and consumes only
            // text field1. Reject that ambiguous legacy form instead of losing
            // the suffix. The modern compressed form carries arbitrary text.
            guard !text.contains("|||") else { throw Error.unsupportedLegacyDelimiter }
            return WireMessage(payload: utf16Bytes(legacyPrefix) + utf16, formatFlag: true)
        }
    }

    /// Decode the original viewer wire bytes, after relay/direct framing.
    public static func decodeViewerToHost(_ payload: Data, formatFlag: Bool) throws -> String {
        try checkPayload(payload.count)
        if !formatFlag { return try decodeCompressedViewer(payload) }
        let text = try decodeUTF16(payload, maximumBytes: maximumPayloadBytes)
        return try decodeLegacyViewerText(text)
    }

    /// For a host adapter that has already converted true-flag UTF-16LE to UTF-8.
    /// False-flag command33 must reach this method unchanged, including binary
    /// compressed data; never normalize that data through a text conversion.
    public static func decodeNormalizedViewerToHost(_ payload: Data) throws -> String {
        try checkPayload(payload.count)
        if payload.starts(with: compressedPrefix) { return try decodeCompressedViewer(payload) }
        guard let text = String(data: payload, encoding: .utf8) else { throw Error.invalidText }
        return try decodeLegacyViewerText(text)
    }

    /// Host→controller modern command33, already LE32 multipart encoded. Send
    /// with the ordinary false format flag; it has no extra clipboard wrapper.
    public static func hostToViewer(_ text: String) throws -> Data {
        let utf16 = try encodeText(text)
        let compressed = try ZstdScreenEncoder.encode(utf16,
            maximumOutputBytes: maximumPayloadBytes - 32)
        return try MultipartPayload.encode([Data([33]), long(utf16.count), compressed],
            limits: .init(maximumPayloadLength: maximumPayloadBytes,
                          maximumPartLength: maximumPayloadBytes, maximumPartCount: 3))
    }

    /// Decodes modern multipart33 and the original uncompressed multipart5.
    /// Clipboard/session permissions are deliberately not implied by decoding.
    public static func decodeHostToViewer(parts: [Data]) throws -> String {
        var total = 0
        for part in parts {
            guard part.count <= maximumPayloadBytes - total else { throw Error.sizeLimitExceeded }
            total += part.count
        }
        guard let command = parts.first?.first else { throw Error.malformedMessage }
        switch command {
        case 33:
            guard parts.count >= 3, parts[1].count >= 4 else { throw Error.malformedMessage }
            let size = [UInt8](parts[1].prefix(4))
            let expected = (0..<4).reduce(UInt32(0)) { $0 | UInt32(size[$1]) << ($1 * 8) }
            guard expected <= UInt32(maximumTextBytes) else { throw Error.sizeLimitExceeded }
            return try decodeCompressedText(parts[2], expected: Int(expected))
        case 5:
            guard parts.count >= 2 else { throw Error.malformedMessage }
            return try decodeUTF16(parts[1], maximumBytes: maximumTextBytes)
        default:
            throw Error.unsupportedCommand
        }
    }

    private static func decodeCompressedViewer(_ payload: Data) throws -> String {
        let bytes = [UInt8](payload)
        guard payload.starts(with: compressedPrefix) else { throw Error.unsupportedCommand }
        var cursor = compressedPrefix.count
        let firstDigit = cursor
        var expected = 0
        while cursor < bytes.count, (48...57).contains(bytes[cursor]) {
            guard cursor - firstDigit < 10 else { throw Error.malformedMessage }
            expected = expected * 10 + Int(bytes[cursor] - 48)
            guard expected <= maximumTextBytes else { throw Error.sizeLimitExceeded }
            cursor += 1
        }
        guard cursor > firstDigit, bytes.count - cursor >= 3,
              bytes[cursor..<(cursor + 3)].allSatisfy({ $0 == 124 }) else {
            throw Error.malformedMessage
        }
        cursor += 3
        return try decodeCompressedText(Data(bytes[cursor...]), expected: expected)
    }

    private static func decodeCompressedText(_ compressed: Data, expected: Int) throws -> String {
        guard expected % 2 == 0 else { throw Error.invalidText }
        guard !compressed.isEmpty else { throw Error.malformedMessage }
        // UVC ordinal50 uses a fresh one-shot context with no screen dictionary.
        let decoder = try ZstdScreenDecoder(maximumOutputBytes: maximumTextBytes)
        let decoded = try decoder.append(compressed)
        try decoder.finish()
        guard decoded.count == expected else {
            throw Error.decompressedLengthMismatch(expected: expected, received: decoded.count)
        }
        return try decodeUTF16(decoded, maximumBytes: maximumTextBytes)
    }

    private static func decodeLegacyViewerText(_ text: String) throws -> String {
        guard text.hasPrefix(legacyPrefix) else { throw Error.unsupportedCommand }
        let content = String(text.dropFirst(legacyPrefix.count))
        // The sender appends the complete text after this prefix. Preserve it
        // on a Mac host even though the original Windows IPC loses text after
        // an embedded delimiter. Only legacy sends to Windows reject that case.
        _ = try encodeText(content)
        return content
    }

    private static func encodeText(_ text: String) throws -> Data {
        guard text.utf16.count <= maximumTextBytes / 2 else { throw Error.sizeLimitExceeded }
        guard !text.utf16.contains(0) else { throw Error.invalidText }
        return utf16Bytes(text)
    }

    private static func utf16Bytes(_ text: String) -> Data {
        var bytes = Data(capacity: text.utf16.count * 2)
        for unit in text.utf16 {
            bytes.append(UInt8(truncatingIfNeeded: unit))
            bytes.append(UInt8(unit >> 8))
        }
        return bytes
    }

    private static func decodeUTF16(_ data: Data, maximumBytes: Int) throws -> String {
        guard data.count <= maximumBytes else { throw Error.sizeLimitExceeded }
        guard data.count % 2 == 0 else { throw Error.invalidText }
        let bytes = [UInt8](data)
        var units: [UInt16] = []
        units.reserveCapacity(data.count / 2)
        var cursor = 0
        while cursor < bytes.count {
            let unit = UInt16(bytes[cursor]) | UInt16(bytes[cursor + 1]) << 8
            guard unit != 0, !(0xdc00...0xdfff).contains(unit) else { throw Error.invalidText }
            units.append(unit)
            cursor += 2
            if (0xd800...0xdbff).contains(unit) {
                guard cursor + 1 < bytes.count else { throw Error.invalidText }
                let low = UInt16(bytes[cursor]) | UInt16(bytes[cursor + 1]) << 8
                guard (0xdc00...0xdfff).contains(low) else { throw Error.invalidText }
                units.append(low)
                cursor += 2
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func checkPayload(_ count: Int) throws {
        guard count <= maximumPayloadBytes else { throw Error.sizeLimitExceeded }
    }

    private static func long(_ value: Int) -> Data {
        (0..<4).reduce(into: Data()) { $0.append(UInt8(truncatingIfNeeded: value >> ($1 * 8))) }
    }
}

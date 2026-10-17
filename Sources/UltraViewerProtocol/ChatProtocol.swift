import Foundation

/// Chat application messages for an authenticated peer route. This type does
/// not perform routing, session authorization, UI display, or transcript logging.
public enum ChatProtocol {
    public enum Event: Sendable, Equatable {
        case message(String)
        case typing(Bool)
    }

    public struct Outbound: Sendable, Equatable {
        public let payload: Data
        public let formatFlag: Bool
    }

    public enum Error: Swift.Error, Equatable {
        case textTooLarge, invalidEncoding, invalidText, unsupportedDelimiter, malformedMessage
    }

    /// Local resource budget in bytes, checked for both UTF-8 and UTF-16LE.
    public static let maximumTextBytes = 32 * 1024

    /// Form1.SendString: UTF-16LE "12|||<text>", relay format flag true.
    public static func viewerToHost(text: String) throws -> Outbound {
        try validate(text)
        // The Windows host uses an unlimited delimiter split and reads index1.
        guard !text.contains("|||") else { throw Error.unsupportedDelimiter }
        return Outbound(payload: utf16LE("12|||" + text), formatFlag: true)
    }

    /// The Windows viewer sends these through the same Unicode SendString path.
    public static func viewerToHostTyping(_ isTyping: Bool) -> Outbound {
        Outbound(payload: utf16LE(isTyping ? "29" : "30"), formatFlag: true)
    }

    /// clsRemoteClient.SendData: multipart [[12], UTF-16LE text].
    public static func hostToViewer(text: String) throws -> Data {
        try validate(text)
        return try MultipartPayload.encode([Data([12]), utf16LE(text)], limits: chatLimits)
    }

    public static func hostToViewerTyping(_ isTyping: Bool) throws -> Data {
        try MultipartPayload.encode([Data([isTyping ? 29 : 30])], limits: chatLimits)
    }

    /// Decode text already normalized from the relay's ANSI/Unicode flag into
    /// UTF-8 by the host. Unrelated commands return nil; malformed chat throws.
    public static func decodeHostPayload(_ payload: Data) throws -> Event? {
        if payload == Data("29".utf8) { return .typing(true) }
        if payload == Data("30".utf8) { return .typing(false) }
        let prefix = Data("12|||".utf8)
        guard payload.starts(with: prefix) else { return nil }
        guard payload.count - prefix.count <= maximumTextBytes else { throw Error.textTooLarge }
        guard let text = String(data: payload.dropFirst(prefix.count), encoding: .utf8) else {
            throw Error.invalidEncoding
        }
        try validate(text)
        guard !text.contains("|||") else { throw Error.unsupportedDelimiter }
        return .message(text)
    }

    /// Decode the host-to-viewer multipart form after bounded multipart parsing.
    public static func decodeViewerParts(_ parts: [Data]) throws -> Event? {
        guard let command = parts.first?.first, [12, 29, 30].contains(command) else { return nil }
        guard parts[0].count == 1 else { throw Error.malformedMessage }
        if command != 12 {
            guard parts.count == 1 else { throw Error.malformedMessage }
            return .typing(command == 29)
        }
        guard parts.count == 2 else { throw Error.malformedMessage }
        let bytes = parts[1]
        guard bytes.count <= maximumTextBytes else { throw Error.textTooLarge }
        let text = try strictUTF16LE(bytes)
        try validate(text)
        return .message(text)
    }

    private static let chatLimits = MultipartPayload.Limits(
        maximumPayloadLength: maximumTextBytes + 9,
        maximumPartLength: maximumTextBytes, maximumPartCount: 2)

    private static func validate(_ text: String) throws {
        guard text.utf8.count <= maximumTextBytes,
              text.utf16.count <= maximumTextBytes / 2 else { throw Error.textTooLarge }
        // Preserve line breaks and tabs; reject BSTR terminators and other
        // control characters as local text policy, not an observed wire limit.
        guard text.unicodeScalars.allSatisfy({ scalar in
            scalar.value >= 32 || [9, 10, 13].contains(scalar.value)
        }) else { throw Error.invalidText }
    }

    private static func utf16LE(_ text: String) -> Data {
        var bytes = Data()
        bytes.reserveCapacity(text.utf16.count * 2)
        for unit in text.utf16 {
            bytes.append(UInt8(truncatingIfNeeded: unit))
            bytes.append(UInt8(truncatingIfNeeded: unit >> 8))
        }
        return bytes
    }

    private static func strictUTF16LE(_ bytes: Data) throws -> String {
        guard bytes.count.isMultiple(of: 2) else { throw Error.invalidEncoding }
        let raw = [UInt8](bytes)
        var units: [UInt16] = []
        units.reserveCapacity(raw.count / 2)
        var index = 0
        while index < raw.count {
            let unit = UInt16(raw[index]) | UInt16(raw[index + 1]) << 8
            if (0xd800...0xdbff).contains(unit) {
                guard index + 3 < raw.count else { throw Error.invalidEncoding }
                let low = UInt16(raw[index + 2]) | UInt16(raw[index + 3]) << 8
                guard (0xdc00...0xdfff).contains(low) else { throw Error.invalidEncoding }
                units.append(unit); units.append(low); index += 4
            } else {
                guard !(0xdc00...0xdfff).contains(unit) else { throw Error.invalidEncoding }
                units.append(unit); index += 2
            }
        }
        return String(decoding: units, as: UTF16.self)
    }
}

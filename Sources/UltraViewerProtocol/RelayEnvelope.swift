import Foundation

/// IPv4 routing address used by VTCPClient.Send (MethodDef 0x06000de1).
/// This address is separate from an UltraViewer partner ID.
public struct RelayIPv4Address: Equatable, Hashable, Sendable, CustomStringConvertible {
    public enum Error: Swift.Error, Equatable { case invalidAddress }
    private let value: UInt32

    public init(_ dottedDecimal: String) throws {
        let parts = dottedDecimal.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { throw Error.invalidAddress }
        var value: UInt32 = 0
        for (index, part) in parts.enumerated() {
            guard !part.isEmpty, part.utf8.count <= 3,
                  part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let octet = UInt8(part) else { throw Error.invalidAddress }
            value |= UInt32(octet) << ((3 - index) * 8)
        }
        self.value = value
    }

    fileprivate init(wireBytes: ArraySlice<UInt8>) {
        precondition(wireBytes.count == 4)
        value = wireBytes.enumerated().reduce(UInt32(0)) {
            $0 | UInt32($1.element) << ($1.offset * 8)
        }
    }

    public var octets: [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> ((3 - $0) * 8)) }
    }

    public var description: String { octets.map(String.init).joined(separator: ".") }
}

/// Inner relay message, before LengthPrefixedFrame framing.
/// Recovered from VTCPClient.Send (0x06000de1) and dispatch (0x06000e37).
public enum RelayEnvelope: Equatable, Sendable {
    case forward(address: RelayIPv4Address, port: UInt16, formatFlag: Bool, payload: Data)
    /// The desktop/server protocol interprets these raw bytes. A leading optional
    /// format flag is retained because the supplied receive dispatcher retains it.
    case system(payload: Data)

    public enum Error: Swift.Error, Equatable {
        case emptyEnvelope
        case truncatedForward
        case unknownKind(UInt8)
    }

    public func encode() -> Data {
        switch self {
        case let .forward(address, port, flag, payload):
            var result = Data([0, flag ? 1 : 0])
            // Original helper333 builds a*256^3+b*256^2+c*256+d, then
            // BitConverter.GetBytes(UInt32) writes it little-endian on Windows.
            result.append(contentsOf: address.octets.reversed())
            result.append(UInt8(truncatingIfNeeded: port))
            result.append(UInt8(truncatingIfNeeded: port >> 8))
            result.append(payload)
            return result
        case let .system(payload):
            return Self.encodeSystem(payload: payload)
        }
    }

    /// `formatFlag == nil` matches Send's default final argument (false).
    /// Supplying a Boolean matches its explicit include-flag variation.
    public static func encodeSystem(payload: Data, formatFlag: Bool? = nil) -> Data {
        var result = Data([1])
        if let formatFlag { result.append(formatFlag ? 1 : 0) }
        result.append(payload)
        return result
    }

    public static func decode(_ bytes: Data) throws -> Self {
        let raw = Array(bytes)
        guard let kind = raw.first else { throw Error.emptyEnvelope }
        switch kind {
        case 0:
            guard raw.count >= 8 else { throw Error.truncatedForward }
            return .forward(address: RelayIPv4Address(wireBytes: raw[2..<6]),
                            port: UInt16(raw[6]) | UInt16(raw[7]) << 8,
                            formatFlag: raw[1] > 0, payload: Data(raw.dropFirst(8)))
        case 1:
            return .system(payload: Data(raw.dropFirst()))
        default:
            throw Error.unknownKind(kind)
        }
    }
}

/// Two distinct system channels; peer ASCII20 has its own routed envelope.
/// Checked source intervals and independent wire fixtures: desktop-heartbeats.md.
public enum RelayKeepalive {
    public static var relayEnvelope: Data {
        RelayEnvelope.encodeSystem(payload: Data("ping".utf8))
    }

    public static func commandEnvelope() throws -> Data {
        let encrypted = try LegacyCommandCipher.desktopServerCommands.encrypt(Data("2".utf8))
        return RelayEnvelope.encodeSystem(payload: encrypted, formatFlag: false)
    }
}

/// P2P inner bytes, before optional AES and outer length-prefix framing.
/// Recovered from P2PSend (0x06000e2c) and receive dispatch (0x06000304).
public struct DirectPeerEnvelope: Equatable, Sendable {
    public let formatFlag: Bool
    public let payload: Data
    public enum Error: Swift.Error, Equatable { case emptyEnvelope }

    public init(formatFlag: Bool, payload: Data) {
        self.formatFlag = formatFlag
        self.payload = payload
    }

    public func encode() -> Data { Data([formatFlag ? 1 : 0]) + payload }

    public static func decode(_ bytes: Data) throws -> Self {
        guard let flag = bytes.first else { throw Error.emptyEnvelope }
        return Self(formatFlag: flag > 0, payload: Data(bytes.dropFirst()))
    }
}

/// Exact streaming HTTP request headers reconstructed from VTCPClient 0x06000e25.
/// The caller supplies the host; this does not discover or authenticate a server.
public enum RelayHTTPPreamble {
    public enum Method: String, Sendable { case post = "POST", get = "GET" }
    public enum Error: Swift.Error, Equatable { case invalidHost }

    public static func request(host: String, method: Method = .post) throws -> Data {
        // Local input validation prevents a user-provided host from adding headers.
        guard !host.isEmpty, host.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw Error.invalidHost
        }
        let lines = [
            "\(method.rawValue) /UVService/ HTTP/1.1",
            "User-Agent: Mozilla/4.0 (compatible; MSIE5.01; Windows NT)",
            "Content-Type: application/octet-stream",
            "Connection: Keep-Alive",
            "Content-length: 8589934590",
            "Host: \(host)", "", "",
        ]
        return Data(lines.joined(separator: "\r\n").utf8)
    }
}

/// Bounded equivalent of VTCPClient's first-response CRLFCRLF stripping.
/// This recognizes the header boundary only; it does not validate HTTP status.
public struct RelayHTTPPreambleDecoder: Sendable {
    public enum Error: Swift.Error, Equatable { case headerTooLarge }
    public let maximumHeaderBytes: Int
    public private(set) var hasReceivedHeader = false
    /// Diagnostic only; header stripping still matches the recovered behavior.
    /// Unrecognized or non-HTTP headers leave this nil.
    public private(set) var responseStatusCode: Int?
    private var header = Data()
    private static let delimiter = Data([13, 10, 13, 10])

    /// The bound is a local memory limit, not a recovered protocol maximum.
    public init(maximumHeaderBytes: Int = 32_768) {
        precondition(maximumHeaderBytes >= 4)
        self.maximumHeaderBytes = maximumHeaderBytes
    }

    /// Returns only bytes following the first complete header. After that, all
    /// appended bytes pass through. Partial headers are buffered within the bound.
    public mutating func append(_ bytes: Data) throws -> Data {
        if hasReceivedHeader { return bytes }
        var cursor = bytes.startIndex
        while cursor < bytes.endIndex {
            guard header.count < maximumHeaderBytes else {
                header.removeAll(keepingCapacity: false)
                throw Error.headerTooLarge
            }
            header.append(bytes[cursor])
            cursor += 1
            if header.count >= 4, header.suffix(4) == Self.delimiter {
                hasReceivedHeader = true
                let line = String(decoding: header.prefix { $0 != 13 && $0 != 10 }, as: UTF8.self)
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                if fields.count >= 2, fields[0].hasPrefix("HTTP/"),
                   fields[1].utf8.count == 3,
                   fields[1].utf8.allSatisfy({ (48...57).contains($0) }) {
                    responseStatusCode = Int(fields[1])
                }
                header.removeAll(keepingCapacity: false)
                return Data(bytes[cursor...])
            }
        }
        return Data()
    }

    public mutating func reset() {
        header.removeAll(keepingCapacity: false)
        hasReceivedHeader = false
        responseStatusCode = nil
    }
}

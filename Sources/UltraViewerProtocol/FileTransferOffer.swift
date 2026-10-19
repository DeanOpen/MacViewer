import Foundation

/// The file sender can be either peer, independently of screen/control direction.
/// Viewer → host uses text/raw chunks; host → viewer uses multipart fields.
public struct FileTransferOffer: Sendable, Equatable {
    public static let command: UInt8 = 13
    public static let maximumPartSize = 32_000
    /// Local bound; sizes/offsets must also be exactly representable as Double.
    public static let maximumFileSize: Int64 = 999_999_999_999_999
    public let transferID: String
    public let fileName: String
    public let size: Int64

    public init(transferID: String, fileName: String, size: Int64) {
        self.transferID = transferID; self.fileName = fileName; self.size = size
    }
    public func viewerToHost() -> (payload: Data, formatFlag: Bool) {
        Self.text("13|||\(transferID)|||\(fileName)|||\(size)")
    }
    public static func viewerAccept(transferID: String) -> (payload: Data, formatFlag: Bool) {
        text("14|||\(transferID)|||1")
    }
    public static func viewerCancel(transferID: String) -> (payload: Data, formatFlag: Bool) {
        text("16|||\(transferID)")
    }
    public static func viewerChunkReceived(transferID: String) -> (payload: Data, formatFlag: Bool) {
        text("21|||\(transferID)")
    }
    public static func viewerChunk(transferID: String, offset: Int, data: Data) -> Data {
        Data("15|||\(transferID)|||\(offset)|||".utf8) + data
    }
    public func hostToViewer() throws -> Data {
        // Native Windows decodes these fields through the system ANSI codepage;
        // it does not negotiate that codepage. ASCII is portable across them.
        try MultipartPayload.encode([Data([13, 0]), Data(transferID.utf8), Data(Self.portableHostFileName(fileName).utf8), Self.double(size)])
    }
    public static func hostAccept(transferID: String) throws -> Data {
        try MultipartPayload.encode([Data([14, 0]), Data(transferID.utf8), Data([1, 0, 0, 0])])
    }
    public static func hostCancel(transferID: String) throws -> Data {
        try MultipartPayload.encode([Data([16, 0]), Data(transferID.utf8)])
    }
    public static func hostChunkReceived(transferID: String) throws -> Data {
        try MultipartPayload.encode([Data([21, 0]), Data(transferID.utf8)])
    }
    public static func hostChunk(transferID: String, offset: Int64, data: Data) throws -> Data {
        try MultipartPayload.encode([Data([15, 0]), Data(transferID.utf8), double(offset), data])
    }

    public static func decodeChunk(parts: [Data]) -> (transferID: String, offset: Int, data: Data)? {
        guard parts.count == 4, validCommand(parts[0], 15),
              let id = identifier(parts[1]), let offset = chunkOffset(parts[2]),
              parts[3].count <= maximumPartSize else { return nil }
        return (id, Int(offset), parts[3])
    }
    public static func decode(parts: [Data]) -> FileTransferOffer? {
        guard parts.count == 4, validCommand(parts[0], 13),
              let id = identifier(parts[1]),
              let name = String(data: parts[2], encoding: .windowsCP1252)
                ?? String(data: parts[2], encoding: .utf8),
              let size = integerDouble(parts[3], minimum: 0) else { return nil }
        let offer = FileTransferOffer(transferID: id, fileName: name, size: size)
        return offer.isValid ? offer : nil
    }
    /// Native host filenames have an unnegotiated ANSI encoding. Preserve the
    /// local Unicode source name in the UI; use a readable, Windows-safe ASCII
    /// name on this legacy host wire path. File contents remain unchanged.
    static func portableHostFileName(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "D")
        var safe = folded.map { character -> String in
            let value = String(character)
            return character.unicodeScalars.allSatisfy({ (32...126).contains($0.value) })
                && !value.contains(where: { "<>:\"/\\|?*".contains($0) }) ? value : "_"
        }.joined().trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if safe.isEmpty { safe = "file" }
        return safe
    }

    var isValid: Bool {
        Self.identifier(Data(transferID.utf8)) != nil && size >= 0 && size <= Self.maximumFileSize
            && !fileName.isEmpty && fileName.utf8.count <= 1024 && !fileName.contains("|||")
            && fileName.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
    }
    static func identifier(_ bytes: Data) -> String? {
        guard !bytes.isEmpty, bytes.count <= 64,
              bytes.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
    static func validCommand(_ bytes: Data, _ command: UInt8) -> Bool {
        bytes == Data([command]) || bytes == Data([command, 0])
    }
    /// Native clsRemoteClient selects Double8 for modern file transfer and
    /// Int32LE4 for the legacy path. Accept either exact positive representation.
    private static func chunkOffset(_ bytes: Data) -> Int64? {
        if bytes.count == 8 { return integerDouble(bytes, minimum: 1) }
        guard bytes.count == 4 else { return nil }
        let value = bytes.reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard value >= 1, value <= UInt32(Int32.max) else { return nil }
        return Int64(value)
    }

    static func integerDouble(_ bytes: Data, minimum: Int64) -> Int64? {
        guard bytes.count == 8 else { return nil }
        let bits = bytes.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let value = Double(bitPattern: bits)
        guard value.isFinite, value >= Double(minimum), value <= Double(maximumFileSize),
              value.rounded(.towardZero) == value else { return nil }
        return Int64(value)
    }
    private static func double(_ value: Int64) -> Data {
        let bits = Double(value).bitPattern
        return Data((0..<8).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) })
    }
    private static func text(_ value: String) -> (payload: Data, formatFlag: Bool) {
        (Data(value.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] }), true)
    }
}

enum FileTransferMessage: Equatable, Sendable {
    case offer(FileTransferOffer)
    case accept(id: String, offset: Int64)
    case chunk(id: String, offset: Int64, data: Data)
    case acknowledgment(String)
    case cancel(String)
    var transferID: String {
        switch self {
        case let .offer(offer): offer.transferID
        case let .accept(id, _), let .chunk(id, _, _), let .acknowledgment(id), let .cancel(id): id
        }
    }
    static func decodeHostParts(_ parts: [Data]) -> Self? {
        guard let command = parts.first?.first, [13, 14, 15, 16, 21].contains(command),
              FileTransferOffer.validCommand(parts[0], command) else { return nil }
        if command == 13 { return FileTransferOffer.decode(parts: parts).map(Self.offer) }
        if command == 15 {
            guard let part = FileTransferOffer.decodeChunk(parts: parts) else { return nil }
            return .chunk(id: part.transferID, offset: Int64(part.offset), data: part.data)
        }
        guard parts.count >= 2, let id = FileTransferOffer.identifier(parts[1]) else { return nil }
        if command == 14 {
            guard parts.count == 3, parts[2].count == 4 else { return nil }
            let offset = parts[2].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            guard offset == 1 else { return nil } // Resume is not implemented.
            return .accept(id: id, offset: 1)
        }
        guard parts.count == 2 else { return nil }
        return command == 16 ? .cancel(id) : .acknowledgment(id)
    }
    /// Split only the header: the file bytes may contain any delimiter/encoding.
    static func decodeViewerPayload(_ payload: Data) -> Self? {
        guard payload.count <= FileTransferOffer.maximumPartSize + 2048 else { return nil }
        if payload.starts(with: Data("15|||".utf8)) {
            let fields = splitHeader(payload, fields: 3)
            guard fields.count == 4, let id = FileTransferOffer.identifier(fields[1]),
                  let offset = decimal(fields[2], minimum: 1),
                  fields[3].count <= FileTransferOffer.maximumPartSize else { return nil }
            return .chunk(id: id, offset: offset, data: fields[3])
        }
        let fields = splitHeader(payload, fields: 4)
        guard let first = fields.first, let command = String(data: first, encoding: .utf8),
              fields.count >= 2, let id = FileTransferOffer.identifier(fields[1]) else { return nil }
        switch command {
        case "13":
            guard fields.count == 4, let name = String(data: fields[2], encoding: .utf8),
                  let size = decimal(fields[3], minimum: 0) else { return nil }
            let offer = FileTransferOffer(transferID: id, fileName: name, size: size)
            return offer.isValid ? .offer(offer) : nil
        case "14":
            guard fields.count == 3, fields[2] == Data("1".utf8) else { return nil }
            return .accept(id: id, offset: 1)
        case "16": return fields.count == 2 ? .cancel(id) : nil
        case "21": return fields.count == 2 ? .acknowledgment(id) : nil
        default: return nil
        }
    }
    private static func decimal(_ bytes: Data, minimum: Int64) -> Int64? {
        guard !bytes.isEmpty, bytes.count <= 16, bytes.allSatisfy({ (48...57).contains($0) }),
              let value = Int64(String(decoding: bytes, as: UTF8.self)),
              value >= minimum, value <= FileTransferOffer.maximumFileSize else { return nil }
        return value
    }
    private static func splitHeader(_ bytes: Data, fields: Int) -> [Data] {
        let delimiter = Data("|||".utf8)
        var remainder = bytes[...], result: [Data] = []
        for _ in 0..<fields {
            guard let range = remainder.range(of: delimiter) else { break }
            result.append(Data(remainder[..<range.lowerBound]))
            remainder = remainder[range.upperBound...]
        }
        result.append(Data(remainder))
        return result
    }
}
